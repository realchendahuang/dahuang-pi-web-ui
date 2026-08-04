import type { ActiveSessionAbortResult } from "./sessions/activeSessionAbort.js";

export const RUNTIME_COMMAND_KINDS = {
	abortActiveWork: "abort-active-work",
} as const;

export type RuntimeCommandKind =
	(typeof RUNTIME_COMMAND_KINDS)[keyof typeof RUNTIME_COMMAND_KINDS];

export interface RuntimeCommandReceipt {
	commandId: string;
	kind: RuntimeCommandKind;
	status: "completed" | "failed";
	startedAt: string;
	completedAt: string;
	result?: ActiveSessionAbortResult;
	error?: string;
}

interface RuntimeCommandRecord {
	promise: Promise<RuntimeCommandReceipt>;
}

/**
 * Runtime-epoch-bound command receipts. Retaining the same promise for a
 * command id makes retry after a client timeout safe without persisting agent
 * objects or SDK state outside the Runtime that owns them.
 */
export class RuntimeCommandReceipts {
	private readonly records = new Map<string, RuntimeCommandRecord>();

	constructor(private readonly now: () => Date = () => new Date()) {}

	execute(
		commandId: string,
		kind: RuntimeCommandKind,
		action: () => Promise<ActiveSessionAbortResult>,
	): Promise<RuntimeCommandReceipt> {
		const existing = this.records.get(commandId);
		if (existing !== undefined) return existing.promise;

		const startedAt = this.now().toISOString();
		const promise = action()
			.then((result) => ({
				commandId,
				kind,
				status: "completed" as const,
				startedAt,
				completedAt: this.now().toISOString(),
				result,
			}))
			.catch((error: unknown) => ({
				commandId,
				kind,
				status: "failed" as const,
				startedAt,
				completedAt: this.now().toISOString(),
				error: error instanceof Error ? error.message : String(error),
			}));
		this.records.set(commandId, { promise });
		return promise;
	}

	get(commandId: string): Promise<RuntimeCommandReceipt> | undefined {
		return this.records.get(commandId)?.promise;
	}
}

export function requireRuntimeCommandId(value: unknown): string {
	if (typeof value !== "string") {
		throw new Error("commandId field must be a string");
	}
	const commandId = value.trim();
	if (commandId.length === 0 || commandId.length > 128) {
		throw new Error("commandId must be between 1 and 128 characters");
	}
	return commandId;
}
