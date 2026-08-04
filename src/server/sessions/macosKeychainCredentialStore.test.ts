import { describe, expect, it } from "vitest";
import { MacOSKeychainCredentialStore, type KeychainHelperRunner } from "./macosKeychainCredentialStore.js";

describe("MacOSKeychainCredentialStore", () => {
  it("keeps secrets inside the helper while list returns only provider metadata", async () => {
    const helper = new FakeKeychainHelper();
    const store = new MacOSKeychainCredentialStore(helper.run);
    await store.modify("anthropic", async () => {
      await Promise.resolve();
      return { type: "api_key", key: "sk-not-in-list" };
    });

    await expect(store.list()).resolves.toEqual([{ providerId: "anthropic", type: "api_key" }]);
    expect(helper.requests.filter((request) => request.operation === "list")).toEqual([{ operation: "list" }]);
    expect(JSON.stringify(helper.requests.filter((request) => request.operation === "list"))).not.toContain("sk-not-in-list");
    await expect(store.read("anthropic")).resolves.toEqual({ type: "api_key", key: "sk-not-in-list" });
  });

  it("serializes concurrent provider mutations so an OAuth refresh cannot overwrite a newer credential", async () => {
    const helper = new FakeKeychainHelper({ openai: { type: "api_key", key: "old" } });
    const store = new MacOSKeychainCredentialStore(helper.run);
    const first = store.modify("openai", async (current) => {
      await Promise.resolve();
      if (current?.type !== "api_key") throw new Error("Expected API-key credential");
      return { ...current, key: "first" };
    });
    const second = store.modify("openai", async (current) => {
      await Promise.resolve();
      if (current?.type !== "api_key") throw new Error("Expected API-key credential");
      return { ...current, key: "second" };
    });

    await expect(Promise.all([first, second])).resolves.toEqual([
      { type: "api_key", key: "first" },
      { type: "api_key", key: "second" },
    ]);
    await expect(store.read("openai")).resolves.toEqual({ type: "api_key", key: "second" });
  });

  it("rejects provider identifiers that could expand the helper account scope", async () => {
    const store = new MacOSKeychainCredentialStore(new FakeKeychainHelper().run);
    await expect(store.read("../../other-service")).rejects.toThrow("Provider id is invalid");
  });
});

class FakeKeychainHelper {
  readonly requests: Parameters<KeychainHelperRunner>[0][] = [];
  private readonly credentials = new Map<string, { type: "api_key" | "oauth"; encoded: string }>();

  constructor(seed: Record<string, { type: "api_key" | "oauth"; key: string }> = {}) {
    for (const [providerId, credential] of Object.entries(seed)) {
      this.credentials.set(providerId, { type: credential.type, encoded: encode(credential) });
    }
  }

  run: KeychainHelperRunner = (request) => {
    this.requests.push(request);
    if (request.operation === "list") {
      return Promise.resolve({ credentials: [...this.credentials].map(([providerId, credential]) => ({ providerId, type: credential.type })) });
    }
    const providerId = request.providerId;
    if (providerId === undefined) return Promise.reject(new Error("Expected provider id"));
    if (request.operation === "read") {
      const credential = this.credentials.get(providerId);
      return Promise.resolve(credential === undefined
        ? { found: false }
        : { found: true, credentialBase64: credential.encoded, credentialType: credential.type });
    }
    if (request.operation === "write") {
      if (request.credentialType === undefined || request.credentialBase64 === undefined) {
        return Promise.reject(new Error("Expected credential payload"));
      }
      this.credentials.set(providerId, { type: request.credentialType, encoded: request.credentialBase64 });
      return Promise.resolve({ found: true });
    }
    this.credentials.delete(providerId);
    return Promise.resolve({ found: false });
  };
}

function encode(value: unknown): string {
  return Buffer.from(JSON.stringify(value), "utf8").toString("base64");
}
