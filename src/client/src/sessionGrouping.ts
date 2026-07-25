/**
 * Time-based grouping and relative-time labels for the session list.
 * Pure functions so grouping behavior can be unit-tested without rendering.
 */

export type SessionTimeGroupId = "today" | "yesterday" | "week" | "older";

export interface SessionTimeGroup<T> {
  id: SessionTimeGroupId;
  label: string;
  items: T[];
}

const GROUP_ORDER: readonly { id: SessionTimeGroupId; label: string }[] = [
  { id: "today", label: "Today" },
  { id: "yesterday", label: "Yesterday" },
  { id: "week", label: "Previous 7 days" },
  { id: "older", label: "Older" },
];

function startOfDay(date: Date): Date {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate());
}

/** Classify an ISO timestamp into a recency bucket relative to `now`. */
export function sessionTimeGroupId(isoDate: string, now: Date = new Date()): SessionTimeGroupId {
  const time = Date.parse(isoDate);
  if (!Number.isFinite(time)) return "older";
  const todayStart = startOfDay(now).getTime();
  const dayMs = 24 * 60 * 60 * 1000;
  if (time >= todayStart) return "today";
  if (time >= todayStart - dayMs) return "yesterday";
  if (time >= todayStart - 7 * dayMs) return "week";
  return "older";
}

/**
 * Group items (already in display order) into recency buckets. Order within a
 * bucket is preserved; empty buckets are omitted.
 */
export function groupBySessionTime<T>(items: readonly T[], modifiedOf: (item: T) => string, now: Date = new Date()): SessionTimeGroup<T>[] {
  const buckets = new Map<SessionTimeGroupId, T[]>();
  for (const item of items) {
    const id = sessionTimeGroupId(modifiedOf(item), now);
    const bucket = buckets.get(id) ?? [];
    bucket.push(item);
    buckets.set(id, bucket);
  }
  const groups: SessionTimeGroup<T>[] = [];
  for (const { id, label } of GROUP_ORDER) {
    const bucket = buckets.get(id);
    if (bucket !== undefined && bucket.length > 0) groups.push({ id, label, items: bucket });
  }
  return groups;
}

/**
 * Compact timestamp for session rows: clock time today, "Yesterday", weekday
 * within the last 7 days, "Mar 12" this year, "2024-03-12" for earlier years.
 */
export function formatRelativeTime(isoDate: string, now: Date = new Date()): string {
  const time = Date.parse(isoDate);
  if (!Number.isFinite(time)) return "";
  const date = new Date(time);
  const group = sessionTimeGroupId(isoDate, now);
  if (group === "today") {
    return date.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
  }
  if (group === "yesterday") return "Yesterday";
  if (group === "week") {
    return date.toLocaleDateString(undefined, { weekday: "short" });
  }
  if (date.getFullYear() === now.getFullYear()) {
    return date.toLocaleDateString(undefined, { month: "short", day: "numeric" });
  }
  return date.toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
}

/** Case-insensitive substring match for session list search. */
export function sessionMatchesQuery(query: string, ...fields: (string | undefined)[]): boolean {
  const needle = query.trim().toLowerCase();
  if (needle === "") return true;
  return fields.some((field) => field?.toLowerCase().includes(needle) === true);
}

/**
 * Group flattened session tree rows (depth-first) into recency buckets. Child
 * rows inherit the bucket of their nearest depth-0 ancestor so a session tree
 * is never split across groups.
 */
export function groupSessionRowsByTime<T extends { depth: number }>(rows: readonly T[], modifiedOf: (row: T) => string, now: Date = new Date()): SessionTimeGroup<T>[] {
  let rootModified = "";
  const effective = rows.map((row) => {
    if (row.depth === 0) rootModified = modifiedOf(row);
    return { row, effectiveModified: row.depth === 0 ? modifiedOf(row) : rootModified };
  });
  return groupBySessionTime(effective, (entry) => entry.effectiveModified, now).map((group) => ({
    ...group,
    items: group.items.map((entry) => entry.row),
  }));
}
