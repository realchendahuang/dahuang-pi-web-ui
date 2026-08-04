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

export type NativeLegacyMigrationAction = "reauthorize-projects" | "migrate-to-keychain" | "copied-and-retained" | "retained";

/** Deliberately redacted auth migration summary supplied by AuthService. */
export interface NativeLegacyAuthMigrationOverviewPreview {
	sourceExists: boolean;
	eligible: boolean;
	credentialCount: number;
	issue?: string;
}

export interface NativeLegacyMigrationOverviewDependencies {
	legacyAuthMigrationPreview?: () => Promise<NativeLegacyAuthMigrationOverviewPreview>;
}

export interface NativeLegacyMigrationOverviewItem {
	id: "projects" | "credentials" | "archived-sessions" | "machines" | "unread";
	source: string;
	sourceExists: boolean;
	action: NativeLegacyMigrationAction;
	itemCount?: number;
	issue?: string;
}

/** Redacted inventory of old PI WEB state; it never returns machine secrets or file contents. */
export interface NativeLegacyMigrationOverview {
	legacyDataDir: string;
	items: NativeLegacyMigrationOverviewItem[];
}

/**
 * A deliberately read-only bridge from PI WEB's old project metadata to the
 * native chooser. Paths remain candidates only: Swift must ask the user to
 * select each directory again before creating a security-scoped bookmark.
 */
export function registerNativeLegacyProjectRoutes(
	app: FastifyInstance,
	env: NodeJS.ProcessEnv = process.env,
	dependencies: NativeLegacyMigrationOverviewDependencies = {},
): void {
	app.get("/projects/legacy-migration/preview", async (): Promise<NativeLegacyProjectPreview> => {
		return await readNativeLegacyProjectPreview(env);
	});
	app.get("/migration/legacy/overview", async (): Promise<NativeLegacyMigrationOverview> =>
		await readNativeLegacyMigrationOverview(env, dependencies));
}

export function legacyPiWebDataDir(env: NodeJS.ProcessEnv): string {
	const configured = env["PI_AGENT_LEGACY_PI_WEB_DATA_DIR"];
	return configured !== undefined && configured.trim() !== "" ? resolve(configured) : join(homedir(), ".pi-web");
}

export async function readNativeLegacyProjectPreview(
	env: NodeJS.ProcessEnv = process.env,
): Promise<NativeLegacyProjectPreview> {
	const source = join(legacyPiWebDataDir(env), "projects.json");
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
}

export async function readNativeLegacyMigrationOverview(
	env: NodeJS.ProcessEnv = process.env,
	dependencies: NativeLegacyMigrationOverviewDependencies = {},
): Promise<NativeLegacyMigrationOverview> {
	const legacyDataDir = legacyPiWebDataDir(env);
	const projects = await readNativeLegacyProjectPreview(env);
	const [auth, archives, machines, unread] = await Promise.all([
		readNativeLegacyAuthMigrationOverview(dependencies),
		legacyFileStatus(join(legacyDataDir, "archived-sessions.json")),
		legacyFileStatus(join(legacyDataDir, "machines.json")),
		legacyFileStatus(join(legacyDataDir, "session-unread.json")),
	]);
	return {
		legacyDataDir,
		items: [
			{
				id: "projects",
				source: projects.source,
				sourceExists: projects.sourceExists,
				action: "reauthorize-projects",
				...(projects.sourceExists ? { itemCount: projects.candidates.length } : {}),
				...(projects.issue === undefined ? {} : { issue: projects.issue }),
			},
			{
				id: "credentials",
				source: "Pi auth.json",
				sourceExists: auth.sourceExists,
				action: "migrate-to-keychain",
				...(auth.sourceExists ? { itemCount: auth.credentialCount } : {}),
				...(auth.issue === undefined ? {} : { issue: auth.issue }),
			},
			{
				id: "archived-sessions",
				source: archives.path,
				sourceExists: archives.exists,
				action: "copied-and-retained",
				...(archives.issue === undefined ? {} : { issue: archives.issue }),
			},
			{
				id: "machines",
				source: machines.path,
				sourceExists: machines.exists,
				action: "retained",
				...(machines.issue === undefined ? {} : { issue: machines.issue }),
			},
			{
				id: "unread",
				source: unread.path,
				sourceExists: unread.exists,
				action: "retained",
				...(unread.issue === undefined ? {} : { issue: unread.issue }),
			},
		],
	};
}

async function readNativeLegacyAuthMigrationOverview(
	dependencies: NativeLegacyMigrationOverviewDependencies,
): Promise<NativeLegacyAuthMigrationOverviewPreview> {
	const preview = dependencies.legacyAuthMigrationPreview;
	if (preview === undefined) {
		return {
			sourceExists: false,
			eligible: false,
			credentialCount: 0,
			issue: "Credential migration is available only from the bundled Pi Agent Runtime.",
		};
	}
	try {
		const result = await preview();
		return {
			sourceExists: result.sourceExists,
			eligible: result.eligible,
			credentialCount: result.credentialCount,
			...(result.issue === undefined ? {} : { issue: result.issue }),
		};
	} catch {
		return {
			sourceExists: false,
			eligible: false,
			credentialCount: 0,
			issue: "Credential migration preview could not be read.",
		};
	}
}

async function legacyFileStatus(path: string): Promise<{ path: string; exists: boolean; issue?: string }> {
	try {
		const metadata = await stat(path);
		return metadata.isFile()
			? { path, exists: true }
			: { path, exists: false, issue: "Legacy state exists but is not a regular file." };
	} catch (error: unknown) {
		return isNodeError(error, "ENOENT")
			? { path, exists: false }
			: { path, exists: true, issue: error instanceof Error ? error.message : String(error) };
	}
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
