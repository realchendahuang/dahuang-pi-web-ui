import { resolve } from "node:path";
import Fastify from "fastify";
import { describe, expect, it } from "vitest";
import type { GitDiffResponse, GitStatusResponse } from "../../shared/apiTypes.js";
import { RuntimeCommandReceipts } from "../runtimeCommandReceipts.js";
import { registerNativeGitRoutes, type NativeGitRouteService } from "./nativeGitRoutes.js";

const cleanStatus: GitStatusResponse = { isGitRepo: true, hash: "clean", branch: "main", files: [], submodules: [] };

describe("native Git routes", () => {
	it("returns Runtime-owned status and both diff projections for the selected project", async () => {
		const service = new CapturingNativeGitService();
		const app = createApp(service);
		try {
			const status = await app.inject({ method: "GET", url: "/git/status?cwd=/repo/../repo" });
			const diff = await app.inject({ method: "GET", url: "/git/diff?cwd=/repo&path=src%2Fmain.ts&staged=true" });
			expect(status.statusCode).toBe(200);
			expect(status.json()).toEqual(cleanStatus);
			expect(diff.statusCode).toBe(200);
			expect(diff.json()).toMatchObject({ path: "src/main.ts", staged: true });
			expect(service.statusCalls).toEqual([resolve("/repo")]);
			expect(service.diffCalls).toEqual([{ cwd: resolve("/repo"), options: { path: "src/main.ts", staged: true } }]);
		} finally { await app.close(); }
	});

	it("executes stage once per receipt and rejects changed intent or a stale Runtime epoch", async () => {
		const service = new CapturingNativeGitService();
		const app = createApp(service);
		const payload = { cwd: "/repo", paths: ["b.ts", "a.ts", "a.ts"], commandId: "stage-1", runtimeEpoch: "epoch-1" };
		try {
			const first = await app.inject({ method: "POST", url: "/git/stage", payload });
			const retry = await app.inject({ method: "POST", url: "/git/stage", payload });
			expect(first.statusCode).toBe(200);
			expect(first.json()).toMatchObject({ commandId: "stage-1", kind: "stage-git-paths", status: "completed", result: { staged: true, paths: ["a.ts", "b.ts"], status: cleanStatus } });
			expect(retry.json()).toEqual(first.json());
			expect(service.stageCalls).toEqual([{ cwd: resolve("/repo"), paths: ["a.ts", "b.ts"] }]);
			const conflict = await app.inject({ method: "POST", url: "/git/stage", payload: { ...payload, paths: ["different.ts"] } });
			const stale = await app.inject({ method: "POST", url: "/git/stage", payload: { ...payload, commandId: "stage-2", runtimeEpoch: "old" } });
			expect(conflict.statusCode).toBe(409);
			expect(stale.statusCode).toBe(409);
		} finally { await app.close(); }
	});

	it("makes unstage and commit receipt-safe and keeps the commit message out of route state", async () => {
		const service = new CapturingNativeGitService();
		const app = createApp(service);
		try {
			const unstage = await app.inject({ method: "POST", url: "/git/unstage", payload: { cwd: "/repo", paths: ["src/main.ts"], commandId: "unstage-1", runtimeEpoch: "epoch-1" } });
			const commit = await app.inject({ method: "POST", url: "/git/commit", payload: { cwd: "/repo", message: "  native git workflow  ", commandId: "commit-1", runtimeEpoch: "epoch-1" } });
			expect(unstage.json()).toMatchObject({ result: { unstaged: true, paths: ["src/main.ts"], status: cleanStatus } });
			expect(commit.json()).toMatchObject({ result: { committed: true, hash: "deadbeef", subject: "native git workflow", status: cleanStatus } });
			expect(service.unstageCalls).toEqual([{ cwd: resolve("/repo"), paths: ["src/main.ts"] }]);
			expect(service.commitCalls).toEqual([{ cwd: resolve("/repo"), message: "native git workflow" }]);
		} finally { await app.close(); }
	});
});

function createApp(service: CapturingNativeGitService) {
	const app = Fastify({ logger: false });
	registerNativeGitRoutes(app, new RuntimeCommandReceipts("epoch-1"), service);
	return app;
}

class CapturingNativeGitService implements NativeGitRouteService {
	readonly statusCalls: string[] = [];
	readonly diffCalls: { cwd: string; options: { path?: string; staged?: boolean } }[] = [];
	readonly stageCalls: { cwd: string; paths: readonly string[] }[] = [];
	readonly unstageCalls: { cwd: string; paths: readonly string[] }[] = [];
	readonly commitCalls: { cwd: string; message: string }[] = [];

	status(cwd: string): Promise<GitStatusResponse> { this.statusCalls.push(cwd); return Promise.resolve(cleanStatus); }
	diff(cwd: string, options: { path?: string; staged?: boolean }): Promise<GitDiffResponse> {
		this.diffCalls.push({ cwd, options });
		return Promise.resolve({
			...(options.path === undefined ? {} : { path: options.path }),
			staged: options.staged === true, hash: "diff", diff: "diff --git", truncated: false,
		});
	}
	stage(cwd: string, paths: readonly string[]): Promise<GitStatusResponse> { this.stageCalls.push({ cwd, paths }); return Promise.resolve(cleanStatus); }
	unstage(cwd: string, paths: readonly string[]): Promise<GitStatusResponse> { this.unstageCalls.push({ cwd, paths }); return Promise.resolve(cleanStatus); }
	commit(cwd: string, message: string) { this.commitCalls.push({ cwd, message }); return Promise.resolve({ hash: "deadbeef", subject: message, status: cleanStatus }); }
}
