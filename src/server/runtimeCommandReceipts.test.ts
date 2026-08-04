import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
	FileRuntimeCommandReceiptPersistence,
	type PersistedRuntimeCommandRecord,
	RUNTIME_COMMAND_KINDS,
	type RuntimeCommandReceiptPersistence,
	RuntimeCommandReceipts,
	requireRuntimeCommandId,
	runtimeCommandFingerprint,
} from "./runtimeCommandReceipts.js";

const temporaryDirectories: string[] = [];

afterEach(async () => {
	await Promise.all(temporaryDirectories.splice(0).map((directory) => rm(directory, { recursive: true, force: true })));
});

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

	it("returns a persisted terminal receipt after a Runtime restart without replaying the action", async () => {
		const persistence = new MemoryRuntimeCommandReceiptPersistence();
		const firstRuntime = await RuntimeCommandReceipts.open({ runtimeEpoch: "epoch-1", persistence });
		const receipt = await firstRuntime.execute(
			{
				commandId: "command-restart",
				kind: RUNTIME_COMMAND_KINDS.prompt,
				expectedRuntimeEpoch: "epoch-1",
				fingerprint: "prompt-fingerprint",
			},
			() => Promise.resolve({ accepted: true as const, sessionId: "session-1" }),
		);

		const restartedRuntime = await RuntimeCommandReceipts.open({ runtimeEpoch: "epoch-2", persistence });
		let replayed = false;
		const recovered = await restartedRuntime.execute(
			{
				commandId: "command-restart",
				kind: RUNTIME_COMMAND_KINDS.prompt,
				expectedRuntimeEpoch: "epoch-1",
				fingerprint: "prompt-fingerprint",
			},
			() => {
				replayed = true;
				return Promise.resolve({ accepted: true as const, sessionId: "session-2" });
			},
		);

		expect(recovered).toEqual({ ...receipt, recoveredAfterRuntimeRestart: true });
		expect(replayed).toBe(false);
		expect(() => restartedRuntime.execute(
			{
				commandId: "command-restart",
				kind: RUNTIME_COMMAND_KINDS.prompt,
				expectedRuntimeEpoch: "epoch-1",
				fingerprint: "different-fingerprint",
			},
			() => Promise.resolve({ accepted: true as const, sessionId: "session-3" }),
		)).toThrow("different Runtime command");
	});

	it("converts an interrupted persisted intent into an explicit non-replayable failure", async () => {
		const persistence = new MemoryRuntimeCommandReceiptPersistence([
			{
				commandId: "command-interrupted",
				kind: RUNTIME_COMMAND_KINDS.prompt,
				fingerprint: "prompt-fingerprint",
				runtimeEpoch: "epoch-1",
				state: "started",
				startedAt: "2026-08-05T00:00:00.000Z",
			},
		]);
		const restartedRuntime = await RuntimeCommandReceipts.open({
			runtimeEpoch: "epoch-2",
			persistence,
			now: () => new Date("2026-08-05T00:00:01.000Z"),
		});
		let replayed = false;
		const receipt = await restartedRuntime.execute(
			{
				commandId: "command-interrupted",
				kind: RUNTIME_COMMAND_KINDS.prompt,
				expectedRuntimeEpoch: "epoch-1",
				fingerprint: "prompt-fingerprint",
			},
			() => {
				replayed = true;
				return Promise.resolve({ accepted: true as const, sessionId: "session-2" });
			},
		);

		expect(replayed).toBe(false);
		expect(receipt.status).toBe("failed");
		expect(receipt.runtimeEpoch).toBe("epoch-1");
		expect(receipt.error).toContain("not replayed");
		expect(persistence.records).toEqual([expect.objectContaining({ state: "failed" })]);
	});

	it("writes a bounded private ledger without retaining raw prompt payloads", async () => {
		const directory = await mkdtemp(join(tmpdir(), "pi-agent-command-receipts-"));
		temporaryDirectories.push(directory);
		const path = join(directory, "receipts.json");
		const persistence = new FileRuntimeCommandReceiptPersistence(path);
		const receipts = await RuntimeCommandReceipts.open({ runtimeEpoch: "epoch-1", persistence });
		const rawPrompt = "do not persist this prompt body";
		await receipts.execute(
			{
				commandId: "command-private",
				kind: RUNTIME_COMMAND_KINDS.prompt,
				expectedRuntimeEpoch: "epoch-1",
				fingerprint: runtimeCommandFingerprint({ text: rawPrompt }),
			},
			() => Promise.resolve({ accepted: true as const, sessionId: "session-1" }),
		);

		expect((await stat(path)).mode & 0o777).toBe(0o600);
		const contents = await readFile(path, "utf8");
		expect(contents).toContain("fingerprint");
		expect(contents).not.toContain(rawPrompt);
	});
});

class MemoryRuntimeCommandReceiptPersistence implements RuntimeCommandReceiptPersistence {
	constructor(public records: PersistedRuntimeCommandRecord[] = []) {}

	load(): Promise<PersistedRuntimeCommandRecord[]> { return Promise.resolve(structuredClone(this.records)); }
	save(records: readonly PersistedRuntimeCommandRecord[]): Promise<void> {
		this.records = structuredClone([...records]);
		return Promise.resolve();
	}
}

describe("requireRuntimeCommandId", () => {
	it("normalizes a valid id and rejects missing or oversized ids", () => {
		expect(requireRuntimeCommandId(" command-1 ")).toBe("command-1");
		expect(() => requireRuntimeCommandId(undefined)).toThrow("must be a string");
		expect(() => requireRuntimeCommandId("x".repeat(129))).toThrow("between 1 and 128");
	});
});
