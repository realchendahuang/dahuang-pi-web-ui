import { describe, expect, it } from "vitest";
import { InMemoryCredentialStore } from "@earendil-works/pi-ai";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { createPiSdkRuntimeAdapter } from "./piSdkRuntimeAdapter.js";

describe("PiSdkRuntimeAdapter", () => {
	it("rejects non-SDK session managers before invoking the SDK factory", async () => {
		const adapter = createPiSdkRuntimeAdapter();
		let factoryCalled = false;
		await expect(
			adapter.createRuntime(
				() => {
					factoryCalled = true;
					return Promise.reject(new Error("unreachable"));
				},
				{ cwd: "/workspace", agentDir: "/agent", sessionManager: {} },
			),
		).rejects.toThrow("requires an SDK SessionManager");
		expect(factoryCalled).toBe(false);
	});

	it("rejects a non-SDK session manager before constructing SDK session services", async () => {
		const adapter = createPiSdkRuntimeAdapter();
		const modelRuntime = await ModelRuntime.create({
			credentials: new InMemoryCredentialStore(),
			modelsPath: null,
			allowModelNetwork: false,
		});

		await expect(
			adapter.createSessionFromServices({
				cwd: "/workspace",
				agentDir: "/agent",
				modelRuntime,
				sessionManager: {},
				customTools: [],
			}),
		).rejects.toThrow("requires an SDK SessionManager");
	});
});
