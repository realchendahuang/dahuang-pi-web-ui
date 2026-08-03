import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
	listOmpSessionFiles,
	readOmpSessionSummary,
} from "./ompSessionStore.js";

let root = "";

beforeEach(async () => {
	root = await mkdtemp(join(tmpdir(), "pi-web-omp-store-"));
});

afterEach(async () => {
	await rm(root, { recursive: true, force: true });
});

describe("OMP session store", () => {
	it("reads title-prefixed OMP JSONL sessions without treating the title as the session header", async () => {
		const sessionPath = await writeSession("workspace-a", "session-a.jsonl", [
			{
				type: "title",
				v: 1,
				title: "OMP task",
				updatedAt: "2026-07-28T01:00:00.000Z",
				pad: "",
			},
			{
				type: "session",
				version: 3,
				id: "session-a",
				timestamp: "2026-07-28T00:00:00.000Z",
				cwd: "/repo/a",
			},
			{
				type: "message",
				id: "m1",
				parentId: null,
				timestamp: "2026-07-28T00:00:01.000Z",
				message: {
					role: "user",
					content: [{ type: "text", text: "Build it" }],
				},
			},
			{
				type: "message",
				id: "m2",
				parentId: "m1",
				timestamp: "2026-07-28T00:00:02.000Z",
				message: {
					role: "assistant",
					content: [{ type: "text", text: "Done" }],
				},
			},
		]);

		await expect(readOmpSessionSummary(sessionPath)).resolves.toMatchObject({
			id: "session-a",
			runtimeId: "omp",
			cwd: "/repo/a",
			name: "OMP task",
			created: "2026-07-28T00:00:00.000Z",
			modified: "2026-07-28T01:00:00.000Z",
			messageCount: 2,
			firstMessage: "Build it",
		});
	});

	it("filters recursively discovered sessions by canonical cwd", async () => {
		await writeSession("a", "one.jsonl", [
			{
				type: "session",
				version: 3,
				id: "one",
				timestamp: "2026-07-28T00:00:00.000Z",
				cwd: "/repo/a",
			},
		]);
		await writeSession("b", "two.jsonl", [
			{
				type: "session",
				version: 3,
				id: "two",
				timestamp: "2026-07-28T00:00:00.000Z",
				cwd: "/repo/b",
			},
		]);

		await expect(listOmpSessionFiles(root, "/repo/a/../a")).resolves.toEqual([
			expect.objectContaining({ id: "one", runtimeId: "omp" }),
		]);
	});

	it("ignores malformed files", async () => {
		await mkdir(join(root, "broken"), { recursive: true });
		await writeFile(join(root, "broken", "bad.jsonl"), "not json\n", "utf8");
		await expect(listOmpSessionFiles(root, "/repo")).resolves.toEqual([]);
	});
});

async function writeSession(
	folder: string,
	name: string,
	entries: unknown[],
): Promise<string> {
	const directory = join(root, folder);
	await mkdir(directory, { recursive: true });
	const path = join(directory, name);
	await writeFile(
		path,
		`${entries.map((entry) => JSON.stringify(entry)).join("\n")}\n`,
		"utf8",
	);
	return path;
}
