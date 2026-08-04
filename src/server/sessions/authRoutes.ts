import type { FastifyInstance } from "fastify";
import {
  RUNTIME_COMMAND_KINDS,
  type RuntimeCommandReceipts,
  requireRuntimeCommandEpoch,
  requireRuntimeCommandId,
  runtimeCommandErrorStatus,
  runtimeCommandFingerprint,
} from "../runtimeCommandReceipts.js";
import type { AuthService } from "./authService.js";

export function registerAuthRoutes(
  app: FastifyInstance,
  auth: AuthService,
  prefix = "",
  runtimeCommandReceipts?: RuntimeCommandReceipts,
): void {
  app.get<{ Querystring: { mode?: "login" | "logout"; authType?: "oauth" | "api_key" } }>(`${prefix}/auth/providers`, async (request, reply) => {
    try {
      return await auth.authProviders(request.query.mode ?? "login", request.query.authType);
    } catch (error) {
      return reply.code(404).send({ error: error instanceof Error ? error.message : String(error) });
    }
  });

  app.post<{ Body: { providerId: string; key: string } }>(`${prefix}/auth/api-key`, async (request, reply) => {
    try {
      return await auth.saveApiKey(request.body.providerId, request.body.key);
    } catch (error) {
      return reply.code(400).send({ error: error instanceof Error ? error.message : String(error) });
    }
  });

  // Additive endpoint for newer browsers; the one-secret route remains for
  // rolling compatibility with older browser bundles.
  app.post<{ Body: { providerId: string } }>(`${prefix}/auth/api-key/interactive`, async (request, reply) => {
    try {
      return await auth.startApiKeyLogin(request.body.providerId);
    } catch (error) {
      return reply.code(400).send({ error: error instanceof Error ? error.message : String(error) });
    }
  });

  app.post<{ Body: { providerId: string } }>(`${prefix}/auth/logout`, async (request, reply) => {
    try {
      return await auth.logoutProvider(request.body.providerId);
    } catch (error) {
      return reply.code(400).send({ error: error instanceof Error ? error.message : String(error) });
    }
  });

  app.post<{ Body: { providerId: string } }>(`${prefix}/auth/oauth`, async (request, reply) => {
    try {
      return await auth.startOAuthLogin(request.body.providerId);
    } catch (error) {
      return reply.code(400).send({ error: error instanceof Error ? error.message : String(error) });
    }
  });

  app.get<{ Params: { flowId: string } }>(`${prefix}/auth/oauth/:flowId`, async (request, reply) => {
    try {
      return auth.oauthFlow(request.params.flowId);
    } catch (error) {
      return reply.code(404).send({ error: error instanceof Error ? error.message : String(error) });
    }
  });

  app.post<{ Params: { flowId: string }; Body: { requestId: string; value: string } }>(`${prefix}/auth/oauth/:flowId/respond`, async (request, reply) => {
    try {
      return auth.respondToOAuthFlow(request.params.flowId, request.body.requestId, request.body.value);
    } catch (error) {
      return reply.code(400).send({ error: error instanceof Error ? error.message : String(error) });
    }
  });

  app.post<{ Params: { flowId: string } }>(`${prefix}/auth/oauth/:flowId/cancel`, async (request, reply) => {
    try {
      return auth.cancelOAuthFlow(request.params.flowId);
    } catch (error) {
      return reply.code(400).send({ error: error instanceof Error ? error.message : String(error) });
    }
  });

  app.get(`${prefix}/auth/legacy-migration/preview`, async (request, reply) => {
    try {
      return await auth.legacyAuthMigrationPreview();
    } catch (error) {
      return reply.code(404).send({ error: error instanceof Error ? error.message : String(error) });
    }
  });

  app.post<{ Body: { commandId?: unknown; runtimeEpoch?: unknown; providerIds?: unknown } }>(`${prefix}/auth/legacy-migration`, async (request, reply) => {
    try {
      if (runtimeCommandReceipts === undefined) throw new Error("Legacy auth migration requires the native Runtime receipt service");
      const providerIds = requireProviderIds(request.body.providerIds);
      const commandId = requireRuntimeCommandId(request.body.commandId);
      return await runtimeCommandReceipts.execute(
        {
          commandId,
          kind: RUNTIME_COMMAND_KINDS.migrateLegacyAuth,
          expectedRuntimeEpoch: requireRuntimeCommandEpoch(request.body.runtimeEpoch),
          fingerprint: runtimeCommandFingerprint({ kind: RUNTIME_COMMAND_KINDS.migrateLegacyAuth, providerIds: [...providerIds].sort() }),
        },
        async () => ({ migrated: true, migration: await auth.migrateLegacyAuth(providerIds) }),
      );
    } catch (error) {
      return reply.code(runtimeCommandErrorStatus(error) ?? 400).send({ error: error instanceof Error ? error.message : String(error) });
    }
  });

  app.get<{ Params: { migrationId: string } }>(`${prefix}/auth/legacy-migration/:migrationId`, async (request, reply) => {
    try {
      const migration = await auth.legacyAuthMigrationStatus(request.params.migrationId);
      if (migration === undefined) return await reply.code(404).send({ error: "Legacy auth migration was not found" });
      return migration;
    } catch (error) {
      return reply.code(404).send({ error: error instanceof Error ? error.message : String(error) });
    }
  });

  app.post<{ Params: { migrationId: string }; Body: { commandId?: unknown; runtimeEpoch?: unknown } }>(`${prefix}/auth/legacy-migration/:migrationId/rollback`, async (request, reply) => {
    try {
      if (runtimeCommandReceipts === undefined) throw new Error("Legacy auth migration requires the native Runtime receipt service");
      const commandId = requireRuntimeCommandId(request.body.commandId);
      const migrationId = request.params.migrationId.trim();
      if (migrationId === "" || migrationId.length > 128) throw new Error("migration id is invalid");
      return await runtimeCommandReceipts.execute(
        {
          commandId,
          kind: RUNTIME_COMMAND_KINDS.rollbackLegacyAuthMigration,
          expectedRuntimeEpoch: requireRuntimeCommandEpoch(request.body.runtimeEpoch),
          fingerprint: runtimeCommandFingerprint({ kind: RUNTIME_COMMAND_KINDS.rollbackLegacyAuthMigration, migrationId }),
        },
        async () => ({ rolledBack: true, migration: await auth.rollbackLegacyAuthMigration(migrationId) }),
      );
    } catch (error) {
      return reply.code(runtimeCommandErrorStatus(error) ?? 400).send({ error: error instanceof Error ? error.message : String(error) });
    }
  });
}

function requireProviderIds(value: unknown): string[] {
  if (!Array.isArray(value) || value.length === 0 || value.length > 128 || !value.every((providerId) => typeof providerId === "string" && /^[a-z0-9][a-z0-9._-]{0,127}$/iu.test(providerId))) {
    throw new Error("providerIds must be a non-empty list of valid provider ids");
  }
  return [...new Set(value.filter(isProviderId))];
}

function isProviderId(value: unknown): value is string {
  return typeof value === "string" && /^[a-z0-9][a-z0-9._-]{0,127}$/iu.test(value);
}
