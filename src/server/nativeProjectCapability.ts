import { timingSafeEqual } from "node:crypto";
import { realpath, stat } from "node:fs/promises";
import { isAbsolute, relative, resolve, sep } from "node:path";

export const NATIVE_PROJECT_CAPABILITY_TOKEN_ENV =
	"PI_AGENT_RUNTIME_PROJECT_CAPABILITY_TOKEN";
export const NATIVE_PROJECT_CAPABILITY_HEADER =
	"x-pi-agent-project-capability";

export class NativeProjectCapabilityError extends Error {
	constructor(message: string, readonly statusCode: 401 | 403 = 403) {
		super(message);
	}
}

/**
 * App-managed Runtime project boundary. This is deliberately not presented as
 * an OS sandbox capability: in the unsigned distribution, Node runs with the
 * same user identity. It does prevent an accidental/raw cwd request from
 * expanding the App's explicitly selected project scope.
 */
export class NativeProjectCapabilityService {
	private readonly authorizedRoots = new Set<string>();

	constructor(private readonly token: string) {}

	static fromEnvironment(
		environment: NodeJS.ProcessEnv,
	): NativeProjectCapabilityService | undefined {
		const token = environment[NATIVE_PROJECT_CAPABILITY_TOKEN_ENV]?.trim();
		return token === undefined || token === ""
			? undefined
			: new NativeProjectCapabilityService(token);
	}

	async authorize(path: unknown): Promise<string> {
		if (typeof path !== "string" || path.trim() === "")
			throw new NativeProjectCapabilityError("Project path is required");
		if (!isAbsolute(path))
			throw new NativeProjectCapabilityError("Project path must be absolute");
		let resolved: string;
		try {
			resolved = await realpath(resolve(path));
			if (!(await stat(resolved)).isDirectory())
				throw new Error("not a directory");
		} catch {
			throw new NativeProjectCapabilityError(
				"Project path is unavailable or is not a directory",
			);
		}
		this.authorizedRoots.add(resolved);
		return resolved;
	}

	assertToken(value: unknown): void {
		if (typeof value !== "string" || !constantTimeEqual(this.token, value))
			throw new NativeProjectCapabilityError(
				"Native project capability is required",
				401,
			);
	}

	async assertAuthorizedCwd(cwd: unknown): Promise<void> {
		if (typeof cwd !== "string" || cwd === "") return;
		if (!isAbsolute(cwd))
			throw new NativeProjectCapabilityError("cwd must be an absolute path");
		let candidate: string;
		try {
			candidate = await realpath(resolve(cwd));
		} catch {
			throw new NativeProjectCapabilityError("cwd is unavailable");
		}
		if (![...this.authorizedRoots].some((root) => isInside(root, candidate)))
			throw new NativeProjectCapabilityError(
				"cwd is outside the projects authorized by Pi Agent",
			);
	}

	list(): string[] {
		return [...this.authorizedRoots].sort();
	}
}

function isInside(root: string, candidate: string): boolean {
	const path = relative(root, candidate);
	return path === "" || (!path.startsWith(`..${sep}`) && path !== ".." && !isAbsolute(path));
}

function constantTimeEqual(expected: string, received: string): boolean {
	const left = Buffer.from(expected);
	const right = Buffer.from(received);
	return left.length === right.length && timingSafeEqual(left, right);
}
