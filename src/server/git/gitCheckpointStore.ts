import { randomUUID } from "node:crypto";
import { chmod, mkdir, readFile, rename, unlink, writeFile } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { piWebDataDir } from "../../config.js";
import type { GitCheckpoint, GitCheckpointFile } from "../../shared/apiTypes.js";
import { canonicalizeStoredCwd } from "../workingDirectory.js";

/**
 * Checkpoints are a local Runtime read model, not a Git ref or a promise that
 * a later worktree can be restored. The 0600 file can contain local diffs, so
 * it intentionally remains in the Runtime-owned PI_WEB_DATA_DIR.
 */
export function defaultGitCheckpointFilePath(
	env: NodeJS.ProcessEnv = process.env,
	cwd = process.cwd(),
): string {
	return join(piWebDataDir(env, cwd), "native-git-checkpoints.json");
}

export class GitCheckpointStore {
	private operationQueue: Promise<void> = Promise.resolve();

	constructor(private readonly filePath = defaultGitCheckpointFilePath()) {}

	async list(cwd: string, sessionId: string): Promise<GitCheckpoint[]> {
		const canonicalCwd = canonicalizeStoredCwd(cwd);
		return (await this.read()).checkpoints
			.filter((checkpoint) => checkpoint.cwd === canonicalCwd && checkpoint.sessionId === sessionId)
			.sort((left, right) => right.createdAt.localeCompare(left.createdAt));
	}

	async create(checkpoint: Omit<GitCheckpoint, "id" | "createdAt">): Promise<GitCheckpoint> {
		return this.exclusive(async () => {
			const data = await this.read();
			const record: GitCheckpoint = {
				...checkpoint,
				id: randomUUID(),
				cwd: canonicalizeStoredCwd(checkpoint.cwd),
				createdAt: new Date().toISOString(),
			};
			data.checkpoints.push(record);
			await this.write(data);
			return record;
		});
	}

	private async exclusive<T>(operation: () => Promise<T>): Promise<T> {
		const previous = this.operationQueue;
		let release = (): void => undefined;
		this.operationQueue = new Promise<void>((resolve) => { release = resolve; });
		await previous.catch(() => undefined);
		try {
			return await operation();
		} finally {
			release();
		}
	}

	private async read(): Promise<GitCheckpointFile> {
		try {
			return parseGitCheckpointFile(JSON.parse(await readFile(this.filePath, "utf8")));
		} catch (error: unknown) {
			if (isNodeErrorWithCode(error, "ENOENT")) return { checkpoints: [] };
			throw error;
		}
	}

	private async write(data: GitCheckpointFile): Promise<void> {
		await mkdir(dirname(this.filePath), { recursive: true, mode: 0o700 });
		const temporaryPath = join(
			dirname(this.filePath),
			`.${basename(this.filePath)}.${String(process.pid)}.${String(Date.now())}.${randomUUID()}.tmp`,
		);
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

export function parseGitCheckpointFile(value: unknown): GitCheckpointFile {
	if (!isRecord(value) || !Array.isArray(value["checkpoints"])) throw new Error("Invalid Git checkpoint file");
	return { checkpoints: value["checkpoints"].map(parseGitCheckpoint) };
}

function parseGitCheckpoint(value: unknown): GitCheckpoint {
	if (!isRecord(value)) throw new Error("Invalid Git checkpoint");
	const id = requiredString(value, "id");
	const sessionId = requiredString(value, "sessionId");
	const cwd = canonicalizeStoredCwd(requiredString(value, "cwd"));
	const createdAt = requiredString(value, "createdAt");
	const status = value["status"];
	const unstaged = value["unstaged"];
	const staged = value["staged"];
	if (!isGitStatus(status) || !isGitCheckpointDiff(unstaged) || !isGitCheckpointDiff(staged)) {
		throw new Error("Invalid Git checkpoint");
	}
	return { id, sessionId, cwd, createdAt, status, unstaged, staged };
}

function isGitStatus(value: unknown): value is GitCheckpoint["status"] {
	return isRecord(value)
		&& typeof value["isGitRepo"] === "boolean"
		&& typeof value["hash"] === "string"
		&& Array.isArray(value["files"])
		&& Array.isArray(value["submodules"]);
}

function isGitCheckpointDiff(value: unknown): value is GitCheckpoint["unstaged"] {
	return isRecord(value)
		&& typeof value["hash"] === "string"
		&& typeof value["diff"] === "string"
		&& typeof value["truncated"] === "boolean";
}

function requiredString(value: Record<string, unknown>, key: string): string {
	const field = value[key];
	if (typeof field !== "string" || field === "") throw new Error("Invalid Git checkpoint");
	return field;
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isNodeErrorWithCode(error: unknown, code: string): error is NodeJS.ErrnoException {
	return error instanceof Error && "code" in error && error.code === code;
}
