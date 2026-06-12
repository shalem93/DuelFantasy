import Foundation

struct Match: Identifiable {
    let id: String
    let league: String
    let awayTeam: String
    let homeTeam: String
    let startsAt: Date
    let state: String
    let statusDetail: String
    let awayScore: Int?
    let homeScore: Int?
    let options: [PickOption]

    var isLive: Bool { state == "in" }
    var isFinal: Bool { state == "post" }
    var isLocked: Bool { state != "pre" || startsAt <= Date() }
}

struct PickOption: Identifiable {
    var id: String { team }
    let team: String
    let gainRR: Int
    let lossRR: Int
}

struct GameFixture {
    let id: String
    let sportKey: String
    let league: String
    let awayTeam: String
    let homeTeam: String
    let startsAt: Date
    let state: String
    let statusDetail: String
    let awayScore: Int?
    let homeScore: Int?
    let awayWinPct: Double?
    let homeWinPct: Double?
    let awayMoneyline: Double?
    let homeMoneyline: Double?
    /// Soccer 3-way draw price, when the odds source provides one.
    var drawMoneyline: Double? = nil
}

struct OddsQuote {
    let team: String
    let gainRR: Int
    let lossRR: Int
}

protocol GameProvider {
    func fetchGames() async throws -> [GameFixture]
}

struct OddsResult {
    /// Odds API quotes matched to existing ESPN fixtures (keyed by fixture ID).
    let quotesByFixture: [String: [OddsQuote]]
    /// Extra matches created from Odds API events that had no ESPN fixture counterpart.
    let extraMatches: [Match]
}

protocol OddsProvider {
    func fetchOdds(for fixtures: [GameFixture]) async throws -> OddsResult
}

protocol MatchProvider {
    func fetchMatches() async throws -> [Match]
}

protocol MatchResultProvider {
    func fetchCompletedWinners(matchIDs: Set<String>) async throws -> [String: String]
}

enum SportsDataError: Error {
    case missingAPIKey
    case invalidResponse
}

enum AppSecrets {
    static let defaultOddsAPIKey = "380bb85ffc24cc7c960796c732b7eb5c"
}

struct ConfiguredMatchProvider: MatchProvider {
    let apiKey: String

    func fetchMatches() async throws -> [Match] {
        let gameProvider = ESPNTodayGameProvider()
        // Always use the default key — @AppStorage may hold a stale/invalid value
        let effectiveKey = AppSecrets.defaultOddsAPIKey
        // Primary: Supabase-backed tennis odds cache (populated by the
        // refresh-tennis-odds edge function). Fallback: The Odds API for
        // anything Supabase didn't cover. Once the edge-function cron has
        // been running reliably you can drop the Odds API subscription and
        // pass NoOddsProvider() as the fallback.
        let fallback: OddsProvider = effectiveKey.isEmpty
            ? NoOddsProvider()
            : TheOddsAPIProvider(apiKey: effectiveKey)
        let oddsProvider: OddsProvider = CompositeOddsProvider(
            primary: SupabaseTennisOddsProvider(),
            fallback: fallback
        )

        return try await CompositeMatchProvider(gameProvider: gameProvider, oddsProvider: oddsProvider).fetchMatches()
    }
}

/// Strips the bookmaker's vig from a 3-way (soccer) market: convert each
/// American price to an implied probability, normalize so the three sum to 1,
/// and convert back to fair American odds. Pick'em quotes shouldn't carry the
/// book's juice — a DK +205 draw is ~+240 fair.
func devigThreeWayOdds(away: Double, draw: Double, home: Double) -> (away: Double, draw: Double, home: Double) {
    func implied(_ odds: Double) -> Double {
        odds > 0 ? 100.0 / (odds + 100.0) : abs(odds) / (abs(odds) + 100.0)
    }
    func american(_ p: Double) -> Double {
        guard p > 0, p < 1 else { return 0 }
        return p >= 0.5 ? -100.0 * p / (1.0 - p) : 100.0 * (1.0 - p) / p
    }
    let pA = implied(away), pD = implied(draw), pH = implied(home)
    let total = pA + pD + pH
    guard total > 0 else { return (away, draw, home) }
    return (american(pA / total), american(pD / total), american(pH / total))
}

struct CompositeMatchProvider: MatchProvider {
    private let gameProvider: GameProvider
    private let oddsProvider: OddsProvider

    init(gameProvider: GameProvider, oddsProvider: OddsProvider) {
        self.gameProvider = gameProvider
        self.oddsProvider = oddsProvider
    }

    func fetchMatches() async throws -> [Match] {
        let fixtures = try await gameProvider.fetchGames()
        // Odds fetch should never kill the entire match load — gracefully degrade
        let oddsResult = (try? await oddsProvider.fetchOdds(for: fixtures)) ?? OddsResult(quotesByFixture: [:], extraMatches: [])
        let oddsByFixture = oddsResult.quotesByFixture

        var matches = fixtures
            .sorted(by: { $0.startsAt < $1.startsAt })
            .compactMap { fixture -> Match? in
                // Prefer Odds API data; fall back to ESPN moneylines.
                // For tennis, rank-estimated moneylines are too inaccurate for
                // lower-tier events — only show tennis matches that have real
                // Odds API data to prevent arbitrage opportunities.
                let quotes: [OddsQuote]
                if let oddsAPIQuotes = oddsByFixture[fixture.id] {
                    quotes = oddsAPIQuotes
                } else if fixture.sportKey.hasPrefix("tennis_") {
                    // No real odds for this tennis match — skip it
                    return nil
                } else if let awayML = fixture.awayMoneyline,
                          let homeML = fixture.homeMoneyline {
                    // Soccer 3-way: each outcome (home, draw, away) is independent.
                    // Picking a team means you LOSE on both draw and opponent win.
                    // Use per-outcome RR (same as Odds API path) not 2-way swing.
                    if fixture.sportKey.hasPrefix("soccer_") {
                        // Real draw price when the odds source has one. The old
                        // synthetic formula reduced to a CONSTANT 28% draw
                        // probability (the pA+pB terms cancelled), which is why
                        // every soccer draw quoted +26. The estimate fallback
                        // uses the 3-way residual: home/away prices come from
                        // the same 3-way market, so 1 + vig − pA − pB ≈ pDraw.
                        let drawOdds: Double
                        if let realDraw = fixture.drawMoneyline {
                            drawOdds = realDraw
                        } else {
                            let pA = impliedProbability(from: awayML)
                            let pB = impliedProbability(from: homeML)
                            let drawProb = max(0.10, min(0.40, 1.07 - (pA + pB)))
                            drawOdds = ((1.0 - drawProb) / drawProb) * 100.0
                        }
                        // Strip the juice before quoting — picks shouldn't pay
                        // the book's margin.
                        let fair = devigThreeWayOdds(away: awayML, draw: drawOdds, home: homeML)
                        let awayQuote = rrQuoteFromIndividualOdds(team: fixture.awayTeam, odds: fair.away)
                        let drawQuote = rrQuoteFromIndividualOdds(team: "Draw", odds: fair.draw)
                        let homeQuote = rrQuoteFromIndividualOdds(team: fixture.homeTeam, odds: fair.home)
                        quotes = [awayQuote, drawQuote, homeQuote]
                    } else {
                        let espnQuotes = rrQuotesFromTwoWayAmericanOdds(
                            teamA: fixture.awayTeam, oddsA: awayML,
                            teamB: fixture.homeTeam, oddsB: homeML
                        )
                        guard espnQuotes.count == 2 else { return nil }
                        quotes = espnQuotes
                    }
                } else {
                    // No valid odds — skip this game
                    return nil
                }

                return Match(
                    id: fixture.id,
                    league: fixture.league,
                    awayTeam: fixture.awayTeam,
                    homeTeam: fixture.homeTeam,
                    startsAt: fixture.startsAt,
                    state: fixture.state,
                    statusDetail: fixture.statusDetail,
                    awayScore: fixture.awayScore,
                    homeScore: fixture.homeScore,
                    options: quotes.map { quote in
                        PickOption(team: quote.team, gainRR: quote.gainRR, lossRR: quote.lossRR)
                    }
                )
            }

        // Add Odds API-only matches (games ESPN doesn't have fixtures for)
        matches.append(contentsOf: oddsResult.extraMatches)
        matches.sort(by: { $0.startsAt < $1.startsAt })
        return matches
    }

    private func rrQuotesFromTwoWayAmericanOdds(
        teamA: String,
        oddsA: Double,
        teamB: String,
        oddsB: Double
    ) -> [OddsQuote] {
        let pA = impliedProbability(from: oddsA)
        let pB = impliedProbability(from: oddsB)
        guard pA > 0, pB > 0 else { return [] }

        // Swing = how many RR the underdog gains (and favorite risks).
        // Based on combined absolute American odds divided by 20, clamped [12, 240].
        // E.g. -305/+245 → (305+245)/20 = 28, -5000/+2500 → 375 → capped at 240
        let swing = clamp(Int(((abs(oddsA) + abs(oddsB)) / 20.0).rounded()), min: 12, max: 240)
        let fixed = 10
        let aIsFavorite = pA >= pB

        let quoteA = aIsFavorite
            ? OddsQuote(team: teamA, gainRR: fixed, lossRR: swing)
            : OddsQuote(team: teamA, gainRR: swing, lossRR: fixed)
        let quoteB = aIsFavorite
            ? OddsQuote(team: teamB, gainRR: swing, lossRR: fixed)
            : OddsQuote(team: teamB, gainRR: fixed, lossRR: swing)
        return [quoteA, quoteB]
    }

    private func impliedProbability(from americanOdds: Double) -> Double {
        if americanOdds > 0 {
            return 100.0 / (americanOdds + 100.0)
        }
        return abs(americanOdds) / (abs(americanOdds) + 100.0)
    }

    /// Computes RR for a single 3-way outcome based on its own American odds.
    private func rrQuoteFromIndividualOdds(team: String, odds: Double) -> OddsQuote {
        let swing = clamp(Int((abs(odds) / 10.0).rounded()), min: 12, max: 160)
        if odds < 0 {
            return OddsQuote(team: team, gainRR: 10, lossRR: swing)
        } else {
            return OddsQuote(team: team, gainRR: swing, lossRR: 10)
        }
    }

    private func clamp(_ value: Int, min: Int, max: Int) -> Int {
        Swift.max(min, Swift.min(max, value))
    }
}

struct ESPNTodayGameProvider: GameProvider {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchGames() async throws -> [GameFixture] {
        // Run inside withoutActuallyEscaping + Task.detached so that
        // cooperative cancellation from SwiftUI's .task modifier does NOT
        // abort in-flight HTTP requests (the root cause of games disappearing
        // when the user switches tabs mid-fetch).
        let session = self.session
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached {
                do {
                    let result = try await Self.fetchGamesImpl(session: session)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// The actual implementation, extracted as a static method so it can run in
    /// a detached Task that is immune to parent-task cancellation.
    private static func fetchGamesImpl(session: URLSession) async throws -> [GameFixture] {
        let dateKeys = ESPNDateKeys.todayAndTomorrow

        // Build the full request matrix (sport × date) and fan out in parallel.
        // The previous sequential loop made one slow ESPN endpoint stall the
        // entire Pick'em load behind it (9 sports × 2 dates = 18 sequential
        // round-trips), which the user saw as an indefinite "Loading games..."
        // spinner. Per-request timeout caps the worst case at ~12s no matter
        // what ESPN's regional CDN is doing.
        struct Job { let sport: ESPSportDefinition; let dateKey: String }
        var jobs: [Job] = []
        for sport in ESPSportDefinition.majorSports {
            for dateKey in dateKeys {
                jobs.append(Job(sport: sport, dateKey: dateKey))
            }
        }

        // Per-request URLSession with a short timeout. The default URLSession
        // timeout (60s) is way too generous for a spinner-blocking load — if
        // ESPN doesn't answer in ~12s, treat it as a soft failure and move on.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 15
        let timedSession = URLSession(configuration: config)

        let fixturesByJob: [[GameFixture]] = await withTaskGroup(of: [GameFixture].self) { group in
            for job in jobs {
                group.addTask {
                    let sport = job.sport
                    let dateKey = job.dateKey
                    guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(sport.sportPath)/\(sport.leaguePath)/scoreboard?dates=\(dateKey)") else {
                        return []
                    }
                    guard let (data, response) = try? await timedSession.data(from: url) else {
                        print("[Pick'em] ESPN API failed for \(sport.displayName) on \(dateKey) — skipping")
                        return []
                    }
                    guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
                        return []
                    }
                    let scoreboard: ESPNScoreboardResponse
                    do {
                        scoreboard = try JSONDecoder.espnDecoder.decode(ESPNScoreboardResponse.self, from: data)
                    } catch {
                        print("[Pick'em] Decode failed for \(sport.displayName) on \(dateKey): \(error)")
                        return []
                    }
                    let leagueLabel = sport.displayName
                    var out: [GameFixture] = []
                    for event in scoreboard.events {
                        guard let competition = event.competitions.first else { continue }
                        let state = competition.status.type.state
                        guard state == "pre" || state == "in" || state == "post" else { continue }
                        guard let awayCompetitor = competition.competitors.first(where: { $0.homeAway == "away" }) else { continue }
                        guard let homeCompetitor = competition.competitors.first(where: { $0.homeAway == "home" }) else { continue }
                        let awayMoneyline = parseAmericanOdds(from: competition.odds?.first?.moneyline?.away?.close?.odds)
                        let homeMoneyline = parseAmericanOdds(from: competition.odds?.first?.moneyline?.home?.close?.odds)
                        let drawMoneyline = parseAmericanOdds(from: competition.odds?.first?.moneyline?.draw?.close?.odds)
                        out.append(
                            GameFixture(
                                id: "espn-\(sport.oddsSportKey)-\(event.id)",
                                sportKey: sport.oddsSportKey,
                                league: leagueLabel,
                                awayTeam: awayCompetitor.team.displayName,
                                homeTeam: homeCompetitor.team.displayName,
                                startsAt: event.date,
                                state: state,
                                statusDetail: competition.status.type.shortDetail ?? competition.status.type.detail ?? state.uppercased(),
                                awayScore: Int(awayCompetitor.score ?? ""),
                                homeScore: Int(homeCompetitor.score ?? ""),
                                awayWinPct: awayCompetitor.records?.compactMap({ $0.summary }).compactMap(parseWinPercentage(from:)).first,
                                homeWinPct: homeCompetitor.records?.compactMap({ $0.summary }).compactMap(parseWinPercentage(from:)).first,
                                awayMoneyline: awayMoneyline,
                                homeMoneyline: homeMoneyline,
                                drawMoneyline: drawMoneyline
                            )
                        )
                    }
                    return out
                }
            }
            var all: [[GameFixture]] = []
            for await batch in group { all.append(batch) }
            return all
        }
        var fixtures: [GameFixture] = fixturesByJob.flatMap { $0 }

        // Also fetch tennis matches
        if let tennisFixtures = try? await ESPNTennisGameProvider(session: session).fetchGames() {
            fixtures.append(contentsOf: tennisFixtures)
        }

        // For fixtures missing moneylines, fetch from ESPN Core API (free, no key needed)
        fixtures = await backfillMoneylines(session: session, fixtures)

        var seenIDs = Set<String>()
        return fixtures
            .filter { seenIDs.insert($0.id).inserted }
            .sorted(by: { $0.startsAt < $1.startsAt })
    }

    /// Fetches moneylines from the ESPN Core API for fixtures that don't have them.
    /// Core API URL: sports.core.api.espn.com/v2/sports/{sport}/leagues/{league}/events/{id}/competitions/{id}/odds
    private static func backfillMoneylines(session: URLSession, _ fixtures: [GameFixture]) async -> [GameFixture] {
        // Build sport/league path lookup from oddsSportKey
        let sportLookup: [String: (sport: String, league: String)] = Dictionary(
            uniqueKeysWithValues: ESPSportDefinition.majorSports.map {
                ($0.oddsSportKey, ($0.sportPath, $0.leaguePath))
            }
        )

        // Find fixtures needing odds (any state, skip tennis)
        // First apply cached odds, then only fetch what's still missing
        var updated = fixtures
        var stillNeedsOdds: [(Int, GameFixture)] = []
        for (index, fixture) in fixtures.enumerated() {
            guard fixture.awayMoneyline == nil && fixture.homeMoneyline == nil
                  && !fixture.sportKey.hasPrefix("tennis_") else { continue }

            // Check cache first
            let parts = fixture.id.split(separator: "-")
            guard parts.count >= 3 else { continue }
            let eventID = String(parts.last!)

            if let cached = CoreAPIOddsCache.shared.get(eventID) {
                updated[index] = GameFixture(
                    id: fixture.id, sportKey: fixture.sportKey, league: fixture.league,
                    awayTeam: fixture.awayTeam, homeTeam: fixture.homeTeam,
                    startsAt: fixture.startsAt, state: fixture.state, statusDetail: fixture.statusDetail,
                    awayScore: fixture.awayScore, homeScore: fixture.homeScore,
                    awayWinPct: fixture.awayWinPct, homeWinPct: fixture.homeWinPct,
                    awayMoneyline: cached.away, homeMoneyline: cached.home
                )
            } else {
                stillNeedsOdds.append((index, fixture))
            }
        }

        guard !stillNeedsOdds.isEmpty else { return updated }

        // Extract ESPN event IDs: fixture ID format is "espn-{sportKey}-{eventID}"
        struct OddsRequest {
            let index: Int
            let eventID: String
            let sportPath: String
            let leaguePath: String
        }
        var requests: [OddsRequest] = []
        for (index, fixture) in stillNeedsOdds {
            let parts = fixture.id.split(separator: "-")
            guard parts.count >= 3,
                  let paths = sportLookup[fixture.sportKey] else { continue }
            let eventID = String(parts.last!)
            requests.append(OddsRequest(index: index, eventID: eventID, sportPath: paths.sport, leaguePath: paths.league))
        }
        guard !requests.isEmpty else { return updated }

        // Fetch odds in parallel (Core API is free, no rate limit concerns)
        let fetched: [(Int, String, Double, Double, Double?)] = await withTaskGroup(of: (Int, String, Double, Double, Double?)?.self) { group in
            for req in requests {
                group.addTask {
                    let urlStr = "https://sports.core.api.espn.com/v2/sports/\(req.sportPath)/leagues/\(req.leaguePath)/events/\(req.eventID)/competitions/\(req.eventID)/odds"
                    guard let url = URL(string: urlStr) else { return nil }
                    guard let (data, response) = try? await session.data(from: url),
                          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
                    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let items = json["items"] as? [[String: Any]],
                          let first = items.first else { return nil }
                    // Parse moneyline from Core API response (can be Int or Double)
                    guard let awayTeamOdds = first["awayTeamOdds"] as? [String: Any],
                          let homeTeamOdds = first["homeTeamOdds"] as? [String: Any] else { return nil }
                    let awayML: Double? = (awayTeamOdds["moneyLine"] as? Double) ?? (awayTeamOdds["moneyLine"] as? Int).map(Double.init)
                    let homeML: Double? = (homeTeamOdds["moneyLine"] as? Double) ?? (homeTeamOdds["moneyLine"] as? Int).map(Double.init)
                    // Soccer 3-way: Core API carries the draw under "drawOdds"
                    let drawML: Double? = {
                        guard let drawOdds = first["drawOdds"] as? [String: Any] else { return nil }
                        return (drawOdds["moneyLine"] as? Double) ?? (drawOdds["moneyLine"] as? Int).map(Double.init)
                    }()
                    guard let awayOdds = awayML, let homeOdds = homeML else { return nil }
                    return (req.index, req.eventID, awayOdds, homeOdds, drawML)
                }
            }
            var results: [(Int, String, Double, Double, Double?)] = []
            for await result in group {
                if let r = result { results.append(r) }
            }
            return results
        }

        for (index, eventID, awayML, homeML, drawML) in fetched {
            // Cache for future refreshes
            CoreAPIOddsCache.shared.set(eventID, away: awayML, home: homeML)

            let f = updated[index]
            updated[index] = GameFixture(
                id: f.id, sportKey: f.sportKey, league: f.league,
                awayTeam: f.awayTeam, homeTeam: f.homeTeam,
                startsAt: f.startsAt, state: f.state, statusDetail: f.statusDetail,
                awayScore: f.awayScore, homeScore: f.homeScore,
                awayWinPct: f.awayWinPct, homeWinPct: f.homeWinPct,
                awayMoneyline: awayML, homeMoneyline: homeML,
                drawMoneyline: drawML
            )
        }
        return updated
    }

    private static func parseWinPercentage(from summary: String) -> Double? {
        let parts = summary.split(separator: "-").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        let wins = parts[0]
        let losses = parts[1]
        let ties = parts.count >= 3 ? parts[2] : 0
        let total = wins + losses + ties
        guard total > 0 else { return nil }
        return (Double(wins) + Double(ties) * 0.5) / Double(total)
    }

    private static func parseAmericanOdds(from raw: String?) -> Double? {
        guard var raw else { return nil }
        raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return nil }
        return Double(raw)
    }
}

struct ESPNMatchResultProvider: MatchResultProvider {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchCompletedWinners(matchIDs: Set<String>) async throws -> [String: String] {
        guard !matchIDs.isEmpty else { return [:] }

        // Only poll sports that have unresolved picks — skip the rest entirely.
        let relevantSports = ESPSportDefinition.majorSports.filter { sport in
            matchIDs.contains { $0.contains(sport.oddsSportKey) }
        }
        let dateKeys = ESPNDateKeys.yesterdayTodayTomorrow

        // Short timeout session so a single slow endpoint doesn't block everything.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        let timedSession = URLSession(configuration: config)

        // Fetch all sport/date combos in parallel instead of sequentially.
        var winnersByMatchID: [String: String] = await withTaskGroup(
            of: [String: String].self
        ) { group in
            for sport in relevantSports {
                for dateKey in dateKeys {
                    group.addTask { @Sendable in
                        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(sport.sportPath)/\(sport.leaguePath)/scoreboard?dates=\(dateKey)") else {
                            return [:]
                        }

                        guard let (data, response) = try? await timedSession.data(from: url),
                              let http = response as? HTTPURLResponse,
                              (200..<300).contains(http.statusCode) else {
                            return [:]
                        }

                        guard let scoreboard = try? JSONDecoder.espnDecoder.decode(ESPNScoreboardResponse.self, from: data) else {
                            return [:]
                        }

                        let isSoccer = sport.oddsSportKey.hasPrefix("soccer_")
                        var results: [String: String] = [:]

                        for event in scoreboard.events {
                            guard let competition = event.competitions.first else { continue }
                            guard competition.status.type.state == "post" else { continue }
                            let matchID = "espn-\(sport.oddsSportKey)-\(event.id)"
                            guard matchIDs.contains(matchID) else { continue }

                            // For soccer, ALWAYS use match score — never the winner flag.
                            // In knockout tournaments (UCL, Europa etc.) ESPN's winner flag
                            // indicates the team that *advances* (aggregate), not who won the
                            // individual match. Pick'em bets are on the single match result.
                            if !isSoccer {
                                let winnerByFlag = competition.competitors.first(where: { $0.winner == true })?.team.displayName
                                if let winnerByFlag {
                                    results[matchID] = winnerByFlag
                                    continue
                                }
                            }

                            let away = competition.competitors.first(where: { $0.homeAway == "away" })
                            let home = competition.competitors.first(where: { $0.homeAway == "home" })
                            let awayScore = Int(away?.score ?? "") ?? 0
                            let homeScore = Int(home?.score ?? "") ?? 0
                            if awayScore == homeScore {
                                if isSoccer {
                                    results[matchID] = "Draw"
                                }
                                continue
                            }
                            results[matchID] = awayScore > homeScore ? away?.team.displayName : home?.team.displayName
                        }
                        return results
                    }
                }
            }

            var merged: [String: String] = [:]
            for await partial in group {
                merged.merge(partial) { existing, _ in existing }
            }
            return merged
        }

        // Also check tennis results
        let tennisMatchIDs = matchIDs.filter { $0.hasPrefix("espn-tennis_") }
        if !tennisMatchIDs.isEmpty {
            // Step 1: Try the header API (shows current tournament matches)
            for league in ["atp", "wta"] {
                guard let url = URL(string: "https://site.web.api.espn.com/apis/v2/scoreboard/header?sport=tennis&league=\(league)") else { continue }
                guard let (data, response) = try? await session.data(from: url) else {
                    print("[Pick'em] Tennis API failed for \(league) — skipping")
                    continue
                }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { continue }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let sports = json["sports"] as? [[String: Any]],
                      let sport = sports.first,
                      let leagues = sport["leagues"] as? [[String: Any]],
                      let leagueData = leagues.first,
                      let events = leagueData["events"] as? [[String: Any]] else { continue }

                for event in events {
                    guard let compID = event["competitionId"] as? String ?? (event["competitionId"] as? Int).map({ String($0) }) else { continue }
                    let matchID = "espn-tennis_\(league)-\(compID)"
                    guard tennisMatchIDs.contains(matchID) else { continue }

                    guard let fullStatus = event["fullStatus"] as? [String: Any],
                          let statusType = fullStatus["type"] as? [String: Any],
                          statusType["state"] as? String == "post" else { continue }

                    guard let competitors = event["competitors"] as? [[String: Any]] else { continue }
                    if let winner = competitors.first(where: { ($0["winner"] as? Bool) == true }) {
                        if let winnerName = winner["displayName"] as? String {
                            winnersByMatchID[matchID] = winnerName
                        }
                    }
                }
            }

            // Step 2: For any unresolved tennis matches, try the scoreboard API with date lookback.
            // Fetch all league/day combos in parallel for speed.
            let unresolvedTennis = tennisMatchIDs.filter { winnersByMatchID[$0] == nil }
            if !unresolvedTennis.isEmpty {
                // Collect needed comp IDs per league
                var neededByLeague: [String: Set<String>] = [:]
                for league in ["atp", "wta"] {
                    let leagueUnresolved = unresolvedTennis.filter { $0.contains("_\(league)-") }
                    let compIDs = Set(leagueUnresolved.compactMap { id -> String? in
                        guard let range = id.range(of: "_\(league)-") else { return nil }
                        return String(id[range.upperBound...])
                    })
                    if !compIDs.isEmpty { neededByLeague[league] = compIDs }
                }
                let allNeeded = neededByLeague  // capture for Sendable
                let dateKeys = ESPNDateKeys.last30Days

                // Fetch all league/day combos in parallel
                let tennisResults: [String: String] = await withTaskGroup(of: [String: String].self) { group in
                    for (league, neededCompIDs) in allNeeded {
                        for dateKey in dateKeys {
                            group.addTask { @Sendable in
                                guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/tennis/\(league)/scoreboard?dates=\(dateKey)") else { return [:] }
                                guard let (data, response) = try? await timedSession.data(from: url),
                                      let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [:] }
                                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                      let events = json["events"] as? [[String: Any]] else { return [:] }

                                var results: [String: String] = [:]
                                for event in events {
                                    var allCompetitions: [[String: Any]] = []
                                    if let groupings = event["groupings"] as? [[String: Any]] {
                                        for grouping in groupings {
                                            if let comps = grouping["competitions"] as? [[String: Any]] {
                                                allCompetitions.append(contentsOf: comps)
                                            }
                                        }
                                    }
                                    if let comps = event["competitions"] as? [[String: Any]] {
                                        allCompetitions.append(contentsOf: comps)
                                    }
                                    for competition in allCompetitions {
                                        guard let compID = competition["id"] as? String else { continue }
                                        guard neededCompIDs.contains(compID) else { continue }
                                        guard let status = competition["status"] as? [String: Any],
                                              let statusType = status["type"] as? [String: Any],
                                              statusType["state"] as? String == "post" else { continue }
                                        guard let competitors = competition["competitors"] as? [[String: Any]] else { continue }
                                        if let winner = competitors.first(where: { ($0["winner"] as? Bool) == true }) {
                                            let athleteInfo = winner["athlete"] as? [String: Any]
                                            let winnerName = athleteInfo?["displayName"] as? String
                                                ?? winner["displayName"] as? String
                                                ?? (winner["athlete"] as? [String: Any])?["shortName"] as? String
                                            if let winnerName {
                                                results["espn-tennis_\(league)-\(compID)"] = winnerName
                                            }
                                        }
                                    }
                                }
                                return results
                            }
                        }
                    }
                    var merged: [String: String] = [:]
                    for await partial in group { merged.merge(partial) { existing, _ in existing } }
                    return merged
                }
                winnersByMatchID.merge(tennisResults) { existing, _ in existing }
            }
        }

        // Also resolve Odds API-only matches (prefixed with "odds-")
        // Only tennis matches use "odds-" IDs now, so only check tennis sport keys
        let oddsOnlyMatchIDs = matchIDs.filter { $0.hasPrefix("odds-") }
        if !oddsOnlyMatchIDs.isEmpty {
            // Map "odds-{eventID}" → eventID
            let eventIDsNeeded = Set(oddsOnlyMatchIDs.compactMap { $0.dropFirst(5).description })
            // Only query tennis score keys — all other sports use ESPN fixture IDs
            // Use the cached Odds API active tennis keys, or fetch if needed
            var tennisKeys: [String] = []
            let sportsURL = URL(string: "https://api.the-odds-api.com/v4/sports?apiKey=\(AppSecrets.defaultOddsAPIKey)")!
            if let (sData, sResp) = try? await session.data(from: sportsURL),
               let sHTTP = sResp as? HTTPURLResponse, (200..<300).contains(sHTTP.statusCode),
               let sports = try? JSONDecoder().decode([OddsAPISport].self, from: sData) {
                tennisKeys = sports.filter { $0.active && $0.key.hasPrefix("tennis_") }.map { $0.key }
            }
            for sportKey in tennisKeys {
                guard var components = URLComponents(string: "https://api.the-odds-api.com/v4/sports/\(sportKey)/scores") else { continue }
                components.queryItems = [
                    URLQueryItem(name: "apiKey", value: AppSecrets.defaultOddsAPIKey),
                    URLQueryItem(name: "daysFrom", value: "3"),
                    URLQueryItem(name: "dateFormat", value: "iso"),
                ]
                guard let url = components.url else { continue }
                guard let (data, response) = try? await session.data(from: url),
                      let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { continue }
                guard let events = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
                for event in events {
                    guard let eventID = event["id"] as? String, eventIDsNeeded.contains(eventID) else { continue }
                    guard event["completed"] as? Bool == true else { continue }
                    guard let scores = event["scores"] as? [[String: Any]], scores.count == 2 else { continue }
                    let home = event["home_team"] as? String ?? ""
                    let away = event["away_team"] as? String ?? ""
                    let homeScore = Int(scores.first(where: { ($0["name"] as? String) == home })?["score"] as? String ?? "") ?? 0
                    let awayScore = Int(scores.first(where: { ($0["name"] as? String) == away })?["score"] as? String ?? "") ?? 0
                    let matchID = "odds-\(eventID)"
                    if homeScore == awayScore {
                        if sportKey.hasPrefix("soccer_") { winnersByMatchID[matchID] = "Draw" }
                    } else {
                        winnersByMatchID[matchID] = homeScore > awayScore ? home : away
                    }
                }
            }
        }

        return winnersByMatchID
    }
}

private struct ESPSportDefinition {
    let sportPath: String
    let leaguePath: String
    let displayName: String
    let oddsSportKey: String

    static let majorSports: [ESPSportDefinition] = [
        ESPSportDefinition(sportPath: "basketball", leaguePath: "nba", displayName: "NBA", oddsSportKey: "basketball_nba"),
        ESPSportDefinition(sportPath: "hockey", leaguePath: "nhl", displayName: "NHL", oddsSportKey: "icehockey_nhl"),
        ESPSportDefinition(sportPath: "baseball", leaguePath: "mlb", displayName: "MLB", oddsSportKey: "baseball_mlb"),
        ESPSportDefinition(sportPath: "football", leaguePath: "nfl", displayName: "NFL", oddsSportKey: "americanfootball_nfl"),
        ESPSportDefinition(sportPath: "football", leaguePath: "college-football", displayName: "NCAAF", oddsSportKey: "americanfootball_ncaaf"),
        ESPSportDefinition(sportPath: "basketball", leaguePath: "mens-college-basketball", displayName: "NCAAB", oddsSportKey: "basketball_ncaab"),
        ESPSportDefinition(sportPath: "soccer", leaguePath: "eng.1", displayName: "EPL", oddsSportKey: "soccer_epl"),
        ESPSportDefinition(sportPath: "soccer", leaguePath: "uefa.champions", displayName: "UCL", oddsSportKey: "soccer_uefa_champs_league"),
        ESPSportDefinition(sportPath: "soccer", leaguePath: "fifa.world", displayName: "World Cup", oddsSportKey: "soccer_fifa_world_cup"),
    ]
}

private enum ESPNDateKeys {
    static var todayAndTomorrow: [String] {
        let now = Date()
        let tomorrow = Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: now) ?? now
        return [formatted(now), formatted(tomorrow)]
    }

    static var yesterdayTodayTomorrow: [String] {
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        // Look back 7 days to catch games that may not have been settled promptly
        // (e.g. UCL midweek games that weren't settled over the weekend)
        return ((-7)...1).compactMap { offset in
            cal.date(byAdding: .day, value: offset, to: now).map { formatted($0) }
        }
    }

    /// 30-day lookback for tennis settlement — tennis picks can linger longer
    /// than team sports because tournaments span weeks.
    static var last30Days: [String] {
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        return ((-30)...0).compactMap { offset in
            cal.date(byAdding: .day, value: offset, to: now).map { formatted($0) }
        }
    }

    private static func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
}

struct NoOddsProvider: OddsProvider {
    func fetchOdds(for fixtures: [GameFixture]) async throws -> OddsResult {
        OddsResult(quotesByFixture: [:], extraMatches: [])
    }
}

// MARK: - Supabase Tennis Odds Provider
//
// Reads pre-cached tennis moneylines from the public.tennis_odds table.
// A Supabase Edge Function (refresh-tennis-odds) refreshes the table every
// few minutes from Pinnacle, so the app fetches odds for ALL users with
// exactly one Supabase request — no upstream API quota burn per user.
//
// Falls back gracefully when the table is empty: this provider returns no
// quotes, and `CompositeMatchProvider` already handles "no odds for tennis"
// by skipping the fixture (per the SportsData tennis guard).

private struct SupabaseTennisOddsRow: Codable {
    let id: String
    let league: String
    let home_team: String
    let away_team: String
    let home_moneyline: Int?
    let away_moneyline: Int?
    let starts_at: Date
}

struct SupabaseTennisOddsProvider: OddsProvider {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func fetchOdds(for fixtures: [GameFixture]) async throws -> OddsResult {
        // Only intervene for tennis fixtures — other sports handled elsewhere.
        let tennisFixtures = fixtures.filter { $0.sportKey.hasPrefix("tennis_") }
        guard !tennisFixtures.isEmpty else {
            return OddsResult(quotesByFixture: [:], extraMatches: [])
        }

        // Fetch upcoming tennis odds (starts_at >= now()) from Supabase.
        var components = URLComponents(
            url: SupabaseConfig.url.appending(path: "/rest/v1/tennis_odds"),
            resolvingAgainstBaseURL: false
        )
        let nowISO = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-2 * 3600))
        components?.queryItems = [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "starts_at", value: "gte.\(nowISO)"),
            URLQueryItem(name: "order", value: "starts_at.asc"),
        ]
        guard let url = components?.url else {
            return OddsResult(quotesByFixture: [:], extraMatches: [])
        }
        var request = URLRequest(url: url)
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(SupabaseConfig.publishableKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let rows: [SupabaseTennisOddsRow]
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return OddsResult(quotesByFixture: [:], extraMatches: [])
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            rows = try decoder.decode([SupabaseTennisOddsRow].self, from: data)
        } catch {
            return OddsResult(quotesByFixture: [:], extraMatches: [])
        }

        // Match each fixture to an odds row by fuzzy team-name match.
        var quotesByFixture: [String: [OddsQuote]] = [:]
        for fixture in tennisFixtures {
            guard let row = rows.first(where: { row in
                Self.namesMatch(row.home_team, fixture.homeTeam)
                    && Self.namesMatch(row.away_team, fixture.awayTeam)
            }) ?? rows.first(where: { row in
                // Also try swapped home/away — Pinnacle and ESPN sometimes
                // disagree on which player is "home" vs "away" in tennis.
                Self.namesMatch(row.home_team, fixture.awayTeam)
                    && Self.namesMatch(row.away_team, fixture.homeTeam)
            }) else { continue }
            guard let homeML = row.home_moneyline, let awayML = row.away_moneyline else { continue }
            // Map odds back to the ESPN-fixture's home/away convention.
            let homeMatchesRowHome = Self.namesMatch(row.home_team, fixture.homeTeam)
            let oddsForFixtureHome = Double(homeMatchesRowHome ? homeML : awayML)
            let oddsForFixtureAway = Double(homeMatchesRowHome ? awayML : homeML)
            let quotes = Self.rrQuotesFromTwoWay(
                teamA: fixture.awayTeam, oddsA: oddsForFixtureAway,
                teamB: fixture.homeTeam, oddsB: oddsForFixtureHome
            )
            if !quotes.isEmpty {
                quotesByFixture[fixture.id] = quotes
            }
        }

        return OddsResult(quotesByFixture: quotesByFixture, extraMatches: [])
    }

    // MARK: - Helpers (duplicated from CompositeMatchProvider — kept private
    // so this provider is self-contained.)

    private static func namesMatch(_ a: String, _ b: String) -> Bool {
        let na = normalize(a)
        let nb = normalize(b)
        if na == nb { return true }
        // Last-name fallback for "Carlos Alcaraz" vs "Alcaraz"
        if let la = na.split(separator: " ").last,
           let lb = nb.split(separator: " ").last,
           la == lb, la.count >= 4 {
            return true
        }
        return false
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func rrQuotesFromTwoWay(
        teamA: String, oddsA: Double,
        teamB: String, oddsB: Double
    ) -> [OddsQuote] {
        let pA = impliedProb(oddsA)
        let pB = impliedProb(oddsB)
        guard pA > 0, pB > 0 else { return [] }
        let swing = max(12, min(240, Int(((abs(oddsA) + abs(oddsB)) / 20.0).rounded())))
        let fixed = 10
        let aIsFavorite = pA >= pB
        let quoteA = aIsFavorite
            ? OddsQuote(team: teamA, gainRR: fixed, lossRR: swing)
            : OddsQuote(team: teamA, gainRR: swing, lossRR: fixed)
        let quoteB = aIsFavorite
            ? OddsQuote(team: teamB, gainRR: swing, lossRR: fixed)
            : OddsQuote(team: teamB, gainRR: fixed, lossRR: swing)
        return [quoteA, quoteB]
    }

    private static func impliedProb(_ americanOdds: Double) -> Double {
        if americanOdds > 0 { return 100.0 / (americanOdds + 100.0) }
        return abs(americanOdds) / (abs(americanOdds) + 100.0)
    }
}

// MARK: - Composite tennis-first odds provider
//
// Tries the Supabase-backed tennis cache first; for any tennis fixtures it
// didn't cover (and for non-tennis fixtures), falls back to the wrapped
// provider (Odds API). Once Supabase cron has been running for a tournament
// cycle, the fallback rarely fires and you can drop the Odds API subscription.

struct CompositeOddsProvider: OddsProvider {
    let primary: OddsProvider
    let fallback: OddsProvider

    func fetchOdds(for fixtures: [GameFixture]) async throws -> OddsResult {
        let primaryResult = (try? await primary.fetchOdds(for: fixtures))
            ?? OddsResult(quotesByFixture: [:], extraMatches: [])

        // Which fixtures still need odds after the primary pass?
        let coveredIDs = Set(primaryResult.quotesByFixture.keys)
        let uncoveredFixtures = fixtures.filter { !coveredIDs.contains($0.id) }
        if uncoveredFixtures.isEmpty {
            return primaryResult
        }

        let fallbackResult = (try? await fallback.fetchOdds(for: uncoveredFixtures))
            ?? OddsResult(quotesByFixture: [:], extraMatches: [])

        // Merge: primary wins on conflict (it shouldn't be any conflicts since
        // we only asked the fallback about uncovered fixtures, but just in case).
        var merged = primaryResult.quotesByFixture
        for (k, v) in fallbackResult.quotesByFixture where merged[k] == nil {
            merged[k] = v
        }
        let mergedExtra = primaryResult.extraMatches + fallbackResult.extraMatches
        return OddsResult(quotesByFixture: merged, extraMatches: mergedExtra)
    }
}

/// Cache for ESPN Core API moneylines keyed by event ID.
/// Odds rarely change — 10 minute TTL avoids re-fetching every 45s refresh.
private final class CoreAPIOddsCache {
    static let shared = CoreAPIOddsCache()
    private var cache: [String: (away: Double, home: Double)] = [:]
    private var cachedAt: Date = .distantPast
    private let ttl: TimeInterval = 10 * 60  // 10 minutes

    func get(_ eventID: String) -> (away: Double, home: Double)? {
        guard Date().timeIntervalSince(cachedAt) < ttl else {
            cache.removeAll()
            return nil
        }
        return cache[eventID]
    }

    func set(_ eventID: String, away: Double, home: Double) {
        if cache.isEmpty { cachedAt = Date() }
        cache[eventID] = (away: away, home: home)
    }
}

/// Cache for Odds API results to avoid burning credits on every 45-second refresh.
/// Tennis odds don't move fast — 15-minute TTL is plenty.
private final class OddsAPICache {
    static let shared = OddsAPICache()
    private var cachedResult: OddsResult?
    private var cachedAt: Date = .distantPast
    private let ttl: TimeInterval = 30 * 60  // 30 minutes

    func get() -> OddsResult? {
        guard Date().timeIntervalSince(cachedAt) < ttl else { return nil }
        return cachedResult
    }

    func set(_ result: OddsResult) {
        cachedResult = result
        cachedAt = Date()
    }
}

struct TheOddsAPIProvider: OddsProvider {
    let apiKey: String
    private let session: URLSession

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    func fetchOdds(for fixtures: [GameFixture]) async throws -> OddsResult {
        guard !apiKey.isEmpty else {
            throw SportsDataError.missingAPIKey
        }

        // Return cached result if still fresh — saves Odds API credits
        if let cached = OddsAPICache.shared.get() {
            return cached
        }

        var oddsByFixture: [String: [OddsQuote]] = [:]
        let sportKeys = Set(fixtures.map { $0.sportKey })

        // Only use The Odds API for tennis — ESPN already provides moneylines
        // for NBA, NHL, MLB, soccer, NCAAB etc. so spending credits on those
        // is wasteful. Reserve the Odds API budget for tennis only.
        let tennisPrefixes = sportKeys.filter { $0.hasPrefix("tennis_") }
        let allSportKeys = tennisPrefixes  // only tennis goes through Odds API

        var resolvedTennisKeys: [String: [String]] = [:]  // prefix → [actual API keys]
        if !tennisPrefixes.isEmpty {
            let actualKeys = await fetchActiveTennisSportKeys()
            for prefix in tennisPrefixes {
                resolvedTennisKeys[prefix] = actualKeys.filter { $0.hasPrefix(prefix) }
            }
        }

        // Build list of all API sport keys we need to query (tennis only)
        var allAPIKeys: [String] = []
        for sportKey in allSportKeys {
            if let resolved = resolvedTennisKeys[sportKey], !resolved.isEmpty {
                allAPIKeys.append(contentsOf: resolved)
            }
        }

        // Fetch odds sequentially to avoid @MainActor isolation issues with TaskGroup
        var eventsBySportPrefix: [String: [OddsEvent]] = [:]
        for (index, apiSportKey) in allAPIKeys.enumerated() {
            if index > 0 {
                try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s between requests
            }
            guard let url = oddsURL(for: apiSportKey) else { continue }
            guard let data = await fetchWithRateLimitRetry(url: url) else { continue }
            if let events = try? JSONDecoder.oddsDecoder.decode([OddsEvent].self, from: data), !events.isEmpty {
                let prefix = allSportKeys.first(where: { apiSportKey.hasPrefix($0) }) ?? apiSportKey
                eventsBySportPrefix[prefix, default: []].append(contentsOf: events)
            }
        }

        // Match fixtures to odds events and track which events got matched
        var matchedEventIDs: Set<String> = []
        for sportKey in allSportKeys {
            let allEvents = eventsBySportPrefix[sportKey] ?? []
            guard !allEvents.isEmpty else { continue }

            let sportFixtures = fixtures.filter { $0.sportKey == sportKey }
            for fixture in sportFixtures {
                guard let matchingEvent = allEvents.first(where: { event in
                    teamsMatch(fixture: fixture, event: event)
                }) else {
                    continue
                }

                matchedEventIDs.insert(matchingEvent.id)
                if let quotes = quotesFromEvent(matchingEvent, awayTeam: fixture.awayTeam, homeTeam: fixture.homeTeam, sportKey: fixture.sportKey) {
                    oddsByFixture[fixture.id] = quotes
                }
            }
        }

        // Create extra matches from Odds API events that had no ESPN fixture
        var extraMatches: [Match] = []
        var sportDisplayNames = Dictionary(uniqueKeysWithValues: ESPSportDefinition.majorSports.map { ($0.oddsSportKey, $0.displayName) })
        sportDisplayNames["tennis_atp"] = "ATP"
        sportDisplayNames["tennis_wta"] = "WTA"

        for (sportPrefix, events) in eventsBySportPrefix {
            let league = sportDisplayNames[sportPrefix] ?? sportPrefix
            for event in events {
                guard !matchedEventIDs.contains(event.id) else { continue }
                guard event.commenceTime > Date() else { continue } // Only upcoming games

                if let quotes = quotesFromEvent(event, awayTeam: event.awayTeam, homeTeam: event.homeTeam, sportKey: sportPrefix) {
                    let matchID = "odds-\(event.id)"
                    let match = Match(
                        id: matchID,
                        league: league,
                        awayTeam: event.awayTeam,
                        homeTeam: event.homeTeam,
                        startsAt: event.commenceTime,
                        state: "pre",
                        statusDetail: "Scheduled",
                        awayScore: nil,
                        homeScore: nil,
                        options: quotes.map { PickOption(team: $0.team, gainRR: $0.gainRR, lossRR: $0.lossRR) }
                    )
                    extraMatches.append(match)
                }
            }
        }

        let result = OddsResult(quotesByFixture: oddsByFixture, extraMatches: extraMatches)
        OddsAPICache.shared.set(result)
        return result
    }

    /// Converts an OddsEvent's h2h outcomes into OddsQuotes. Handles both 2-way and 3-way (soccer Draw) markets.
    private func quotesFromEvent(_ event: OddsEvent, awayTeam: String, homeTeam: String, sportKey: String) -> [OddsQuote]? {
        let outcomes = event.primaryHeadToHeadOutcomes ?? []
        let awayKey = canonicalTeamKey(awayTeam)
        let homeKey = canonicalTeamKey(homeTeam)
        let awayLast = lastNameKey(awayTeam)
        let homeLast = lastNameKey(homeTeam)
        let isTennis = sportKey.hasPrefix("tennis_")
        let isSoccer = sportKey.hasPrefix("soccer_")

        var awayPrice: Double?
        var homePrice: Double?
        var drawPrice: Double?

        for outcome in outcomes {
            let outcomeKey = canonicalTeamKey(outcome.name)
            if outcome.name.lowercased() == "draw" {
                drawPrice = outcome.price
            } else if outcomeKey == awayKey {
                awayPrice = outcome.price
            } else if outcomeKey == homeKey {
                homePrice = outcome.price
            } else if isTennis {
                let outcomeLast = lastNameKey(outcome.name)
                if outcomeLast == awayLast { awayPrice = outcome.price }
                else if outcomeLast == homeLast { homePrice = outcome.price }
            }
        }

        guard let aPrice = awayPrice, let hPrice = homePrice else { return nil }

        // For soccer 3-way: each outcome has independent odds, so compute RR individually.
        // Negative odds = favorite for that outcome → +10 / -swing
        // Positive odds = underdog for that outcome → +swing / -10
        // Swing = |odds| / 10, clamped [12, 80]
        if isSoccer, let dPrice = drawPrice {
            // De-vig the book's 3-way prices so picks quote fair odds.
            let fair = devigThreeWayOdds(away: aPrice, draw: dPrice, home: hPrice)
            let awayQuote = rrQuoteFromIndividualOdds(team: awayTeam, odds: fair.away)
            let homeQuote = rrQuoteFromIndividualOdds(team: homeTeam, odds: fair.home)
            let drawQuote = rrQuoteFromIndividualOdds(team: "Draw", odds: fair.draw)
            return [awayQuote, drawQuote, homeQuote]
        }

        // Standard 2-way: shared swing, fav +10/-swing, dog +swing/-10
        var quotes = rrQuotesFromTwoWayAmericanOdds(teamA: awayTeam, oddsA: aPrice, teamB: homeTeam, oddsB: hPrice)
        guard quotes.count == 2 else { return nil }

        return quotes
    }

    /// Fetches active sport keys from The Odds API that start with "tennis_"
    private func fetchActiveTennisSportKeys() async -> [String] {
        guard let url = URL(string: "https://api.the-odds-api.com/v4/sports?apiKey=\(apiKey)") else {
            return []
        }
        guard let data = await fetchWithRateLimitRetry(url: url) else {
            return []
        }
        guard let sports = try? JSONDecoder().decode([OddsAPISport].self, from: data) else {
            return []
        }
        return sports.filter { $0.active && $0.key.hasPrefix("tennis_") }.map { $0.key }
    }

    /// Fetches data from a URL with automatic retry on 429 (rate limit) responses.
    private func fetchWithRateLimitRetry(url: URL, maxRetries: Int = 3) async -> Data? {
        for attempt in 0...maxRetries {
            if attempt > 0 {
                let backoff = UInt64(attempt * 2) * 1_000_000_000
                try? await Task.sleep(nanoseconds: backoff)
            }

            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse else { return nil }
                if (200..<300).contains(http.statusCode) { return data }
                if http.statusCode == 429 { continue }
                return nil
            } catch {
                return nil
            }
        }
        return nil
    }

    private func oddsURL(for sportKey: String) -> URL? {
        var components = URLComponents(string: "https://api.the-odds-api.com/v4/sports/\(sportKey)/odds")
        components?.queryItems = [
            URLQueryItem(name: "apiKey", value: apiKey),
            URLQueryItem(name: "regions", value: "us"),
            URLQueryItem(name: "markets", value: "h2h"),
            URLQueryItem(name: "oddsFormat", value: "american"),
            URLQueryItem(name: "dateFormat", value: "iso")
        ]
        return components?.url
    }

    private func teamsMatch(fixture: GameFixture, event: OddsEvent) -> Bool {
        let fixtureTeams = Set([canonicalTeamKey(fixture.awayTeam), canonicalTeamKey(fixture.homeTeam)])
        let eventTeams = Set([canonicalTeamKey(event.awayTeam), canonicalTeamKey(event.homeTeam)])
        if fixtureTeams == eventTeams { return true }

        // For tennis: try last-name matching since ESPN and Odds API may format names differently
        if fixture.sportKey.hasPrefix("tennis_") {
            let fixtureLast = Set([lastNameKey(fixture.awayTeam), lastNameKey(fixture.homeTeam)])
            let eventLast = Set([lastNameKey(event.awayTeam), lastNameKey(event.homeTeam)])
            return fixtureLast == eventLast && fixtureLast.count == 2
        }

        // For soccer: team names differ significantly between ESPN and Odds API
        // (e.g. "Sporting CP" vs "Sporting Lisbon", "PSG" vs "Paris Saint Germain")
        // Use first-word matching as a fuzzy fallback — if both teams' first words match, it's likely the same game
        if fixture.sportKey.hasPrefix("soccer_") {
            let fixtureFirst = Set([firstWordKey(fixture.awayTeam), firstWordKey(fixture.homeTeam)])
            let eventFirst = Set([firstWordKey(event.awayTeam), firstWordKey(event.homeTeam)])
            if fixtureFirst == eventFirst && fixtureFirst.count == 2 { return true }
            // Also try substring matching: if one name contains the other's first significant word
            let fixtureNames = [fixture.awayTeam.lowercased(), fixture.homeTeam.lowercased()]
            let eventNames = [event.awayTeam.lowercased(), event.homeTeam.lowercased()]
            let matchedCount = fixtureNames.filter { fn in
                eventNames.contains(where: { en in fn.contains(en.prefix(6)) || en.contains(fn.prefix(6)) })
            }.count
            return matchedCount == 2
        }

        return false
    }

    private func firstWordKey(_ name: String) -> String {
        var cleaned = name.lowercased()
        for (from, to) in [("ø", "o"), ("æ", "ae"), ("å", "a"), ("ð", "d")] {
            cleaned = cleaned.replacingOccurrences(of: from, with: to)
        }
        cleaned = cleaned.folding(options: .diacriticInsensitive, locale: .init(identifier: "en"))
        cleaned = cleaned.replacingOccurrences(of: "[^a-z ]", with: "", options: .regularExpression)
        let words = cleaned.split(separator: " ").filter { $0.count > 2 } // Skip short words like "FC", "CF"
        if let first = words.first { return String(first) }
        return cleaned.replacingOccurrences(of: " ", with: "")
    }

    private func lastNameKey(_ name: String) -> String {
        let parts = name.lowercased()
            .replacingOccurrences(of: #"^no\.\s*\d+\s+"#, with: "", options: .regularExpression)
            .split(separator: " ")
        let last = parts.last.map(String.init) ?? name.lowercased()
        return last.replacingOccurrences(of: "[^a-z]", with: "", options: .regularExpression)
    }

    private func canonicalTeamKey(_ value: String) -> String {
        var normalized = value.lowercased()
        // Normalize special characters (Nordic ø/æ/å, accented chars, etc.)
        normalized = normalized.folding(options: .diacriticInsensitive, locale: .init(identifier: "en"))
        for (from, to) in [("ø", "o"), ("æ", "ae"), ("å", "a"), ("ð", "d"), ("ß", "ss")] {
            normalized = normalized.replacingOccurrences(of: from, with: to)
        }
        normalized = normalized.replacingOccurrences(of: "st.", with: "saint")
        normalized = normalized.replacingOccurrences(of: "st ", with: "saint ")
        normalized = normalized.replacingOccurrences(of: "la ", with: "los angeles ")
        normalized = normalized.replacingOccurrences(of: #"^no\.\s*\d+\s+"#, with: "", options: .regularExpression)
        normalized = normalized.replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
        return normalized
    }

    private func rrQuotesFromTwoWayAmericanOdds(
        teamA: String,
        oddsA: Double,
        teamB: String,
        oddsB: Double
    ) -> [OddsQuote] {
        let pA = impliedProbability(from: oddsA)
        let pB = impliedProbability(from: oddsB)
        guard pA > 0, pB > 0 else { return [] }

        // Swing = how many RR the underdog gains (and favorite risks).
        // Based on combined absolute American odds divided by 20, clamped [12, 240].
        // Favorite always gets +10 gain, underdog always gets -10 loss.
        // E.g. -305/+245 → (305+245)/20 = 28, -5000/+2500 → 375 → capped at 240
        let swing = clamp(Int(((abs(oddsA) + abs(oddsB)) / 20.0).rounded()), min: 12, max: 240)
        let fixed = 10
        let aIsFavorite = pA >= pB

        let quoteA = aIsFavorite
            ? OddsQuote(team: teamA, gainRR: fixed, lossRR: swing)
            : OddsQuote(team: teamA, gainRR: swing, lossRR: fixed)
        let quoteB = aIsFavorite
            ? OddsQuote(team: teamB, gainRR: swing, lossRR: fixed)
            : OddsQuote(team: teamB, gainRR: fixed, lossRR: swing)
        return [quoteA, quoteB]
    }

    private func impliedProbability(from americanOdds: Double) -> Double {
        if americanOdds > 0 {
            return 100.0 / (americanOdds + 100.0)
        }
        return abs(americanOdds) / (abs(americanOdds) + 100.0)
    }

    /// Computes RR for a single 3-way outcome based on its own American odds.
    /// Negative odds (favorite): +10 / -swing.  Positive odds (underdog): +swing / -10.
    /// Swing = |odds| / 10, clamped [12, 160].
    /// E.g. -190 → swing=19 → +10/-19.  +105 → swing=12 → +12/-10.  +500 → swing=50 → +50/-10.
    private func rrQuoteFromIndividualOdds(team: String, odds: Double) -> OddsQuote {
        let swing = clamp(Int((abs(odds) / 10.0).rounded()), min: 12, max: 160)
        if odds < 0 {
            // Favorite: gain +10, risk swing
            return OddsQuote(team: team, gainRR: 10, lossRR: swing)
        } else {
            // Underdog (or even money): gain swing, risk 10
            return OddsQuote(team: team, gainRR: swing, lossRR: 10)
        }
    }

    private func clamp(_ value: Int, min: Int, max: Int) -> Int {
        Swift.max(min, Swift.min(max, value))
    }
}

// MARK: - Tennis

struct ESPNTennisGameProvider: GameProvider {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchGames() async throws -> [GameFixture] {
        var fixtures: [GameFixture] = []

        for league in [("atp", "ATP"), ("wta", "WTA")] {
            guard let url = URL(string: "https://site.web.api.espn.com/apis/v2/scoreboard/header?sport=tennis&league=\(league.0)") else { continue }
            let data: Data
            do {
                let (d, r) = try await session.data(from: url)
                guard let http = r as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { continue }
                data = d
            } catch {
                print("[Pick'em] ESPN Tennis \(league.1) fetch failed: \(error.localizedDescription)")
                continue
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sports = json["sports"] as? [[String: Any]],
                  let sport = sports.first,
                  let leagues = sport["leagues"] as? [[String: Any]],
                  let leagueData = leagues.first,
                  let events = leagueData["events"] as? [[String: Any]] else { continue }

            for event in events {
                guard let compID = event["competitionId"] as? String ?? (event["competitionId"] as? Int).map({ String($0) }) else { continue }
                guard let competitors = event["competitors"] as? [[String: Any]], competitors.count == 2 else { continue }

                // Skip doubles matches (names contain " / ")
                let names = competitors.compactMap { $0["displayName"] as? String }
                guard names.count == 2, !names.contains(where: { $0.contains(" / ") }) else { continue }

                guard let fullStatus = event["fullStatus"] as? [String: Any],
                      let statusType = fullStatus["type"] as? [String: Any],
                      let state = statusType["state"] as? String else { continue }
                guard state == "pre" || state == "in" || state == "post" else { continue }

                let detail = statusType["shortDetail"] as? String ?? statusType["detail"] as? String ?? state.uppercased()

                let dateString = event["date"] as? String ?? ""
                let date = ESPNDateParsers.withSecondsUTC.date(from: dateString)
                    ?? ESPNDateParsers.noSecondsUTC.date(from: dateString)
                    ?? Date()

                let away = competitors.first(where: { ($0["homeAway"] as? String) == "away" }) ?? competitors[1]
                let home = competitors.first(where: { ($0["homeAway"] as? String) == "home" }) ?? competitors[0]

                let awayName = away["displayName"] as? String ?? "Player 1"
                let homeName = home["displayName"] as? String ?? "Player 2"

                // Parse scores (sets won) when available
                let awayScoreStr = away["score"] as? String
                let homeScoreStr = home["score"] as? String
                let awayScore = awayScoreStr.flatMap { Int($0) } ?? (away["score"] as? Int)
                let homeScore = homeScoreStr.flatMap { Int($0) } ?? (home["score"] as? Int)

                // Extract ATP/WTA rankings to estimate moneylines.
                // Rank 0 means "unknown" — default relative to opponent's rank
                // so lines stay reasonable for lower-tier WTA/ATP events.
                let rawAwayRank = (away["rank"] as? Int) ?? 0
                let rawHomeRank = (home["rank"] as? Int) ?? 0
                let awayRank = rawAwayRank > 0 ? rawAwayRank : defaultUnrankedRank(opponentRank: rawHomeRank)
                let homeRank = rawHomeRank > 0 ? rawHomeRank : defaultUnrankedRank(opponentRank: rawAwayRank)
                let (awayML, homeML) = estimateMoneylineFromRanks(
                    rankA: awayRank,
                    rankB: homeRank
                )

                let fixtureID = "espn-tennis_\(league.0)-\(compID)"

                fixtures.append(
                    GameFixture(
                        id: fixtureID,
                        sportKey: "tennis_\(league.0)",
                        league: league.1,
                        awayTeam: awayName,
                        homeTeam: homeName,
                        startsAt: date,
                        state: state,
                        statusDetail: detail,
                        awayScore: awayScore,
                        homeScore: homeScore,
                        awayWinPct: nil,
                        homeWinPct: nil,
                        awayMoneyline: awayML,
                        homeMoneyline: homeML
                    )
                )
            }
        }

        return fixtures.sorted(by: { $0.startsAt < $1.startsAt })
    }

    /// When a player's rank is 0 (unknown), estimate a reasonable default
    /// relative to their opponent. Unranked qualifiers at smaller events are
    /// typically 2-3 tiers below the seeded player, not rank 200.
    private func defaultUnrankedRank(opponentRank: Int) -> Int {
        guard opponentRank > 0 else { return 80 }  // both unknown → roughly mid-tier
        // Unranked player is roughly 2.5× worse than opponent, clamped [30, 150]
        return max(30, min(150, Int(Double(opponentRank) * 2.5)))
    }

    /// Estimates American moneylines from ATP/WTA rankings.
    /// Uses a log-ratio model: higher-ranked player (lower number) is favored.
    ///
    /// Scaling factor of 0.6 calibrated against real moneylines:
    ///   Rank 4 vs 21  → ~73%  → -266  (Zverev vs Tiafoe actual)
    ///   Rank 2 vs 50  → ~87%  → -680
    ///   Rank 3 vs 7   → ~62%  → -165
    ///   Rank 10 vs 10 → 50%   → pick'em
    private func estimateMoneylineFromRanks(rankA: Int, rankB: Int) -> (Double, Double) {
        let rA = max(1.0, Double(rankA))
        let rB = max(1.0, Double(rankB))

        let logRatio = log(rB / rA)  // positive when A is favored
        let probA = 1.0 / (1.0 + exp(-logRatio * 0.6))
        let probB = 1.0 - probA

        func americanOdds(from prob: Double) -> Double {
            let p = max(0.08, min(0.92, prob))
            if p >= 0.5 {
                return -((p / (1.0 - p)) * 100.0)
            }
            return ((1.0 - p) / p) * 100.0
        }

        return (americanOdds(from: probA), americanOdds(from: probB))
    }
}

struct MockGameProvider: GameProvider {
    func fetchGames() async throws -> [GameFixture] {
        [
            GameFixture(
                id: "mock-nhl-pit-bos",
                sportKey: "icehockey_nhl",
                league: "NHL",
                awayTeam: "Pittsburgh Penguins",
                homeTeam: "Boston Bruins",
                startsAt: .now.addingTimeInterval(60 * 60 * 3),
                state: "pre",
                statusDetail: "Scheduled",
                awayScore: nil,
                homeScore: nil,
                awayWinPct: 0.47,
                homeWinPct: 0.61,
                awayMoneyline: 210,
                homeMoneyline: -260
            ),
            GameFixture(
                id: "mock-nba-lal-bos",
                sportKey: "basketball_nba",
                league: "NBA",
                awayTeam: "Los Angeles Lakers",
                homeTeam: "Boston Celtics",
                startsAt: .now.addingTimeInterval(60 * 60 * 5),
                state: "pre",
                statusDetail: "Scheduled",
                awayScore: nil,
                homeScore: nil,
                awayWinPct: 0.52,
                homeWinPct: 0.66,
                awayMoneyline: 160,
                homeMoneyline: -185
            )
        ]
    }
}

struct MockOddsProvider: OddsProvider {
    func fetchOdds(for fixtures: [GameFixture]) async throws -> OddsResult {
        var result: [String: [OddsQuote]] = [:]
        for fixture in fixtures {
            result[fixture.id] = [
                OddsQuote(team: fixture.awayTeam, gainRR: 24, lossRR: 18),
                OddsQuote(team: fixture.homeTeam, gainRR: 18, lossRR: 24)
            ]
        }
        return OddsResult(quotesByFixture: result, extraMatches: [])
    }
}

struct MockMatchProvider: MatchProvider {
    private let gameProvider: GameProvider
    private let oddsProvider: OddsProvider

    init(gameProvider: GameProvider = MockGameProvider(), oddsProvider: OddsProvider = MockOddsProvider()) {
        self.gameProvider = gameProvider
        self.oddsProvider = oddsProvider
    }

    func fetchMatches() async throws -> [Match] {
        try await CompositeMatchProvider(gameProvider: gameProvider, oddsProvider: oddsProvider).fetchMatches()
    }
}

private struct ESPNScoreboardResponse: Codable {
    let leagues: [ESPNLeague]
    let events: [ESPNEvent]
}

private struct ESPNLeague: Codable {
    let abbreviation: String
}

private struct ESPNEvent: Codable {
    let id: String
    let date: Date
    let competitions: [ESPNCompetition]
}

private struct ESPNCompetition: Codable {
    let status: ESPNCompetitionStatus
    let competitors: [ESPNCompetitor]
    let odds: [ESPNCompetitionOdds]?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(ESPNCompetitionStatus.self, forKey: .status)
        competitors = try container.decode([ESPNCompetitor].self, forKey: .competitors)
        // ESPN sometimes returns [null] in the odds array — decode each element individually
        if var oddsContainer = try? container.nestedUnkeyedContainer(forKey: .odds) {
            var decoded: [ESPNCompetitionOdds] = []
            while !oddsContainer.isAtEnd {
                if let item = try? oddsContainer.decode(ESPNCompetitionOdds.self) {
                    decoded.append(item)
                } else {
                    // Skip null or malformed entries
                    _ = try? oddsContainer.decode(AnyCodable.self)
                }
            }
            odds = decoded.isEmpty ? nil : decoded
        } else {
            odds = nil
        }
    }

    private struct AnyCodable: Codable {}
}

private struct ESPNCompetitionStatus: Codable {
    let type: ESPNCompetitionStatusType
}

private struct ESPNCompetitionStatusType: Codable {
    let state: String
    let detail: String?
    let shortDetail: String?
}

private struct ESPNCompetitor: Codable {
    let homeAway: String
    let score: String?
    let winner: Bool?
    let records: [ESPNRecord]?
    let team: ESPNCompetitorTeam
}

private struct ESPNRecord: Codable {
    let summary: String?
}

private struct ESPNCompetitorTeam: Codable {
    let displayName: String
}

private struct ESPNCompetitionOdds: Codable {
    let moneyline: ESPNMoneyline?
}

private struct ESPNMoneyline: Codable {
    let away: ESPNOddsSide?
    let home: ESPNOddsSide?
    /// Present for soccer 3-way markets.
    let draw: ESPNOddsSide?
}

private struct ESPNOddsSide: Codable {
    let close: ESPNOddsClose?
}

private struct ESPNOddsClose: Codable {
    let odds: String?
}

private struct OddsAPISport: Codable {
    let key: String
    let active: Bool
}

private struct OddsEvent: Codable {
    let id: String
    let sportKey: String
    let commenceTime: Date
    let awayTeam: String
    let homeTeam: String
    let bookmakers: [OddsBookmaker]

    var primaryHeadToHeadOutcomes: [OddsOutcome]? {
        bookmakers
            .first?
            .markets
            .first(where: { $0.key == "h2h" })?
            .outcomes
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sportKey = "sport_key"
        case commenceTime = "commence_time"
        case awayTeam = "away_team"
        case homeTeam = "home_team"
        case bookmakers
    }
}

private struct OddsBookmaker: Codable {
    let markets: [OddsMarket]
}

private struct OddsMarket: Codable {
    let key: String
    let outcomes: [OddsOutcome]
}

private struct OddsOutcome: Codable {
    let name: String
    let price: Double
}

private extension JSONDecoder {
    static var espnDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { container in
            let value = try container.singleValueContainer().decode(String.self)
            if let date = ESPNDateParsers.noSecondsUTC.date(from: value) {
                return date
            }
            if let date = ESPNDateParsers.withSecondsUTC.date(from: value) {
                return date
            }
            if let date = ESPNDateParsers.withFractionalSeconds.date(from: value) {
                return date
            }
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Unsupported ESPN date format: \(value)"
                )
            )
        }
        return decoder
    }

    static var oddsDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private enum ESPNDateParsers {
    static let noSecondsUTC: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
        return formatter
    }()

    static let withSecondsUTC: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter
    }()

    static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
