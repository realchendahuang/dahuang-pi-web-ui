import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import type { Readable, Writable } from "node:stream";
import {
	encodeOmpRpcFrame,
	isOmpRpcReadyFrame,
	isOmpRpcResponseFrame,
	OMP_RPC_PROTOCOL_V1,
	OMP_RPC_PROTOCOL_V2,
	OmpRpcFrameDecoder,
	OmpRpcProtocolError,
	type OmpRpcFrame,
	type OmpRpcReadyFrame,
	type OmpRpcResponseFrame,
} from "./ompRpcProtocol.js";

const DEFAULT_COMMAND_TIMEOUT_MS = 30_000;
const DEFAULT_START_TIMEOUT_MS = 15_000;
const DEFAULT_CLOSE_TIMEOUT_MS = 5_000;
const STDERR_TAIL_BYTES = 64 * 1024;

export interface OmpRpcProcess {
	stdin: Writable;
	stdout: Readable;
	stderr: Readable;
	pid: number | undefined;
	exitCode: number | null;
	signalCode: NodeJS.Signals | null;
	kill(signal?: NodeJS.Signals): boolean;
	onError(listener: (error: Error) => void): void;
	onExit(
		listener: (code: number | null, signal: NodeJS.Signals | null) => void,
	): void;
}

export type SpawnOmpRpcProcess = (
	command: string,
	args: readonly string[],
	options: { cwd: string; env: NodeJS.ProcessEnv },
) => OmpRpcProcess;

export interface OmpRpcClientOptions {
	command: string;
	cwd: string;
	args?: readonly string[];
	env?: NodeJS.ProcessEnv;
	spawnProcess?: SpawnOmpRpcProcess;
	commandTimeoutMs?: number;
	startTimeoutMs?: number;
	closeTimeoutMs?: number;
}

interface PendingCommand {
	command: string;
	resolve: (response: OmpRpcResponseFrame) => void;
	reject: (error: Error) => void;
	timer: NodeJS.Timeout;
}

interface Deferred<T> {
	promise: Promise<T>;
	resolve: (value: T) => void;
	reject: (error: Error) => void;
	settled: boolean;
}

export class OmpRpcCommandError extends Error {
	constructor(
		readonly command: string,
		message: string,
	) {
		super(message);
		this.name = "OmpRpcCommandError";
	}
}

export class OmpRpcClient {
	readonly process: OmpRpcProcess;
	private readonly decoder = new OmpRpcFrameDecoder();
	private readonly pending = new Map<string, PendingCommand>();
	private readonly subscribers = new Set<(frame: OmpRpcFrame) => void>();
	private readonly failureSubscribers = new Set<(error: Error) => void>();
	private readonly ready = deferred<OmpRpcReadyFrame>();
	private readonly exited = deferred<{
		code: number | null;
		signal: NodeJS.Signals | null;
	}>();
	private readonly commandTimeoutMs: number;
	private readonly closeTimeoutMs: number;
	private protocolVersion = OMP_RPC_PROTOCOL_V1;
	private commandSequence = 0;
	private writeQueue: Promise<void> = Promise.resolve();
	private stderrBuffer = Buffer.alloc(0);
	private firstFrameSeen = false;
	private closing = false;
	private failurePublished = false;
	private failure: Error | undefined;

	private constructor(process: OmpRpcProcess, options: OmpRpcClientOptions) {
		this.process = process;
		this.commandTimeoutMs =
			options.commandTimeoutMs ?? DEFAULT_COMMAND_TIMEOUT_MS;
		this.closeTimeoutMs = options.closeTimeoutMs ?? DEFAULT_CLOSE_TIMEOUT_MS;
		process.stdout.on("data", (chunk: Buffer | string) => {
			this.consumeStdout(chunk);
		});
		process.stderr.on("data", (chunk: Buffer | string) => {
			this.captureStderr(chunk);
		});
		process.onError((error) => {
			this.fail(error);
		});
		process.onExit((code, signal) => {
			this.handleExit(code, signal);
		});
	}

	static async connect(options: OmpRpcClientOptions): Promise<OmpRpcClient> {
		const args = options.args ?? ["--mode", "rpc-ui", "--cwd", options.cwd];
		const spawnProcess = options.spawnProcess ?? defaultSpawnProcess;
		const process = spawnProcess(options.command, args, {
			cwd: options.cwd,
			env: options.env ?? processEnv(),
		});
		const client = new OmpRpcClient(process, options);
		try {
			const ready = await withTimeout(
				client.ready.promise,
				options.startTimeoutMs ?? DEFAULT_START_TIMEOUT_MS,
				"Timed out waiting for OMP RPC ready frame",
			);
			if (ready.supportedProtocolVersions.includes(OMP_RPC_PROTOCOL_V2)) {
				const response = await client.request("negotiate_protocol", {
					protocolVersion: OMP_RPC_PROTOCOL_V2,
				});
				const negotiated = response.data;
				if (
					!isRecord(negotiated) ||
					negotiated["protocolVersion"] !== OMP_RPC_PROTOCOL_V2
				) {
					throw new OmpRpcProtocolError(
						"OMP RPC protocol negotiation returned an invalid version",
					);
				}
				client.protocolVersion = OMP_RPC_PROTOCOL_V2;
			}
			return client;
		} catch (error) {
			await client.close().catch(() => undefined);
			throw error;
		}
	}

	get negotiatedProtocolVersion(): number {
		return this.protocolVersion;
	}

	get stderrTail(): string {
		return this.stderrBuffer.toString("utf8");
	}

	subscribe(listener: (frame: OmpRpcFrame) => void): () => void {
		this.subscribers.add(listener);
		return () => {
			this.subscribers.delete(listener);
		};
	}

	subscribeFailure(listener: (error: Error) => void): () => void {
		this.failureSubscribers.add(listener);
		if (this.failure !== undefined) listener(this.failure);
		return () => {
			this.failureSubscribers.delete(listener);
		};
	}

	send(frame: OmpRpcFrame): Promise<void> {
		this.assertUsable();
		return this.enqueueWrite(frame);
	}

	async request(
		command: string,
		fields: Record<string, unknown> = {},
		timeoutMs = this.commandTimeoutMs,
	): Promise<OmpRpcResponseFrame> {
		this.assertUsable();
		const id = `pi-web-${String(++this.commandSequence)}`;
		const response = new Promise<OmpRpcResponseFrame>((resolve, reject) => {
			const timer = setTimeout(() => {
				this.pending.delete(id);
				reject(
					new OmpRpcCommandError(
						command,
						`OMP RPC command timed out: ${command}`,
					),
				);
			}, timeoutMs);
			this.pending.set(id, { command, resolve, reject, timer });
		});

		try {
			await this.enqueueWrite({ id, type: command, ...fields });
		} catch (error) {
			const pending = this.pending.get(id);
			if (pending !== undefined) {
				clearTimeout(pending.timer);
				this.pending.delete(id);
				pending.reject(asError(error));
			}
		}
		return response;
	}

	async close(): Promise<void> {
		if (this.closing) {
			await this.exited.promise.catch(() => undefined);
			return;
		}
		this.closing = true;
		await this.writeQueue.catch(() => undefined);
		if (!this.process.stdin.destroyed) this.process.stdin.end();
		try {
			await withTimeout(
				this.exited.promise,
				this.closeTimeoutMs,
				"Timed out waiting for OMP RPC process to exit",
			);
		} catch {
			this.process.kill("SIGTERM");
			try {
				await withTimeout(
					this.exited.promise,
					this.closeTimeoutMs,
					"Timed out waiting for OMP RPC process after SIGTERM",
				);
			} catch {
				this.process.kill("SIGKILL");
				await this.exited.promise.catch(() => undefined);
			}
		}
	}

	private consumeStdout(chunk: Buffer | string): void {
		if (this.failure !== undefined) return;
		try {
			for (const frame of this.decoder.push(chunk)) this.handleFrame(frame);
		} catch (error) {
			this.fail(asError(error));
		}
	}

	private handleFrame(frame: OmpRpcFrame): void {
		if (!this.firstFrameSeen) {
			this.firstFrameSeen = true;
			if (!isOmpRpcReadyFrame(frame)) {
				this.fail(
					new OmpRpcProtocolError(
						"The first OMP RPC frame was not a valid ready frame",
					),
				);
				return;
			}
			if (frame.protocolVersion !== OMP_RPC_PROTOCOL_V1) {
				this.fail(
					new OmpRpcProtocolError("OMP RPC did not start in protocol v1"),
				);
				return;
			}
			this.ready.resolve(frame);
			this.publish(frame);
			return;
		}

		if (isOmpRpcResponseFrame(frame) && frame.id !== undefined) {
			const pending = this.pending.get(frame.id);
			if (pending !== undefined) {
				clearTimeout(pending.timer);
				this.pending.delete(frame.id);
				if (frame.success) pending.resolve(frame);
				else
					pending.reject(
						new OmpRpcCommandError(
							pending.command,
							frame.error ?? `OMP RPC command failed: ${pending.command}`,
						),
					);
				return;
			}
		}
		this.publish(frame);
	}

	private enqueueWrite(frame: OmpRpcFrame): Promise<void> {
		const encoded = encodeOmpRpcFrame(frame, this.protocolVersion);
		const write = this.writeQueue.then(async () => {
			for (const physical of encoded)
				await writeChunk(this.process.stdin, physical);
		});
		this.writeQueue = write.catch(() => undefined);
		return write;
	}

	private captureStderr(chunk: Buffer | string): void {
		const bytes =
			typeof chunk === "string"
				? Buffer.from(chunk, "utf8")
				: Buffer.from(chunk);
		this.stderrBuffer = Buffer.concat([this.stderrBuffer, bytes]);
		if (this.stderrBuffer.length > STDERR_TAIL_BYTES)
			this.stderrBuffer = this.stderrBuffer.subarray(
				this.stderrBuffer.length - STDERR_TAIL_BYTES,
			);
	}

	private handleExit(code: number | null, signal: NodeJS.Signals | null): void {
		try {
			this.decoder.finish();
		} catch (error) {
			this.failure ??= asError(error);
		}
		this.exited.resolve({ code, signal });
		const detail = this.stderrTail.trim();
		const unexpected = !this.closing || (code !== null && code !== 0);
		if (unexpected && this.failure === undefined) {
			this.failure = new Error(
				`OMP RPC process exited${code === null ? "" : ` with code ${String(code)}`}${signal === null ? "" : ` from ${signal}`}${detail === "" ? "" : `: ${detail}`}`,
			);
		}
		if (this.failure !== undefined) {
			this.rejectAll(this.failure);
			this.publishFailure(this.failure);
		} else this.rejectAll(new Error("OMP RPC process closed"));
		if (!this.ready.settled)
			this.ready.reject(
				this.failure ?? new Error("OMP RPC process exited before ready"),
			);
	}

	private fail(error: Error): void {
		if (this.failure !== undefined) return;
		this.failure = error;
		this.publishFailure(error);
		if (!this.ready.settled) this.ready.reject(error);
		this.rejectAll(error);
		if (!this.closing) this.process.kill("SIGTERM");
	}

	private rejectAll(error: Error): void {
		for (const pending of this.pending.values()) {
			clearTimeout(pending.timer);
			pending.reject(error);
		}
		this.pending.clear();
	}

	private publish(frame: OmpRpcFrame): void {
		for (const listener of this.subscribers) listener(frame);
	}

	private publishFailure(error: Error): void {
		if (this.failurePublished) return;
		this.failurePublished = true;
		for (const listener of this.failureSubscribers) listener(error);
	}

	private assertUsable(): void {
		if (this.failure !== undefined) throw this.failure;
		if (this.closing) throw new Error("OMP RPC client is closing");
	}
}

function defaultSpawnProcess(
	command: string,
	args: readonly string[],
	options: { cwd: string; env: NodeJS.ProcessEnv },
): OmpRpcProcess {
	const child: ChildProcessWithoutNullStreams = spawn(command, [...args], {
		cwd: options.cwd,
		env: options.env,
		shell: false,
		stdio: ["pipe", "pipe", "pipe"],
	});
	return {
		stdin: child.stdin,
		stdout: child.stdout,
		stderr: child.stderr,
		get pid() {
			return child.pid;
		},
		get exitCode() {
			return child.exitCode;
		},
		get signalCode() {
			return child.signalCode;
		},
		kill: (signal) => child.kill(signal),
		onError: (listener) => {
			child.once("error", listener);
		},
		onExit: (listener) => {
			child.once("exit", listener);
		},
	};
}

function processEnv(): NodeJS.ProcessEnv {
	return { ...process.env };
}

function writeChunk(stream: Writable, chunk: Buffer): Promise<void> {
	return new Promise((resolve, reject) => {
		stream.write(chunk, (error) => {
			if (error !== null && error !== undefined) reject(error);
			else resolve();
		});
	});
}

function deferred<T>(): Deferred<T> {
	let resolvePromise: ((value: T) => void) | undefined;
	let rejectPromise: ((error: Error) => void) | undefined;
	const result: Deferred<T> = {
		promise: new Promise<T>((resolve, reject) => {
			resolvePromise = resolve;
			rejectPromise = reject;
		}),
		resolve(value) {
			if (result.settled) return;
			result.settled = true;
			resolvePromise?.(value);
		},
		reject(error) {
			if (result.settled) return;
			result.settled = true;
			rejectPromise?.(error);
		},
		settled: false,
	};
	return result;
}

async function withTimeout<T>(
	promise: Promise<T>,
	timeoutMs: number,
	message: string,
): Promise<T> {
	let timer: NodeJS.Timeout | undefined;
	try {
		return await Promise.race([
			promise,
			new Promise<never>((_resolve, reject) => {
				timer = setTimeout(() => {
					reject(new Error(message));
				}, timeoutMs);
			}),
		]);
	} finally {
		if (timer !== undefined) clearTimeout(timer);
	}
}

function asError(value: unknown): Error {
	return value instanceof Error ? value : new Error(String(value));
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}
