export interface ActiveSessionAbortTarget {
	sessionId: string;
	runtimeId: string;
}

export interface ActiveSessionAbortFailure extends ActiveSessionAbortTarget {
	error: string;
}

export interface ActiveSessionAbortResult {
	requested: number;
	aborted: ActiveSessionAbortTarget[];
	failures: ActiveSessionAbortFailure[];
}

/**
 * Applies an agent-level abort to a snapshot of sessions with actual work.
 * Every target is attempted so one failed provider/extension cannot prevent
 * the rest of the Runtime from reaching a safe shutdown point.
 */
export async function abortActiveSessions(
	targets: readonly ActiveSessionAbortTarget[],
	abort: (target: ActiveSessionAbortTarget) => Promise<void>,
): Promise<ActiveSessionAbortResult> {
	const outcomes = await Promise.all(
		targets.map(async (target) => {
			try {
				await abort(target);
				return { target, error: undefined };
			} catch (error) {
				return {
					target,
					error: error instanceof Error ? error.message : String(error),
				};
			}
		}),
	);
	return {
		requested: targets.length,
		aborted: outcomes
			.filter((outcome) => outcome.error === undefined)
			.map((outcome) => outcome.target),
		failures: outcomes.flatMap((outcome) =>
			outcome.error === undefined
				? []
				: [{ ...outcome.target, error: outcome.error }],
		),
	};
}
