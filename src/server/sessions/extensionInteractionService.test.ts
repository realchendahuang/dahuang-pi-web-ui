import { describe, expect, it, vi } from "vitest";
import {
	ExtensionInteractionResponseError,
	ExtensionInteractionService,
} from "./extensionInteractionService.js";

describe("ExtensionInteractionService", () => {
	it("projects a pending select and resolves its SDK callback exactly once", async () => {
		const service = new ExtensionInteractionService({
			now: () => new Date("2026-08-04T10:00:00.000Z"),
		});
		const pending = service.select("session-1", "/repo", "Choose", ["one", "two"]);
		const [interaction] = service.list("session-1", "/repo");
		if (interaction === undefined) throw new Error("Expected a pending interaction");
		expect(interaction).toMatchObject({
			kind: "select",
			title: "Choose",
			options: ["one", "two"],
		});

		service.respond(interaction.id, { selected: "two" });
		expect(await pending).toBe("two");
		expect(service.list("session-1", "/repo")).toEqual([]);
	});

	it("rejects a response that does not match the pending dialog kind", () => {
		const service = new ExtensionInteractionService();
		void service.confirm("session-1", "/repo", "Proceed", "Continue?");
		const [interaction] = service.list("session-1", "/repo");
		if (interaction === undefined) throw new Error("Expected a pending interaction");
		expect(() => service.respond(interaction.id, { text: "no" })).toThrow(
			ExtensionInteractionResponseError,
		);
		expect(service.list("session-1", "/repo")).toHaveLength(1);
		service.dispose();
	});

	it("cancels an input on SDK abort and clears its native projection", async () => {
		const controller = new AbortController();
		const service = new ExtensionInteractionService();
		const pending = service.input(
			"session-1",
			"/repo",
			"Name",
			undefined,
			{ signal: controller.signal },
		);
		expect(service.list("session-1", "/repo")).toHaveLength(1);
		controller.abort();
		expect(await pending).toBeUndefined();
		expect(service.list("session-1", "/repo")).toEqual([]);
	});

	it("honors dialog timeout without leaving a pending callback", async () => {
		vi.useFakeTimers();
		try {
			const service = new ExtensionInteractionService();
			const pending = service.confirm(
				"session-1",
				"/repo",
				"Proceed",
				"Continue?",
				{ timeout: 10 },
			);
			await vi.advanceTimersByTimeAsync(10);
			expect(await pending).toBe(false);
			expect(service.list("session-1", "/repo")).toEqual([]);
		} finally {
			vi.useRealTimers();
		}
	});
});
