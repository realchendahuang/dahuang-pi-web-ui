import { execFile } from "node:child_process";
import { readFile, realpath, stat } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { promisify } from "node:util";
import type { FastifyInstance } from "fastify";
import {
  effectiveOmpRuntimeConfig,
  loadPiWebConfig,
  PI_CODING_AGENT_DIR_ENV,
  type LoadOptions,
} from "../config.js";
import { resolveOmpExecutable } from "./runtimes/omp/ompExecutable.js";
import {
  isOmpSettingType,
  type OmpConfigResponse,
  type OmpSettingDescriptor,
  type OmpSettingType,
} from "../shared/apiTypes.js";

const execFileAsync = promisify(execFile);

const OMP_CONFIG_EXEC_TIMEOUT_MS = 10_000;
const OMP_CONFIG_PATH_TIMEOUT_MS = 5_000;
const OMP_SETTINGS_SCHEMA_PACKAGE = "@oh-my-pi/pi-coding-agent";
const OMP_SETTINGS_SCHEMA_RELATIVE_PATH = "src/config/settings-schema.ts";

export interface OmpConfigExecResult {
  stdout: string;
  stderr: string;
}

export interface OmpConfigExecOptions {
  env: NodeJS.ProcessEnv;
  timeout: number;
}

export type OmpConfigExecFile = (
  command: string,
  args: readonly string[],
  options: OmpConfigExecOptions,
) => Promise<OmpConfigExecResult>;

/**
 * Injectable seams for the OMP config service. Every process, filesystem, and
 * config-store touch goes through these so tests can drive the full route
 * contract without a real `omp` install.
 */
export interface OmpConfigServiceDeps extends LoadOptions {
  execFile?: OmpConfigExecFile;
  resolveExecutable?: (command: string) => Promise<string | undefined>;
  readFile?: (path: string) => Promise<string>;
  realpath?: (path: string) => Promise<string>;
  /** Returns the file mtime in ms, or undefined when the file does not exist. */
  statMtime?: (path: string) => Promise<number | undefined>;
}

export interface OmpConfigService {
  read: () => Promise<OmpConfigResponse>;
  write: (values: Record<string, unknown>) => Promise<OmpConfigResponse>;
}

export interface OmpSchemaSettingEntry {
  type?: string;
  values?: string[];
  default?: unknown;
  tab?: string;
  group?: string;
}

interface OmpSchemaCacheEntry {
  schemaPath: string;
  mtimeMs: number;
  entries: Map<string, OmpSchemaSettingEntry>;
}

class OmpConfigUnavailableError extends Error {}

async function defaultStatMtime(path: string): Promise<number | undefined> {
  try {
    return (await stat(path)).mtimeMs;
  } catch {
    return undefined;
  }
}

export function createOmpConfigService(deps: OmpConfigServiceDeps = {}): OmpConfigService {
  const execFileImpl: OmpConfigExecFile =
    deps.execFile ??
    (async (command, args, options) => {
      const result = await execFileAsync(command, [...args], {
        env: options.env,
        timeout: options.timeout,
      });
      return { stdout: result.stdout, stderr: result.stderr };
    });
  const resolveExecutable =
    deps.resolveExecutable ??
    ((command: string) =>
      resolveOmpExecutable(
        command,
        deps.env === undefined ? {} : { env: deps.env },
      ));
  const readFileImpl = deps.readFile ?? ((path: string) => readFile(path, "utf8"));
  const realpathImpl = deps.realpath ?? ((path: string) => realpath(path));
  const statMtime = deps.statMtime ?? defaultStatMtime;
  // Keyed by resolved executable path; revalidated against the schema file mtime.
  const schemaCache = new Map<string, OmpSchemaCacheEntry>();

  function runtimeConfig(): { command: string; dir: string; env: NodeJS.ProcessEnv } {
    const env = deps.env ?? process.env;
    const loaded = loadPiWebConfig({
      env,
      ...(deps.cwd === undefined ? {} : { cwd: deps.cwd }),
    });
    const runtime = effectiveOmpRuntimeConfig(env, loaded.config);
    return { command: runtime.command, dir: runtime.dir, env };
  }

  async function resolveRuntime(): Promise<
    { executable: string; spawnEnv: NodeJS.ProcessEnv } | { error: string }
  > {
    const runtime = runtimeConfig();
    const executable = await resolveExecutable(runtime.command);
    if (executable === undefined) {
      return { error: `OMP executable not found: ${runtime.command}` };
    }
    return {
      executable,
      spawnEnv: { ...runtime.env, [PI_CODING_AGENT_DIR_ENV]: runtime.dir },
    };
  }

  async function readSettings(executable: string, spawnEnv: NodeJS.ProcessEnv): Promise<OmpSettingDescriptor[]> {
    const result = await execFileImpl(executable, ["config", "list", "--json"], {
      env: spawnEnv,
      timeout: OMP_CONFIG_EXEC_TIMEOUT_MS,
    });
    const schemaEntries = await loadSchemaEntries(executable);
    return parseOmpConfigList(result.stdout).map((descriptor) => {
      const schemaEntry = schemaEntries.get(descriptor.key);
      if (schemaEntry === undefined) return descriptor;
      return {
        ...descriptor,
        ...(schemaEntry.values !== undefined && schemaEntry.values.length > 0
          ? { enumValues: schemaEntry.values }
          : {}),
        ...(descriptor.default === undefined && schemaEntry.default !== undefined
          ? { default: schemaEntry.default }
          : {}),
        ...(schemaEntry.tab !== undefined ? { tab: schemaEntry.tab } : {}),
        ...(schemaEntry.group !== undefined ? { group: schemaEntry.group } : {}),
      };
    });
  }

  async function readConfigPath(executable: string, spawnEnv: NodeJS.ProcessEnv): Promise<string | undefined> {
    try {
      const result = await execFileImpl(executable, ["config", "path"], {
        env: spawnEnv,
        timeout: OMP_CONFIG_PATH_TIMEOUT_MS,
      });
      const path = result.stdout.trim();
      return path === "" ? undefined : path;
    } catch {
      return undefined;
    }
  }

  async function loadSchemaEntries(executable: string): Promise<Map<string, OmpSchemaSettingEntry>> {
    try {
      const resolved = await realpathImpl(executable).catch(() => executable);
      const schemaPath = await locateSettingsSchema(resolved);
      if (schemaPath === undefined) return new Map();
      const mtimeMs = await statMtime(schemaPath);
      if (mtimeMs === undefined) return new Map();
      const cached = schemaCache.get(resolved);
      if (cached?.schemaPath === schemaPath && cached.mtimeMs === mtimeMs) {
        return cached.entries;
      }
      const entries = parseOmpSettingsSchema(await readFileImpl(schemaPath));
      schemaCache.set(resolved, { schemaPath, mtimeMs, entries });
      return entries;
    } catch {
      // Schema enrichment is best-effort: any failure still yields a usable payload.
      return new Map();
    }
  }

  async function locateSettingsSchema(resolvedExecutable: string): Promise<string | undefined> {
    const packageSchema = `${OMP_SETTINGS_SCHEMA_PACKAGE}/${OMP_SETTINGS_SCHEMA_RELATIVE_PATH}`;
    const startDir = dirname(resolvedExecutable);
    const candidates = [
      join(startDir, "..", "lib", "node_modules", packageSchema),
      join(startDir, "..", "node_modules", packageSchema),
    ];
    let current = startDir;
    for (let depth = 0; depth < 8; depth += 1) {
      if (basename(current) === "node_modules") candidates.push(join(current, packageSchema));
      if (current.endsWith(OMP_SETTINGS_SCHEMA_PACKAGE)) {
        candidates.push(join(current, OMP_SETTINGS_SCHEMA_RELATIVE_PATH));
      }
      const parent = dirname(current);
      if (parent === current) break;
      current = parent;
    }
    for (const candidate of candidates) {
      if ((await statMtime(candidate)) !== undefined) return candidate;
    }
    return undefined;
  }

  const read = async (): Promise<OmpConfigResponse> => {
    const runtime = await resolveRuntime();
    if ("error" in runtime) {
      return { available: false, error: runtime.error, settings: [] };
    }
    try {
      const settings = await readSettings(runtime.executable, runtime.spawnEnv);
      const configPath = await readConfigPath(runtime.executable, runtime.spawnEnv);
      return {
        available: true,
        command: runtime.executable,
        ...(configPath !== undefined ? { configPath } : {}),
        settings,
      };
    } catch (error) {
      return {
        available: false,
        command: runtime.executable,
        error: errorMessage(error),
        settings: [],
      };
    }
  };

  const write = async (values: Record<string, unknown>): Promise<OmpConfigResponse> => {
    if (!isRecord(values)) throw new Error("OMP config update must include a values object");
    const current = await read();
    if (!current.available) {
      throw new OmpConfigUnavailableError(current.error ?? "OMP is not available");
    }
    const descriptors = new Map(current.settings.map((setting) => [setting.key, setting]));
    const entries = Object.entries(values);
    for (const [key, value] of entries) {
      const descriptor = descriptors.get(key);
      if (descriptor === undefined) throw new Error(`OMP config key is not a known setting: ${key}`);
      if (value !== null) validateOmpSettingValue(descriptor, value);
    }
    const runtime = await resolveRuntime();
    if ("error" in runtime) throw new OmpConfigUnavailableError(runtime.error);
    for (const [key, value] of entries) {
      const descriptor = descriptors.get(key);
      const args =
        value === null
          ? ["config", "reset", key]
          : ["config", "set", key, serializeOmpSettingValue(descriptor?.type, value)];
      try {
        await execFileImpl(runtime.executable, args, {
          env: runtime.spawnEnv,
          timeout: OMP_CONFIG_EXEC_TIMEOUT_MS,
        });
      } catch (error) {
        throw new Error(`OMP config set failed for ${key}: ${errorMessage(error)}`, { cause: error });
      }
    }
    return read();
  };

  return { read, write };
}

export function registerOmpConfigRoutes(
  app: FastifyInstance,
  service: OmpConfigService = createOmpConfigService(),
): void {
  registerOmpConfigHandlers(app, "/api/omp/config", service);
}

export function registerLocalMachineOmpConfigRoutes(
  app: FastifyInstance,
  service: OmpConfigService = createOmpConfigService(),
): void {
  registerOmpConfigHandlers(app, "/api/machines/local/omp/config", service);
}

function registerOmpConfigHandlers(app: FastifyInstance, path: string, service: OmpConfigService): void {
  app.get(path, async (_request, reply) => {
    try {
      return await service.read();
    } catch (error) {
      return reply.code(500).send({ error: errorMessage(error) });
    }
  });

  app.put<{ Body: { values?: unknown } | undefined }>(path, async (request, reply) => {
    try {
      const values = isRecord(request.body) ? request.body.values : undefined;
      if (!isRecord(values)) throw new Error("OMP config update must include a values object");
      return await service.write(values);
    } catch (error) {
      if (error instanceof OmpConfigUnavailableError) {
        return reply.code(503).send({ error: errorMessage(error) });
      }
      const status = isOmpConfigValidationError(error) ? 400 : 500;
      return reply.code(status).send({ error: errorMessage(error) });
    }
  });
}

function parseOmpConfigList(stdout: string): OmpSettingDescriptor[] {
  const parsed: unknown = JSON.parse(stdout);
  if (!isRecord(parsed)) throw new Error("OMP config list returned an unexpected payload");
  const settings: OmpSettingDescriptor[] = [];
  for (const [key, entry] of Object.entries(parsed)) {
    if (!isRecord(entry)) continue;
    const value = entry["value"];
    const type = parseOmpSettingType(entry["type"], value);
    const description = typeof entry["description"] === "string" ? entry["description"] : "";
    settings.push({
      key,
      type,
      description,
      ...(value !== undefined ? { value } : {}),
      ...(entry["default"] !== undefined ? { default: entry["default"] } : {}),
    });
  }
  return settings.sort((a, b) => a.key.localeCompare(b.key));
}

function parseOmpSettingType(value: unknown, settingValue: unknown): OmpSettingType {
  if (isOmpSettingType(value)) return value;
  if (typeof settingValue === "boolean") return "boolean";
  if (typeof settingValue === "number") return "number";
  if (Array.isArray(settingValue)) return "array";
  if (isRecord(settingValue)) return "record";
  return "string";
}

function validateOmpSettingValue(descriptor: OmpSettingDescriptor, value: unknown): void {
  switch (descriptor.type) {
    case "boolean":
      if (typeof value !== "boolean") throw new Error(`OMP config setting ${descriptor.key} must be a boolean`);
      return;
    case "number":
      if (typeof value !== "number" || !Number.isFinite(value)) {
        throw new Error(`OMP config setting ${descriptor.key} must be a finite number`);
      }
      return;
    case "string":
      if (typeof value !== "string") throw new Error(`OMP config setting ${descriptor.key} must be a string`);
      return;
    case "enum": {
      if (typeof value !== "string") throw new Error(`OMP config setting ${descriptor.key} must be a string`);
      if (descriptor.enumValues !== undefined && !descriptor.enumValues.includes(value)) {
        throw new Error(
          `OMP config setting ${descriptor.key} must be one of: ${descriptor.enumValues.join(", ")}`,
        );
      }
      return;
    }
    case "array":
      if (!Array.isArray(value)) throw new Error(`OMP config setting ${descriptor.key} must be an array`);
      return;
    case "record":
      if (!isRecord(value) && !Array.isArray(value)) {
        throw new Error(`OMP config setting ${descriptor.key} must be an object or array`);
      }
      return;
  }
}

function serializeOmpSettingValue(type: OmpSettingType | undefined, value: unknown): string {
  if (type === "array" || type === "record") return JSON.stringify(value);
  return String(value);
}

/**
 * Tolerant text parse of OMP's settings-schema.ts. Finds `"key": {` entries at
 * any nesting depth, flattens them into dot paths, and keeps leaf blocks that
 * declare a `type`. Only string-literal-safe brace matching is attempted; any
 * oddity simply drops that entry instead of failing the parse.
 */
export function parseOmpSettingsSchema(source: string): Map<string, OmpSchemaSettingEntry> {
  const entries = new Map<string, OmpSchemaSettingEntry>();
  scanSchemaBlock(source, "", entries);
  return entries;
}

function scanSchemaBlock(
  text: string,
  prefix: string,
  entries: Map<string, OmpSchemaSettingEntry>,
): void {
  const propertyPattern = /(?:"([^"]+)"|([A-Za-z_$][\w$.-]*))\s*:\s*\{/g;
  let match: RegExpExecArray | null;
  while ((match = propertyPattern.exec(text)) !== null) {
    const openIndex = propertyPattern.lastIndex - 1;
    const closeIndex = matchingBrace(text, openIndex);
    if (closeIndex === -1) continue;
    const block = text.slice(openIndex, closeIndex + 1);
    const key = match[1] ?? match[2];
    if (key === undefined) continue;
    const entry = parseSchemaSettingBlock(block);
    if (entry.type !== undefined) entries.set(`${prefix}${key}`, entry);
    scanSchemaBlock(block.slice(1, -1), `${prefix}${key}.`, entries);
    propertyPattern.lastIndex = closeIndex + 1;
  }
}

function parseSchemaSettingBlock(block: string): OmpSchemaSettingEntry {
  const entry: OmpSchemaSettingEntry = {};
  const type = /"?type"?\s*:\s*"([^"]+)"/u.exec(block);
  const typeValue = type?.[1];
  if (typeValue !== undefined) entry.type = typeValue;
  const values = /"?values"?\s*:\s*\[/u.exec(block);
  if (values !== null) {
    const openIndex = values.index + values[0].length - 1;
    const closeIndex = matchingBrace(block, openIndex);
    if (closeIndex !== -1) {
      entry.values = stringLiterals(block.slice(openIndex + 1, closeIndex));
    }
  }
  const defaultMatch = /"?default"?\s*:/u.exec(block);
  if (defaultMatch !== null) {
    entry.default = parseSchemaDefault(block.slice(defaultMatch.index + defaultMatch[0].length));
  }
  const ui = /"?ui"?\s*:\s*\{/u.exec(block);
  if (ui !== null) {
    const openIndex = ui.index + ui[0].length - 1;
    const closeIndex = matchingBrace(block, openIndex);
    const uiBlock = closeIndex === -1 ? block.slice(openIndex + 1) : block.slice(openIndex + 1, closeIndex);
    const tab = /"?tab"?\s*:\s*"([^"]+)"/u.exec(uiBlock);
    const group = /"?group"?\s*:\s*"([^"]+)"/u.exec(uiBlock);
    const tabValue = tab?.[1];
    const groupValue = group?.[1];
    if (tabValue !== undefined) entry.tab = tabValue;
    if (groupValue !== undefined) entry.group = groupValue;
  }
  return entry;
}

function parseSchemaDefault(text: string): unknown {
  let depth = 0;
  let inString = false;
  let end = text.length;
  for (let index = 0; index < text.length; index += 1) {
    const char = text[index];
    if (inString) {
      if (char === "\\") index += 1;
      else if (char === '"') inString = false;
      continue;
    }
    if (char === '"') inString = true;
    else if (char === "[" || char === "{") depth += 1;
    else if (char === "]" || char === "}") {
      if (depth === 0) {
        end = index;
        break;
      }
      depth -= 1;
    } else if ((char === "," || char === "\n") && depth === 0) {
      end = index;
      break;
    }
  }
  const raw = text.slice(0, end).trim();
  if (raw === "") return undefined;
  try {
    return JSON.parse(raw);
  } catch {
    const quoted = /^"((?:[^"\\]|\\.)*)"\s*$/u.exec(raw);
    if (quoted !== null) return quoted[1];
    return undefined;
  }
}

/** Finds the closing brace for the opening `{`/`[` at `openIndex`, skipping string literals. */
function matchingBrace(text: string, openIndex: number): number {
  const open = text[openIndex];
  const close = open === "{" ? "}" : open === "[" ? "]" : undefined;
  if (close === undefined) return -1;
  let depth = 0;
  let inString = false;
  for (let index = openIndex; index < text.length; index += 1) {
    const char = text[index];
    if (inString) {
      if (char === "\\") index += 1;
      else if (char === '"') inString = false;
      continue;
    }
    if (char === '"') inString = true;
    else if (char === open) depth += 1;
    else if (char === close) {
      depth -= 1;
      if (depth === 0) return index;
    }
  }
  return -1;
}

function stringLiterals(text: string): string[] {
  const values: string[] = [];
  const pattern = /"((?:[^"\\]|\\.)*)"/g;
  let match: RegExpExecArray | null;
  while ((match = pattern.exec(text)) !== null) {
    const literal = match[1];
    if (literal === undefined) continue;
    try {
      const parsed: unknown = JSON.parse(`"${literal}"`);
      values.push(typeof parsed === "string" ? parsed : literal);
    } catch {
      values.push(literal);
    }
  }
  return values;
}

function isOmpConfigValidationError(error: unknown): boolean {
  return error instanceof Error && error.message.startsWith("OMP config");
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
