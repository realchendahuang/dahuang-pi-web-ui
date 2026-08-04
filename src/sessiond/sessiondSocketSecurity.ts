import { chmod, lstat, mkdir, rm } from "node:fs/promises";
import { dirname } from "node:path";

const SOCKET_DIRECTORY_MODE = 0o700;
const SOCKET_MODE = 0o600;

export interface SessiondSocketIdentity {
	dev: number;
	ino: number;
}

/**
 * Prepares an exact Unix-socket path without treating it as a disposable
 * general-purpose file. A stale socket is safe to replace; a regular file,
 * symlink, FIFO, or device is an ownership/security error and is left intact.
 */
export async function prepareSessiondSocketPath(socketPath: string): Promise<void> {
	const directory = dirname(socketPath);
	await mkdir(directory, { recursive: true, mode: SOCKET_DIRECTORY_MODE });
	await chmod(directory, SOCKET_DIRECTORY_MODE);

	try {
		const existing = await lstat(socketPath);
		if (!existing.isSocket()) {
			throw new Error(
				`Refusing to replace non-socket session daemon path: ${socketPath}`,
			);
		}
		await rm(socketPath);
	} catch (error) {
		if (isMissingPathError(error)) return;
		throw error;
	}
}

/** Secures the socket just created by Fastify and returns its file identity. */
export async function secureSessiondSocket(
	socketPath: string,
): Promise<SessiondSocketIdentity> {
	const socket = await lstat(socketPath);
	if (!socket.isSocket()) {
		throw new Error(`Session daemon did not create a Unix socket: ${socketPath}`);
	}
	await chmod(socketPath, SOCKET_MODE);
	return { dev: socket.dev, ino: socket.ino };
}

/**
 * Removes only the socket instance created by this daemon. If a later process
 * replaced the path, its file is deliberately preserved for that process.
 */
export async function removeOwnedSessiondSocket(
	socketPath: string,
	identity: SessiondSocketIdentity,
): Promise<void> {
	try {
		const current = await lstat(socketPath);
		if (
			current.isSocket() &&
			current.dev === identity.dev &&
			current.ino === identity.ino
		) {
			await rm(socketPath);
		}
	} catch (error) {
		if (isMissingPathError(error)) return;
		throw error;
	}
}

function isMissingPathError(error: unknown): boolean {
	return hasErrorCode(error) && error.code === "ENOENT";
}

function hasErrorCode(error: unknown): error is { code?: unknown } {
	return typeof error === "object" && error !== null && "code" in error;
}
