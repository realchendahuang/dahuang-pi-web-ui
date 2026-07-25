import { describe, expect, it } from "vitest";
import { parseArgs, resolvePiWebSubcommand } from "./pi-web.js";

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

describe("resolvePiWebSubcommand", () => {
  it("defaults bare /pi-web to up", () => {
    expect(resolvePiWebSubcommand("")).toEqual({ subcommand: "up", rest: [] });
    expect(resolvePiWebSubcommand("   ")).toEqual({ subcommand: "up", rest: [] });
  });

  it("passes through explicit subcommands and flags", () => {
    expect(resolvePiWebSubcommand("up --install")).toEqual({
      subcommand: "up",
      rest: ["--install"],
    });
    expect(resolvePiWebSubcommand("status")).toEqual({ subcommand: "status", rest: [] });
    expect(resolvePiWebSubcommand("open")).toEqual({ subcommand: "open", rest: [] });
  });
});
