import {
	AGENT_RUNTIME_IDS,
	type AgentRuntimeId,
} from "../../shared/agentRuntime.js";
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
	SessionNotificationDismissAllRequest,
	SessionNotificationDismissRequest,
	SessionNotificationInboxSnapshot,
	SessionStatus,
	SessionStreamSnapshot,
	SessionTreeNavigateRequest,
	SessionTreeNavigateResult,
	SessionUnreadAcknowledgeRequest,
	SessionUnreadCatalogSnapshot,
	SlashCommand,
} from "../../shared/apiTypes.js";
import type { AuthChange } from "../sessions/authService.js";
import type { ActiveSessionAbortResult } from "../sessions/activeSessionAbort.js";
import type { NormalizedSessionCleanupRequest } from "../sessions/sessionCleanup.js";
import type {
	ExtensionInteraction,
	ExtensionInteractionResponse,
} from "../sessions/extensionInteractionService.js";
import type {
	SessionForkCandidate,
	SessionForkResult,
	SessionImportResult,
	SessionRouteLookup,
	SessionRouteRef,
	SessionRouteService,
} from "../sessions/sessionService.js";

export interface ManagedSessionRouteService extends SessionRouteService {
	activeCount(): number;
	abortActiveWork(): Promise<ActiveSessionAbortResult>;
	dispose(): void | Promise<void>;
}

export interface PiRuntimeRouteService extends ManagedSessionRouteService {
	applyAuthChange(change: AuthChange): void;
}

export class MultiRuntimeSessionService implements SessionRouteService {
	constructor(
		private readonly pi: PiRuntimeRouteService,
		private readonly omp: ManagedSessionRouteService,
		private readonly defaultRuntimeId: AgentRuntimeId = AGENT_RUNTIME_IDS.pi,
	) {}

	activeCount(): number {
		return this.pi.activeCount() + this.omp.activeCount();
	}

	async abortActiveWork(): Promise<ActiveSessionAbortResult> {
		const [pi, omp] = await Promise.all([
			this.pi.abortActiveWork(),
			this.omp.abortActiveWork(),
		]);
		return {
			requested: pi.requested + omp.requested,
			aborted: [...pi.aborted, ...omp.aborted],
			failures: [...pi.failures, ...omp.failures],
		};
	}

	applyAuthChange(change: AuthChange = {}): void {
		this.pi.applyAuthChange(change);
	}

	async runtimes(): Promise<AgentRuntimesResponse> {
		const pi = await this.pi.runtimes();
		const omp = await this.omp.runtimes();
		return {
			defaultRuntimeId: this.defaultRuntimeId,
			runtimes: [...pi.runtimes, ...omp.runtimes],
		};
	}

	async list(cwd: string): Promise<SessionInfo[]> {
		const [pi, omp] = await Promise.all([
			this.pi.list(cwd),
			this.omp.list(cwd),
		]);
		return [...pi, ...omp].sort(
			(left, right) => Date.parse(right.modified) - Date.parse(left.modified),
		);
	}

	start(
		cwd: string,
		options: { runtimeId?: AgentRuntimeId } = {},
	): Promise<SessionInfo> {
		const runtimeId = options.runtimeId ?? this.defaultRuntimeId;
		return this.serviceForRuntime(runtimeId).start(cwd, { runtimeId });
	}

	messages(
		ref: SessionRouteLookup,
		page?: { before?: number; limit?: number },
	): Promise<unknown[] | MessagePage> {
		return this.serviceForLookup(ref).messages(ref, page);
	}

	status(ref: SessionRouteLookup): Promise<SessionStatus> {
		return this.serviceForLookup(ref).status(ref);
	}

	streamSnapshot(ref: SessionRouteLookup): Promise<SessionStreamSnapshot> {
		return this.serviceForLookup(ref).streamSnapshot(ref);
	}

	notificationCatalog():
		| SessionNotificationCatalogSnapshot
		| Promise<SessionNotificationCatalogSnapshot> {
		return this.pi.notificationCatalog();
	}

	unreadCatalog(): Promise<SessionUnreadCatalogSnapshot> {
		return this.pi.unreadCatalog();
	}

	acknowledgeUnread(
		sessionId: string,
		request: SessionUnreadAcknowledgeRequest,
	): Promise<SessionUnreadCatalogSnapshot> {
		return this.pi.acknowledgeUnread(sessionId, request);
	}

	notificationInbox(
		ref: SessionRouteRef,
	):
		| SessionNotificationInboxSnapshot
		| Promise<SessionNotificationInboxSnapshot> {
		return this.serviceForLookup(ref).notificationInbox(ref);
	}

	dismissNotification(
		ref: SessionRouteRef,
		request: Omit<SessionNotificationDismissRequest, "cwd">,
	):
		| SessionNotificationInboxSnapshot
		| Promise<SessionNotificationInboxSnapshot> {
		return this.serviceForLookup(ref).dismissNotification(ref, request);
	}

	dismissAllNotifications(
		ref: SessionRouteRef,
		request: Omit<SessionNotificationDismissAllRequest, "cwd">,
	):
		| SessionNotificationInboxSnapshot
		| Promise<SessionNotificationInboxSnapshot> {
		return this.serviceForLookup(ref).dismissAllNotifications(ref, request);
	}

	clearQueue(ref: SessionRouteLookup): Promise<SessionStatus> {
		return this.serviceForLookup(ref).clearQueue(ref);
	}

	dismissWarning(
		ref: SessionRouteLookup,
		dismissId: string,
	): Promise<SessionStatus> {
		return this.serviceForLookup(ref).dismissWarning(ref, dismissId);
	}

	availableModels(ref: SessionRouteLookup): Promise<SessionModel[]> {
		return this.serviceForLookup(ref).availableModels(ref);
	}

	setModel(
		ref: SessionRouteLookup,
		provider: string,
		modelId: string,
	): Promise<SessionStatus> {
		return this.serviceForLookup(ref).setModel(ref, provider, modelId);
	}

	cycleModel(
		ref: SessionRouteLookup,
		direction: "forward" | "backward",
	): Promise<SessionStatus> {
		return this.serviceForLookup(ref).cycleModel(ref, direction);
	}

	availableThinkingLevels(ref: SessionRouteLookup): Promise<string[]> {
		return this.serviceForLookup(ref).availableThinkingLevels(ref);
	}

	setThinkingLevel(
		ref: SessionRouteLookup,
		level: string,
	): Promise<SessionStatus> {
		return this.serviceForLookup(ref).setThinkingLevel(ref, level);
	}

	cycleThinkingLevel(ref: SessionRouteLookup): Promise<SessionStatus> {
		return this.serviceForLookup(ref).cycleThinkingLevel(ref);
	}

	commands(ref: SessionRouteLookup): Promise<SlashCommand[]> {
		return this.serviceForLookup(ref).commands(ref);
	}

	prompt(
		ref: SessionRouteLookup,
		text: unknown,
		streamingBehavior?: unknown,
		attachments?: unknown,
	): Promise<void> {
		return this.serviceForLookup(ref).prompt(
			ref,
			text,
			streamingBehavior,
			attachments,
		);
	}

	saveAttachments(
		ref: SessionRouteLookup,
		attachments: unknown,
		folder?: string,
	): Promise<SavedPromptAttachment[]> {
		return this.serviceForLookup(ref).saveAttachments(ref, attachments, folder);
	}

	cleanupPreview(
		request: NormalizedSessionCleanupRequest,
	): Promise<SessionCleanupPreviewResponse> {
		return this.pi.cleanupPreview(request);
	}

	cleanup(
		request: NormalizedSessionCleanupRequest,
	): Promise<SessionCleanupExecuteResponse> {
		return this.pi.cleanup(request);
	}

	async archiveMany(
		refs: readonly SessionBulkMutationRef[],
	): Promise<SessionBulkArchiveResponse> {
		const [piRefs, ompRefs] = partitionRefs(refs);
		const [pi, omp] = await Promise.all([
			this.pi.archiveMany(piRefs),
			this.omp.archiveMany(ompRefs),
		]);
		return {
			archived: true,
			archivedSessionIds: [...pi.archivedSessionIds, ...omp.archivedSessionIds],
			failures: [...pi.failures, ...omp.failures],
			generatedAt: latestTimestamp(pi.generatedAt, omp.generatedAt),
		};
	}

	async deleteArchivedMany(
		refs: readonly SessionBulkMutationRef[],
	): Promise<SessionBulkDeleteArchivedResponse> {
		const [piRefs, ompRefs] = partitionRefs(refs);
		const [pi, omp] = await Promise.all([
			this.pi.deleteArchivedMany(piRefs),
			this.omp.deleteArchivedMany(ompRefs),
		]);
		return {
			deleted: true,
			deletedSessionIds: [...pi.deletedSessionIds, ...omp.deletedSessionIds],
			failures: [...pi.failures, ...omp.failures],
			generatedAt: latestTimestamp(pi.generatedAt, omp.generatedAt),
		};
	}

	shell(ref: SessionRouteLookup, text: string): Promise<void> {
		return this.serviceForLookup(ref).shell(ref, text);
	}

	runCommand(ref: SessionRouteLookup, text: string): Promise<CommandResult> {
		return this.serviceForLookup(ref).runCommand(ref, text);
	}

	respondToCommand(
		ref: SessionRouteLookup,
		requestId: string,
		value: string,
	): Promise<CommandResult> {
		return this.serviceForLookup(ref).respondToCommand(ref, requestId, value);
	}

	listExtensionInteractions(
		ref: SessionRouteLookup,
	): Promise<ExtensionInteraction[]> {
		return this.serviceForLookup(ref).listExtensionInteractions(ref);
	}

	respondToExtensionInteraction(
		ref: SessionRouteLookup,
		interactionId: string,
		response: ExtensionInteractionResponse,
	): Promise<ExtensionInteraction> {
		return this.serviceForLookup(ref).respondToExtensionInteraction(
			ref,
			interactionId,
			response,
		);
	}

	forkCandidates(ref: SessionRouteLookup): Promise<SessionForkCandidate[]> {
		return this.serviceForLookup(ref).forkCandidates(ref);
	}

	fork(ref: SessionRouteLookup, entryId: string): Promise<SessionForkResult> {
		return this.serviceForLookup(ref).fork(ref, entryId);
	}

	importSession(
		ref: SessionRouteLookup,
		inputPath: string,
	): Promise<SessionImportResult> {
		return this.serviceForLookup(ref).importSession(ref, inputPath);
	}

	navigateTree(
		ref: SessionRouteLookup,
		request: SessionTreeNavigateRequest,
	): Promise<SessionTreeNavigateResult> {
		return this.serviceForLookup(ref).navigateTree(ref, request);
	}

	abort(ref: SessionRouteLookup): Promise<void> {
		return this.serviceForLookup(ref).abort(ref);
	}

	stop(ref: SessionRouteLookup): void | Promise<void> {
		return this.serviceForLookup(ref).stop(ref);
	}

	archive(ref: SessionRouteLookup): Promise<void> {
		return this.serviceForLookup(ref).archive(ref);
	}

	archiveTree(ref: SessionRouteLookup): Promise<ArchiveSessionsResponse> {
		return this.serviceForLookup(ref).archiveTree(ref);
	}

	restore(ref: SessionRouteLookup): Promise<void> {
		return this.serviceForLookup(ref).restore(ref);
	}

	deleteArchived(ref: SessionRouteLookup): Promise<void> {
		return this.serviceForLookup(ref).deleteArchived(ref);
	}

	reload(ref: SessionRouteLookup): Promise<void> {
		return this.serviceForLookup(ref).reload(ref);
	}

	detachParent(ref: SessionRouteLookup): Promise<void> {
		return this.serviceForLookup(ref).detachParent(ref);
	}

	async dispose(): Promise<void> {
		await Promise.allSettled([this.pi.dispose(), this.omp.dispose()]);
	}

	private serviceForLookup(ref: SessionRouteLookup): SessionRouteService {
		if (typeof ref !== "string" && ref.runtimeId !== undefined)
			return this.serviceForRuntime(ref.runtimeId);
		return this.serviceForRuntime(this.defaultRuntimeId);
	}

	private serviceForRuntime(runtimeId: AgentRuntimeId): SessionRouteService {
		return runtimeId === AGENT_RUNTIME_IDS.pi ? this.pi : this.omp;
	}
}

function partitionRefs(
	refs: readonly SessionBulkMutationRef[],
): [SessionBulkMutationRef[], SessionBulkMutationRef[]] {
	const pi: SessionBulkMutationRef[] = [];
	const omp: SessionBulkMutationRef[] = [];
	for (const ref of refs)
		(ref.runtimeId === AGENT_RUNTIME_IDS.omp ? omp : pi).push(ref);
	return [pi, omp];
}

function latestTimestamp(left: string, right: string): string {
	return Date.parse(left) >= Date.parse(right) ? left : right;
}
