import { randomUUID } from "node:crypto";
import { chmod, mkdir, readFile, rename, unlink, writeFile } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import type { Credential, CredentialStore } from "@earendil-works/pi-ai";
import { piWebDataDir } from "../../config.js";

const MAX_LEGACY_AUTH_BYTES = 1_000_000;
const MAX_SERIALIZED_CREDENTIAL_BYTES = 768 * 1024;

export interface LegacyAuthCredentialPreview {
  providerId: string;
  type: Credential["type"];
  status: "ready" | "already-in-keychain";
}

export interface LegacyAuthMigrationPreview {
  available: boolean;
  source: "legacy-auth-json";
  sourceExists: boolean;
  eligible: boolean;
  credentials: LegacyAuthCredentialPreview[];
  issue?: string;
}

export type LegacyAuthMigrationState = "writing" | "verified" | "rolled-back" | "rollback-required";

export interface LegacyAuthMigrationRecord {
  id: string;
  source: "legacy-auth-json";
  createdAt: string;
  completedAt?: string;
  state: LegacyAuthMigrationState;
  credentials: { providerId: string; type: Credential["type"]; created: boolean }[];
  /** Only true after all entries were read back from the Keychain. */
  rollbackEligible: boolean;
  error?: string;
}

interface LegacyAuthMigrationFile {
  migrations: LegacyAuthMigrationRecord[];
}

/**
 * Moves an existing Pi auth.json into an App-owned CredentialStore without
 * exposing a credential through the Native Contract. The source file stays in
 * place: deleting or retiring it is deliberately a separate, explicit future
 * operation. Migration refuses Keychain conflicts so rollback never needs a
 * copy of a pre-existing secret.
 */
export class LegacyAuthMigrationService {
  private operationQueue: Promise<void> = Promise.resolve();

  constructor(
    private readonly credentials: CredentialStore,
    private readonly authPath: string,
    private readonly journalPath = defaultLegacyAuthMigrationFilePath(),
  ) {}

  async preview(): Promise<LegacyAuthMigrationPreview> {
    const inspected = await inspectLegacyAuthFile(this.authPath);
    if (!isLegacyAuthInspection(inspected)) return inspected;
    const existing = new Set((await this.credentials.list()).map((credential) => credential.providerId));
    const credentials = inspected.credentials.map(({ providerId, credential }) => ({
      providerId,
      type: credential.type,
      status: existing.has(providerId) ? "already-in-keychain" as const : "ready" as const,
    }));
    return {
      available: true,
      source: "legacy-auth-json",
      sourceExists: true,
      eligible: credentials.length > 0 && credentials.every((credential) => credential.status === "ready"),
      credentials,
      ...(credentials.length === 0 ? { issue: "Legacy auth.json does not contain credentials" } : {}),
      ...(credentials.some((credential) => credential.status === "already-in-keychain")
        ? { issue: "Some providers already have Keychain credentials and will not be overwritten" }
        : {}),
    };
  }

  async migrate(expectedProviderIds: readonly string[]): Promise<LegacyAuthMigrationRecord> {
    return this.exclusive(async () => {
      const inspected = await inspectLegacyAuthFile(this.authPath);
      if (!isLegacyAuthInspection(inspected)) throw new Error(inspected.issue ?? "Legacy auth.json cannot be migrated");
      const actualProviderIds = inspected.credentials.map((entry) => entry.providerId).sort();
      const expected = [...new Set(expectedProviderIds)].sort();
      if (expected.length === 0 || expected.length !== actualProviderIds.length || expected.some((id, index) => id !== actualProviderIds[index])) {
        throw new Error("Legacy credentials changed; review the migration preview again");
      }

      const existing = new Set((await this.credentials.list()).map((credential) => credential.providerId));
      const conflict = actualProviderIds.find((providerId) => existing.has(providerId));
      if (conflict !== undefined) throw new Error(`Keychain credential already exists for ${conflict}; migration will not overwrite it`);

      let record: LegacyAuthMigrationRecord = {
        id: randomUUID(),
        source: "legacy-auth-json",
        createdAt: new Date().toISOString(),
        state: "writing",
        credentials: inspected.credentials.map(({ providerId, credential }) => ({ providerId, type: credential.type, created: false })),
        rollbackEligible: false,
      };
      await this.upsert(record);

      try {
        for (const { providerId, credential } of inspected.credentials) {
          await this.credentials.modify(providerId, (current) => {
            if (current !== undefined) throw new Error(`Keychain credential already exists for ${providerId}; migration will not overwrite it`);
            return Promise.resolve(credential);
          });
          const readBack = await this.credentials.read(providerId);
          if (readBack?.type !== credential.type) throw new Error(`Keychain readback failed for ${providerId}`);
          record = markCreated(record, providerId);
          await this.upsert(record);
        }
        record = { ...record, state: "verified", completedAt: new Date().toISOString(), rollbackEligible: true };
        await this.upsert(record);
        return record;
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        const created = record.credentials.filter((credential) => credential.created);
        let rollbackFailed = false;
        for (const credential of created) {
          try {
            await this.credentials.delete(credential.providerId);
          } catch {
            rollbackFailed = true;
          }
        }
        record = {
          ...record,
          state: rollbackFailed ? "rollback-required" : "rolled-back",
          completedAt: new Date().toISOString(),
          rollbackEligible: false,
          error: message,
        };
        await this.upsert(record);
        throw new Error(message, { cause: error });
      }
    });
  }

  async get(id: string): Promise<LegacyAuthMigrationRecord | undefined> {
    return (await this.read()).migrations.find((migration) => migration.id === id);
  }

  async rollback(id: string): Promise<LegacyAuthMigrationRecord> {
    return this.exclusive(async () => {
      const record = await this.get(id);
      if (record === undefined) throw new Error("Legacy auth migration was not found");
      if (!record.rollbackEligible || record.state !== "verified") throw new Error("This migration is not eligible for automatic rollback");
      for (const credential of record.credentials) {
        if (credential.created) await this.credentials.delete(credential.providerId);
      }
      const rolledBack: LegacyAuthMigrationRecord = {
        ...record,
        state: "rolled-back",
        completedAt: new Date().toISOString(),
        rollbackEligible: false,
      };
      await this.upsert(rolledBack);
      return rolledBack;
    });
  }

  private async exclusive<T>(operation: () => Promise<T>): Promise<T> {
    const previous = this.operationQueue;
    let release = (): void => undefined;
    this.operationQueue = new Promise<void>((resolve) => { release = resolve; });
    await previous.catch(() => undefined);
    try { return await operation(); } finally { release(); }
  }

  private async read(): Promise<LegacyAuthMigrationFile> {
    try {
      return parseLegacyAuthMigrationFile(JSON.parse(await readFile(this.journalPath, "utf8")));
    } catch (error) {
      if (isNodeError(error, "ENOENT")) return { migrations: [] };
      throw error;
    }
  }

  private async upsert(record: LegacyAuthMigrationRecord): Promise<void> {
    const data = await this.read();
    const index = data.migrations.findIndex((migration) => migration.id === record.id);
    if (index === -1) data.migrations.push(record);
    else data.migrations[index] = record;
    await atomicWrite(this.journalPath, data);
  }
}

export function defaultLegacyAuthMigrationFilePath(env: NodeJS.ProcessEnv = process.env, cwd = process.cwd()): string {
  return join(piWebDataDir(env, cwd), "native-auth-migrations.json");
}

export function parseLegacyAuthMigrationFile(value: unknown): LegacyAuthMigrationFile {
  if (!isRecord(value) || !Array.isArray(value["migrations"])) throw new Error("Invalid legacy auth migration journal");
  return { migrations: value["migrations"].map(parseMigrationRecord) };
}

async function inspectLegacyAuthFile(authPath: string): Promise<{ credentials: { providerId: string; credential: Credential }[] } | LegacyAuthMigrationPreview> {
  let content: string;
  try {
    content = await readFileWithLimit(authPath, MAX_LEGACY_AUTH_BYTES);
  } catch (error) {
    if (isNodeError(error, "ENOENT")) return unavailable(false, "No legacy auth.json was found");
    return unavailable(true, error instanceof Error ? error.message : "Legacy auth.json could not be read");
  }
  let data: unknown;
  try { data = JSON.parse(content); } catch { return unavailable(true, "Legacy auth.json is not valid JSON"); }
  if (!isRecord(data)) return unavailable(true, "Legacy auth.json must be a credential object");
  const credentials: { providerId: string; credential: Credential }[] = [];
  for (const [providerId, value] of Object.entries(data)) {
    if (!isProviderId(providerId) || !isCredential(value)) return unavailable(true, "Legacy auth.json contains an unsupported credential");
    if (Buffer.byteLength(JSON.stringify(value), "utf8") > MAX_SERIALIZED_CREDENTIAL_BYTES) return unavailable(true, "A legacy credential is too large for secure Keychain migration");
    credentials.push({ providerId, credential: value });
  }
  return { credentials: credentials.sort((left, right) => left.providerId.localeCompare(right.providerId)) };
}

function unavailable(sourceExists: boolean, issue: string): LegacyAuthMigrationPreview {
  return { available: true, source: "legacy-auth-json", sourceExists, eligible: false, credentials: [], issue };
}

function isLegacyAuthInspection(
  value: { credentials: { providerId: string; credential: Credential }[] } | LegacyAuthMigrationPreview,
): value is { credentials: { providerId: string; credential: Credential }[] } {
  return value.credentials.every((credential) => "credential" in credential);
}

function markCreated(record: LegacyAuthMigrationRecord, providerId: string): LegacyAuthMigrationRecord {
  return { ...record, credentials: record.credentials.map((credential) => credential.providerId === providerId ? { ...credential, created: true } : credential) };
}

async function readFileWithLimit(path: string, maxBytes: number): Promise<string> {
  const content = await readFile(path, "utf8");
  if (Buffer.byteLength(content, "utf8") > maxBytes) throw new Error("Legacy auth.json exceeds the migration size limit");
  return content;
}

async function atomicWrite(path: string, data: LegacyAuthMigrationFile): Promise<void> {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = join(dirname(path), `.${basename(path)}.${String(process.pid)}.${String(Date.now())}.${randomUUID()}.tmp`);
  try {
    await writeFile(temporary, `${JSON.stringify(data, null, 2)}\n`, { encoding: "utf8", mode: 0o600 });
    await rename(temporary, path);
    await chmod(path, 0o600);
  } catch (error) {
    await unlink(temporary).catch(() => undefined);
    throw error;
  }
}

function parseMigrationRecord(value: unknown): LegacyAuthMigrationRecord {
  if (!isRecord(value) || typeof value["id"] !== "string" || typeof value["createdAt"] !== "string" || !isMigrationState(value["state"]) || !Array.isArray(value["credentials"]) || typeof value["rollbackEligible"] !== "boolean") throw new Error("Invalid legacy auth migration journal");
  const credentials = value["credentials"].map((credential) => {
    if (!isRecord(credential) || !isProviderId(credential["providerId"]) || !isCredentialType(credential["type"]) || typeof credential["created"] !== "boolean") throw new Error("Invalid legacy auth migration journal");
    return { providerId: credential["providerId"], type: credential["type"], created: credential["created"] };
  });
  return { id: value["id"], source: "legacy-auth-json", createdAt: value["createdAt"], state: value["state"], credentials, rollbackEligible: value["rollbackEligible"], ...(typeof value["completedAt"] === "string" ? { completedAt: value["completedAt"] } : {}), ...(typeof value["error"] === "string" ? { error: value["error"] } : {}) };
}

function isMigrationState(value: unknown): value is LegacyAuthMigrationState {
  return value === "writing" || value === "verified" || value === "rolled-back" || value === "rollback-required";
}

function isCredential(value: unknown): value is Credential {
  return isRecord(value) && isCredentialType(value["type"]) && Object.values(value).every(isJsonValue);
}

function isCredentialType(value: unknown): value is Credential["type"] { return value === "api_key" || value === "oauth"; }
function isProviderId(value: unknown): value is string { return typeof value === "string" && /^[a-z0-9][a-z0-9._-]{0,127}$/iu.test(value); }
function isRecord(value: unknown): value is Record<string, unknown> { return typeof value === "object" && value !== null && !Array.isArray(value); }
function isJsonValue(value: unknown): boolean { return value === null || typeof value === "string" || typeof value === "number" || typeof value === "boolean" || Array.isArray(value) && value.every(isJsonValue) || isRecord(value) && Object.values(value).every(isJsonValue); }
function isNodeError(error: unknown, code: string): error is NodeJS.ErrnoException { return error instanceof Error && "code" in error && error.code === code; }
