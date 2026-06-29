// supabase/functions/refresh-tennis-draws/index.ts
//
// Edge function that pulls the current Grand Slam main-draw (128-player,
// in bracket order) for ATP + WTA and upserts it into
// public.tennis_bracket_tournaments.draw_data — so the iOS app picks up new
// slam draws OVER THE AIR (it reads Supabase draw_data first, before the
// hardcoded fallback). No app update / redownload required per slam.
//
// Deploy:
//   supabase functions deploy refresh-tennis-draws --no-verify-jwt
//
// Schedule (run daily — see cron SQL in this folder's README):
//   the function is a safe no-op when no clean 128-draw is available yet,
//   so running it daily simply back-fills each slam the day its draw drops.
//
// Source: the Nothing Major bracket pool embeds the official draw as inline
// JSON (`var bracket=[...]`) on each entry page, in exact draw order with
// seeds. It's the only clean, machine-readable, correctly-ordered source we
// found (ESPN/official sites are JS-rendered and expose no draw position).
// If the source structure ever changes, validation fails closed (writes
// nothing) rather than corrupting a draw.

// deno-lint-ignore-file no-explicit-any

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const NM_BASE = "https://bracket.nothingmajorshow.com";

interface NMEntry { seed: string; team: string; id: number }
interface DrawPlayer { draw_position: number; name: string; country: string; rank: number; seed?: number }
interface DiscoveredBracket { code: string; year: number; grandSlam: string; drawType: "atp" | "wta" }

/** Map a slam's display name (from the link text) to the schema enum value. */
function slamEnum(text: string): string | null {
  const t = text.toLowerCase();
  if (t.includes("wimbledon")) return "wimbledon";
  if (t.includes("us open") || t.includes("u.s. open")) return "us_open";
  if (t.includes("french open") || t.includes("roland garros")) return "french_open";
  if (t.includes("australian open")) return "australian_open";
  return null;
}

function slamDisplay(grandSlam: string): string {
  switch (grandSlam) {
    case "wimbledon": return "Wimbledon";
    case "us_open": return "US Open";
    case "french_open": return "French Open";
    case "australian_open": return "Australian Open";
    default: return grandSlam;
  }
}

/** Approximate ATP/WTA rank from the seed token — feeds the bot win-probability
 *  model only (the source carries no real ranking). Not used for scoring. */
function rankForSeed(seed: string): number {
  if (/^\d+$/.test(seed)) return parseInt(seed, 10);
  if (seed === "Q") return 150;   // qualifier
  if (seed === "WC") return 120;  // wildcard
  return 50;                       // unseeded direct entry
}

/** Discover which slam/draws the pool currently has up by scraping the home
 *  page's bracket links + their text ("2026 Wimbledon Men's Bracket Entry"). */
async function discoverBrackets(): Promise<DiscoveredBracket[]> {
  const res = await fetch(`${NM_BASE}/`, { headers: { "User-Agent": "Mozilla/5.0" } });
  if (!res.ok) { console.error(`NM home fetch failed: ${res.status}`); return []; }
  const html = await res.text();
  const out: DiscoveredBracket[] = [];
  const seen = new Set<string>();
  const re = /<a[^>]*href="\/nothingmajor\/bracket\/([a-z0-9]+)"[^>]*>([^<]+)<\/a>/gi;
  let m: RegExpExecArray | null;
  while ((m = re.exec(html)) !== null) {
    const code = m[1];
    const text = m[2];
    if (seen.has(code)) continue;
    seen.add(code);
    const grandSlam = slamEnum(text);
    if (!grandSlam) continue;
    const yearMatch = text.match(/(20\d{2})/);
    if (!yearMatch) continue;
    const year = parseInt(yearMatch[1], 10);
    const lower = text.toLowerCase();
    let drawType: "atp" | "wta" | null = null;
    if (lower.includes("men")) drawType = "atp";       // "Men's" (note: must test before "women")
    if (lower.includes("women")) drawType = "wta";     // "Women's" overrides — contains "men"
    if (!drawType) continue;
    out.push({ code, year, grandSlam, drawType });
  }
  return out;
}

/** Fetch + parse the embedded `var bracket=[...]` from a bracket entry page. */
async function fetchNMBracket(code: string): Promise<NMEntry[] | null> {
  const res = await fetch(`${NM_BASE}/nothingmajor/bracket/${code}`, {
    headers: { "User-Agent": "Mozilla/5.0" },
  });
  if (!res.ok) { console.error(`NM bracket ${code} fetch failed: ${res.status}`); return null; }
  const html = await res.text();
  const m = html.match(/var bracket=(\[[\s\S]*?\]);/);
  if (!m) { console.error(`NM bracket ${code}: no bracket var found`); return null; }
  try {
    return JSON.parse(m[1]) as NMEntry[];
  } catch (e) {
    console.error(`NM bracket ${code}: JSON parse failed: ${e}`);
    return null;
  }
}

/** Convert + validate. Returns the draw_data array only if it's a clean,
 *  correctly-ordered 128-player main draw; otherwise null (fail closed). */
function buildValidatedDraw(entries: NMEntry[]): DrawPlayer[] | null {
  if (!Array.isArray(entries) || entries.length !== 128) {
    console.error(`validate: expected 128 entries, got ${entries?.length}`);
    return null;
  }
  const sorted = [...entries].sort((a, b) => a.id - b.id);
  // ids must be exactly 1..128
  for (let i = 0; i < 128; i++) {
    if (sorted[i].id !== i + 1) { console.error(`validate: id gap at ${i + 1}`); return null; }
    if (!sorted[i].team || typeof sorted[i].team !== "string") { console.error(`validate: bad name at ${i + 1}`); return null; }
  }
  // Grand Slam seeding invariants: seed 1 at the top, seed 2 at the bottom.
  if (sorted[0].seed !== "1") { console.error(`validate: pos1 seed is '${sorted[0].seed}', expected 1`); return null; }
  if (sorted[127].seed !== "2") { console.error(`validate: pos128 seed is '${sorted[127].seed}', expected 2`); return null; }
  // Exactly 32 unique numeric seeds 1..32.
  const numericSeeds = sorted.filter((e) => /^\d+$/.test(e.seed)).map((e) => parseInt(e.seed, 10));
  const uniqueSeeds = new Set(numericSeeds);
  if (uniqueSeeds.size !== 32 || Math.min(...numericSeeds) !== 1 || Math.max(...numericSeeds) !== 32) {
    console.error(`validate: seeds not 1..32 unique (got ${uniqueSeeds.size})`);
    return null;
  }
  // No duplicate names.
  const names = sorted.map((e) => e.team);
  if (new Set(names).size !== 128) { console.error(`validate: duplicate names`); return null; }

  return sorted.map((e) => {
    const player: DrawPlayer = {
      draw_position: e.id,
      name: e.team,
      country: "",                 // source carries no country (UI shows seed instead)
      rank: rankForSeed(e.seed),
    };
    if (/^\d+$/.test(e.seed)) player.seed = parseInt(e.seed, 10);
    return player;
  });
}

serve(async (_req) => {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    return new Response("missing env vars", { status: 500 });
  }
  const supabase = createClient(supabaseUrl, serviceRoleKey);

  const brackets = await discoverBrackets();
  console.log(`tennis-draws: discovered ${brackets.length} bracket(s):`, brackets.map((b) => `${b.code}=${b.grandSlam}-${b.drawType}-${b.year}`));

  const report: Array<Record<string, unknown>> = [];

  for (const b of brackets) {
    const tid = `${b.grandSlam}-${b.drawType}-${b.year}`;
    const entries = await fetchNMBracket(b.code);
    if (!entries) { report.push({ tid, status: "fetch_failed" }); continue; }

    const draw = buildValidatedDraw(entries);
    if (!draw) { report.push({ tid, status: "validation_failed" }); continue; }

    // Don't clobber a row that's already populated (idempotent), and never
    // overwrite other columns (status/lock_time/results_data/bot_field) on an
    // existing live tournament — only fill draw_data.
    const { data: existing, error: selErr } = await supabase
      .from("tennis_bracket_tournaments")
      .select("id, draw_data")
      .eq("id", tid)
      .maybeSingle();
    if (selErr) { report.push({ tid, status: "select_error", error: selErr.message }); continue; }

    if (existing && Array.isArray(existing.draw_data) && existing.draw_data.length === 128) {
      report.push({ tid, status: "already_populated" });
      continue;
    }

    if (existing) {
      const { error } = await supabase
        .from("tennis_bracket_tournaments")
        .update({ draw_data: draw })
        .eq("id", tid);
      report.push({ tid, status: error ? "update_error" : "updated", error: error?.message });
    } else {
      const { error } = await supabase
        .from("tennis_bracket_tournaments")
        .insert({
          id: tid,
          title: `${slamDisplay(b.grandSlam)} ${b.year}`,
          grand_slam: b.grandSlam,
          draw_type: b.drawType,
          season: String(b.year),
          status: "open",
          draw_data: draw,
        });
      report.push({ tid, status: error ? "insert_error" : "inserted", error: error?.message });
    }
  }

  return new Response(
    JSON.stringify({ ok: true, brackets: brackets.length, report }),
    { headers: { "Content-Type": "application/json" } }
  );
});
