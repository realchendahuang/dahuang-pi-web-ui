import { LitElement, html } from "lit";
import { customElement, property } from "lit/decorators.js";
import type { SessionStatus } from "../api";
import { formatCost, formatTokenCount } from "../utils/format";
import { renderSessionWarningIcon, statusBarStyles } from "./shared";
import { t } from "../i18n";

export interface StatusBarWarningControlContent {
	countText: string;
	accessibleLabel: string;
}

export function statusBarWarningControlContent(
	count: number,
	expanded: boolean,
): StatusBarWarningControlContent | undefined {
	if (!Number.isInteger(count) || count <= 0) return undefined;
	const warningText =
		count === 1 ? t("status.warningOne") : t("status.warningMany", { count });
	return {
		countText: String(count),
		accessibleLabel: expanded
			? t("status.minimiseWarningsCount", { warnings: warningText })
			: t("status.showWarningsCount", { warnings: warningText }),
	};
}

@customElement("status-bar")
export class StatusBar extends LitElement {
	@property({ attribute: false }) status?: SessionStatus;
	@property({ type: Number }) warningCount = 0;
	@property({ type: Boolean }) warningsExpanded = false;
	@property({ attribute: false }) onToggleWarnings?: () => void;

	private readonly handleToggleWarnings = (): void => {
		this.onToggleWarnings?.();
	};

	override render() {
		const status = this.status;
		if (status === undefined)
			return html`<div class="bar muted">${t("status.noStatus")}</div>`;
		const context = status.contextUsage;
		const contextText = context
			? context.percent == null
				? `${t("status.contextWord")} ${formatTokenCount(context.contextWindow)}`
				: `${context.percent.toFixed(1)}%/${formatTokenCount(context.contextWindow)}`
			: t("status.contextUnknown");
		const tokens = status.tokens;
		const warningControl = statusBarWarningControlContent(
			this.warningCount,
			this.warningsExpanded,
		);
		return html`
      <div class="bar">
        ${
					warningControl === undefined || this.onToggleWarnings === undefined
						? null
						: html`
          <button
            type="button"
            class="warning-toggle"
            title=${warningControl.accessibleLabel}
            aria-label=${warningControl.accessibleLabel}
            aria-expanded=${String(this.warningsExpanded)}
            @click=${this.handleToggleWarnings}
          >
            ${renderSessionWarningIcon("warning", "warning-toggle-icon")}
            <span>${warningControl.countText}</span>
          </button>
        `
				}
        <span>↑${formatTokenCount(tokens.input)}</span>
        <span>↓${formatTokenCount(tokens.output)}</span>
        <span class="context">${contextText}</span>
        <span>${formatCost(status.cost)}</span>
        ${status.pendingMessageCount > 0 ? html`<span>${t("status.queued", { count: status.pendingMessageCount })}</span>` : null}
      </div>
    `;
	}

	static override styles = statusBarStyles;
}
