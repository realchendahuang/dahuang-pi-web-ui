import { LitElement, css, html, svg, type TemplateResult } from "lit";
import { customElement, property, state } from "lit/decorators.js";
import { writeClipboardText } from "../../clipboard";
import type { ToolExecutionPart } from "../../components/shared";
import {
	toolCardViewModel,
	type ToolCardKind,
	type ToolCardViewModel,
} from "./toolCardModel";

const MAX_COLLAPSED_DIFF_LINES = 160;
const MAX_OUTPUT_LINES = 400;

/**
 * Unified tool call card. Collapsed by default to a single informative row;
 * expands to a per-tool body (file preview, terminal output, diff, matches,
 * or a readable error). Supersedes tool-execution-view.
 */
@customElement("tool-card")
export class ToolCard extends LitElement {
	@property({ attribute: false }) execution: ToolExecutionPart | undefined;
	@property({ attribute: false }) onOpenInChanges?: (
		filePath: string | undefined,
	) => void;
	@state() private open = false;
	@state() private userToggled = false;
	@state() private showFullDiff = false;
	@state() private copiedTarget: "command" | "output" | "diff" | undefined;

	override render() {
		const execution = this.execution;
		if (execution === undefined) return null;
		const model = toolCardViewModel(execution);
		const open = this.effectiveOpen(model);
		return html`
      <section class=${`tool-card ${model.status} kind-${model.kind}`} data-status=${model.status}>
        <button type="button" class="tool-row" aria-expanded=${String(open)} @click=${() => {
					this.toggle(model);
				}}>
          <span class=${`status-dot ${model.status}`} aria-hidden="true"></span>
          <span class="tool-icon" aria-hidden="true">${toolIcon(model.kind)}</span>
          <span class="tool-title" dir="auto" title=${model.title}>${model.title}</span>
          ${model.editCountLabel === undefined ? null : html`<span class="tool-meta-text">${model.editCountLabel}</span>`}
          ${model.diff === undefined ? null : html`<span class="diff-stats" aria-label=${`${String(model.diff.additions)} additions, ${String(model.diff.deletions)} deletions`}><b class="added">+${model.diff.additions}</b> <b class="removed">−${model.diff.deletions}</b></span>`}
          ${model.status === "failed" ? html`<span class="tool-status-label failed">failed</span>` : null}
          ${model.status === "running" || model.status === "pending" ? html`<span class="tool-status-label running">${model.status}</span>` : null}
          <span class=${`chevron ${open ? "open" : ""}`} aria-hidden="true">›</span>
        </button>
        ${open ? this.renderBody(model) : null}
      </section>
    `;
	}

	private effectiveOpen(model: ToolCardViewModel): boolean {
		if (this.userToggled) return this.open;
		return model.status === "failed";
	}

	private toggle(model: ToolCardViewModel): void {
		this.open = !this.effectiveOpen(model);
		this.userToggled = true;
	}

	private renderBody(model: ToolCardViewModel) {
		return html`
      <div class="tool-body">
        ${model.status === "failed" ? this.renderErrorBody(model) : null}
        ${model.kind === "read" ? this.renderReadBody(model) : null}
        ${model.kind === "bash" ? this.renderBashBody(model) : null}
        ${model.kind === "edit" || model.kind === "write" ? this.renderDiffBody(model) : null}
        ${model.kind === "search" ? this.renderSearchBody(model) : null}
        ${model.kind === "generic" && model.status !== "failed" ? this.renderGenericBody(model) : null}
      </div>
    `;
	}

	private renderFileHeader(model: ToolCardViewModel) {
		if (model.filePath === undefined) return null;
		return html`
      <div class="body-header">
        <span class="body-path" dir="auto" title=${model.filePath}>${model.filePath}</span>
        ${
					this.onOpenInChanges === undefined
						? null
						: html`
          <button type="button" class="text-button" @click=${() => this.onOpenInChanges?.(model.filePath)}>Open in Changes</button>
        `
				}
      </div>
    `;
	}

	private renderReadBody(model: ToolCardViewModel) {
		const preview = truncateLines(model.resultText ?? "", MAX_OUTPUT_LINES);
		if (model.filePath === undefined && preview.text === "") return null;
		return html`
      ${this.renderFileHeader(model)}
      ${
				preview.text === ""
					? null
					: html`
        <div class="output-block">
          <pre class="output" data-kind="read"><code>${preview.text}</code></pre>
          <div class="output-footer">
            ${preview.truncated ? html`<span class="truncation-note">Output truncated to the first ${String(MAX_OUTPUT_LINES)} lines.</span>` : null}
            <button type="button" class="text-button" @click=${() => {
							void this.copy("output", model.resultText ?? "");
						}}>${this.copiedTarget === "output" ? "Copied" : "Copy output"}</button>
          </div>
        </div>
      `
			}
    `;
	}

	private renderBashBody(model: ToolCardViewModel) {
		const output = truncateLines(model.resultText ?? "", MAX_OUTPUT_LINES);
		return html`
      ${this.renderCommandBlock(model)}
      ${
				output.text === ""
					? null
					: html`
        <div class="output-block">
          <pre class="output shell" dir="ltr"><code>${output.text}</code></pre>
          <div class="output-footer">
            ${output.truncated ? html`<span class="truncation-note">Showing first ${String(MAX_OUTPUT_LINES)} lines</span>` : null}
            <button type="button" class="text-button" @click=${() => {
							void this.copy("output", model.resultText ?? "");
						}}>${this.copiedTarget === "output" ? "Copied" : "Copy output"}</button>
          </div>
        </div>
      `
			}
    `;
	}

	private renderDiffBody(model: ToolCardViewModel) {
		const diff = model.diff;
		return html`
      ${this.renderFileHeader(model)}
      ${
				diff === undefined
					? model.resultText === undefined || model.resultText === ""
						? null
						: html`<pre class="output"><code>${truncateLines(model.resultText, MAX_OUTPUT_LINES).text}</code></pre>`
					: html`
        ${diff.isPreview ? html`<p class="preview-note">Preview of proposed changes — the applied diff may differ.</p>` : null}
        ${this.renderDiff(diff.content)}
      `
			}
    `;
	}

	private renderDiff(content: string) {
		const lines = content.split("\n");
		const truncated =
			!this.showFullDiff && lines.length > MAX_COLLAPSED_DIFF_LINES;
		const visible = truncated
			? lines.slice(0, MAX_COLLAPSED_DIFF_LINES)
			: lines;
		return html`
      <pre class="diff" dir="ltr" aria-label="Diff"><code>${visible.map((line) => html`<span class=${diffLineClass(line)}>${line}</span>`)}</code></pre>
      <div class="output-footer">
        ${
					truncated
						? html`
          <button type="button" class="text-button" @click=${() => {
						this.showFullDiff = true;
					}}>Show all ${String(lines.length)} lines</button>
        `
						: null
				}
        <button type="button" class="text-button" @click=${() => {
					void this.copy("diff", content);
				}}>${this.copiedTarget === "diff" ? "Copied" : "Copy diff"}</button>
      </div>
    `;
	}

	private renderSearchBody(model: ToolCardViewModel) {
		const text = model.resultText ?? "";
		if (text === "") return null;
		const result = truncateLines(text, MAX_OUTPUT_LINES);
		const count = text.split("\n").filter((line) => line.trim() !== "").length;
		return html`
      <p class="result-count">${String(count)} result${count === 1 ? "" : "s"}</p>
      <pre class="output" dir="ltr"><code>${result.text}</code></pre>
      ${result.truncated ? html`<p class="truncation-note">Output truncated to the first ${String(MAX_OUTPUT_LINES)} lines.</p>` : null}
    `;
	}

	private renderGenericBody(model: ToolCardViewModel) {
		if (model.resultText === undefined || model.resultText === "") return null;
		const result = truncateLines(model.resultText, MAX_OUTPUT_LINES);
		return html`
      <pre class="output" dir="ltr"><code>${result.text}</code></pre>
      ${result.truncated ? html`<p class="truncation-note">Output truncated to the first ${String(MAX_OUTPUT_LINES)} lines.</p>` : null}
    `;
	}

	private renderErrorBody(model: ToolCardViewModel) {
		return html`
      ${model.error === undefined ? null : html`<pre class="error-text" dir="auto">${model.error}</pre>`}
      ${
				model.rawDetails === undefined
					? null
					: html`
        <details class="raw-details">
          <summary>Raw error details</summary>
          <pre class="output" dir="ltr"><code>${truncateLines(model.rawDetails, MAX_OUTPUT_LINES).text}</code></pre>
        </details>
      `
			}
      ${model.kind === "bash" && model.command !== undefined ? this.renderCommandBlock(model) : null}
    `;
	}

	private renderCommandBlock(model: ToolCardViewModel) {
		if (model.command === undefined) return null;
		return html`
      <div class="command-block">
        <pre class="command" dir="ltr"><code>$ ${model.command}</code></pre>
        <button type="button" class="text-button" @click=${() => {
					void this.copy("command", model.command ?? "");
				}}>${this.copiedTarget === "command" ? "Copied" : "Copy command"}</button>
      </div>
    `;
	}

	private async copy(
		target: "command" | "output" | "diff",
		text: string,
	): Promise<void> {
		const copied = await writeClipboardText(text);
		if (!copied) return;
		this.copiedTarget = target;
		window.setTimeout(() => {
			if (this.copiedTarget === target) this.copiedTarget = undefined;
		}, 1200);
	}

	static override styles = css`
    :host { display: block; width: 100%; max-width: 100%; min-width: 0; color: var(--pi-text); }
    .tool-card { box-sizing: border-box; width: 100%; max-width: 100%; min-width: 0; overflow: hidden; border: 1px solid var(--pi-border-muted); border-radius: var(--pi-radius-md, 10px); background: var(--pi-surface); }
    .tool-card.failed { border-color: color-mix(in srgb, var(--pi-danger) 40%, transparent); }
    .tool-row { display: flex; align-items: center; gap: 8px; width: 100%; min-width: 0; box-sizing: border-box; border: 0; background: transparent; color: var(--pi-text); padding: 8px 10px; font: inherit; font-size: 13px; text-align: left; cursor: pointer; }
    .tool-row:hover { background: var(--pi-surface-hover); }
    .tool-row:focus-visible { outline: 2px solid var(--pi-accent); outline-offset: -2px; }
    .status-dot { flex: 0 0 auto; width: 7px; height: 7px; border-radius: 50%; background: var(--pi-dim); }
    .status-dot.success { background: var(--pi-success); }
    .status-dot.failed { background: var(--pi-danger); }
    .status-dot.running, .status-dot.pending { background: var(--pi-accent); animation: pulse 1.1s ease-in-out infinite; }
    .tool-icon { flex: 0 0 auto; display: inline-grid; place-items: center; width: 16px; height: 16px; color: var(--pi-text-secondary); }
    .tool-icon svg { width: 15px; height: 15px; fill: none; stroke: currentColor; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; }
    .tool-title { flex: 1 1 auto; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--pi-text); }
    .tool-meta-text { flex: 0 0 auto; color: var(--pi-muted); font-size: 12px; }
    .diff-stats { flex: 0 0 auto; display: inline-flex; gap: 4px; font-size: 12px; font-weight: 400; }
    .diff-stats .added, .diff .added { color: var(--pi-success); }
    .diff-stats .removed, .diff .removed { color: var(--pi-danger); }
    .tool-status-label { flex: 0 0 auto; font-size: 11px; text-transform: uppercase; letter-spacing: .05em; }
    .tool-status-label.failed { color: var(--pi-danger); }
    .tool-status-label.running { color: var(--pi-accent); }
    .chevron { flex: 0 0 auto; color: var(--pi-muted); font-size: 14px; line-height: 1; transition: transform .12s ease; }
    .chevron.open { transform: rotate(90deg); }
    .tool-body { min-width: 0; padding: 2px 10px 10px 34px; border-top: 1px solid var(--pi-border-muted); }
    .body-header { display: flex; align-items: center; justify-content: space-between; gap: 8px; min-width: 0; margin-top: 8px; }
    .body-path { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--pi-accent); font: 12px var(--pi-font-mono, ui-monospace, monospace); direction: ltr; text-align: left; unicode-bidi: isolate; }
    .command-block { display: flex; align-items: flex-start; justify-content: space-between; gap: 8px; min-width: 0; margin-top: 8px; }
    .command { flex: 1 1 auto; min-width: 0; margin: 0; overflow-x: auto; border: 1px solid var(--pi-border-muted); border-radius: var(--pi-radius-xs, 6px); background: var(--pi-bg); padding: 6px 8px; color: var(--pi-text); font: 12px var(--pi-font-mono, ui-monospace, monospace); white-space: pre; unicode-bidi: isolate; }
    .output-block { margin-top: 6px; }
    .output { box-sizing: border-box; width: 100%; max-width: 100%; max-height: 320px; margin: 6px 0 0; overflow: auto; overscroll-behavior: contain; border: 1px solid var(--pi-border-muted); border-radius: var(--pi-radius-xs, 6px); background: var(--pi-bg); padding: 8px; color: var(--pi-text-secondary); font: 12px/1.5 var(--pi-font-mono, ui-monospace, monospace); white-space: pre-wrap; overflow-wrap: anywhere; unicode-bidi: isolate; }
    .output.shell { color: var(--pi-terminal-text); background: var(--pi-terminal-bg); white-space: pre; overflow-wrap: normal; }
    .output.shell code { display: block; width: max-content; min-width: 100%; }
    .output-footer { display: flex; align-items: center; justify-content: flex-end; gap: 10px; margin-top: 6px; }
    .truncation-note { margin: 4px 0 0; color: var(--pi-muted); font-size: 12px; }
    .preview-note { margin: 8px 0 0; color: var(--pi-warning); font-size: 12px; }
    .result-count { margin: 8px 0 0; color: var(--pi-muted); font-size: 12px; }
    .text-button { flex: 0 0 auto; border: 1px solid var(--pi-border); border-radius: var(--pi-radius-xs, 6px); background: var(--pi-surface); color: var(--pi-text-secondary); padding: 3px 8px; font: inherit; font-size: 12px; cursor: pointer; }
    .text-button:hover { color: var(--pi-text); border-color: var(--pi-border-strong, var(--pi-border)); }
    .diff { box-sizing: border-box; width: 100%; max-width: 100%; max-height: 420px; margin: 8px 0 0; overflow: auto; overscroll-behavior: contain; border: 1px solid var(--pi-border-muted); border-radius: var(--pi-radius-xs, 6px); background: var(--pi-bg); padding: 8px 0; color: var(--pi-muted); font: 12px/1.5 var(--pi-font-mono, ui-monospace, monospace); unicode-bidi: isolate; }
    .diff code { display: block; width: max-content; min-width: 100%; }
    .diff span { display: block; min-height: 1.5em; padding: 0 8px; white-space: pre; }
    .diff .context { color: var(--pi-muted); }
    .diff .hunk { color: var(--pi-accent); }
    .diff .file, .diff .meta { color: var(--pi-dim); }
    .diff .added { background: color-mix(in srgb, var(--pi-success) 12%, transparent); }
    .diff .removed { background: color-mix(in srgb, var(--pi-danger) 12%, transparent); }
    .error-text { margin: 8px 0 0; padding: 8px; border: 1px solid color-mix(in srgb, var(--pi-danger) 40%, transparent); border-radius: var(--pi-radius-xs, 6px); background: color-mix(in srgb, var(--pi-danger) 8%, transparent); color: var(--pi-danger); font: 12px/1.5 var(--pi-font-mono, ui-monospace, monospace); white-space: pre-wrap; overflow-wrap: anywhere; }
    .raw-details { margin-top: 8px; }
    .raw-details > summary { color: var(--pi-muted); font-size: 12px; cursor: pointer; }
    @keyframes pulse { 0%, 100% { transform: scale(.8); opacity: .5; } 50% { transform: scale(1.15); opacity: 1; } }
  `;
}

function toolIcon(kind: ToolCardKind): TemplateResult {
	switch (kind) {
		case "read":
			return svg`<svg viewBox="0 0 24 24"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6"/><path d="M16 13H8"/><path d="M16 17H8"/></svg>`;
		case "bash":
			return svg`<svg viewBox="0 0 24 24"><path d="m4 17 6-6-6-6"/><path d="M12 19h8"/></svg>`;
		case "edit":
			return svg`<svg viewBox="0 0 24 24"><path d="M17 3a2.85 2.83 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5z"/></svg>`;
		case "write":
			return svg`<svg viewBox="0 0 24 24"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6"/><path d="M12 18v-6"/><path d="m9 15 3 3 3-3"/></svg>`;
		case "search":
			return svg`<svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/></svg>`;
		case "generic":
			return svg`<svg viewBox="0 0 24 24"><path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z"/></svg>`;
	}
}

function diffLineClass(line: string): string {
	if (line.startsWith("+") && !line.startsWith("+++")) return "added";
	if (line.startsWith("-") && !line.startsWith("---")) return "removed";
	if (line.startsWith("@@")) return "hunk";
	if (line.startsWith("+++") || line.startsWith("---")) return "file";
	if (line.startsWith("diff ") || line.startsWith("index ")) return "meta";
	return "context";
}

function truncateLines(
	text: string,
	maxLines: number,
): { text: string; truncated: boolean } {
	if (text === "") return { text: "", truncated: false };
	const lines = text.split("\n");
	if (lines.length <= maxLines) return { text, truncated: false };
	return { text: lines.slice(0, maxLines).join("\n"), truncated: true };
}
