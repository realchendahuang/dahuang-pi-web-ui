import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import type { AuthInteraction } from "@earendil-works/pi-ai";
import type { CredentialStore } from "@earendil-works/pi-ai";
import type { AuthProvidersResponse, AuthType, OAuthFlowState } from "../../shared/apiTypes.js";
import { getLoginProviderOptions, getLogoutProviderOptions } from "./authProviderOptions.js";
import {
  LegacyAuthMigrationService,
  type LegacyAuthMigrationPreview,
  type LegacyAuthMigrationRecord,
} from "./legacyAuthMigration.js";
import { OAuthLoginFlowService } from "./oauthLoginFlowService.js";

export interface AuthChange {
  removedProviderId?: string;
}

type AuthChangeListener = (change: AuthChange) => void | Promise<void>;

export interface AuthServiceDependencies {
  agentDir?: string;
  runtime?: ModelRuntime;
  authFlows?: OAuthLoginFlowService;
  logger?: AuthServiceLogger;
  credentials?: CredentialStore;
  legacyAuthMigration?: LegacyAuthMigrationService;
}

/** Minimal structured-logging seam for non-fatal auth propagation failures. */
export interface AuthServiceLogger {
  error(details: Record<string, unknown>, message: string): void;
}

interface AuthChangeContext {
  operation: "login" | "logout";
  providerId: string;
  authType?: AuthType;
}

const noopLogger: AuthServiceLogger = { error() { /* no-op */ } };

export function createModelRuntimeForAgentDir(
  agentDir: string,
  allowModelNetwork?: boolean,
  credentials?: CredentialStore,
): Promise<ModelRuntime> {
  return ModelRuntime.create({
    ...(credentials === undefined ? { authPath: join(agentDir, "auth.json") } : { credentials }),
    modelsPath: join(agentDir, "models.json"),
    ...(allowModelNetwork === undefined ? {} : { allowModelNetwork }),
  });
}

export class AuthService {
  readonly runtime: ModelRuntime;
  private readonly authFlows: OAuthLoginFlowService;
  private readonly logger: AuthServiceLogger;
  private readonly legacyAuthMigration: LegacyAuthMigrationService | undefined;
  private readonly listeners = new Set<AuthChangeListener>();

  private constructor(
    runtime: ModelRuntime,
    authFlows: OAuthLoginFlowService,
    logger: AuthServiceLogger,
    legacyAuthMigration?: LegacyAuthMigrationService,
  ) {
    this.runtime = runtime;
    this.authFlows = authFlows;
    this.logger = logger;
    this.legacyAuthMigration = legacyAuthMigration;
  }

  static async create(deps: AuthServiceDependencies = {}): Promise<AuthService> {
    const runtime = deps.runtime ?? (deps.agentDir === undefined
      ? await ModelRuntime.create(deps.credentials === undefined ? {} : { credentials: deps.credentials })
      : await createModelRuntimeForAgentDir(deps.agentDir, undefined, deps.credentials));
    const logger = deps.logger ?? noopLogger;
    const authFlows = deps.authFlows ?? new OAuthLoginFlowService({ logger });
    const legacyAuthMigration = deps.legacyAuthMigration ?? (deps.credentials !== undefined && deps.agentDir !== undefined
      ? new LegacyAuthMigrationService(deps.credentials, join(deps.agentDir, "auth.json"))
      : undefined);
    return new AuthService(runtime, authFlows, logger, legacyAuthMigration);
  }

  subscribe(listener: AuthChangeListener): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  dispose(): void {
    this.authFlows.dispose();
    this.listeners.clear();
  }

  async authProviders(mode: "login" | "logout", authType?: AuthType): Promise<AuthProvidersResponse> {
    await this.runtime.reloadConfig();
    const providers = mode === "logout" ? await getLogoutProviderOptions(this.runtime) : getLoginProviderOptions(this.runtime, authType);
    return { providers };
  }

  async saveApiKey(providerId: string, key: string): Promise<{ accepted: true }> {
    if (key.trim() === "") throw new Error("API key is required");
    const provider = await this.requireApiKeyLoginProvider(providerId);
    let promptAttempted = false;
    const interaction: AuthInteraction = {
      prompt: (prompt) => {
        if (promptAttempted) {
          throw new Error(`${provider.name} requires interactive setup; use Pi's generic /login flow`);
        }
        promptAttempted = true;
        if (prompt.signal?.aborted === true) throw new Error("Login cancelled");
        if (prompt.type !== "secret") {
          throw new Error(`${provider.name} requires interactive setup; use Pi's generic /login flow`);
        }
        return Promise.resolve(key);
      },
      notify: () => undefined,
    };
    await this.runtime.login(providerId, "api_key", interaction);
    await this.emit({}, { operation: "login", providerId, authType: "api_key" });
    return { accepted: true };
  }

  async logoutProvider(providerId: string): Promise<{ accepted: true }> {
    await this.runtime.logout(providerId);
    await this.emit({ removedProviderId: providerId }, { operation: "logout", providerId });
    return { accepted: true };
  }

  async startApiKeyLogin(providerId: string): Promise<OAuthFlowState> {
    const provider = await this.requireApiKeyLoginProvider(providerId);
    return this.authFlows.start({
      providerId,
      providerName: provider.name,
      runtime: this.runtime,
      authType: "api_key",
      onComplete: () => this.emit({}, { operation: "login", providerId, authType: "api_key" }),
    });
  }

  async startOAuthLogin(providerId: string): Promise<OAuthFlowState> {
    const provider = await this.requireOAuthLoginProvider(providerId);
    return this.authFlows.start({
      providerId,
      providerName: provider.name,
      runtime: this.runtime,
      authType: "oauth",
      onComplete: () => this.emit({}, { operation: "login", providerId, authType: "oauth" }),
    });
  }

  oauthFlow(flowId: string): OAuthFlowState {
    return this.authFlows.get(flowId);
  }

  respondToOAuthFlow(flowId: string, requestId: string, value: string): OAuthFlowState {
    return this.authFlows.respond(flowId, requestId, value);
  }

  cancelOAuthFlow(flowId: string): OAuthFlowState {
    return this.authFlows.cancel(flowId);
  }

  async legacyAuthMigrationPreview(): Promise<LegacyAuthMigrationPreview> {
    return await this.requireLegacyAuthMigration().preview();
  }

  async migrateLegacyAuth(expectedProviderIds: readonly string[]): Promise<LegacyAuthMigrationRecord> {
    const migration = await this.requireLegacyAuthMigration().migrate(expectedProviderIds);
    await this.runtime.reloadConfig();
    await this.emit({}, { operation: "login", providerId: "legacy-auth-json" });
    return migration;
  }

  async rollbackLegacyAuthMigration(id: string): Promise<LegacyAuthMigrationRecord> {
    const migration = await this.requireLegacyAuthMigration().rollback(id);
    await this.runtime.reloadConfig();
    await this.emit({}, { operation: "logout", providerId: "legacy-auth-json" });
    return migration;
  }

  legacyAuthMigrationStatus(id: string): Promise<LegacyAuthMigrationRecord | undefined> {
    return this.requireLegacyAuthMigration().get(id);
  }

  private async emit(change: AuthChange, context: AuthChangeContext): Promise<void> {
    const results = await Promise.allSettled([...this.listeners].map(async (listener) => listener(change)));
    for (const result of results) {
      if (result.status === "rejected") {
        this.logErrorNoThrow({ err: result.reason, ...context }, "auth-change listener failed");
      }
    }
  }

  private logErrorNoThrow(details: Record<string, unknown>, message: string): void {
    try {
      this.logger.error(details, message);
    } catch {
      // A diagnostic failure cannot turn an already-committed auth mutation into an API failure.
    }
  }

  private async requireApiKeyLoginProvider(providerId: string) {
    await this.runtime.reloadConfig();
    const provider = getLoginProviderOptions(this.runtime, "api_key").find((option) => option.id === providerId);
    if (provider !== undefined) return provider;

    const knownProvider = this.runtime.getProviders().find((option) => option.id === providerId);
    if (knownProvider !== undefined) {
      throw new Error(`${knownProvider.name} does not support interactive API-key setup`);
    }
    throw new Error(`API key provider not found: ${providerId}`);
  }

  private async requireOAuthLoginProvider(providerId: string) {
    await this.runtime.reloadConfig();
    const provider = getLoginProviderOptions(this.runtime, "oauth").find((option) => option.id === providerId);
    if (provider === undefined) throw new Error(`OAuth provider not found: ${providerId}`);
    return provider;
  }

  private requireLegacyAuthMigration(): LegacyAuthMigrationService {
    if (this.legacyAuthMigration === undefined) {
      throw new Error("Legacy auth migration is available only in the bundled macOS Runtime");
    }
    return this.legacyAuthMigration;
  }
}
