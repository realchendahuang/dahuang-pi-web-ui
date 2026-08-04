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
			() => new Date(ticks.shift() ?? "2026-08-04T00:00:01.000Z"),
		);
		const action = async () => {
			calls += 1;
			await Promise.resolve();
			return { requested: 1, aborted: [{ sessionId: "s1", runtimeId: "pi" }], failures: [] };
		};

		const [first, retry] = await Promise.all([
			receipts.execute("command-1", RUNTIME_COMMAND_KINDS.abortActiveWork, action),
			receipts.execute("command-1", RUNTIME_COMMAND_KINDS.abortActiveWork, action),
		]);

		expect(calls).toBe(1);
		expect(retry).toEqual(first);
		await expect(receipts.get("command-1")).resolves.toEqual(first);
	});

	it("records an operational failure instead of making retry ambiguous", async () => {
		const receipts = new RuntimeCommandReceipts(() => new Date("2026-08-04T00:00:00.000Z"));
		const receipt = await receipts.execute(
			"command-2",
			RUNTIME_COMMAND_KINDS.abortActiveWork,
			async () => Promise.reject(new Error("agent unavailable")),
		);

		expect(receipt).toMatchObject({ status: "failed", error: "agent unavailable" });
	});
});

describe("requireRuntimeCommandId", () => {
	it("normalizes a valid id and rejects missing or oversized ids", () => {
		expect(requireRuntimeCommandId(" command-1 ")).toBe("command-1");
		expect(() => requireRuntimeCommandId(undefined)).toThrow("must be a string");
		expect(() => requireRuntimeCommandId("x".repeat(129))).toThrow("between 1 and 128");
	});
});
