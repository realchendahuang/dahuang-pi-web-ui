import { LitElement, css, html } from "lit";
import { customElement, property } from "lit/decorators.js";
import type { SessionStatus } from "../api";
import type { WorkspacePanelContext } from "../plugins/types";
import { LocaleController, t } from "../i18n";

/**
 * Context panel: the current session's model, thinking level, context window
 * usage, token counters, cost, and compaction state. Data comes from the
 * already-loaded AppState (SessionStatus); no extra requests.
 */
@customElement("workspace-context-panel")
export class WorkspaceContextPanel extends LitElement {
  private readonly locale = new LocaleController(this);

	@property({ attribute: false }) context: WorkspacePanelContext | undefined;

	override render() {
    void this.locale.locale;
		const context = this.context;
		if (context === undefined) return html`<p class="muted">${t("common.loading")}</p>`;
		const state = context.state;
		const session = state.selectedSession;
		if (session === undefined) {
			return html`
        <div class="empty-state">
          <h2>${t("contextBar.noSessionSelected")}</h2>
          <p>${t("empty.selectSessionToInspect")}</p>
        </div>
      `;
		}
		const status = state.status;
		return html`
      <div class="sections">
        <section>
          <h3>${t("context.model")}</h3>
          <dl>
            <div><dt>${t("context.model")}</dt><dd>${status?.model?.id ?? "—"}</dd></div>
            <div><dt>${t("context.provider")}</dt><dd>${status?.model?.provider ?? "—"}</dd></div>
            <div><dt>${t("context.thinkingLevel")}</dt><dd>${status?.thinkingLevel ?? "—"}</dd></div>
          </dl>
        </section>
        <section>
          <h3>${t("context.heading")}</h3>
          ${this.renderContextUsage(status)}
        </section>
        <section>
          <h3>${t("context.tokens")}</h3>
          <dl>
            <div><dt>${t("context.tokensInput")}</dt><dd>${formatCount(status?.tokens.input)}</dd></div>
            <div><dt>${t("context.tokensOutput")}</dt><dd>${formatCount(status?.tokens.output)}</dd></div>
            <div><dt>${t("context.tokensCacheRead")}</dt><dd>${formatCount(status?.tokens.cacheRead)}</dd></div>
            <div><dt>${t("context.tokensCacheWrite")}</dt><dd>${formatCount(status?.tokens.cacheWrite)}</dd></div>
            <div><dt>${t("context.tokensTotal")}</dt><dd>${formatCount(status?.tokens.total)}</dd></div>
          </dl>
        </section>
        <section>
          <h3>${t("context.sessionHeading")}</h3>
          <dl>
            <div><dt>${t("context.cost")}</dt><dd>$${formatCost(status?.cost)}</dd></div>
            <div><dt>${t("context.messages")}</dt><dd>${String(status?.messageCount ?? session.messageCount)}</dd></div>
            <div><dt>${t("context.compaction")}</dt><dd>${status?.isCompacting === true ? t("context.compacting") : t("context.idle")}</dd></div>
            <div><dt>${t("context.streaming")}</dt><dd>${status?.isStreaming === true ? t("common.yes") : t("common.no")}</dd></div>
          </dl>
        </section>
      </div>
    `;
	}

	private renderContextUsage(status: SessionStatus | undefined) {
		const usage = status?.contextUsage;
		const percent = usage?.percent;
		if (percent === undefined || percent === null) {
			return html`<p class="muted">${t("context.windowUsed")}</p>`;
		}
		const clampedPercent = Math.min(100, Math.max(0, percent));
		const tokens =
			usage?.tokens === null || usage?.tokens === undefined
				? "—"
				: formatCount(usage.tokens);
		return html`
      <div class="usage">
        <div class="usage-bar" role="progressbar" aria-valuenow=${Math.round(clampedPercent)} aria-valuemin="0" aria-valuemax="100" aria-label=${t("context.windowUsed")}>
          <div class=${`usage-fill ${clampedPercent >= 90 ? "critical" : clampedPercent >= 70 ? "warn" : ""}`} style=${`width:${String(clampedPercent)}%`}></div>
        </div>
        <p class="usage-label">${t("context.usageLabel", { tokens, window: formatCount(usage?.contextWindow), percent: clampedPercent.toFixed(1) })}</p>
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
