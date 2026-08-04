import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { prepareSessiondSocketPath } from "./sessiondSocketSecurity.js";

describe("prepareSessiondSocketPath", () => {
	it("creates a private parent directory without deleting an unrelated regular file", async () => {
		const root = await mkdtemp(join(tmpdir(), "pi-web-sessiond-socket-"));
		const socketPath = join(root, "Runtime", "sessiond.sock");
		try {
			await prepareSessiondSocketPath(socketPath);
			const directory = await stat(join(root, "Runtime"));
			expect(directory.mode & 0o777).toBe(0o700);

			await writeFile(socketPath, "do not delete", "utf8");
			await expect(prepareSessiondSocketPath(socketPath)).rejects.toThrow(
				"Refusing to replace non-socket",
			);
			await expect(readFile(socketPath, "utf8")).resolves.toBe("do not delete");
		} finally {
			await rm(root, { recursive: true, force: true });
		}
	});
});
