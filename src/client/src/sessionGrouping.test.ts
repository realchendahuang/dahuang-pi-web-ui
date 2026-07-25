import { describe, expect, it } from "vitest";
import { formatRelativeTime, groupBySessionTime, groupSessionRowsByTime, sessionMatchesQuery, sessionTimeGroupId } from "./sessionGrouping";

const NOW = new Date(2026, 6, 25, 15, 30, 0); // 2026-07-25 15:30 local time

function iso(date: Date): string {
  return date.toISOString();
}

describe("sessionTimeGroupId", () => {
  it("groups timestamps into recency buckets", () => {
    expect(sessionTimeGroupId(iso(new Date(2026, 6, 25, 9, 0, 0)), NOW)).toBe("today");
    expect(sessionTimeGroupId(iso(new Date(2026, 6, 25, 0, 0, 0)), NOW)).toBe("today");
    expect(sessionTimeGroupId(iso(new Date(2026, 6, 24, 23, 59, 0)), NOW)).toBe("yesterday");
    expect(sessionTimeGroupId(iso(new Date(2026, 6, 20, 12, 0, 0)), NOW)).toBe("week");
    expect(sessionTimeGroupId(iso(new Date(2026, 6, 18, 12, 0, 0)), NOW)).toBe("week");
    expect(sessionTimeGroupId(iso(new Date(2026, 6, 17, 12, 0, 0)), NOW)).toBe("older");
    expect(sessionTimeGroupId(iso(new Date(2025, 0, 1, 12, 0, 0)), NOW)).toBe("older");
  });

  it("treats unparseable timestamps as older", () => {
    expect(sessionTimeGroupId("not-a-date", NOW)).toBe("older");
  });
});

describe("groupBySessionTime", () => {
  it("buckets items in order and omits empty groups", () => {
    const items = [
      { id: "a", modified: iso(new Date(2026, 6, 25, 10, 0, 0)) },
      { id: "b", modified: iso(new Date(2026, 6, 25, 8, 0, 0)) },
      { id: "c", modified: iso(new Date(2026, 6, 24, 10, 0, 0)) },
      { id: "d", modified: iso(new Date(2026, 5, 1, 10, 0, 0)) },
    ];

    const groups = groupBySessionTime(items, (item) => item.modified, NOW);

    expect(groups.map((group) => group.id)).toEqual(["today", "yesterday", "older"]);
    expect(groups[0]?.items.map((item) => item.id)).toEqual(["a", "b"]);
    expect(groups[1]?.items.map((item) => item.id)).toEqual(["c"]);
    expect(groups[2]?.items.map((item) => item.id)).toEqual(["d"]);
    expect(groups[0]?.label).toBe("Today");
    expect(groups[1]?.label).toBe("Yesterday");
    expect(groups[2]?.label).toBe("Older");
  });

  it("returns no groups for empty input", () => {
    expect(groupBySessionTime([], (item: string) => item, NOW)).toEqual([]);
  });
});

describe("formatRelativeTime", () => {
  it("renders a clock time for today", () => {
    const label = formatRelativeTime(iso(new Date(2026, 6, 25, 14, 5, 0)), NOW);
    expect(label).toMatch(/2:05/);
  });

  it("renders bucket labels for recent days", () => {
    expect(formatRelativeTime(iso(new Date(2026, 6, 24, 10, 0, 0)), NOW)).toBe("Yesterday");
    expect(formatRelativeTime(iso(new Date(2026, 6, 21, 10, 0, 0)), NOW)).toMatch(/Tue/);
  });

  it("renders a short date for older items in the same year", () => {
    expect(formatRelativeTime(iso(new Date(2026, 2, 12, 10, 0, 0)), NOW)).toMatch(/Mar 12/);
  });

  it("includes the year for earlier years", () => {
    expect(formatRelativeTime(iso(new Date(2024, 2, 12, 10, 0, 0)), NOW)).toMatch(/2024/);
  });

  it("returns an empty label for unparseable timestamps", () => {
    expect(formatRelativeTime("nope", NOW)).toBe("");
  });
});

describe("groupSessionRowsByTime", () => {
  it("keeps tree children in their root session's group", () => {
    const rows = [
      { depth: 0, modified: iso(new Date(2026, 6, 25, 10, 0, 0)), id: "root-today" },
      { depth: 1, modified: iso(new Date(2026, 0, 1, 10, 0, 0)), id: "child-old" },
      { depth: 0, modified: iso(new Date(2026, 6, 1, 10, 0, 0)), id: "root-older" },
    ];

    const groups = groupSessionRowsByTime(rows, (row) => row.modified, NOW);

    expect(groups.map((group) => group.id)).toEqual(["today", "older"]);
    expect(groups[0]?.items.map((row) => row.id)).toEqual(["root-today", "child-old"]);
    expect(groups[1]?.items.map((row) => row.id)).toEqual(["root-older"]);
  });
});

describe("sessionMatchesQuery", () => {
  it("matches case-insensitively against any field", () => {
    expect(sessionMatchesQuery("chat", "Fix chat layout", "other")).toBe(true);
    expect(sessionMatchesQuery("CHAT", "fix chat layout")).toBe(true);
    expect(sessionMatchesQuery("missing", "fix chat layout")).toBe(false);
  });

  it("matches everything for a blank query", () => {
    expect(sessionMatchesQuery("  ", "anything")).toBe(true);
    expect(sessionMatchesQuery("", undefined)).toBe(true);
  });

  it("skips undefined fields", () => {
    expect(sessionMatchesQuery("x", undefined, undefined)).toBe(false);
  });
});
