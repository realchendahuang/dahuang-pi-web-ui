import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { InMemoryCredentialStore, type CredentialStore } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { LegacyAuthMigrationService } from "./legacyAuthMigration.js";

const tempDirs: string[] = [];

afterEach(async () => {
  await Promise.all(tempDirs.splice(0).map((path) => rm(path, { recursive: true, force: true })));
});

describe("LegacyAuthMigrationService", () => {
  it("returns a redacted preview and preserves the legacy source after verified Keychain migration", async () => {
    const { authPath, journalPath } = await authFiles({
      anthropic: { type: "api_key", key: "secret-must-not-leak" },
      openai: { type: "oauth", access: "access-secret", refresh: "refresh-secret", expires: 1 },
    });
    const store = new InMemoryCredentialStore();
    const service = new LegacyAuthMigrationService(store, authPath, journalPath);

    await expect(service.preview()).resolves.toEqual({
      available: true,
      source: "legacy-auth-json",
      sourceExists: true,
      eligible: true,
      credentials: [
        { providerId: "anthropic", type: "api_key", status: "ready" },
        { providerId: "openai", type: "oauth", status: "ready" },
      ],
    });

    const migration = await service.migrate(["anthropic", "openai"]);
    expect(migration.state).toBe("verified");
    expect(migration.rollbackEligible).toBe(true);
    expect(await store.list()).toEqual([
      { providerId: "anthropic", type: "api_key" },
      { providerId: "openai", type: "oauth" },
    ]);
    await expect(readFile(authPath, "utf8")).resolves.toContain("secret-must-not-leak");
    const journal = await readFile(journalPath, "utf8");
    expect(journal).not.toContain("secret-must-not-leak");
    expect(journal).not.toContain("access-secret");
    expect(journal).not.toContain("refresh-secret");
  });

  it("refuses to overwrite an existing Keychain credential", async () => {
    const { authPath, journalPath } = await authFiles({ anthropic: { type: "api_key", key: "legacy-secret" } });
    const store = new InMemoryCredentialStore();
    await store.modify("anthropic", async () => {
      await Promise.resolve();
      return { type: "api_key", key: "keychain-secret" };
    });
    const service = new LegacyAuthMigrationService(store, authPath, journalPath);

    await expect(service.preview()).resolves.toMatchObject({ eligible: false, credentials: [{ providerId: "anthropic", status: "already-in-keychain" }] });
    await expect(service.migrate(["anthropic"])).rejects.toThrow("will not overwrite");
    await expect(store.read("anthropic")).resolves.toEqual({ type: "api_key", key: "keychain-secret" });
  });

  it("removes only already-created migration entries when a later Keychain write fails", async () => {
    const { authPath, journalPath } = await authFiles({
      anthropic: { type: "api_key", key: "first" },
      openai: { type: "api_key", key: "second" },
    });
    const store = new FailingCredentialStore("openai");
    const service = new LegacyAuthMigrationService(store, authPath, journalPath);

    await expect(service.migrate(["anthropic", "openai"])).rejects.toThrow("write failed");
    await expect(store.read("anthropic")).resolves.toBeUndefined();
    await expect(store.read("openai")).resolves.toBeUndefined();
    await expect(readFile(journalPath, "utf8")).resolves.toContain("rolled-back");
  });

  it("rolls back only the credentials created by the verified migration", async () => {
    const { authPath, journalPath } = await authFiles({ anthropic: { type: "api_key", key: "legacy-secret" } });
    const store = new InMemoryCredentialStore();
    const service = new LegacyAuthMigrationService(store, authPath, journalPath);
    const migration = await service.migrate(["anthropic"]);

    const rolledBack = await service.rollback(migration.id);
    expect(rolledBack.state).toBe("rolled-back");
    expect(rolledBack.rollbackEligible).toBe(false);
    await expect(store.read("anthropic")).resolves.toBeUndefined();
    await expect(readFile(authPath, "utf8")).resolves.toContain("legacy-secret");
  });
});

async function authFiles(data: unknown): Promise<{ authPath: string; journalPath: string }> {
  const directory = await mkdtemp(join(tmpdir(), "pi-web-legacy-auth-"));
  tempDirs.push(directory);
  const authPath = join(directory, "auth.json");
  await writeFile(authPath, JSON.stringify(data), "utf8");
  return { authPath, journalPath: join(directory, "native-auth-migrations.json") };
}

class FailingCredentialStore implements CredentialStore {
  private readonly store = new InMemoryCredentialStore();

  constructor(private readonly failingProvider: string) {}

  read(providerId: string) { return this.store.read(providerId); }
  list() { return this.store.list(); }
  delete(providerId: string) { return this.store.delete(providerId); }
  modify(providerId: string, fn: Parameters<CredentialStore["modify"]>[1]) {
    if (providerId === this.failingProvider) return Promise.reject(new Error("Keychain write failed"));
    return this.store.modify(providerId, fn);
  }
}
