// supabase/functions/refresh-tennis-odds/index.ts
//
// Edge function that pulls upcoming tennis moneylines from Pinnacle's guest
// API and upserts them into public.tennis_odds.
//
// Deploy:
//   supabase functions deploy refresh-tennis-odds --no-verify-jwt
//
// Pinnacle returns ALL tennis worldwide (incl. ITF / Challenger / minor events).
// We aggressively filter to tour-level ATP / WTA + Grand Slams.

// deno-lint-ignore-file no-explicit-any

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const PINNACLE_SPORT_ID_TENNIS = 33;
const PINNACLE_GUEST_KEY = "CmX2KcMrXuFmNg6YFbmTxE0y/qyBK60G3CqHk8XRSlAqlnVz";
const PINNACLE_BASE = "https://guest.api.arcadia.pinnacle.com/0.1";

interface Matchup {
  id: number;
  startTime: string;
  participants: Array<{ name: string; alignment: string }>;
  league: { id: number; name: string };
  type: string;
  status: string;
  parent?: unknown;
}

interface Market {
  matchupId: number;
  type: string;
  isAlternate: boolean;
  period?: number;      // 0 = full match, 1 = first set, etc. We want 0.
  status?: string;      // "open" when active, otherwise skip
  prices: Array<{
    participantId?: number;
    designation?: string;
    price: number;      // ALREADY in American odds (e.g. -204, +183).
    points?: number;
  }>;
}

/**
 * Pinnacle's tennis `price` field is already in AMERICAN odds (-204, +183).
 * Validate sanity bounds and round to integer.
 */
function sanitizeAmericanOdds(price: number | null | undefined): number | null {
  if (typeof price !== "number" || !Number.isFinite(price)) return null;
  const american = Math.round(price);
  if (Math.abs(american) < 100) return null;     // even-money / invalid
  if (Math.abs(american) > 50000) return null;   // absurd
  return american;
}

/**
 * Whitelist tour-level ATP / WTA and the four Grand Slams. Pinnacle's
 * league.name field is the truth source — examples we want to keep:
 *   "ATP", "WTA", "Grand Slam", "French Open", "Roland Garros",
 *   "Wimbledon", "US Open", "Australian Open"
 * Examples we drop:
 *   "ITF", "ATP Challenger", "WTA 125", "WTA Challenger", "Doubles",
 *   "Exhibition", anything else.
 */
function classifyLeague(name: string): string | null {
  const lower = name.toLowerCase();

  // Outright dropouts.
  if (lower.includes("challenger")) return null;
  if (lower.startsWith("itf")) return null;
  if (lower.includes(" itf ") || lower.endsWith(" itf")) return null;
  if (lower.includes("doubles")) return null;
  if (lower.includes("exhibition")) return null;
  if (lower.includes("wta 125")) return null;

  // Grand Slams — sometimes Pinnacle labels these without ATP/WTA prefix.
  if (lower.includes("french open") || lower.includes("roland garros")) {
    return lower.includes("wta") || lower.includes("women") ? "wta" : "atp";
  }
  if (lower.includes("wimbledon")) {
    return lower.includes("wta") || lower.includes("women") ? "wta" : "atp";
  }
  if (lower.includes("us open") || lower.includes("u.s. open")) {
    return lower.includes("wta") || lower.includes("women") ? "wta" : "atp";
  }
  if (lower.includes("australian open")) {
    return lower.includes("wta") || lower.includes("women") ? "wta" : "atp";
  }
  if (lower.includes("grand slam")) {
    return lower.includes("wta") || lower.includes("women") ? "wta" : "atp";
  }

  // Tour level.
  if (lower.startsWith("atp") || lower.includes(" atp ") || lower.endsWith(" atp")) {
    return "atp";
  }
  if (lower.startsWith("wta") || lower.includes(" wta ") || lower.endsWith(" wta")) {
    return "wta";
  }

  return null;  // drop everything else (ITF, M15s, W25s, etc.)
}

async function fetchPinnacle<T>(path: string): Promise<T | null> {
  const url = `${PINNACLE_BASE}${path}`;
  const res = await fetch(url, {
    headers: {
      "X-API-Key": PINNACLE_GUEST_KEY,
      "Accept": "application/json",
      "User-Agent": "Mozilla/5.0",
    },
  });
  if (!res.ok) {
    console.error(`Pinnacle ${path} failed: ${res.status}`);
    return null;
  }
  return (await res.json()) as T;
}

serve(async (_req) => {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    return new Response("missing env vars", { status: 500 });
  }
  const supabase = createClient(supabaseUrl, serviceRoleKey);

  const matchups = await fetchPinnacle<Matchup[]>(
    `/sports/${PINNACLE_SPORT_ID_TENNIS}/matchups`
  );
  if (!matchups) {
    return new Response(
      JSON.stringify({ ok: false, error: "matchups fetch failed" }),
      { status: 502, headers: { "Content-Type": "application/json" } }
    );
  }

  const markets = await fetchPinnacle<Market[]>(
    `/sports/${PINNACLE_SPORT_ID_TENNIS}/markets/straight`
  );
  if (!markets) {
    return new Response(
      JSON.stringify({ ok: false, error: "markets fetch failed" }),
      { status: 502, headers: { "Content-Type": "application/json" } }
    );
  }

  // Only keep period=0 (full match) moneyline markets that are open.
  // Pinnacle exposes period=1 (first set) too, which would cause us to
  // overwrite the full-match line for the same matchupId.
  const moneylineByMatchup: Record<number, Market> = {};
  for (const market of markets) {
    if (market.type !== "moneyline") continue;
    if (market.isAlternate) continue;
    if (market.period !== undefined && market.period !== 0) continue;
    if (market.status && market.status !== "open") continue;
    moneylineByMatchup[market.matchupId] = market;
  }

  const now = new Date();
  const rows: Array<Record<string, unknown>> = [];
  let droppedByLeague = 0;
  let droppedByPrice = 0;
  const sampleLeagueNames = new Set<string>();
  for (const matchup of matchups) {
    if (matchup.type !== "matchup") continue;
    if (matchup.participants.length !== 2) continue;
    if (matchup.status && matchup.status !== "pending") continue;
    const startsAt = new Date(matchup.startTime);
    if (Number.isNaN(startsAt.getTime())) continue;
    if (startsAt.getTime() < now.getTime() - 4 * 3600_000) continue;

    const market = moneylineByMatchup[matchup.id];
    if (!market) continue;

    const league = classifyLeague(matchup.league?.name ?? "");
    if (!league) {
      droppedByLeague++;
      if (sampleLeagueNames.size < 30) sampleLeagueNames.add(matchup.league?.name ?? "(empty)");
      continue;
    }

    const homePart = matchup.participants.find((p) => p.alignment === "home");
    const awayPart = matchup.participants.find((p) => p.alignment === "away");
    if (!homePart || !awayPart) continue;

    const homePrice = market.prices.find((p) => p.designation === "home");
    const awayPrice = market.prices.find((p) => p.designation === "away");
    if (!homePrice || !awayPrice) continue;

    const homeAM = sanitizeAmericanOdds(homePrice.price);
    const awayAM = sanitizeAmericanOdds(awayPrice.price);
    if (homeAM === null || awayAM === null) {
      droppedByPrice++;
      continue;
    }

    rows.push({
      id: String(matchup.id),
      league,
      home_team: homePart.name,
      away_team: awayPart.name,
      home_moneyline: homeAM,
      away_moneyline: awayAM,
      starts_at: startsAt.toISOString(),
      fetched_at: now.toISOString(),
      source: "pinnacle",
    });
  }

  console.log(
    `tennis-odds: kept ${rows.length}, droppedByLeague=${droppedByLeague}, droppedByPrice=${droppedByPrice}`
  );
  const sampleRejected = Array.from(sampleLeagueNames);
  if (sampleRejected.length > 0) {
    console.log("Sample rejected leagues:", sampleRejected);
  }

  // Wipe + upsert: keeps the table tidy. Old rows that no longer pass our
  // league/price filter should disappear, not linger.
  await supabase.from("tennis_odds").delete().neq("id", "");

  if (rows.length === 0) {
    return new Response(
      JSON.stringify({
        ok: true,
        written: 0,
        droppedByLeague,
        droppedByPrice,
        sampleRejectedLeagues: sampleRejected,
        note: "no qualifying upcoming matches",
      }),
      { headers: { "Content-Type": "application/json" } }
    );
  }

  const { error } = await supabase
    .from("tennis_odds")
    .upsert(rows, { onConflict: "id" });

  if (error) {
    console.error("Upsert failed:", error);
    return new Response(
      JSON.stringify({ ok: false, error: error.message }),
      { status: 500, headers: { "Content-Type": "application/json" } }
    );
  }

  return new Response(
    JSON.stringify({
      ok: true,
      written: rows.length,
      droppedByLeague,
      droppedByPrice,
      sampleRejectedLeagues: sampleRejected,
    }),
    { headers: { "Content-Type": "application/json" } }
  );
});
