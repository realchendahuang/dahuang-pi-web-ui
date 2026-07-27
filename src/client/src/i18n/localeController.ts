import type { ReactiveController, ReactiveControllerHost } from "lit";
import { getLocale, subscribeLocale, type AppLocale } from "./locale";

/** Requests a host update whenever the active UI locale changes. */
export class LocaleController implements ReactiveController {
	private unsubscribe: (() => void) | undefined;

	constructor(private readonly host: ReactiveControllerHost) {
		this.host.addController(this);
	}

	get locale(): AppLocale {
		return getLocale();
	}

	hostConnected(): void {
		this.unsubscribe = subscribeLocale(() => {
			this.host.requestUpdate();
		});
	}

	hostDisconnected(): void {
		this.unsubscribe?.();
		this.unsubscribe = undefined;
	}
}
