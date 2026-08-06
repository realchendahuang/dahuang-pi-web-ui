import type { FastifyInstance, FastifyRequest } from "fastify";
import {
	RUNTIME_COMMAND_KINDS,
	RuntimeCommandReceipts,
	requireRuntimeCommandEpoch,
	requireRuntimeCommandId,
	runtimeCommandErrorStatus,
	runtimeCommandFingerprint,
} from "./runtimeCommandReceipts.js";
import {
	NATIVE_PROJECT_CAPABILITY_HEADER,
	NativeProjectCapabilityError,
	NativeProjectCapabilityService,
} from "./nativeProjectCapability.js";

/**
 * Registers the App-to-bundled-Runtime project boundary. It is intentionally
 * absent for the existing development/sessiond path, where no launch token is
 * supplied. The daemon therefore retains its compatibility contract while an
 * App-owned Runtime cannot widen access through a raw cwd.
 */
export function registerNativeProjectCapabilityRoutes(
	app: FastifyInstance,
	capabilities: NativeProjectCapabilityService | undefined,
	runtimeCommandReceipts: RuntimeCommandReceipts,
): void {
	if (capabilities === undefined) return;

	// preHandler runs after Fastify has parsed a JSON body, unlike onRequest.
	// That is required to apply the same cwd rule to GET query strings and
	// mutation bodies, while it remains early enough to protect every handler.
	app.addHook("preHandler", async (request, reply) => {
		if (isUnauthenticatedBootstrapPath(request)) return;
		try {
			capabilities.assertToken(request.headers[NATIVE_PROJECT_CAPABILITY_HEADER]);
			const cwd = cwdFromRequest(request.query, request.body);
			if (cwd !== undefined) await capabilities.assertAuthorizedCwd(cwd);
		} catch (error) {
			return reply.code(capabilityStatus(error)).send({
				error: error instanceof Error ? error.message : String(error),
			});
		}
	});

	app.post<{
		Body: { path?: unknown; commandId?: unknown; runtimeEpoch?: unknown };
	}>("/runtime/projects/authorize", async (request, reply) => {
		try {
			const commandId = requireRuntimeCommandId(request.body.commandId);
			const path = request.body.path;
			return await runtimeCommandReceipts.execute(
				{
					commandId,
					kind: RUNTIME_COMMAND_KINDS.authorizeProject,
					expectedRuntimeEpoch: requireRuntimeCommandEpoch(request.body.runtimeEpoch),
					fingerprint: runtimeCommandFingerprint({ path }),
				},
				async () => ({
					authorized: true as const,
					path: await capabilities.authorize(path),
				}),
			);
		} catch (error) {
			return reply.code(runtimeCommandErrorStatus(error) ?? capabilityStatus(error)).send({
				error: error instanceof Error ? error.message : String(error),
			});
		}
	});
}

function isUnauthenticatedBootstrapPath(request: FastifyRequest): boolean {
	const pathname = request.raw.url === undefined
		? request.url
		: new URL(request.raw.url, "http://pi-agent.local").pathname;
	return pathname === "/health" || pathname === "/runtime/hello";
}

function cwdFromRequest(query: unknown, body: unknown): unknown {
	return recordValue(query, "cwd") ?? recordValue(body, "cwd");
}

function recordValue(value: unknown, key: string): unknown {
	return isRecord(value) ? value[key] : undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

function capabilityStatus(error: unknown): 400 | 401 | 403 {
	return error instanceof NativeProjectCapabilityError ? error.statusCode : 400;
}
