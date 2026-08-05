import { dirname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import ts from "typescript";
import { describe, expect, it } from "vitest";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");

describe("production build contents", () => {
  // Constructing the full compiler graph can exceed Vitest's default timeout under parallel-suite CPU contention.
  it("keeps test-support modules out of the TypeScript build graph", { timeout: 15_000 }, () => {
    const buildConfig = readBuildConfig();
    const program = ts.createProgram({ rootNames: buildConfig.fileNames, options: buildConfig.options });
    const projectSources = program.getSourceFiles()
      .map((sourceFile) => normalizePath(relative(repoRoot, sourceFile.fileName)))
      .filter((path) => path.startsWith("src/"));

    expect(projectSources).toContain("src/server/app.ts");
    expect(projectSources.filter(isTestSupportPath)).toEqual([]);
  });
});

function readBuildConfig(): ts.ParsedCommandLine {
  const configPath = join(repoRoot, "tsconfig.build.json");
  const config = ts.getParsedCommandLineOfConfigFile(configPath, {}, {
    ...ts.sys,
    onUnRecoverableConfigFileDiagnostic(diagnostic) {
      throw new Error(formatDiagnostics([diagnostic]));
    },
  });
  if (config === undefined) throw new Error(`Unable to parse ${configPath}`);
  if (config.errors.length > 0) throw new Error(formatDiagnostics(config.errors));
  return config;
}

function formatDiagnostics(diagnostics: readonly ts.Diagnostic[]): string {
  return ts.formatDiagnostics(diagnostics, {
    getCanonicalFileName: (fileName) => fileName,
    getCurrentDirectory: () => repoRoot,
    getNewLine: () => "\n",
  });
}

function normalizePath(path: string): string {
  return path.split(sep).join("/");
}

function isTestSupportPath(path: string): boolean {
  return path.includes(".testSupport.");
}
