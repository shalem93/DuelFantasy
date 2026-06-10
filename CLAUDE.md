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
