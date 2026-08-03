import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { registerPiWebCommand } from "./piWebLaunch.js";

/**
 * Package install is `pi install …`.
 * The only slash command is `/pi-web` — bring the Web UI up and open it.
 * Launched from a Pi terminal, sessions default to the Pi runtime.
 */
export default function piWebExtension(pi: ExtensionAPI): void {
	registerPiWebCommand(pi, "pi");
}
