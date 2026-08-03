import { createReadStream } from "node:fs";
import { readdir, stat } from "node:fs/promises";
import { resolve } from "node:path";
import { createInterface } from "node:readline";
import { AGENT_RUNTIME_IDS } from "../../../shared/agentRuntime.js";
import type { SessionInfo } from "../../../shared/apiTypes.js";

interface SessionHeader {
	id: string;
	cwd: string;
	timestamp: string;
}

interface TitleHeader {
	title?: string;
	updatedAt?: string;
}

export async function listOmpSessionFiles(
	sessionDir: string,
	cwd: string,
): Promise<SessionInfo[]> {
	const files = await findJsonlFiles(sessionDir);
	const sessions = await Promise.all(
		files.map((file) => readOmpSessionSummary(file)),
	);
	const canonicalCwd = resolve(cwd);
	return sessions
		.filter(
			(session): session is SessionInfo =>
				session !== undefined && resolve(session.cwd) === canonicalCwd,
		)
		.sort(
			(left, right) => Date.parse(right.modified) - Date.parse(left.modified),
		);
}

export async function readOmpSessionSummary(
	path: string,
): Promise<SessionInfo | undefined> {
	let title: TitleHeader | undefined;
	let header: SessionHeader | undefined;
	let messageCount = 0;
	let firstMessage = "";

	try {
		const lines = createInterface({
			input: createReadStream(path, { encoding: "utf8" }),
			crlfDelay: Infinity,
		});
		for await (const line of lines) {
			if (line === "") continue;
			const entry = parseJsonRecord(line);
			if (entry === undefined) return undefined;
			if (entry["type"] === "title" && title === undefined) {
				title = {
					...(typeof entry["title"] === "string" && entry["title"] !== ""
						? { title: entry["title"] }
						: {}),
					...(typeof entry["updatedAt"] === "string"
						? { updatedAt: entry["updatedAt"] }
						: {}),
				};
				continue;
			}
			if (entry["type"] === "session" && header === undefined) {
				const id = entry["id"];
				const cwd = entry["cwd"];
				const timestamp = entry["timestamp"];
				if (
					typeof id !== "string" ||
					typeof cwd !== "string" ||
					typeof timestamp !== "string"
				)
					return undefined;
				header = { id, cwd, timestamp };
				continue;
			}
			if (entry["type"] !== "message") continue;
			messageCount += 1;
			if (firstMessage === "") firstMessage = userMessageText(entry["message"]);
		}
	} catch {
		return undefined;
	}

	if (header === undefined) return undefined;
	const fileStat = await stat(path).catch(() => undefined);
	const modified =
		validIsoDate(title?.updatedAt) ??
		fileStat?.mtime.toISOString() ??
		header.timestamp;
	return {
		id: header.id,
		path,
		cwd: header.cwd,
		runtimeId: AGENT_RUNTIME_IDS.omp,
		persisted: true,
		...(title?.title === undefined ? {} : { name: title.title }),
		created: validIsoDate(header.timestamp) ?? header.timestamp,
		modified,
		messageCount,
		firstMessage,
	};
}

async function findJsonlFiles(root: string): Promise<string[]> {
	const entries = await readdir(root, { withFileTypes: true }).catch(() => []);
	const nested = await Promise.all(
		entries.map(async (entry): Promise<string[]> => {
			const path = `${root}/${entry.name}`;
			if (entry.isDirectory()) return findJsonlFiles(path);
			return entry.isFile() && entry.name.endsWith(".jsonl") ? [path] : [];
		}),
	);
	return nested.flat();
}

function userMessageText(value: unknown): string {
	if (!isRecord(value) || value["role"] !== "user") return "";
	const content = value["content"];
	if (typeof content === "string") return content.trim();
	if (!Array.isArray(content)) return "";
	return content
		.filter(isRecord)
		.filter(
			(part) => part["type"] === "text" && typeof part["text"] === "string",
		)
		.map((part) => part["text"])
		.join("\n")
		.trim();
}

function validIsoDate(value: string | undefined): string | undefined {
	if (value === undefined || !Number.isFinite(Date.parse(value)))
		return undefined;
	return new Date(value).toISOString();
}

function parseJsonRecord(text: string): Record<string, unknown> | undefined {
	let value: unknown;
	try {
		value = JSON.parse(text);
	} catch {
		return undefined;
	}
	return isRecord(value) ? value : undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}
