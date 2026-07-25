import { html, type TemplateResult } from "lit";
import { renderBuiltinTabIcon } from "../../components/tabIcons";
import "../../components/WorkspaceFilesPanel";
import "../../components/WorkspaceGitPanel";
import "../../components/WorkspaceChangesPanel";
import "../../components/WorkspaceContextPanel";
import type {
	WorkspacePanelContribution,
	WorkspacePanelContext,
} from "../types";

export function createCoreWorkspacePanels(): WorkspacePanelContribution[] {
	return [
		{
			id: "workspace.changes",
			title: "Changes",
			icon: renderBuiltinTabIcon("changes"),
			order: 5,
			visible: ({ workspace }) => workspace.isGitRepo,
			badge: (context) => {
				const count = context.gitStatus?.files.length ?? 0;
				return count > 0 ? count : undefined;
			},
			render: renderChanges,
		},
		{
			id: "workspace.files",
			title: "Files",
			icon: renderBuiltinTabIcon("files"),
			order: 10,
			render: renderFiles,
		},
		{
			id: "workspace.git",
			title: "Git",
			icon: renderBuiltinTabIcon("git"),
			order: 20,
			visible: ({ workspace }) => workspace.isGitRepo,
			render: renderGit,
		},
		{
			id: "workspace.terminal",
			title: "Terminal",
			icon: renderBuiltinTabIcon("terminal"),
			order: 30,
			badge: (context) =>
				context.activeTerminalCount > 0
					? context.activeTerminalCount
					: undefined,
			render: renderTerminal,
		},
		{
			id: "workspace.context",
			title: "Context",
			icon: renderBuiltinTabIcon("context"),
			order: 40,
			render: renderContext,
		},
	];
}

function renderChanges(context: WorkspacePanelContext): TemplateResult {
	return html`<workspace-changes-panel .context=${context}></workspace-changes-panel>`;
}

function renderContext(context: WorkspacePanelContext): TemplateResult {
	return html`<workspace-context-panel .context=${context}></workspace-context-panel>`;
}

function renderFiles(context: WorkspacePanelContext): TemplateResult {
	return html`<workspace-files-panel .context=${context}></workspace-files-panel>`;
}

function renderTerminal(context: WorkspacePanelContext): TemplateResult {
	loadTerminalPanel();
	return html`<terminal-panel .workspace=${context.workspace} .machineId=${context.machine.id} .selectedTerminalId=${context.selectedTerminalId} .autoStart=${context.terminalAutoStart} .onSelectTerminal=${context.onSelectTerminal}></terminal-panel>`;
}

function renderGit(context: WorkspacePanelContext): TemplateResult {
	return html`<workspace-git-panel .context=${context}></workspace-git-panel>`;
}

function loadTerminalPanel(): void {
	void import("../../components/TerminalPanel");
}
