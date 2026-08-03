import {
	api,
	type AgentRuntimesResponse,
	type Machine,
	type MachineHealth,
	type MachineRuntime,
} from "../api";
import {
	selectedAvailableAgentRuntimeId,
	type AgentRuntimeId,
} from "../../../shared/agentRuntime";
import { resetWorkspaceScopedState } from "../appState";
import type { GetState, SetState, UpdateUrl } from "./types";
import type { ProjectController } from "./projectController";

export class MachineController {
	private readonly runtimeRefreshSeqByMachine = new Map<string, number>();
	private readonly agentRuntimeRefreshSeqByMachine = new Map<string, number>();

	constructor(
		private readonly getState: GetState,
		private readonly setState: SetState,
		private readonly updateUrl: UpdateUrl,
		private readonly projects: Pick<ProjectController, "loadProjects">,
	) {}

	async loadMachines(routeMachineId?: string): Promise<void> {
		this.setState({ error: "", isLoadingMachines: true });
		try {
			const machines = await api.machines();
			const selectedMachine = await this.selectInitialMachine(
				machines,
				routeMachineId,
			);
			const machineIds = new Set(machines.map((machine) => machine.id));
			this.setState({
				machines,
				selectedMachine,
				machineActivities: filterKeys(
					this.getState().machineActivities,
					machineIds,
				),
				machineRuntimes: filterKeys(
					this.getState().machineRuntimes,
					machineIds,
				),
				agentRuntimeCatalogs: filterKeys(
					this.getState().agentRuntimeCatalogs,
					machineIds,
				),
				agentRuntimeCatalogErrors: filterKeys(
					this.getState().agentRuntimeCatalogErrors,
					machineIds,
				),
				selectedAgentRuntimeIds: filterKeys(
					this.getState().selectedAgentRuntimeIds,
					machineIds,
				),
			});
			void this.refreshMachineHealthFor(machines);
			void this.refreshMachineRuntimeFor(machines);
			void this.refreshAgentRuntimesFor(machines);
		} catch (error) {
			this.setState({ error: String(error) });
		} finally {
			this.setState({ isLoadingMachines: false });
		}
	}

	async selectMachine(
		machine: Machine,
		options: { updateUrl?: boolean | undefined } = {},
	): Promise<void> {
		if (this.getState().selectedMachine?.id === machine.id) return;
		this.setState({
			selectedMachine: machine,
			projects: [],
			workspaces: [],
			isLoadingWorkspaces: false,
			selectedProject: undefined,
			selectedWorkspace: undefined,
			selectedSession: undefined,
			messages: [],
			messagePageStart: 0,
			messagePageTotal: 0,
			status: undefined,
			activity: undefined,
			sessionStatuses: {},
			sessionActivities: {},
			sendingPrompts: {},
			workspaceActivities: {},
			workspacesByProjectId: {},
			workspaceDeletionRuns: {},
			activeTerminalCount: 0,
			...resetWorkspaceScopedState(),
		});
		if (options.updateUrl !== false) this.updateUrl();
		await this.projects.loadProjects();
		void this.refreshMachineHealth(machine.id);
		void this.refreshMachineRuntime(machine.id);
		void this.refreshAgentRuntimes(machine.id);
	}

	async addMachine(input: {
		name: string;
		baseUrl: string;
		token?: string;
	}): Promise<Machine | undefined> {
		this.setState({ error: "" });
		try {
			const machine = await api.addMachine(input);
			this.setState({
				machines: [
					...this.getState().machines.filter(
						(candidate) => candidate.id !== machine.id,
					),
					machine,
				],
			});
			await this.selectMachine(machine);
			return machine;
		} catch (error) {
			this.setState({ error: String(error) });
			return undefined;
		}
	}

	async deleteMachine(
		machine: Machine | undefined = this.getState().selectedMachine,
		options: { selectFallback?: boolean } = {},
	): Promise<Machine | undefined> {
		if (machine === undefined) return undefined;
		if (machine.kind === "local") {
			this.setState({ error: "The local machine cannot be removed." });
			return undefined;
		}
		try {
			const wasSelected = this.getState().selectedMachine?.id === machine.id;
			await api.deleteMachine(machine.id);
			const machines = this.getState().machines.filter(
				(candidate) => candidate.id !== machine.id,
			);
			const local =
				machines.find((candidate) => candidate.id === "local") ?? machines[0];
			this.setState({
				machines,
				machineStatuses: omitKey(this.getState().machineStatuses, machine.id),
				machineRuntimes: omitKey(this.getState().machineRuntimes, machine.id),
				machineActivities: omitKey(
					this.getState().machineActivities,
					machine.id,
				),
				agentRuntimeCatalogs: omitKey(
					this.getState().agentRuntimeCatalogs,
					machine.id,
				),
				agentRuntimeCatalogErrors: omitKey(
					this.getState().agentRuntimeCatalogErrors,
					machine.id,
				),
				selectedAgentRuntimeIds: omitKey(
					this.getState().selectedAgentRuntimeIds,
					machine.id,
				),
			});
			if (wasSelected && local !== undefined) {
				if (options.selectFallback === false) return local;
				await this.selectMachine(local);
				return local;
			}
			return undefined;
		} catch (error) {
			this.setState({ error: String(error) });
			return undefined;
		}
	}

	async refreshMachineHealth(
		machineId = this.getState().selectedMachine?.id ?? "local",
	): Promise<MachineHealth | undefined> {
		try {
			const health = await api.health(machineId);
			this.setState({
				machineStatuses: {
					...this.getState().machineStatuses,
					[health.machineId]: health,
				},
			});
			return health;
		} catch (error) {
			this.setState({ error: String(error) });
			return undefined;
		}
	}

	async refreshMachineRuntime(
		machineId = this.getState().selectedMachine?.id ?? "local",
	): Promise<MachineRuntime | undefined> {
		const seq = (this.runtimeRefreshSeqByMachine.get(machineId) ?? 0) + 1;
		this.runtimeRefreshSeqByMachine.set(machineId, seq);
		try {
			const runtime = await api.runtime(machineId, true);
			if (this.runtimeRefreshSeqByMachine.get(machineId) !== seq)
				return undefined;
			this.setState({
				machineRuntimes: {
					...this.getState().machineRuntimes,
					[runtime.machineId]: runtime,
				},
			});
			return runtime;
		} catch (error) {
			if (this.runtimeRefreshSeqByMachine.get(machineId) === seq)
				this.setState({ error: String(error) });
			return undefined;
		}
	}

	async refreshAgentRuntimes(
		machineId = this.getState().selectedMachine?.id ?? "local",
	): Promise<AgentRuntimesResponse | undefined> {
		const seq = (this.agentRuntimeRefreshSeqByMachine.get(machineId) ?? 0) + 1;
		this.agentRuntimeRefreshSeqByMachine.set(machineId, seq);
		try {
			const catalog = await api.runtimes(machineId);
			if (this.agentRuntimeRefreshSeqByMachine.get(machineId) !== seq)
				return undefined;
			const selectedRuntimeId = selectedAvailableAgentRuntimeId(
				catalog,
				this.getState().selectedAgentRuntimeIds[machineId],
			);
			this.setState({
				agentRuntimeCatalogs: {
					...this.getState().agentRuntimeCatalogs,
					[machineId]: catalog,
				},
				agentRuntimeCatalogErrors: omitKey(
					this.getState().agentRuntimeCatalogErrors,
					machineId,
				),
				selectedAgentRuntimeIds: {
					...this.getState().selectedAgentRuntimeIds,
					[machineId]: selectedRuntimeId,
				},
			});
			return catalog;
		} catch (error) {
			if (this.agentRuntimeRefreshSeqByMachine.get(machineId) === seq) {
				this.setState({
					agentRuntimeCatalogErrors: {
						...this.getState().agentRuntimeCatalogErrors,
						[machineId]: error instanceof Error ? error.message : String(error),
					},
				});
			}
			return undefined;
		}
	}

	selectAgentRuntime(
		runtimeId: AgentRuntimeId,
		machineId = this.getState().selectedMachine?.id ?? "local",
	): void {
		const catalog = this.getState().agentRuntimeCatalogs[machineId];
		const runtime = catalog?.runtimes.find(
			(candidate) => candidate.id === runtimeId,
		);
		if (runtime?.available !== true) return;
		this.setState({
			selectedAgentRuntimeIds: {
				...this.getState().selectedAgentRuntimeIds,
				[machineId]: runtimeId,
			},
		});
	}

	private async selectInitialMachine(
		machines: Machine[],
		routeMachineId?: string,
	): Promise<Machine | undefined> {
		const requestedMachine = machines.find(
			(machine) => machine.id === (routeMachineId ?? "local"),
		);
		if (requestedMachine === undefined) return this.localMachine(machines);
		if (requestedMachine.kind !== "remote") return requestedMachine;

		const health = await this.safeRemoteHealth(requestedMachine);
		this.setState({
			machineStatuses: {
				...this.getState().machineStatuses,
				[health.machineId]: health,
			},
			...(health.ok
				? {}
				: { error: `${requestedMachine.name} is unavailable; reconnecting…` }),
		});
		return requestedMachine;
	}

	private async safeRemoteHealth(machine: Machine): Promise<MachineHealth> {
		try {
			return await api.health(machine.id);
		} catch (error) {
			return {
				machineId: machine.id,
				ok: false,
				checkedAt: new Date().toISOString(),
				status: "offline",
				error: error instanceof Error ? error.message : String(error),
			};
		}
	}

	private localMachine(machines: Machine[]): Machine | undefined {
		return machines.find((machine) => machine.id === "local") ?? machines[0];
	}

	private async refreshMachineHealthFor(machines: Machine[]): Promise<void> {
		const results = await Promise.allSettled(
			machines.map((machine) => api.health(machine.id)),
		);
		const health = Object.fromEntries(
			results.flatMap((result) =>
				result.status === "fulfilled"
					? [[result.value.machineId, result.value] as const]
					: [],
			),
		);
		if (Object.keys(health).length > 0)
			this.setState({
				machineStatuses: { ...this.getState().machineStatuses, ...health },
			});
	}

	private async refreshMachineRuntimeFor(machines: Machine[]): Promise<void> {
		const results = await Promise.allSettled(
			machines.map((machine) => api.runtime(machine.id)),
		);
		const runtimes = Object.fromEntries(
			results.flatMap((result) =>
				result.status === "fulfilled"
					? [[result.value.machineId, result.value] as const]
					: [],
			),
		);
		if (Object.keys(runtimes).length > 0)
			this.setState({
				machineRuntimes: { ...this.getState().machineRuntimes, ...runtimes },
			});
	}

	private async refreshAgentRuntimesFor(machines: Machine[]): Promise<void> {
		await Promise.allSettled(
			machines.map((machine) => this.refreshAgentRuntimes(machine.id)),
		);
	}
}

function omitKey<T>(
	record: Record<string, T>,
	keyToOmit: string,
): Record<string, T> {
	return Object.fromEntries(
		Object.entries(record).filter(([key]) => key !== keyToOmit),
	);
}

function filterKeys<T>(
	record: Record<string, T>,
	allowedKeys: Set<string>,
): Record<string, T> {
	return Object.fromEntries(
		Object.entries(record).filter(([key]) => allowedKeys.has(key)),
	);
}
