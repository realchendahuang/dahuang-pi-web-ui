import { describe, expect, it } from "vitest";
import {
	resolveOmpExecutable,
	wellKnownOmpBinDirs,
} from "./ompExecutable.js";

const executableFrom =
	(executables: ReadonlySet<string>) =>
	(path: string): Promise<boolean> =>
		Promise.resolve(executables.has(path));

describe("resolveOmpExecutable", () => {
	it("finds bare commands on the service PATH", async () => {
		const resolved = await resolveOmpExecutable("omp", {
			env: { PATH: "/service/bin:/usr/bin" },
			homeDir: "/home/user",
			isExecutable: executableFrom(new Set(["/service/bin/omp"])),
		});
		expect(resolved).toBe("/service/bin/omp");
	});

	it("falls back to well-known user install locations when PATH misses", async () => {
		// Services launched from a login shell miss interactive-rc PATH entries
		// such as ~/.npm-global/bin.
		const resolved = await resolveOmpExecutable("omp", {
			env: { PATH: "/usr/bin:/bin" },
			homeDir: "/home/user",
			isExecutable: executableFrom(
				new Set(["/home/user/.npm-global/bin/omp"]),
			),
		});
		expect(resolved).toBe("/home/user/.npm-global/bin/omp");
	});

	it("checks explicit paths directly without searching", async () => {
		const resolved = await resolveOmpExecutable("/opt/omp/bin/omp", {
			isExecutable: executableFrom(new Set(["/opt/omp/bin/omp"])),
		});
		expect(resolved).toBe("/opt/omp/bin/omp");
	});

	it("returns undefined when nothing executable matches", async () => {
		const resolved = await resolveOmpExecutable("omp", {
			env: { PATH: "/usr/bin" },
			homeDir: "/home/user",
			isExecutable: () => Promise.resolve(false),
		});
		expect(resolved).toBeUndefined();
	});

	it("returns undefined for non-executable explicit paths", async () => {
		const resolved = await resolveOmpExecutable("/missing/omp", {
			isExecutable: () => Promise.resolve(false),
		});
		expect(resolved).toBeUndefined();
	});
});

describe("wellKnownOmpBinDirs", () => {
	it("covers user-level npm and bun global bins before system dirs", () => {
		const dirs = wellKnownOmpBinDirs("/home/user");
		expect(dirs.indexOf("/home/user/.npm-global/bin")).toBeLessThan(
			dirs.indexOf("/opt/homebrew/bin"),
		);
		expect(dirs).toContain("/home/user/.bun/bin");
		expect(dirs).toContain("/usr/local/bin");
	});
});
