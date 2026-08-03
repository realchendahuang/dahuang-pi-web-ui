import { PassThrough } from "node:stream";
import { describe, expect, it } from "vitest";
import { OmpRpcClient, type OmpRpcProcess } from "./ompRpcClient.js";
import { OmpRpcFrameDecoder, type OmpRpcFrame } from "./ompRpcProtocol.js";

describe("OmpRpcClient", () => {
	it("negotiates protocol v2 and correlates out-of-order command responses", async () => {
		const child = new FakeOmpProcess((frame, process) => {
			const id = stringField(frame, "id");
			const type = stringField(frame, "type");
			if (type === "negotiate_protocol") {
				process.send({
					id,
					type: "response",
					command: type,
					success: true,
					data: { protocolVersion: 2 },
				});
			} else if (type === "slow") {
				setTimeout(() => {
					process.send({
						id,
						type: "response",
						command: type,
						success: true,
						data: "slow",
					});
				}, 10);
			} else if (type === "fast") {
				process.send({
					id,
					type: "response",
					command: type,
					success: true,
					data: "fast",
				});
			}
		});
		child.sendReady();
		const client = await OmpRpcClient.connect(clientOptions(child));

		const slow = client.request("slow");
		const fast = client.request("fast");
		await expect(fast).resolves.toMatchObject({ data: "fast" });
		await expect(slow).resolves.toMatchObject({ data: "slow" });
		expect(client.negotiatedProtocolVersion).toBe(2);

		await client.close();
		expect(child.exitCode).toBe(0);
	});

	it("publishes non-response frames and rejects failed commands", async () => {
		const child = new FakeOmpProcess((frame, process) => {
			const id = stringField(frame, "id");
			const type = stringField(frame, "type");
			if (type === "negotiate_protocol") {
				process.send({
					id,
					type: "response",
					command: type,
					success: true,
					data: { protocolVersion: 2 },
				});
			} else {
				process.send({ type: "notice", message: "working" });
				process.send({
					id,
					type: "response",
					command: type,
					success: false,
					error: "denied",
				});
			}
		});
		child.sendReady();
		const client = await OmpRpcClient.connect(clientOptions(child));
		const events: OmpRpcFrame[] = [];
		client.subscribe((frame) => {
			events.push(frame);
		});

		await expect(client.request("dangerous")).rejects.toEqual(
			expect.objectContaining({
				command: "dangerous",
				message: "denied",
				name: "OmpRpcCommandError",
			}),
		);
		expect(events).toContainEqual({ type: "notice", message: "working" });
		await client.close();
	});

	it("rejects startup when the first frame is not ready", async () => {
		const child = new FakeOmpProcess(() => undefined);
		queueMicrotask(() => {
			child.send({ type: "notice" });
		});
		await expect(OmpRpcClient.connect(clientOptions(child))).rejects.toThrow(
			"first OMP RPC frame",
		);
	});

	it("fails pending commands with bounded stderr context on unexpected exit", async () => {
		const child = new FakeOmpProcess((frame, process) => {
			const type = stringField(frame, "type");
			if (type === "negotiate_protocol") {
				process.send({
					id: stringField(frame, "id"),
					type: "response",
					command: type,
					success: true,
					data: { protocolVersion: 2 },
				});
			} else {
				process.stderr.write("runtime exploded");
				process.exitUnexpectedly(17);
			}
		});
		child.sendReady();
		const client = await OmpRpcClient.connect(clientOptions(child));
		const failures: Error[] = [];
		client.subscribeFailure((error) => {
			failures.push(error);
		});
		await expect(client.request("explode")).rejects.toThrow("runtime exploded");
		expect(client.stderrTail).toContain("runtime exploded");
		expect(failures).toHaveLength(1);
		expect(failures[0]?.message).toContain("runtime exploded");
	});
});

class FakeOmpProcess implements OmpRpcProcess {
	readonly stdin = new PassThrough();
	readonly stdout = new PassThrough();
	readonly stderr = new PassThrough();
	readonly pid = 1234;
	exitCode: number | null = null;
	signalCode: NodeJS.Signals | null = null;
	private readonly decoder = new OmpRpcFrameDecoder();
	private readonly errorListeners = new Set<(error: Error) => void>();
	private readonly exitListeners = new Set<
		(code: number | null, signal: NodeJS.Signals | null) => void
	>();
	private exited = false;

	constructor(
		private readonly onFrame: (
			frame: OmpRpcFrame,
			process: FakeOmpProcess,
		) => void,
	) {
		this.stdin.on("data", (chunk: Buffer) => {
			for (const frame of this.decoder.push(chunk)) this.onFrame(frame, this);
		});
		this.stdin.on("finish", () => {
			this.finishExit(0, null);
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
		this.finishExit(null, signal);
		return true;
	}

	exitUnexpectedly(code: number): void {
		this.finishExit(code, null);
	}

	private finishExit(code: number | null, signal: NodeJS.Signals | null): void {
		if (this.exited) return;
		this.exited = true;
		this.exitCode = code;
		this.signalCode = signal;
		this.stdout.end();
		this.stderr.end();
		for (const listener of this.exitListeners) listener(code, signal);
		this.exitListeners.clear();
		this.errorListeners.clear();
	}
}

function clientOptions(child: FakeOmpProcess) {
	return {
		command: "omp",
		cwd: "/repo",
		spawnProcess: () => child,
		startTimeoutMs: 1_000,
		commandTimeoutMs: 1_000,
		closeTimeoutMs: 100,
	};
}

function stringField(frame: OmpRpcFrame, key: string): string {
	const value = frame[key];
	if (typeof value !== "string")
		throw new Error(`Expected string field ${key}`);
	return value;
}
