import { createHash } from "node:crypto";
import type { ActiveSessionAbortResult } from "./sessions/activeSessionAbort.js";
import type { ClientSession } from "./types.js";
import type { TerminalInfo } from "./terminals/terminalService.js";

export const RUNTIME_COMMAND_KINDS = {
	abortActiveWork: "abort-active-work",
	prompt: "prompt",
	startSession: "start-session",
	archiveSession: "archive-session",
	restoreSession: "restore-session",
	deleteArchivedSession: "delete-archived-session",
	forkSession: "fork-session",
	createTerminal: "create-terminal",
	continueTerminal: "continue-terminal",
} as const;

export type RuntimeCommandKind =
	(typeof RUNTIME_COMMAND_KINDS)[keyof typeof RUNTIME_COMMAND_KINDS];

export interface RuntimePromptCommandResult {
	accepted: true;
	sessionId: string;
	runtimeId?: string;
}

export interface RuntimeStartSessionCommandResult {
	created: true;
	sessionId: string;
	cwd: string;
	runtimeId: string;
}

export interface RuntimeArchiveSessionCommandResult {
	archived: true;
	sessionId: string;
	cwd?: string;
	runtimeId?: string;
}

export interface RuntimeRestoreSessionCommandResult {
	restored: true;
	sessionId: string;
	cwd?: string;
	runtimeId?: string;
}

export interface RuntimeDeleteArchivedSessionCommandResult {
	deleted: true;
	sessionId: string;
	cwd?: string;
	runtimeId?: string;
}

export interface RuntimeForkSessionCommandResult {
	forked: true;
	session: ClientSession;
	promptDraft?: string;
}

export interface RuntimeCreateTerminalCommandResult {
	created: true;
	terminal: TerminalInfo;
}

export interface RuntimeContinueTerminalCommandResult {
	continued: true;
	terminal: TerminalInfo;
}

export type RuntimeCommandResult =
	| ActiveSessionAbortResult
	| RuntimePromptCommandResult
	| RuntimeStartSessionCommandResult
	| RuntimeArchiveSessionCommandResult
	| RuntimeRestoreSessionCommandResult
	| RuntimeDeleteArchivedSessionCommandResult
	| RuntimeForkSessionCommandResult
	| RuntimeCreateTerminalCommandResult
	| RuntimeContinueTerminalCommandResult;

export interface RuntimeCommandReceipt {
	commandId: string;
	kind: RuntimeCommandKind;
	runtimeEpoch: string;
	status: "completed" | "failed";
	startedAt: string;
	completedAt: string;
	result?: RuntimeCommandResult;
	error?: string;
}

interface RuntimeCommandRecord {
	kind: RuntimeCommandKind;
	fingerprint: string;
	promise: Promise<RuntimeCommandReceipt>;
}

export interface RuntimeCommandExecution {
	commandId: string;
	kind: RuntimeCommandKind;
	expectedRuntimeEpoch: string;
	/** SHA-256 of the command payload. Never retain raw prompt or attachment data. */
	fingerprint: string;
}

export class RuntimeCommandConflictError extends Error {}

export class RuntimeCommandEpochMismatchError extends Error {}

/**
 * Runtime-epoch-bound command receipts. Retaining the same promise for a
 * command id makes retry after a client timeout safe without persisting agent
 * objects or SDK state outside the Runtime that owns them.
 */
export class RuntimeCommandReceipts {
	private readonly records = new Map<string, RuntimeCommandRecord>();

	constructor(
		private readonly runtimeEpoch: string,
		private readonly now: () => Date = () => new Date(),
	) {}

	execute<Result extends RuntimeCommandResult>(
		command: RuntimeCommandExecution,
		action: () => Promise<Result>,
	): Promise<RuntimeCommandReceipt> {
		if (command.expectedRuntimeEpoch !== this.runtimeEpoch) {
			throw new RuntimeCommandEpochMismatchError(
				`Runtime epoch changed; expected ${command.expectedRuntimeEpoch}, current ${this.runtimeEpoch}`,
			);
		}
		const existing = this.records.get(command.commandId);
		if (existing !== undefined) {
			if (
				existing.kind !== command.kind ||
				existing.fingerprint !== command.fingerprint
			) {
				throw new RuntimeCommandConflictError(
					`commandId ${command.commandId} is already associated with a different Runtime command`,
				);
			}
			return existing.promise;
		}

		const startedAt = this.now().toISOString();
		const promise = action()
			.then((result) => ({
				commandId: command.commandId,
				kind: command.kind,
				runtimeEpoch: this.runtimeEpoch,
				status: "completed" as const,
				startedAt,
				completedAt: this.now().toISOString(),
				result,
			}))
			.catch((error: unknown) => ({
				commandId: command.commandId,
				kind: command.kind,
				runtimeEpoch: this.runtimeEpoch,
				status: "failed" as const,
				startedAt,
				completedAt: this.now().toISOString(),
				error: error instanceof Error ? error.message : String(error),
			}));
		this.records.set(command.commandId, {
			kind: command.kind,
			fingerprint: command.fingerprint,
			promise,
		});
		return promise;
	}

	get(commandId: string): Promise<RuntimeCommandReceipt> | undefined {
		return this.records.get(commandId)?.promise;
	}
}

export function requireRuntimeCommandId(value: unknown): string {
	if (typeof value !== "string") {
		throw new Error("commandId field must be a string");
	}
	const commandId = value.trim();
	if (commandId.length === 0 || commandId.length > 128) {
		throw new Error("commandId must be between 1 and 128 characters");
	}
	return commandId;
}

export function requireRuntimeCommandEpoch(value: unknown): string {
	if (typeof value !== "string") {
		throw new Error("runtimeEpoch field must be a string");
	}
	const runtimeEpoch = value.trim();
	if (runtimeEpoch.length === 0 || runtimeEpoch.length > 128) {
		throw new Error("runtimeEpoch must be between 1 and 128 characters");
	}
	return runtimeEpoch;
}

/**
 * Generates a deterministic payload fingerprint for commandId collision
 * detection without retaining user prompts or attachment data in memory.
 */
export function runtimeCommandFingerprint(value: unknown): string {
	return createHash("sha256").update(canonicalJson(value)).digest("hex");
}

export function runtimeCommandErrorStatus(error: unknown): number | undefined {
	return error instanceof RuntimeCommandConflictError ||
		error instanceof RuntimeCommandEpochMismatchError
		? 409
		: undefined;
}

function canonicalJson(value: unknown): string {
	if (value === null) return "null";
	switch (typeof value) {
		case "string":
			return JSON.stringify(value);
		case "boolean":
			return value ? "true" : "false";
		case "number":
			if (!Number.isFinite(value)) throw new Error("Runtime command payload must be JSON-safe");
			return JSON.stringify(value);
		case "object":
			if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
			if (!isRecord(value)) throw new Error("Runtime command payload must be JSON-safe");
			return `{${Object.keys(value)
				.filter((key) => value[key] !== undefined)
				.sort()
				.map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`)
				.join(",")}}`;
		case "bigint":
		case "function":
		case "symbol":
		case "undefined":
			throw new Error("Runtime command payload must be JSON-safe");
	}
	throw new Error("Runtime command payload must be JSON-safe");
}

function isRecord(value: object): value is Record<string, unknown> {
	return Object.getPrototypeOf(value) === Object.prototype || Object.getPrototypeOf(value) === null;
}
