import { describe, expect, it } from "vitest";
import {
	encodeOmpRpcFrame,
	OMP_RPC_MAX_FRAME_BYTES,
	OmpRpcFrameDecoder,
	OmpRpcProtocolError,
} from "./ompRpcProtocol.js";

describe("OMP RPC framing", () => {
	it("decodes fragmented JSONL, CRLF, and blank lines", () => {
		const decoder = new OmpRpcFrameDecoder();
		expect(decoder.push('\r\n{"type":"ready",')).toEqual([]);
		expect(decoder.push('"protocolVersion":1}\r\n{"type":"notice"}\n')).toEqual(
			[{ type: "ready", protocolVersion: 1 }, { type: "notice" }],
		);
		expect(() => {
			decoder.finish();
		}).not.toThrow();
	});

	it("round-trips v2 chunked logical frames", () => {
		const frame = {
			type: "response",
			id: "large",
			command: "get_messages",
			success: true,
			data: { text: "x".repeat(OMP_RPC_MAX_FRAME_BYTES + 1) },
		};
		const encoded = encodeOmpRpcFrame(frame, 2);
		expect(encoded.length).toBeGreaterThan(1);
		expect(
			encoded.every((physical) => physical.length <= OMP_RPC_MAX_FRAME_BYTES),
		).toBe(true);

		const decoder = new OmpRpcFrameDecoder();
		const decoded = encoded.flatMap((physical) => {
			const midpoint = Math.floor(physical.length / 2);
			return [
				...decoder.push(physical.subarray(0, midpoint)),
				...decoder.push(physical.subarray(midpoint)),
			];
		});
		decoder.finish();
		expect(decoded).toEqual([frame]);
	});

	it("rejects oversized v1 commands", () => {
		expect(() =>
			encodeOmpRpcFrame(
				{ type: "prompt", message: "x".repeat(OMP_RPC_MAX_FRAME_BYTES) },
				1,
			),
		).toThrow(OmpRpcProtocolError);
	});

	it("rejects interrupted and out-of-order chunk sequences", () => {
		const encoded = encodeOmpRpcFrame(
			{
				type: "response",
				command: "large",
				success: true,
				data: "x".repeat(OMP_RPC_MAX_FRAME_BYTES + 1),
			},
			2,
		);
		const interrupted = new OmpRpcFrameDecoder();
		interrupted.push(encoded[0] ?? Buffer.alloc(0));
		expect(() => interrupted.push('{"type":"notice"}\n')).toThrow(
			"chunk sequence was interrupted",
		);

		const outOfOrder = new OmpRpcFrameDecoder();
		const second = parsePhysicalChunk(encoded[1] ?? Buffer.alloc(0));
		second["index"] = 4;
		outOfOrder.push(encoded[0] ?? Buffer.alloc(0));
		expect(() => outOfOrder.push(`${JSON.stringify(second)}\n`)).toThrow(
			"out of order",
		);
	});

	it("rejects invalid JSON, UTF-8, and incomplete frames", () => {
		expect(() => new OmpRpcFrameDecoder().push("not-json\n")).toThrow(
			"valid JSON",
		);
		expect(() =>
			new OmpRpcFrameDecoder().push(Buffer.from([0xff, 0x0a])),
		).toThrow("valid UTF-8");
		const decoder = new OmpRpcFrameDecoder();
		decoder.push('{"type":"ready"}');
		expect(() => {
			decoder.finish();
		}).toThrow("incomplete frame");
	});
});

function parsePhysicalChunk(value: Buffer): Record<string, unknown> {
	const text = value.toString("utf8").trim();
	let parsed: unknown;
	try {
		parsed = JSON.parse(text);
	} catch (error) {
		throw new Error("Expected valid chunk JSON", { cause: error });
	}
	if (!isRecord(parsed)) throw new Error("Expected chunk object");
	return parsed;
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}
