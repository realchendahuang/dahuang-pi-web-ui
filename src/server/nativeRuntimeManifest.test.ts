import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
	loadNativeRuntimeIdentity,
	nativeRuntimeHello,
	parseNativeRuntimeManifest,
} from "./nativeRuntimeManifest.js";

const hash = "a".repeat(64);
const manifest = {
	schemaVersion: 1,
	appVersion: "0.1.0",
	runtimeVersion: "0.1.0",
	protocol: { major: 1, minor: 0 },
	node: {
		version: "v24.18.0",
		architecture: "arm64",
		executablePath: "node/bin/node",
		sha256: hash,
	},
	piSdkVersion: "0.81.1",
	files: [{ path: "dist/server/sessiond.js", sha256: hash, bytes: 42 }],
};

const temporaryDirectories: string[] = [];

afterEach(async () => {
	await Promise.all(temporaryDirectories.splice(0).map((directory) => rm(directory, { recursive: true, force: true })));
});

describe("native Runtime manifest", () => {
	it("loads a valid bundled manifest and exposes a stable hello projection", async () => {
		const directory = await mkdtemp(join(tmpdir(), "pi-agent-runtime-manifest-"));
		temporaryDirectories.push(directory);
		const path = join(directory, "runtime-manifest.json");
		await writeFile(path, `${JSON.stringify(manifest)}\n`, "utf8");

		const identity = loadNativeRuntimeIdentity({
			PI_AGENT_RUNTIME_MANIFEST: path,
			PI_AGENT_RUNTIME_EPOCH: "epoch-1",
		});
		expect(identity.manifest).toEqual({
			...manifest,
			files: [{ ...manifest.files[0], kind: "file" }],
		});
		expect(nativeRuntimeHello(identity, { version: "v24.18.0", arch: "arm64" })).toEqual({
			kind: "pi-agent-runtime",
			protocol: { major: 1, minor: 0 },
			runtimeEpoch: "epoch-1",
			nodeVersion: "v24.18.0",
			architecture: "arm64",
			manifest: {
				schemaVersion: 1,
				appVersion: "0.1.0",
				runtimeVersion: "0.1.0",
				piSdkVersion: "0.81.1",
			},
		});
	});

	it("keeps unbundled development daemons compatible", () => {
		const identity = loadNativeRuntimeIdentity({ PI_AGENT_RUNTIME_EPOCH: "dev-epoch" });
		expect(identity).toEqual({ runtimeEpoch: "dev-epoch" });
		expect(nativeRuntimeHello(identity, { version: "v26.5.0", arch: "arm64" })).toMatchObject({
			runtimeEpoch: "dev-epoch",
			protocol: { major: 1, minor: 0 },
		});
	});

	it("rejects a manifest that escapes the app bundle", () => {
		expect(() => parseNativeRuntimeManifest({ ...manifest, files: [{ ...manifest.files[0], path: "../../outside" }] })).toThrow(
			"must not escape the app bundle",
		);
	});

	it("rejects malformed hashes and duplicate file entries", () => {
		expect(() => parseNativeRuntimeManifest({ ...manifest, node: { ...manifest.node, sha256: "not-a-hash" } })).toThrow(
			"node.sha256 must be a SHA-256 hex digest",
		);
		expect(() => parseNativeRuntimeManifest({ ...manifest, files: [manifest.files[0], manifest.files[0]] })).toThrow(
			"duplicate path",
		);
	});
});
