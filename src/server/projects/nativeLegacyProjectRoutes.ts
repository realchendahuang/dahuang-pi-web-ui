import type { FastifyInstance } from "fastify";
import { readFile, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";

export interface NativeLegacyProjectCandidate {
	id: string;
	name: string;
	path: string;
	createdAt: string;
}

export interface NativeLegacyProjectPreview {
	source: string;
	sourceExists: boolean;
	candidates: NativeLegacyProjectCandidate[];
	issue?: string;
}

/**
 * A deliberately read-only bridge from PI WEB's old project metadata to the
 * native chooser. Paths remain candidates only: Swift must ask the user to
 * select each directory again before creating a security-scoped bookmark.
 */
export function registerNativeLegacyProjectRoutes(
	app: FastifyInstance,
	env: NodeJS.ProcessEnv = process.env,
): void {
	app.get("/projects/legacy-migration/preview", async (): Promise<NativeLegacyProjectPreview> => {
		const source = join(legacyDataDir(env), "projects.json");
		try {
			const metadata = await stat(source);
			if (!metadata.isFile()) return { source, sourceExists: false, candidates: [] };
			if (metadata.size > 1024 * 1024) return { source, sourceExists: true, candidates: [], issue: "Legacy project metadata exceeds the 1 MiB migration limit." };
			const candidates = parseLegacyProjects(await readFile(source, "utf8"));
			return { source, sourceExists: true, candidates };
		} catch (error: unknown) {
			if (isNodeError(error, "ENOENT")) return { source, sourceExists: false, candidates: [] };
			return { source, sourceExists: true, candidates: [], issue: error instanceof Error ? error.message : String(error) };
		}
	});
}

function legacyDataDir(env: NodeJS.ProcessEnv): string {
	const configured = env["PI_AGENT_LEGACY_PI_WEB_DATA_DIR"];
	return configured !== undefined && configured.trim() !== "" ? resolve(configured) : join(homedir(), ".pi-web");
}

function parseLegacyProjects(content: string): NativeLegacyProjectCandidate[] {
	const value: unknown = JSON.parse(content);
	if (!isRecord(value) || !Array.isArray(value["projects"])) throw new Error("Legacy projects.json is invalid");
	const candidates: NativeLegacyProjectCandidate[] = [];
	for (const item of value["projects"]) {
		if (!isRecord(item) || typeof item["id"] !== "string" || typeof item["name"] !== "string" || typeof item["path"] !== "string" || typeof item["createdAt"] !== "string") continue;
		if (!isAbsolute(item["path"])) continue;
		candidates.push({ id: item["id"], name: item["name"], path: resolve(item["path"]), createdAt: item["createdAt"] });
	}
	return candidates.sort((a, b) => a.createdAt.localeCompare(b.createdAt) || a.id.localeCompare(b.id));
}

function isRecord(value: unknown): value is Record<string, unknown> { return value !== null && typeof value === "object" && !Array.isArray(value); }
function isNodeError(error: unknown, code: string): error is NodeJS.ErrnoException { return error instanceof Error && "code" in error && error.code === code; }
