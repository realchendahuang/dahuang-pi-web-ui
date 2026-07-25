import { describe, expect, it } from "vitest";
import { parseArgs, resolvePiWebCliArgs } from "./pi-web.js";

describe("parseArgs", () => {
	it("splits plain words", () => {
		expect(parseArgs("up --no-open")).toEqual(["up", "--no-open"]);
	});

	it("keeps quoted segments", () => {
		expect(parseArgs(`install --config "/tmp/my config.json"`)).toEqual([
			"install",
			"--config",
			"/tmp/my config.json",
		]);
	});
});

describe("resolvePiWebCliArgs", () => {
	it("maps bare /pi-web to up", () => {
		expect(resolvePiWebCliArgs("")).toEqual(["up"]);
		expect(resolvePiWebCliArgs("   ")).toEqual(["up"]);
	});

	it("ignores other subcommands and only forwards --no-open", () => {
		expect(resolvePiWebCliArgs("install")).toEqual(["up"]);
		expect(resolvePiWebCliArgs("status")).toEqual(["up"]);
		expect(resolvePiWebCliArgs("open")).toEqual(["up"]);
		expect(resolvePiWebCliArgs("--no-open")).toEqual(["up", "--no-open"]);
		expect(resolvePiWebCliArgs("up --no-open")).toEqual(["up", "--no-open"]);
	});
});
