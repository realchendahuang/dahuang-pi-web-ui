import { describe, expect, it } from "vitest";
import { parseArgs, resolvePiWebCliArgs } from "./piWebLaunch.js";

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
	it("maps bare /pi-web to up with the launching terminal's default runtime", () => {
		expect(resolvePiWebCliArgs("", "pi")).toEqual([
			"up",
			"--default-runtime",
			"pi",
		]);
		expect(resolvePiWebCliArgs("   ", "pi")).toEqual([
			"up",
			"--default-runtime",
			"pi",
		]);
		expect(resolvePiWebCliArgs("", "omp")).toEqual([
			"up",
			"--default-runtime",
			"omp",
		]);
	});

	it("ignores other subcommands and only forwards --no-open", () => {
		expect(resolvePiWebCliArgs("install", "pi")).toEqual([
			"up",
			"--default-runtime",
			"pi",
		]);
		expect(resolvePiWebCliArgs("status", "omp")).toEqual([
			"up",
			"--default-runtime",
			"omp",
		]);
		expect(resolvePiWebCliArgs("open", "pi")).toEqual([
			"up",
			"--default-runtime",
			"pi",
		]);
		expect(resolvePiWebCliArgs("--no-open", "pi")).toEqual([
			"up",
			"--default-runtime",
			"pi",
			"--no-open",
		]);
		expect(resolvePiWebCliArgs("up --no-open", "omp")).toEqual([
			"up",
			"--default-runtime",
			"omp",
			"--no-open",
		]);
	});
});
