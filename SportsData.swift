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
    /// Home-team point spread (e.g. -1.5) from ESPN's odds block.
    var spreadHome: Double? = nil
    /// Full-game over/under line from ESPN's odds block.
    var overUnder: Double? = nil
    /// Per-side American prices for the spread and total, when available.
    var spreadAwayOdds: Double? = nil
    var spreadHomeOdds: Double? = nil
    var overOdds: Double? = nil
    var underOdds: Double? = nil
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

// MARK: - Derived Pick'em markets (spread / total / props)
//
// Each extra market is its own Match with a suffixed id so the existing
// pick, sync, and settle pipeline needs no schema changes:
//   "<baseID>|sprd|<homeLine>"                    options "Team -1.5" / "Team +1.5"
//   "<baseID>|tot|<line>"                         options "Over 9.5" / "Under 9.5"
//   "<baseID>|prop|<athleteID>|<statKey>|<line>"  options "Over 0.5" / "Under 0.5"
// The line is snapshotted into the id + option strings at fetch time, so a
// later line move can never regrade an existing pick. Winner "PUSH" settles
// as result "expired" with 0 RR.

func pickemFormatLine(_ v: Double) -> String {
    v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
}

func pickemSignedLine(_ v: Double) -> String {
    v >= 0 ? "+\(pickemFormatLine(v))" : "-\(pickemFormatLine(abs(v)))"
}

func isDerivedPickemMatchID(_ id: String) -> Bool { id.contains("|") }

/// RR quote pair for a one-sided milestone prop (e.g. "to hit a HR" at
/// +300). Books shade longshots hard (favorite-longshot bias): a +300
/// Yes typically pairs with a -500/-600 No, so the fair price sits near
/// the odds-space midpoint of +300 and +500/+600 — about 1.4x the
/// posted plus odds, NOT a mere ~6% trim. Near-even one-sided prices
/// fall back to a mild proportional devig.
func pickemOneSidedQuotes(yesOdds: Double, yesName: String, noName: String, eventPropShade: Bool = false) -> [PickOption] {
    let fairOdds: Double
    if eventPropShade {
        // Event props ("to homer", "to score a TD"): books hide a much
        // bigger margin than moneylines, but it SCALES with the implied
        // probability — ~7 points on an Ohtani-tier ~35% price, only
        // ~4.5 on a Yandy-Diaz-tier ~14% (true ~9.5%). A flat 7-point
        // subtract overpaid Yes on low-power longshots (+127 quoted
        // where fair was ~+90). Margin = 30% of implied, capped at 7pts.
        let pImplied = pickemImpliedProb(yesOdds)
        let margin = min(0.07, 0.30 * pImplied)
        let pFair = min(0.99, max(0.02, pImplied - margin))
        fairOdds = pickemAmericanOdds(fromProb: pFair)
    } else if yesOdds >= 100 {
        // Longshot shade calibrated against real DK two-sided pairs:
        // -172/+141 has its juice-free middle at ~+156 (1.10x the dog),
        // -710/+486 at ~+600 (1.24x) — so scale from 1.10 at +100 to
        // 1.24 at +500 and hold there. (1.4x proved too aggressive.)
        let scale = 1.10 + 0.14 * min(1.0, max(0.0, (yesOdds - 100.0) / 400.0))
        fairOdds = yesOdds * scale
    } else {
        let pFair = max(0.01, min(0.99, pickemImpliedProb(yesOdds) / 1.06))
        fairOdds = pickemAmericanOdds(fromProb: pFair)
    }
    let pFair = pickemImpliedProb(fairOdds)
    let swing = max(10, min(240, Int((abs(fairOdds) / 10.0).rounded())))
    if pFair < 0.5 {
        return [PickOption(team: yesName, gainRR: swing, lossRR: 10),
                PickOption(team: noName, gainRR: 10, lossRR: swing)]
    }
    return [PickOption(team: yesName, gainRR: 10, lossRR: swing),
            PickOption(team: noName, gainRR: swing, lossRR: 10)]
}

func pickemYesNoQuotes(yesOdds: Double) -> [PickOption] {
    pickemOneSidedQuotes(yesOdds: yesOdds, yesName: "Yes", noName: "No", eventPropShade: true)
}

func pickemImpliedProb(_ odds: Double) -> Double {
    odds > 0 ? 100.0 / (odds + 100.0) : abs(odds) / (abs(odds) + 100.0)
}

func pickemAmericanOdds(fromProb p: Double) -> Double {
    p >= 0.5 ? -100.0 * p / (1.0 - p) : 100.0 * (1.0 - p) / p
}

/// Two-way RR quotes from a pair of book prices, DEVIGGED: the implied
/// probabilities are normalized to sum to 1 (the "in between" of the
/// juice) and RR swings derive from the fair odds — so neither side of
/// a juiced market is systematically +EV.
func pickemTwoWayQuotes(nameA: String, oddsA: Double, nameB: String, oddsB: Double) -> [PickOption] {
    let pA = pickemImpliedProb(oddsA)
    let pB = pickemImpliedProb(oddsB)
    guard pA > 0, pB > 0 else { return [] }
    let fairA = pA / (pA + pB)
    let fairB = 1.0 - fairA
    guard fairA > 0.005, fairB > 0.005 else { return [] }
    let fairOddsA = pickemAmericanOdds(fromProb: fairA)
    let fairOddsB = pickemAmericanOdds(fromProb: fairB)
    // Floor of 10, not 12: an even market (fair ±100) must quote a flat
    // +10/-10 on both sides — a 12 floor manufactured a phantom favorite
    // on every spread/total.
    let swing = max(10, min(240, Int(((abs(fairOddsA) + abs(fairOddsB)) / 20.0).rounded())))
    let aIsFavorite = fairA >= fairB
    return [
        PickOption(team: nameA, gainRR: aIsFavorite ? 10 : swing, lossRR: aIsFavorite ? swing : 10),
        PickOption(team: nameB, gainRR: aIsFavorite ? swing : 10, lossRR: aIsFavorite ? 10 : swing)
    ]
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

        // Derived markets: one extra Match per game for the spread and the
        // total, rendered as rows inside the game card. Flat +10/-10 both
        // sides (near-even markets don't need juice-scaled RR).
        let baseIDs = Set(matches.map(\.id))
        var derived: [Match] = []
        for fixture in fixtures {
            guard baseIDs.contains(fixture.id),
                  !fixture.sportKey.hasPrefix("tennis_") else { continue }
            if let line = fixture.spreadHome, line != 0 {
                let awayLabel = "\(fixture.awayTeam) \(pickemSignedLine(-line))"
                let homeLabel = "\(fixture.homeTeam) \(pickemSignedLine(line))"
                // Real per-side prices (devigged) when the book posts them —
                // a -1.5 run line is NOT a coin flip. Flat only as fallback.
                var options: [PickOption] = []
                if let awayPrice = fixture.spreadAwayOdds, let homePrice = fixture.spreadHomeOdds {
                    options = pickemTwoWayQuotes(
                        nameA: awayLabel, oddsA: awayPrice,
                        nameB: homeLabel, oddsB: homePrice
                    )
                }
                if options.count != 2 {
                    options = [
                        PickOption(team: awayLabel, gainRR: 10, lossRR: 10),
                        PickOption(team: homeLabel, gainRR: 10, lossRR: 10)
                    ]
                }
                derived.append(Match(
                    id: "\(fixture.id)|sprd|\(pickemFormatLine(line))",
                    league: fixture.league,
                    awayTeam: fixture.awayTeam, homeTeam: fixture.homeTeam,
                    startsAt: fixture.startsAt, state: fixture.state,
                    statusDetail: fixture.statusDetail,
                    awayScore: fixture.awayScore, homeScore: fixture.homeScore,
                    options: options
                ))
            }
            if let total = fixture.overUnder, total > 0 {
                let fmt = pickemFormatLine(total)
                var options: [PickOption] = []
                if let overPrice = fixture.overOdds, let underPrice = fixture.underOdds {
                    options = pickemTwoWayQuotes(
                        nameA: "Over \(fmt)", oddsA: overPrice,
                        nameB: "Under \(fmt)", oddsB: underPrice
                    )
                }
                if options.count != 2 {
                    options = [
                        PickOption(team: "Over \(fmt)", gainRR: 10, lossRR: 10),
                        PickOption(team: "Under \(fmt)", gainRR: 10, lossRR: 10)
                    ]
                }
                derived.append(Match(
                    id: "\(fixture.id)|tot|\(fmt)",
                    league: fixture.league,
                    awayTeam: fixture.awayTeam, homeTeam: fixture.homeTeam,
                    startsAt: fixture.startsAt, state: fixture.state,
                    statusDetail: fixture.statusDetail,
                    awayScore: fixture.awayScore, homeScore: fixture.homeScore,
                    options: options
                ))
            }
        }
        matches.append(contentsOf: derived)

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
        // Shared devigged math — see pickemTwoWayQuotes.
        pickemTwoWayQuotes(nameA: teamA, oddsA: oddsA, nameB: teamB, oddsB: oddsB)
            .map { OddsQuote(team: $0.team, gainRR: $0.gainRR, lossRR: $0.lossRR) }
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
                        let spreadHome = competition.odds?.first?.spread
                        let overUnder = competition.odds?.first?.overUnder
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
                                drawMoneyline: drawMoneyline,
                                spreadHome: spreadHome,
                                overUnder: overUnder
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
            let needsML = fixture.awayMoneyline == nil && fixture.homeMoneyline == nil
            // The site scoreboard's odds block is empty for much of the day,
            // so spread/total usually need the Core API even when moneylines
            // came through.
            let needsLines = fixture.spreadHome == nil || fixture.overUnder == nil
                || fixture.spreadAwayOdds == nil || fixture.overOdds == nil
            guard (needsML || needsLines) && !fixture.sportKey.hasPrefix("tennis_") else { continue }

            // Check cache first
            let parts = fixture.id.split(separator: "-")
            guard parts.count >= 3 else { continue }
            let eventID = String(parts.last!)

            if needsML, !needsLines, let cached = CoreAPIOddsCache.shared.get(eventID) {
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
        struct CoreOddsFetch {
            let index: Int
            let eventID: String
            let awayML: Double?
            let homeML: Double?
            let drawML: Double?
            let spreadHome: Double?
            let overUnder: Double?
            let spreadAwayOdds: Double?
            let spreadHomeOdds: Double?
            let overOdds: Double?
            let underOdds: Double?
        }
        let fetched: [CoreOddsFetch] = await withTaskGroup(of: CoreOddsFetch?.self) { group in
            for req in requests {
                group.addTask {
                    let urlStr = "https://sports.core.api.espn.com/v2/sports/\(req.sportPath)/leagues/\(req.leaguePath)/events/\(req.eventID)/competitions/\(req.eventID)/odds"
                    guard let url = URL(string: urlStr) else { return nil }
                    guard let (data, response) = try? await session.data(from: url),
                          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
                    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let items = json["items"] as? [[String: Any]],
                          let first = items.first else { return nil }
                    func num(_ any: Any?) -> Double? {
                        (any as? Double) ?? (any as? Int).map(Double.init)
                    }
                    // Parse moneyline from Core API response (can be Int or Double)
                    let awayML = num((first["awayTeamOdds"] as? [String: Any])?["moneyLine"])
                    let homeML = num((first["homeTeamOdds"] as? [String: Any])?["moneyLine"])
                    // Soccer 3-way: Core API carries the draw under "drawOdds"
                    let drawML = num((first["drawOdds"] as? [String: Any])?["moneyLine"])
                    // Home-relative point spread + full-game total (verified:
                    // top-level "spread" matches homeTeamOdds.pointSpread sign).
                    let spreadHome = num(first["spread"])
                    let overUnder = num(first["overUnder"])
                    // Per-side prices: total prices are top-level; spread
                    // prices sit under each team's current.spread as a
                    // decimal — convert to American.
                    func decimalToAmerican(_ dec: Double?) -> Double? {
                        guard let dec, dec > 1.0 else { return nil }
                        return dec >= 2.0 ? (dec - 1.0) * 100.0 : -100.0 / (dec - 1.0)
                    }
                    func spreadPrice(_ side: Any?) -> Double? {
                        let spread = ((side as? [String: Any])?["current"] as? [String: Any])?["spread"] as? [String: Any]
                        return decimalToAmerican(num(spread?["value"]))
                    }
                    let overOdds = num(first["overOdds"])
                    let underOdds = num(first["underOdds"])
                    let spreadAwayOdds = spreadPrice(first["awayTeamOdds"])
                    let spreadHomeOdds = spreadPrice(first["homeTeamOdds"])
                    if awayML == nil && homeML == nil && spreadHome == nil && overUnder == nil { return nil }
                    return CoreOddsFetch(
                        index: req.index, eventID: req.eventID,
                        awayML: awayML, homeML: homeML, drawML: drawML,
                        spreadHome: spreadHome, overUnder: overUnder,
                        spreadAwayOdds: spreadAwayOdds, spreadHomeOdds: spreadHomeOdds,
                        overOdds: overOdds, underOdds: underOdds
                    )
                }
            }
            var results: [CoreOddsFetch] = []
            for await result in group {
                if let r = result { results.append(r) }
            }
            return results
        }

        for fetch in fetched {
            // Cache for future refreshes
            if let awayML = fetch.awayML, let homeML = fetch.homeML {
                CoreAPIOddsCache.shared.set(fetch.eventID, away: awayML, home: homeML)
            }

            let f = updated[fetch.index]
            updated[fetch.index] = GameFixture(
                id: f.id, sportKey: f.sportKey, league: f.league,
                awayTeam: f.awayTeam, homeTeam: f.homeTeam,
                startsAt: f.startsAt, state: f.state, statusDetail: f.statusDetail,
                awayScore: f.awayScore, homeScore: f.homeScore,
                awayWinPct: f.awayWinPct, homeWinPct: f.homeWinPct,
                awayMoneyline: f.awayMoneyline ?? fetch.awayML,
                homeMoneyline: f.homeMoneyline ?? fetch.homeML,
                drawMoneyline: f.drawMoneyline ?? fetch.drawML,
                spreadHome: f.spreadHome ?? fetch.spreadHome,
                overUnder: f.overUnder ?? fetch.overUnder,
                spreadAwayOdds: f.spreadAwayOdds ?? fetch.spreadAwayOdds,
                spreadHomeOdds: f.spreadHomeOdds ?? fetch.spreadHomeOdds,
                overOdds: f.overOdds ?? fetch.overOdds,
                underOdds: f.underOdds ?? fetch.underOdds
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

// MARK: - Player prop board (ESPN core API, DraftKings lines — free)

/// Fetches the DraftKings player-prop board for a game from ESPN's core
/// API and converts headline markets into derived pick'em Matches.
/// Pairs arrive as [over, under] in feed order; RR quotes are juice-scaled
/// with the same math as moneylines.
struct ESPNPropBoardProvider {
    struct PropStatType {
        let espnName: String
        let key: String
        let shortLabel: String
    }

    static func statTypes(forSportKey sportKey: String) -> [PropStatType] {
        if sportKey == "baseball_mlb" {
            return [
                PropStatType(espnName: "Total Hits", key: "h", shortLabel: "Hits"),
                PropStatType(espnName: "Total Hits + Runs + RBIs", key: "hrr", shortLabel: "H+R+RBI"),
                PropStatType(espnName: "Total Strikeouts", key: "k", shortLabel: "Ks"),
                PropStatType(espnName: "Total Runs Scored", key: "r", shortLabel: "Runs")
            ]
        }
        // NHL/soccer type names are pattern-based (no live boards to
        // verify against pre-season) — same approach as football; fix
        // names here if a posted board's rows don't appear.
        if sportKey == "icehockey_nhl" {
            return [
                PropStatType(espnName: "Total Shots on Goal", key: "sog", shortLabel: "SOG"),
                PropStatType(espnName: "Total Saves", key: "sv", shortLabel: "Saves")
            ]
        }
        if sportKey.hasPrefix("soccer_") {
            return [
                PropStatType(espnName: "Total Shots", key: "sh", shortLabel: "Shots"),
                PropStatType(espnName: "Total Shots on Target", key: "st", shortLabel: "SOT")
            ]
        }
        return []
    }

    /// Milestone-style markets: per (athlete, target) items with a single
    /// Yes price ("Points Milestones" 20+, "Home Runs Milestones" 1+).
    /// yesNo styles render Yes/No at target 1; the rest pick the target
    /// priced closest to even and render as an O/U at target - 0.5.
    /// Basketball props are ONLY published in this shape; football names
    /// follow the same pattern (verify once NFL boards post in Aug).
    struct MilestoneType {
        let espnName: String
        let key: String
        let shortLabel: String
        var yesNo: Bool = false
        var cap: Int = 6
    }

    static func milestoneTypes(forSportKey sportKey: String) -> [MilestoneType] {
        if sportKey == "baseball_mlb" {
            return [MilestoneType(espnName: "Home Runs Milestones", key: "hr", shortLabel: "To Hit a HR", yesNo: true, cap: 8)]
        }
        if sportKey.hasPrefix("basketball_") {
            return [
                MilestoneType(espnName: "Points Milestones", key: "pts", shortLabel: "Pts", cap: 8),
                MilestoneType(espnName: "Points + Assists + Rebounds Milestones", key: "pra", shortLabel: "PRA", cap: 6),
                MilestoneType(espnName: "Rebounds Milestones", key: "reb", shortLabel: "Reb", cap: 5),
                MilestoneType(espnName: "Assists Milestones", key: "ast", shortLabel: "Ast", cap: 5)
            ]
        }
        if sportKey.hasPrefix("americanfootball_") {
            return [
                MilestoneType(espnName: "Passing Yards Milestones", key: "payds", shortLabel: "Pass Yds", cap: 4),
                MilestoneType(espnName: "Rushing Yards Milestones", key: "ruyds", shortLabel: "Rush Yds", cap: 6),
                MilestoneType(espnName: "Receiving Yards Milestones", key: "reyds", shortLabel: "Rec Yds", cap: 8),
                MilestoneType(espnName: "Receptions Milestones", key: "rec", shortLabel: "Receptions", cap: 6),
                MilestoneType(espnName: "Touchdowns Milestones", key: "anytd", shortLabel: "To Score a TD", yesNo: true, cap: 10)
            ]
        }
        if sportKey == "icehockey_nhl" {
            return [
                MilestoneType(espnName: "Goals Milestones", key: "g", shortLabel: "To Score a Goal", yesNo: true, cap: 8),
                MilestoneType(espnName: "Points Milestones", key: "hpts", shortLabel: "Pts", cap: 6)
            ]
        }
        if sportKey.hasPrefix("soccer_") {
            return [
                MilestoneType(espnName: "Anytime Goal Scorer", key: "g", shortLabel: "To Score a Goal", yesNo: true, cap: 10),
                MilestoneType(espnName: "Goals Milestones", key: "g", shortLabel: "To Score a Goal", yesNo: true, cap: 10)
            ]
        }
        return []
    }

    /// Sports whose boards carry 1st Half game markets (spread/ML/total).
    static func supportsFirstHalf(sportKey: String) -> Bool {
        sportKey.hasPrefix("basketball_") || sportKey.hasPrefix("americanfootball_")
    }

    static func supportsProps(matchID: String) -> Bool {
        guard let key = sportKeyFromMatchID(matchID) else { return false }
        return !statTypes(forSportKey: key).isEmpty
            || !milestoneTypes(forSportKey: key).isEmpty
            || supportsFirstHalf(sportKey: key)
    }

    static func sportKeyFromMatchID(_ id: String) -> String? {
        guard id.hasPrefix("espn-"), !id.contains("|") else { return nil }
        let core = id.dropFirst(5)
        guard let lastDash = core.lastIndex(of: "-") else { return nil }
        return String(core[..<lastDash])
    }

    private static let nameCacheLock = NSLock()
    nonisolated(unsafe) private static var athleteNameCache: [String: String] = [:]

    func fetchPropMatches(for match: Match) async -> [Match] {
        guard let sportKey = Self.sportKeyFromMatchID(match.id),
              let sport = ESPSportDefinition.majorSports.first(where: { $0.oddsSportKey == sportKey }) else { return [] }
        let types = Self.statTypes(forSportKey: sportKey)
        // Basketball has NO O/U pair types (its props are all milestones),
        // so gate on the union of capabilities — the old `types.isEmpty`
        // guard returned [] for every WNBA/NBA game before fetching.
        guard !types.isEmpty
            || !Self.milestoneTypes(forSportKey: sportKey).isEmpty
            || Self.supportsFirstHalf(sportKey: sportKey) else { return [] }
        let eventID = String(match.id.split(separator: "-").last ?? "")
        guard !eventID.isEmpty else { return [] }

        // 1. The odds item carries a $ref to its propBets collection.
        let oddsURL = "https://sports.core.api.espn.com/v2/sports/\(sport.sportPath)/leagues/\(sport.leaguePath)/events/\(eventID)/competitions/\(eventID)/odds"
        guard let url = URL(string: oddsURL),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else { return [] }
        guard let propRef = items.compactMap({ ($0["propBets"] as? [String: Any])?["$ref"] as? String }).first,
              var refComponents = URLComponents(string: propRef) else { return [] }
        refComponents.scheme = "https"
        var refItems = refComponents.queryItems ?? []
        refItems.append(URLQueryItem(name: "limit", value: "1000"))
        refComponents.queryItems = refItems
        guard let propURL = refComponents.url,
              let (propData, _) = try? await URLSession.shared.data(from: propURL),
              let propJSON = try? JSONSerialization.jsonObject(with: propData) as? [String: Any],
              let propItems = propJSON["items"] as? [[String: Any]] else { return [] }

        // 2. Group by (athlete, market); feed order within a pair is [over, under].
        struct PropPair {
            let athleteID: String
            let type: PropStatType
            var line: Double?
            var overOdds: Double?
            var underOdds: Double?
        }
        // Home/away ESPN team ids (for team-level F5 markets) come from the
        // main odds item we already fetched.
        func teamID(from teamOdds: Any?) -> String? {
            guard let ref = ((teamOdds as? [String: Any])?["team"] as? [String: Any])?["$ref"] as? String else { return nil }
            return ref.split(separator: "?").first.flatMap { $0.split(separator: "/").last }.map(String.init)
        }
        let oddsItem = items.first
        let homeTeamID = teamID(from: oddsItem?["homeTeamOdds"])
        let awayTeamID = teamID(from: oddsItem?["awayTeamOdds"])

        var pairs: [String: PropPair] = [:]
        var order: [String] = []
        // Milestone markets: per (athlete, target) single-price items.
        var milestonesByKey: [String: [(athleteID: String, target: Double, odds: Double)]] = [:]
        // 1st Half game markets (basketball / football).
        var h1MLByTeam: [String: Double] = [:]
        // odds are nil when the book has posted the line but not yet the
        // prices (preseason boards) — those mint with flat +10/-10.
        var h1SpreadByTeam: [String: (line: Double, odds: Double?)] = [:]
        var h1TotalSides: [Double] = []
        var h1TotalLine: Double?
        // 1st-5-innings markets (MLB): team-keyed ML, per-team alt run
        // lines, and totals arriving [overs..., unders...] across alt lines.
        var f5MLByTeam: [String: Double] = [:]
        var f5RunLines: [(teamID: String, line: Double, odds: Double)] = []
        var f5TotalsByLine: [Double: [Double]] = [:]
        var f5TotalLineOrder: [Double] = []

        func americanOdds(_ item: [String: Any]) -> Double? {
            (((item["odds"] as? [String: Any])?["american"] as? [String: Any])?["value"] as? String)
                .flatMap { Double($0.replacingOccurrences(of: "+", with: "")) }
        }
        func lineValue(_ item: [String: Any]) -> Double? {
            (((item["odds"] as? [String: Any])?["total"] as? [String: Any])?["value"] as? String).flatMap(Double.init)
                ?? ((item["current"] as? [String: Any])?["target"] as? [String: Any])?["value"] as? Double
        }

        let typeByName = Dictionary(uniqueKeysWithValues: types.map { ($0.espnName, $0) })
        let milestoneByName = Dictionary(uniqueKeysWithValues: Self.milestoneTypes(forSportKey: sportKey).map { ($0.espnName, $0) })
        for item in propItems {
            guard let typeName = (item["type"] as? [String: Any])?["name"] as? String else { continue }

            if Self.supportsFirstHalf(sportKey: sportKey) {
                switch typeName {
                case "1st Half Moneyline":
                    if let tid = teamID(from: item), let odds = americanOdds(item) {
                        h1MLByTeam[tid] = odds
                    }
                    continue
                case "1st Half Spread":
                    if let tid = teamID(from: item),
                       let line = ((item["current"] as? [String: Any])?["target"] as? [String: Any])?["value"] as? Double {
                        h1SpreadByTeam[tid] = (line, americanOdds(item))
                    }
                    continue
                case "1st Half Total":
                    if h1TotalLine == nil {
                        h1TotalLine = ((item["current"] as? [String: Any])?["target"] as? [String: Any])?["value"] as? Double
                    }
                    if let odds = americanOdds(item) {
                        h1TotalSides.append(odds)
                    }
                    continue
                default:
                    break
                }
            }

            if let milestone = milestoneByName[typeName] {
                // Yes/No event props (anytime goal/TD) often post WITHOUT a
                // target — the market IS "1+"; default the target to 1.
                let rawTarget = ((item["current"] as? [String: Any])?["target"] as? [String: Any])?["value"] as? Double
                let target = rawTarget ?? (milestone.yesNo ? 1.0 : nil)
                let odds = americanOdds(item)
                let athleteID = ((item["athlete"] as? [String: Any])?["$ref"] as? String)?
                    .split(separator: "?").first
                    .flatMap { $0.split(separator: "/").last }.map(String.init) ?? ""
                if let target, let odds, !athleteID.isEmpty {
                    milestonesByKey[milestone.key, default: []].append((athleteID, target, odds))
                }
                continue
            }

            if sportKey == "baseball_mlb" {
                switch typeName {
                case "1st 5 Innings Moneyline":
                    if let tid = teamID(from: item), let odds = americanOdds(item) {
                        f5MLByTeam[tid] = odds
                    }
                    continue
                case "1st 5 Innings Run Line":
                    if let tid = teamID(from: item), let odds = americanOdds(item), let line = lineValue(item) {
                        f5RunLines.append((tid, line, odds))
                    }
                    continue
                case "1st 5 Innings Total Runs":
                    if let odds = americanOdds(item), let line = lineValue(item) {
                        if f5TotalsByLine[line] == nil { f5TotalLineOrder.append(line) }
                        f5TotalsByLine[line, default: []].append(odds)
                    }
                    continue
                default:
                    break
                }
            }

            guard let athleteRef = (item["athlete"] as? [String: Any])?["$ref"] as? String else { continue }
            guard let type = typeByName[typeName] else { continue }
            let athleteID = athleteRef.split(separator: "?").first
                .flatMap { $0.split(separator: "/").last }.map(String.init) ?? ""
            guard !athleteID.isEmpty else { continue }
            let odds = item["odds"] as? [String: Any]
            let american = ((odds?["american"] as? [String: Any])?["value"] as? String)
                .flatMap { Double($0.replacingOccurrences(of: "+", with: "")) }
            let line = ((odds?["total"] as? [String: Any])?["value"] as? String).flatMap(Double.init)
                ?? ((item["current"] as? [String: Any])?["target"] as? [String: Any])?["value"] as? Double
            let key = "\(athleteID)|\(type.key)"
            if pairs[key] == nil {
                pairs[key] = PropPair(athleteID: athleteID, type: type, line: line, overOdds: american, underOdds: nil)
                order.append(key)
            } else if pairs[key]?.underOdds == nil {
                pairs[key]?.underOdds = american
                if pairs[key]?.line == nil { pairs[key]?.line = line }
            }
        }

        let complete = order.compactMap { pairs[$0] }.filter {
            $0.line != nil && $0.overOdds != nil && $0.underOdds != nil
        }
        let hasF5 = !f5MLByTeam.isEmpty || !f5RunLines.isEmpty || !f5TotalsByLine.isEmpty
        let hasH1 = !h1MLByTeam.isEmpty || !h1SpreadByTeam.isEmpty || !h1TotalSides.isEmpty
        let hasMilestones = milestonesByKey.values.contains { !$0.isEmpty }
        guard !complete.isEmpty || hasMilestones || hasF5 || hasH1 else { return [] }

        // 3. Resolve athlete display names (cached).
        let uniqueIDs = Array(Set(complete.map(\.athleteID) + milestonesByKey.values.flatMap { $0.map(\.athleteID) }))
        var names: [String: String] = [:]
        Self.nameCacheLock.lock()
        for id in uniqueIDs where Self.athleteNameCache[id] != nil {
            names[id] = Self.athleteNameCache[id]
        }
        Self.nameCacheLock.unlock()
        let missing = uniqueIDs.filter { names[$0] == nil }
        let fetchedNames: [(String, String)] = await withTaskGroup(of: (String, String)?.self) { group in
            for id in missing {
                group.addTask {
                    let urlStr = "https://sports.core.api.espn.com/v2/sports/\(sport.sportPath)/leagues/\(sport.leaguePath)/athletes/\(id)"
                    guard let url = URL(string: urlStr),
                          let (data, _) = try? await URLSession.shared.data(from: url),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let name = (json["displayName"] as? String) ?? (json["fullName"] as? String) else { return nil }
                    return (id, name)
                }
            }
            var out: [(String, String)] = []
            for await r in group { if let r { out.append(r) } }
            return out
        }
        Self.nameCacheLock.lock()
        for (id, name) in fetchedNames {
            names[id] = name
            Self.athleteNameCache[id] = name
        }
        Self.nameCacheLock.unlock()

        // 4. Build derived Matches, grouped by market with per-type caps so
        // hits don't crowd out Ks/runs; favorites first within each type.
        var out: [Match] = []

        func implied(_ o: Double) -> Double {
            o > 0 ? 100.0 / (o + 100.0) : abs(o) / (abs(o) + 100.0)
        }

        // 1st 5 Innings rows lead the board.
        if let homeID = homeTeamID, let awayID = awayTeamID {
            if let homeML = f5MLByTeam[homeID], let awayML = f5MLByTeam[awayID] {
                let options = pickemTwoWayQuotes(
                    nameA: match.awayTeam, oddsA: awayML,
                    nameB: match.homeTeam, oddsB: homeML
                )
                if options.count == 2 {
                    out.append(Match(
                        id: "\(match.id)|f5ml",
                        league: match.league,
                        awayTeam: match.awayTeam, homeTeam: match.homeTeam,
                        startsAt: match.startsAt, state: match.state,
                        statusDetail: match.statusDetail,
                        awayScore: nil, homeScore: nil,
                        options: options
                    ))
                }
            }
            // Run line: the most balanced home-relative line pair, quoted
            // from its real per-side prices (devigged).
            var bestRunLine: (line: Double, homeOdds: Double, awayOdds: Double, gap: Double)?
            for home in f5RunLines where home.teamID == homeID {
                guard let away = f5RunLines.first(where: { $0.teamID == awayID && $0.line == -home.line }) else { continue }
                let gap = abs(implied(home.odds) - implied(away.odds))
                if bestRunLine == nil || gap < bestRunLine!.gap {
                    bestRunLine = (home.line, home.odds, away.odds, gap)
                }
            }
            if let runLine = bestRunLine {
                let line = runLine.line
                let options = pickemTwoWayQuotes(
                    nameA: "\(match.awayTeam) \(pickemSignedLine(-line))", oddsA: runLine.awayOdds,
                    nameB: "\(match.homeTeam) \(pickemSignedLine(line))", oddsB: runLine.homeOdds
                )
                if options.count == 2 {
                    out.append(Match(
                        id: "\(match.id)|f5sprd|\(pickemFormatLine(line))",
                        league: match.league,
                        awayTeam: match.awayTeam, homeTeam: match.homeTeam,
                        startsAt: match.startsAt, state: match.state,
                        statusDetail: match.statusDetail,
                        awayScore: nil, homeScore: nil,
                        options: options
                    ))
                }
            }
        }
        // 1st Half markets (basketball / football): ML, spread, total.
        if let homeID = homeTeamID, let awayID = awayTeamID {
            if let homeML = h1MLByTeam[homeID], let awayML = h1MLByTeam[awayID] {
                let options = pickemTwoWayQuotes(
                    nameA: match.awayTeam, oddsA: awayML,
                    nameB: match.homeTeam, oddsB: homeML
                )
                if options.count == 2 {
                    out.append(Match(
                        id: "\(match.id)|h1ml",
                        league: match.league,
                        awayTeam: match.awayTeam, homeTeam: match.homeTeam,
                        startsAt: match.startsAt, state: match.state,
                        statusDetail: match.statusDetail,
                        awayScore: nil, homeScore: nil,
                        options: options
                    ))
                }
            }
            if let home = h1SpreadByTeam[homeID], let away = h1SpreadByTeam[awayID], home.line == -away.line, home.line != 0 {
                let awayLabel = "\(match.awayTeam) \(pickemSignedLine(away.line))"
                let homeLabel = "\(match.homeTeam) \(pickemSignedLine(home.line))"
                var options: [PickOption] = []
                if let awayOdds = away.odds, let homeOdds = home.odds {
                    options = pickemTwoWayQuotes(
                        nameA: awayLabel, oddsA: awayOdds,
                        nameB: homeLabel, oddsB: homeOdds
                    )
                }
                if options.count != 2 {
                    options = [PickOption(team: awayLabel, gainRR: 10, lossRR: 10),
                               PickOption(team: homeLabel, gainRR: 10, lossRR: 10)]
                }
                if options.count == 2 {
                    out.append(Match(
                        id: "\(match.id)|h1sprd|\(pickemFormatLine(home.line))",
                        league: match.league,
                        awayTeam: match.awayTeam, homeTeam: match.homeTeam,
                        startsAt: match.startsAt, state: match.state,
                        statusDetail: match.statusDetail,
                        awayScore: nil, homeScore: nil,
                        options: options
                    ))
                }
            }
        }
        if let line = h1TotalLine {
            let fmt = pickemFormatLine(line)
            var options: [PickOption] = []
            if h1TotalSides.count == 2 {
                options = pickemTwoWayQuotes(
                    nameA: "Over \(fmt)", oddsA: h1TotalSides[0],
                    nameB: "Under \(fmt)", oddsB: h1TotalSides[1]
                )
            }
            if options.count != 2 {
                options = [PickOption(team: "Over \(fmt)", gainRR: 10, lossRR: 10),
                           PickOption(team: "Under \(fmt)", gainRR: 10, lossRR: 10)]
            }
            if options.count == 2 {
                out.append(Match(
                    id: "\(match.id)|h1tot|\(fmt)",
                    league: match.league,
                    awayTeam: match.awayTeam, homeTeam: match.homeTeam,
                    startsAt: match.startsAt, state: match.state,
                    statusDetail: match.statusDetail,
                    awayScore: nil, homeScore: nil,
                    options: options
                ))
            }
        }

        // Total: most balanced over/under pair ([over, under] feed order),
        // quoted from its real prices (devigged).
        var bestTotal: (line: Double, overOdds: Double, underOdds: Double, gap: Double)?
        for line in f5TotalLineOrder {
            guard let sides = f5TotalsByLine[line], sides.count == 2 else { continue }
            let gap = abs(implied(sides[0]) - implied(sides[1]))
            if bestTotal == nil || gap < bestTotal!.gap {
                bestTotal = (line, sides[0], sides[1], gap)
            }
        }
        if let total = bestTotal {
            let fmt = pickemFormatLine(total.line)
            let options = pickemTwoWayQuotes(
                nameA: "Over \(fmt)", oddsA: total.overOdds,
                nameB: "Under \(fmt)", oddsB: total.underOdds
            )
            if options.count == 2 {
                out.append(Match(
                    id: "\(match.id)|f5tot|\(fmt)",
                    league: match.league,
                    awayTeam: match.awayTeam, homeTeam: match.homeTeam,
                    startsAt: match.startsAt, state: match.state,
                    statusDetail: match.statusDetail,
                    awayScore: nil, homeScore: nil,
                    options: options
                ))
            }
        }

        func appendPairs(key: String, cap: Int) {
            let bucket = complete
                .filter { $0.type.key == key }
                .sorted { ($0.overOdds ?? 0) < ($1.overOdds ?? 0) }
                .prefix(cap)
            for pair in bucket {
                guard let line = pair.line, let over = pair.overOdds, let under = pair.underOdds,
                      let name = names[pair.athleteID] else { continue }
                let fmt = pickemFormatLine(line)
                let options = pickemTwoWayQuotes(
                    nameA: "Over \(fmt)", oddsA: over,
                    nameB: "Under \(fmt)", oddsB: under
                )
                guard options.count == 2 else { continue }
                out.append(Match(
                    id: "\(match.id)|prop|\(pair.athleteID)|\(pair.type.key)|\(fmt)",
                    league: match.league,
                    awayTeam: "\(name) — \(pair.type.shortLabel) \(fmt)",
                    homeTeam: "",
                    startsAt: match.startsAt, state: match.state,
                    statusDetail: match.statusDetail,
                    awayScore: nil, homeScore: nil,
                    options: options
                ))
            }
        }

        appendPairs(key: "h", cap: 8)

        // Milestone markets. Yes/No styles (HR, anytime TD) use the
        // target-1 item; the rest pick each athlete's target priced
        // closest to even and render as an O/U at target - 0.5.
        var emittedMilestoneKeys = Set<String>()
        for milestone in Self.milestoneTypes(forSportKey: sportKey) {
            let items = milestonesByKey[milestone.key] ?? []
            guard !items.isEmpty else { continue }
            // Alias entries (e.g. soccer's two possible anytime-goal names)
            // share a key — emit each key's rows once.
            guard emittedMilestoneKeys.insert(milestone.key).inserted else { continue }
            if milestone.yesNo {
                let candidates = items.filter { $0.target == 1.0 }.sorted { $0.odds < $1.odds }
                for item in candidates.prefix(milestone.cap) {
                    guard let name = names[item.athleteID] else { continue }
                    out.append(Match(
                        id: "\(match.id)|prop|\(item.athleteID)|\(milestone.key)|0.5",
                        league: match.league,
                        awayTeam: "\(name) — \(milestone.shortLabel)",
                        homeTeam: "",
                        startsAt: match.startsAt, state: match.state,
                        statusDetail: match.statusDetail,
                        awayScore: nil, homeScore: nil,
                        options: pickemYesNoQuotes(yesOdds: item.odds)
                    ))
                }
            } else {
                var bestByAthlete: [String: (target: Double, odds: Double)] = [:]
                for item in items {
                    let gap = abs(pickemImpliedProb(item.odds) - 0.5)
                    if let existing = bestByAthlete[item.athleteID] {
                        if gap < abs(pickemImpliedProb(existing.odds) - 0.5) {
                            bestByAthlete[item.athleteID] = (item.target, item.odds)
                        }
                    } else {
                        bestByAthlete[item.athleteID] = (item.target, item.odds)
                    }
                }
                // Stars first: highest line at the top.
                let ranked = bestByAthlete.sorted { $0.value.target > $1.value.target }.prefix(milestone.cap)
                for (athleteID, pick) in ranked {
                    guard let name = names[athleteID] else { continue }
                    let line = pick.target - 0.5
                    let fmt = pickemFormatLine(line)
                    out.append(Match(
                        id: "\(match.id)|prop|\(athleteID)|\(milestone.key)|\(fmt)",
                        league: match.league,
                        awayTeam: "\(name) — \(milestone.shortLabel) \(fmt)",
                        homeTeam: "",
                        startsAt: match.startsAt, state: match.state,
                        statusDetail: match.statusDetail,
                        awayScore: nil, homeScore: nil,
                        options: pickemOneSidedQuotes(yesOdds: pick.odds, yesName: "Over \(fmt)", noName: "Under \(fmt)")
                    ))
                }
            }
        }

        appendPairs(key: "hrr", cap: 6)
        appendPairs(key: "r", cap: 6)
        appendPairs(key: "k", cap: 4)
        appendPairs(key: "sog", cap: 8)
        appendPairs(key: "sv", cap: 2)
        appendPairs(key: "sh", cap: 6)
        appendPairs(key: "st", cap: 6)
        return out
    }
}

/// First-5-innings runs for both teams from an ESPN event summary's
/// header linescores. Returns nil (void) when either side played fewer
/// than 5 innings (rain-shortened).
func pickemF5Scores(summary: [String: Any]) -> (away: Int, home: Int, awayName: String, homeName: String)? {
    guard let header = summary["header"] as? [String: Any],
          let comp = (header["competitions"] as? [[String: Any]])?.first,
          let competitors = comp["competitors"] as? [[String: Any]] else { return nil }
    var away: (runs: Int, name: String)?
    var home: (runs: Int, name: String)?
    for competitor in competitors {
        let name = ((competitor["team"] as? [String: Any])?["displayName"] as? String) ?? ""
        guard let lines = competitor["linescores"] as? [[String: Any]], lines.count >= 5 else { return nil }
        var runs = 0
        for line in lines.prefix(5) {
            if let v = line["value"] as? Double {
                runs += Int(v)
            } else if let dv = line["displayValue"] as? String, let v = Int(dv) {
                runs += v
            } else {
                return nil
            }
        }
        if (competitor["homeAway"] as? String) == "home" {
            home = (runs, name)
        } else {
            away = (runs, name)
        }
    }
    guard let away, let home else { return nil }
    return (away.runs, home.runs, away.name, home.name)
}

/// First-half points for both teams from the summary linescores.
/// Quarter sports (NBA/WNBA/NFL/CFB) sum the first two periods; half
/// sports (NCAAB) take the first. Returns nil (void) when linescores
/// are missing.
func pickemFirstHalfScores(summary: [String: Any]) -> (away: Int, home: Int, awayName: String, homeName: String)? {
    guard let header = summary["header"] as? [String: Any],
          let comp = (header["competitions"] as? [[String: Any]])?.first,
          let competitors = comp["competitors"] as? [[String: Any]] else { return nil }
    var away: (runs: Int, name: String)?
    var home: (runs: Int, name: String)?
    for competitor in competitors {
        let name = ((competitor["team"] as? [String: Any])?["displayName"] as? String) ?? ""
        guard let lines = competitor["linescores"] as? [[String: Any]], lines.count >= 2 else { return nil }
        let periodCount = lines.count >= 4 ? 2 : 1
        var points = 0
        for line in lines.prefix(periodCount) {
            if let v = line["value"] as? Double {
                points += Int(v)
            } else if let dv = line["displayValue"] as? String, let v = Int(dv) {
                points += v
            } else {
                return nil
            }
        }
        if (competitor["homeAway"] as? String) == "home" {
            home = (points, name)
        } else {
            away = (points, name)
        }
    }
    guard let away, let home else { return nil }
    return (away.runs, home.runs, away.name, home.name)
}

/// Pulls a single athlete stat out of an ESPN event summary box score.
/// statKey: "h"/"r"/"hrr" (MLB batting), "k" (MLB pitching),
/// "pts"/"reb"/"ast"/"pra" (basketball). Returns nil when the athlete
/// isn't in the box (DNP) — callers treat that as a void/PUSH.
func pickemPropStat(summary: [String: Any], athleteID: String, statKey: String) -> Double? {
    guard let box = summary["boxscore"] as? [String: Any],
          let teams = box["players"] as? [[String: Any]] else { return nil }

    func statLine(groupType: String?, labelsWanted: [String]) -> [String: Double]? {
        for team in teams {
            for group in (team["statistics"] as? [[String: Any]]) ?? [] {
                if let groupType {
                    let gtype = (group["type"] as? String) ?? (group["name"] as? String) ?? ""
                    guard gtype.lowercased() == groupType else { continue }
                }
                let labels = (group["labels"] as? [String]) ?? (group["names"] as? [String]) ?? []
                for entry in (group["athletes"] as? [[String: Any]]) ?? [] {
                    guard let ath = entry["athlete"] as? [String: Any],
                          (ath["id"] as? String) == athleteID,
                          let stats = entry["stats"] as? [String], !stats.isEmpty else { continue }
                    var line: [String: Double] = [:]
                    for (label, raw) in zip(labels, stats) {
                        line[label] = Double(raw)
                    }
                    guard labelsWanted.allSatisfy({ line[$0] != nil }) else { continue }
                    return line
                }
            }
        }
        return nil
    }

    switch statKey {
    case "h":
        return statLine(groupType: "batting", labelsWanted: ["H"])?["H"]
    case "hr":
        return statLine(groupType: "batting", labelsWanted: ["HR"])?["HR"]
    case "r":
        return statLine(groupType: "batting", labelsWanted: ["R"])?["R"]
    case "hrr":
        guard let line = statLine(groupType: "batting", labelsWanted: ["H", "R", "RBI"]) else { return nil }
        return (line["H"] ?? 0) + (line["R"] ?? 0) + (line["RBI"] ?? 0)
    case "k":
        return statLine(groupType: "pitching", labelsWanted: ["K"])?["K"]
    case "pts":
        return statLine(groupType: nil, labelsWanted: ["PTS"])?["PTS"]
    case "reb":
        return statLine(groupType: nil, labelsWanted: ["REB"])?["REB"]
    case "ast":
        return statLine(groupType: nil, labelsWanted: ["AST"])?["AST"]
    case "pra":
        guard let line = statLine(groupType: nil, labelsWanted: ["PTS", "REB", "AST"]) else { return nil }
        return (line["PTS"] ?? 0) + (line["REB"] ?? 0) + (line["AST"] ?? 0)
    case "payds":
        return statLine(groupType: "passing", labelsWanted: ["YDS"])?["YDS"]
    case "ruyds":
        return statLine(groupType: "rushing", labelsWanted: ["YDS"])?["YDS"]
    case "reyds":
        return statLine(groupType: "receiving", labelsWanted: ["YDS"])?["YDS"]
    case "rec":
        return statLine(groupType: "receiving", labelsWanted: ["REC"])?["REC"]
    case "anytd":
        // Rushing + receiving TDs; in either box group counts as playing.
        let rush = statLine(groupType: "rushing", labelsWanted: ["TD"])?["TD"]
        let recv = statLine(groupType: "receiving", labelsWanted: ["TD"])?["TD"]
        guard rush != nil || recv != nil else { return nil }
        return (rush ?? 0) + (recv ?? 0)
    case "g":
        // Goals — NHL skaters and soccer players both box under "G".
        return statLine(groupType: nil, labelsWanted: ["G"])?["G"]
    case "sog":
        return statLine(groupType: nil, labelsWanted: ["SOG"])?["SOG"]
    case "sv":
        return statLine(groupType: nil, labelsWanted: ["SV"])?["SV"]
    case "hpts":
        guard let line = statLine(groupType: nil, labelsWanted: ["G", "A"]) else { return nil }
        return (line["G"] ?? 0) + (line["A"] ?? 0)
    case "sh":
        return statLine(groupType: nil, labelsWanted: ["SH"])?["SH"]
    case "st":
        return statLine(groupType: nil, labelsWanted: ["ST"])?["ST"]
    default:
        return nil
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

                            // Derived markets (spread/total) grade off the
                            // final score with the line parsed from the id;
                            // props are collected and graded from box scores
                            // after the scoreboard pass.
                            let derivedIDs = matchIDs.filter { $0.hasPrefix(matchID + "|") }
                            if !derivedIDs.isEmpty {
                                let away = competition.competitors.first(where: { $0.homeAway == "away" })
                                let home = competition.competitors.first(where: { $0.homeAway == "home" })
                                if let awayScore = Int(away?.score ?? ""),
                                   let homeScore = Int(home?.score ?? "") {
                                    for derivedID in derivedIDs {
                                        let parts = derivedID.components(separatedBy: "|")
                                        guard parts.count >= 3 else { continue }
                                        switch parts[1] {
                                        case "sprd":
                                            guard let homeLine = Double(parts[2]) else { continue }
                                            let adjusted = Double(homeScore - awayScore) + homeLine
                                            if adjusted > 0 {
                                                results[derivedID] = "\(home?.team.displayName ?? "") \(pickemSignedLine(homeLine))"
                                            } else if adjusted < 0 {
                                                results[derivedID] = "\(away?.team.displayName ?? "") \(pickemSignedLine(-homeLine))"
                                            } else {
                                                results[derivedID] = "PUSH"
                                            }
                                        case "tot":
                                            guard let line = Double(parts[2]) else { continue }
                                            let total = Double(awayScore + homeScore)
                                            if total > line {
                                                results[derivedID] = "Over \(pickemFormatLine(line))"
                                            } else if total < line {
                                                results[derivedID] = "Under \(pickemFormatLine(line))"
                                            } else {
                                                results[derivedID] = "PUSH"
                                            }
                                        default:
                                            break   // props handled below
                                        }
                                    }
                                }
                            }

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

                        // Player props: grade from the final box score. Only
                        // events this scoreboard saw as final are attempted.
                        let finalEventIDs = Set(scoreboard.events.compactMap { ev -> String? in
                            ev.competitions.first?.status.type.state == "post" ? ev.id : nil
                        })
                        let propIDs = matchIDs.filter { mid in
                            guard mid.contains("|prop|") || mid.contains("|f5") || mid.contains("|h1"),
                                  mid.hasPrefix("espn-\(sport.oddsSportKey)-") else { return false }
                            let base = mid.components(separatedBy: "|").first ?? ""
                            let eventID = base.components(separatedBy: "-").last ?? ""
                            return finalEventIDs.contains(eventID)
                        }
                        if !propIDs.isEmpty {
                            let byEvent = Dictionary(grouping: propIDs) { mid in
                                (mid.components(separatedBy: "|").first ?? "").components(separatedBy: "-").last ?? ""
                            }
                            // Summaries in parallel — sequential fetches made a
                            // full prop slate take (events x latency) and picks
                            // visibly trickled in over minutes.
                            let summaries: [(String, [String: Any])] = await withTaskGroup(of: (String, [String: Any])?.self) { sg in
                                for eventID in byEvent.keys {
                                    sg.addTask { @Sendable in
                                        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(sport.sportPath)/\(sport.leaguePath)/summary?event=\(eventID)"),
                                              let (data, response) = try? await timedSession.data(from: url),
                                              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                                        return (eventID, json)
                                    }
                                }
                                var out: [(String, [String: Any])] = []
                                for await r in sg { if let r { out.append(r) } }
                                return out
                            }
                            for (eventID, json) in summaries {
                                let ids = byEvent[eventID] ?? []
                                for mid in ids {
                                    let parts = mid.components(separatedBy: "|")

                                    // Partial-game markets (F5 innings /
                                    // 1st half) grade from the linescores;
                                    // missing linescores void.
                                    if parts.count >= 2, parts[1].hasPrefix("f5") || parts[1].hasPrefix("h1") {
                                        let scores = parts[1].hasPrefix("f5")
                                            ? pickemF5Scores(summary: json)
                                            : pickemFirstHalfScores(summary: json)
                                        guard let f5 = scores else {
                                            results[mid] = "PUSH"
                                            continue
                                        }
                                        switch parts[1] {
                                        case "f5ml", "h1ml":
                                            if f5.away > f5.home {
                                                results[mid] = f5.awayName
                                            } else if f5.home > f5.away {
                                                results[mid] = f5.homeName
                                            } else {
                                                results[mid] = "PUSH"
                                            }
                                        case "f5sprd", "h1sprd":
                                            guard parts.count >= 3, let homeLine = Double(parts[2]) else { continue }
                                            let adjusted = Double(f5.home - f5.away) + homeLine
                                            if adjusted > 0 {
                                                results[mid] = "\(f5.homeName) \(pickemSignedLine(homeLine))"
                                            } else if adjusted < 0 {
                                                results[mid] = "\(f5.awayName) \(pickemSignedLine(-homeLine))"
                                            } else {
                                                results[mid] = "PUSH"
                                            }
                                        case "f5tot", "h1tot":
                                            guard parts.count >= 3, let line = Double(parts[2]) else { continue }
                                            let total = Double(f5.away + f5.home)
                                            if total > line {
                                                results[mid] = "Over \(pickemFormatLine(line))"
                                            } else if total < line {
                                                results[mid] = "Under \(pickemFormatLine(line))"
                                            } else {
                                                results[mid] = "PUSH"
                                            }
                                        default:
                                            break
                                        }
                                        continue
                                    }

                                    guard parts.count >= 5, let line = Double(parts[4]) else { continue }
                                    let athleteID = parts[2]
                                    let statKey = parts[3]
                                    guard let value = pickemPropStat(summary: json, athleteID: athleteID, statKey: statKey) else {
                                        results[mid] = "PUSH"   // DNP / not in box — void
                                        continue
                                    }
                                    // Milestone props ("to hit a HR", "to score a TD/goal") are Yes/No
                                    let isYesNo = statKey == "hr" || statKey == "anytd" || statKey == "g"
                                    let overLabel = isYesNo ? "Yes" : "Over \(pickemFormatLine(line))"
                                    let underLabel = isYesNo ? "No" : "Under \(pickemFormatLine(line))"
                                    if value > line {
                                        results[mid] = overLabel
                                    } else if value < line {
                                        results[mid] = underLabel
                                    } else {
                                        results[mid] = "PUSH"
                                    }
                                }
                            }
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
        ESPSportDefinition(sportPath: "basketball", leaguePath: "wnba", displayName: "WNBA", oddsSportKey: "basketball_wnba"),
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
    let spread: Double?
    let overUnder: Double?
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

// MARK: - MLB Probable Pitchers (Pick'em cards)

/// Probable starting pitchers for MLB Pick'em match cards. Fetched from
/// ESPN's MLB scoreboard (`competitors[].probables`) and matched to
/// Odds-API-sourced matches by team name + closest start time (the time
/// tiebreak keeps doubleheader games from swapping pitchers).
struct MLBProbablePitcherProvider {
    struct GameProbables {
        let awayTeam: String
        let homeTeam: String
        let startsAt: Date
        let awayPitcher: String?
        let homePitcher: String?
    }

    /// Fetches probables for the given ET date keys ("yyyyMMdd").
    static func fetch(dateKeys: [String]) async -> [GameProbables] {
        await withTaskGroup(of: [GameProbables].self, returning: [GameProbables].self) { group in
            for dateKey in Set(dateKeys) {
                group.addTask {
                    guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/baseball/mlb/scoreboard?dates=\(dateKey)"),
                          let (data, response) = try? await URLSession.shared.data(from: url),
                          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let events = json["events"] as? [[String: Any]] else {
                        return []
                    }
                    let iso = ISO8601DateFormatter()
                    var out: [GameProbables] = []
                    for event in events {
                        guard let competitions = event["competitions"] as? [[String: Any]],
                              let competition = competitions.first,
                              let competitors = competition["competitors"] as? [[String: Any]] else { continue }
                        var awayName = "", homeName = ""
                        var awayPitcher: String?, homePitcher: String?
                        for competitor in competitors {
                            let side = competitor["homeAway"] as? String ?? ""
                            let name = (competitor["team"] as? [String: Any])?["displayName"] as? String ?? ""
                            let probable = (competitor["probables"] as? [[String: Any]])?.first
                            let athlete = probable?["athlete"] as? [String: Any]
                            let pitcher = athlete?["shortName"] as? String ?? athlete?["displayName"] as? String
                            if side == "away" { awayName = name; awayPitcher = pitcher }
                            else if side == "home" { homeName = name; homePitcher = pitcher }
                        }
                        guard !awayName.isEmpty, !homeName.isEmpty else { continue }
                        let dateStr = event["date"] as? String ?? ""
                        let startsAt = iso.date(from: dateStr)
                            ?? iso.date(from: dateStr.replacingOccurrences(of: "Z", with: ":00Z"))
                            ?? .distantPast
                        out.append(GameProbables(
                            awayTeam: awayName, homeTeam: homeName,
                            startsAt: startsAt,
                            awayPitcher: awayPitcher, homePitcher: homePitcher
                        ))
                    }
                    return out
                }
            }
            var all: [GameProbables] = []
            for await batch in group { all.append(contentsOf: batch) }
            return all
        }
    }

    /// Odds-API names and ESPN displayNames mostly agree ("Baltimore
    /// Orioles"), but stay defensive: equality or containment either way.
    static func teamsMatch(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased(), y = b.lowercased()
        return x == y || x.contains(y) || y.contains(x)
    }

    /// Best game for a match: both team names match, closest start time.
    static func probables(awayTeam: String, homeTeam: String, startsAt: Date, in games: [GameProbables]) -> (away: String?, home: String?)? {
        let candidates = games.filter {
            teamsMatch($0.awayTeam, awayTeam) && teamsMatch($0.homeTeam, homeTeam)
        }
        guard let best = candidates.min(by: {
            abs($0.startsAt.timeIntervalSince(startsAt)) < abs($1.startsAt.timeIntervalSince(startsAt))
        }) else { return nil }
        // Only trust the pairing within a few hours — a name match from the
        // wrong day shouldn't stamp pitchers on tomorrow's card.
        guard abs(best.startsAt.timeIntervalSince(startsAt)) < 4 * 3600 else { return nil }
        return (best.awayPitcher, best.homePitcher)
    }
}
