import { describe, expect, it } from "vitest";
import {
	agentRuntimeDescriptor,
	selectedAvailableAgentRuntimeId,
	supportsAgentRuntimeCapability,
	type AgentRuntimesResponse,
} from "./agentRuntime.js";

const catalog: AgentRuntimesResponse = {
	defaultRuntimeId: "pi",
	runtimes: [
		{
			id: "pi",
			kind: "pi-embedded",
			label: "Pi",
			available: false,
			command: "embedded",
			profileDir: "/pi",
			capabilities: ["prompt"],
		},
		{
			id: "omp",
			kind: "omp-rpc",
			label: "OMP",
			available: true,
			command: "omp",
			profileDir: "/omp",
			capabilities: ["prompt", "shell"],
		},
	],
};

describe("agent runtime catalog helpers", () => {
	it("falls back from an unavailable default to the first available runtime", () => {
		expect(selectedAvailableAgentRuntimeId(catalog, undefined)).toBe("omp");
		expect(selectedAvailableAgentRuntimeId(catalog, "pi")).toBe("omp");
		expect(selectedAvailableAgentRuntimeId(catalog, "omp")).toBe("omp");
	});

	it("requires both availability and the advertised capability", () => {
		expect(supportsAgentRuntimeCapability(catalog, "omp", "shell")).toBe(true);
		expect(supportsAgentRuntimeCapability(catalog, "omp", "archive")).toBe(
			false,
		);
		expect(supportsAgentRuntimeCapability(catalog, "pi", "prompt")).toBe(false);
		expect(agentRuntimeDescriptor(catalog, "omp")?.label).toBe("OMP");
	});
});
