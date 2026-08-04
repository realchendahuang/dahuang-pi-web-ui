import { mkdtemp, mkdir, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import Fastify from "fastify";
import { afterEach, describe, expect, it } from "vitest";
import { registerNativeWorkspaceRoutes } from "./nativeWorkspaceRoutes.js";

const temporaryRoots: string[] = [];

afterEach(async () => {
    await Promise.all(temporaryRoots.splice(0).map((path) => rm(path, { recursive: true, force: true })));
});

describe("native workspace routes", () => {
    it("projects a selected project tree and UTF-8 file content without exposing absolute child paths", async () => {
        const root = await temporaryProject();
        await mkdir(join(root, "Sources"));
        await writeFile(join(root, "Sources", "App.swift"), "print(\"Pi Agent\")\n");
        await writeFile(join(root, "README.md"), "# Native workspace\n");
        const app = createApp();
        try {
            const normalizedRoot = `${root}/../${basename(root)}`;
            const tree = await app.inject({ method: "GET", url: `/workspace/tree?cwd=${encodeURIComponent(normalizedRoot)}` });
            expect(tree.statusCode).toBe(200);
            expect(tree.json()).toMatchObject({
                path: "",
                truncated: false,
                entries: [
                    { name: "Sources", path: "Sources", type: "directory" },
                    { name: "README.md", path: "README.md", type: "file" },
                ],
            });

            const file = await app.inject({ method: "GET", url: `/workspace/file?cwd=${encodeURIComponent(root)}&path=Sources%2FApp.swift` });
            expect(file.statusCode).toBe(200);
            expect(file.json()).toMatchObject({
                path: "Sources/App.swift",
                content: "print(\"Pi Agent\")\n",
                binary: false,
            });
        } finally {
            await app.close();
        }
    });

    it("rejects relative cwd values, path traversal, and a symlink that escapes the selected project", async () => {
        const root = await temporaryProject();
        const outside = await temporaryProject();
        await writeFile(join(outside, "secret.txt"), "outside");
        await symlink(outside, join(root, "escape"));
        const app = createApp();
        try {
            const relativeCwd = await app.inject({ method: "GET", url: "/workspace/tree?cwd=relative-project" });
            const traversal = await app.inject({ method: "GET", url: `/workspace/file?cwd=${encodeURIComponent(root)}&path=..%2Fsecret.txt` });
            const symlinkEscape = await app.inject({ method: "GET", url: `/workspace/file?cwd=${encodeURIComponent(root)}&path=escape%2Fsecret.txt` });
            expect(relativeCwd.statusCode).toBe(400);
            expect(traversal.statusCode).toBe(400);
            expect(symlinkEscape.statusCode).toBe(400);
        } finally {
            await app.close();
        }
    });
});

function createApp() {
    const app = Fastify({ logger: false });
    registerNativeWorkspaceRoutes(app);
    return app;
}

async function temporaryProject(): Promise<string> {
    const root = await mkdtemp(join(tmpdir(), "pi-agent-native-workspace-"));
    temporaryRoots.push(root);
    return root;
}
