import { describe, expect, it } from "vitest";
import type { GitStatusFile } from "../api";
import { groupChangedFiles } from "./WorkspaceChangesPanel";

function file(path: string, index: GitStatusFile["index"], workingTree: GitStatusFile["workingTree"]): GitStatusFile {
  return { path, index, workingTree };
}

describe("groupChangedFiles", () => {
  it("returns no groups for a clean tree", () => {
    expect(groupChangedFiles([])).toEqual([]);
  });

  it("groups staged, modified, and untracked files", () => {
    const groups = groupChangedFiles([
      file("a.ts", "added", "unmodified"),
      file("b.ts", "unmodified", "modified"),
      file("c.ts", "untracked", "untracked"),
    ]);
    expect(groups.map((group) => group.id)).toEqual(["staged", "modified", "untracked"]);
    expect(groups[0]?.files.map((entry) => entry.path)).toEqual(["a.ts"]);
    expect(groups[1]?.files.map((entry) => entry.path)).toEqual(["b.ts"]);
    expect(groups[2]?.files.map((entry) => entry.path)).toEqual(["c.ts"]);
  });

  it("lists a file in both staged and modified when it has both kinds of changes", () => {
    const groups = groupChangedFiles([file("a.ts", "modified", "modified")]);
    expect(groups.map((group) => group.id)).toEqual(["staged", "modified"]);
  });

  it("treats index-level untracked entries as untracked only", () => {
    const groups = groupChangedFiles([file("a.ts", "untracked", "untracked")]);
    expect(groups.map((group) => group.id)).toEqual(["untracked"]);
  });

  it("omits empty groups", () => {
    const groups = groupChangedFiles([file("a.ts", "unmodified", "modified")]);
    expect(groups.map((group) => group.id)).toEqual(["modified"]);
  });
});
