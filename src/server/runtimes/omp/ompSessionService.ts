import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { promisify } from "node:util";
import {
	AGENT_RUNTIME_CAPABILITIES,
	AGENT_RUNTIME_IDS,
	type AgentRuntimeId,
} from "../../../shared/agentRuntime.js";
import { parsePromptAttachments } from "../../../shared/promptAttachments.js";
import type {
	AgentRuntimesResponse,
	ArchiveSessionsResponse,
	CommandResult,
	MessagePage,
	SavedPromptAttachment,
	SessionBulkArchiveResponse,
	SessionBulkDeleteArchivedResponse,
	SessionBulkMutationRef,
	SessionCleanupExecuteResponse,
	SessionCleanupPreviewResponse,
	SessionInfo,
	SessionModel,
	SessionNotificationCatalogSnapshot,
	SessionNotificationInboxSnapshot,
	SessionStatus,
	SessionStreamSnapshot,
	SessionTreeNavigateRequest,
	SessionTreeNavigateResult,
	SessionUnreadCatalogSnapshot,
	SlashCommand,
} from "../../../shared/apiTypes.js";
import type { WorkspaceActivityService } from "../../activity/workspaceActivityService.js";
import type { SessionEventHub } from "../../realtime/sessionEventHub.js";
import { saveAttachmentsToWorkspace } from "../../sessions/attachmentService.js";
import type {
	SessionRouteLookup,
	SessionRouteRef,
	SessionRouteService,
} from "../../sessions/sessionService.js";
import {
	defaultOmpSessionDir,
	OmpSessionRuntime,
	type OmpRuntimeIdentity,
	type OmpSessionRuntimeOptions,
} from "./ompSessionRuntime.js";
import { resolveOmpExecutable } from "./ompExecutable.js";
import { listOmpSessionFiles } from "./ompSessionStore.js";

const execFileAsync = promisify(execFile);

export interface OmpSessionServiceOptions {
	command?: string;
	agentDir: string;
	sessionDir?: string;
	env?: NodeJS.ProcessEnv;
	runtimeClientOptions?: OmpSessionRuntimeOptions["clientOptions"];
	workspaceActivity?: Pick<
		WorkspaceActivityService,
		| "applySessionStatus"
		| "applySessionActivity"
		| "removeSession"
		| "reconcileSessionActivity"
	>;
}

export class OmpSessionService implements SessionRouteService {
	private readonly active = new Map<string, OmpSessionRuntime>();
	private readonly opening = new Map<string, Promise<OmpSessionRuntime>>();
	private readonly command: string;
	private readonly sessionDir: string;
	private readonly notificationDaemonId = randomUUID();
	private version: string | undefined;
	private resolvedCommand: string | undefined;

	constructor(
		private readonly events: SessionEventHub,
		private readonly options: OmpSessionServiceOptions,
	) {
		this.command = options.command ?? "omp";
		this.sessionDir =
			options.sessionDir ?? defaultOmpSessionDir(options.agentDir);
	}

	activeCount(): number {
		return this.active.size;
	}

	async runtimes(): Promise<AgentRuntimesResponse> {
		const availability = await this.probe();
		return {
			defaultRuntimeId: AGENT_RUNTIME_IDS.omp,
			runtimes: [
				{
					id: AGENT_RUNTIME_IDS.omp,
					kind: "omp-rpc",
					label: "OMP",
					available: availability.available,
					command: this.command,
					profileDir: this.options.agentDir,
					protocolVersion: 2,
					capabilities: [
						AGENT_RUNTIME_CAPABILITIES.prompt,
						AGENT_RUNTIME_CAPABILITIES.promptAttachments,
						AGENT_RUNTIME_CAPABILITIES.abort,
						AGENT_RUNTIME_CAPABILITIES.stop,
						AGENT_RUNTIME_CAPABILITIES.resume,
						AGENT_RUNTIME_CAPABILITIES.models,
						AGENT_RUNTIME_CAPABILITIES.thinkingLevels,
						AGENT_RUNTIME_CAPABILITIES.steering,
						AGENT_RUNTIME_CAPABILITIES.followUp,
						AGENT_RUNTIME_CAPABILITIES.shell,
						AGENT_RUNTIME_CAPABILITIES.commands,
						AGENT_RUNTIME_CAPABILITIES.branching,
						AGENT_RUNTIME_CAPABILITIES.compaction,
						AGENT_RUNTIME_CAPABILITIES.subagents,
					],
					...(this.version === undefined ? {} : { version: this.version }),
					...(availability.available
						? {}
						: { unavailableReason: availability.error }),
				},
			],
		};
	}

	async list(cwd: string): Promise<SessionInfo[]> {
		const stored = await listOmpSessionFiles(this.sessionDir, cwd);
		const active = [...this.active.values()]
			.filter((runtime) => runtime.identity.cwd === cwd)
			.map((runtime) => runtime.sessionInfo());
		const activeIds = new Set(active.map((session) => session.id));
		const sessions = [
			...active,
			...stored.filter((session) => !activeIds.has(session.id)),
		];
		this.options.workspaceActivity?.reconcileSessionActivity(
			cwd,
			sessions.map((session) => session.id),
		);
		return sessions.sort(
			(left, right) => Date.parse(right.modified) - Date.parse(left.modified),
		);
	}

	async start(
		cwd: string,
		options: { runtimeId?: AgentRuntimeId } = {},
	): Promise<SessionInfo> {
		if (
			options.runtimeId !== undefined &&
			options.runtimeId !== AGENT_RUNTIME_IDS.omp
		)
			throw new Error(
				`OMP session service cannot start runtime ${JSON.stringify(options.runtimeId)}`,
			);
		const runtime = await this.createRuntime(cwd);
		const session = runtime.sessionInfo();
		this.active.set(session.id, runtime);
		this.publishStatus(runtime);
		this.events.publishGlobal({ type: "session.created", session });
		return session;
	}

	async messages(
		ref: SessionRouteLookup,
		page?: { before?: number; limit?: number },
	): Promise<MessagePage> {
		return (await this.getOrOpen(ref)).messages(page);
	}

	async status(ref: SessionRouteLookup): Promise<SessionStatus> {
		const runtime = await this.getOrOpen(ref);
		await runtime.refresh();
		return runtime.status();
	}

	async streamSnapshot(
		ref: SessionRouteLookup,
	): Promise<SessionStreamSnapshot> {
		const runtime = await this.getOrOpen(ref);
		return runtime.streamSnapshot(
			this.events.currentSeq(runtime.identity.sessionId),
		);
	}

	notificationCatalog(): SessionNotificationCatalogSnapshot {
		return {
			daemonInstanceId: this.notificationDaemonId,
			catalogRevision: 0,
			sessions: [],
		};
	}

	unreadCatalog(): Promise<SessionUnreadCatalogSnapshot> {
		return Promise.resolve({
			catalogId: `omp-${this.notificationDaemonId}`,
			catalogRevision: 0,
			sessions: [],
		});
	}

	acknowledgeUnread(): Promise<SessionUnreadCatalogSnapshot> {
		return this.unreadCatalog();
	}

	notificationInbox(ref: SessionRouteRef): SessionNotificationInboxSnapshot {
		return emptyNotificationInbox(this.notificationDaemonId, ref);
	}

	dismissNotification(ref: SessionRouteRef): SessionNotificationInboxSnapshot {
		return this.notificationInbox(ref);
	}

	dismissAllNotifications(
		ref: SessionRouteRef,
	): SessionNotificationInboxSnapshot {
		return this.notificationInbox(ref);
	}

	async clearQueue(ref: SessionRouteLookup): Promise<SessionStatus> {
		const runtime = await this.getOrOpen(ref);
		if (runtime.status().pendingMessageCount > 0)
			throw new Error("OMP does not expose a safe clear-queue RPC command");
		return runtime.status();
	}

	async dismissWarning(ref: SessionRouteLookup): Promise<SessionStatus> {
		return this.status(ref);
	}

	async availableModels(ref: SessionRouteLookup): Promise<SessionModel[]> {
		return (await this.getOrOpen(ref)).availableModels();
	}

	async setModel(
		ref: SessionRouteLookup,
		provider: string,
		modelId: string,
	): Promise<SessionStatus> {
		const runtime = await this.getOrOpen(ref);
		await runtime.setModel(provider, modelId);
		return this.publishStatus(runtime);
	}

	async cycleModel(
		ref: SessionRouteLookup,
		direction: "forward" | "backward",
	): Promise<SessionStatus> {
		const runtime = await this.getOrOpen(ref);
		await runtime.cycleModel(direction);
		return this.publishStatus(runtime);
	}

	async availableThinkingLevels(ref: SessionRouteLookup): Promise<string[]> {
		return (await this.getOrOpen(ref)).thinkingLevels();
	}

	async setThinkingLevel(
		ref: SessionRouteLookup,
		level: string,
	): Promise<SessionStatus> {
		const runtime = await this.getOrOpen(ref);
		await runtime.setThinkingLevel(level);
		return this.publishStatus(runtime);
	}

	async cycleThinkingLevel(ref: SessionRouteLookup): Promise<SessionStatus> {
		const runtime = await this.getOrOpen(ref);
		await runtime.cycleThinkingLevel();
		return this.publishStatus(runtime);
	}

	async commands(ref: SessionRouteLookup): Promise<SlashCommand[]> {
		return (await this.getOrOpen(ref)).commands();
	}

	async prompt(
		ref: SessionRouteLookup,
		text: unknown,
		streamingBehavior?: unknown,
		attachments?: unknown,
	): Promise<void> {
		if (typeof text !== "string") throw new Error("Prompt text is required");
		if (
			streamingBehavior !== undefined &&
			streamingBehavior !== "steer" &&
			streamingBehavior !== "followUp"
		)
			throw new Error("Invalid prompt streaming behavior");
		const runtime = await this.getOrOpen(ref);
		await runtime.prompt(
			text,
			streamingBehavior,
			parsePromptAttachments(attachments),
		);
		this.publishStatus(runtime);
	}

	async saveAttachments(
		ref: SessionRouteLookup,
		attachments: unknown,
		folder?: string,
	): Promise<SavedPromptAttachment[]> {
		const cwd = cwdFromLookup(ref);
		if (cwd === undefined)
			throw new Error("cwd is required to save OMP attachments");
		return saveAttachmentsToWorkspace(
			cwd,
			parsePromptAttachments(attachments),
			folder === undefined ? {} : { folder },
		);
	}

	cleanupPreview(): Promise<SessionCleanupPreviewResponse> {
		return Promise.resolve(emptyCleanupPreview());
	}

	cleanup(): Promise<SessionCleanupExecuteResponse> {
		return Promise.resolve({
			...emptyCleanupPreview(),
			archivedSessionIds: [],
			deletedSessionIds: [],
		});
	}

	archiveMany(
		refs: readonly SessionBulkMutationRef[],
	): Promise<SessionBulkArchiveResponse> {
		return Promise.resolve({
			archived: true,
			archivedSessionIds: [],
			failures: refs.map((ref) => ({
				sessionId: ref.id,
				error: "OMP session archiving is not configured",
			})),
			generatedAt: new Date().toISOString(),
		});
	}

	deleteArchivedMany(
		refs: readonly SessionBulkMutationRef[],
	): Promise<SessionBulkDeleteArchivedResponse> {
		return Promise.resolve({
			deleted: true,
			deletedSessionIds: [],
			failures: refs.map((ref) => ({
				sessionId: ref.id,
				error: "OMP archived-session deletion is not configured",
			})),
			generatedAt: new Date().toISOString(),
		});
	}

	async shell(ref: SessionRouteLookup, text: string): Promise<void> {
		const runtime = await this.getOrOpen(ref);
		await runtime.shell(text);
		this.publishStatus(runtime);
	}

	runCommand(ref: SessionRouteLookup, text: string): Promise<CommandResult> {
		return this.getOrOpen(ref).then((runtime) => runtime.runCommand(text));
	}

	async respondToCommand(
		ref: SessionRouteLookup,
		requestId: string,
		value: string,
	): Promise<CommandResult> {
		await (await this.getOrOpen(ref)).respondToExtension(requestId, value);
		return { type: "done" };
	}

	async navigateTree(
		ref: SessionRouteLookup,
		request: SessionTreeNavigateRequest,
	): Promise<SessionTreeNavigateResult> {
		const runtime = await this.getOrOpen(ref);
		const result = await runtime.branch(request.targetId);
		this.rekeyRuntime(runtime);
		return {
			cancelled: false,
			...(result.type === "done" && result.promptDraft !== undefined
				? { editorText: result.promptDraft }
				: {}),
		};
	}

	async abort(ref: SessionRouteLookup): Promise<void> {
		const runtime = await this.getOrOpen(ref);
		await runtime.abort();
		this.publishStatus(runtime);
	}

	async stop(ref: SessionRouteLookup): Promise<void> {
		const runtime = await this.getOrOpen(ref);
		await runtime.close();
		this.active.delete(runtime.identity.sessionId);
		this.options.workspaceActivity?.removeSession(
			runtime.identity.sessionId,
			runtime.identity.cwd,
		);
	}

	archive(): Promise<void> {
		return Promise.reject(new Error("OMP session archiving is not configured"));
	}

	archiveTree(): Promise<ArchiveSessionsResponse> {
		return Promise.reject(
			new Error("OMP session tree archiving is not configured"),
		);
	}

	restore(): Promise<void> {
		return Promise.reject(new Error("OMP session restore is not configured"));
	}

	deleteArchived(): Promise<void> {
		return Promise.reject(
			new Error("OMP archived-session deletion is not configured"),
		);
	}

	async reload(ref: SessionRouteLookup): Promise<void> {
		const runtime = await this.getOrOpen(ref);
		const identity = runtime.identity;
		await runtime.close();
		this.active.delete(identity.sessionId);
		const reopened = await this.openRuntime(identity);
		this.active.set(reopened.identity.sessionId, reopened);
		this.publishStatus(reopened);
	}

	detachParent(): Promise<void> {
		return Promise.reject(
			new Error("OMP sessions do not expose Pi parent links"),
		);
	}

	async dispose(): Promise<void> {
		const active = [...new Set(this.active.values())];
		this.active.clear();
		this.opening.clear();
		await Promise.allSettled(active.map((runtime) => runtime.close()));
	}

	private async createRuntime(
		cwd: string,
		sessionFile?: string,
	): Promise<OmpSessionRuntime> {
		const eventTarget: { sessionId?: string; runtime?: OmpSessionRuntime } = {};
		const runtime = await OmpSessionRuntime.start({
			command: await this.commandPath(),
			agentDir: this.options.agentDir,
			cwd,
			sessionDir: this.sessionDir,
			...(sessionFile === undefined ? {} : { sessionFile }),
			...(this.options.env === undefined ? {} : { env: this.options.env }),
			...(this.options.runtimeClientOptions === undefined
				? {}
				: { clientOptions: this.options.runtimeClientOptions }),
			onEvent: (event) => {
				if (eventTarget.sessionId !== undefined)
					this.events.publish(eventTarget.sessionId, event);
				if (eventTarget.runtime !== undefined)
					this.publishStatus(eventTarget.runtime);
			},
			onError: (error) => {
				const failedRuntime = eventTarget.runtime;
				const sessionId = eventTarget.sessionId;
				if (failedRuntime === undefined || sessionId === undefined) return;
				this.events.publish(sessionId, {
					type: "session.error",
					message: error.message,
				});
				if (this.active.get(sessionId) === failedRuntime)
					this.active.delete(sessionId);
				this.options.workspaceActivity?.removeSession(
					sessionId,
					failedRuntime.identity.cwd,
				);
			},
		});
		eventTarget.sessionId = runtime.identity.sessionId;
		eventTarget.runtime = runtime;
		return runtime;
	}

	private async openRuntime(
		identity: OmpRuntimeIdentity,
	): Promise<OmpSessionRuntime> {
		if (identity.sessionFile === undefined)
			throw new Error(
				"OMP session has not been persisted and cannot be reopened",
			);
		return this.createRuntime(identity.cwd, identity.sessionFile);
	}

	private async getOrOpen(ref: SessionRouteLookup): Promise<OmpSessionRuntime> {
		const id = idFromLookup(ref);
		const active = this.active.get(id);
		if (active !== undefined) return active;
		const pending = this.opening.get(id);
		if (pending !== undefined) return pending;
		const cwd = cwdFromLookup(ref);
		if (cwd === undefined)
			throw new Error("cwd is required to open an OMP session");
		const opening = this.openStoredRuntime(id, cwd);
		this.opening.set(id, opening);
		try {
			return await opening;
		} finally {
			this.opening.delete(id);
		}
	}

	private async openStoredRuntime(
		id: string,
		cwd: string,
	): Promise<OmpSessionRuntime> {
		const stored = (await listOmpSessionFiles(this.sessionDir, cwd)).find(
			(session) => session.id === id,
		);
		if (stored === undefined) throw new Error(`OMP session not found: ${id}`);
		const runtime = await this.createRuntime(cwd, stored.path);
		this.active.set(runtime.identity.sessionId, runtime);
		this.publishStatus(runtime);
		return runtime;
	}

	private rekeyRuntime(runtime: OmpSessionRuntime): void {
		for (const [id, candidate] of this.active) {
			if (candidate === runtime && id !== runtime.identity.sessionId)
				this.active.delete(id);
		}
		this.active.set(runtime.identity.sessionId, runtime);
	}

	private publishStatus(runtime: OmpSessionRuntime): SessionStatus {
		const status = runtime.status();
		this.events.publish(status.sessionId, { type: "status.update", status });
		this.events.publishGlobal({ type: "status.update", status });
		this.options.workspaceActivity?.applySessionStatus(
			runtime.identity.cwd,
			status,
		);
		return status;
	}

	private async probe(): Promise<
		{ available: true } | { available: false; error: string }
	> {
		const command = await resolveOmpExecutable(this.command, {
			env: this.options.env ?? process.env,
		});
		if (command === undefined)
			return {
				available: false,
				error: `OMP executable not found: ${this.command} is not on the service PATH or in well-known install locations`,
			};
		this.resolvedCommand = command;
		try {
			const result = await execFileAsync(command, ["--version"], {
				env: this.options.env ?? process.env,
				timeout: 5_000,
			});
			this.version = firstVersion(result.stdout);
			return { available: true };
		} catch (error) {
			return {
				available: false,
				error: error instanceof Error ? error.message : String(error),
			};
		}
	}

	/**
	 * Resolved executable path. Successful resolutions are cached; failures
	 * are retried so installing OMP does not require a daemon restart.
	 */
	private async commandPath(): Promise<string> {
		if (this.resolvedCommand !== undefined) return this.resolvedCommand;
		const resolved = await resolveOmpExecutable(this.command, {
			env: this.options.env ?? process.env,
		});
		if (resolved === undefined) return this.command;
		this.resolvedCommand = resolved;
		return resolved;
	}
}

function idFromLookup(ref: SessionRouteLookup): string {
	return typeof ref === "string" ? ref : ref.id;
}

function cwdFromLookup(ref: SessionRouteLookup): string | undefined {
	return typeof ref === "string" ? undefined : ref.cwd;
}

function emptyNotificationInbox(
	daemonInstanceId: string,
	ref: SessionRouteRef,
): SessionNotificationInboxSnapshot {
	return {
		daemonInstanceId,
		catalogRevision: 0,
		summary: {
			sessionId: ref.id,
			cwd: ref.cwd,
			inboxRevision: 0,
			retainedCount: 0,
			discardedCount: 0,
		},
		notifications: [],
		dismissThrough: { order: 0, overflowWatermark: 0 },
	};
}

function emptyCleanupPreview(): SessionCleanupPreviewResponse {
	return {
		generatedAt: new Date().toISOString(),
		thresholds: {},
		projects: [],
		totals: { archiveCount: 0, deleteCount: 0 },
	};
}

function firstVersion(value: string): string | undefined {
	const match = /\d+\.\d+\.\d+/u.exec(value);
	return match?.[0];
}
