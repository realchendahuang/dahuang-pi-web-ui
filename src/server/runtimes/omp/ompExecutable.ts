import { constants } from "node:fs";
import { access } from "node:fs/promises";
import { homedir } from "node:os";
import { delimiter, join } from "node:path";

/**
 * Resolves the OMP executable for session daemons.
 *
 * User services start from a login shell (`zsh -lc`), which does not read
 * interactive-only rc files (`~/.zshrc`). Global npm/bun bin directories added
 * there are missing from the service PATH, so a bare `omp` command fails with
 * ENOENT even though the user can run it in a terminal. Probe the service PATH
 * first, then well-known user-level install locations.
 */

export interface OmpExecutableResolutionDeps {
	env?: NodeJS.ProcessEnv;
	homeDir?: string;
	isExecutable?: (path: string) => Promise<boolean>;
}

async function defaultIsExecutable(path: string): Promise<boolean> {
	try {
		await access(path, constants.X_OK);
		return true;
	} catch {
		return false;
	}
}

/** Directories searched after PATH when resolving a bare `omp` command. */
export function wellKnownOmpBinDirs(homeDir = homedir()): string[] {
	return [
		join(homeDir, ".npm-global", "bin"),
		join(homeDir, ".bun", "bin"),
		join(homeDir, ".local", "bin"),
		join(homeDir, ".volta", "bin"),
		join(homeDir, ".fnm", "current", "bin"),
		"/opt/homebrew/bin",
		"/usr/local/bin",
	];
}

/**
 * Resolves `command` to an executable path, or undefined when nothing
 * executable matches. Explicit paths (containing a separator) are checked
 * directly; bare commands search PATH and then well-known install locations.
 */
export async function resolveOmpExecutable(
	command: string,
	deps: OmpExecutableResolutionDeps = {},
): Promise<string | undefined> {
	const isExecutable = deps.isExecutable ?? defaultIsExecutable;
	if (command.includes("/")) {
		return (await isExecutable(command)) ? command : undefined;
	}
	const env = deps.env ?? process.env;
	const pathDirs = (env["PATH"] ?? "").split(delimiter).filter(Boolean);
	for (const dir of [...pathDirs, ...wellKnownOmpBinDirs(deps.homeDir)]) {
		const candidate = join(dir, command);
		if (await isExecutable(candidate)) return candidate;
	}
	return undefined;
}
