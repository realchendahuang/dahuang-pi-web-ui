#!/usr/bin/env node
import Fastify from "fastify";
import fastifyWebsocket from "@fastify/websocket";
import { WorkspaceActivityService } from "./activity/workspaceActivityService.js";
import { registerWorkspaceActivityRoutes } from "./activity/workspaceActivityRoutes.js";
import { SessionEventHub } from "./realtime/sessionEventHub.js";
import { AuthService } from "./sessions/authService.js";
import { bootstrapAndFreezeGlobalExtensionProviders } from "./sessions/globalProviderPolicy.js";
import { registerAuthRoutes } from "./sessions/authRoutes.js";
import { PiSessionService } from "./sessions/piSessionService.js";
import { createPiSessionManagerGateway } from "./sessions/piSessionManagerGateway.js";
import { registerSessionRoutes } from "./sessions/sessionRoutes.js";
import { SessionNotificationStore } from "./sessions/sessionNotificationStore.js";
import {
	FileSessionUnreadPersistence,
	SessionUnreadStore,
} from "./sessions/sessionUnreadStore.js";
import { ProjectScopedSpawnTargetResolver } from "./sessions/spawnTargetResolver.js";
import { ProjectService } from "./projects/projectService.js";
import { ProjectStore } from "./storage/projectStore.js";
import { WorkspaceService } from "./workspaces/workspaceService.js";
import { sessiondSocketPath } from "../sessiond/config.js";
import { TerminalService } from "./terminals/terminalService.js";
import { registerTerminalRoutes } from "./terminals/terminalRoutes.js";
import { registerNativeGitRoutes } from "./git/nativeGitRoutes.js";
import { getPiWebRuntimeComponent } from "./piWebStatus.js";
import { SESSIOND_RUNTIME_CAPABILITIES } from "../shared/capabilities.js";
import {
	agentSessionDirEnvKeys,
	defaultAgentRuntimeId,
	effectiveOmpRuntimeConfig,
	effectivePiWebConfig,
	maxUploadBytes,
} from "../config.js";
import { createActiveAgentProfileDescriptor } from "../sessiond/activeAgentProfile.js";
import { runSessionDaemonStartup } from "./sessiond/sessionDaemonStartup.js";
import { MultiRuntimeSessionService } from "./runtimes/multiRuntimeSessionService.js";
import { OmpSessionService } from "./runtimes/omp/ompSessionService.js";
import {
	loadNativeRuntimeIdentity,
	nativeRuntimeHello,
} from "./nativeRuntimeManifest.js";
import {
	prepareSessiondSocketPath,
	removeOwnedSessiondSocket,
	secureSessiondSocket,
} from "../sessiond/sessiondSocketSecurity.js";
import {
	RUNTIME_COMMAND_KINDS,
	RuntimeCommandReceipts,
	requireRuntimeCommandEpoch,
	requireRuntimeCommandId,
	runtimeCommandErrorStatus,
	runtimeCommandFingerprint,
} from "./runtimeCommandReceipts.js";

const daemonEnvironment: NodeJS.ProcessEnv = Object.freeze({ ...process.env });
const nativeRuntimeIdentity = loadNativeRuntimeIdentity(daemonEnvironment);
const { config } = effectivePiWebConfig({ env: daemonEnvironment });
const activeAgentProfile = createActiveAgentProfileDescriptor({
	command: config.agent.command,
	dir: config.agent.dir,
	sessionDirEnvKeys: agentSessionDirEnvKeys(config.agent.command),
});
const defaultRuntimeValue = defaultAgentRuntimeId(daemonEnvironment, config);
const ompRuntime = effectiveOmpRuntimeConfig(daemonEnvironment, config);
const app = Fastify({
	logger: true,
	bodyLimit: maxUploadBytes(daemonEnvironment, config),
});
await app.register(fastifyWebsocket);

await runSessionDaemonStartup({
	logger: app.log,
	async createRuntime() {
		const eventHub = new SessionEventHub();
		const notificationStore = new SessionNotificationStore();
		const unreadStore = new SessionUnreadStore({
			persistence: new FileSessionUnreadPersistence(),
			onPersistenceError(operation, error) {
				app.log.error(
					{ err: error, operation },
					"session unread persistence failed",
				);
			},
		});
		await unreadStore.load();
		const workspaceActivity = new WorkspaceActivityService(eventHub);
		const auth = await AuthService.create({
			agentDir: activeAgentProfile.dir,
			logger: app.log,
		});
		// Capture providers registered by global extensions while the runtime is
		// still mutable, then freeze every later extension-provider mutation before
		// any real session can load project resources.
		await bootstrapAndFreezeGlobalExtensionProviders(
			auth.runtime,
			activeAgentProfile.dir,
			app.log,
		);
		const spawnTargets = config.spawnSessions
			? new ProjectScopedSpawnTargetResolver({
					projects: new ProjectService(new ProjectStore()),
					workspaces: new WorkspaceService(),
				})
			: undefined;
		const piSessions = new PiSessionService(eventHub, {
			modelRuntime: auth.runtime,
			agentDir: activeAgentProfile.dir,
			agentCommand: activeAgentProfile.command,
			workspaceActivity,
			logger: app.log,
			...(spawnTargets === undefined ? {} : { spawnTargets }),
			subsessionsEnabled: spawnTargets !== undefined && config.subsessions,
			notificationStore,
			unreadStore,
			sessionManager: createPiSessionManagerGateway({
				agentDir: activeAgentProfile.dir,
				env: daemonEnvironment,
				sessionDirEnvKeys: activeAgentProfile.sessionDirEnvKeys,
			}),
		});
		const ompSessions = new OmpSessionService(eventHub, {
			command: ompRuntime.command,
			agentDir: ompRuntime.dir,
			env: daemonEnvironment,
			workspaceActivity,
		});
		const sessions = new MultiRuntimeSessionService(
			piSessions,
			ompSessions,
			defaultRuntimeValue,
		);
		const runtimeCommandReceipts = new RuntimeCommandReceipts(
			nativeRuntimeIdentity.runtimeEpoch,
		);
		auth.subscribe((change) => {
			sessions.applyAuthChange(change);
		});
		const terminals = new TerminalService(eventHub, workspaceActivity);
		const runtimeComponent = Object.freeze({
			...getPiWebRuntimeComponent("sessiond", SESSIOND_RUNTIME_CAPABILITIES),
			activeAgentProfile,
		});
		return {
			eventHub,
			workspaceActivity,
			auth,
			sessions,
			runtimeCommandReceipts,
			terminals,
			unreadStore,
			activeAgentProfile,
			runtimeComponent,
		};
	},
	registerRoutes({
		eventHub,
		workspaceActivity,
		auth,
		sessions,
		runtimeCommandReceipts,
		terminals,
		runtimeComponent,
	}) {
		registerWorkspaceActivityRoutes(app, workspaceActivity);
		registerAuthRoutes(app, auth);
		registerSessionRoutes(app, sessions, eventHub, "", {
			runtimeCommandReceipts,
		});
		registerTerminalRoutes(app, terminals, "", { runtimeCommandReceipts });
		registerNativeGitRoutes(app, runtimeCommandReceipts);

		app.get("/health", () => ({
			ok: true,
			activeSessions: sessions.activeCount(),
			checkedAt: new Date().toISOString(),
			version: {
				component: runtimeComponent.component,
				label: runtimeComponent.label,
				...(runtimeComponent.runtimeVersion === undefined
					? {}
					: { runtimeVersion: runtimeComponent.runtimeVersion }),
				stale: false,
				available: runtimeComponent.available,
			},
		}));

		app.get("/runtime", () => runtimeComponent);
		app.get("/runtime/hello", () => nativeRuntimeHello(nativeRuntimeIdentity));
		app.get<{ Params: { commandId: string } }>(
			"/runtime/commands/:commandId",
			async (request, reply) => {
				try {
					const commandId = requireRuntimeCommandId(request.params.commandId);
					const receipt = runtimeCommandReceipts.get(commandId);
					if (receipt === undefined)
						return await reply
							.code(404)
							.send({ error: "Runtime command receipt not found" });
					return await receipt;
				} catch (error) {
					return reply.code(400).send({
						error: error instanceof Error ? error.message : String(error),
					});
				}
			},
		);
		app.post<{ Body: { commandId?: unknown; runtimeEpoch?: unknown } }>(
			"/runtime/commands/abort-active-work",
			async (request, reply) => {
				try {
					const commandId = requireRuntimeCommandId(request.body.commandId);
					return await runtimeCommandReceipts.execute(
						{
							commandId,
							kind: RUNTIME_COMMAND_KINDS.abortActiveWork,
							expectedRuntimeEpoch: requireRuntimeCommandEpoch(
								request.body.runtimeEpoch,
							),
							fingerprint: runtimeCommandFingerprint({
								kind: RUNTIME_COMMAND_KINDS.abortActiveWork,
							}),
						},
						() => sessions.abortActiveWork(),
					);
				} catch (error) {
					return reply.code(runtimeCommandErrorStatus(error) ?? 400).send({
						error: error instanceof Error ? error.message : String(error),
					});
				}
			},
		);
	},
	async listen({ auth, sessions, terminals, unreadStore }) {
		let shuttingDown = false;
		async function shutdown(signal: NodeJS.Signals): Promise<void> {
			if (shuttingDown) return;
			shuttingDown = true;
			app.log.info({ signal }, "shutting down session daemon");
			const attempt = async (
				operation: string,
				run: () => void | Promise<void>,
			): Promise<void> => {
				try {
					await run();
				} catch (error: unknown) {
					process.exitCode = 1;
					app.log.error(
						{ err: error, operation },
						"session daemon shutdown operation failed",
					);
				}
			};
			await attempt("dispose terminals", () => {
				terminals.dispose();
			});
			await attempt("dispose auth", () => {
				auth.dispose();
			});
			await attempt("dispose sessions", () => sessions.dispose());
			await attempt("flush session unread state", () => unreadStore.flush());
			await attempt("close server", () => app.close());
		}

		process.once("SIGINT", (signal) => {
			void shutdown(signal);
		});
		process.once("SIGTERM", (signal) => {
			void shutdown(signal);
		});

		const portValue = daemonEnvironment["PI_WEB_SESSIOND_PORT"];
		const port =
			portValue !== undefined && portValue !== ""
				? Number(portValue)
				: undefined;
		const host = daemonEnvironment["PI_WEB_SESSIOND_HOST"] ?? "127.0.0.1";

		if (port !== undefined) {
			await app.listen({ port, host });
		} else {
			const path = sessiondSocketPath();
			await prepareSessiondSocketPath(path);
			await app.listen({ path });
			const socketIdentity = await secureSessiondSocket(path);
			process.on("exit", () =>
				void removeOwnedSessiondSocket(path, socketIdentity),
			);
		}
	},
});
