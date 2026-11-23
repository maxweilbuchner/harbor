// Build-time facts, read from the two files a release already updates: the Sparkle feed
// (updates/appcast.xml) and CHANGELOG.md at the repository root. Nothing here is typed in
// twice, so the site cannot name a version the app doesn't have.
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const root = resolve(process.cwd(), "..");

export interface Release {
  version: string;
  date: string;
  items: string[];
}

export interface Download {
  version: string;
  url: string;
  megabytes: string;
}

/** The newest item of the Sparkle feed: the feed lists them newest first. */
export function latestDownload(): Download {
  const xml = readFileSync(resolve(root, "updates/appcast.xml"), "utf8");
  const item = xml.match(/<item>[\s\S]*?<\/item>/)?.[0];
  const version = item?.match(/<sparkle:shortVersionString>([^<]+)</)?.[1];
  const url = item?.match(/<enclosure[^>]*\burl="([^"]+)"/)?.[1];
  const length = item?.match(/<enclosure[^>]*\blength="(\d+)"/)?.[1];
  if (!version || !url || !length) throw new Error("updates/appcast.xml: no complete first item");
  return { version, url, megabytes: (Number(length) / 1_000_000).toFixed(1) };
}

/** Sections of CHANGELOG.md: "## 0.1.4 (2026-11-23)" followed by "- " bullets. Apostrophes are set curly for the page;
 *  a heading without a date ("## Unreleased") and its bullets are skipped. */
export function releases(): Release[] {
  const text = readFileSync(resolve(root, "CHANGELOG.md"), "utf8");
  const out: Release[] = [];
  for (const line of text.split("\n")) {
    const head = line.match(/^## (\S+) \((\d{4}-\d{2}-\d{2})\)\s*$/);
    if (head) out.push({ version: head[1], date: head[2], items: [] });
    else if (line.startsWith("- ") && out.length) out[out.length - 1].items.push(line.slice(2).trim().replace(/'/g, "’"));
  }
  if (!out.length) throw new Error("CHANGELOG.md: no releases found");
  return out;
}

const dateFormat = new Intl.DateTimeFormat("en-GB", { dateStyle: "long", timeZone: "UTC" });
export const formatDate = (iso: string) => dateFormat.format(new Date(`${iso}T00:00:00Z`));

/** Internal links and assets: the site is served under a subpath on GitHub Pages. */
export function withBase(path: string): string {
  const base = import.meta.env.BASE_URL.replace(/\/$/, "");
  return `${base}/${path.replace(/^\//, "")}`;
}

export const REPO = "https://github.com/maxweilbuchner/harbor";
