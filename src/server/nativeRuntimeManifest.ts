import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { isAbsolute, normalize, relative, resolve, sep } from "node:path";

export const NATIVE_RUNTIME_MANIFEST_ENV = "PI_AGENT_RUNTIME_MANIFEST";
export const NATIVE_RUNTIME_EPOCH_ENV = "PI_AGENT_RUNTIME_EPOCH";
export const NATIVE_RUNTIME_PROTOCOL = Object.freeze({ major: 1, minor: 0 });

export interface NativeRuntimeManifestFile {
	path: string;
	sha256: string;
	bytes: number;
	kind?: "file" | "symlink";
	target?: string;
}

export interface NativeRuntimeManifest {
	schemaVersion: 1;
	appVersion: string;
	runtimeVersion: string;
	protocol: {
		major: number;
		minor: number;
	};
	node: {
		version: string;
		architecture: string;
		executablePath: string;
		sha256: string;
	};
	piSdkVersion: string;
	files: NativeRuntimeManifestFile[];
}

export interface NativeRuntimeIdentity {
	runtimeEpoch: string;
	manifest?: NativeRuntimeManifest;
	manifestPath?: string;
}

export interface NativeRuntimeHello {
	kind: "pi-agent-runtime";
	protocol: {
		major: number;
		minor: number;
	};
	runtimeEpoch: string;
	nodeVersion: string;
	architecture: string;
	manifest?: Pick<
		NativeRuntimeManifest,
		"schemaVersion" | "appVersion" | "runtimeVersion" | "piSdkVersion"
	>;
}

/**
 * Reads the manifest passed by the bundled launcher. Development sessiond
 * instances intentionally have no manifest and remain protocol-compatible.
 */
export function loadNativeRuntimeIdentity(
	env: NodeJS.ProcessEnv = process.env,
): NativeRuntimeIdentity {
	const runtimeEpoch = nonEmptyString(env[NATIVE_RUNTIME_EPOCH_ENV]) ?? randomUUID();
	const configuredPath = nonEmptyString(env[NATIVE_RUNTIME_MANIFEST_ENV]);
	if (configuredPath === undefined) return { runtimeEpoch };

	const manifestPath = resolve(configuredPath);
	let value: unknown;
	try {
		value = JSON.parse(readFileSync(manifestPath, "utf8"));
	} catch (error) {
		throw new Error(`Could not read bundled Runtime manifest: ${manifestPath}`, {
			cause: error,
		});
	}
	return { runtimeEpoch, manifest: parseNativeRuntimeManifest(value), manifestPath };
}

export function nativeRuntimeHello(
	identity: NativeRuntimeIdentity,
	runtime: Pick<NodeJS.Process, "version" | "arch"> = process,
): NativeRuntimeHello {
	const manifest = identity.manifest;
	return {
		kind: "pi-agent-runtime",
		protocol: manifest?.protocol ?? NATIVE_RUNTIME_PROTOCOL,
		runtimeEpoch: identity.runtimeEpoch,
		nodeVersion: runtime.version,
		architecture: runtime.arch,
		...(manifest === undefined
			? {}
			: {
				manifest: {
					schemaVersion: manifest.schemaVersion,
					appVersion: manifest.appVersion,
					runtimeVersion: manifest.runtimeVersion,
					piSdkVersion: manifest.piSdkVersion,
				},
			}),
	};
}

export function parseNativeRuntimeManifest(value: unknown): NativeRuntimeManifest {
	if (!isRecord(value)) throw new Error("Bundled Runtime manifest must be a JSON object");
	if (value["schemaVersion"] !== 1) {
		throw new Error("Bundled Runtime manifest schemaVersion must be 1");
	}
	const protocol = parseProtocol(value["protocol"]);
	const node = parseNode(value["node"]);
	const files = parseFiles(value["files"]);
	return {
		schemaVersion: 1,
		appVersion: requiredString(value["appVersion"], "appVersion"),
		runtimeVersion: requiredString(value["runtimeVersion"], "runtimeVersion"),
		protocol,
		node,
		piSdkVersion: requiredString(value["piSdkVersion"], "piSdkVersion"),
		files,
	};
}

function parseProtocol(value: unknown): NativeRuntimeManifest["protocol"] {
	if (!isRecord(value)) throw new Error("Bundled Runtime manifest protocol must be an object");
	const major = requiredNonNegativeInteger(value["major"], "protocol.major");
	const minor = requiredNonNegativeInteger(value["minor"], "protocol.minor");
	return { major, minor };
}

function parseNode(value: unknown): NativeRuntimeManifest["node"] {
	if (!isRecord(value)) throw new Error("Bundled Runtime manifest node must be an object");
	return {
		version: requiredString(value["version"], "node.version"),
		architecture: requiredString(value["architecture"], "node.architecture"),
		executablePath: requiredBundleRelativePath(value["executablePath"], "node.executablePath"),
		sha256: requiredSha256(value["sha256"], "node.sha256"),
	};
}

function parseFiles(value: unknown): NativeRuntimeManifestFile[] {
	if (!Array.isArray(value)) throw new Error("Bundled Runtime manifest files must be an array");
	const seen = new Set<string>();
	return value.map((entry, index) => {
		if (!isRecord(entry)) throw new Error(`Bundled Runtime manifest files[${String(index)}] must be an object`);
		const path = requiredBundleRelativePath(entry["path"], `files[${String(index)}].path`);
		if (seen.has(path)) throw new Error(`Bundled Runtime manifest files contains duplicate path: ${path}`);
		seen.add(path);
		const rawKind = entry["kind"];
		const kind = rawKind === undefined ? "file" : rawKind;
		if (kind !== "file" && kind !== "symlink") {
			throw new Error(`Bundled Runtime manifest files[${String(index)}].kind must be file or symlink`);
		}
		const target = entry["target"];
		if (kind === "symlink" && typeof target !== "string") {
			throw new Error(`Bundled Runtime manifest files[${String(index)}].target is required for symlinks`);
		}
		return {
			path,
			sha256: requiredSha256(entry["sha256"], `files[${String(index)}].sha256`),
			bytes: requiredNonNegativeInteger(entry["bytes"], `files[${String(index)}].bytes`),
			kind,
			...(typeof target === "string" ? { target } : {}),
		};
	});
}

function requiredBundleRelativePath(value: unknown, name: string): string {
	const path = requiredString(value, name);
	if (isAbsolute(path)) throw new Error(`${name} must be relative to the app bundle`);
	const normalized = normalize(path);
	const escaped = relative(".", normalized).split(sep).includes("..");
	if (normalized === "." || escaped || normalized.startsWith(`..${sep}`)) {
		throw new Error(`${name} must not escape the app bundle`);
	}
	return normalized;
}

function requiredSha256(value: unknown, name: string): string {
	const hash = requiredString(value, name);
	if (!/^[a-f0-9]{64}$/i.test(hash)) throw new Error(`${name} must be a SHA-256 hex digest`);
	return hash.toLowerCase();
}

function requiredNonNegativeInteger(value: unknown, name: string): number {
	if (typeof value !== "number" || !Number.isInteger(value) || value < 0) {
		throw new Error(`${name} must be a non-negative integer`);
	}
	return value;
}

function requiredString(value: unknown, name: string): string {
	if (typeof value !== "string" || value.trim().length === 0) {
		throw new Error(`${name} must be a non-empty string`);
	}
	return value;
}

function nonEmptyString(value: string | undefined): string | undefined {
	return value === undefined || value.trim().length === 0 ? undefined : value;
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}
