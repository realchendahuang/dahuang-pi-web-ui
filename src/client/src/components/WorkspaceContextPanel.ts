import { LitElement, css, html } from "lit";
import { customElement, property } from "lit/decorators.js";
import type { SessionStatus } from "../api";
import type { WorkspacePanelContext } from "../plugins/types";

/**
 * Context panel: the current session's model, thinking level, context window
 * usage, token counters, cost, and compaction state. Data comes from the
 * already-loaded AppState (SessionStatus); no extra requests.
 */
@customElement("workspace-context-panel")
export class WorkspaceContextPanel extends LitElement {
	@property({ attribute: false }) context: WorkspacePanelContext | undefined;

	override render() {
		const context = this.context;
		if (context === undefined) return html`<p class="muted">Loading…</p>`;
		const state = context.state;
		const session = state.selectedSession;
		if (session === undefined) {
			return html`
        <div class="empty-state">
          <h2>No session selected</h2>
          <p>Select a session to inspect its model, context usage, and cost.</p>
        </div>
      `;
		}
		const status = state.status;
		return html`
      <div class="sections">
        <section>
          <h3>Model</h3>
          <dl>
            <div><dt>Model</dt><dd>${status?.model?.id ?? "—"}</dd></div>
            <div><dt>Provider</dt><dd>${status?.model?.provider ?? "—"}</dd></div>
            <div><dt>Thinking level</dt><dd>${status?.thinkingLevel ?? "—"}</dd></div>
          </dl>
        </section>
        <section>
          <h3>Context</h3>
          ${this.renderContextUsage(status)}
        </section>
        <section>
          <h3>Tokens</h3>
          <dl>
            <div><dt>Input</dt><dd>${formatCount(status?.tokens.input)}</dd></div>
            <div><dt>Output</dt><dd>${formatCount(status?.tokens.output)}</dd></div>
            <div><dt>Cache read</dt><dd>${formatCount(status?.tokens.cacheRead)}</dd></div>
            <div><dt>Cache write</dt><dd>${formatCount(status?.tokens.cacheWrite)}</dd></div>
            <div><dt>Total</dt><dd>${formatCount(status?.tokens.total)}</dd></div>
          </dl>
        </section>
        <section>
          <h3>Session</h3>
          <dl>
            <div><dt>Cost</dt><dd>$${formatCost(status?.cost)}</dd></div>
            <div><dt>Messages</dt><dd>${String(status?.messageCount ?? session.messageCount)}</dd></div>
            <div><dt>Compaction</dt><dd>${status?.isCompacting === true ? "Compacting…" : "Idle"}</dd></div>
            <div><dt>Streaming</dt><dd>${status?.isStreaming === true ? "Yes" : "No"}</dd></div>
          </dl>
        </section>
      </div>
    `;
	}

	private renderContextUsage(status: SessionStatus | undefined) {
		const usage = status?.contextUsage;
		const percent = usage?.percent;
		if (percent === undefined || percent === null) {
			return html`<p class="muted">Context usage is not available for this model.</p>`;
		}
		const clampedPercent = Math.min(100, Math.max(0, percent));
		const tokens =
			usage?.tokens === null || usage?.tokens === undefined
				? "—"
				: formatCount(usage.tokens);
		return html`
      <div class="usage">
        <div class="usage-bar" role="progressbar" aria-valuenow=${Math.round(clampedPercent)} aria-valuemin="0" aria-valuemax="100" aria-label="Context window used">
          <div class=${`usage-fill ${clampedPercent >= 90 ? "critical" : clampedPercent >= 70 ? "warn" : ""}`} style=${`width:${String(clampedPercent)}%`}></div>
        </div>
        <p class="usage-label">${tokens} / ${formatCount(usage?.contextWindow)} tokens · ${clampedPercent.toFixed(1)}% used</p>
      </div>
    `;
	}

	static override styles = css`
    :host { display: block; min-height: 0; height: 100%; overflow: auto; color: var(--pi-text); font: 13px var(--pi-font-sans, system-ui, sans-serif); }
    .sections { display: grid; gap: 4px; padding: 10px 12px 20px; }
    section { padding: 10px 0 12px; border-bottom: 1px solid var(--pi-border-muted); }
    section:last-child { border-bottom: 0; }
    h3 { margin: 0 0 8px; color: var(--pi-muted); font-size: 11px; font-weight: 600; letter-spacing: .04em; text-transform: uppercase; }
    dl { display: grid; gap: 5px; margin: 0; }
    dl > div { display: grid; grid-template-columns: minmax(96px, max-content) minmax(0, 1fr); gap: 10px; align-items: baseline; }
    dt { color: var(--pi-muted); font-size: 12px; }
    dd { min-width: 0; margin: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 12.5px; }
    .usage { display: grid; gap: 6px; }
    .usage-bar { height: 5px; overflow: hidden; border-radius: 999px; background: var(--pi-surface-secondary, var(--pi-surface-hover)); }
    .usage-fill { height: 100%; border-radius: 999px; background: var(--pi-success); transition: width .2s ease; }
    .usage-fill.warn { background: var(--pi-warning); }
    .usage-fill.critical { background: var(--pi-danger); }
    .usage-label { margin: 0; color: var(--pi-muted); font-size: 12px; }
    .muted { padding: 4px 0; color: var(--pi-muted); font-size: 12px; }
    .empty-state { box-sizing: border-box; width: min(100%, 340px); margin: auto; padding: 32px 24px; display: grid; gap: 8px; color: var(--pi-muted); text-align: center; }
    .empty-state h2 { margin: 0; color: var(--pi-text); font-size: 15px; }
    .empty-state p { margin: 0; line-height: 1.45; }
  `;
}

function formatCount(value: number | undefined): string {
	if (value === undefined) return "—";
	if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(1)}M`;
	if (value >= 1_000) return `${(value / 1_000).toFixed(1)}k`;
	return String(value);
}

function formatCost(value: number | undefined): string {
	if (value === undefined) return "0.00";
	return value.toFixed(value >= 1 ? 2 : 4);
}
