import { PassThrough } from "node:stream";
import { describe, expect, it, vi } from "vitest";
import type { OmpRpcProcess } from "./ompRpcClient.js";
import { OmpRpcFrameDecoder, type OmpRpcFrame } from "./ompRpcProtocol.js";
import {
	OmpSessionRuntime,
	ompFrameToSessionEvent,
} from "./ompSessionRuntime.js";

describe("OmpSessionRuntime", () => {
	it("maps OMP agent stream events into runtime-neutral session events", () => {
		expect(
			ompFrameToSessionEvent({
				type: "message_update",
				message: { role: "assistant", content: [] },
				assistantMessageEvent: { type: "text_delta", delta: "hello" },
			}),
		).toEqual({ type: "assistant.delta", text: "hello" });

		expect(
			ompFrameToSessionEvent({
				type: "tool_execution_end",
				toolName: "read",
				toolCallId: "tool-1",
				result: { content: "contents", details: { path: "README.md" } },
				isError: false,
			}),
		).toEqual({
			type: "tool.end",
			toolName: "read",
			toolCallId: "tool-1",
			text: "contents",
			content: "contents",
			details: { path: "README.md" },
			isError: false,
		});

		expect(
			ompFrameToSessionEvent({
				type: "subagent_progress",
				subagentId: "child-1",
			}),
		).toEqual({
			type: "runtime.event",
			runtimeId: "omp",
			eventType: "subagent_progress",
			event: { type: "subagent_progress", subagentId: "child-1" },
		});
	});

	it("loads OMP state, messages, models, commands, and emits live events", async () => {
		const child = new FakeOmpRuntimeProcess();
		const onEvent = vi.fn();
		child.sendReady();
		const runtime = await OmpSessionRuntime.start({
			command: "omp",
			agentDir: "/profiles/omp",
			cwd: "/repo",
			clientOptions: {
				spawnProcess: (_command, _args, options) => {
					expect(options.env["PI_CODING_AGENT_DIR"]).toBe("/profiles/omp");
					return child;
				},
				startTimeoutMs: 1_000,
				commandTimeoutMs: 1_000,
				closeTimeoutMs: 100,
			},
			onEvent,
		});

		expect(runtime.identity).toEqual({
			sessionId: "omp-session",
			sessionFile: "/profiles/omp/sessions/repo/session.jsonl",
			sessionName: "OMP task",
			cwd: "/repo",
		});
		expect(runtime.status()).toMatchObject({
			runtimeId: "omp",
			sessionId: "omp-session",
			persisted: false,
			model: { provider: "openai", id: "gpt-test", name: "GPT Test" },
			thinkingLevel: "high",
			messageCount: 2,
			tokens: { input: 11, output: 7, total: 18 },
			cost: 0.25,
		});
		await expect(runtime.messages()).resolves.toEqual({
			messages: [
				{ role: "user", content: "hello" },
				{ role: "assistant", content: "hi" },
			],
			start: 0,
			total: 2,
		});
		await expect(runtime.availableModels()).resolves.toEqual([
			expect.objectContaining({
				provider: "openai",
				id: "gpt-test",
				name: "GPT Test",
			}),
		]);
		await expect(runtime.commands()).resolves.toEqual([
			{ name: "compact", description: "Compact context", source: "builtin" },
		]);

		child.send({ type: "agent_start" });
		child.send({
			type: "message_update",
			message: {
				role: "assistant",
				content: [{ type: "text", text: "partial" }],
			},
			assistantMessageEvent: { type: "text_delta", delta: "partial" },
		});
		await vi.waitFor(() => {
			expect(onEvent).toHaveBeenCalledWith({ type: "agent.start" });
			expect(onEvent).toHaveBeenCalledWith({
				type: "assistant.delta",
				text: "partial",
			});
		});
		expect(runtime.streamSnapshot(9)).toEqual({
			seq: 9,
			partial: {
				role: "assistant",
				content: [{ type: "text", text: "partial" }],
			},
		});

		await runtime.close();
	});
});

class FakeOmpRuntimeProcess implements OmpRpcProcess {
	readonly stdin = new PassThrough();
	readonly stdout = new PassThrough();
	readonly stderr = new PassThrough();
	readonly pid = 42;
	exitCode: number | null = null;
	signalCode: NodeJS.Signals | null = null;
	private readonly decoder = new OmpRpcFrameDecoder();
	private readonly errorListeners = new Set<(error: Error) => void>();
	private readonly exitListeners = new Set<
		(code: number | null, signal: NodeJS.Signals | null) => void
	>();
	private state = {
		sessionId: "omp-session",
		sessionFile: "/profiles/omp/sessions/repo/session.jsonl",
		sessionName: "OMP task",
		model: {
			provider: "openai",
			id: "gpt-test",
			name: "GPT Test",
			contextWindow: 100_000,
			reasoning: true,
		},
		thinkingLevel: "high",
		isStreaming: false,
		isCompacting: false,
		queuedMessageCount: 0,
		messageCount: 2,
		contextUsage: { tokens: 18, contextWindow: 100_000, percent: 0.018 },
	};

	constructor() {
		this.stdin.on("data", (chunk: Buffer) => {
			for (const frame of this.decoder.push(chunk)) this.handle(frame);
		});
		this.stdin.on("finish", () => {
			this.finish(0, null);
		});
	}

	onError(listener: (error: Error) => void): void {
		this.errorListeners.add(listener);
	}

	onExit(
		listener: (code: number | null, signal: NodeJS.Signals | null) => void,
	): void {
		this.exitListeners.add(listener);
	}

	sendReady(): void {
		queueMicrotask(() => {
			this.send({
				type: "ready",
				protocolVersion: 1,
				supportedProtocolVersions: [1, 2],
				maxFrameBytes: 1024 * 1024,
				maxReassembledFrameBytes: 64 * 1024 * 1024,
			});
		});
	}

	send(frame: OmpRpcFrame): void {
		this.stdout.write(`${JSON.stringify(frame)}\n`);
	}

	kill(signal: NodeJS.Signals = "SIGTERM"): boolean {
		this.finish(null, signal);
		return true;
	}

	private handle(frame: OmpRpcFrame): void {
		const id = stringField(frame, "id");
		const command = stringField(frame, "type");
		switch (command) {
			case "negotiate_protocol":
				this.respond(id, command, { protocolVersion: 2 });
				break;
			case "get_state":
				this.respond(id, command, this.state);
				break;
			case "get_session_stats":
				this.respond(id, command, {
					tokens: {
						input: 11,
						output: 7,
						cacheRead: 0,
						cacheWrite: 0,
						total: 18,
					},
					cost: 0.25,
				});
				break;
			case "get_messages":
				this.respond(id, command, {
					messages: [
						{ role: "user", content: "hello" },
						{ role: "assistant", content: "hi" },
					],
				});
				break;
			case "get_available_models":
				this.respond(id, command, { models: [this.state.model] });
				break;
			case "get_available_commands":
				this.respond(id, command, {
					commands: [
						{
							name: "compact",
							description: "Compact context",
							source: "builtin",
						},
					],
				});
				break;
			default:
				this.respond(id, command, {});
		}
	}

	private respond(id: string, command: string, data: unknown): void {
		this.send({ id, type: "response", command, success: true, data });
	}

	private finish(code: number | null, signal: NodeJS.Signals | null): void {
		if (this.exitCode !== null || this.signalCode !== null) return;
		this.exitCode = code;
		this.signalCode = signal;
		this.stdout.end();
		this.stderr.end();
		for (const listener of this.exitListeners) listener(code, signal);
		this.errorListeners.clear();
		this.exitListeners.clear();
	}
}

function stringField(frame: OmpRpcFrame, key: string): string {
	const value = frame[key];
	if (typeof value !== "string") throw new Error(`Expected ${key}`);
	return value;
}
