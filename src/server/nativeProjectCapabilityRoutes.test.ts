import { mkdtemp, mkdir, realpath, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import Fastify, { type FastifyInstance } from "fastify";
import fastifyWebsocket from "@fastify/websocket";
import { afterEach, describe, expect, it } from "vitest";
import { WebSocket } from "ws";
import { NativeProjectCapabilityService } from "./nativeProjectCapability.js";
import { registerNativeProjectCapabilityRoutes } from "./nativeProjectCapabilityRoutes.js";
import { RuntimeCommandReceipts } from "./runtimeCommandReceipts.js";

const roots: string[] = [];

afterEach(async () => {
	await Promise.all(roots.splice(0).map((root) => {
		return rm(root, { recursive: true, force: true });
	}));
});

describe("bundled Runtime project capability routes", () => {
	it("requires a token, authorizes an explicit root receipt-safely, and guards every cwd", async () => {
		const root = await fixtureRoot();
		const project = join(root, "project");
		const nested = join(project, "nested");
		const sibling = join(root, "project-other");
		await Promise.all([mkdir(nested, { recursive: true }), mkdir(sibling)]);
		const app = createApp(new NativeProjectCapabilityService("token-1"));
		try {
			const encodedProject = encodeURIComponent(project);
			expect((await app.inject({ method: "GET", url: `/sessions?cwd=${encodedProject}` })).statusCode).toBe(401);
			expect((await app.inject({ method: "GET", url: `/runtime/commands/test` })).statusCode).toBe(401);

			const beforeAuthorization = await app.inject({
				method: "GET", url: `/sessions?cwd=${encodedProject}`, headers: capabilityHeader(),
			});
			expect(beforeAuthorization.statusCode).toBe(403);

			const first = await app.inject({
				method: "POST", url: "/runtime/projects/authorize", headers: capabilityHeader(),
				payload: { path: project, commandId: "authorize-1", runtimeEpoch: "epoch-1" },
			});
			const retry = await app.inject({
				method: "POST", url: "/runtime/projects/authorize", headers: capabilityHeader(),
				payload: { path: project, commandId: "authorize-1", runtimeEpoch: "epoch-1" },
			});
			expect(first.statusCode).toBe(200);
			expect(first.json()).toMatchObject({
				kind: "authorize-project", status: "completed",
				result: { authorized: true, path: await realpath(project) },
			});
			expect(retry.json()).toEqual(first.json());

			const conflict = await app.inject({
				method: "POST", url: "/runtime/projects/authorize", headers: capabilityHeader(),
				payload: { path: nested, commandId: "authorize-1", runtimeEpoch: "epoch-1" },
			});
			expect(conflict.statusCode).toBe(409);

			expect((await app.inject({
				method: "GET", url: `/sessions?cwd=${encodeURIComponent(nested)}`, headers: capabilityHeader(),
			})).statusCode).toBe(200);
			expect((await app.inject({
				method: "POST", url: "/mutate", headers: capabilityHeader(), payload: { cwd: sibling },
			})).statusCode).toBe(403);
		} finally {
			await app.close();
		}
	});

	it("leaves only health and protocol hello usable before App authentication", async () => {
		const app = createApp(new NativeProjectCapabilityService("token-1"));
		try {
			expect((await app.inject({ method: "GET", url: "/health" })).statusCode).toBe(200);
			expect((await app.inject({ method: "GET", url: "/runtime/hello?probe=1" })).statusCode).toBe(200);
			expect((await app.inject({ method: "GET", url: "/healthcheck" })).statusCode).toBe(401);
		} finally {
			await app.close();
		}
	});

	it("does not add the production guard to an un-tokened development daemon", async () => {
		const app = createApp(undefined);
		try {
			expect((await app.inject({ method: "GET", url: "/sessions?cwd=/development/repo" })).statusCode).toBe(200);
			expect((await app.inject({ method: "POST", url: "/mutate", payload: { cwd: "/development/repo" } })).statusCode).toBe(200);
			expect((await app.inject({ method: "POST", url: "/runtime/projects/authorize", payload: {} })).statusCode).toBe(404);
		} finally {
			await app.close();
		}
	});

	it("accepts the private capability header on an authorized WebSocket event stream", async () => {
		const root = await fixtureRoot();
		const project = join(root, "project");
		await mkdir(project);
		const app = Fastify({ logger: false });
		await app.register(fastifyWebsocket);
		const capabilities = new NativeProjectCapabilityService("token-1");
		registerNativeProjectCapabilityRoutes(app, capabilities, new RuntimeCommandReceipts("epoch-1"));
		app.get("/events", { websocket: true }, (socket) => {
			socket.send(JSON.stringify({ type: "ready" }));
		});
		await app.listen({ host: "127.0.0.1", port: 0 });
		try {
			const authorize = await app.inject({
				method: "POST", url: "/runtime/projects/authorize", headers: capabilityHeader(),
				payload: { path: project, commandId: "authorize-stream", runtimeEpoch: "epoch-1" },
			});
			expect(authorize.statusCode).toBe(200);

			const socket = new WebSocket(`${serverUrl(app)}/events?cwd=${encodeURIComponent(project)}`, {
				headers: capabilityHeader(),
			});
			await expect(nextMessage(socket)).resolves.toBe(JSON.stringify({ type: "ready" }));
			socket.close();
		} finally {
			await app.close();
		}
	});
});

function createApp(capabilities: NativeProjectCapabilityService | undefined): FastifyInstance {
	const app = Fastify({ logger: false });
	registerNativeProjectCapabilityRoutes(app, capabilities, new RuntimeCommandReceipts("epoch-1"));
	app.get("/health", () => ({ ok: true }));
	app.get("/runtime/hello", () => ({ protocol: 1 }));
	app.get("/sessions", () => []);
	app.get("/runtime/commands/:id", () => ({ receipt: true }));
	app.post("/mutate", () => ({ mutated: true }));
	app.get("/healthcheck", () => ({ shouldNotBePublic: true }));
	return app;
}

function capabilityHeader(): Record<string, string> {
	return { "x-pi-agent-project-capability": "token-1" };
}

async function fixtureRoot(): Promise<string> {
	const root = await mkdtemp(join(tmpdir(), "pi-agent-capability-routes-"));
	roots.push(root);
	return root;
}

function serverUrl(app: FastifyInstance): string {
	const address = app.server.address();
	if (address === null || typeof address === "string") {
		throw new Error("Test server did not bind a TCP address");
	}
	return `ws://127.0.0.1:${String(address.port)}`;
}

function nextMessage(socket: WebSocket): Promise<string> {
	return new Promise((resolve, reject) => {
		const timeout = setTimeout(() => {
			reject(new Error("WebSocket did not emit a message"));
		}, 5_000);
		socket.once("message", (data) => {
			clearTimeout(timeout);
			resolve(rawDataText(data));
		});
		socket.once("error", (error) => {
			clearTimeout(timeout);
			reject(error);
		});
	});
}

function rawDataText(data: import("ws").RawData): string {
	if (Array.isArray(data)) return Buffer.concat(data).toString();
	if (data instanceof ArrayBuffer) return Buffer.from(data).toString();
	return data.toString();
}
