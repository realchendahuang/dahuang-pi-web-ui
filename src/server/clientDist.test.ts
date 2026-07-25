import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { isBuiltClientDist, resolveClientDist } from "./clientDist.js";

const tempDirs: string[] = [];

afterEach(() => {
	while (tempDirs.length > 0) {
		const dir = tempDirs.pop();
		if (dir !== undefined) rmSync(dir, { recursive: true, force: true });
	}
});

function tempDir(): string {
	const dir = mkdtempSync(join(tmpdir(), "pi-web-client-dist-"));
	tempDirs.push(dir);
	return dir;
}

function writeBuiltClient(root: string): string {
	const dir = join(root, "client");
	mkdirSync(join(dir, "assets"), { recursive: true });
	writeFileSync(
		join(dir, "index.html"),
		'<!doctype html><script type="module" src="./assets/index-abc.js"></script>\n',
	);
	writeFileSync(join(dir, "assets", "index-abc.js"), "console.log('ok');\n");
	return dir;
}

function writeSourceClient(root: string): string {
	const dir = join(root, "client");
	mkdirSync(join(dir, "src"), { recursive: true });
	writeFileSync(
		join(dir, "index.html"),
		'<!doctype html><link rel="icon" href="%BASE_URL%favicon.svg" /><script type="module" src="/src/main.ts"></script>\n',
	);
	writeFileSync(join(dir, "src", "main.ts"), "export {};\n");
	return dir;
}

describe("isBuiltClientDist", () => {
	it("accepts a Vite build output directory", () => {
		const built = writeBuiltClient(tempDir());
		expect(isBuiltClientDist(built)).toBe(true);
	});

	it("rejects the Vite source root (src/main.ts present)", () => {
		const source = writeSourceClient(tempDir());
		expect(isBuiltClientDist(source)).toBe(false);
	});

	it("rejects missing directories", () => {
		expect(isBuiltClientDist(join(tempDir(), "missing"))).toBe(false);
	});
});

describe("resolveClientDist", () => {
	it("honors an explicit override, including false", () => {
		expect(
			resolveClientDist({ override: false, packagedCandidate: "/nope" }),
		).toBe(false);
		expect(
			resolveClientDist({ override: "/explicit", packagedCandidate: "/nope" }),
		).toBe("/explicit");
	});

	it("prefers a built packaged candidate over cwd", () => {
		const root = tempDir();
		const packaged = writeBuiltClient(join(root, "packaged"));
		const cwd = writeBuiltClient(join(root, "cwd"));
		expect(
			resolveClientDist({
				packagedCandidate: packaged,
				cwdCandidate: cwd,
			}),
		).toBe(packaged);
	});

	it("falls back to a built cwd candidate when packaged is the source tree", () => {
		const root = tempDir();
		const packagedSource = writeSourceClient(join(root, "src"));
		const cwdBuilt = writeBuiltClient(join(root, "dist"));
		expect(
			resolveClientDist({
				packagedCandidate: packagedSource,
				cwdCandidate: cwdBuilt,
			}),
		).toBe(cwdBuilt);
	});

	it("returns false when only the Vite source root exists", () => {
		const source = writeSourceClient(tempDir());
		expect(
			resolveClientDist({
				packagedCandidate: source,
				cwdCandidate: join(tempDir(), "dist", "client"),
			}),
		).toBe(false);
	});
});
