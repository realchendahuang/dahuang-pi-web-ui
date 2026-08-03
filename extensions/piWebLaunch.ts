import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/**
 * Agent runtime the `/pi-web` slash command pins as default: launching from a
 * Pi terminal defaults to Pi sessions, launching from an OMP terminal defaults
 * to OMP sessions.
 */
export type PiWebDefaultRuntime = "pi" | "omp";

const packageRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const cliPath = join(packageRoot, "dist", "cli.js");

export function parseArgs(args: string): string[] {
	return (
		args.match(/(?:[^\s"']+|"[^"]*"|'[^']*')+/g)?.map((part) => {
			if (
				(part.startsWith('"') && part.endsWith('"')) ||
				(part.startsWith("'") && part.endsWith("'"))
			) {
				return part.slice(1, -1);
			}
			return part;
		}) ?? []
	);
}

/**
 * Slash `/pi-web` always maps to CLI `up`, persisting the default agent
 * runtime for the terminal it was launched from (optional --no-open only).
 */
export function resolvePiWebCliArgs(
	args: string,
	defaultRuntime: PiWebDefaultRuntime,
): string[] {
	const parsed = parseArgs(args);
	const cliArgs = ["up", "--default-runtime", defaultRuntime];
	if (parsed.includes("--no-open")) cliArgs.push("--no-open");
	return cliArgs;
}

function truncateOutput(output: string): string {
	const trimmed = output.trim();
	if (trimmed.length <= 3_500) return trimmed;
	return `${trimmed.slice(0, 3_500)}\n… output truncated`;
}

function run(
	command: string,
	args: string[],
	env: NodeJS.ProcessEnv = {},
): Promise<{ code: number; output: string }> {
	// Promise.withResolvers is ES2024; this package targets ES2022.
	return new Promise((resolve) => {
		const child = spawn(command, args, {
			env: { ...process.env, ...env },
			stdio: ["ignore", "pipe", "pipe"],
		});

		let output = "";
		child.stdout.setEncoding("utf8");
		child.stderr.setEncoding("utf8");
		child.stdout.on("data", (chunk: string) => {
			output += chunk;
		});
		child.stderr.on("data", (chunk: string) => {
			output += chunk;
		});
		child.on("error", (error) => {
			resolve({ code: 1, output: error.message });
		});
		child.on("close", (code) => {
			resolve({ code: code ?? 1, output });
		});
	});
}

async function runPiWeb(
	args: string[],
	env: NodeJS.ProcessEnv = {},
): Promise<{ code: number; output: string }> {
	if (existsSync(cliPath)) {
		return run(process.execPath, [cliPath, ...args], env);
	}
	return run("pi-web", args, env);
}

/** Register the `/pi-web` slash command for one terminal flavor. */
export function registerPiWebCommand(
	pi: ExtensionAPI,
	defaultRuntime: PiWebDefaultRuntime,
): void {
	pi.registerCommand("pi-web", {
		description: "Start PI WEB and open the browser UI",
		async handler(args, ctx) {
			const result = await runPiWeb(resolvePiWebCliArgs(args, defaultRuntime));
			const body =
				truncateOutput(result.output) ||
				(result.code === 0
					? "Done."
					: `Command failed with exit code ${String(result.code)}.`);
			ctx.ui.notify(`pi-web\n\n${body}`, result.code === 0 ? "info" : "error");
		},
	});
}
