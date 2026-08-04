import { describe, expect, it } from "vitest";
import { abortActiveSessions } from "./activeSessionAbort.js";

describe("abortActiveSessions", () => {
	it("attempts every active target and returns deterministic per-session failures", async () => {
		const calls: string[] = [];
		const result = await abortActiveSessions(
			[
				{ sessionId: "pi-1", runtimeId: "pi" },
				{ sessionId: "omp-1", runtimeId: "omp" },
			],
			async (target) => {
				calls.push(target.sessionId);
				if (target.sessionId === "omp-1") throw new Error("OMP disconnected");
				await Promise.resolve();
			},
		);

		expect(calls).toEqual(["pi-1", "omp-1"]);
		expect(result).toEqual({
			requested: 2,
			aborted: [{ sessionId: "pi-1", runtimeId: "pi" }],
			failures: [
				{ sessionId: "omp-1", runtimeId: "omp", error: "OMP disconnected" },
			],
		});
	});
});
