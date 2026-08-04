#!/usr/bin/env node
import { createHash } from "node:crypto";
import {
	chmod,
	cp,
	mkdir,
	readdir,
	readFile,
	readlink,
	realpath,
	rm,
	stat,
	writeFile,
} from "node:fs/promises";
import { dirname, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { execFile } from "node:child_process";

const execFileAsync = promisify(execFile);
const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const outputRoot = optionValue("--output");
const nodeExecutable = optionValue("--node");
if (outputRoot === undefined || nodeExecutable === undefined) {
	throw new Error("Usage: build-runtime.mjs --output <path> --node <node executable>");
}

const output = resolve(outputRoot);
const allowedBuildRoot = resolve(repositoryRoot, "build/macos");
if (!isWithin(allowedBuildRoot, output) || output === allowedBuildRoot) {
	throw new Error(`Runtime output must be inside ${allowedBuildRoot}`);
}

const templateRoot = resolve(repositoryRoot, "macos/PiAgentRuntime");
const sourceDist = resolve(repositoryRoot, "dist");
const sourcePackage = JSON.parse(await readFile(resolve(repositoryRoot, "package.json"), "utf8"));
const resolvedNodeExecutable = await realpath(resolve(nodeExecutable));
const sourceNodeHome = resolve(dirname(resolvedNodeExecutable), "..");
const sourceNodeLibraries = resolve(sourceNodeHome, "lib");

await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });
await cp(resolve(templateRoot, "package.json"), resolve(output, "package.json"));
await cp(resolve(templateRoot, "package-lock.json"), resolve(output, "package-lock.json"));
await execFileAsync("npm", ["ci", "--omit=dev", "--no-audit", "--no-fund"], {
	cwd: output,
	maxBuffer: 16 * 1024 * 1024,
});

await cp(sourceDist, resolve(output, "dist"), { recursive: true });
await cp(resolve(templateRoot, "runtime-launcher.mjs"), resolve(output, "runtime-launcher.mjs"));
await mkdir(resolve(output, "node/bin"), { recursive: true });
await cp(resolvedNodeExecutable, resolve(output, "node/bin/node"), { force: true });
await chmod(resolve(output, "node/bin/node"), 0o755);
try {
	await cp(sourceNodeLibraries, resolve(output, "node/lib"), { recursive: true });
} catch (error) {
	throw new Error(`Could not bundle Node shared libraries from ${sourceNodeLibraries}`, { cause: error });
}

const bundledNode = resolve(output, "node/bin/node");
const nodeVersion = (await execFileAsync(bundledNode, ["--version"])).stdout.trim();
const nodeArchitecture = (await execFileAsync(bundledNode, ["-p", "process.arch"])).stdout.trim();
const piSdkPackage = JSON.parse(
	await readFile(resolve(output, "node_modules/@earendil-works/pi-coding-agent/package.json"), "utf8"),
);
await execFileAsync(bundledNode, [
	resolve(repositoryRoot, "scripts/macos/generate-runtime-compliance.mjs"),
	"--runtime",
	output,
]);
const files = await collectManifestFiles(output);
const nodePath = bundledNode;
const manifest = {
	schemaVersion: 1,
	appVersion: sourcePackage.version,
	runtimeVersion: sourcePackage.version,
	protocol: { major: 1, minor: 0 },
	node: {
		version: nodeVersion,
		architecture: nodeArchitecture,
		executablePath: "node/bin/node",
		sha256: await hashFile(nodePath),
	},
	piSdkVersion: piSdkPackage.version,
	files,
};
await writeFile(resolve(output, "runtime-manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
console.log(`Built Runtime ${manifest.runtimeVersion} at ${output} (${files.length} verified resources)`);

async function collectManifestFiles(root) {
	const entries = [];
	async function walk(directory) {
		const children = await readdir(directory, { withFileTypes: true });
		for (const child of children) {
			const absolutePath = resolve(directory, child.name);
			const relativePath = relative(root, absolutePath);
			if (relativePath === "runtime-manifest.json") continue;
			if (child.isDirectory()) {
				await walk(absolutePath);
				continue;
			}
			if (child.isSymbolicLink()) {
				const target = await readlink(absolutePath);
				entries.push({
					path: relativePath,
					sha256: hash(Buffer.from(target)),
					bytes: Buffer.byteLength(target),
					kind: "symlink",
					target,
				});
				continue;
			}
			const metadata = await stat(absolutePath);
			if (!metadata.isFile()) throw new Error(`Runtime contains unsupported entry: ${absolutePath}`);
			entries.push({ path: relativePath, sha256: await hashFile(absolutePath), bytes: metadata.size, kind: "file" });
		}
	}
	await walk(root);
	return entries.sort((left, right) => left.path.localeCompare(right.path));
}

async function hashFile(path) {
	return hash(await readFile(path));
}

function hash(value) {
	return createHash("sha256").update(value).digest("hex");
}

function optionValue(name) {
	const index = process.argv.indexOf(name);
	if (index < 0 || process.argv[index + 1] === undefined) return undefined;
	return process.argv[index + 1];
}

function isWithin(parent, candidate) {
	const value = relative(parent, candidate);
	return value !== "" && !value.startsWith(`..${sep}`) && value !== ".." && !resolve(candidate).startsWith(`${parent}${sep}..`);
}
