import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const packageRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const cliPath = join(packageRoot, "dist", "cli.js");
const serviceNames = ["pi-web-sessiond.service", "pi-web.service", "pi-web-ui-dev.service"];
const macLogPaths = ["sessiond.log", "web.log", "ui-dev.log"].map((name) => join(homedir(), ".pi-web", "logs", name));

/**
 * Single slash surface: `/pi-web`.
 * Bare `/pi-web` (no args) means "bring the Web UI up" — not help.
 */
const subcommands = [
  "up",
  "open",
  "install",
  "status",
  "logs",
  "restart",
  "start",
  "stop",
  "doctor",
  "version",
  "uninstall",
  "help",
] as const;

type Subcommand = (typeof subcommands)[number];

export function parseArgs(args: string): string[] {
  return args.match(/(?:[^\s"']+|"[^"]*"|'[^']*')+/g)?.map((part) => {
    if ((part.startsWith('"') && part.endsWith('"')) || (part.startsWith("'") && part.endsWith("'"))) {
      return part.slice(1, -1);
    }
    return part;
  }) ?? [];
}

/** Bare `/pi-web` defaults to `up` (start if needed + open URL). */
export function resolvePiWebSubcommand(args: string): { subcommand: string; rest: string[] } {
  const parsedArgs = parseArgs(args);
  const head = parsedArgs[0];
  if (head === undefined || head === "") return { subcommand: "up", rest: [] };
  return { subcommand: head, rest: parsedArgs.slice(1) };
}

function truncateOutput(output: string): string {
  const trimmed = output.trim();
  if (trimmed.length <= 3_500) return trimmed;
  return `${trimmed.slice(0, 3_500)}\n… output truncated`;
}

function run(command: string, args: string[], env: NodeJS.ProcessEnv = {}): Promise<{ code: number; output: string }> {
  return new Promise((resolve) => {
    const child = spawn(command, args, {
      env: { ...process.env, ...env },
      stdio: ["ignore", "pipe", "pipe"],
    });

    let output = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => { output += chunk; });
    child.stderr.on("data", (chunk: string) => { output += chunk; });
    child.on("error", (error) => {
      resolve({ code: 1, output: error.message });
    });
    child.on("close", (code) => {
      resolve({ code: code ?? 1, output });
    });
  });
}

async function runPiWeb(args: string[], env: NodeJS.ProcessEnv = {}): Promise<{ code: number; output: string }> {
  if (existsSync(cliPath)) {
    return run(process.execPath, [cliPath, ...args], env);
  }
  return run("pi-web", args, env);
}

function showResult(ctx: { ui: { notify(message: string, type?: "info" | "warning" | "error" | "success"): void } }, title: string, result: { code: number; output: string }): void {
  const body = truncateOutput(result.output) || (result.code === 0 ? "Done." : `Command failed with exit code ${String(result.code)}.`);
  ctx.ui.notify(`${title}\n\n${body}`, result.code === 0 ? "info" : "error");
}

function isSubcommand(value: string): value is Subcommand {
  return subcommands.some((command) => command === value);
}

async function boundedLogs(): Promise<{ code: number; output: string }> {
  if (process.platform === "darwin") {
    const existingLogs = macLogPaths.filter((path) => existsSync(path));
    if (existingLogs.length === 0) return { code: 1, output: "No PI WEB log files found in ~/.pi-web/logs." };
    return run("tail", ["-n", "100", ...existingLogs]);
  }
  return run("journalctl", ["--user", ...serviceNames.flatMap((serviceName) => ["-u", serviceName]), "-n", "100", "--no-pager"]);
}

export default function piWebExtension(pi: ExtensionAPI): void {
  pi.registerCommand("pi-web", {
    description: "Open PI WEB UI (default), or manage services: up, open, install, status, start, stop, …",
    getArgumentCompletions(prefix: string): { value: string; label: string }[] | null {
      const [first = ""] = parseArgs(prefix);
      const items = subcommands
        .filter((command) => command.startsWith(first))
        .map((command) => ({ value: command, label: command }));
      return items.length > 0 ? items : null;
    },
    async handler(args, ctx) {
      const { subcommand, rest } = resolvePiWebSubcommand(args);

      if (subcommand === "help") {
        ctx.ui.notify(
          [
            "PI WEB — single slash entry `/pi-web`",
            "",
            "/pi-web              Start if needed, print URL, open browser  (same as /pi-web up)",
            "/pi-web up [--install] [--no-open]",
            "/pi-web open         Open the Web UI URL in a browser",
            "/pi-web install      One-time user service install (LaunchAgent / systemd)",
            "/pi-web status|start|stop|restart|logs|doctor|version|uninstall",
            "",
            "First time after `pi install`:",
            "  /pi-web install",
            "  /pi-web",
            "",
            "Logs in this command are bounded to the last 100 lines. Use `pi-web logs` in a shell to follow.",
          ].join("\n"),
          "info",
        );
        return;
      }

      if (!isSubcommand(subcommand)) {
        ctx.ui.notify(`Unknown pi-web command: ${subcommand}. Try /pi-web help.`, "error");
        return;
      }

      if (subcommand === "stop" || subcommand === "uninstall") {
        const ok = await ctx.ui.confirm(`pi-web ${subcommand}`, `Run pi-web ${subcommand}?`);
        if (!ok) return;
      }

      if (subcommand === "logs") {
        showResult(ctx, "pi-web logs", await boundedLogs());
        return;
      }

      // `up` / `open` / everything else goes through the CLI so behavior matches the shell.
      showResult(ctx, `pi-web ${subcommand}`, await runPiWeb([subcommand, ...rest]));
    },
  });
}
