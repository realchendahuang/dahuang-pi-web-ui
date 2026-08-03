import Fastify, { type FastifyInstance } from "fastify";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { OmpConfigResponse } from "../shared/apiTypes.js";
import {
  createOmpConfigService,
  registerLocalMachineOmpConfigRoutes,
  registerOmpConfigRoutes,
  type OmpConfigExecOptions,
  type OmpConfigServiceDeps,
} from "./ompConfigRoutes.js";

const OMP_EXECUTABLE = "/usr/local/bin/omp";
const OMP_AGENT_DIR = "/tmp/omp-agent-profile";
const SCHEMA_PATH =
  "/usr/local/lib/node_modules/@oh-my-pi/pi-coding-agent/src/config/settings-schema.ts";

const CONFIG_LIST_JSON = JSON.stringify({
  "model.temperature": { value: 0.7, type: "number", description: "Sampling temperature" },
  "model.name": { value: "k3", type: "enum", description: "Active model" },
  "tools.enabled": { value: true, type: "boolean", description: "Enable tools" },
  extensions: { value: ["ext-a.ts"], type: "array", description: "Extension entry files" },
  "retry.fallbackChains": {
    value: { default: [["a", "b"]] },
    type: "record",
    description: "Model fallback chains",
  },
});

const SETTINGS_SCHEMA_SOURCE = `
export const SETTINGS_SCHEMA = {
  model: {
    name: {
      type: "enum",
      values: ["k3", "k2", "gpt-5"],
      default: "k3",
      description: "Active model",
      ui: { tab: "model", group: "selection" },
    },
    temperature: {
      type: "number",
      default: 1,
      ui: { tab: "model", group: "sampling" },
    },
  },
  tools: {
    enabled: {
      type: "boolean",
      default: true,
      ui: { tab: "tools" },
    },
  },
};
`;

interface ExecCall {
  command: string;
  args: readonly string[];
  options: OmpConfigExecOptions;
}

type ExecFile = NonNullable<OmpConfigServiceDeps["execFile"]>;

let app: FastifyInstance;
let execCalls: ExecCall[];
let execFileBehavior: ExecFile;
let statMtimeBehavior: (path: string) => Promise<number | undefined>;
let readFileBehavior: (path: string) => Promise<string>;
let resolveExecutableBehavior: (command: string) => Promise<string | undefined>;

function defaultExecFile(
  args: readonly string[],
): Promise<{ stdout: string; stderr: string }> {
  const key = args.join(" ");
  if (key === "config list --json") return Promise.resolve({ stdout: CONFIG_LIST_JSON, stderr: "" });
  if (key === "config path") return Promise.resolve({ stdout: "/home/test/.omp/agent/config.yml\n", stderr: "" });
  if (key.startsWith("config set ") || key.startsWith("config reset ")) {
    return Promise.resolve({ stdout: "", stderr: "" });
  }
  return Promise.reject(new Error(`unexpected exec: ${key}`));
}

function execArgs(args: readonly string[]): string {
  return args.join(" ");
}

function mutationCalls(): string[] {
  return execCalls
    .map((call) => execArgs(call.args))
    .filter((args) => args.startsWith("config set") || args.startsWith("config reset"));
}

beforeEach(async () => {
  execCalls = [];
  execFileBehavior = (_command, args) => defaultExecFile(args);
  statMtimeBehavior = () => Promise.resolve(undefined);
  readFileBehavior = () => Promise.reject(new Error("no schema"));
  resolveExecutableBehavior = (command) => Promise.resolve(command === "omp" ? OMP_EXECUTABLE : undefined);
  const deps: OmpConfigServiceDeps = {
    env: {
      PI_WEB_CONFIG: "/nonexistent/pi-web-config.json",
      PI_WEB_OMP_AGENT_DIR: OMP_AGENT_DIR,
    },
    resolveExecutable: (command) => resolveExecutableBehavior(command),
    execFile: (command, args, options) => {
      execCalls.push({ command, args, options });
      return execFileBehavior(command, args, options);
    },
    realpath: (path) => Promise.resolve(path),
    statMtime: (path) => statMtimeBehavior(path),
    readFile: (path) => readFileBehavior(path),
  };
  app = Fastify({ logger: false });
  const service = createOmpConfigService(deps);
  registerOmpConfigRoutes(app, service);
  registerLocalMachineOmpConfigRoutes(app, service);
  await app.ready();
});

afterEach(async () => {
  await app.close();
});

describe("omp config routes", () => {
  it("GET returns settings with config path and injects the agent dir env", async () => {
    const response = await app.inject({ method: "GET", url: "/api/machines/local/omp/config" });

    expect(response.statusCode).toBe(200);
    const payload = response.json<OmpConfigResponse>();
    expect(payload.available).toBe(true);
    expect(payload.command).toBe(OMP_EXECUTABLE);
    expect(payload.configPath).toBe("/home/test/.omp/agent/config.yml");
    expect(payload.settings.map((setting) => setting.key)).toEqual([
      "extensions",
      "model.name",
      "model.temperature",
      "retry.fallbackChains",
      "tools.enabled",
    ]);
    const listCall = execCalls.find((call) => execArgs(call.args) === "config list --json");
    expect(listCall?.options.env["PI_CODING_AGENT_DIR"]).toBe(OMP_AGENT_DIR);
    expect(listCall?.options.timeout).toBe(10_000);
  });

  it("GET is also served on the gateway path used by remote-machine proxies", async () => {
    const response = await app.inject({ method: "GET", url: "/api/omp/config" });

    expect(response.statusCode).toBe(200);
    expect(response.json<OmpConfigResponse>().available).toBe(true);
  });

  it("GET degrades when the omp executable is missing", async () => {
    resolveExecutableBehavior = () => Promise.resolve(undefined);

    const response = await app.inject({ method: "GET", url: "/api/machines/local/omp/config" });

    expect(response.statusCode).toBe(200);
    const payload = response.json<OmpConfigResponse>();
    expect(payload.available).toBe(false);
    expect(payload.error).toContain("omp");
    expect(payload.settings).toEqual([]);
  });

  it("GET degrades when omp config list fails", async () => {
    execFileBehavior = () => Promise.reject(new Error("spawn omp ENOENT"));

    const response = await app.inject({ method: "GET", url: "/api/machines/local/omp/config" });

    expect(response.statusCode).toBe(200);
    const payload = response.json<OmpConfigResponse>();
    expect(payload.available).toBe(false);
    expect(payload.error).toContain("ENOENT");
    expect(payload.settings).toEqual([]);
  });

  it("GET enriches enum settings from the installed settings schema", async () => {
    statMtimeBehavior = (path) => Promise.resolve(path === SCHEMA_PATH ? 42 : undefined);
    readFileBehavior = (path) =>
      path === SCHEMA_PATH ? Promise.resolve(SETTINGS_SCHEMA_SOURCE) : Promise.reject(new Error("nope"));

    const response = await app.inject({ method: "GET", url: "/api/machines/local/omp/config" });

    expect(response.statusCode).toBe(200);
    const payload = response.json<OmpConfigResponse>();
    const model = payload.settings.find((setting) => setting.key === "model.name");
    expect(model?.enumValues).toEqual(["k3", "k2", "gpt-5"]);
    expect(model?.tab).toBe("model");
    expect(model?.group).toBe("selection");
    const temperature = payload.settings.find((setting) => setting.key === "model.temperature");
    expect(temperature?.tab).toBe("model");
    expect(temperature?.group).toBe("sampling");
    const tools = payload.settings.find((setting) => setting.key === "tools.enabled");
    expect(tools?.tab).toBe("tools");
    expect(tools?.group).toBeUndefined();
    const extensions = payload.settings.find((setting) => setting.key === "extensions");
    expect(extensions?.enumValues).toBeUndefined();
    expect(extensions?.tab).toBeUndefined();
  });

  it("PUT sets and resets values then returns a fresh payload", async () => {
    const response = await app.inject({
      method: "PUT",
      url: "/api/machines/local/omp/config",
      payload: {
        values: {
          "tools.enabled": false,
          "model.name": null,
          extensions: ["ext-a.ts", "ext-b.ts"],
        },
      },
    });

    expect(response.statusCode).toBe(200);
    expect(mutationCalls()).toEqual([
      "config set tools.enabled false",
      "config reset model.name",
      'config set extensions ["ext-a.ts","ext-b.ts"]',
    ]);
    const payload = response.json<OmpConfigResponse>();
    expect(payload.available).toBe(true);
    expect(execCalls.filter((call) => execArgs(call.args) === "config list --json").length).toBe(2);
  });

  it("PUT rejects values with the wrong type before touching omp", async () => {
    const response = await app.inject({
      method: "PUT",
      url: "/api/machines/local/omp/config",
      payload: { values: { "tools.enabled": "yes" } },
    });

    expect(response.statusCode).toBe(400);
    expect(response.json<{ error: string }>().error).toContain("tools.enabled");
    expect(mutationCalls()).toEqual([]);
  });

  it("PUT rejects enum values outside the schema enum list", async () => {
    statMtimeBehavior = (path) => Promise.resolve(path === SCHEMA_PATH ? 42 : undefined);
    readFileBehavior = (path) =>
      path === SCHEMA_PATH ? Promise.resolve(SETTINGS_SCHEMA_SOURCE) : Promise.reject(new Error("nope"));

    const response = await app.inject({
      method: "PUT",
      url: "/api/machines/local/omp/config",
      payload: { values: { "model.name": "not-a-model" } },
    });

    expect(response.statusCode).toBe(400);
    expect(response.json<{ error: string }>().error).toContain("model.name");
    expect(mutationCalls()).toEqual([]);
  });

  it("PUT rejects unknown keys", async () => {
    const response = await app.inject({
      method: "PUT",
      url: "/api/machines/local/omp/config",
      payload: { values: { "no.such.key": true } },
    });

    expect(response.statusCode).toBe(400);
    expect(response.json<{ error: string }>().error).toContain("no.such.key");
  });

  it("PUT reports 400 with the failing key when omp config set fails", async () => {
    execFileBehavior = (_command, args) => {
      if (execArgs(args).startsWith("config set")) {
        return Promise.reject(new Error("invalid value"));
      }
      return defaultExecFile(args);
    };

    const response = await app.inject({
      method: "PUT",
      url: "/api/machines/local/omp/config",
      payload: { values: { "model.temperature": 0.2 } },
    });

    expect(response.statusCode).toBe(400);
    expect(response.json<{ error: string }>().error).toContain("model.temperature");
  });

  it("PUT returns 503 when omp is unavailable", async () => {
    resolveExecutableBehavior = () => Promise.resolve(undefined);

    const response = await app.inject({
      method: "PUT",
      url: "/api/machines/local/omp/config",
      payload: { values: { "tools.enabled": false } },
    });

    expect(response.statusCode).toBe(503);
  });

  it("PUT rejects a malformed body", async () => {
    const response = await app.inject({
      method: "PUT",
      url: "/api/machines/local/omp/config",
      payload: { values: "not-an-object" },
    });

    expect(response.statusCode).toBe(400);
  });
});
