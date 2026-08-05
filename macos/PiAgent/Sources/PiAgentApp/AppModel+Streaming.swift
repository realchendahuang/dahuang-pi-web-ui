import AppKit
import PiAgentCore
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import UserNotifications

@MainActor
extension AppModel {
    func loadSelectedSession() {
        guard let session = selectedSession else { return }
        let client = runtimeClient
        let cwd = session.cwd
        Task { [weak self] in
            do {
                let page = try await client.messages(
                    sessionId: session.id,
                    cwd: cwd,
                    runtimeId: session.runtimeId
                )
                let status = try? await client.status(
                    sessionId: session.id,
                    cwd: cwd,
                    runtimeId: session.runtimeId
                )
                guard let self else { return }
                self.mergeLoadedMessages(page.messages)
                self.synchronizeStreamingMessage()
                if let status { self.statusBySession[session.id] = status }
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    /// Loads the model and thinking-level catalogs for the selected session.
    /// Failures are non-fatal: the capsule falls back to the status-reported
    /// model name, so a missing catalog only means fewer picker options.
    func refreshModelOptions() {
        guard let session = selectedSession else { return }
        let client = runtimeClient
        Task { [weak self] in
            let models = try? await client.listModels(
                sessionId: session.id,
                cwd: session.cwd,
                runtimeId: session.runtimeId
            )
            let levels = try? await client.listThinkingLevels(
                sessionId: session.id,
                cwd: session.cwd,
                runtimeId: session.runtimeId
            )
            guard let self, self.selectedSessionID == session.id else { return }
            if let models { self.availableModels = models }
            if let levels { self.availableThinkingLevels = levels }
        }
    }

    func selectModel(provider: String, modelId: String) {
        guard let session = selectedSession else { return }
        let client = runtimeClient
        Task { [weak self] in
            do {
                let status = try await client.setModel(
                    sessionId: session.id,
                    cwd: session.cwd,
                    runtimeId: session.runtimeId,
                    provider: provider,
                    modelId: modelId
                )
                guard let self, self.selectedSessionID == session.id else { return }
                self.statusBySession[session.id] = status
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func selectThinkingLevel(_ level: String) {
        guard let session = selectedSession else { return }
        let client = runtimeClient
        Task { [weak self] in
            do {
                let status = try await client.setThinkingLevel(
                    sessionId: session.id,
                    cwd: session.cwd,
                    runtimeId: session.runtimeId,
                    level: level
                )
                guard let self, self.selectedSessionID == session.id else { return }
                self.statusBySession[session.id] = status
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    /// Cancels the agent's in-flight work for the selected session. The
    /// runtime sends a `status.update` afterwards, so the spinner clears on
    /// its own; we only surface failures here.
    func abortPrompt() {
        guard let session = selectedSession else { return }
        let client = runtimeClient
        Task { [weak self] in
            do {
                try await client.abort(
                    sessionId: session.id,
                    cwd: session.cwd,
                    runtimeId: session.runtimeId
                )
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func startSessionEventStream() {
        stopSessionEventStream()
        guard let session = selectedSession,
              session.archived != true,
              let client = runtimeClient as? any RuntimeEventStreamClient
        else { return }

        sessionStreamGeneration += 1
        let generation = sessionStreamGeneration
        lastSessionSequence = 0
        streamingMessage = nil
        let cwd = session.cwd

        sessionStreamTask = Task { [weak self] in
            guard let self else { return }
            var reconnectDelay: UInt64 = 250_000_000
            while !Task.isCancelled && self.isCurrentSessionStream(generation, sessionID: session.id) {
                let subscription = client.subscribe(
                    sessionId: session.id,
                    cwd: cwd,
                    runtimeId: session.runtimeId
                )
                self.sessionEventSubscription = subscription
                do {
                    var connected = false
                    for try await _ in subscription.ready {
                        connected = true
                        break
                    }
                    guard connected else { throw RuntimeClientError.connectionFailed("session event socket closed before handshake") }

                    let snapshot = try await client.streamSnapshot(
                        sessionId: session.id,
                        cwd: cwd,
                        runtimeId: session.runtimeId
                    )
                    guard self.isCurrentSessionStream(generation, sessionID: session.id) else {
                        subscription.cancel()
                        return
                    }
                    self.applyStreamSnapshot(snapshot, sessionID: session.id)
                    self.refreshExtensionInteractions(for: session)
                    reconnectDelay = 250_000_000

                    for try await event in subscription.events {
                        guard self.isCurrentSessionStream(generation, sessionID: session.id) else {
                            subscription.cancel()
                            return
                        }
                        self.applySessionEvent(event, sessionID: session.id)
                    }
                    throw RuntimeClientError.connectionFailed("session event socket closed")
                } catch is CancellationError {
                    subscription.cancel()
                    return
                } catch {
                    subscription.cancel()
                    guard self.isCurrentSessionStream(generation, sessionID: session.id) else { return }
                    self.errorMessage = "会话流正在重新连接：\(error.localizedDescription)"
                    self.scheduleOwnedRuntimeRecovery()
                    do {
                        try await Task.sleep(nanoseconds: reconnectDelay)
                    } catch {
                        return
                    }
                    reconnectDelay = min(reconnectDelay * 2, 5_000_000_000)
                }
            }
        }
    }

    func stopSessionEventStream() {
        sessionStreamGeneration += 1
        sessionStreamTask?.cancel()
        sessionEventSubscription?.cancel()
        sessionStreamTask = nil
        sessionEventSubscription = nil
    }

    func stopTerminalConnection() {
        terminalTask?.cancel()
        terminalSubscription?.cancel()
        terminalTask = nil
        terminalSubscription = nil
        terminalInfo = nil
        terminalCWD = nil
        terminalErrorMessage = nil
    }

    private func applyStreamSnapshot(_ snapshot: RuntimeStreamSnapshot, sessionID: String) {
        // A lower watermark means the daemon/runtime epoch changed. The
        // persisted history remains authoritative, so refresh it once and then
        // continue applying events from the new epoch.
        if snapshot.seq < lastSessionSequence {
            lastSessionSequence = 0
            loadSelectedSession()
        }
        lastSessionSequence = snapshot.seq
        streamingMessage = snapshot.partial
        synchronizeStreamingMessage()
    }

    private func applySessionEvent(_ event: RuntimeSessionEvent, sessionID: String) {
        if let sequence = event.seq {
            guard sequence > lastSessionSequence else { return }
            lastSessionSequence = sequence
        }

        switch event.type {
		case "extension.interaction.opened", "extension.interaction.closed":
			if let session = selectedSession, session.id == sessionID {
				refreshExtensionInteractions(for: session)
			}
        case "message.append":
            if let message = event.message { upsertTranscript(message) }
        case "assistant.delta":
            appendAssistantDelta(event.text ?? "")
        case "assistant.thinking.delta":
            // Thinking is intentionally not rendered as transcript content;
            // the visible assistant text still arrives through assistant.delta.
            break
        case "message.end":
            if let message = event.message {
                upsertTranscript(message)
            } else {
                synchronizeStreamingMessage()
            }
            streamingMessage = nil
        case "status.update":
            if let status = event.status { statusBySession[sessionID] = status }
        case "session.name":
            updateSessionName(sessionID: event.sessionId ?? sessionID, name: event.name)
        case "session.created":
            if let session = event.session {
                upsertSession(session)
            }
        case "session.error":
            errorMessage = event.errorMessage ?? event.text ?? "会话报告了一个错误。"
        case "tool.start":
            if let toolCallId = event.toolCallId {
                upsertTranscript(RuntimeMessage(
                    id: "tool:\(toolCallId)",
                    role: "tool",
                    text: [event.toolName, event.summary].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
                ))
            }
        case "tool.update", "tool.end":
            if let toolCallId = event.toolCallId {
                upsertTranscript(RuntimeMessage(
                    id: "tool:\(toolCallId)",
                    role: "tool",
                    text: event.text ?? event.output ?? ""
                ))
            }
        case "shell.start":
            if let command = event.command, !command.isEmpty {
                upsertTranscript(RuntimeMessage(id: "shell:\(lastSessionSequence)", role: "shell", text: "$ \(command)"))
            }
        case "shell.chunk", "command.output":
            if let text = event.chunk ?? event.text, !text.isEmpty {
                upsertTranscript(RuntimeMessage(id: "shell:\(lastSessionSequence)", role: "shell", text: text))
            }
        default:
            break
        }
    }

	func refreshExtensionInteractions(for session: RuntimeSession? = nil) {
		guard let session = session ?? selectedSession,
			  session.archived != true,
			  let client = runtimeClient as? any RuntimeExtensionInteractionClient
		else {
			extensionInteractions = []
			return
		}
		Task { [weak self] in
			guard let self else { return }
			do {
				let interactions = try await client.listExtensionInteractions(
					sessionId: session.id, cwd: session.cwd, runtimeId: session.runtimeId
				)
				guard self.selectedSessionID == session.id else { return }
				self.extensionInteractions = interactions
				if let active = interactions.first, active.kind == "editor" || active.kind == "input" {
					self.extensionInteractionText = active.prefill ?? ""
				}
			} catch {
				guard self.selectedSessionID == session.id else { return }
				self.errorMessage = "无法刷新扩展对话框：\(error.localizedDescription)"
			}
		}
	}

	func respondToExtensionInteraction(
		_ interaction: RuntimeExtensionInteraction,
		response: RuntimeExtensionInteractionResponse
	) {
		guard !isExtensionInteractionMutationInFlight,
			  let session = selectedSession,
			  session.id == interaction.sessionId,
			  let client = runtimeClient as? any RuntimeExtensionInteractionClient,
			  let expectedRuntimeEpoch = runtimeEpoch
		else {
			errorMessage = "请先重新连接 Runtime，再回应扩展对话框。"
			return
		}
		let commandId = UUID().uuidString
		isExtensionInteractionMutationInFlight = true
		errorMessage = nil
		Task { [weak self] in
			guard let self else { return }
			do {
				let receipt: RuntimeCommandReceipt
				do {
					receipt = try await client.respondToExtensionInteraction(
						sessionId: session.id, cwd: session.cwd, runtimeId: session.runtimeId,
						interactionId: interaction.id, response: response,
						commandId: commandId, expectedRuntimeEpoch: expectedRuntimeEpoch
					)
				} catch {
					receipt = try await self.commandReceiptAfterUnknownTransport(
						client: self.runtimeClient, commandId: commandId, originalError: error
					)
				}
				try self.requireCompletedReceipt(
					receipt,
					kind: "respond-extension-interaction",
					expectedRuntimeEpoch: expectedRuntimeEpoch
				)
				guard receipt.result?.responded == true,
					  receipt.result?.interaction?.id == interaction.id
				else {
					throw RuntimeClientError.serverError(500, "Runtime 交互回执不完整。")
				}
				self.isExtensionInteractionMutationInFlight = false
				self.refreshExtensionInteractions(for: session)
			} catch {
				self.errorMessage = error.localizedDescription
				self.isExtensionInteractionMutationInFlight = false
			}
		}
	}

    private func appendAssistantDelta(_ delta: String) {
        guard !delta.isEmpty else { return }
        if let current = streamingMessage {
            streamingMessage = RuntimeMessage(id: current.id, role: current.role, text: current.text + delta)
        } else {
            streamingMessage = RuntimeMessage(id: "streaming-assistant", role: "assistant", text: delta)
        }
        synchronizeStreamingMessage()
    }

    private func synchronizeStreamingMessage() {
        guard let streamingMessage else { return }
        transcriptMessages.removeAll { $0.id == streamingMessage.id }
        transcriptMessages.append(streamingMessage)
    }

    private func mergeLoadedMessages(_ loaded: [RuntimeMessage]) {
        var merged = loaded
        let loadedIDs = Set(loaded.map(\.id))
        for live in transcriptMessages where !loadedIDs.contains(live.id) {
            // Keep events that arrived while the history request was in
            // flight. Persisted messages normally have stable ids; the
            // role/text fallback prevents duplication for older Pi records
            // that do not carry an id.
            guard !merged.contains(where: { $0.id == live.id || ($0.role == live.role && $0.text == live.text) }) else { continue }
            merged.append(live)
        }
        transcriptMessages = merged
    }

    private func upsertTranscript(_ message: RuntimeMessage) {
        if let index = transcriptMessages.firstIndex(where: { $0.id == message.id }) {
            transcriptMessages[index] = message
        } else if message.id == "streaming-assistant" {
            transcriptMessages.removeAll { $0.role == "assistant" && $0.id == "streaming-assistant" }
            transcriptMessages.append(message)
        } else {
            transcriptMessages.append(message)
        }
    }

    private func upsertSession(_ session: RuntimeSession) {
        sessions.removeAll { $0.id == session.id }
        sessions.insert(session, at: 0)
    }

    private func updateSessionName(sessionID: String, name: String?) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let session = sessions[index]
        sessions[index] = RuntimeSession(
            id: session.id,
            cwd: session.cwd,
            runtimeId: session.runtimeId,
            path: session.path,
            persisted: session.persisted,
            name: name,
            created: session.created,
            modified: session.modified,
            messageCount: session.messageCount,
            firstMessage: session.firstMessage,
            archived: session.archived,
            archivedAt: session.archivedAt
        )
    }

    func replaceSessions(_ sessions: [RuntimeSession]) {
        let ordered = sessions.sorted { $0.modified > $1.modified }
        self.sessions = ordered
        if canUseProjectRuntime,
           let client = runtimeClient as? any RuntimeNotificationClient
        {
            taskNotifications?.reconcile(client: client, cwd: projectPath, sessions: ordered)
        }
        if let selectedSessionID, ordered.contains(where: { $0.id == selectedSessionID }) {
            loadSelectedSession()
            if selectedSession?.archived != true { startSessionEventStream() }
        } else {
            stopSessionEventStream()
            self.selectedSessionID = ordered.first(where: { $0.archived != true })?.id ?? ordered.first?.id
            if self.selectedSessionID != nil {
                loadSelectedSession()
                if selectedSession?.archived != true { startSessionEventStream() }
            }
        }
    }

}
