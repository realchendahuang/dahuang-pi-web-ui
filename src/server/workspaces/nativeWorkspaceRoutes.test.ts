import { mkdtemp, mkdir, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import Fastify from "fastify";
import { afterEach, describe, expect, it } from "vitest";
import { RuntimeCommandReceipts } from "../runtimeCommandReceipts.js";
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

    it("returns bounded image bytes through the Native Contract without exposing a workspace path", async () => {
        const root = await temporaryProject();
        const image = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00]);
        await mkdir(join(root, "Assets"), { recursive: true });
        await writeFile(join(root, "Assets", "preview.png"), image);
        await writeFile(join(root, "Assets", "preview.txt"), "not an image");
        const app = createApp();
        try {
            const preview = await app.inject({
                method: "GET",
                url: `/workspace/file/preview?cwd=${encodeURIComponent(root)}&path=Assets%2Fpreview.png`,
            });
            expect(preview.statusCode).toBe(200);
            expect(preview.json()).toMatchObject({
                path: "Assets/preview.png",
                mimeType: "image/png",
                size: image.byteLength,
                data: image.toString("base64"),
            });
            expect(preview.body).not.toContain(root);

            const unsupported = await app.inject({
                method: "GET",
                url: `/workspace/file/preview?cwd=${encodeURIComponent(root)}&path=Assets%2Fpreview.txt`,
            });
            expect(unsupported.statusCode).toBe(400);
        } finally {
            await app.close();
        }
    });

    it("writes, moves, and deletes a text file once per epoch-bound receipt", async () => {
        const root = await temporaryProject();
        const app = createApp();
        try {
            const write = {
                cwd: root,
                path: "Notes/agent.txt",
                content: "native edit\n",
                commandId: "write-1",
                runtimeEpoch: "epoch-1",
            };
            const firstWrite = await app.inject({ method: "PUT", url: "/workspace/file", payload: write });
            const repeatWrite = await app.inject({ method: "PUT", url: "/workspace/file", payload: write });
            expect(firstWrite.statusCode).toBe(200);
            expect(repeatWrite.json()).toEqual(firstWrite.json());
            expect(firstWrite.json()).toMatchObject({
                kind: "write-workspace-file",
                status: "completed",
                result: { written: true, path: "Notes/agent.txt", created: true },
            });

            const protectedCreate = await app.inject({
                method: "PUT",
                url: "/workspace/file",
                payload: { ...write, commandId: "write-existing", overwrite: false },
            });
            expect(protectedCreate.json()).toMatchObject({
                kind: "write-workspace-file",
                status: "failed",
                error: "File already exists: Notes/agent.txt",
            });

            const moved = await app.inject({
                method: "POST",
                url: "/workspace/file/move",
                payload: {
                    cwd: root,
                    fromPath: "Notes/agent.txt",
                    toPath: "Notes/renamed.txt",
                    commandId: "move-1",
                    runtimeEpoch: "epoch-1",
                },
            });
            expect(moved.json()).toMatchObject({ result: { moved: true, fromPath: "Notes/agent.txt", toPath: "Notes/renamed.txt" } });

            const deleted = await app.inject({
                method: "DELETE",
                url: "/workspace/file",
                payload: { cwd: root, path: "Notes/renamed.txt", commandId: "delete-1", runtimeEpoch: "epoch-1" },
            });
            expect(deleted.json()).toMatchObject({ result: { deletedFile: true, path: "Notes/renamed.txt", existed: true } });

            const changedIntent = await app.inject({ method: "PUT", url: "/workspace/file", payload: { ...write, content: "different" } });
            const staleEpoch = await app.inject({ method: "PUT", url: "/workspace/file", payload: { ...write, commandId: "write-2", runtimeEpoch: "old" } });
            expect(changedIntent.statusCode).toBe(409);
            expect(staleEpoch.statusCode).toBe(409);
        } finally {
            await app.close();
        }
    });
});

function createApp() {
    const app = Fastify({ logger: false });
    registerNativeWorkspaceRoutes(app, new RuntimeCommandReceipts("epoch-1"));
    return app;
}

async function temporaryProject(): Promise<string> {
    const root = await mkdtemp(join(tmpdir(), "pi-agent-native-workspace-"));
    temporaryRoots.push(root);
    return root;
}
