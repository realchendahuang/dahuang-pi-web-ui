import {
	css,
	html,
	LitElement,
	type PropertyValues,
	type TemplateResult,
} from "lit";
import { customElement, property, state } from "lit/decorators.js";
import type {
	ActiveAgentProfileDescriptor,
	PiWebConfigResponse,
	PiWebConfigValues,
} from "../../api";
import { LocaleController, t } from "../../i18n";
import "./SettingsPanelFrame";
import type { SettingsNotice } from "./SettingsPanelFrame";
import {
	agentProfileConfigPatchFromDraft,
	agentProfileDraftFromConfig,
	agentProfileDraftMatchesConfig,
	emptyAgentProfileConfigDraft,
	type AgentProfileConfigDraft,
} from "./settingsConfigDraft";
import type { AgentProfileSettingsSupport } from "./settingsMachineTarget";
import {
	agentDirFieldOverridden,
	agentProfileActivationState,
	spawnSessionsConfigPatch,
	subsessionsConfigPatch,
} from "./settingsSessiondConfig";

@customElement("settings-sessiond-panel")
export class SettingsSessiondPanel extends LitElement {
	@property({ attribute: false }) configResponse:
		| PiWebConfigResponse
		| undefined;
	@property({ type: Boolean }) loading = false;
	@property({ type: Boolean }) saving = false;
	@property() error = "";
	@property() savedMessage = "";
	@property() targetLabel = "local (local gateway)";
	@property({ attribute: false }) activeAgentProfile:
		| ActiveAgentProfileDescriptor
		| undefined;
	@property({ attribute: false })
	agentProfileSupport: AgentProfileSettingsSupport = { state: "supported" };
	@property({ attribute: false }) onReload?: () => void | Promise<void>;
	@property({ attribute: false }) onSave?: (
		config: PiWebConfigValues,
	) => void | Promise<void>;
	@state() private agentDraft: AgentProfileConfigDraft =
		emptyAgentProfileConfigDraft();
	@state() private agentDraftDirty = false;
	@state() private agentLocalError = "";
	private readonly locale = new LocaleController(this);

	protected override willUpdate(changed: PropertyValues<this>): void {
		if (!changed.has("configResponse")) return;
		if (this.configResponse === undefined) {
			this.agentDraft = emptyAgentProfileConfigDraft();
			this.agentDraftDirty = false;
			this.agentLocalError = "";
			return;
		}
		if (
			!this.agentDraftDirty ||
			agentProfileDraftMatchesConfig(
				this.agentDraft,
				this.configResponse.config,
			)
		) {
			this.agentDraft = agentProfileDraftFromConfig(this.configResponse.config);
			this.agentDraftDirty = false;
			this.agentLocalError = "";
		}
	}

	override render(): TemplateResult {
		const config = this.configResponse;
		const spawnOverridden = config?.envOverrides.spawnSessions === true;
		// On by default: the effective config is the source of truth for the toggle
		// state, so an unset config file still shows the feature as enabled.
		const effectiveSpawn = config?.effectiveConfig.spawnSessions !== false;
		const subsessionsOverridden = config?.envOverrides.subsessions === true;
		// Beta, off by default; also requires spawn to be enabled.
		const effectiveSubsessions =
			config?.effectiveConfig.subsessions === true && effectiveSpawn;
		const agentCommandOverridden = config?.envOverrides.agentCommand === true;
		const profileEditingSupported =
			this.agentProfileSupport.state === "supported";
		const draftCommand = agentCommandOverridden
			? (config.effectiveConfig.agent?.command ?? this.agentDraft.command)
			: this.agentDraft.command;
		const agentDirLocked = agentDirFieldOverridden(
			config?.envOverrides,
			draftCommand,
		);
		const effectiveAgentDirOverridden = config?.envOverrides.agentDir === true;
		const effectiveAgent = config?.effectiveConfig.agent;
		const profileActivation = agentProfileActivationState(
			config,
			this.activeAgentProfile,
		);
		void this.locale.locale;
		return html`
      <settings-panel-frame
        heading=${t("settings.sessiond.heading")}
        .description=${sessiondDescription(this.targetLabel)}
        actionLabel=${t("common.reload")}
        .actionDisabled=${this.loading}
        .notices=${this.panelNotices(config)}
        .onAction=${this.onReload}
      >
        ${
					config === undefined
						? this.renderUnavailableConfigState()
						: html`
          <div class="config-path-card">
            <span>${t("common.configFile")}</span>
            <code>${config.path}</code>
          </div>
          <form class="profile-form" aria-label=${t("settings.sessiond.heading")} @submit=${(
						event: Event,
					) => {
						void this.saveAgentProfile(event);
					}}>
            ${profileEditingSupported ? null : html`<div class="profile-support-message">${this.agentProfileSupport.message ?? t("settings.sessiond.profileUnsupported")}</div>`}
            <label class="field">
              <span class="field-heading">
                <span>${t("settings.sessiond.cliCommand")}</span>
                ${agentCommandOverridden ? html`<span class="override-badge">${t("common.envOverride")}</span>` : null}
              </span>
              <input
                class="text-input"
                type="text"
                autocomplete="off"
                spellcheck="false"
                .value=${this.agentDraft.command}
                placeholder="pi"
                ?disabled=${this.loading || this.saving || !profileEditingSupported || agentCommandOverridden}
                @input=${(event: Event) => {
									this.updateAgentDraft({ command: inputValue(event) });
								}}
              >
              <small>${t("settings.sessiond.cliHint")}</small>
            </label>
            <label class="field">
              <span class="field-heading">
                <span>${t("settings.sessiond.profileDir")}</span>
                ${effectiveAgentDirOverridden ? html`<span class="override-badge">${t("common.envOverride")}</span>` : null}
              </span>
              <input
                class="text-input"
                type="text"
                autocomplete="off"
                spellcheck="false"
                .value=${this.agentDraft.dir}
                placeholder="~/.pi/agent or ~/agent-profiles/work"
                ?disabled=${this.loading || this.saving || !profileEditingSupported || agentDirLocked}
                @input=${(event: Event) => {
									this.updateAgentDraft({ dir: inputValue(event) });
								}}
              >
              <small>${t("settings.sessiond.profileDirHint")}</small>
            </label>
            <footer class="form-actions">
              <button class="primary" type="submit" ?disabled=${this.loading || this.saving || !profileEditingSupported || (agentCommandOverridden && agentDirLocked)}>${this.saving ? t("common.saving") : t("settings.sessiond.saveProfile")}</button>
            </footer>
          </form>
          <div class="field">
            <span class="field-heading">
              <span>${t("settings.sessiond.spawnLabel")}</span>
              ${spawnOverridden ? html`<span class="override-badge">${t("common.envOverride")}</span>` : null}
            </span>
            <label class="toggle">
              <input
                type="checkbox"
                .checked=${effectiveSpawn}
                ?disabled=${this.loading || this.saving || spawnOverridden}
                @change=${(event: Event) => {
									void this.toggleSpawnSessions(event);
								}}
              >
              <span>${t("settings.sessiond.spawnToggle")}</span>
            </label>
            <small>${t("settings.sessiond.spawnHint")}</small>
          </div>
          <div class="field">
            <span class="field-heading">
              <span>${t("settings.sessiond.subsessionLabel")}</span>
              <span class="beta-badge">${t("common.beta")}</span>
              ${subsessionsOverridden ? html`<span class="override-badge">${t("common.envOverride")}</span>` : null}
            </span>
            <label class="toggle">
              <input
                type="checkbox"
                .checked=${effectiveSubsessions}
                ?disabled=${this.loading || this.saving || subsessionsOverridden || !effectiveSpawn}
                @change=${(event: Event) => {
									void this.toggleSubsessions(event);
								}}
              >
              <span>${t("settings.sessiond.subsessionToggle")}</span>
            </label>
            <small>${t("settings.sessiond.subsessionHint")}</small>
          </div>
          <section class="effective-card" aria-label=${t("settings.sessiond.effectiveHeading")}>
            <h3>${t("settings.sessiond.effectiveHeading")}</h3>
            <dl>
              <div><dt>${t("settings.sessiond.desiredCommand")}</dt><dd>${effectiveAgent?.command ?? html`<span class="muted">${t("common.unavailable")}</span>`}</dd></div>
              <div><dt>${t("settings.sessiond.desiredState")}</dt><dd>${effectiveAgent?.dir ?? html`<span class="muted">${t("common.unavailable")}</span>`}</dd></div>
              <div><dt>${t("settings.sessiond.activeCommand")}</dt><dd>${this.activeAgentProfile?.command ?? html`<span class="muted">${t("common.unavailable")}</span>`}</dd></div>
              <div><dt>${t("settings.sessiond.activeState")}</dt><dd>${this.activeAgentProfile?.dir ?? html`<span class="muted">${t("common.unavailable")}</span>`}</dd></div>
              <div><dt>${t("settings.sessiond.profileStatus")}</dt><dd>${profileActivationLabel(profileActivation)}</dd></div>
              <div><dt>${t("settings.sessiond.spawnSessions")}</dt><dd>${effectiveSpawn ? t("common.enabled") : html`<span class="muted">${t("common.disabled")}</span>`}</dd></div>
              <div><dt>${t("settings.sessiond.subsessions")}</dt><dd>${effectiveSubsessions ? t("common.enabled") : html`<span class="muted">${t("common.disabled")}</span>`}</dd></div>
            </dl>
          </section>
        `
				}
      </settings-panel-frame>
    `;
	}

	private panelNotices(
		config: PiWebConfigResponse | undefined,
	): readonly SettingsNotice[] {
		return sessiondPanelNotices(config, {
			error: this.agentLocalError || this.error,
			savedMessage: this.savedMessage,
			activeProfile: this.activeAgentProfile,
			targetLabel: this.targetLabel,
			profileEditingSupported: this.agentProfileSupport.state === "supported",
		});
	}

	private renderUnavailableConfigState(): TemplateResult {
		return html`<div class="loading-card">${this.loading ? t("settings.sessiond.loading") : t("settings.sessiond.unavailable")}</div>`;
	}

	private async saveAgentProfile(event: Event): Promise<void> {
		event.preventDefault();
		this.agentLocalError = "";
		try {
			await this.onSave?.(agentProfileConfigPatchFromDraft(this.agentDraft));
		} catch (error) {
			this.agentLocalError = errorMessage(error);
		}
	}

	private updateAgentDraft(patch: Partial<AgentProfileConfigDraft>): void {
		this.agentDraft = { ...this.agentDraft, ...patch };
		this.agentDraftDirty = true;
		this.agentLocalError = "";
	}

	private async toggleSpawnSessions(event: Event): Promise<void> {
		const enabled =
			event.target instanceof HTMLInputElement && event.target.checked;
		await this.onSave?.(spawnSessionsConfigPatch(enabled));
	}

	private async toggleSubsessions(event: Event): Promise<void> {
		const enabled =
			event.target instanceof HTMLInputElement && event.target.checked;
		await this.onSave?.(subsessionsConfigPatch(enabled));
	}

	static override styles = css`
    :host { display: block; }
    h3 { margin: 0; font-size: 13px; line-height: 1.3; }
    button, input { font: inherit; }
    button { border: 1px solid var(--pi-border); border-radius: 8px; background: var(--pi-surface); color: var(--pi-text); padding: 7px 9px; cursor: pointer; }
    button:disabled { opacity: .55; cursor: not-allowed; }
    .loading-card, .config-path-card, .effective-card, .profile-support-message { border: 1px solid var(--pi-border); border-radius: 10px; background: var(--pi-surface); padding: 12px; }
    .loading-card { color: var(--pi-muted); }
    .config-path-card { display: grid; gap: 5px; }
    .profile-form { display: grid; gap: 14px; }
    .profile-support-message { color: var(--pi-muted); line-height: 1.45; }
    .form-actions { display: flex; justify-content: flex-end; }
    .primary { border-color: var(--pi-accent); background: var(--pi-accent); color: var(--pi-accent-contrast); }
    .config-path-card span, .field-heading, dt { color: var(--pi-muted); font-size: 12px; font-weight: 700; text-transform: uppercase; }
    code { border: 1px solid var(--pi-border-muted); border-radius: 5px; background: var(--pi-bg); padding: 1px 4px; color: var(--pi-text); font: 12px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; overflow-wrap: anywhere; }
    .field { display: grid; gap: 7px; }
    .field small { color: var(--pi-muted); line-height: 1.45; }
    .field-heading { display: flex; align-items: center; gap: 8px; }
    .toggle { display: flex; align-items: center; gap: 9px; cursor: pointer; }
    .toggle input { width: 16px; height: 16px; }
    .text-input {
      width: 100%;
      min-width: 0;
      box-sizing: border-box;
      border: 1px solid var(--pi-border);
      border-radius: 8px;
      background: var(--pi-bg);
      color: var(--pi-text);
      padding: 8px 9px;
      outline: none;
      font: var(--pi-control-font-size, 16px) var(--pi-control-monospace-font-family, ui-monospace, SFMono-Regular, Menlo, Consolas, monospace);
    }
    .text-input:focus { border-color: var(--pi-accent); box-shadow: 0 0 0 1px var(--pi-accent-border); }
    .text-input:disabled { opacity: .55; cursor: not-allowed; }
    .toggle input:disabled { cursor: not-allowed; }
    .override-badge { border: 1px solid var(--pi-warning-border); border-radius: 999px; color: var(--pi-warning); background: var(--pi-warning-surface); padding: 2px 7px; font-size: 11px; font-weight: 600; text-transform: none; }
    .beta-badge { border: 1px solid var(--pi-border); border-radius: 999px; color: var(--pi-muted); background: var(--pi-bg); padding: 2px 7px; font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: .04em; }
    .effective-card { display: grid; gap: 10px; }
    .effective-card dl { display: grid; gap: 8px; margin: 0; }
    .effective-card dl > div { display: grid; grid-template-columns: 130px minmax(0, 1fr); gap: 12px; align-items: baseline; }
    dd { margin: 0; min-width: 0; overflow-wrap: anywhere; }
    .muted { color: var(--pi-muted); }

    @media (max-width: 760px) {
      .effective-card dl > div { grid-template-columns: minmax(0, 1fr); gap: 3px; }
    }
  `;
}

function profileActivationLabel(
	state: ReturnType<typeof agentProfileActivationState>,
): string | TemplateResult {
	if (state === "active") return t("settings.sessiond.profileActive");
	if (state === "restart-required")
		return t("settings.sessiond.restartRequired");
	return html`<span class="muted">${t("common.unavailable")}</span>`;
}

function inputValue(event: Event): string {
	return event.target instanceof HTMLInputElement ? event.target.value : "";
}

function errorMessage(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}

export function sessiondDescription(targetLabel: string): string {
	return t("settings.sessiond.description", { target: targetLabel });
}

export interface SessiondPanelNoticeContext {
	readonly error: string;
	readonly savedMessage: string;
	readonly activeProfile: ActiveAgentProfileDescriptor | undefined;
	readonly targetLabel: string;
	readonly profileEditingSupported: boolean;
}

/**
 * Compute the session-daemon panel's notice stack (error, saved, and
 * profile-activation guidance) as a pure, publicly testable seam so tests assert
 * the dynamic notice logic and ordering here instead of scraping rendered
 * `TemplateResult` internals.
 */
export function sessiondPanelNotices(
	config: PiWebConfigResponse | undefined,
	context: SessiondPanelNoticeContext,
): readonly SettingsNotice[] {
	const notices: SettingsNotice[] = [];
	if (context.error !== "")
		notices.push({ type: "error", content: context.error });
	if (context.savedMessage !== "")
		notices.push({ type: "success", content: context.savedMessage });
	const activation = agentProfileActivationState(config, context.activeProfile);
	if (activation === "restart-required") {
		notices.push({
			type: "warning",
			title: t("settings.sessiond.restartTitle", {
				target: context.targetLabel,
			}),
			content: t("settings.sessiond.restartBody"),
		});
	} else if (
		config !== undefined &&
		activation === "unavailable" &&
		context.profileEditingSupported
	) {
		notices.push({
			type: "info",
			title: t("settings.sessiond.activeUnavailableTitle", {
				target: context.targetLabel,
			}),
			content: t("settings.sessiond.activeUnavailableBody"),
		});
	}
	return notices;
}
