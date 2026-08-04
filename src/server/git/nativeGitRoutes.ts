import type { FastifyInstance } from "fastify";
import type { GitCheckpoint, GitCheckpointDiff, GitDiffResponse, GitPushPreview, GitStatusResponse } from "../../shared/apiTypes.js";
import {
	RUNTIME_COMMAND_KINDS,
	type RuntimeCommandReceipts,
	type RuntimeGitCheckpointCommandResult,
	type RuntimeGitMutationCommandResult,
	type RuntimeGitPushCommandResult,
	requireRuntimeCommandEpoch,
	requireRuntimeCommandId,
	runtimeCommandErrorStatus,
	runtimeCommandFingerprint,
} from "../runtimeCommandReceipts.js";
import { normalizeRequestCwd } from "../workingDirectory.js";
import { GitCheckpointStore } from "./gitCheckpointStore.js";
import {
	gitCommit,
	gitDiff,
	gitPush,
	gitPushPreview,
	gitStage,
	gitStatus,
	gitUnstage,
	normalizeCommitMessage,
	normalizeGitMutationPaths,
} from "./gitService.js";

export interface NativeGitRouteService {
	status(cwd: string): Promise<GitStatusResponse>;
	diff(cwd: string, options: { path?: string; staged?: boolean }): Promise<GitDiffResponse>;
	stage(cwd: string, paths: readonly string[]): Promise<GitStatusResponse>;
	unstage(cwd: string, paths: readonly string[]): Promise<GitStatusResponse>;
	commit(cwd: string, message: string): Promise<{ hash: string; subject: string; status: GitStatusResponse }>;
	pushPreview(cwd: string): Promise<GitPushPreview>;
	push(cwd: string): Promise<GitStatusResponse>;
	listCheckpoints(cwd: string, sessionId: string): Promise<GitCheckpoint[]>;
	createCheckpoint(cwd: string, sessionId: string): Promise<GitCheckpoint>;
}

const checkpointStore = new GitCheckpointStore();
const defaultService: NativeGitRouteService = {
	status: gitStatus,
	diff: gitDiff,
	stage: gitStage,
	unstage: gitUnstage,
	commit: gitCommit,
	pushPreview: gitPushPreview,
	push: gitPush,
	listCheckpoints: (cwd, sessionId) => checkpointStore.list(cwd, sessionId),
	createCheckpoint: async (cwd, sessionId) => {
		const status = await gitStatus(cwd);
		if (!status.isGitRepo) throw new Error("Git checkpoints require a Git repository");
		const [unstaged, staged] = await Promise.all([
			gitDiff(cwd, { staged: false }),
			gitDiff(cwd, { staged: true }),
		]);
		return checkpointStore.create({
			sessionId,
			cwd,
			status,
			unstaged: boundedCheckpointDiff(unstaged),
			staged: boundedCheckpointDiff(staged),
		});
	},
};

interface GitQuery { cwd?: string; path?: string; staged?: string; sessionId?: string }
interface GitPathsCommand { cwd?: unknown; paths?: unknown; commandId?: unknown; runtimeEpoch?: unknown }
interface GitCommitCommand { cwd?: unknown; message?: unknown; commandId?: unknown; runtimeEpoch?: unknown }
interface GitPushCommand { cwd?: unknown; confirmed?: unknown; commandId?: unknown; runtimeEpoch?: unknown }
interface GitCheckpointCommand { cwd?: unknown; sessionId?: unknown; commandId?: unknown; runtimeEpoch?: unknown }

/**
 * Persisting more than this per diff makes a review checkpoint a hidden local
 * archive. The `truncated` flag is preserved so the native UI never mistakes a
 * bounded projection for a complete restore point.
 */
const MAX_CHECKPOINT_DIFF_BYTES = 256 * 1024;

/**
 * Native-only Git contract. Unlike `/api` workspace compatibility routes this
 * surface is scoped by a directly selected project cwd and every mutation is
 * receipt-safe, so Swift never executes `git` itself or retries unknown work.
 */
export function registerNativeGitRoutes(
	app: FastifyInstance,
	receipts: RuntimeCommandReceipts,
	service: NativeGitRouteService = defaultService,
): void {
	app.get<{ Querystring: GitQuery }>("/git/status", async (request, reply) => {
		try { return await service.status(requireCwd(request.query.cwd)); }
		catch (error) { return reply.code(400).send({ error: errorMessage(error) }); }
	});
	app.get<{ Querystring: GitQuery }>("/git/diff", async (request, reply) => {
		try {
			const cwd = requireCwd(request.query.cwd);
			return await service.diff(cwd, {
				...(request.query.path === undefined || request.query.path === "" ? {} : { path: request.query.path }),
				staged: request.query.staged === "true",
			});
		} catch (error) { return reply.code(400).send({ error: errorMessage(error) }); }
	});
	app.post<{ Body: GitPathsCommand | undefined }>("/git/stage", async (request, reply) => {
		try {
			const command = parsePathsCommand(request.body, RUNTIME_COMMAND_KINDS.stageGitPaths);
			return await receipts.execute(command.receipt, async (): Promise<RuntimeGitMutationCommandResult> => ({
				staged: true, paths: command.paths, status: await service.stage(command.cwd, command.paths),
			}));
		} catch (error) { return reply.code(runtimeCommandErrorStatus(error) ?? 400).send({ error: errorMessage(error) }); }
	});
	app.post<{ Body: GitPathsCommand | undefined }>("/git/unstage", async (request, reply) => {
		try {
			const command = parsePathsCommand(request.body, RUNTIME_COMMAND_KINDS.unstageGitPaths);
			return await receipts.execute(command.receipt, async (): Promise<RuntimeGitMutationCommandResult> => ({
				unstaged: true, paths: command.paths, status: await service.unstage(command.cwd, command.paths),
			}));
		} catch (error) { return reply.code(runtimeCommandErrorStatus(error) ?? 400).send({ error: errorMessage(error) }); }
	});
	app.post<{ Body: GitCommitCommand | undefined }>("/git/commit", async (request, reply) => {
		try {
			const command = parseCommitCommand(request.body);
			return await receipts.execute(command.receipt, async (): Promise<RuntimeGitMutationCommandResult> => {
				const result = await service.commit(command.cwd, command.message);
				return { committed: true, hash: result.hash, subject: result.subject, status: result.status };
			});
		} catch (error) { return reply.code(runtimeCommandErrorStatus(error) ?? 400).send({ error: errorMessage(error) }); }
	});
	app.get<{ Querystring: GitQuery }>("/git/push-preview", async (request, reply) => {
		try { return await service.pushPreview(requireCwd(request.query.cwd)); }
		catch (error) { return reply.code(400).send({ error: errorMessage(error) }); }
	});
	app.post<{ Body: GitPushCommand | undefined }>("/git/push", async (request, reply) => {
		try {
			const command = parsePushCommand(request.body);
			return await receipts.execute(command.receipt, async (): Promise<RuntimeGitPushCommandResult> => ({
				pushed: true, status: await service.push(command.cwd),
			}));
		} catch (error) { return reply.code(runtimeCommandErrorStatus(error) ?? 400).send({ error: errorMessage(error) }); }
	});
	app.get<{ Querystring: GitQuery }>("/git/checkpoints", async (request, reply) => {
		try {
			return await service.listCheckpoints(
				requireCwd(request.query.cwd),
				requireSessionId(request.query.sessionId),
			);
		} catch (error) { return reply.code(400).send({ error: errorMessage(error) }); }
	});
	app.post<{ Body: GitCheckpointCommand | undefined }>("/git/checkpoints", async (request, reply) => {
		try {
			const command = parseCheckpointCommand(request.body);
			return await receipts.execute(command.receipt, async (): Promise<RuntimeGitCheckpointCommandResult> => ({
				checkpointed: true,
				checkpoint: await service.createCheckpoint(command.cwd, command.sessionId),
			}));
		} catch (error) { return reply.code(runtimeCommandErrorStatus(error) ?? 400).send({ error: errorMessage(error) }); }
	});
}

function parsePathsCommand(body: GitPathsCommand | undefined, kind: typeof RUNTIME_COMMAND_KINDS.stageGitPaths | typeof RUNTIME_COMMAND_KINDS.unstageGitPaths) {
	const record = requireRecord(body);
	const cwd = requireCwd(record["cwd"]);
	const paths = normalizeGitMutationPaths(requireStringArray(record["paths"], "paths"));
	return { cwd, paths, receipt: nativeReceipt(record, kind, { cwd, paths }) };
}

function parseCommitCommand(body: GitCommitCommand | undefined) {
	const record = requireRecord(body);
	const cwd = requireCwd(record["cwd"]);
	const message = normalizeCommitMessage(requireString(record["message"], "message"));
	return { cwd, message, receipt: nativeReceipt(record, RUNTIME_COMMAND_KINDS.commitGit, { cwd, message }) };
}

function parsePushCommand(body: GitPushCommand | undefined) {
	const record = requireRecord(body);
	const cwd = requireCwd(record["cwd"]);
	if (record["confirmed"] !== true) throw new Error("Push requires explicit confirmation");
	return { cwd, receipt: nativeReceipt(record, RUNTIME_COMMAND_KINDS.pushGit, { cwd }) };
}

function parseCheckpointCommand(body: GitCheckpointCommand | undefined) {
	const record = requireRecord(body);
	const cwd = requireCwd(record["cwd"]);
	const sessionId = requireSessionId(record["sessionId"]);
	return {
		cwd,
		sessionId,
		receipt: nativeReceipt(record, RUNTIME_COMMAND_KINDS.createGitCheckpoint, { cwd, sessionId }),
	};
}

function nativeReceipt(body: Record<string, unknown>, kind: typeof RUNTIME_COMMAND_KINDS.stageGitPaths | typeof RUNTIME_COMMAND_KINDS.unstageGitPaths | typeof RUNTIME_COMMAND_KINDS.commitGit | typeof RUNTIME_COMMAND_KINDS.pushGit | typeof RUNTIME_COMMAND_KINDS.createGitCheckpoint, payload: unknown) {
	return {
		commandId: requireRuntimeCommandId(body["commandId"]), kind,
		expectedRuntimeEpoch: requireRuntimeCommandEpoch(body["runtimeEpoch"]),
		fingerprint: runtimeCommandFingerprint({ kind, payload }),
	};
}

function requireCwd(value: unknown): string { return normalizeRequestCwd(requireString(value, "cwd")); }
function requireSessionId(value: unknown): string {
	const sessionId = requireString(value, "sessionId").trim();
	if (sessionId === "" || sessionId.length > 512) throw new Error("sessionId must be between 1 and 512 characters");
	return sessionId;
}
function requireString(value: unknown, name: string): string { if (typeof value !== "string") throw new Error(`${name} must be a string`); return value; }
function requireStringArray(value: unknown, name: string): string[] { if (!Array.isArray(value) || !value.every((item) => typeof item === "string")) throw new Error(`${name} must be an array of strings`); return value; }
function requireRecord(value: unknown): Record<string, unknown> {
	if (!isRecord(value)) throw new Error("request body must be an object");
	return value;
}
function isRecord(value: unknown): value is Record<string, unknown> {
	return value !== null && typeof value === "object" && !Array.isArray(value);
}
function errorMessage(error: unknown): string { return error instanceof Error ? error.message : String(error); }

export function boundedCheckpointDiff(diff: GitDiffResponse): GitCheckpointDiff {
	const bytes = Buffer.from(diff.diff, "utf8");
	if (bytes.byteLength <= MAX_CHECKPOINT_DIFF_BYTES) {
		return { hash: diff.hash, diff: diff.diff, truncated: diff.truncated };
	}
	return {
		hash: diff.hash,
		diff: bytes.subarray(0, MAX_CHECKPOINT_DIFF_BYTES).toString("utf8"),
		truncated: true,
	};
}
