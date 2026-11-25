// Harbor's receiving service (issue #50): a Supabase Edge Function in Frankfurt, deployed as `collect` without
// JWT verification (the app holds no key). It takes the opt-in statistics record and a problem report somebody
// chose to send here instead of to GitHub, and deletes a report for whoever holds its reference.
//
//   GET    …/collect                      "ok" (and a look at the database, which keeps the project awake)
//   POST   …/collect/statistics           one record, see `statistics` below
//   POST   …/collect/reports              { kind, title, body } -> { reference }
//   DELETE …/collect/reports/<reference>  removes that report
//
// It stores what is listed on the website's privacy page and nothing else: no address, no time of day, nothing
// from the request's headers. It writes no log lines of its own. Anything that isn't exactly the expected
// shape is refused, and each table takes a limited number of rows a day, so the endpoint can't be used to
// fill the database.
import { createClient } from "jsr:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});

const OUTCOMES = ["ran", "missingLibrary", "dotNet", "shaderCompiler", "antiCheat", "crashed", "unexplained"];
// Versions and a chip's name: short, printable ASCII.
const WORDS = /^[A-Za-z0-9 .,()+_-]{1,80}$/;
const DAILY = { statistics: 20_000, reports: 300 };

const headers = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
  "Content-Type": "application/json",
};
const answer = (status: number, body: unknown = {}) => new Response(JSON.stringify(body), { status, headers });

const today = () => new Date().toISOString().slice(0, 10);

async function full(table: "statistics" | "reports"): Promise<boolean> {
  const { count } = await db.from(table).select("*", { count: "exact", head: true }).eq("day", today());
  return (count ?? 0) >= DAILY[table];
}

/** The request's JSON object, or null when it is too long or isn't one. */
async function object(req: Request, limit: number): Promise<Record<string, unknown> | null> {
  const text = await req.text();
  if (text.length > limit) return null;
  try {
    const value = JSON.parse(text);
    return value && typeof value === "object" && !Array.isArray(value) ? value : null;
  } catch {
    return null;
  }
}

function only(value: Record<string, unknown>, keys: string[]): boolean {
  return Object.keys(value).every((key) => keys.includes(key));
}

async function statistics(req: Request): Promise<Response> {
  const record = await object(req, 2_000);
  if (!record || !only(record, ["harbor", "windowsSupport", "macOS", "chip", "outcomes"])) return answer(400);
  const { harbor, windowsSupport, macOS, chip, outcomes } = record;
  const word = (value: unknown) => typeof value === "string" && WORDS.test(value);
  if (!word(harbor) || !word(macOS) || !word(chip) || !(windowsSupport == null || word(windowsSupport))) return answer(400);
  if (!outcomes || typeof outcomes !== "object" || Array.isArray(outcomes) || !only(outcomes as Record<string, unknown>, OUTCOMES)) return answer(400);
  const counts = Object.values(outcomes as Record<string, unknown>);
  if (counts.length === 0 || !counts.every((n) => Number.isInteger(n) && (n as number) >= 0 && (n as number) <= 100_000)) return answer(400);
  if (await full("statistics")) return answer(429);
  const { error } = await db.from("statistics").insert({ harbor, windows_support: windowsSupport ?? null, macos: macOS, chip, outcomes });
  return answer(error ? 500 : 201);
}

/** 80 random bits as four groups of letters and digits that aren't mistaken for each other. */
function reference(): string {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  const text = Array.from(bytes, (b) => alphabet[b % 32]).join("");
  return text.match(/.{4}/g)!.join("-");
}

async function report(req: Request): Promise<Response> {
  const sent = await object(req, 64_000);
  if (!sent || !only(sent, ["kind", "title", "body"])) return answer(400);
  const { kind, title, body } = sent;
  if (kind !== "program" && kind !== "harbor") return answer(400);
  if (typeof title !== "string" || title.length > 200) return answer(400);
  if (typeof body !== "string" || body.trim().length === 0 || body.length > 20_000) return answer(400);
  if (await full("reports")) return answer(429);
  const ref = reference();
  const { error } = await db.from("reports").insert({ reference: ref, kind, title, body });
  return error ? answer(500) : answer(201, { reference: ref });
}

async function remove(ref: string): Promise<Response> {
  if (!/^[A-Z2-9]{4}(-[A-Z2-9]{4}){3}$/.test(ref)) return answer(400);
  const { data, error } = await db.from("reports").delete().eq("reference", ref).select("reference");
  if (error) return answer(500);
  return answer(data.length ? 200 : 404);
}

Deno.serve(async (req: Request) => {
  // `/collect/statistics` here, `/functions/v1/collect/statistics` outside: what follows the function's name.
  const path = new URL(req.url).pathname.replace(/^.*?\/collect/, "").replace(/\/$/, "");
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers });
  if (req.method === "GET" && path === "") return answer((await full("statistics")) ? 429 : 200, { ok: true });
  if (req.method === "POST" && path === "/statistics") return await statistics(req);
  if (req.method === "POST" && path === "/reports") return await report(req);
  if (req.method === "DELETE" && path.startsWith("/reports/")) return await remove(path.slice("/reports/".length));
  return answer(404);
});
