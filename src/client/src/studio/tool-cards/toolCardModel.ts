import type { ToolExecutionPart } from "../../components/shared";

/**
 * Standardized display model for tool calls. Adapts the wire-level
 * ToolExecutionPart into everything a tool card needs to render, so UI
 * components never parse tool args/details themselves.
 */

export type ToolCardStatus =
	| "pending"
	| "running"
	| "success"
	| "failed"
	| "cancelled"
	| "approval-required";

export type ToolCardKind =
	| "read"
	| "bash"
	| "edit"
	| "write"
	| "search"
	| "generic";

export interface ToolCardDiff {
	additions: number;
	deletions: number;
	content: string;
	/** True when the diff is the pre-apply preview rather than the applied diff. */
	isPreview: boolean;
}

export interface ToolCardViewModel {
	id: string;
	toolName: string;
	kind: ToolCardKind;
	/** Past-tense verb for the collapsed line, e.g. "Read", "Ran", "Edited". */
	verb: string;
	/** Full one-line summary for the collapsed row, e.g. "Read src/app.ts". */
	title: string;
	status: ToolCardStatus;
	filePath?: string;
	command?: string;
	query?: string;
	resultText?: string;
	error?: string;
	/** Pretty-printed raw payload for error inspection. */
	rawDetails?: string;
	diff?: ToolCardDiff;
	/** e.g. "3 edits" for multi-edit calls. */
	editCountLabel?: string;
	startedAt?: number;
	endedAt?: number;
	duration?: number;
}

const SEARCH_TOOLS = new Set([
	"grep",
	"find",
	"ls",
	"search",
	"glob",
	"ast_grep_search",
]);

export function toolCardViewModel(
	execution: ToolExecutionPart,
): ToolCardViewModel {
	const toolName = execution.toolName;
	const kind = toolCardKind(toolName);
	const status = toolCardStatus(execution.status);
	const filePath = pathFromArgs(execution.args);
	const command = getString(execution.args, "command");
	const query =
		getString(execution.args, "pattern") ?? getString(execution.args, "query");
	const diff = toolCardDiff(execution);
	const error =
		status === "failed"
			? firstNonEmpty(execution.resultText, execution.preview?.error)
			: undefined;
	const edits = editCountLabel(execution);

	return {
		id: execution.toolCallId ?? "",
		toolName,
		kind,
		verb: toolCardVerb(kind, status),
		title: toolCardTitle(execution, kind, status, filePath, command, query),
		status,
		...(filePath === undefined ? {} : { filePath }),
		...(command === undefined ? {} : { command }),
		...(query === undefined ? {} : { query }),
		...(execution.resultText === undefined
			? {}
			: { resultText: execution.resultText }),
		...(error === undefined ? {} : { error }),
		...(status === "failed" ? rawDetailsOf(execution) : {}),
		...(diff === undefined ? {} : { diff }),
		...(edits === undefined ? {} : { editCountLabel: edits }),
	};
}

export function toolCardKind(toolName: string): ToolCardKind {
	const normalized = toolName.toLowerCase();
	if (normalized === "read") return "read";
	if (normalized === "bash") return "bash";
	if (normalized === "edit") return "edit";
	if (normalized === "write") return "write";
	if (SEARCH_TOOLS.has(normalized)) return "search";
	return "generic";
}

export function toolCardStatus(
	status: ToolExecutionPart["status"],
): ToolCardStatus {
	if (status === "error") return "failed";
	return status;
}

function toolCardVerb(kind: ToolCardKind, status: ToolCardStatus): string {
	const done = status === "success" || status === "failed";
	switch (kind) {
		case "read":
			return done ? "Read" : "Reading";
		case "bash":
			return done ? "Ran" : "Running";
		case "edit":
			return done ? "Edited" : "Editing";
		case "write":
			return done ? "Wrote" : "Writing";
		case "search":
			return done ? "Searched" : "Searching";
		case "generic":
			return done ? "Used" : "Using";
	}
}

function toolCardTitle(
	execution: ToolExecutionPart,
	kind: ToolCardKind,
	status: ToolCardStatus,
	filePath: string | undefined,
	command: string | undefined,
	query: string | undefined,
): string {
	const verb = toolCardVerb(kind, status);
	if (kind === "bash" && command !== undefined && command !== "")
		return `${verb} ${firstLine(command)}`;
	if (
		(kind === "read" || kind === "edit" || kind === "write") &&
		filePath !== undefined &&
		filePath !== ""
	)
		return `${verb} ${filePath}`;
	if (kind === "search" && query !== undefined && query !== "")
		return `${verb} for “${query}”`;
	if (execution.summary !== "") return `${verb} ${execution.summary}`;
	return `${verb} ${execution.toolName}`;
}

export function toolCardDiff(
	execution: ToolExecutionPart,
): ToolCardDiff | undefined {
	const applied = getString(execution.details, "diff");
	const preview = execution.preview?.diff;
	const content = applied ?? preview;
	if (content === undefined || content === "") return undefined;
	const { added, removed } = countDiffLines(content);
	return {
		additions: added,
		deletions: removed,
		content,
		isPreview: applied === undefined,
	};
}

function countDiffLines(diff: string): { added: number; removed: number } {
	let added = 0;
	let removed = 0;
	for (const line of diff.split("\n")) {
		if (line.startsWith("+") && !line.startsWith("+++")) added++;
		else if (line.startsWith("-") && !line.startsWith("---")) removed++;
	}
	return { added, removed };
}

function editCountLabel(execution: ToolExecutionPart): string | undefined {
	if (execution.toolName.toLowerCase() !== "edit") return undefined;
	const edits = getProperty(execution.args, "edits");
	if (Array.isArray(edits))
		return `${String(edits.length)} edit${edits.length === 1 ? "" : "s"}`;
	if (
		typeof getProperty(execution.args, "oldText") === "string" &&
		typeof getProperty(execution.args, "newText") === "string"
	)
		return "1 edit";
	return undefined;
}

function rawDetailsOf(
	execution: ToolExecutionPart,
): { rawDetails: string } | undefined {
	const source = execution.details ?? execution.content;
	if (source === undefined || source === null) return undefined;
	if (typeof source === "string")
		return source === "" ? undefined : { rawDetails: source };
	try {
		return { rawDetails: JSON.stringify(source, null, 2) };
	} catch {
		return undefined;
	}
}

function pathFromArgs(args: unknown): string | undefined {
	return getString(args, "path") ?? getString(args, "file_path");
}

function firstLine(text: string): string {
	const line = text.split("\n", 1)[0] ?? text;
	return line;
}

function firstNonEmpty(...values: (string | undefined)[]): string | undefined {
	for (const value of values) {
		if (value !== undefined && value.trim() !== "") return value;
	}
	return undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null;
}

function getProperty(value: unknown, key: string): unknown {
	return isRecord(value) ? value[key] : undefined;
}

function getString(value: unknown, key: string): string | undefined {
	const property = getProperty(value, key);
	return typeof property === "string" ? property : undefined;
}
