import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { registerPiWebCommand } from "./piWebLaunch.js";

/**
 * OMP entry point (`omp install …` via the package.json "omp" manifest).
 * Same `/pi-web` slash command as the Pi extension, but sessions default to
 * the OMP runtime.
 */
export default function ompWebExtension(pi: ExtensionAPI): void {
	registerPiWebCommand(pi, "omp");
}
