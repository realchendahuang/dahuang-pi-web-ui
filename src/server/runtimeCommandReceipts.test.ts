import { describe, expect, it } from "vitest";
import {
	RUNTIME_COMMAND_KINDS,
	RuntimeCommandReceipts,
	requireRuntimeCommandId,
} from "./runtimeCommandReceipts.js";

describe("RuntimeCommandReceipts", () => {
	it("shares one in-flight action and returns the same receipt for retry", async () => {
		let calls = 0;
		const ticks = ["2026-08-04T00:00:00.000Z", "2026-08-04T00:00:01.000Z"];
		const receipts = new RuntimeCommandReceipts(
			"epoch-1",
			() => new Date(ticks.shift() ?? "2026-08-04T00:00:01.000Z"),
		);
		const action = async () => {
			calls += 1;
			await Promise.resolve();
			return { requested: 1, aborted: [{ sessionId: "s1", runtimeId: "pi" }], failures: [] };
		};

		const [first, retry] = await Promise.all([
			receipts.execute(
				{
					commandId: "command-1",
					kind: RUNTIME_COMMAND_KINDS.abortActiveWork,
					expectedRuntimeEpoch: "epoch-1",
					fingerprint: "abort",
				},
				action,
			),
			receipts.execute(
				{
					commandId: "command-1",
					kind: RUNTIME_COMMAND_KINDS.abortActiveWork,
					expectedRuntimeEpoch: "epoch-1",
					fingerprint: "abort",
				},
				action,
			),
		]);

		expect(calls).toBe(1);
		expect(first.runtimeEpoch).toBe("epoch-1");
		expect(retry).toEqual(first);
		await expect(receipts.get("command-1")).resolves.toEqual(first);
	});

	it("records an operational failure instead of making retry ambiguous", async () => {
		const receipts = new RuntimeCommandReceipts(
			"epoch-1",
			() => new Date("2026-08-04T00:00:00.000Z"),
		);
		const receipt = await receipts.execute(
			{
				commandId: "command-2",
				kind: RUNTIME_COMMAND_KINDS.abortActiveWork,
				expectedRuntimeEpoch: "epoch-1",
				fingerprint: "abort",
			},
			() => Promise.reject(new Error("agent unavailable")),
		);

		expect(receipt).toMatchObject({ status: "failed", error: "agent unavailable" });
	});

	it("rejects stale epochs and commandId reuse with different intent", async () => {
		const receipts = new RuntimeCommandReceipts("epoch-1");
		expect(() =>
			receipts.execute(
				{
					commandId: "command-3",
					kind: RUNTIME_COMMAND_KINDS.prompt,
					expectedRuntimeEpoch: "epoch-0",
					fingerprint: "prompt-a",
				},
				() => Promise.resolve({ accepted: true as const, sessionId: "s1" }),
			),
		).toThrow("Runtime epoch changed");

		await receipts.execute(
			{
				commandId: "command-3",
				kind: RUNTIME_COMMAND_KINDS.prompt,
				expectedRuntimeEpoch: "epoch-1",
				fingerprint: "prompt-a",
			},
			() => Promise.resolve({ accepted: true as const, sessionId: "s1" }),
		);
		expect(() =>
			receipts.execute(
				{
					commandId: "command-3",
					kind: RUNTIME_COMMAND_KINDS.prompt,
					expectedRuntimeEpoch: "epoch-1",
					fingerprint: "prompt-b",
				},
				() => Promise.resolve({ accepted: true as const, sessionId: "s1" }),
			),
		).toThrow("different Runtime command");
	});
});

describe("requireRuntimeCommandId", () => {
	it("normalizes a valid id and rejects missing or oversized ids", () => {
		expect(requireRuntimeCommandId(" command-1 ")).toBe("command-1");
		expect(() => requireRuntimeCommandId(undefined)).toThrow("must be a string");
		expect(() => requireRuntimeCommandId("x".repeat(129))).toThrow("between 1 and 128");
	});
});
