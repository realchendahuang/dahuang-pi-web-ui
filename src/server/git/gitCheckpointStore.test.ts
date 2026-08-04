import { mkdtemp, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import type { GitStatusResponse } from "../../shared/apiTypes.js";
import { GitCheckpointStore, parseGitCheckpointFile } from "./gitCheckpointStore.js";

const status: GitStatusResponse = { isGitRepo: true, hash: "clean", branch: "main", files: [], submodules: [] };

describe("GitCheckpointStore", () => {
	it("keeps Thread checkpoints in an atomic Runtime-owned file with private permissions", async () => {
		const directory = await mkdtemp(join(tmpdir(), "pi-agent-checkpoints-"));
		const path = join(directory, "native-git-checkpoints.json");
		const store = new GitCheckpointStore(path);
		const created = await store.create({
			sessionId: "thread-1", cwd: "/repo/../repo", status,
			unstaged: { hash: "u", diff: "unstaged", truncated: false },
			staged: { hash: "s", diff: "staged", truncated: false },
		});
		expect(created.cwd).toBe("/repo");
		expect((await store.list("/repo", "thread-1")).map((checkpoint) => checkpoint.id)).toEqual([created.id]);
		expect((await stat(path)).mode & 0o777).toBe(0o600);
	});

	it("rejects malformed persisted data instead of treating it as a valid review", () => {
		expect(() => parseGitCheckpointFile({ checkpoints: [{ id: "only-an-id" }] })).toThrow("Invalid Git checkpoint");
	});
});
