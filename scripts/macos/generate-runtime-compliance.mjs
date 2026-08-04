#!/usr/bin/env node
import { createHash } from "node:crypto";
import { readdir, readFile, stat, writeFile } from "node:fs/promises";
import { basename, relative, resolve, sep } from "node:path";
const runtimeArgument = optionValue("--runtime");
const verifyOnly = process.argv.includes("--verify");
if (runtimeArgument === undefined) {
  throw new Error(
    "Usage: generate-runtime-compliance.mjs --runtime <runtime directory> [--verify]"
  );
}

const runtimeRoot = resolve(runtimeArgument);
const packageLockPath = resolve(runtimeRoot, "package-lock.json");
const runtimePackagePath = resolve(runtimeRoot, "package.json");
const nodePath = resolve(runtimeRoot, "node/bin/node");
const packageLock = JSON.parse(await readFile(packageLockPath, "utf8"));
const runtimePackage = JSON.parse(await readFile(runtimePackagePath, "utf8"));
const components = await collectComponents(runtimeRoot, packageLock);
const nodeComponent = {
  "bom-ref": "pkg:generic/node-runtime",
  type: "framework",
  name: "Node.js",
  version: await nodeVersion(nodePath),
  hashes: [{ alg: "SHA-256", content: await hashFile(nodePath) }],
  properties: [{ name: "pi-agent:bundled-path", value: "node/bin/node" }],
};
const sbom = {
  $schema: "http://cyclonedx.org/schema/bom-1.5.schema.json",
  bomFormat: "CycloneDX",
  specVersion: "1.5",
  version: 1,
  metadata: {
    component: {
      type: "application",
      name: "Pi Agent Runtime",
      version: runtimePackage.version,
      properties: [
        { name: "pi-agent:runtime-package", value: runtimePackage.name },
      ],
    },
  },
  components: [nodeComponent, ...components.map(componentToSbom)],
};
const notices = {
  schemaVersion: 1,
  runtime: { name: runtimePackage.name, version: runtimePackage.version },
  coverage: {
    componentCount: components.length,
    componentsWithBundledLicenseFiles: components.filter(
      (component) => component.licenseFiles.length > 0
    ).length,
    componentsWithoutBundledLicenseFiles: components
      .filter((component) => component.licenseFiles.length === 0)
      .map((component) => `${component.name}@${component.version}`),
  },
  components: components.map((component) => ({
    name: component.name,
    version: component.version,
    license: component.license,
    packagePath: component.packagePath,
    licenseFiles: component.licenseFiles,
    ...(component.resolved === undefined
      ? {}
      : { resolved: component.resolved }),
    ...(component.integrity === undefined
      ? {}
      : { integrity: component.integrity }),
  })),
};

await writeOrVerify(
  resolve(runtimeRoot, "runtime-sbom.cdx.json"),
  `${JSON.stringify(sbom, null, 2)}\n`
);
await writeOrVerify(
  resolve(runtimeRoot, "runtime-third-party-notices.json"),
  `${JSON.stringify(notices, null, 2)}\n`
);

if (verifyOnly) {
  console.log(
    `Verified Runtime compliance inventory (${components.length} npm components)`
  );
} else {
  console.log(
    `Generated Runtime SBOM and notices (${components.length} npm components)`
  );
}

async function collectComponents(root, lock) {
  if (
    lock.lockfileVersion !== 3 ||
    typeof lock.packages !== "object" ||
    lock.packages === null
  ) {
    throw new Error("Runtime package-lock.json must use npm lockfileVersion 3");
  }
  const components = [];
  for (const [packagePath, entry] of Object.entries(lock.packages)) {
    if (!packagePath.startsWith("node_modules/")) continue;
    if (entry === null || typeof entry !== "object")
      throw new Error(`Invalid lock entry: ${packagePath}`);
    if (entry.dev === true) continue;
    const name = packageNameFromLockPath(packagePath);
    if (typeof entry.version !== "string" || entry.version.length === 0) {
      throw new Error(`Runtime package lock has no version for ${packagePath}`);
    }
    if (typeof entry.license !== "string" || entry.license.length === 0) {
      throw new Error(
        `Runtime package lock has no declared license for ${packagePath}`
      );
    }
    const packageDirectory = resolve(root, packagePath);
    assertWithin(root, packageDirectory);
    try {
      await stat(packageDirectory);
    } catch (error) {
      if (entry.optional === true && error?.code === "ENOENT") continue;
      throw error;
    }
    const installedPackage = JSON.parse(
      await readFile(resolve(packageDirectory, "package.json"), "utf8")
    );
    if (
      installedPackage.name !== name ||
      installedPackage.version !== entry.version
    ) {
      throw new Error(
        `Installed package does not match the lock entry: ${packagePath}`
      );
    }
    const licenseFiles = await findLicenseFiles(root, packageDirectory);
    components.push({
      name,
      version: entry.version,
      license: entry.license,
      packagePath,
      licenseFiles,
      ...(typeof entry.resolved === "string"
        ? { resolved: entry.resolved }
        : {}),
      ...(typeof entry.integrity === "string"
        ? { integrity: entry.integrity }
        : {}),
    });
  }
  return components.sort((left, right) =>
    left.packagePath.localeCompare(right.packagePath)
  );
}

async function findLicenseFiles(runtime, packageDirectory) {
  const names = await readdir(packageDirectory, { withFileTypes: true });
  const candidates = names
    .filter(
      (entry) =>
        entry.isFile() &&
        /^(license|licence|notice|copying)([._-]|$)/i.test(entry.name)
    )
    .map((entry) => resolve(packageDirectory, entry.name))
    .sort((left, right) => basename(left).localeCompare(basename(right)));
  for (const candidate of candidates) {
    const metadata = await stat(candidate);
    if (!metadata.isFile() || metadata.size === 0) {
      throw new Error(
        `Bundled license file is not a non-empty file: ${candidate}`
      );
    }
  }
  return candidates.map((candidate) => relative(runtime, candidate));
}

function componentToSbom(component) {
  const purlName = component.name.startsWith("@")
    ? `%40${component.name.slice(1).replace("/", "/")}`
    : component.name;
  const purl = `pkg:npm/${purlName}@${component.version}`;
  const value = {
    "bom-ref": `${purl}?pi-agent-path=${encodeURIComponent(
      component.packagePath
    )}`,
    type: "library",
    name: component.name,
    version: component.version,
    licenses: [{ license: { expression: component.license } }],
    purl,
    properties: [
      { name: "pi-agent:bundled-path", value: component.packagePath },
      {
        name: "pi-agent:license-files",
        value: component.licenseFiles.join(","),
      },
      {
        name: "pi-agent:license-file-status",
        value:
          component.licenseFiles.length === 0
            ? "not-bundled-by-package"
            : "bundled",
      },
    ],
  };
  if (component.integrity?.startsWith("sha512-")) {
    value.hashes = [
      {
        alg: "SHA-512",
        content: Buffer.from(
          component.integrity.slice("sha512-".length),
          "base64"
        ).toString("hex"),
      },
    ];
  }
  if (component.resolved !== undefined) {
    value.externalReferences = [
      { type: "distribution", url: component.resolved },
    ];
  }
  return value;
}

async function writeOrVerify(path, content) {
  if (!verifyOnly) {
    await writeFile(path, content, "utf8");
    return;
  }
  const current = await readFile(path, "utf8");
  if (current !== content)
    throw new Error(
      `Runtime compliance inventory is stale or malformed: ${path}`
    );
}

async function nodeVersion(path) {
  const packageJSON = JSON.parse(
    await readFile(resolve(runtimeRoot, "package.json"), "utf8")
  );
  if (typeof packageJSON.engines?.node !== "string")
    throw new Error("Runtime package must declare a Node engine range");
  return (await import("node:child_process"))
    .execFileSync(path, ["--version"], { encoding: "utf8" })
    .trim()
    .replace(/^v/, "");
}

async function hashFile(path) {
  return createHash("sha256")
    .update(await readFile(path))
    .digest("hex");
}

function packageNameFromLockPath(packagePath) {
  const segments = packagePath.split("/");
  const nodeModulesIndex = segments.lastIndexOf("node_modules");
  const packageSegments = segments.slice(nodeModulesIndex + 1);
  if (packageSegments.length === 1 && !packageSegments[0].startsWith("@"))
    return packageSegments[0];
  if (packageSegments.length === 2 && packageSegments[0].startsWith("@"))
    return packageSegments.join("/");
  throw new Error(
    `Could not determine npm package name from lock path: ${packagePath}`
  );
}

function assertWithin(parent, candidate) {
  const value = relative(parent, candidate);
  if (value === "" || value === ".." || value.startsWith(`..${sep}`)) {
    throw new Error(`Path escapes the Runtime root: ${candidate}`);
  }
}

function optionValue(name) {
  const index = process.argv.indexOf(name);
  return index < 0 ? undefined : process.argv[index + 1];
}
