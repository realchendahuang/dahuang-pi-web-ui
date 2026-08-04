import { createHash, randomUUID } from "node:crypto";
import { chmod, mkdir, readFile, rename, unlink, writeFile } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import type { ActiveSessionAbortResult } from "./sessions/activeSessionAbort.js";
import type { ClientSession } from "./types.js";
import type { TerminalInfo } from "./terminals/terminalService.js";
import type { GitCheckpoint, GitStatusResponse } from "../shared/apiTypes.js";
import type { ExtensionInteraction } from "./sessions/extensionInteractionService.js";
import { piWebDataDir } from "../config.js";

export const RUNTIME_COMMAND_KINDS = {
	abortActiveWork: "abort-active-work",
	prompt: "prompt",
	startSession: "start-session",
	archiveSession: "archive-session",
	restoreSession: "restore-session",
	deleteArchivedSession: "delete-archived-session",
	forkSession: "fork-session",
	importSession: "import-session",
	createTerminal: "create-terminal",
	continueTerminal: "continue-terminal",
	stageGitPaths: "stage-git-paths",
	unstageGitPaths: "unstage-git-paths",
	discardGitPaths: "discard-git-paths",
	commitGit: "commit-git",
	pushGit: "push-git",
	revertGitHead: "revert-git-head",
	createGitCheckpoint: "create-git-checkpoint",
	respondExtensionInteraction: "respond-extension-interaction",
	authorizeProject: "authorize-project",
	writeWorkspaceFile: "write-workspace-file",
	deleteWorkspaceFile: "delete-workspace-file",
	moveWorkspaceFile: "move-workspace-file",
	migrateLegacyAuth: "migrate-legacy-auth",
	rollbackLegacyAuthMigration: "rollback-legacy-auth-migration",
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

export interface RuntimeImportSessionCommandResult {
	imported: true;
	session: ClientSession;
}

export interface RuntimeCreateTerminalCommandResult {
	created: true;
	terminal: TerminalInfo;
}

export interface RuntimeContinueTerminalCommandResult {
	continued: true;
	terminal: TerminalInfo;
}

/** A Git mutation is Runtime-owned; native UI receives only its refreshed status. */
export interface RuntimeGitMutationCommandResult {
	staged?: true;
	unstaged?: true;
	discarded?: true;
	committed?: true;
	reverted?: true;
	paths?: string[];
	hash?: string;
	subject?: string;
	status: GitStatusResponse;
}

export interface RuntimeGitCheckpointCommandResult {
	checkpointed: true;
	checkpoint: GitCheckpoint;
}

/** The Runtime derives the tracking upstream itself; Swift supplies no Git arguments. */
export interface RuntimeGitPushCommandResult {
	pushed: true;
	status: GitStatusResponse;
}

export interface RuntimeExtensionInteractionResponseCommandResult {
	responded: true;
	interaction: ExtensionInteraction;
}

export interface RuntimeAuthorizeProjectCommandResult {
	authorized: true;
	path: string;
}

export interface RuntimeWriteWorkspaceFileCommandResult {
	written: true;
	path: string;
	size: number;
	modifiedAt: string;
	created: boolean;
}

export interface RuntimeDeleteWorkspaceFileCommandResult {
	deletedFile: true;
	path: string;
	existed: boolean;
}

export interface RuntimeMoveWorkspaceFileCommandResult {
	moved: true;
	fromPath: string;
	toPath: string;
	size: number;
	modifiedAt: string;
}

export interface RuntimeLegacyAuthMigrationCommandResult {
	migrated?: true;
	rolledBack?: true;
	migration: import("./sessions/legacyAuthMigration.js").LegacyAuthMigrationRecord;
}

export type RuntimeCommandResult =
	| ActiveSessionAbortResult
	| RuntimePromptCommandResult
	| RuntimeStartSessionCommandResult
	| RuntimeArchiveSessionCommandResult
	| RuntimeRestoreSessionCommandResult
	| RuntimeDeleteArchivedSessionCommandResult
	| RuntimeForkSessionCommandResult
	| RuntimeImportSessionCommandResult
	| RuntimeCreateTerminalCommandResult
	| RuntimeContinueTerminalCommandResult
	| RuntimeGitMutationCommandResult
	| RuntimeGitPushCommandResult
	| RuntimeGitCheckpointCommandResult
	| RuntimeExtensionInteractionResponseCommandResult
	| RuntimeAuthorizeProjectCommandResult
	| RuntimeWriteWorkspaceFileCommandResult
	| RuntimeDeleteWorkspaceFileCommandResult
	| RuntimeMoveWorkspaceFileCommandResult
	| RuntimeLegacyAuthMigrationCommandResult;

export interface RuntimeCommandReceipt {
	commandId: string;
	kind: RuntimeCommandKind;
	runtimeEpoch: string;
	status: "completed" | "failed";
	startedAt: string;
	completedAt: string;
	result?: RuntimeCommandResult;
	error?: string;
	/** A terminal receipt loaded from a private ledger after a newer Runtime epoch began. */
	recoveredAfterRuntimeRestart?: true;
}

interface RuntimeCommandRecord {
	kind: RuntimeCommandKind;
	fingerprint: string;
	promise: Promise<RuntimeCommandReceipt>;
}

type PersistedRuntimeCommandState = "started" | "completed" | "failed";

export interface PersistedRuntimeCommandRecord {
	commandId: string;
	kind: RuntimeCommandKind;
	fingerprint: string;
	runtimeEpoch: string;
	state: PersistedRuntimeCommandState;
	startedAt: string;
	completedAt?: string;
	result?: RuntimeCommandResult;
	error?: string;
}

interface RuntimeCommandReceiptFile {
	schemaVersion: 1;
	records: PersistedRuntimeCommandRecord[];
}

export interface RuntimeCommandReceiptPersistence {
	load(): Promise<PersistedRuntimeCommandRecord[]>;
	save(records: readonly PersistedRuntimeCommandRecord[]): Promise<void>;
}

const RUNTIME_COMMAND_RECEIPT_SCHEMA_VERSION = 1;
const MAX_PERSISTED_RUNTIME_COMMAND_RECEIPTS = 1_000;
const runtimeCommandKindValues: readonly RuntimeCommandKind[] = Object.values(RUNTIME_COMMAND_KINDS);

/** The private Runtime ledger is deliberately separate from user-editable config. */
export function defaultRuntimeCommandReceiptFilePath(
	env: NodeJS.ProcessEnv = process.env,
	cwd = process.cwd(),
): string {
	return join(piWebDataDir(env, cwd), "native-runtime-command-receipts.json");
}

/**
 * Atomic, private persistence for command intent and terminal receipts. It
 * never stores a raw command request payload: it records only the payload
 * fingerprint and the same private result projection returned to the native
 * client. The ledger is private Runtime state, never a shared support export.
 */
export class FileRuntimeCommandReceiptPersistence implements RuntimeCommandReceiptPersistence {
	constructor(private readonly filePath = defaultRuntimeCommandReceiptFilePath()) {}

	async load(): Promise<PersistedRuntimeCommandRecord[]> {
		try {
			return parseRuntimeCommandReceiptFile(JSON.parse(await readFile(this.filePath, "utf8"))).records;
		} catch (error: unknown) {
			if (isNodeErrorWithCode(error, "ENOENT")) return [];
			throw error;
		}
	}

	async save(records: readonly PersistedRuntimeCommandRecord[]): Promise<void> {
		await mkdir(dirname(this.filePath), { recursive: true, mode: 0o700 });
		await chmod(dirname(this.filePath), 0o700);
		const temporaryPath = join(
			dirname(this.filePath),
			`.${basename(this.filePath)}.${String(process.pid)}.${String(Date.now())}.${randomUUID()}.tmp`,
		);
		const data: RuntimeCommandReceiptFile = {
			schemaVersion: RUNTIME_COMMAND_RECEIPT_SCHEMA_VERSION,
			records: [...records],
		};
		try {
			await writeFile(temporaryPath, `${JSON.stringify(data, null, 2)}\n`, { encoding: "utf8", mode: 0o600 });
			await rename(temporaryPath, this.filePath);
			await chmod(this.filePath, 0o600);
		} catch (error: unknown) {
			await unlink(temporaryPath).catch(() => undefined);
			throw error;
		}
	}
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

export class RuntimeCommandInterruptedError extends Error {}

/**
 * Runtime-epoch-bound command receipts. An optional private ledger records an
 * intent before the side effect begins and a terminal receipt after it ends.
 * A Runtime that dies between those writes restores an explicit non-replayable
 * failure instead of guessing whether a Prompt, Git mutation or PTY action ran.
 */
export class RuntimeCommandReceipts {
	private readonly records = new Map<string, RuntimeCommandRecord>();
	private readonly persistedRecords = new Map<string, PersistedRuntimeCommandRecord>();
	private persistenceQueue: Promise<void> = Promise.resolve();

	constructor(
		private readonly runtimeEpoch: string,
		private readonly now: () => Date = () => new Date(),
		private readonly persistence?: RuntimeCommandReceiptPersistence,
	) {}

	static async open(options: {
		runtimeEpoch: string;
		persistence: RuntimeCommandReceiptPersistence;
		now?: () => Date;
	}): Promise<RuntimeCommandReceipts> {
		const receipts = new RuntimeCommandReceipts(options.runtimeEpoch, options.now, options.persistence);
		const loaded = await options.persistence.load();
		let recoveredInterruptedRecord = false;
		for (const record of loaded) {
			receipts.persistedRecords.set(record.commandId, record);
			if (record.state === "started") {
				const recovered: PersistedRuntimeCommandRecord = {
					...record,
					state: "failed",
					completedAt: receipts.now().toISOString(),
					error: "Runtime restarted before this command recorded an outcome. The command was not replayed; refresh the affected session or project before taking another action.",
				};
				receipts.persistedRecords.set(record.commandId, recovered);
				receipts.records.set(record.commandId, {
					kind: recovered.kind,
					fingerprint: recovered.fingerprint,
					promise: Promise.resolve(receiptFromPersistedRecord(recovered, true)),
				});
				recoveredInterruptedRecord = true;
			} else {
				receipts.records.set(record.commandId, {
					kind: record.kind,
					fingerprint: record.fingerprint,
					promise: Promise.resolve(receiptFromPersistedRecord(record, true)),
				});
			}
		}
		if (recoveredInterruptedRecord) await receipts.persist();
		return receipts;
	}

	execute<Result extends RuntimeCommandResult>(
		command: RuntimeCommandExecution,
		action: () => Promise<Result>,
	): Promise<RuntimeCommandReceipt> {
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
		if (command.expectedRuntimeEpoch !== this.runtimeEpoch) {
			throw new RuntimeCommandEpochMismatchError(
				`Runtime epoch changed; expected ${command.expectedRuntimeEpoch}, current ${this.runtimeEpoch}`,
			);
		}

		const startedAt = this.now().toISOString();
		const started: PersistedRuntimeCommandRecord = {
			commandId: command.commandId,
			kind: command.kind,
			fingerprint: command.fingerprint,
			runtimeEpoch: this.runtimeEpoch,
			state: "started",
			startedAt,
		};
		const promise = this.persistBeforeAction(started)
			.then(action)
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
			}))
			.then(async (receipt) => {
				await this.persistTerminalReceipt(command, receipt);
				return receipt;
			});
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

	private async persistBeforeAction(record: PersistedRuntimeCommandRecord): Promise<void> {
		if (this.persistence === undefined) return;
		this.persistedRecords.set(record.commandId, record);
		await this.persist();
	}

	private async persistTerminalReceipt(
		command: RuntimeCommandExecution,
		receipt: RuntimeCommandReceipt,
	): Promise<void> {
		if (this.persistence === undefined) return;
		this.persistedRecords.set(command.commandId, {
			commandId: receipt.commandId,
			kind: receipt.kind,
			fingerprint: command.fingerprint,
			runtimeEpoch: receipt.runtimeEpoch,
			state: receipt.status,
			startedAt: receipt.startedAt,
			completedAt: receipt.completedAt,
			...(receipt.result === undefined ? {} : { result: receipt.result }),
			...(receipt.error === undefined ? {} : { error: receipt.error }),
		});
		await this.persist();
	}

	private async persist(): Promise<void> {
		if (this.persistence === undefined) return;
		const records = [...this.persistedRecords.values()]
			.sort((left, right) => right.startedAt.localeCompare(left.startedAt))
			.slice(0, MAX_PERSISTED_RUNTIME_COMMAND_RECEIPTS);
		this.persistedRecords.clear();
		for (const record of records) this.persistedRecords.set(record.commandId, record);
		const previous = this.persistenceQueue;
		let release = (): void => undefined;
		this.persistenceQueue = new Promise<void>((resolve) => { release = resolve; });
		await previous.catch(() => undefined);
		try {
			await this.persistence.save(records);
		} finally {
			release();
		}
	}
}

export function parseRuntimeCommandReceiptFile(value: unknown): RuntimeCommandReceiptFile {
	if (!isRecord(value) || value["schemaVersion"] !== RUNTIME_COMMAND_RECEIPT_SCHEMA_VERSION || !Array.isArray(value["records"])) {
		throw new Error("Invalid Runtime command receipt file");
	}
	if (value["records"].length > MAX_PERSISTED_RUNTIME_COMMAND_RECEIPTS) throw new Error("Runtime command receipt file exceeds its retention limit");
	return {
		schemaVersion: RUNTIME_COMMAND_RECEIPT_SCHEMA_VERSION,
		records: value["records"].map(parsePersistedRuntimeCommandRecord),
	};
}

function parsePersistedRuntimeCommandRecord(value: unknown): PersistedRuntimeCommandRecord {
	if (!isRecord(value)) throw new Error("Invalid Runtime command receipt record");
	const commandId = requireRuntimeCommandId(value["commandId"]);
	const kind = requiredRuntimeCommandKind(value["kind"]);
	const fingerprint = requiredNonEmptyString(value["fingerprint"], "fingerprint");
	const runtimeEpoch = requireRuntimeCommandEpoch(value["runtimeEpoch"]);
	const state = value["state"];
	if (state !== "started" && state !== "completed" && state !== "failed") throw new Error("Invalid Runtime command receipt state");
	const startedAt = requiredNonEmptyString(value["startedAt"], "startedAt");
	const completedAt = value["completedAt"];
	const completedAtString = typeof completedAt === "string" ? completedAt : undefined;
	const error = value["error"];
	const result = optionalRuntimeCommandResult(value);
	if (state !== "started" && completedAtString === undefined) throw new Error("Terminal Runtime command receipt is missing completedAt");
	if (error !== undefined && typeof error !== "string") throw new Error("Invalid Runtime command receipt error");
	return {
		commandId,
		kind,
		fingerprint,
		runtimeEpoch,
		state,
		startedAt,
		...(completedAtString === undefined ? {} : { completedAt: completedAtString }),
		...(result === undefined ? {} : { result }),
		...(error === undefined ? {} : { error }),
	};
}

function receiptFromPersistedRecord(record: PersistedRuntimeCommandRecord, recoveredAfterRuntimeRestart = false): RuntimeCommandReceipt {
	if (record.state === "started" || record.completedAt === undefined) {
		throw new RuntimeCommandInterruptedError("Runtime command receipt did not reach a terminal state");
	}
	return {
		commandId: record.commandId,
		kind: record.kind,
		runtimeEpoch: record.runtimeEpoch,
		status: record.state,
		startedAt: record.startedAt,
		completedAt: record.completedAt,
		...(record.result === undefined ? {} : { result: record.result }),
		...(record.error === undefined ? {} : { error: record.error }),
		...(recoveredAfterRuntimeRestart ? { recoveredAfterRuntimeRestart: true } : {}),
	};
}

function requiredRuntimeCommandKind(value: unknown): RuntimeCommandKind {
	if (typeof value !== "string" || !isRuntimeCommandKind(value)) {
		throw new Error("Invalid Runtime command receipt kind");
	}
	return value;
}

function isRuntimeCommandKind(value: string): value is RuntimeCommandKind {
	return runtimeCommandKindValues.some((kind) => kind === value);
}

function isRuntimeCommandResult(value: unknown): value is RuntimeCommandResult {
	return isRecord(value);
}

function optionalRuntimeCommandResult(
	record: Record<string, unknown>,
): RuntimeCommandResult | undefined {
	const candidate: unknown = record["result"];
	if (candidate === undefined) return undefined;
	if (!isRuntimeCommandResult(candidate)) {
		throw new Error("Invalid Runtime command receipt result");
	}
	return candidate;
}

function requiredNonEmptyString(value: unknown, name: string): string {
	if (typeof value !== "string" || value === "") throw new Error(`Invalid Runtime command receipt ${name}`);
	return value;
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

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null &&
		(Object.getPrototypeOf(value) === Object.prototype || Object.getPrototypeOf(value) === null);
}

function isNodeErrorWithCode(error: unknown, code: string): error is NodeJS.ErrnoException {
	return error instanceof Error && "code" in error && error.code === code;
}
