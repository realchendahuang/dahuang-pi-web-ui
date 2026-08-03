import { randomUUID } from "node:crypto";

export const OMP_RPC_PROTOCOL_V1 = 1;
export const OMP_RPC_PROTOCOL_V2 = 2;
export const OMP_RPC_MAX_FRAME_BYTES = 1024 * 1024;
export const OMP_RPC_MAX_REASSEMBLED_FRAME_BYTES = 64 * 1024 * 1024;
export const OMP_RPC_CHUNK_BYTES = 256 * 1024;

export type OmpRpcFrame = Record<string, unknown>;

export interface OmpRpcReadyFrame extends OmpRpcFrame {
	type: "ready";
	protocolVersion: number;
	supportedProtocolVersions: number[];
	maxFrameBytes: number;
	maxReassembledFrameBytes: number;
}

export interface OmpRpcResponseFrame extends OmpRpcFrame {
	type: "response";
	command: string;
	success: boolean;
	id?: string;
	data?: unknown;
	error?: string;
}

interface OmpRpcChunkFrame extends OmpRpcFrame {
	type: "rpc_chunk";
	chunkId: string;
	index: number;
	count: number;
	byteLength: number;
	data: string;
}

interface PendingChunks {
	chunkId: string;
	count: number;
	byteLength: number;
	chunks: Buffer[];
}

export class OmpRpcProtocolError extends Error {
	constructor(message: string, options?: ErrorOptions) {
		super(message, options);
		this.name = "OmpRpcProtocolError";
	}
}

export class OmpRpcFrameDecoder {
	private buffered = Buffer.alloc(0);
	private pendingChunks: PendingChunks | undefined;

	push(chunk: Uint8Array | string): OmpRpcFrame[] {
		const bytes =
			typeof chunk === "string"
				? Buffer.from(chunk, "utf8")
				: Buffer.from(chunk);
		this.buffered =
			this.buffered.length === 0
				? bytes
				: Buffer.concat([this.buffered, bytes]);
		if (
			this.buffered.length > OMP_RPC_MAX_FRAME_BYTES &&
			this.buffered.indexOf(0x0a) === -1
		) {
			throw new OmpRpcProtocolError("OMP RPC physical frame exceeds 1 MiB");
		}

		const frames: OmpRpcFrame[] = [];
		for (;;) {
			const newline = this.buffered.indexOf(0x0a);
			if (newline === -1) break;
			const physicalBytes = newline + 1;
			if (physicalBytes > OMP_RPC_MAX_FRAME_BYTES)
				throw new OmpRpcProtocolError("OMP RPC physical frame exceeds 1 MiB");
			let line = this.buffered.subarray(0, newline);
			this.buffered = this.buffered.subarray(newline + 1);
			if (line.at(-1) === 0x0d) line = line.subarray(0, line.length - 1);
			if (line.length === 0) continue;
			const frame = parseFrame(line);
			const logicalFrame = this.consumeFrame(frame);
			if (logicalFrame !== undefined) frames.push(logicalFrame);
		}
		return frames;
	}

	finish(): void {
		if (this.buffered.length > 0)
			throw new OmpRpcProtocolError(
				"OMP RPC stdout ended with an incomplete frame",
			);
		if (this.pendingChunks !== undefined)
			throw new OmpRpcProtocolError(
				"OMP RPC stdout ended with an incomplete chunk sequence",
			);
	}

	private consumeFrame(frame: OmpRpcFrame): OmpRpcFrame | undefined {
		if (!isOmpRpcChunkFrame(frame)) {
			if (this.pendingChunks !== undefined)
				throw new OmpRpcProtocolError("OMP RPC chunk sequence was interrupted");
			return frame;
		}

		const decoded = decodeBase64(frame.data);
		if (this.pendingChunks === undefined) {
			validateInitialChunk(frame);
			this.pendingChunks = {
				chunkId: frame.chunkId,
				count: frame.count,
				byteLength: frame.byteLength,
				chunks: [],
			};
		}

		const pending = this.pendingChunks;
		if (
			frame.chunkId !== pending.chunkId ||
			frame.count !== pending.count ||
			frame.byteLength !== pending.byteLength
		) {
			throw new OmpRpcProtocolError(
				"OMP RPC chunk metadata changed during reassembly",
			);
		}
		if (frame.index !== pending.chunks.length)
			throw new OmpRpcProtocolError("OMP RPC chunks arrived out of order");
		pending.chunks.push(decoded);
		if (pending.chunks.length < pending.count) return undefined;

		const payload = Buffer.concat(pending.chunks);
		this.pendingChunks = undefined;
		if (payload.length !== pending.byteLength)
			throw new OmpRpcProtocolError(
				"OMP RPC reassembled byte length does not match metadata",
			);
		return parseFrame(payload);
	}
}

export function encodeOmpRpcFrame(
	frame: OmpRpcFrame,
	protocolVersion = OMP_RPC_PROTOCOL_V1,
): Buffer[] {
	const payload = Buffer.from(JSON.stringify(frame), "utf8");
	if (payload.length + 1 <= OMP_RPC_MAX_FRAME_BYTES)
		return [Buffer.concat([payload, Buffer.from("\n")])];
	if (protocolVersion < OMP_RPC_PROTOCOL_V2)
		throw new OmpRpcProtocolError(
			"OMP RPC v1 command exceeds the 1 MiB frame limit",
		);
	if (payload.length > OMP_RPC_MAX_REASSEMBLED_FRAME_BYTES)
		throw new OmpRpcProtocolError(
			"OMP RPC command exceeds the 64 MiB logical frame limit",
		);

	const count = Math.ceil(payload.length / OMP_RPC_CHUNK_BYTES);
	const chunkId = `pi-web-${randomUUID()}`;
	return Array.from({ length: count }, (_, index) => {
		const start = index * OMP_RPC_CHUNK_BYTES;
		const chunk: OmpRpcChunkFrame = {
			type: "rpc_chunk",
			chunkId,
			index,
			count,
			byteLength: payload.length,
			data: payload
				.subarray(start, Math.min(start + OMP_RPC_CHUNK_BYTES, payload.length))
				.toString("base64"),
		};
		const physical = Buffer.from(`${JSON.stringify(chunk)}\n`, "utf8");
		if (physical.length > OMP_RPC_MAX_FRAME_BYTES)
			throw new OmpRpcProtocolError(
				"Encoded OMP RPC chunk exceeds the physical frame limit",
			);
		return physical;
	});
}

export function isOmpRpcReadyFrame(
	frame: OmpRpcFrame,
): frame is OmpRpcReadyFrame {
	return (
		frame["type"] === "ready" &&
		Number.isInteger(frame["protocolVersion"]) &&
		Array.isArray(frame["supportedProtocolVersions"]) &&
		frame["supportedProtocolVersions"].every((version) =>
			Number.isInteger(version),
		) &&
		Number.isInteger(frame["maxFrameBytes"]) &&
		Number.isInteger(frame["maxReassembledFrameBytes"])
	);
}

export function isOmpRpcResponseFrame(
	frame: OmpRpcFrame,
): frame is OmpRpcResponseFrame {
	return (
		frame["type"] === "response" &&
		typeof frame["command"] === "string" &&
		typeof frame["success"] === "boolean" &&
		(frame["id"] === undefined || typeof frame["id"] === "string") &&
		(frame["error"] === undefined || typeof frame["error"] === "string")
	);
}

function isOmpRpcChunkFrame(frame: OmpRpcFrame): frame is OmpRpcChunkFrame {
	return (
		frame["type"] === "rpc_chunk" &&
		typeof frame["chunkId"] === "string" &&
		Number.isInteger(frame["index"]) &&
		Number.isInteger(frame["count"]) &&
		Number.isInteger(frame["byteLength"]) &&
		typeof frame["data"] === "string"
	);
}

function validateInitialChunk(frame: OmpRpcChunkFrame): void {
	const maxChunkCount = Math.ceil(
		OMP_RPC_MAX_REASSEMBLED_FRAME_BYTES / OMP_RPC_CHUNK_BYTES,
	);
	if (frame.index !== 0)
		throw new OmpRpcProtocolError(
			"OMP RPC chunk sequence must start at index zero",
		);
	if (frame.count < 2 || frame.count > maxChunkCount)
		throw new OmpRpcProtocolError("OMP RPC chunk count is invalid");
	if (
		frame.byteLength < OMP_RPC_MAX_FRAME_BYTES ||
		frame.byteLength > OMP_RPC_MAX_REASSEMBLED_FRAME_BYTES
	) {
		throw new OmpRpcProtocolError("OMP RPC chunk byte length is invalid");
	}
}

function parseFrame(bytes: Uint8Array): OmpRpcFrame {
	let text: string;
	try {
		text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
	} catch (error) {
		throw new OmpRpcProtocolError("OMP RPC frame is not valid UTF-8", {
			cause: error,
		});
	}

	let value: unknown;
	try {
		value = JSON.parse(text);
	} catch (error) {
		throw new OmpRpcProtocolError("OMP RPC frame is not valid JSON", {
			cause: error,
		});
	}
	if (!isRecord(value))
		throw new OmpRpcProtocolError("OMP RPC frame must be a JSON object");
	return value;
}

function decodeBase64(value: string): Buffer {
	if (
		value.length === 0 ||
		value.length % 4 !== 0 ||
		!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/u.test(
			value,
		)
	) {
		throw new OmpRpcProtocolError("OMP RPC chunk data is not canonical base64");
	}
	const decoded = Buffer.from(value, "base64");
	if (decoded.toString("base64") !== value)
		throw new OmpRpcProtocolError("OMP RPC chunk data is not canonical base64");
	return decoded;
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}
