import { access } from "node:fs/promises";
import { join } from "node:path";
import { AGENT_RUNTIME_IDS } from "../../../shared/agentRuntime.js";
import type {
	CommandResult,
	MessagePage,
	PromptAttachment,
	SessionInfo,
	SessionModel,
	SessionStatus,
	SessionStreamSnapshot,
	SessionUiEvent,
	SlashCommand,
} from "../../../shared/apiTypes.js";
import { KNOWN_THINKING_LEVELS } from "../../../shared/thinkingLevels.js";
import { attachmentsToInlineImages } from "../../sessions/attachmentService.js";
import { pageMessagesAtSafeBoundary } from "../../sessions/messagePaging.js";
import { OmpRpcClient, type OmpRpcClientOptions } from "./ompRpcClient.js";
import type { OmpRpcFrame } from "./ompRpcProtocol.js";

export interface OmpSessionRuntimeOptions {
	command: string;
	agentDir: string;
	cwd: string;
	sessionFile?: string;
	sessionDir?: string;
	env?: NodeJS.ProcessEnv;
	clientOptions?: Pick<
		OmpRpcClientOptions,
		"spawnProcess" | "commandTimeoutMs" | "startTimeoutMs" | "closeTimeoutMs"
	>;
	onEvent?: (event: SessionUiEvent) => void;
	onError?: (error: Error) => void;
	onIdentity?: (identity: OmpRuntimeIdentity) => void;
}

export interface OmpRuntimeIdentity {
	sessionId: string;
	sessionFile?: string;
	sessionName?: string;
	cwd: string;
}

interface OmpState {
	sessionId: string;
	sessionFile?: string;
	sessionName?: string;
	model?: SessionModel;
	thinkingLevel?: string;
	isStreaming: boolean;
	isCompacting: boolean;
	queuedMessageCount: number;
	messageCount: number;
	contextUsage?: SessionStatus["contextUsage"];
}

interface OmpStats {
	tokens: SessionStatus["tokens"];
	cost: number;
}

const OMP_THINKING_LEVELS = [...KNOWN_THINKING_LEVELS, "auto"];

export class OmpSessionRuntime {
	private state: OmpState;
	private stats: OmpStats = { tokens: emptyTokens(), cost: 0 };
	private partial: unknown = null;
	private isBashRunning = false;
	private sessionFilePersisted = false;
	private unsubscribe: (() => void) | undefined;
	private unsubscribeFailure: (() => void) | undefined;

	private constructor(
		readonly client: OmpRpcClient,
		private readonly options: OmpSessionRuntimeOptions,
		state: OmpState,
		sessionFilePersisted: boolean,
	) {
		this.state = state;
		this.sessionFilePersisted = sessionFilePersisted;
		this.unsubscribe = client.subscribe((frame) => {
			this.handleFrame(frame);
		});
		this.unsubscribeFailure = client.subscribeFailure((error) => {
			this.options.onError?.(error);
		});
	}

	static async start(
		options: OmpSessionRuntimeOptions,
	): Promise<OmpSessionRuntime> {
		const args = ["--mode", "rpc-ui"];
		if (options.sessionFile === undefined) args.push("--cwd", options.cwd);
		else args.push("--resume", options.sessionFile);
		if (options.sessionDir !== undefined)
			args.push("--session-dir", options.sessionDir);
		const env = {
			...(options.env ?? process.env),
			PI_CODING_AGENT_DIR: options.agentDir,
		};
		const client = await OmpRpcClient.connect({
			command: options.command,
			cwd: options.cwd,
			args,
			env,
			...options.clientOptions,
		});
		try {
			const state = parseState((await client.request("get_state")).data);
			const runtime = new OmpSessionRuntime(
				client,
				options,
				state,
				await fileExists(state.sessionFile),
			);
			await runtime.refreshStats();
			runtime.publishIdentity();
			return runtime;
		} catch (error) {
			await client.close().catch(() => undefined);
			throw error;
		}
	}

	get identity(): OmpRuntimeIdentity {
		return {
			sessionId: this.state.sessionId,
			...(this.state.sessionFile === undefined
				? {}
				: { sessionFile: this.state.sessionFile }),
			...(this.state.sessionName === undefined
				? {}
				: { sessionName: this.state.sessionName }),
			cwd: this.options.cwd,
		};
	}

	async refresh(): Promise<void> {
		const [stateResponse] = await Promise.all([
			this.client.request("get_state"),
			this.refreshStats(),
		]);
		const previousId = this.state.sessionId;
		const previousFile = this.state.sessionFile;
		this.state = parseState(stateResponse.data);
		this.sessionFilePersisted = await fileExists(this.state.sessionFile);
		if (
			this.state.sessionId !== previousId ||
			this.state.sessionFile !== previousFile
		)
			this.publishIdentity();
	}

	sessionInfo(now = new Date()): SessionInfo {
		const timestamp = now.toISOString();
		return {
			id: this.state.sessionId,
			path: this.state.sessionFile ?? `omp://session/${this.state.sessionId}`,
			cwd: this.options.cwd,
			runtimeId: AGENT_RUNTIME_IDS.omp,
			persisted: this.sessionFilePersisted,
			...(this.state.sessionName === undefined
				? {}
				: { name: this.state.sessionName }),
			created: timestamp,
			modified: timestamp,
			messageCount: this.state.messageCount,
			firstMessage: "",
		};
	}

	status(): SessionStatus {
		return {
			sessionId: this.state.sessionId,
			runtimeId: AGENT_RUNTIME_IDS.omp,
			persisted: this.sessionFilePersisted,
			...(this.state.model === undefined ? {} : { model: this.state.model }),
			...(this.state.thinkingLevel === undefined
				? {}
				: { thinkingLevel: this.state.thinkingLevel }),
			isStreaming: this.state.isStreaming,
			isCompacting: this.state.isCompacting,
			isBashRunning: this.isBashRunning,
			pendingMessageCount: this.state.queuedMessageCount,
			queuedMessages: [],
			messageCount: this.state.messageCount,
			tokens: this.stats.tokens,
			cost: this.stats.cost,
			...(this.state.contextUsage === undefined
				? {}
				: { contextUsage: this.state.contextUsage }),
		};
	}

	streamSnapshot(seq: number): SessionStreamSnapshot {
		return { seq, partial: this.partial };
	}

	async messages(page?: {
		before?: number;
		limit?: number;
	}): Promise<MessagePage> {
		const response = await this.client.request("get_messages");
		const data = requireRecord(response.data, "OMP get_messages response");
		const messages = data["messages"];
		if (!Array.isArray(messages))
			throw new Error("OMP get_messages response did not contain messages");
		const paged = pageMessagesAtSafeBoundary(messages, page);
		return Array.isArray(paged)
			? { messages: paged, start: 0, total: paged.length }
			: paged;
	}

	async availableModels(): Promise<SessionModel[]> {
		const response = await this.client.request("get_available_models");
		const data = requireRecord(
			response.data,
			"OMP get_available_models response",
		);
		const models = data["models"];
		if (!Array.isArray(models))
			throw new Error(
				"OMP get_available_models response did not contain models",
			);
		return models
			.map(parseModel)
			.filter((model): model is SessionModel => model !== undefined);
	}

	async setModel(provider: string, modelId: string): Promise<void> {
		await this.client.request("set_model", { provider, modelId });
		await this.refresh();
	}

	async cycleModel(direction: "forward" | "backward"): Promise<void> {
		if (direction === "forward") {
			await this.client.request("cycle_model");
			await this.refresh();
			return;
		}
		const models = await this.availableModels();
		const currentIndex = models.findIndex(
			(model) =>
				model.provider === this.state.model?.provider &&
				model.id === this.state.model?.id,
		);
		const previous =
			models[(currentIndex <= 0 ? models.length : currentIndex) - 1];
		if (previous?.provider === undefined || previous.id === undefined)
			throw new Error("OMP has no previous model to select");
		await this.setModel(previous.provider, previous.id);
	}

	thinkingLevels(): string[] {
		return [...OMP_THINKING_LEVELS];
	}

	async setThinkingLevel(level: string): Promise<void> {
		if (!OMP_THINKING_LEVELS.includes(level))
			throw new Error(
				`OMP does not support thinking level ${JSON.stringify(level)}`,
			);
		await this.client.request("set_thinking_level", { level });
		await this.refresh();
	}

	async cycleThinkingLevel(): Promise<void> {
		await this.client.request("cycle_thinking_level");
		await this.refresh();
	}

	async commands(): Promise<SlashCommand[]> {
		const response = await this.client.request("get_available_commands");
		const data = requireRecord(
			response.data,
			"OMP get_available_commands response",
		);
		const commands = data["commands"];
		if (!Array.isArray(commands))
			throw new Error(
				"OMP get_available_commands response did not contain commands",
			);
		return commands
			.map(parseCommand)
			.filter((command): command is SlashCommand => command !== undefined);
	}

	async prompt(
		text: string,
		streamingBehavior?: "steer" | "followUp",
		attachments: PromptAttachment[] = [],
	): Promise<void> {
		const inlineImages = await attachmentsToInlineImages(
			attachments.filter((attachment) => attachment.kind === "image"),
		);
		const images = inlineImages.map((entry) => entry.image);
		await this.client.request("prompt", {
			message: text,
			...(images.length === 0 ? {} : { images }),
			...(streamingBehavior === undefined ? {} : { streamingBehavior }),
		});
		await this.refreshStateOnly();
	}

	async abort(): Promise<void> {
		await this.client.request("abort");
		if (this.isBashRunning)
			await this.client.request("abort_bash").catch(() => undefined);
		await this.refresh();
	}

	async shell(command: string): Promise<void> {
		this.isBashRunning = true;
		this.options.onEvent?.({ type: "shell.start", command });
		try {
			const response = await this.client.request(
				"bash",
				{ command },
				0x7fffffff,
			);
			const data = isRecord(response.data) ? response.data : {};
			this.options.onEvent?.({
				type: "shell.end",
				...optionalStringField(data, "output"),
				...optionalNumberField(data, "exitCode"),
				...(data["cancelled"] === true ? { cancelled: true } : {}),
				...(data["truncated"] === true ? { truncated: true } : {}),
				...(typeof data["fullOutputPath"] === "string"
					? { fullOutputPath: data["fullOutputPath"] }
					: {}),
				isError: typeof data["exitCode"] === "number" && data["exitCode"] !== 0,
			});
		} finally {
			this.isBashRunning = false;
		}
	}

	async runCommand(text: string): Promise<CommandResult> {
		await this.prompt(text);
		return { type: "done" };
	}

	respondToExtension(requestId: string, value: string): Promise<void> {
		return this.client.send({
			type: "extension_ui_response",
			id: requestId,
			value,
		});
	}

	async branch(entryId: string): Promise<CommandResult> {
		const response = await this.client.request("branch", { entryId });
		const data = isRecord(response.data) ? response.data : {};
		if (data["cancelled"] === true)
			return { type: "done", message: "Branch cancelled" };
		await this.refresh();
		return {
			type: "done",
			...(typeof data["text"] === "string"
				? { promptDraft: data["text"] }
				: {}),
		};
	}

	async setSessionName(name: string): Promise<void> {
		await this.client.request("set_session_name", { name });
		await this.refresh();
	}

	async close(): Promise<void> {
		this.unsubscribe?.();
		this.unsubscribe = undefined;
		this.unsubscribeFailure?.();
		this.unsubscribeFailure = undefined;
		await this.client.close();
	}

	private async refreshStateOnly(): Promise<void> {
		this.state = parseState((await this.client.request("get_state")).data);
		this.sessionFilePersisted = await fileExists(this.state.sessionFile);
		this.publishIdentity();
	}

	private async refreshStats(): Promise<void> {
		const response = await this.client.request("get_session_stats");
		this.stats = parseStats(response.data);
	}

	private publishIdentity(): void {
		this.options.onIdentity?.(this.identity);
	}

	private handleFrame(frame: OmpRpcFrame): void {
		const event = ompFrameToSessionEvent(frame);
		this.reduceFrame(frame);
		if (event !== undefined) this.options.onEvent?.(event);
	}

	private reduceFrame(frame: OmpRpcFrame): void {
		const type = stringValue(frame["type"]);
		if (type === "agent_start") this.state.isStreaming = true;
		if (type === "agent_end") {
			this.state.isStreaming = false;
			this.partial = null;
			void this.refresh().catch(() => undefined);
		}
		if (type === "auto_compaction_start") this.state.isCompacting = true;
		if (type === "auto_compaction_end") this.state.isCompacting = false;
		if (type === "message_start" || type === "message_update") {
			const message = frame["message"];
			if (isRecord(message) && message["role"] === "assistant")
				this.partial = message;
		}
		if (type === "message_end") {
			this.partial = null;
			this.state.messageCount += 1;
		}
		if (
			type === "thinking_level_changed" &&
			typeof frame["thinkingLevel"] === "string"
		)
			this.state.thinkingLevel = frame["thinkingLevel"];
	}
}

export function ompFrameToSessionEvent(
	frame: OmpRpcFrame,
): SessionUiEvent | undefined {
	const type = stringValue(frame["type"]) ?? "unknown";
	const assistantEvent = frame["assistantMessageEvent"];
	if (type === "message_update" && isRecord(assistantEvent)) {
		if (assistantEvent["type"] === "text_delta")
			return {
				type: "assistant.delta",
				text: stringValue(assistantEvent["delta"]) ?? "",
			};
		if (assistantEvent["type"] === "thinking_delta")
			return {
				type: "assistant.thinking.delta",
				text: stringValue(assistantEvent["delta"]) ?? "",
			};
	}
	if (type === "tool_execution_start") {
		return {
			type: "tool.start",
			toolName: stringValue(frame["toolName"]) ?? "",
			toolCallId: stringValue(frame["toolCallId"]) ?? "",
			summary: summarizeArgs(frame["args"]),
			...(frame["args"] === undefined ? {} : { args: frame["args"] }),
		};
	}
	if (type === "tool_execution_update") {
		return toolUpdateEvent(frame, frame["partialResult"]);
	}
	if (type === "tool_execution_end") {
		return toolEndEvent(frame, frame["result"]);
	}
	if (type === "agent_start") return { type: "agent.start" };
	if (type === "agent_end") return { type: "agent.end" };
	if (type === "message_end")
		return frame["message"] === undefined
			? { type: "message.end" }
			: { type: "message.end", message: frame["message"] };
	if (type === "notice") {
		return {
			type: "command.output",
			level: noticeLevel(frame["level"]),
			message: stringValue(frame["message"]) ?? "OMP notice",
		};
	}
	if (type === "ready" || type === "response" || type === "prompt_result")
		return undefined;
	return {
		type: "runtime.event",
		runtimeId: AGENT_RUNTIME_IDS.omp,
		eventType: type,
		event: frame,
	};
}

function toolUpdateEvent(
	frame: OmpRpcFrame,
	result: unknown,
): Extract<SessionUiEvent, { type: "tool.update" }> {
	return {
		type: "tool.update",
		...toolResultFields(frame, result),
	};
}

function toolEndEvent(
	frame: OmpRpcFrame,
	result: unknown,
): Extract<SessionUiEvent, { type: "tool.end" }> {
	return {
		type: "tool.end",
		...toolResultFields(frame, result),
		isError: frame["isError"] === true,
	};
}

function toolResultFields(frame: OmpRpcFrame, result: unknown) {
	return {
		toolName: stringValue(frame["toolName"]) ?? "",
		toolCallId: stringValue(frame["toolCallId"]) ?? "",
		text: stringifyResult(result),
		...(isRecord(result) && result["content"] !== undefined
			? { content: result["content"] }
			: {}),
		...(isRecord(result) && result["details"] !== undefined
			? { details: result["details"] }
			: {}),
	};
}

function parseState(value: unknown): OmpState {
	const state = requireRecord(value, "OMP get_state response");
	const sessionId = stringValue(state["sessionId"]);
	if (sessionId === undefined || sessionId === "")
		throw new Error("OMP get_state response did not contain a session id");
	const model = parseModel(state["model"]);
	const sessionFile = stringValue(state["sessionFile"]);
	const sessionName = stringValue(state["sessionName"]);
	const thinkingLevel = stringValue(state["thinkingLevel"]);
	return {
		sessionId,
		...(sessionFile === undefined ? {} : { sessionFile }),
		...(sessionName === undefined ? {} : { sessionName }),
		...(model === undefined ? {} : { model }),
		...(thinkingLevel === undefined ? {} : { thinkingLevel }),
		isStreaming: state["isStreaming"] === true,
		isCompacting: state["isCompacting"] === true,
		queuedMessageCount: nonNegativeNumber(state["queuedMessageCount"]),
		messageCount: nonNegativeNumber(state["messageCount"]),
		...parseContextUsage(state["contextUsage"]),
	};
}

function parseStats(value: unknown): OmpStats {
	if (!isRecord(value)) return { tokens: emptyTokens(), cost: 0 };
	const tokens = isRecord(value["tokens"]) ? value["tokens"] : {};
	return {
		tokens: {
			input: nonNegativeNumber(tokens["input"]),
			output: nonNegativeNumber(tokens["output"]),
			cacheRead: nonNegativeNumber(tokens["cacheRead"]),
			cacheWrite: nonNegativeNumber(tokens["cacheWrite"]),
			total: nonNegativeNumber(tokens["total"]),
		},
		cost: nonNegativeNumber(value["cost"]),
	};
}

function parseModel(value: unknown): SessionModel | undefined {
	if (!isRecord(value)) return undefined;
	const id = stringValue(value["id"]);
	const provider = stringValue(value["provider"]);
	if (id === undefined && provider === undefined) return undefined;
	const name = stringValue(value["name"]);
	return {
		...(provider === undefined ? {} : { provider }),
		...(id === undefined ? {} : { id }),
		...(name === undefined ? {} : { name }),
		...(typeof value["contextWindow"] === "number"
			? { contextWindow: value["contextWindow"] }
			: {}),
		...(value["reasoning"] === undefined
			? {}
			: { reasoning: value["reasoning"] }),
	};
}

function parseCommand(value: unknown): SlashCommand | undefined {
	if (!isRecord(value) || typeof value["name"] !== "string") return undefined;
	const source = value["source"];
	const description = stringValue(value["description"]);
	return {
		name: value["name"],
		...(description === undefined ? {} : { description }),
		source:
			source === "extension" ||
			source === "prompt" ||
			source === "skill" ||
			source === "builtin"
				? source
				: "builtin",
	};
}

function parseContextUsage(
	value: unknown,
): Pick<OmpState, "contextUsage"> | object {
	if (!isRecord(value)) return {};
	const contextWindow =
		typeof value["contextWindow"] === "number"
			? value["contextWindow"]
			: undefined;
	if (contextWindow === undefined) return {};
	const tokens = typeof value["tokens"] === "number" ? value["tokens"] : null;
	const percent =
		typeof value["percent"] === "number" ? value["percent"] : null;
	return { contextUsage: { tokens, contextWindow, percent } };
}

function emptyTokens(): SessionStatus["tokens"] {
	return { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 };
}

function summarizeArgs(value: unknown): string {
	if (!isRecord(value)) return "";
	return Object.entries(value)
		.slice(0, 3)
		.map(([key, item]) => `${key}: ${shortValue(item)}`)
		.join(", ");
}

function shortValue(value: unknown): string {
	if (typeof value === "string")
		return value.length > 80 ? `${value.slice(0, 77)}...` : value;
	if (typeof value === "number" || typeof value === "boolean")
		return String(value);
	return Array.isArray(value)
		? `[${String(value.length)} items]`
		: isRecord(value)
			? "{...}"
			: "";
}

function stringifyResult(value: unknown): string {
	if (typeof value === "string") return value;
	if (isRecord(value) && typeof value["content"] === "string")
		return value["content"];
	try {
		return JSON.stringify(value);
	} catch {
		return String(value);
	}
}

function noticeLevel(value: unknown): "info" | "success" | "error" {
	return value === "error" ? "error" : value === "success" ? "success" : "info";
}

function requireRecord(value: unknown, label: string): Record<string, unknown> {
	if (!isRecord(value)) throw new Error(`${label} must be an object`);
	return value;
}

function optionalStringField(
	record: Record<string, unknown>,
	key: string,
): { output?: string } {
	return typeof record[key] === "string" ? { output: record[key] } : {};
}

function optionalNumberField(
	record: Record<string, unknown>,
	key: string,
): { exitCode?: number } {
	return typeof record[key] === "number" ? { exitCode: record[key] } : {};
}

function nonNegativeNumber(value: unknown): number {
	return typeof value === "number" && Number.isFinite(value) && value >= 0
		? value
		: 0;
}

function stringValue(value: unknown): string | undefined {
	return typeof value === "string" ? value : undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

async function fileExists(path: string | undefined): Promise<boolean> {
	if (path === undefined) return false;
	try {
		await access(path);
		return true;
	} catch {
		return false;
	}
}

export function defaultOmpSessionDir(agentDir: string): string {
	return join(agentDir, "sessions");
}
