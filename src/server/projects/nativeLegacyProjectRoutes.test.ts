import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
	readNativeLegacyMigrationOverview,
	readNativeLegacyProjectPreview,
} from "./nativeLegacyProjectRoutes.js";

const roots: string[] = [];

afterEach(async () => {
	await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe("native legacy PI WEB migration overview", () => {
	it("returns a redacted inventory and never reads machine or unread payloads", async () => {
		const legacyDataDir = await fixtureRoot();
		const secretMachineToken = "machine-token-must-not-leave-the-runtime";
		const unreadPrompt = "private unread prompt must not be returned";
		await Promise.all([
			writeFile(join(legacyDataDir, "projects.json"), JSON.stringify({
				projects: [
					{ id: "project-1", name: "One", path: "/private/tmp/one", createdAt: "2026-08-01T00:00:00Z" },
					{ id: "relative", name: "Skip", path: "relative/path", createdAt: "2026-08-01T00:00:01Z" },
				],
			})),
			writeFile(join(legacyDataDir, "archived-sessions.json"), "{}"),
			writeFile(join(legacyDataDir, "machines.json"), JSON.stringify({ token: secretMachineToken })),
			writeFile(join(legacyDataDir, "session-unread.json"), JSON.stringify({ prompt: unreadPrompt })),
		]);

		const overview = await readNativeLegacyMigrationOverview({
			PI_AGENT_LEGACY_PI_WEB_DATA_DIR: legacyDataDir,
		});

		expect(overview).toEqual({
			legacyDataDir,
			items: [
				{
					id: "projects",
					source: join(legacyDataDir, "projects.json"),
					sourceExists: true,
					action: "reauthorize-projects",
					itemCount: 1,
				},
				{
					id: "archived-sessions",
					source: join(legacyDataDir, "archived-sessions.json"),
					sourceExists: true,
					action: "copied-and-retained",
				},
				{
					id: "machines",
					source: join(legacyDataDir, "machines.json"),
					sourceExists: true,
					action: "retained",
				},
				{
					id: "unread",
					source: join(legacyDataDir, "session-unread.json"),
					sourceExists: true,
					action: "retained",
				},
			],
		});
		expect(JSON.stringify(overview)).not.toContain(secretMachineToken);
		expect(JSON.stringify(overview)).not.toContain(unreadPrompt);
	});

	it("reports malformed project metadata without concealing the rest of the inventory", async () => {
		const legacyDataDir = await fixtureRoot();
		await mkdir(join(legacyDataDir, "machines.json"));
		await writeFile(join(legacyDataDir, "projects.json"), "not json");

		const env = { PI_AGENT_LEGACY_PI_WEB_DATA_DIR: legacyDataDir };
		const preview = await readNativeLegacyProjectPreview(env);
		const overview = await readNativeLegacyMigrationOverview(env);

		expect(preview.sourceExists).toBe(true);
		expect(preview.candidates).toEqual([]);
		expect(preview.issue).toContain("Unexpected token");
		const projects = overview.items.find((item) => item.id === "projects");
		const machines = overview.items.find((item) => item.id === "machines");
		const archives = overview.items.find((item) => item.id === "archived-sessions");
		expect(projects).toMatchObject({ sourceExists: true, action: "reauthorize-projects" });
		expect(projects?.issue).toContain("Unexpected token");
		expect(machines).toEqual({
			id: "machines",
			source: join(legacyDataDir, "machines.json"),
			sourceExists: false,
			action: "retained",
			issue: "Legacy state exists but is not a regular file.",
		});
		expect(archives).toEqual({
			id: "archived-sessions",
			source: join(legacyDataDir, "archived-sessions.json"),
			sourceExists: false,
			action: "copied-and-retained",
		});
	});
});

async function fixtureRoot(): Promise<string> {
	const root = await mkdtemp(join(tmpdir(), "pi-agent-legacy-overview-"));
	roots.push(root);
	return root;
}
