# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

DuelFantasy is a SwiftUI iOS fantasy-sports app (DFS, Best Ball, Pick'em, and several "Tiers"/bracket game modes) backed by Supabase. The Xcode target/scheme is `DuelFantasy`, but the codebase retains an older internal name "GameOn": the entry point is `GameOnApp.swift`, test folders are `GameOnTests`/`GameOnUITests`, and the (unused) CoreData model is `GameOn.xcdatamodeld`.

## Build & Test

```bash
# Build
xcodebuild -project DuelFantasy.xcodeproj -scheme DuelFantasy \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' build

# Tests (both targets are empty template stubs — there are no real tests)
xcodebuild -project DuelFantasy.xcodeproj -scheme DuelFantasy \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' test
```

Deployment target is iOS 26.2. No linter, no SPM/CocoaPods dependencies — networking is raw URLSession (no Supabase SDK).

```bash
# Deploy the one Supabase edge function (tennis odds from Pinnacle → tennis_odds table)
supabase functions deploy refresh-tennis-odds --no-verify-jwt
```

## Architecture

### Per-game-mode file pattern

Every game mode follows the same three-part layout. New modes should follow it too:

- **`<Mode>Data.swift` (repo root)** — Codable models, scoring/stat calculation, data-provider logic against external APIs, and bot logic (e.g. `BestBallBotDrafter`). DFS sports each get their own file (`NFLDFSData.swift`, `GolfDFSData.swift`, `UFCDFSData.swift`, …) implementing the provider protocols (`DFSSlateProvider`, `DFSLiveScoringProvider`) defined in `DFSData.swift`.
- **`DuelFantasy/<Mode>ViewModel.swift`** — observable state, fetch/persist via `SupabaseService.shared`, settlement tracking.
- **`DuelFantasy/<Mode>*View.swift`** — SwiftUI views (lobby, live, group detail, etc.).

### Navigation & view-model wiring

`GameOnApp.swift` → `ContentView.swift`, which hosts a 5-tab TabView (Pick'em, DFS, Fantasy hub, Chat, Profile) and instantiates **all** view models: ten `DFSViewModel` instances (one per sport — NFL, NHL, MLB, PGA, UFC, EPL, UCL, World Cup, CFB, NBA) plus one VM per fantasy mode. `FantasyHubView` is the launcher for Best Ball / Playoff Tiers / Tennis Bracket / Golf Tiers / Soccer Tiers and preloads their tournaments.

### Backend (Supabase)

- `SupabaseService.swift` is a very large (~235KB) singleton (`SupabaseService.shared`) doing all REST calls by hand. Supabase URL and anon key are hardcoded in `SupabaseConfig` at the top of the file.
- Auth: `AuthViewModel.swift` persists the session in UserDefaults and installs a `tokenRefreshProvider` closure on `SupabaseService`; 401s trigger a serialized token refresh + retry. Session refresh also runs when the app returns to foreground.
- Schema lives in `supabase_schema.sql` (profiles, `dfs_*`, `pickem_picks`, `bestball_*`, `{tennis_bracket,golf_tiers,playoff_tiers,soccer_tiers}_*`, `friendships`), all with RLS. Keep this file in sync when changing tables.

### Scoring & settlement (client-driven)

There is no server-side scoring job: clients fetch live stats from external APIs, compute fantasy points locally, and write scores/ranks back to Supabase via the ViewModels (`update<Mode>EntryScores`-style methods). Settlement state is tracked per mode (e.g. `DFSViewModel.settledTournaments`); Pick'em RR adjustments go through a Postgres RPC to avoid double-counting across devices.

### External data sources

- **ESPN public APIs** (`site.api.espn.com`, `sports.core.api.espn.com`) — rosters, scoreboards, live stats for most sports.
- **The Odds API** — key hardcoded in `AppSecrets` (`SportsData.swift`), overridable via `@AppStorage("odds_api_key")`.
- **Pinnacle guest API** — tennis moneylines, via the `refresh-tennis-odds` edge function only.
- **RotoGrinders** — DFS salary canonicalization (`RotoGrindersSalaryProvider` in `DFSData.swift`).

### Local persistence

App data lives in Supabase; device-local state (RR score, DFS history blob, past-results caches) lives in `@AppStorage`/UserDefaults. CoreData (`Persistence.swift`, `GameOn.xcdatamodeld`) is untouched Xcode template code — don't build on it.

## Non-obvious behaviors

- **Bots**: Best Ball leagues auto-fill with bot members (`is_bot = true`, `user_id = nil` in `bestball_members`); draft picks come from `BestBallBotDrafter.pickForBot()`. Other modes have bot fields snapshotted into results tables.
- **Force update**: `ForceUpdate.swift` compares the bundle version against the App Store via the iTunes lookup API (throttled hourly) and shows a non-dismissable blocking screen when outdated. Bump the marketing version carefully — shipping a version check bug can lock users out.
- **History sync**: on launch, `ContentView` runs `syncAllSportsHistoryFromServer` across all ten DFS view models concurrently and merges into a single `@AppStorage("dfs_history_data")` blob; profile stats (RR/wins/losses) are merged server↔local rather than overwritten.
- **Per-sport DFS VM fan-out (easy to break)**: there is one `DFSViewModel` per sport and they must each be wired into EVERY per-VM list in `ContentView` — the settlement group, the `loadSlateIfNeeded`/`refreshLive` polling loop (`.task(id: "dfs-settlement-timer")`), the `.onChange(of: scenePhase)` foreground refresh, the history-sync `allVMs`, and the `profileName` fan-out. Omitting a VM from the polling loop or foreground refresh means that sport never re-probes confirmed lineups or re-runs bot late-swap while the app is open, so its confirmed starters and bots only update on a cold launch (force-quit) — and settlement/RR silently drifts. WC, ncaam, and wnba were each missed this way at least once.
- **DFS staggered-slate bots (late swap)**: for multi-game soccer/MLB slates, bots are generated when the FIRST game locks (later games' XIs aren't out yet), then `applyLateSwapBotOptimization()` (called inside `refreshLive`) upgrades each bot's not-yet-started, non-confirmed slots to confirmed starters as each later game's XI drops — so a healthy field ends up spread across all games, not just the first. This only works if the sport's VM is in the polling loop above; a confirmed starter that drops while the app is backgrounded is picked up on the next `refreshLive` (foreground or 60s poll). Single-game bots must only roster confirmed starters — never let unconfirmed players into the SG bot pool/weighting.
