import type { FastifyInstance } from "fastify";
import {
    RUNTIME_COMMAND_KINDS,
    type RuntimeCommandReceipts,
    requireRuntimeCommandEpoch,
    requireRuntimeCommandId,
    runtimeCommandErrorStatus,
    runtimeCommandFingerprint,
} from "../runtimeCommandReceipts.js";
import { normalizeRequestCwd } from "../workingDirectory.js";
import {
    deleteWorkspaceFile,
    moveWorkspaceFile,
    readWorkspaceFile,
    writeWorkspaceFile,
} from "./fileContentService.js";
import { listWorkspaceTree } from "./fileTreeService.js";

interface WorkspaceQuery {
    cwd?: string;
    path?: string;
}

interface WriteWorkspaceFileCommand {
    cwd?: unknown;
    path?: unknown;
    content?: unknown;
    overwrite?: unknown;
    commandId?: unknown;
    runtimeEpoch?: unknown;
}

interface DeleteWorkspaceFileCommand {
    cwd?: unknown;
    path?: unknown;
    commandId?: unknown;
    runtimeEpoch?: unknown;
}

interface MoveWorkspaceFileCommand {
    cwd?: unknown;
    fromPath?: unknown;
    toPath?: unknown;
    overwrite?: unknown;
    commandId?: unknown;
    runtimeEpoch?: unknown;
}

/**
 * Native-only workspace projection and mutation boundary. The selected
 * project remains the root of trust: callers provide an absolute cwd, which
 * the bundled Runtime's project-capability hook authorizes before these
 * handlers run. Swift never reads or mutates the checkout directly.
 */
export function registerNativeWorkspaceRoutes(
    app: FastifyInstance,
    receipts: RuntimeCommandReceipts,
): void {
    app.get<{ Querystring: WorkspaceQuery }>("/workspace/tree", async (request, reply) => {
        try {
            return await listWorkspaceTree(requireCwd(request.query.cwd), request.query.path);
        } catch (error) {
            return reply.code(400).send({ error: errorMessage(error) });
        }
    });

    app.get<{ Querystring: WorkspaceQuery }>("/workspace/file", async (request, reply) => {
        try {
            return await readWorkspaceFile(requireCwd(request.query.cwd), request.query.path);
        } catch (error) {
            return reply.code(400).send({ error: errorMessage(error) });
        }
    });

    app.put<{ Body: WriteWorkspaceFileCommand }>("/workspace/file", async (request, reply) => {
        try {
            const command = parseWriteCommand(request.body);
            return await receipts.execute(command.receipt, async () => {
                const result = await writeWorkspaceFile(
                    command.cwd,
                    command.path,
                    Buffer.from(command.content, "utf8"),
                    { overwrite: command.overwrite },
                );
                return { written: true as const, ...result };
            });
        } catch (error) {
            return reply.code(runtimeCommandErrorStatus(error) ?? 400).send({ error: errorMessage(error) });
        }
    });

    app.delete<{ Body: DeleteWorkspaceFileCommand }>("/workspace/file", async (request, reply) => {
        try {
            const command = parseDeleteCommand(request.body);
            return await receipts.execute(command.receipt, async () => {
                const result = await deleteWorkspaceFile(command.cwd, command.path);
                return { deletedFile: true as const, ...result };
            });
        } catch (error) {
            return reply.code(runtimeCommandErrorStatus(error) ?? 400).send({ error: errorMessage(error) });
        }
    });

    app.post<{ Body: MoveWorkspaceFileCommand }>("/workspace/file/move", async (request, reply) => {
        try {
            const command = parseMoveCommand(request.body);
            return await receipts.execute(command.receipt, async () => {
                const result = await moveWorkspaceFile(command.cwd, command.fromPath, command.toPath, {
                    overwrite: command.overwrite,
                });
                return { moved: true as const, ...result };
            });
        } catch (error) {
            return reply.code(runtimeCommandErrorStatus(error) ?? 400).send({ error: errorMessage(error) });
        }
    });
}

function parseWriteCommand(body: WriteWorkspaceFileCommand) {
    const cwd = requireCwd(body.cwd);
    const path = requireString(body.path, "path");
    const content = requireString(body.content, "content");
    if (Buffer.byteLength(content, "utf8") > MAX_NATIVE_WORKSPACE_TEXT_BYTES) {
        throw new Error("content exceeds the 512 KB native workspace edit limit");
    }
    if (body.overwrite !== undefined && typeof body.overwrite !== "boolean") {
        throw new Error("overwrite must be a boolean");
    }
    const overwrite = body.overwrite ?? true;
    return {
        cwd,
        path,
        content,
        overwrite,
        receipt: receipt(body, RUNTIME_COMMAND_KINDS.writeWorkspaceFile, { cwd, path, content, overwrite }),
    };
}

const MAX_NATIVE_WORKSPACE_TEXT_BYTES = 512 * 1024;

function parseDeleteCommand(body: DeleteWorkspaceFileCommand) {
    const cwd = requireCwd(body.cwd);
    const path = requireString(body.path, "path");
    return {
        cwd,
        path,
        receipt: receipt(body, RUNTIME_COMMAND_KINDS.deleteWorkspaceFile, { cwd, path }),
    };
}

function parseMoveCommand(body: MoveWorkspaceFileCommand) {
    const cwd = requireCwd(body.cwd);
    const fromPath = requireString(body.fromPath, "fromPath");
    const toPath = requireString(body.toPath, "toPath");
    if (body.overwrite !== undefined && typeof body.overwrite !== "boolean") {
        throw new Error("overwrite must be a boolean");
    }
    const overwrite = body.overwrite === true;
    return {
        cwd,
        fromPath,
        toPath,
        overwrite,
        receipt: receipt(body, RUNTIME_COMMAND_KINDS.moveWorkspaceFile, { cwd, fromPath, toPath, overwrite }),
    };
}

function receipt(
    body: { commandId?: unknown; runtimeEpoch?: unknown },
    kind: typeof RUNTIME_COMMAND_KINDS.writeWorkspaceFile | typeof RUNTIME_COMMAND_KINDS.deleteWorkspaceFile | typeof RUNTIME_COMMAND_KINDS.moveWorkspaceFile,
    payload: unknown,
) {
    return {
        commandId: requireRuntimeCommandId(body.commandId),
        kind,
        expectedRuntimeEpoch: requireRuntimeCommandEpoch(body.runtimeEpoch),
        fingerprint: runtimeCommandFingerprint({ kind, payload }),
    };
}

function requireCwd(value: unknown): string {
    return normalizeRequestCwd(value);
}

function requireString(value: unknown, name: string): string {
    if (typeof value !== "string") throw new Error(`${name} must be a string`);
    return value;
}

function errorMessage(error: unknown): string {
    return error instanceof Error ? error.message : String(error);
}
