import { LitElement, css, html, type TemplateResult } from "lit";
import { customElement, property } from "lit/decorators.js";
import type { GitDiffResponse, GitStatusFile, GitStatusResponse } from "../api";
import type { WorkspacePanelContext } from "../plugins/types";

/**
 * Changes panel: review the working-tree changes produced while working in
 * this workspace. Flat grouped file list (staged / modified / untracked) with
 * a unified diff viewer. Read-only by design: git mutations (stage, restore,
 * commit) are not exposed by the server API yet.
 */
@customElement("workspace-changes-panel")
export class WorkspaceChangesPanel extends LitElement {
	@property({ attribute: false }) context: WorkspacePanelContext | undefined;

	override render() {
		const context = this.context;
		if (context === undefined) return html`<p class="muted">Loading…</p>`;
		const status = context.gitStatus;
		return html`
      <div class="toolbar">
        <strong>${branchLabel(status)}</strong>
        ${context.gitStale ? html`<span class="stale">stale</span>` : null}
        <button type="button" @click=${() => {
					context.onRefreshGit();
				}}>Refresh</button>
      </div>
      ${this.renderBody(context, status)}
    `;
	}

	private renderBody(
		context: WorkspacePanelContext,
		status: GitStatusResponse | undefined,
	) {
		if (status === undefined)
			return html`<p class="muted">No status loaded.</p>`;
		if (!status.isGitRepo)
			return html`<p class="muted">Not a git repository.</p>`;
		if (status.files.length === 0) {
			return html`
        <div class="empty-state">
          <h2>No changes</h2>
          <p>Files the agent edits in this workspace will show up here for review.</p>
        </div>
      `;
		}
		const groups = groupChangedFiles(status.files);
		return html`
      <section class="split">
        <div class="list">
          <p class="summary">${String(status.files.length)} changed ${status.files.length === 1 ? "file" : "files"}</p>
          ${groups.map(
						(group) => html`
            <h3 class="group-heading">${group.label} · ${String(group.files.length)}</h3>
            ${group.files.map((file) => this.renderFileRow(context, file))}
          `,
					)}
        </div>
        <div class="viewer">${renderDiffViewer(context)}</div>
      </section>
    `;
	}

	private renderFileRow(context: WorkspacePanelContext, file: GitStatusFile) {
		const selected = context.selectedDiffPath === file.path;
		return html`
      <button type="button" class=${selected ? "row selected" : "row"} @click=${() => {
				context.onSelectDiff(file.path);
			}}>
        <span class=${`state state-${stateClass(file)}`}>${stateLabel(file.index, file.workingTree)}</span>
        <span class="path" dir="auto" title=${file.path}>${file.path}</span>
      </button>
    `;
	}

	static override styles = css`
    :host { display: flex; flex-direction: column; min-height: 0; height: 100%; color: var(--pi-text); font: 13px var(--pi-font-sans, system-ui, sans-serif); }
    .toolbar { flex: 0 0 auto; display: flex; align-items: center; gap: 8px; padding: 8px 10px; border-bottom: 1px solid var(--pi-border-muted); }
    .toolbar strong { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 13px; }
    .toolbar button { margin-left: auto; border: 1px solid var(--pi-border); border-radius: var(--pi-radius-xs, 6px); background: var(--pi-surface); color: var(--pi-text-secondary); padding: 4px 8px; font: inherit; font-size: 12px; cursor: pointer; }
    .toolbar button:hover { color: var(--pi-text); border-color: var(--pi-border-strong, var(--pi-border)); }
    .stale { border: 1px solid var(--pi-warning-border); border-radius: 999px; color: var(--pi-warning); padding: 1px 6px; font-size: 11px; }
    .split { flex: 1 1 auto; min-height: 0; display: grid; grid-template-rows: minmax(140px, 36%) minmax(0, 1fr); }
    .list { min-height: 0; overflow: auto; border-bottom: 1px solid var(--pi-border-muted); padding: 4px 6px 10px; }
    .summary { margin: 4px 6px 6px; color: var(--pi-muted); font-size: 12px; }
    .group-heading { margin: 10px 6px 3px; color: var(--pi-muted); font-size: 11px; font-weight: 600; letter-spacing: .04em; text-transform: uppercase; }
    .row { display: grid; grid-template-columns: 16px minmax(0, 1fr); gap: 6px; align-items: center; width: 100%; border: 0; border-radius: var(--pi-radius-xs, 6px); background: transparent; color: var(--pi-text); text-align: left; padding: 4px 6px; font: inherit; cursor: pointer; }
    .row:hover { background: var(--pi-surface-hover); }
    .row.selected { background: var(--pi-surface-secondary, var(--pi-selection-bg)); }
    .state { font: 600 11px var(--pi-font-mono, ui-monospace, monospace); text-align: center; }
    .state-modified { color: var(--pi-warning); }
    .state-added { color: var(--pi-success); }
    .state-deleted { color: var(--pi-danger); }
    .state-other { color: var(--pi-muted); }
    .path { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 12.5px; unicode-bidi: plaintext; }
    .viewer { min-height: 0; overflow: auto; display: flex; flex-direction: column; }
    .viewer .diffs { flex: 1 1 auto; min-height: 0; display: grid; }
    .viewer .diffs:not(.single) { grid-template-rows: 1fr 1fr; }
    .diff-section { min-height: 0; display: flex; flex-direction: column; }
    .viewer-header { display: flex; align-items: baseline; justify-content: space-between; gap: 8px; padding: 6px 10px; border-bottom: 1px solid var(--pi-border-muted); }
    .viewer-header strong { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 12px; }
    .viewer-header small { flex: 0 0 auto; color: var(--pi-muted); }
    .diff-section unified-diff-viewer { flex: 1 1 auto; min-height: 0; }
    .muted { padding: 12px; color: var(--pi-muted); }
    .empty-state { box-sizing: border-box; width: min(100%, 340px); margin: auto; padding: 24px; display: grid; gap: 8px; color: var(--pi-muted); text-align: center; }
    .empty-state h2 { margin: 0; color: var(--pi-text); font-size: 15px; }
    .empty-state p { margin: 0; line-height: 1.45; }
  `;
}

interface ChangedFileGroup {
	id: "staged" | "modified" | "untracked";
	label: string;
	files: GitStatusFile[];
}

export function groupChangedFiles(
	files: readonly GitStatusFile[],
): ChangedFileGroup[] {
	const staged: GitStatusFile[] = [];
	const modified: GitStatusFile[] = [];
	const untracked: GitStatusFile[] = [];
	for (const file of files) {
		if (file.index === "untracked" || file.workingTree === "untracked") {
			untracked.push(file);
			continue;
		}
		if (file.index !== "unmodified" && file.index !== "ignored")
			staged.push(file);
		if (file.workingTree !== "unmodified" && file.workingTree !== "ignored")
			modified.push(file);
	}
	const groups: ChangedFileGroup[] = [];
	if (staged.length > 0)
		groups.push({ id: "staged", label: "Staged", files: staged });
	if (modified.length > 0)
		groups.push({ id: "modified", label: "Modified", files: modified });
	if (untracked.length > 0)
		groups.push({ id: "untracked", label: "Untracked", files: untracked });
	return groups;
}

function renderDiffViewer(context: WorkspacePanelContext): TemplateResult {
	if (context.selectedDiffPath === undefined || context.selectedDiffPath === "")
		return html`<p class="muted">Select a changed file to review its diff.</p>`;
	const unstaged = context.selectedDiff;
	const staged = context.selectedStagedDiff;
	if (unstaged === undefined || staged === undefined)
		return html`<p class="muted">Loading diff…</p>`;
	const diffs = [staged, unstaged].filter((diff) => diff.diff !== "");
	if (diffs.length === 0)
		return html`<p class="muted">No staged or unstaged diff.</p>`;
	return html`
    <div class=${diffs.length === 1 ? "diffs single" : "diffs"}>
      ${diffs.map((diff) => renderDiffSection(diff))}
    </div>
  `;
}

function renderDiffSection(diff: GitDiffResponse): TemplateResult {
	loadUnifiedDiffViewer();
	return html`
    <section class="diff-section">
      <div class="viewer-header"><strong>${diff.path ?? "diff"}</strong><small>${diff.staged ? "staged" : "unstaged"}${diff.truncated ? " · truncated" : ""}</small></div>
      <unified-diff-viewer .diff=${diff.diff}></unified-diff-viewer>
    </section>
  `;
}

function loadUnifiedDiffViewer(): void {
	void import("./UnifiedDiffViewer");
}

function branchLabel(status: GitStatusResponse | undefined): string {
	if (status?.isGitRepo !== true) return "Changes";
	const branch = status.branch ?? "detached";
	const ahead = status.ahead ?? 0;
	const behind = status.behind ?? 0;
	return ahead === 0 && behind === 0
		? branch
		: `${branch} · ↑${String(ahead)} ↓${String(behind)}`;
}

function stateLabel(index: string, workingTree: string): string {
	const label = workingTree !== "unmodified" ? workingTree : index;
	return label.slice(0, 1).toUpperCase();
}

function stateClass(file: GitStatusFile): string {
	const label =
		file.workingTree !== "unmodified" ? file.workingTree : file.index;
	if (label === "added" || label === "untracked") return "added";
	if (label === "deleted") return "deleted";
	if (label === "modified" || label === "renamed" || label === "copied")
		return "modified";
	return "other";
}
