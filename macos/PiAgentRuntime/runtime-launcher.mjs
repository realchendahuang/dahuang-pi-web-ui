import { createHash, randomUUID } from "node:crypto";
import { lstat, readFile, readlink } from "node:fs/promises";
import { dirname, isAbsolute, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const runtimeRoot = dirname(fileURLToPath(import.meta.url));
const manifestPath = resolve(runtimeRoot, "runtime-manifest.json");

const manifest = await validateRuntime();
if (process.argv.includes("--verify-only")) {
	console.log(
		`Verified Pi Agent Runtime ${manifest.runtimeVersion} (${manifest.node.version}, ${manifest.node.architecture})`,
	);
} else {
	process.env.PI_AGENT_RUNTIME_MANIFEST = manifestPath;
	process.env.PI_AGENT_RUNTIME_EPOCH ??= randomUUID();
	await import("./dist/server/sessiond.js");
}

async function validateRuntime() {
	let manifest;
	try {
		manifest = JSON.parse(await readFile(manifestPath, "utf8"));
	} catch (error) {
		throw new Error(`Could not read Pi Agent Runtime manifest at ${manifestPath}`, { cause: error });
	}
	if (!isRecord(manifest) || manifest.schemaVersion !== 1) {
		throw new Error("Pi Agent Runtime manifest schemaVersion must be 1");
	}
	if (!isRecord(manifest.node) || !Array.isArray(manifest.files)) {
		throw new Error("Pi Agent Runtime manifest is missing node or files metadata");
	}
	if (manifest.node.version !== process.version) {
		throw new Error(`Pi Agent Runtime requires Node ${String(manifest.node.version)}, found ${process.version}`);
	}
	if (manifest.node.architecture !== process.arch) {
		throw new Error(`Pi Agent Runtime requires ${String(manifest.node.architecture)}, found ${process.arch}`);
	}

	const nodePath = bundlePath(requiredString(manifest.node.executablePath, "node.executablePath"));
	await verifyFile(nodePath, requiredString(manifest.node.sha256, "node.sha256"), undefined);

	for (const entry of manifest.files) {
		if (!isRecord(entry)) throw new Error("Pi Agent Runtime manifest has an invalid file entry");
		const path = bundlePath(requiredString(entry.path, "files[].path"));
		const kind = entry.kind ?? "file";
		if (kind === "symlink") {
			const target = await readlink(path);
			if (target !== entry.target) throw new Error(`Pi Agent Runtime symlink target mismatch: ${String(entry.path)}`);
			const expectedHash = requiredString(entry.sha256, "files[].sha256");
			if (sha256(Buffer.from(target)) !== expectedHash) throw new Error(`Pi Agent Runtime symlink hash mismatch: ${String(entry.path)}`);
			continue;
		}
		await verifyFile(path, requiredString(entry.sha256, "files[].sha256"), requiredNonNegativeInteger(entry.bytes, "files[].bytes"));
	}
	return manifest;
}

async function verifyFile(path, expectedHash, expectedBytes) {
	const metadata = await lstat(path);
	if (!metadata.isFile()) throw new Error(`Pi Agent Runtime expected a file: ${path}`);
	if (expectedBytes !== undefined && metadata.size !== expectedBytes) {
		throw new Error(`Pi Agent Runtime file size mismatch: ${path}`);
	}
	const contents = await readFile(path);
	if (sha256(contents) !== expectedHash) throw new Error(`Pi Agent Runtime file hash mismatch: ${path}`);
}

function bundlePath(value) {
	if (isAbsolute(value)) throw new Error("Pi Agent Runtime manifest paths must be relative");
	const resolved = resolve(runtimeRoot, value);
	const escaped = relative(runtimeRoot, resolved).split(sep).includes("..");
	if (escaped || resolved === runtimeRoot) throw new Error("Pi Agent Runtime manifest path escapes its bundle");
	return resolved;
}

function requiredString(value, name) {
	if (typeof value !== "string" || value.length === 0) throw new Error(`Pi Agent Runtime ${name} must be a non-empty string`);
	return value;
}

function requiredNonNegativeInteger(value, name) {
	if (!Number.isInteger(value) || value < 0) throw new Error(`Pi Agent Runtime ${name} must be a non-negative integer`);
	return value;
}

function sha256(value) {
	return createHash("sha256").update(value).digest("hex");
}

function isRecord(value) {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}
