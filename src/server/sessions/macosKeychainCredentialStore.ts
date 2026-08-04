import { access, constants } from "node:fs/promises";
import { spawn } from "node:child_process";
import type { Credential, CredentialInfo, CredentialStore } from "@earendil-works/pi-ai";

export const PI_AGENT_KEYCHAIN_HELPER_ENV = "PI_AGENT_KEYCHAIN_HELPER";

type KeychainOperation = "read" | "write" | "delete" | "list";

interface KeychainHelperRequest {
  operation: KeychainOperation;
  providerId?: string;
  credentialBase64?: string;
  credentialType?: Credential["type"];
}

interface KeychainHelperResponse {
  found?: boolean;
  credentialBase64?: string;
  credentialType?: Credential["type"];
  credentials?: CredentialInfo[];
  error?: string;
}

export type KeychainHelperRunner = (request: KeychainHelperRequest) => Promise<KeychainHelperResponse>;

/**
 * Persistent CredentialStore for an App-bundled Runtime. The Node process
 * never invokes `security` with a secret command-line argument and SwiftUI
 * never sees a credential: the signed-in macOS user's Keychain is accessed by
 * the small Security.framework helper over stdin/stdout only.
 *
 * The helper is intentionally constrained to Pi Agent's service namespace and
 * provider-id-shaped accounts. Its list operation returns only metadata; OAuth
 * refresh and login keep using the SDK's serialized `modify` contract.
 */
export class MacOSKeychainCredentialStore implements CredentialStore {
  private readonly chains = new Map<string, Promise<void>>();

  constructor(private readonly run: KeychainHelperRunner) {}

  async read(providerId: string): Promise<Credential | undefined> {
    validateProviderId(providerId);
    const result = await this.run({ operation: "read", providerId });
    if (result.found !== true) return undefined;
    if (typeof result.credentialBase64 !== "string" || !isCredentialType(result.credentialType)) {
      throw new Error("Pi Agent Keychain returned an invalid credential record");
    }
    const credential = parseCredential(result.credentialBase64, providerId);
    if (credential.type !== result.credentialType) {
      throw new Error("Pi Agent Keychain credential metadata did not match its stored value");
    }
    return credential;
  }

  async list(): Promise<readonly CredentialInfo[]> {
    const result = await this.run({ operation: "list" });
    const credentials = result.credentials ?? [];
    if (!credentials.every((credential) => isCredentialInfo(credential))) {
      throw new Error("Pi Agent Keychain returned invalid credential metadata");
    }
    return credentials
      .map((credential) => ({ providerId: credential.providerId, type: credential.type }))
      .sort((left, right) => left.providerId.localeCompare(right.providerId));
  }

  modify(
    providerId: string,
    fn: (current: Credential | undefined) => Promise<Credential | undefined>,
  ): Promise<Credential | undefined> {
    validateProviderId(providerId);
    return this.enqueue(providerId, async () => {
      const next = await fn(await this.read(providerId));
      if (next === undefined) return await this.read(providerId);
      await this.write(providerId, next);
      return next;
    });
  }

  delete(providerId: string): Promise<void> {
    validateProviderId(providerId);
    return this.enqueue(providerId, async () => {
      await this.run({ operation: "delete", providerId });
    });
  }

  private async write(providerId: string, credential: Credential): Promise<void> {
    const serialized = Buffer.from(JSON.stringify(credential), "utf8").toString("base64");
    await this.run({
      operation: "write",
      providerId,
      credentialBase64: serialized,
      credentialType: credential.type,
    });
  }

  private enqueue<T>(providerId: string, task: () => Promise<T>): Promise<T> {
    const previous = this.chains.get(providerId) ?? Promise.resolve();
    const next = previous.then(task, task);
    this.chains.set(providerId, next.then(() => undefined, () => undefined));
    return next;
  }
}

/** Returns undefined for development/sessiond runtimes that were not bundled by the App. */
export async function createMacOSKeychainCredentialStore(
  environment: NodeJS.ProcessEnv,
): Promise<MacOSKeychainCredentialStore | undefined> {
  const helperPath = environment[PI_AGENT_KEYCHAIN_HELPER_ENV]?.trim();
  if (helperPath === undefined || helperPath === "") return undefined;
  if (process.platform !== "darwin") throw new Error("Pi Agent Keychain helper is only available on macOS");
  await access(helperPath, constants.X_OK);
  return new MacOSKeychainCredentialStore(createProcessRunner(helperPath));
}

function createProcessRunner(helperPath: string): KeychainHelperRunner {
  return async (request) => await new Promise<KeychainHelperResponse>((resolve, reject) => {
    const child = spawn(helperPath, [], { stdio: ["pipe", "pipe", "pipe"] });
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    child.stdout.on("data", (chunk: Buffer) => stdout.push(chunk));
    child.stderr.on("data", (chunk: Buffer) => stderr.push(chunk));
    child.once("error", reject);
    child.once("close", (code) => {
      const output = Buffer.concat(stdout).toString("utf8");
      if (code !== 0) {
        reject(new Error(`Pi Agent Keychain helper failed${stderr.length === 0 ? "" : `: ${Buffer.concat(stderr).toString("utf8").trim()}`}`));
        return;
      }
      try {
        const response: unknown = JSON.parse(output);
        if (!isKeychainHelperResponse(response)) throw new Error("response must be an object");
        if (typeof response.error === "string" && response.error !== "") throw new Error(response.error);
        resolve(response);
      } catch (error) {
        reject(error instanceof Error ? error : new Error(String(error)));
      }
    });
    child.stdin.end(JSON.stringify(request));
  });
}

function parseCredential(encoded: string, providerId: string): Credential {
  let parsed: unknown;
  try {
    parsed = JSON.parse(Buffer.from(encoded, "base64").toString("utf8"));
  } catch {
    throw new Error(`Pi Agent Keychain credential for ${providerId} could not be decoded`);
  }
  if (!isCredential(parsed)) throw new Error(`Pi Agent Keychain credential for ${providerId} was invalid`);
  return parsed;
}

function validateProviderId(providerId: string): void {
  if (!/^[a-z0-9][a-z0-9._-]{0,127}$/iu.test(providerId)) {
    throw new Error("Provider id is invalid for Pi Agent Keychain");
  }
}

function isCredential(value: unknown): value is Credential {
  return isRecord(value)
    && (value["type"] === "api_key" || value["type"] === "oauth")
    && Object.values(value).every((item) => isJSONValue(item));
}

function isCredentialInfo(value: unknown): value is CredentialInfo {
  return isRecord(value)
    && typeof value["providerId"] === "string"
    && isCredentialType(value["type"])
    && /^[a-z0-9][a-z0-9._-]{0,127}$/iu.test(value["providerId"]);
}

function isCredentialType(value: unknown): value is Credential["type"] {
  return value === "api_key" || value === "oauth";
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isKeychainHelperResponse(value: unknown): value is KeychainHelperResponse {
  return isRecord(value);
}

function isJSONValue(value: unknown): boolean {
  if (value === null || typeof value === "string" || typeof value === "number" || typeof value === "boolean") return true;
  if (Array.isArray(value)) return value.every(isJSONValue);
  return isRecord(value) && Object.values(value).every(isJSONValue);
}
