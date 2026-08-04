import type { FastifyInstance } from "fastify";
import type { GitDiffResponse, GitStatusResponse } from "../../shared/apiTypes.js";
import {
	RUNTIME_COMMAND_KINDS,
	type RuntimeCommandReceipts,
	type RuntimeGitMutationCommandResult,
	requireRuntimeCommandEpoch,
	requireRuntimeCommandId,
	runtimeCommandErrorStatus,
	runtimeCommandFingerprint,
} from "../runtimeCommandReceipts.js";
import { normalizeRequestCwd } from "../workingDirectory.js";
import {
	gitCommit,
	gitDiff,
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
}

const defaultService: NativeGitRouteService = { status: gitStatus, diff: gitDiff, stage: gitStage, unstage: gitUnstage, commit: gitCommit };

interface GitQuery { cwd?: string; path?: string; staged?: string }
interface GitPathsCommand { cwd?: unknown; paths?: unknown; commandId?: unknown; runtimeEpoch?: unknown }
interface GitCommitCommand { cwd?: unknown; message?: unknown; commandId?: unknown; runtimeEpoch?: unknown }

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

function nativeReceipt(body: Record<string, unknown>, kind: typeof RUNTIME_COMMAND_KINDS.stageGitPaths | typeof RUNTIME_COMMAND_KINDS.unstageGitPaths | typeof RUNTIME_COMMAND_KINDS.commitGit, payload: unknown) {
	return {
		commandId: requireRuntimeCommandId(body["commandId"]), kind,
		expectedRuntimeEpoch: requireRuntimeCommandEpoch(body["runtimeEpoch"]),
		fingerprint: runtimeCommandFingerprint({ kind, payload }),
	};
}

function requireCwd(value: unknown): string { return normalizeRequestCwd(requireString(value, "cwd")); }
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
