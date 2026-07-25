import { existsSync } from "node:fs";
import { join } from "node:path";

/**
 * True when `dir` looks like a Vite *build* output suitable for `@fastify/static`.
 *
 * The checkout's `src/client` also has an `index.html`, but it is the Vite source
 * root (`%BASE_URL%` placeholders + `/src/main.ts`). Serving that from the API
 * port makes the browser load raw TypeScript and show a blank white page.
 */
export function isBuiltClientDist(dir: string): boolean {
	return (
		existsSync(join(dir, "index.html")) &&
		!existsSync(join(dir, "src", "main.ts"))
	);
}

/**
 * Resolve the static client directory for the web server.
 *
 * Prefer an explicit override, then the packaged sibling of the server bundle
 * (`dist/client` next to `dist/server`), then a cwd-relative build output.
 */
export function resolveClientDist(options: {
	override?: string | false | undefined;
	packagedCandidate: string;
	cwdCandidate?: string | undefined;
}): string | false {
	if (options.override !== undefined) return options.override;
	if (isBuiltClientDist(options.packagedCandidate))
		return options.packagedCandidate;
	const cwdCandidate = options.cwdCandidate;
	if (cwdCandidate !== undefined && isBuiltClientDist(cwdCandidate))
		return cwdCandidate;
	return false;
}
