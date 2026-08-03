export const AGENT_RUNTIME_IDS = {
	pi: "pi",
	omp: "omp",
} as const;

export type AgentRuntimeId =
	(typeof AGENT_RUNTIME_IDS)[keyof typeof AGENT_RUNTIME_IDS];

export type AgentRuntimeDriverKind = "pi-embedded" | "omp-rpc";

export const AGENT_RUNTIME_CAPABILITIES = {
	prompt: "prompt",
	promptAttachments: "prompt-attachments",
	abort: "abort",
	stop: "stop",
	resume: "resume",
	models: "models",
	thinkingLevels: "thinking-levels",
	steering: "steering",
	followUp: "follow-up",
	clearQueue: "clear-queue",
	shell: "shell",
	commands: "commands",
	branching: "branching",
	compaction: "compaction",
	permissions: "permissions",
	subagents: "subagents",
	extensionUi: "extension-ui",
	archive: "archive",
	notifications: "notifications",
	unread: "unread",
} as const;

export type AgentRuntimeCapability =
	(typeof AGENT_RUNTIME_CAPABILITIES)[keyof typeof AGENT_RUNTIME_CAPABILITIES];

export interface AgentRuntimeDescriptor {
	id: AgentRuntimeId;
	kind: AgentRuntimeDriverKind;
	label: string;
	available: boolean;
	command: string;
	profileDir: string;
	capabilities: AgentRuntimeCapability[];
	version?: string;
	protocolVersion?: number;
	unavailableReason?: string;
}

export interface AgentRuntimesResponse {
	defaultRuntimeId: AgentRuntimeId;
	runtimes: AgentRuntimeDescriptor[];
}

export function isAgentRuntimeId(value: unknown): value is AgentRuntimeId {
	return value === AGENT_RUNTIME_IDS.pi || value === AGENT_RUNTIME_IDS.omp;
}

export function agentRuntimeDescriptor(
	catalog: AgentRuntimesResponse | undefined,
	runtimeId: AgentRuntimeId | undefined,
): AgentRuntimeDescriptor | undefined {
	if (catalog === undefined || runtimeId === undefined) return undefined;
	return catalog.runtimes.find((runtime) => runtime.id === runtimeId);
}

export function supportsAgentRuntimeCapability(
	catalog: AgentRuntimesResponse | undefined,
	runtimeId: AgentRuntimeId | undefined,
	capability: AgentRuntimeCapability,
): boolean {
	const runtime = agentRuntimeDescriptor(catalog, runtimeId);
	return (
		runtime?.available === true && runtime.capabilities.includes(capability)
	);
}

export function selectedAvailableAgentRuntimeId(
	catalog: AgentRuntimesResponse,
	selected: AgentRuntimeId | undefined,
): AgentRuntimeId {
	const available = catalog.runtimes.filter((runtime) => runtime.available);
	if (
		selected !== undefined &&
		available.some((runtime) => runtime.id === selected)
	)
		return selected;
	if (available.some((runtime) => runtime.id === catalog.defaultRuntimeId))
		return catalog.defaultRuntimeId;
	return available[0]?.id ?? catalog.defaultRuntimeId;
}

export function requireAgentRuntimeId(
	value: unknown,
	label = "runtimeId",
): AgentRuntimeId {
	if (!isAgentRuntimeId(value))
		throw new Error(
			`${label} must be ${AGENT_RUNTIME_IDS.pi} or ${AGENT_RUNTIME_IDS.omp}`,
		);
	return value;
}
