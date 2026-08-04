import type { FastifyInstance } from "fastify";
import { normalizeRequestCwd } from "../workingDirectory.js";
import { readWorkspaceFile } from "./fileContentService.js";
import { listWorkspaceTree } from "./fileTreeService.js";

interface WorkspaceQuery {
    cwd?: string;
    path?: string;
}

/**
 * Native-only, read-only workspace projection. The selected project remains
 * the root of trust: callers provide an absolute cwd, which the bundled
 * Runtime's project-capability hook authorizes before these handlers run.
 *
 * Swift never reads the checkout directly. This preserves one ownership and
 * path-safety boundary for native files, Git, terminals, and Pi sessions.
 */
export function registerNativeWorkspaceRoutes(app: FastifyInstance): void {
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
}

function requireCwd(value: unknown): string {
    return normalizeRequestCwd(value);
}

function errorMessage(error: unknown): string {
    return error instanceof Error ? error.message : String(error);
}
