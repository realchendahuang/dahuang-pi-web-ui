import { describe, expect, it } from "vitest";
import type { ToolExecutionPart } from "../../components/shared";
import { toolCardKind, toolCardStatus, toolCardViewModel } from "./toolCardModel";

function execution(patch: Partial<ToolExecutionPart> = {}): ToolExecutionPart {
  return {
    type: "toolExecution",
    toolCallId: "call-1",
    toolName: "read",
    summary: "",
    status: "success",
    ...patch,
  };
}

describe("toolCardKind", () => {
  it("maps known tools to kinds", () => {
    expect(toolCardKind("read")).toBe("read");
    expect(toolCardKind("bash")).toBe("bash");
    expect(toolCardKind("edit")).toBe("edit");
    expect(toolCardKind("write")).toBe("write");
    expect(toolCardKind("grep")).toBe("search");
    expect(toolCardKind("find")).toBe("search");
    expect(toolCardKind("todo")).toBe("generic");
    expect(toolCardKind("Read")).toBe("read");
  });
});

describe("toolCardStatus", () => {
  it("maps wire statuses to card statuses", () => {
    expect(toolCardStatus("pending")).toBe("pending");
    expect(toolCardStatus("running")).toBe("running");
    expect(toolCardStatus("success")).toBe("success");
    expect(toolCardStatus("error")).toBe("failed");
  });
});

describe("toolCardViewModel", () => {
  it("builds a read card with the file path in the title", () => {
    const model = toolCardViewModel(execution({ args: { path: "src/app.ts" } }));
    expect(model.kind).toBe("read");
    expect(model.title).toBe("Read src/app.ts");
    expect(model.filePath).toBe("src/app.ts");
    expect(model.verb).toBe("Read");
  });

  it("builds a bash card with the first command line", () => {
    const model = toolCardViewModel(execution({ toolName: "bash", args: { command: "npm test\n-- --watch" }, status: "running" }));
    expect(model.kind).toBe("bash");
    expect(model.title).toBe("Running npm test");
    expect(model.command).toBe("npm test\n-- --watch");
    expect(model.verb).toBe("Running");
  });

  it("builds an edit card with diff stats from applied details", () => {
    const diff = ["--- a/src/app.ts", "+++ b/src/app.ts", "@@ -1,2 +1,3 @@", " line", "+added one", "+added two", "-removed one"].join("\n");
    const model = toolCardViewModel(execution({ toolName: "edit", args: { path: "src/app.ts", oldText: "a", newText: "b" }, details: { diff } }));
    expect(model.kind).toBe("edit");
    expect(model.title).toBe("Edited src/app.ts");
    expect(model.diff).toEqual({ additions: 2, deletions: 1, content: diff, isPreview: false });
    expect(model.editCountLabel).toBe("1 edit");
  });

  it("marks preview diffs when only a preview is available", () => {
    const model = toolCardViewModel(execution({ toolName: "edit", args: { path: "src/app.ts" }, preview: { diff: "+a\n-b" } }));
    expect(model.diff?.isPreview).toBe(true);
    expect(model.diff?.additions).toBe(1);
    expect(model.diff?.deletions).toBe(1);
  });

  it("counts multi-edit calls", () => {
    const model = toolCardViewModel(execution({ toolName: "edit", args: { path: "a.ts", edits: [{}, {}, {}] } }));
    expect(model.editCountLabel).toBe("3 edits");
  });

  it("builds a search card quoting the pattern", () => {
    const model = toolCardViewModel(execution({ toolName: "grep", args: { pattern: "AgentSession" } }));
    expect(model.kind).toBe("search");
    expect(model.title).toBe("Searched for “AgentSession”");
    expect(model.query).toBe("AgentSession");
  });

  it("falls back to the wire summary for generic tools", () => {
    const model = toolCardViewModel(execution({ toolName: "todo", summary: "3 tasks updated" }));
    expect(model.kind).toBe("generic");
    expect(model.title).toBe("Used 3 tasks updated");
  });

  it("extracts a readable error and raw details for failed calls", () => {
    const model = toolCardViewModel(execution({
      toolName: "bash",
      args: { command: "false" },
      status: "error",
      resultText: "exit code 1",
      details: { exitCode: 1 },
    }));
    expect(model.status).toBe("failed");
    expect(model.error).toBe("exit code 1");
    expect(model.rawDetails).toContain("\"exitCode\": 1");
  });

  it("uses present-tense verbs while running", () => {
    expect(toolCardViewModel(execution({ status: "running", args: { path: "a.ts" } })).verb).toBe("Reading");
    expect(toolCardViewModel(execution({ toolName: "write", status: "running", args: { path: "a.ts" } })).verb).toBe("Writing");
    expect(toolCardViewModel(execution({ toolName: "grep", status: "running", args: { pattern: "x" } })).verb).toBe("Searching");
  });
});
