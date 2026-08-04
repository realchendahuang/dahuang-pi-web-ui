import { randomUUID } from "node:crypto";
import type { ExtensionUIDialogOptions } from "@earendil-works/pi-coding-agent";

export const EXTENSION_INTERACTION_KINDS = [
	"select",
	"confirm",
	"input",
	"editor",
] as const;

export type ExtensionInteractionKind =
	(typeof EXTENSION_INTERACTION_KINDS)[number];

/**
 * Stable product projection of a Pi extension dialog. The Node Runtime keeps
 * the resolver and extension implementation private; native clients can only
 * render this data and submit a kind-compatible response.
 */
export interface ExtensionInteraction {
	id: string;
	sessionId: string;
	cwd: string;
	kind: ExtensionInteractionKind;
	title: string;
	message?: string;
	options?: string[];
	placeholder?: string;
	prefill?: string;
	createdAt: string;
	timeoutAt?: string;
}

export type ExtensionInteractionResponse =
	| { cancelled: true }
	| { selected: string }
	| { confirmed: boolean }
	| { text: string };

interface PendingInteraction {
	projection: ExtensionInteraction;
	resolve: (response: ExtensionInteractionResponse) => void;
	timer?: NodeJS.Timeout;
	signal?: AbortSignal;
	onAbort?: () => void;
}

export interface ExtensionInteractionServiceOptions {
	now?: () => Date;
	onOpened?: (interaction: ExtensionInteraction) => void;
	onClosed?: (interaction: ExtensionInteraction, reason: string) => void;
}

/** Error translated by routes without exposing an extension callback. */
export class ExtensionInteractionNotFoundError extends Error {}

/** Error for a response shape incompatible with the pending dialog kind. */
export class ExtensionInteractionResponseError extends Error {}

/**
 * Daemon-lifetime ownership for extension dialogs. Pending callbacks are never
 * serialized or given to the native shell. They are cleaned up on SDK abort,
 * timeout, session replacement, and daemon shutdown.
 */
export class ExtensionInteractionService {
	private readonly pending = new Map<string, PendingInteraction>();
	private readonly now: () => Date;
	private readonly onOpened: (interaction: ExtensionInteraction) => void;
	private readonly onClosed: (
		interaction: ExtensionInteraction,
		reason: string,
	) => void;

	constructor(options: ExtensionInteractionServiceOptions = {}) {
		this.now = options.now ?? (() => new Date());
		this.onOpened = options.onOpened ?? (() => undefined);
		this.onClosed = options.onClosed ?? (() => undefined);
	}

	list(sessionId: string, cwd: string): ExtensionInteraction[] {
		return [...this.pending.values()]
			.map(({ projection }) => projection)
			.filter(
				(interaction) =>
					interaction.sessionId === sessionId && interaction.cwd === cwd,
			)
			.sort((left, right) => left.createdAt.localeCompare(right.createdAt));
	}

	select(
		sessionId: string,
		cwd: string,
		title: string,
		options: string[],
		dialogOptions?: ExtensionUIDialogOptions,
	): Promise<string | undefined> {
		return this.open(
			{ sessionId, cwd, kind: "select", title, options },
			dialogOptions,
		).then((response) => ("selected" in response ? response.selected : undefined));
	}

	confirm(
		sessionId: string,
		cwd: string,
		title: string,
		message: string,
		dialogOptions?: ExtensionUIDialogOptions,
	): Promise<boolean> {
		return this.open(
			{ sessionId, cwd, kind: "confirm", title, message },
			dialogOptions,
		).then((response) => ("confirmed" in response ? response.confirmed : false));
	}

	input(
		sessionId: string,
		cwd: string,
		title: string,
		placeholder: string | undefined,
		dialogOptions?: ExtensionUIDialogOptions,
	): Promise<string | undefined> {
		return this.open(
			{
				sessionId,
				cwd,
				kind: "input",
				title,
				...(placeholder === undefined ? {} : { placeholder }),
			},
			dialogOptions,
		).then((response) => ("text" in response ? response.text : undefined));
	}

	editor(
		sessionId: string,
		cwd: string,
		title: string,
		prefill: string | undefined,
	): Promise<string | undefined> {
		return this.open({
			sessionId,
			cwd,
			kind: "editor",
			title,
			...(prefill === undefined ? {} : { prefill }),
		}).then(
			(response) => ("text" in response ? response.text : undefined),
		);
	}

	respond(
		interactionId: string,
		response: ExtensionInteractionResponse,
	): ExtensionInteraction {
		const pending = this.pending.get(interactionId);
		if (pending === undefined)
			throw new ExtensionInteractionNotFoundError("Extension interaction not found");
		validateResponse(pending.projection, response);
		this.settle(interactionId, response, "responded");
		return pending.projection;
	}

	cancelSession(sessionId: string, reason: string): void {
		for (const [id, pending] of this.pending) {
			if (pending.projection.sessionId === sessionId)
				this.settle(id, { cancelled: true }, reason);
		}
	}

	dispose(): void {
		for (const id of this.pending.keys())
			this.settle(id, { cancelled: true }, "runtime-dispose");
	}

	private open(
		input: Omit<ExtensionInteraction, "id" | "createdAt" | "timeoutAt">,
		dialogOptions?: ExtensionUIDialogOptions,
	): Promise<ExtensionInteractionResponse> {
		const created = this.now();
		const timeout = validTimeout(dialogOptions?.timeout);
		const projection: ExtensionInteraction = {
			...input,
			id: randomUUID(),
			createdAt: created.toISOString(),
			...(timeout === undefined
				? {}
				: { timeoutAt: new Date(created.getTime() + timeout).toISOString() }),
		};
		return new Promise((resolve) => {
			const pending: PendingInteraction = { projection, resolve };
			if (timeout !== undefined) {
				pending.timer = setTimeout(
					() => {
						this.settle(projection.id, { cancelled: true }, "timeout");
					},
					timeout,
				);
			}
			if (dialogOptions?.signal !== undefined) {
				pending.signal = dialogOptions.signal;
				pending.onAbort = () => {
					this.settle(projection.id, { cancelled: true }, "aborted");
				};
				dialogOptions.signal.addEventListener("abort", pending.onAbort, {
					once: true,
				});
			}
			this.pending.set(projection.id, pending);
			this.onOpened(projection);
			if (dialogOptions?.signal?.aborted === true) pending.onAbort?.();
		});
	}

	private settle(
		interactionId: string,
		response: ExtensionInteractionResponse,
		reason: string,
	): void {
		const pending = this.pending.get(interactionId);
		if (pending === undefined) return;
		this.pending.delete(interactionId);
		if (pending.timer !== undefined) clearTimeout(pending.timer);
		if (pending.signal !== undefined && pending.onAbort !== undefined)
			pending.signal.removeEventListener("abort", pending.onAbort);
		pending.resolve(response);
		this.onClosed(pending.projection, reason);
	}
}

function validTimeout(value: number | undefined): number | undefined {
	return typeof value === "number" && Number.isFinite(value) && value > 0
		? Math.floor(value)
		: undefined;
}

function validateResponse(
	interaction: ExtensionInteraction,
	response: ExtensionInteractionResponse,
): void {
	if ("cancelled" in response) return;
	switch (interaction.kind) {
		case "select":
			if (
				"selected" in response &&
				interaction.options?.includes(response.selected) === true
			)
				return;
			break;
		case "confirm":
			if ("confirmed" in response) return;
			break;
		case "input":
		case "editor":
			if ("text" in response) return;
			break;
	}
	throw new ExtensionInteractionResponseError(
		`Response is incompatible with ${interaction.kind} extension interaction`,
	);
}
