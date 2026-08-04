import {
	createAgentSessionFromServices,
	createAgentSessionRuntime,
	createAgentSessionServices,
	SessionManager,
	type AgentSessionRuntime,
	type AgentSessionServices,
	type CreateAgentSessionRuntimeFactory,
	type ModelRuntime,
} from "@earendil-works/pi-coding-agent";

type CreateSessionFromServicesOptions = Parameters<
	typeof createAgentSessionFromServices
>[0];

export interface PiSdkSessionFactoryOptions {
	cwd: string;
	agentDir: string;
	modelRuntime: ModelRuntime;
	sessionManager: unknown;
	customTools: NonNullable<CreateSessionFromServicesOptions["customTools"]>;
	sessionStartEvent?: CreateSessionFromServicesOptions["sessionStartEvent"];
	initialModel?: CreateSessionFromServicesOptions["model"];
}

/**
 * The only adapter responsible for Pi's replaceable `AgentSessionRuntime`.
 *
 * PI WEB orchestration depends on its own narrow session interfaces. Keeping
 * runtime construction here confines upstream SDK lifecycle changes (notably
 * new/resume/fork replacement behavior) to one boundary instead of spreading
 * `instanceof SessionManager` and factory details through product services.
 */
export interface PiSdkRuntimeAdapter {
	createRuntime(
		factory: CreateAgentSessionRuntimeFactory,
		options: {
			cwd: string;
			agentDir: string;
			sessionManager: unknown;
		},
	): Promise<AgentSessionRuntime>;
	createSessionFromServices(
		options: PiSdkSessionFactoryOptions,
	): ReturnType<CreateAgentSessionRuntimeFactory>;
}

export function createPiSdkRuntimeAdapter(): PiSdkRuntimeAdapter {
	return {
		async createRuntime(factory, options) {
			const sessionManager = requireSessionManager(options.sessionManager);
			return await createAgentSessionRuntime(factory, {
				cwd: options.cwd,
				agentDir: options.agentDir,
				sessionManager,
			});
		},
		async createSessionFromServices(options) {
			const sessionManager = requireSessionManager(options.sessionManager);
			const services: AgentSessionServices = await createAgentSessionServices({
				cwd: options.cwd,
				agentDir: options.agentDir,
				modelRuntime: options.modelRuntime,
			});
			const result = await createAgentSessionFromServices({
				services,
				sessionManager,
				customTools: options.customTools,
				...(options.sessionStartEvent === undefined
					? {}
					: { sessionStartEvent: options.sessionStartEvent }),
				...(options.initialModel === undefined ? {} : { model: options.initialModel }),
			});
			return { ...result, services, diagnostics: services.diagnostics };
		},
	};
}

function requireSessionManager(sessionManager: unknown): SessionManager {
	if (!(sessionManager instanceof SessionManager)) {
		throw new Error("Pi SDK runtime creation requires an SDK SessionManager");
	}
	return sessionManager;
}
