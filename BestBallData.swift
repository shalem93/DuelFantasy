import Foundation

// MARK: - Scoring Mode

enum BestBallScoringMode: String, Equatable, Hashable, CaseIterable {
    case normal = "normal"
    case dingersOnly = "dingers_only"

    var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .dingersOnly: return "Dingers Only"
        }
    }
}

// MARK: - Models

struct BestBallLeague: Identifiable, Equatable, Hashable {
    let id: String
    var title: String
    let sport: String
    let season: String
    var status: String
    let draftStartTime: Date?
    var draftOrder: [String]
    var currentPickNumber: Int
    var pickTimerSeconds: Int
    var rosterSize: Int
    let scoringSlots: Int
    var currentWeek: Int
    let totalWeeks: Int
    let createdAt: Date
    var schedule: [[[String]]]    // [week][ [memberA, memberB], ... ]
    let weekStructure: String     // "mon_sun" or "thu_mon"
    var isPrivate: Bool
    let createdBy: String?        // commissioner's user ID
    var maxMembers: Int
    let inviteCode: String?
    var pitcherSlots: Int         // MLB: scoring pitcher count; NBA/NFL: ignored
    var batterSlots: Int          // MLB: scoring batter/UTIL count; NBA/NFL: ignored
    var scoringMode: BestBallScoringMode
    /// RR entry fee (10/20/50/100/250). 0 = free (grandfathered leagues).
    var entryFee: Int = 10

    // NFL starting-lineup config (only relevant when sport == "NFL").
    // Defaults match the prior hardcoded lineup; can be edited by the
    // commissioner while the league status is still "open".
    var nflQbStarters: Int = 1
    var nflRbStarters: Int = 2
    var nflWrStarters: Int = 2
    var nflTeStarters: Int = 1
    var nflFlexStarters: Int = 2
    // Superflex slots accept QB/RB/WR/TE — popular best-ball variant
    // where you can start a second QB. Defaults to 0 so existing leagues
    // remain standard. Setting this > 0 also raises the per-team QB cap
    // in the bot drafter so it doesn't run out of QBs.
    var nflSflexStarters: Int = 0

    // NBA positional lineup (nil = legacy league from before positional
    // config existed: 1 of each position + (starters−5) FLEX).
    var nbaPgStarters: Int? = nil
    var nbaSgStarters: Int? = nil
    var nbaSfStarters: Int? = nil
    var nbaPfStarters: Int? = nil
    var nbaCStarters: Int? = nil
    var nbaFlexStarters: Int? = nil

    // EPL positional lineup (nil = league from before EPL config
    // existed: the default 1 GK / 3 DEF / 4 MID / 2 FWD / 1 FLEX XI).
    var eplGkStarters: Int? = nil
    var eplDefStarters: Int? = nil
    var eplMidStarters: Int? = nil
    var eplFwdStarters: Int? = nil
    var eplFlexStarters: Int? = nil

    /// CFB player pool scope: "power" = ACC/Big Ten/Big 12/SEC + Notre
    /// Dame; nil/"all" = every FBS program (legacy default).
    var cfbPool: String? = nil

    var memberCount: Int { draftOrder.count }
    var isFull: Bool { draftOrder.count >= maxMembers }
    var isDingersOnly: Bool { scoringMode == .dingersOnly }

    /// Total starting-lineup size for NFL (sum of all per-position
    /// counts). Used as the minimum allowed roster size when editing
    /// settings.
    var nflTotalStarters: Int { nflQbStarters + nflRbStarters + nflWrStarters + nflTeStarters + nflFlexStarters + nflSflexStarters }

    /// Total EPL starters with the default-XI fallbacks applied.
    var eplTotalStarters: Int {
        (eplGkStarters ?? 1) + (eplDefStarters ?? 3) + (eplMidStarters ?? 4)
            + (eplFwdStarters ?? 2) + (eplFlexStarters ?? 1)
    }
}

struct BestBallMember: Identifiable, Equatable, Hashable {
    let id: String
    let leagueID: String
    let userID: String?
    let slotIndex: Int
    let displayName: String
    let isBot: Bool
}

struct BestBallPick: Identifiable, Equatable {
    let id: String
    let leagueID: String
    let memberID: String
    let pickNumber: Int
    let round: Int
    let playerID: String
    let playerName: String
    let playerTeam: String
    let playerPosition: String
    let pickedAt: Date
}

struct BestBallPlayer: Identifiable, Hashable {
    let id: String
    let name: String
    let team: String
    let position: String
    let projectedPoints: Double
    let sport: String
    let lastSeasonHR: Int
    /// Market average draft position (FantasyFootballCalculator). PPR is
    /// the 1-QB board; 2QB is the superflex board where QBs rise. NFL only.
    var adpPPR: Double? = nil
    var adp2QB: Double? = nil
    /// EPL/CFB: average fantasy points per game actually played, from
    /// the most recent season with data (real appearances, unlike the
    /// PROJ column's season-total ÷ scheduled-games which dilutes
    /// rotation players and short seasons).
    var avgPointsPerMatch: Double? = nil

    /// The board-relevant ADP for a league's format.
    func adp(superflex: Bool) -> Double? {
        superflex ? (adp2QB ?? adpPPR) : adpPPR
    }
}

/// "Ja'Marr Chase Jr." -> "jamarrchase" for cross-source matching.
func bbNormalizeName(_ name: String) -> String {
    var s = name.lowercased()
    for suffix in [" jr.", " jr", " sr.", " sr", " iii", " ii", " iv", " v"] {
        if s.hasSuffix(suffix) { s = String(s.dropLast(suffix.count)) }
    }
    return s.filter { $0.isLetter }
}

/// Free NFL ADP from FantasyFootballCalculator (no key): real market
/// draft position in PPR (1-QB) and 2QB (superflex) formats.
enum FFCADPProvider {
    struct Board {
        /// "normname|POS" -> (pprADP, twoQBADP)
        var byNamePos: [String: (ppr: Double?, twoQB: Double?)] = [:]
        /// unique normname -> same (fallback when position labels differ)
        var byName: [String: (ppr: Double?, twoQB: Double?)] = [:]
    }

    static func fetchBoard() async -> Board {
        let year = Calendar.current.component(.year, from: Date())
        var board = Board()
        for (formatIndex, format) in ["ppr", "2qb"].enumerated() {
            var entries: [(name: String, pos: String, adp: Double)] = []
            for tryYear in [year, year - 1] {
                entries = await fetchFormat(format: format, year: tryYear)
                if entries.count >= 50 { break }
            }
            for entry in entries {
                let key = "\(bbNormalizeName(entry.name))|\(entry.pos)"
                var pair = board.byNamePos[key] ?? (nil, nil)
                if formatIndex == 0 { pair.ppr = entry.adp } else { pair.twoQB = entry.adp }
                board.byNamePos[key] = pair
            }
        }
        // Name-only fallback: only for names that map to exactly one
        // (name, position) entry — same-name different-position players
        // stay position-keyed only.
        var posKeysByName: [String: [String]] = [:]
        for key in board.byNamePos.keys {
            let norm = key.components(separatedBy: "|").first ?? key
            posKeysByName[norm, default: []].append(key)
        }
        for (norm, keys) in posKeysByName where keys.count == 1 {
            board.byName[norm] = board.byNamePos[keys[0]]
        }
        return board
    }

    private static func fetchFormat(format: String, year: Int) async -> [(name: String, pos: String, adp: Double)] {
        guard let url = URL(string: "https://fantasyfootballcalculator.com/api/v1/adp/\(format)?teams=12&year=\(year)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let players = json["players"] as? [[String: Any]] else { return [] }
        return players.compactMap { p in
            guard let name = p["name"] as? String,
                  let pos = p["position"] as? String else { return nil }
            let adp = (p["adp"] as? Double) ?? (p["adp"] as? Int).map(Double.init) ?? 0
            guard adp > 0 else { return nil }
            return (name, pos, adp)
        }
    }
}

/// NFL bye weeks by team abbreviation, one ESPN fantasy-API request for
/// all 32 teams. Abbreviations match the site-API roster abbreviations
/// the player pool uses (WSH, JAX, LAR, ...). Cached per season in
/// UserDefaults so drafts don't refetch on every open.
enum NFLByeWeekProvider {
    /// NFL season year: Jan/Feb still belong to the prior season.
    static var seasonYear: Int {
        let now = Date()
        let year = Calendar.current.component(.year, from: now)
        let month = Calendar.current.component(.month, from: now)
        return month <= 2 ? year - 1 : year
    }

    static func fetchByeWeeks() async -> [String: Int] {
        let season = seasonYear
        let cacheKey = "nfl_bye_weeks_\(season)"
        if let cached = UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: Int],
           !cached.isEmpty {
            return cached
        }
        guard let url = URL(string: "https://lm-api-reads.fantasy.espn.com/apis/v3/games/ffl/seasons/\(season)?view=proTeamSchedules_wl"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let settings = json["settings"] as? [String: Any],
              let proTeams = settings["proTeams"] as? [[String: Any]] else { return [:] }
        var byes: [String: Int] = [:]
        for team in proTeams {
            guard let abbrev = team["abbrev"] as? String,
                  let bye = team["byeWeek"] as? Int, bye > 0 else { continue }
            byes[abbrev.uppercased()] = bye
        }
        if !byes.isEmpty {
            UserDefaults.standard.set(byes, forKey: cacheKey)
        }
        return byes
    }
}

/// CFB bye weeks by team abbreviation. Unlike the NFL's single bye, a
/// CFB team can have several open weeks in the Best Ball grid; we report
/// the unplayed weeks strictly inside the team's scheduled span (first →
/// last regular-season game) so the post-championship tail doesn't read
/// as a bye for every team. One schedule request per power-conference
/// team, cached per season in UserDefaults.
enum CFBByeWeekProvider {
    static var seasonYear: Int {
        let now = Date()
        let year = Calendar.current.component(.year, from: now)
        let month = Calendar.current.component(.month, from: now)
        return month <= 1 ? year - 1 : year
    }

    static func fetchByeWeeks() async -> [String: [Int]] {
        let season = seasonYear
        // v2: v1 tables were computed with the broken date parse and cached.
        let cacheKey = "cfb_bye_weeks_v2_\(season)"
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let cached = try? JSONDecoder().decode([String: [Int]].self, from: data),
           !cached.isEmpty {
            return cached
        }

        // Same power-conference membership the player pool uses.
        let teamIDs = await fetchPowerConferenceTeamIDs(season: season)
        guard !teamIDs.isEmpty else { return [:] }
        let teams = (await fetchTeamAbbreviations()).filter { teamIDs.contains($0.id) }
        guard !teams.isEmpty else { return [:] }

        // Precompute the Best Ball week windows once.
        let totalWeeks = BestBallSeasonHelper.totalWeeks(for: "CFB")
        let ranges: [(week: Int, start: Date, end: Date)] = (1...totalWeeks).map { week in
            let (s, e) = BestBallSeasonHelper.weekDateRange(sport: "CFB", week: week)
            return (week, s, e.addingTimeInterval(24 * 3600))  // end-of-day inclusive
        }

        // Dedicated session: ~138 schedule fetches through the shared
        // 6-connections-per-host session took 30s+ mid-draft and timed
        // out partially on slow networks.
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 24
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config)

        var byes: [String: [Int]] = [:]
        await withTaskGroup(of: (String, [Int])?.self) { group in
            for team in teams {
                group.addTask {
                    guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/football/college-football/teams/\(team.id)/schedule?season=\(season)&seasontype=2"),
                          let (data, response) = try? await session.data(from: url),
                          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let events = json["events"] as? [[String: Any]], !events.isEmpty else { return nil }
                    let fmt = ISO8601DateFormatter()
                    fmt.formatOptions = [.withInternetDateTime]
                    var playedWeeks = Set<Int>()
                    for event in events {
                        guard let dateStr = event["date"] as? String else { continue }
                        // ESPN schedule dates lack seconds ("2026-09-05T16:00Z",
                        // 17 chars) — insert them. The old hasSuffix(":00Z")
                        // check confused on-the-hour MINUTES for seconds, so
                        // every top-of-the-hour kickoff failed to parse and
                        // read as a bye week (the "3,4,5,6,7" garbage).
                        let normalized = dateStr.count == 17
                            ? String(dateStr.dropLast()) + ":00Z"
                            : dateStr
                        guard let date = fmt.date(from: normalized) ?? fmt.date(from: dateStr) else { continue }
                        if let hit = ranges.first(where: { date >= $0.start && date < $0.end }) {
                            playedWeeks.insert(hit.week)
                        }
                    }
                    guard let first = playedWeeks.min(), let last = playedWeeks.max() else { return nil }
                    let open = (first...last).filter { !playedWeeks.contains($0) }
                    return (team.abbreviation.uppercased(), open)
                }
            }
            for await item in group {
                if let (abbr, open) = item { byes[abbr] = open }
            }
        }
        // Only cache a substantially complete table — caching a partial
        // fetch (network flake) used to freeze "no bye shown" for most
        // teams permanently.
        if byes.count >= (teams.count * 9) / 10, let encoded = try? JSONEncoder().encode(byes) {
            UserDefaults.standard.set(encoded, forKey: cacheKey)
        }
        return byes
    }

    /// Power-conference + independents team IDs (same ESPN group IDs the
    /// Best Ball CFB player pool uses). Tries this season, then last.
    private static func fetchPowerConferenceTeamIDs(season: Int) async -> Set<String> {
        for seasonYear in [season, season - 1] {
            var ids = Set<String>()
            await withTaskGroup(of: [String].self) { group in
                for groupID in [1, 4, 5, 8, 9, 12, 15, 17, 18, 37, 151] {
                    group.addTask {
                        let urlString = "https://sports.core.api.espn.com/v2/sports/football/leagues/college-football/seasons/\(seasonYear)/types/2/groups/\(groupID)/teams?limit=40"
                        guard let url = URL(string: urlString),
                              let (data, response) = try? await URLSession.shared.data(from: url),
                              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let items = json["items"] as? [[String: Any]] else { return [] }
                        return items.compactMap { item in
                            guard let ref = item["$ref"] as? String,
                                  let idPart = ref.split(separator: "?").first?.split(separator: "/").last else { return nil }
                            return String(idPart)
                        }
                    }
                }
                for await batch in group { ids.formUnion(batch) }
            }
            if !ids.isEmpty { return ids }
        }
        return []
    }

    private static func fetchTeamAbbreviations() async -> [(id: String, abbreviation: String)] {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/football/college-football/teams?limit=1000"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sportsList = json["sports"] as? [[String: Any]],
              let leagues = sportsList.first?["leagues"] as? [[String: Any]],
              let teams = leagues.first?["teams"] as? [[String: Any]] else { return [] }
        return teams.compactMap { wrapper in
            guard let team = wrapper["team"] as? [String: Any],
                  let id = team["id"] as? String ?? (team["id"] as? Int).map({ String($0) }),
                  let abbr = team["abbreviation"] as? String else { return nil }
            return (id, abbr)
        }
    }
}

struct BestBallWeeklyScore: Identifiable, Equatable {
    let id: String
    let leagueID: String
    let memberID: String
    let week: Int
    let totalPoints: Double
    let scoringPlayerIDs: [String]
    let playerPoints: [String: Double]
    let playerStats: [String: [String: Double]]
    let opponentMemberID: String?
    let matchupResult: String?   // "win", "loss", "pending", nil
}

struct BestBallStanding: Identifiable, Equatable {
    let id: String
    let leagueID: String
    let memberID: String
    var totalPoints: Double
    var weeksScored: Int
    var rank: Int
    var wins: Int
    var losses: Int
}

// MARK: - H2H Matchup

struct BestBallMatchup: Identifiable, Equatable {
    var id: String { "\(week)-\(member1ID)-\(member2ID)" }
    let week: Int
    let member1ID: String
    let member2ID: String
    var member1Score: Double
    var member2Score: Double
    var winnerID: String?
}

// MARK: - Player Game Stats (full stat line)

struct BestBallPlayerGameStats: Identifiable, Equatable {
    let id: String
    let playerID: String
    let date: Date
    let opponent: String
    let stats: [String: Double]
    let fantasyPoints: Double
    let gameState: String
}

// MARK: - Daily Score

struct BestBallDailyScore: Identifiable, Equatable {
    let id: String
    let leagueID: String
    let memberID: String
    let week: Int
    let gameDate: Date
    let playerPoints: [String: Double]
    let playerStats: [String: [String: Double]]
}

// MARK: - Draft State

struct BestBallDraftState: Equatable {
    let league: BestBallLeague
    let members: [BestBallMember]
    let picks: [BestBallPick]
    let availablePlayers: [BestBallPlayer]

    var totalPicks: Int { league.rosterSize * members.count }
    var isDraftComplete: Bool { picks.count >= totalPicks }
    var currentPickNumber: Int { picks.count + 1 }

    var currentRound: Int {
        ((currentPickNumber - 1) / members.count) + 1
    }

    var positionInRound: Int {
        let indexInRound = (currentPickNumber - 1) % members.count
        let isReverse = currentRound % 2 == 0
        return isReverse ? (members.count - 1 - indexInRound) : indexInRound
    }

    var onTheClockMemberID: String? {
        guard !isDraftComplete else { return nil }
        let draftPosition = positionInRound
        // Use the league's shuffled draft order if available, otherwise fall back to slotIndex
        if !league.draftOrder.isEmpty, draftPosition < league.draftOrder.count {
            return league.draftOrder[draftPosition]
        }
        return members.first(where: { $0.slotIndex == draftPosition })?.id
    }

    func roster(for memberID: String) -> [BestBallPick] {
        picks.filter { $0.memberID == memberID }
    }

    func pickedPlayerIDs() -> Set<String> {
        Set(picks.map { $0.playerID })
    }
}

// MARK: - Position Configuration

struct BestBallPositionRequirement {
    let label: String
    let count: Int
    let eligible: Set<String>
}

enum BestBallLineupConfig {
    static func requirements(for sport: String, pitcherSlots: Int = 2, batterSlots: Int = 6, scoringMode: BestBallScoringMode = .normal, nflQB: Int = 1, nflRB: Int = 2, nflWR: Int = 2, nflTE: Int = 1, nflFLEX: Int = 2, nflSFLEX: Int = 0, eplGK: Int = 1, eplDEF: Int = 3, eplMID: Int = 4, eplFWD: Int = 2, eplFLEX: Int = 1) -> (starters: Int, constraints: [BestBallPositionRequirement]) {
        switch sport {
        case "NBA":
            // For NBA, total starters = pitcherSlots + batterSlots (reused as generic starters)
            let total = pitcherSlots + batterSlots
            return (total, [
                BestBallPositionRequirement(label: "PG", count: 1, eligible: ["PG"]),
                BestBallPositionRequirement(label: "SG", count: 1, eligible: ["SG"]),
                BestBallPositionRequirement(label: "SF", count: 1, eligible: ["SF"]),
                BestBallPositionRequirement(label: "PF", count: 1, eligible: ["PF"]),
                BestBallPositionRequirement(label: "C",  count: 1, eligible: ["C"]),
                BestBallPositionRequirement(label: "FLEX", count: max(0, total - 5), eligible: ["PG", "SG", "SF", "PF", "C"]),
            ])
        case "MLB":
            if scoringMode == .dingersOnly {
                // Dingers only: all batter slots, no pitchers
                return (batterSlots, [
                    BestBallPositionRequirement(label: "UTIL", count: batterSlots, eligible: ["C", "1B", "2B", "3B", "SS", "LF", "CF", "RF", "OF", "DH"]),
                ])
            }
            return (pitcherSlots + batterSlots, [
                BestBallPositionRequirement(label: "P",    count: pitcherSlots, eligible: ["SP", "P"]),
                BestBallPositionRequirement(label: "UTIL", count: batterSlots, eligible: ["C", "1B", "2B", "3B", "SS", "LF", "CF", "RF", "OF", "DH"]),
            ])
        case "EPL":
            // Commissioner-configurable XI (defaults to 1 GK / 3 DEF /
            // 4 MID / 2 FWD / 1 FLEX). FLEX takes any outfield player so
            // the optimizer can morph between 3-5-2 / 3-4-3 / 4-4-2.
            var constraints: [BestBallPositionRequirement] = []
            if eplGK > 0 { constraints.append(BestBallPositionRequirement(label: "GK", count: eplGK, eligible: ["GK"])) }
            if eplDEF > 0 { constraints.append(BestBallPositionRequirement(label: "DEF", count: eplDEF, eligible: ["DEF"])) }
            if eplMID > 0 { constraints.append(BestBallPositionRequirement(label: "MID", count: eplMID, eligible: ["MID"])) }
            if eplFWD > 0 { constraints.append(BestBallPositionRequirement(label: "FWD", count: eplFWD, eligible: ["FWD"])) }
            if eplFLEX > 0 { constraints.append(BestBallPositionRequirement(label: "FLEX", count: eplFLEX, eligible: ["DEF", "MID", "FWD"])) }
            return (eplGK + eplDEF + eplMID + eplFWD + eplFLEX, constraints)
        case "NFL", "CFB":
            // Commissioner-configurable lineup. Standard FLEX = RB/WR/TE
            // (no QB); Superflex (SFLEX) = QB/RB/WR/TE for leagues that
            // want a second-QB-eligible flex slot.
            var constraints: [BestBallPositionRequirement] = []
            if nflQB > 0 { constraints.append(BestBallPositionRequirement(label: "QB", count: nflQB, eligible: ["QB"])) }
            if nflRB > 0 { constraints.append(BestBallPositionRequirement(label: "RB", count: nflRB, eligible: ["RB"])) }
            if nflWR > 0 { constraints.append(BestBallPositionRequirement(label: "WR", count: nflWR, eligible: ["WR"])) }
            if nflTE > 0 { constraints.append(BestBallPositionRequirement(label: "TE", count: nflTE, eligible: ["TE"])) }
            if nflFLEX > 0 { constraints.append(BestBallPositionRequirement(label: "FLEX", count: nflFLEX, eligible: ["RB", "WR", "TE"])) }
            if nflSFLEX > 0 { constraints.append(BestBallPositionRequirement(label: "SFLEX", count: nflSFLEX, eligible: ["QB", "RB", "WR", "TE"])) }
            return (nflQB + nflRB + nflWR + nflTE + nflFLEX + nflSFLEX, constraints)
        default:
            return (8, [])
        }
    }

    /// Convenience overload that pulls NFL config straight off the
    /// league object so callers don't have to hand-thread five Ints.
    static func requirements(for league: BestBallLeague) -> (starters: Int, constraints: [BestBallPositionRequirement]) {
        // NBA positional config (new leagues persist explicit counts;
        // pre-config leagues fall through to the legacy shape below).
        if league.sport == "NBA", let pg = league.nbaPgStarters {
            let sg = league.nbaSgStarters ?? 1
            let sf = league.nbaSfStarters ?? 1
            let pf = league.nbaPfStarters ?? 1
            let c = league.nbaCStarters ?? 1
            let flex = league.nbaFlexStarters ?? 3
            var constraints: [BestBallPositionRequirement] = []
            if pg > 0 { constraints.append(BestBallPositionRequirement(label: "PG", count: pg, eligible: ["PG"])) }
            if sg > 0 { constraints.append(BestBallPositionRequirement(label: "SG", count: sg, eligible: ["SG"])) }
            if sf > 0 { constraints.append(BestBallPositionRequirement(label: "SF", count: sf, eligible: ["SF"])) }
            if pf > 0 { constraints.append(BestBallPositionRequirement(label: "PF", count: pf, eligible: ["PF"])) }
            if c > 0 { constraints.append(BestBallPositionRequirement(label: "C", count: c, eligible: ["C"])) }
            if flex > 0 { constraints.append(BestBallPositionRequirement(label: "FLEX", count: flex, eligible: ["PG", "SG", "SF", "PF", "C"])) }
            return (pg + sg + sf + pf + c + flex, constraints)
        }
        return requirements(
            for: league.sport,
            pitcherSlots: league.pitcherSlots,
            batterSlots: league.batterSlots,
            scoringMode: league.scoringMode,
            nflQB: league.nflQbStarters,
            nflRB: league.nflRbStarters,
            nflWR: league.nflWrStarters,
            nflTE: league.nflTeStarters,
            nflFLEX: league.nflFlexStarters,
            nflSFLEX: league.nflSflexStarters,
            eplGK: league.eplGkStarters ?? 1,
            eplDEF: league.eplDefStarters ?? 3,
            eplMID: league.eplMidStarters ?? 4,
            eplFWD: league.eplFwdStarters ?? 2,
            eplFLEX: league.eplFlexStarters ?? 1
        )
    }

    /// Minimum positions a roster must have by end of draft.
    static func draftMinimums(for sport: String, pitcherSlots: Int = 2, batterSlots: Int = 6, nflQB: Int = 1, nflRB: Int = 2, nflWR: Int = 2, nflTE: Int = 1, eplGK: Int = 1, eplDEF: Int = 3, eplMID: Int = 4, eplFWD: Int = 2) -> [String: Int] {
        switch sport {
        case "NBA": return ["PG": 1, "SG": 1, "SF": 1, "PF": 1, "C": 1]
        case "EPL":
            var mins: [String: Int] = [:]
            if eplGK > 0 { mins["GK"] = eplGK }
            if eplDEF > 0 { mins["DEF"] = eplDEF }
            if eplMID > 0 { mins["MID"] = eplMID }
            if eplFWD > 0 { mins["FWD"] = eplFWD }
            return mins
        case "MLB": return ["SP": pitcherSlots]  // Must fill pitcher starter slots; batters handled by balanced pick logic
        case "NFL", "CFB":
            var mins: [String: Int] = [:]
            if nflQB > 0 { mins["QB"] = nflQB }
            if nflRB > 0 { mins["RB"] = nflRB }
            if nflWR > 0 { mins["WR"] = nflWR }
            if nflTE > 0 { mins["TE"] = nflTE }
            return mins
        default: return [:]
        }
    }

    /// Stat labels to display per sport
    static func statLabels(for sport: String, isPitcher: Bool = false) -> [String] {
        switch sport {
        case "NBA": return ["PTS", "REB", "AST", "STL", "BLK", "TO"]
        case "MLB" where isPitcher: return ["IP", "K", "ER", "W", "SV"]
        case "MLB": return ["H", "AB", "HR", "RBI", "R", "BB", "K", "SB"]
        case "NFL", "CFB": return ["PYDS", "PTD", "INT", "RYDS", "RTD", "REC", "RECYDS", "RECTD"]
        case "EPL": return ["G", "A", "SOT", "SH", "SV", "YC", "RC"]
        default: return []
        }
    }

    /// Whether a position string represents a pitcher (RP excluded from best ball drafts).
    static func isPitcher(_ position: String) -> Bool {
        ["SP", "P"].contains(position)
    }

    /// Assigns a set of scoring (starter) player IDs to ordered roster slots.
    /// Position-specific constraints (QB/RB/WR/TE) get filled first by the
    /// highest-scoring eligible player, then FLEX picks up whatever's left.
    /// Returns slots in the canonical lineup order — `[("QB", id), ("RB", id),
    /// ("RB", id), ("WR", id), ("WR", id), ("TE", id), ("FLEX", id), ("FLEX", id)]`
    /// for the default NFL config — which is what both the matchup and roster
    /// UIs render side-by-side.
    static func assignStartersToSlots(
        scoringIDs: [String],
        positions: [String: String],
        points: [String: Double],
        constraints: [BestBallPositionRequirement]
    ) -> [(label: String, playerID: String)] {
        var remaining = scoringIDs.sorted { (points[$0] ?? 0) > (points[$1] ?? 0) }
        var result: [(label: String, playerID: String)] = []

        // Two passes: position-specific constraints first (so a top WR
        // doesn't get stolen by a FLEX/SFLEX slot), then flex absorbs
        // the rest. SFLEX (Superflex, QB-eligible) is also deferred so
        // a dedicated QB slot fills before the Superflex grabs a QB.
        let flexLabels: Set<String> = ["FLEX", "SFLEX"]
        let primary = constraints.filter { !flexLabels.contains($0.label) }
        let flex = constraints.filter { flexLabels.contains($0.label) }

        for constraint in primary {
            for _ in 0..<constraint.count {
                if let idx = remaining.firstIndex(where: {
                    if let pos = positions[$0] { return constraint.eligible.contains(pos) }
                    return false
                }) {
                    result.append((label: constraint.label, playerID: remaining.remove(at: idx)))
                }
            }
        }
        for constraint in flex {
            for _ in 0..<constraint.count {
                if let idx = remaining.firstIndex(where: {
                    if let pos = positions[$0] { return constraint.eligible.contains(pos) }
                    return false
                }) {
                    result.append((label: constraint.label, playerID: remaining.remove(at: idx)))
                }
                // No eligible player left → the slot stays EMPTY. The old
                // fallback shoved the next-best player in regardless of
                // position, which displayed (and scored) a QB in the
                // RB/WR/TE FLEX slot on QB-overloaded rosters.
            }
        }
        return result
    }

    /// Human-readable scoring formula blurb for a given sport.
    static func scoringDescription(for sport: String, scoringMode: BestBallScoringMode = .normal) -> String {
        switch sport {
        case "NBA":
            return """
            NBA Fantasy Points:
            PTS ×1.0 · REB ×1.2 · AST ×1.5 · STL ×3.0 · BLK ×3.0 · TO ×−1.0
            """
        case "MLB" where scoringMode == .dingersOnly:
            return """
            Dingers Only:
            Each batter's score = raw HR count
            Season standings = total HRs across all weeks
            No W-L matchups — pure HR leaderboard
            """
        case "MLB":
            return """
            MLB Batter Points:
            1B ×3 · 2B ×5 · 3B ×8 · HR ×10 · RBI ×2 · R ×2 · BB ×2 · SB ×5 · K ×−0.5

            MLB Pitcher Points:
            IP ×3 · K ×2 · W ×5 · ER ×−2 · SV ×5
            """
        case "NFL", "CFB":
            return """
            Football Fantasy Points:
            Pass YDS ×0.04 · Pass TD ×4 · INT ×−1
            Rush YDS ×0.1 · Rush TD ×6
            REC ×1 · Rec YDS ×0.1 · Rec TD ×6 · FUM ×−2
            """
        case "EPL":
            return """
            Soccer Fantasy Points (DK-style):
            Goal ×10 · Assist ×6 · Shot ×1 · Shot on Goal ×+1
            Cross ×0.7 · Shot Assist ×1 · Accurate Pass ×0.02
            Foul Drawn ×1 · Foul ×−0.5 · Tackle Won ×1 · INT ×0.5
            YC ×−1.5 · RC ×−3
            DEF: Clean Sheet +3
            GK: Save ×2 · Goal Against ×−2 · Clean Sheet +5 · Win +5
            """
        default:
            return ""
        }
    }
}

// MARK: - Schedule Generator

enum BestBallScheduleGenerator {
    /// Round-robin schedule. Returns [week][ [memberA, memberB], ... ].
    /// Odd member counts get a rotating bye (that member simply has no
    /// matchup that week) — the old even-only guard returned [] for odd
    /// leagues, which then got PERSISTED as an empty schedule and left
    /// the Matchup tab on "No matchup found" forever.
    static func generateSchedule(memberIDs: [String], totalWeeks: Int) -> [[[String]]] {
        guard memberIDs.count >= 2, totalWeeks > 0 else { return [] }

        let bye = "__bye__"
        var ids = memberIDs
        if ids.count % 2 != 0 { ids.append(bye) }
        let n = ids.count
        var rounds: [[[String]]] = []

        // Circle method: fix first element, rotate the rest
        for _ in 0..<(n - 1) {
            var weekMatchups: [[String]] = []
            for i in 0..<(n / 2) {
                let a = ids[i], b = ids[n - 1 - i]
                if a == bye || b == bye { continue }
                weekMatchups.append([a, b])
            }
            rounds.append(weekMatchups)
            // Rotate: keep first, shift rest
            let last = ids.removeLast()
            ids.insert(last, at: 1)
        }

        // Extend to totalWeeks by repeating the cycle
        var schedule: [[[String]]] = []
        for w in 0..<totalWeeks {
            schedule.append(rounds[w % rounds.count])
        }
        return schedule
    }
}

// MARK: - Scoring Engine

enum BestBallScoringEngine {
    /// Position-constrained best-ball optimizer.
    /// Enumerates C(N, starters) combos — for 12-choose-8 = 495, trivially fast.
    static func bestBallScore(
        playerPoints: [String: Double],
        playerPositions: [String: String],
        sport: String,
        scoringSlots: Int,
        pitcherSlots: Int = 2,
        batterSlots: Int = 6,
        scoringMode: BestBallScoringMode = .normal,
        nflQB: Int = 1,
        nflRB: Int = 2,
        nflWR: Int = 2,
        nflTE: Int = 1,
        nflFLEX: Int = 2,
        nflSFLEX: Int = 0,
        eplGK: Int = 1,
        eplDEF: Int = 3,
        eplMID: Int = 4,
        eplFWD: Int = 2,
        eplFLEX: Int = 1
    ) -> (total: Double, scoringIDs: [String]) {
        let (starters, constraints) = BestBallLineupConfig.requirements(
            for: sport,
            pitcherSlots: pitcherSlots, batterSlots: batterSlots,
            scoringMode: scoringMode,
            nflQB: nflQB, nflRB: nflRB, nflWR: nflWR, nflTE: nflTE, nflFLEX: nflFLEX, nflSFLEX: nflSFLEX,
            eplGK: eplGK, eplDEF: eplDEF, eplMID: eplMID, eplFWD: eplFWD, eplFLEX: eplFLEX
        )
        let candidates = playerPoints.sorted { $0.value > $1.value }

        guard !constraints.isEmpty else {
            // No positional rules (legacy slot-less shapes): top-N by points.
            let topN = Array(candidates.prefix(scoringSlots))
            return (topN.reduce(0.0) { $0 + $1.value }, topN.map { $0.key })
        }

        let playerIDs = candidates.map { $0.key }
        let count = min(starters, playerIDs.count)
        var bestTotal = -Double.infinity
        var bestLineup: [String] = []

        for combo in combinations(of: Array(0..<playerIDs.count), choose: count) {
            let lineup = combo.map { playerIDs[$0] }
            if satisfiesConstraints(lineup: lineup, positions: playerPositions, constraints: constraints) {
                let total = lineup.reduce(0.0) { $0 + (playerPoints[$1] ?? 0) }
                if total > bestTotal {
                    bestTotal = total
                    bestLineup = lineup
                }
            }
        }

        if bestLineup.isEmpty {
            // The constraints can't ALL be filled from this roster (a
            // QB-heavy team with no FLEX-eligible player left, or fewer
            // scored players than starters). Score the best PARTIAL
            // lineup — fill the slots that are fillable, leave the rest
            // empty — instead of the old top-N-regardless-of-position
            // fallback, which quietly scored a 6-QB "lineup" in a 1-QB
            // league.
            let assigned = BestBallLineupConfig.assignStartersToSlots(
                scoringIDs: playerIDs,
                positions: playerPositions,
                points: playerPoints,
                constraints: constraints
            )
            let ids = assigned.map(\.playerID)
            return (ids.reduce(0.0) { $0 + (playerPoints[$1] ?? 0) }, ids)
        }
        return (bestTotal, bestLineup)
    }

    private static func combinations(of elements: [Int], choose k: Int) -> [[Int]] {
        guard k > 0, k <= elements.count else { return k == 0 ? [[]] : [] }
        if k == elements.count { return [elements] }

        var result: [[Int]] = []
        func build(_ start: Int, _ current: [Int]) {
            if current.count == k {
                result.append(current)
                return
            }
            let remaining = k - current.count
            for i in start...(elements.count - remaining) {
                build(i + 1, current + [elements[i]])
            }
        }
        build(0, [])
        return result
    }

    private static func satisfiesConstraints(
        lineup: [String],
        positions: [String: String],
        constraints: [BestBallPositionRequirement]
    ) -> Bool {
        var assigned = Set<String>()
        for constraint in constraints {
            var filled = 0
            for playerID in lineup where !assigned.contains(playerID) {
                if let pos = positions[playerID], constraint.eligible.contains(pos) {
                    filled += 1
                    assigned.insert(playerID)
                    if filled >= constraint.count { break }
                }
            }
            if filled < constraint.count { return false }
        }
        return true
    }

    /// Compute standings sorted by wins first, then total points as tiebreaker.
    /// For dingers-only mode, sorts purely by total HRs (stored in totalPoints).
    static func computeStandings(
        weeklyScores: [BestBallWeeklyScore],
        members: [BestBallMember],
        scoringMode: BestBallScoringMode = .normal
    ) -> [BestBallStanding] {
        var pointsByMember: [String: Double] = [:]
        var weeksByMember: [String: Int] = [:]
        var winsByMember: [String: Int] = [:]
        var lossesByMember: [String: Int] = [:]

        for score in weeklyScores {
            pointsByMember[score.memberID, default: 0] += score.totalPoints
            weeksByMember[score.memberID, default: 0] += 1
            if scoringMode == .normal {
                if score.matchupResult == "win" {
                    winsByMember[score.memberID, default: 0] += 1
                } else if score.matchupResult == "loss" {
                    lossesByMember[score.memberID, default: 0] += 1
                }
            }
        }

        let sorted: [BestBallMember]
        if scoringMode == .dingersOnly {
            // Dingers only: sort purely by total HRs
            sorted = members.sorted {
                (pointsByMember[$0.id] ?? 0) > (pointsByMember[$1.id] ?? 0)
            }
        } else {
            // Normal: sort by wins first, then total points
            sorted = members.sorted {
                let w0 = winsByMember[$0.id] ?? 0
                let w1 = winsByMember[$1.id] ?? 0
                if w0 != w1 { return w0 > w1 }
                return (pointsByMember[$0.id] ?? 0) > (pointsByMember[$1.id] ?? 0)
            }
        }

        return sorted.enumerated().map { index, member in
            BestBallStanding(
                id: member.id,
                leagueID: member.leagueID,
                memberID: member.id,
                totalPoints: pointsByMember[member.id] ?? 0,
                weeksScored: weeksByMember[member.id] ?? 0,
                rank: index + 1,
                wins: winsByMember[member.id] ?? 0,
                losses: lossesByMember[member.id] ?? 0
            )
        }
    }

    // MARK: - Fantasy Points Formulas

    nonisolated static func nbaFantasyPoints(pts: Int, reb: Int, ast: Int, stl: Int, blk: Int, tov: Int) -> Double {
        Double(pts) * 1.0 + Double(reb) * 1.2 + Double(ast) * 1.5 + Double(stl) * 3.0 + Double(blk) * 3.0 - Double(tov) * 1.0
    }

    nonisolated static func mlbHitterPoints(singles: Int, doubles: Int, triples: Int, hr: Int, rbi: Int, runs: Int, bb: Int, sb: Int, k: Int) -> Double {
        Double(singles) * 3 + Double(doubles) * 5 + Double(triples) * 8 + Double(hr) * 10 +
        Double(rbi) * 2 + Double(runs) * 2 + Double(bb) * 2 + Double(sb) * 5 - Double(k) * 0.5
    }

    nonisolated static func mlbPitcherPoints(ip: Double, k: Int, w: Int, er: Int, sv: Int) -> Double {
        ip * 3 + Double(k) * 2 + Double(w) * 5 - Double(er) * 2 + Double(sv) * 5
    }

    nonisolated static func nflFantasyPoints(
        passYds: Int, passTD: Int, interceptions: Int,
        rushYds: Int, rushTD: Int,
        recYds: Int, receptions: Int, recTD: Int,
        fumblesLost: Int
    ) -> Double {
        Double(passYds) * 0.04 + Double(passTD) * 4 - Double(interceptions) * 1 +
        Double(rushYds) * 0.1 + Double(rushTD) * 6 +
        Double(recYds) * 0.1 + Double(receptions) * 1 + Double(recTD) * 6 -
        Double(fumblesLost) * 2
    }

    /// Soccer (EPL) scoring. Same shape as the Tiers/DFS soccer formula
    /// but WITHOUT tackles/interceptions/blocks/clearances — those need
    /// one extra core-API request per player per match, which is far too
    /// many calls for a season-long weekly refresh. Clean sheets and
    /// goals-against (which ARE in the summary payload) keep DEF/GK
    /// competitive instead.
    /// DraftKings soccer scoring. The "detail" stats (crosses, shot assists,
    /// accurate passes, tackles won, interceptions) come from ESPN's core
    /// per-athlete statistics endpoint — pass 0 when unavailable and the
    /// summary-derived stats still score.
    nonisolated static func soccerFantasyPoints(
        position: String,
        goals: Int, assists: Int, shotsOnTarget: Int, totalShots: Int,
        saves: Int, yellowCards: Int, redCards: Int,
        foulsDrawn: Int, foulsConceded: Int, goalsAgainst: Int,
        crosses: Int, shotAssists: Int, accuratePasses: Int,
        tacklesWon: Int, interceptions: Int,
        cleanSheet: Bool, gameFinal: Bool, teamWon: Bool
    ) -> Double {
        var pts = 0.0
        pts += Double(goals) * 10.0
        pts += Double(assists) * 6.0
        pts += Double(totalShots) * 1.0          // every shot
        pts += Double(shotsOnTarget) * 1.0       // on-target adds +1 on top
        pts += Double(crosses) * 0.7
        pts += Double(shotAssists) * 1.0
        pts += Double(accuratePasses) * 0.02
        pts += Double(foulsDrawn) * 1.0
        pts -= Double(foulsConceded) * 0.5
        pts += Double(tacklesWon) * 1.0
        pts += Double(interceptions) * 0.5
        pts -= Double(yellowCards) * 1.5
        pts -= Double(redCards) * 3.0
        if position == "DEF" {
            if cleanSheet && gameFinal { pts += 3.0 }
        }
        if position == "GK" {
            pts += Double(saves) * 2.0
            pts -= Double(goalsAgainst) * 2.0
            if cleanSheet && gameFinal { pts += 5.0 }
            if gameFinal && teamWon { pts += 5.0 }
        }
        return pts
    }
}

/// ESPN soccer positions → the four best-ball slots GK/DEF/MID/FWD.
/// Roster endpoints use simple codes ("G"/"D"/"M"/"F"); match summaries
/// use formation codes, often compound ("CD-L", "AM-R") where the token
/// before the dash carries the role. Substitutes come through as "SUB"
/// with no real position and land on the MID default — which also means
/// they never collect DEF/GK clean-sheet bonuses, mirroring the usual
/// 60-minute clean-sheet rule closely enough.
func bbSoccerPosition(_ raw: String) -> String {
    let upper = raw.uppercased().trimmingCharacters(in: .whitespaces)
    let base = upper.split(separator: "-").first.map(String.init) ?? upper
    if base == "G" || base == "GK" || upper.contains("GOALKEEPER") || upper.contains("KEEPER") {
        return "GK"
    }
    if ["D", "DEF", "CB", "CD", "LB", "RB", "LWB", "RWB", "WB", "SW"].contains(base)
        || upper.contains("DEFENDER") || upper.contains("BACK") {
        return "DEF"
    }
    if ["M", "MID", "CM", "CAM", "CDM", "LM", "RM", "AM", "DM"].contains(base)
        || upper.contains("MIDFIELDER") || upper.contains("MIDFIELD") {
        return "MID"
    }
    if ["F", "FWD", "ST", "CF", "LW", "RW", "SS"].contains(base)
        || upper.contains("FORWARD") || upper.contains("STRIKER") || upper.contains("WINGER") {
        return "FWD"
    }
    return "MID"
}

// MARK: - Bot Drafter

enum BestBallBotDrafter {
    private static let botNames = [
        "Bot Alpha", "Bot Bravo", "Bot Charlie", "Bot Delta",
        "Bot Echo", "Bot Foxtrot", "Bot Golf", "Bot Hotel",
        "Bot India", "Bot Juliet", "Bot Kilo", "Bot Lima"
    ]

    static func botName(at index: Int) -> String {
        botNames[index % botNames.count]
    }

    static func pickForBot(
        available: [BestBallPlayer],
        existingRoster: [BestBallPick],
        sport: String,
        rosterSize: Int,
        scoringMode: BestBallScoringMode = .normal,
        pitcherSlots: Int = 2,
        batterSlots: Int = 6,
        nflQB: Int = 1,
        nflRB: Int = 2,
        nflWR: Int = 2,
        nflTE: Int = 1,
        nflFLEX: Int = 2,
        nflSFLEX: Int = 0,
        eplGK: Int = 1,
        eplDEF: Int = 3,
        eplMID: Int = 4,
        eplFWD: Int = 2,
        eplFLEX: Int = 1
    ) -> BestBallPlayer? {
        // Filter out pitchers for dingers-only leagues
        var candidates = available
        if sport == "MLB" && scoringMode == .dingersOnly {
            candidates = candidates.filter { !BestBallLineupConfig.isPitcher($0.position) }
        }

        let minimums = BestBallLineupConfig.draftMinimums(
            for: sport,
            pitcherSlots: pitcherSlots,
            batterSlots: batterSlots,
            nflQB: nflQB, nflRB: nflRB, nflWR: nflWR, nflTE: nflTE,
            eplGK: eplGK, eplDEF: eplDEF, eplMID: eplMID, eplFWD: eplFWD
        )
        let pickedPositions = Dictionary(grouping: existingRoster, by: \.playerPosition)
            .mapValues { $0.count }
        let remainingPicks = rosterSize - existingRoster.count

        // Determine which minimums are NOT yet met
        var neededPositions: [String] = []
        for (pos, minCount) in minimums {
            let have = pickedPositions[pos] ?? 0
            if have < minCount {
                for _ in 0..<(minCount - have) {
                    neededPositions.append(pos)
                }
            }
        }

        let sorted: [BestBallPlayer]
        if scoringMode == .dingersOnly {
            sorted = candidates.sorted { $0.lastSeasonHR > $1.lastSeasonHR }
        } else {
            // Market ADP is a far truer board than raw projections (and the
            // 2QB board reorders QBs correctly for superflex leagues).
            // Players without ADP fall in behind, ordered by projections.
            let isSuperflex = nflSFLEX >= 1 || nflQB >= 2
            sorted = candidates.sorted { a, b in
                switch (a.adp(superflex: isSuperflex), b.adp(superflex: isSuperflex)) {
                case let (x?, y?): return x < y
                case (.some, .none): return true
                case (.none, .some): return false
                default: return a.projectedPoints > b.projectedPoints
                }
            }
        }

        // For MLB: fill starter slots (SP + batters) before allowing bench pitchers
        if sport == "MLB" && scoringMode != .dingersOnly {
            let spCount = (pickedPositions["SP"] ?? 0) + (pickedPositions["P"] ?? 0)
            let batterCount = existingRoster.filter { !BestBallLineupConfig.isPitcher($0.playerPosition) }.count
            let starterSlots = pitcherSlots + batterSlots

            // Priority 1: If we still need SP starters, pick the best SP
            if spCount < pitcherSlots {
                if let bestSP = sorted.first(where: { BestBallLineupConfig.isPitcher($0.position) }) {
                    return bestSP
                }
            }

            // Priority 2: If we still need batters to fill starter slots, pick batters only
            if batterCount < batterSlots {
                if let bestBatter = sorted.first(where: { !BestBallLineupConfig.isPitcher($0.position) }) {
                    return bestBatter
                }
            }

            // Priority 3: Once starters are filled, fill bench with best available (balanced)
            if existingRoster.count >= starterSlots {
                if let balanced = sorted.first(where: { (pickedPositions[$0.position] ?? 0) < 3 }) {
                    return balanced
                }
                return sorted.first
            }
        }

        // If we're running out of picks, force-fill needed positions
        if neededPositions.count >= remainingPicks, let mustFillPos = neededPositions.first {
            if let forced = sorted.first(where: { $0.position == mustFillPos }) {
                return forced
            }
        }

        // NFL-specific draft logic with config-aware position caps. The
        // generic "< 3 of same position" fallback below is fine for MLB
        // (lots of position flexibility) and NBA, but for NFL in a 1-QB
        // league it lets a bot stack a 3rd QB on its bench instead of
        // grabbing the next-best RB/WR. Two phases:
        //   1. Fill any unmet starter minimum first.
        //   2. Pick the best available respecting per-position caps.
        if sport == "NFL" || sport == "CFB" {
            // Phase 1: are we still missing starters?
            if !neededPositions.isEmpty {
                // Pick the highest-ranked player at ANY unmet position.
                if let forced = sorted.first(where: { neededPositions.contains($0.position) }) {
                    return forced
                }
            }
            // Phase 2: useful upper bounds per position, given the
            // configured starting lineup. Standard FLEX is RB/WR/TE
            // only — QBs are only useful past their dedicated slot if
            // the league has Superflex slots (which DO accept QB).
            // Defaults err on the generous side so bots still draft
            // depth at the skill positions.
            let qbCap = max(nflQB, nflQB + nflSFLEX + (nflSFLEX > 0 ? 1 : 0))
            let rbCap = max(nflRB + 2, nflRB + nflFLEX + nflSFLEX + 1)
            let wrCap = max(nflWR + 2, nflWR + nflFLEX + nflSFLEX + 1)
            let teCap = max(nflTE + 1, nflTE + (nflFLEX > 0 || nflSFLEX > 0 ? 1 : 0))
            let positionCaps: [String: Int] = [
                "QB": qbCap, "RB": rbCap, "WR": wrCap, "TE": teCap
            ]
            if let pick = sorted.first(where: {
                let cap = positionCaps[$0.position] ?? Int.max
                return (pickedPositions[$0.position] ?? 0) < cap
            }) {
                return pick
            }
            // Hard fallback (shouldn't normally reach): just take the
            // best available.
            return sorted.first
        }

        // EPL: same two-phase shape as NFL. The generic "< 3 of same
        // position" fallback below would happily hand a bot three
        // goalkeepers; cap GK at dedicated slots + 1 and keep outfield
        // depth sensible (dedicated slots + flex + one bench spare each).
        if sport == "EPL" {
            if !neededPositions.isEmpty {
                if let forced = sorted.first(where: { neededPositions.contains($0.position) }) {
                    return forced
                }
            }
            let positionCaps: [String: Int] = [
                "GK": eplGK == 0 ? 0 : eplGK + 1,
                "DEF": eplDEF + eplFLEX + 1,
                "MID": eplMID + eplFLEX + 1,
                "FWD": eplFWD + eplFLEX + 1,
            ]
            if let pick = sorted.first(where: {
                let cap = positionCaps[$0.position] ?? Int.max
                return (pickedPositions[$0.position] ?? 0) < cap
            }) {
                return pick
            }
            return sorted.first
        }

        // Prefer balanced approach: underrepresented positions (< 3)
        if let balanced = sorted.first(where: { (pickedPositions[$0.position] ?? 0) < 3 }) {
            return balanced
        }
        return sorted.first
    }
}

// MARK: - Protocols

protocol BestBallPlayerProvider {
    /// `cfbPool` narrows the CFB pool ("power" = P4 + Notre Dame); other
    /// sports ignore it.
    func fetchPlayers(sport: String, cfbPool: String?) async throws -> [BestBallPlayer]
}

/// Result from weekly scoring with full stat lines
struct BestBallWeeklyStatsResult {
    let playerPoints: [String: Double]
    let playerStats: [String: [String: Double]]
    let dailyBreakdown: [String: [String: Double]]  // "YYYYMMDD" -> { playerID: points }
    let dailyStats: [String: [String: [String: Double]]]  // "YYYYMMDD" -> { playerID: { stat: val } }
}

protocol BestBallWeeklyScoringProvider {
    func fetchWeeklyPoints(sport: String, playerIDs: [String], weekStartDate: Date, weekEndDate: Date) async throws -> [String: Double]
    func fetchWeeklyPointsWithStats(sport: String, playerIDs: [String], weekStartDate: Date, weekEndDate: Date) async throws -> BestBallWeeklyStatsResult
    /// Bulk fetch: fetches all ESPN data for a week once and returns stats for ALL players found.
    /// Much faster than calling fetchWeeklyPointsWithStats per member since HTTP requests are shared.
    /// `restrictToPlayerIDs` bounds per-player detail fetches (EPL DK stats)
    /// to the players a league actually drafted; nil = no restriction.
    func fetchWeeklyAllPlayerStats(sport: String, weekStartDate: Date, weekEndDate: Date, restrictToPlayerIDs: Set<String>?) async throws -> BestBallWeeklyStatsResult
    /// Lightweight fetch: returns season HR count for each player via ESPN athlete stats endpoint.
    /// Much cheaper than fetching full box scores for every game of the season.
    func fetchSeasonHRCounts(playerIDs: [String]) async -> [String: Int]
}

// MARK: - ESPN Best Ball Player Provider

/// Simple reference-type cache for player projection data
private class BBProjectionCache {
    /// Team-level performance ratings: [teamID: [espnAthleteID: 0-1 rating]]
    var teamRatings: [String: [String: Double]] = [:]
    /// League-wide fantasy point projections from leaders endpoint: [espnAthleteID: projectedPoints]
    var leagueProjections: [String: Double] = [:]
    /// Last season HR counts from ESPN leaders: [espnAthleteID: hrCount]
    var leagueHRCounts: [String: Int] = [:]
    /// Whether league-wide projections have been fetched for a given sport key
    var leagueProjectionsFetched: Set<String> = []
    /// NFL market ADP board (fetched once per session).
    var nflADPBoard: FFCADPProvider.Board?
    /// The season year whose eng.1 leaders actually had data (the new
    /// season's are empty until matches are played).
    var eplLeadersSeason: Int?
    /// EPL avg fantasy points per match played: [playerID: avg].
    var eplAvgPoints: [String: Double] = [:]
    var eplAvgFetched = false
    /// The season year whose CFB leaders had data (empty until games are
    /// played early in a new season, so this is last season until then).
    var cfbLeadersSeason: Int?
    /// CFB avg fantasy points per game played: [playerID: avg].
    var cfbAvgPoints: [String: Double] = [:]
    /// Pool scopes ("all"/"power") whose averages sweep already ran —
    /// the two scopes contain different players.
    var cfbAvgScopesFetched: Set<String> = []
}

struct ESPNBestBallPlayerProvider: BestBallPlayerProvider {
    private let session: URLSession
    private let cache = BBProjectionCache()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchPlayers(sport: String, cfbPool: String? = nil) async throws -> [BestBallPlayer] {
        switch sport {
        case "NBA": return try await fetchSportPlayers(sport: "basketball", league: "nba", sportName: "NBA", teamLimit: 30)
        case "MLB": return try await fetchSportPlayers(sport: "baseball", league: "mlb", sportName: "MLB", teamLimit: 30)
        case "NFL": return try await fetchSportPlayers(sport: "football", league: "nfl", sportName: "NFL", teamLimit: 32)
        case "CFB": return try await fetchSportPlayers(sport: "football", league: "college-football", sportName: "CFB", teamLimit: 140, cfbPool: cfbPool)
        case "EPL": return try await fetchSportPlayers(sport: "soccer", league: "eng.1", sportName: "EPL", teamLimit: 20)
        default: return []
        }
    }

    private func fetchSportPlayers(sport: String, league: String, sportName: String, teamLimit: Int, cfbPool: String? = nil) async throws -> [BestBallPlayer] {
        // Step 1: Fetch league-wide leader stats to get real projections for top players
        try await fetchLeagueWideProjections(sport: sport, league: league, sportName: sportName)

        let teams = try await fetchAllTeams(sport: sport, league: league, cfbPool: cfbPool)
        // Roster fetches in parallel — the CFB pool is ~130 FBS programs
        // now, and 2 sequential requests per team took minutes.
        var players: [BestBallPlayer] = []
        let teamList = Array(teams.prefix(teamLimit))
        await withTaskGroup(of: [BestBallPlayer].self) { group in
            for team in teamList {
                group.addTask {
                    let ratings = (try? await self.fetchTeamPerformanceRatings(sport: sport, league: league, teamID: team.id)) ?? [:]
                    return (try? await self.fetchRoster(sport: sport, league: league, teamID: team.id, teamAbbr: team.abbreviation, sportName: sportName, ratings: ratings)) ?? []
                }
            }
            for await roster in group {
                players.append(contentsOf: roster)
            }
        }
        players = deduplicatePlayers(players)

        // EPL/CFB: attach avg fantasy points per game played — a truer
        // drafting signal than the projection column for rotation and
        // injury-shortened seasons.
        if sportName == "EPL" {
            await attachEPLAverages(to: &players)
        }
        if sportName == "CFB" {
            await attachCFBAverages(to: &players, scope: cfbPool ?? "all")
        }

        // NFL: attach real market ADP (PPR + 2QB superflex boards). The
        // draft board and bots order by ADP; projections are the fallback.
        if sportName == "NFL" {
            if cache.nflADPBoard == nil {
                cache.nflADPBoard = await FFCADPProvider.fetchBoard()
            }
            if let board = cache.nflADPBoard {
                players = players.map { player in
                    var player = player
                    let norm = bbNormalizeName(player.name)
                    let pair = board.byNamePos["\(norm)|\(player.position)"] ?? board.byName[norm]
                    if let pair {
                        player.adpPPR = pair.ppr
                        player.adp2QB = pair.twoQB
                    }
                    return player
                }
            }
        }

        return players.sorted { a, b in
            switch (a.adpPPR, b.adpPPR) {
            case let (x?, y?): return x < y
            case (.some, .none): return true
            case (.none, .some): return false
            default: return a.projectedPoints > b.projectedPoints
            }
        }
    }

    private func fetchAllTeams(sport: String, league: String, cfbPool: String? = nil) async throws -> [BBTeamRef] {
        // CFB: ~755 programs across all divisions is far too many rosters
        // to pull (and the long tail has no fantasy relevance). Take the
        // power conferences + independents (~69 teams) from the core API's
        // season group membership — the site API's `groups` query param is
        // silently ignored (it returns D3 schools).
        if league == "college-football" {
            // "power" pool = ACC (1), Big 12 (4), Big Ten (5), SEC (8),
            // plus Notre Dame (team 87) explicitly — the Independents
            // group would drag in the non-ND randos.
            let isPowerPool = cfbPool == "power"
            let groups = isPowerPool ? [1, 4, 5, 8] : [1, 4, 5, 8, 9, 12, 15, 17, 18, 37, 151]
            var ids = await fetchCFBPowerConferenceTeamIDs(groups: groups)
            guard !ids.isEmpty else { return [] }
            if isPowerPool { ids.insert("87") }   // Notre Dame
            // One site-API call maps every team ID → abbreviation.
            let allTeams = try await fetchTeamsPage(sport: sport, league: league, query: "limit=1000")
            return allTeams.filter { ids.contains($0.id) }
        }
        return try await fetchTeamsPage(sport: sport, league: league, query: "limit=50")
    }

    /// Team IDs for the power conferences + FBS independents from the core
    /// API (ESPN group IDs: ACC 1, Big 12 4, Big Ten 5, SEC 8, Indep 18).
    /// Tries the current season year first, then the prior year (the new
    /// season's group memberships publish over the summer).
    private func fetchCFBPowerConferenceTeamIDs(groups: [Int]) async -> Set<String> {
        let year = Calendar.current.component(.year, from: Date())
        for seasonYear in [year, year - 1] {
            var ids = Set<String>()
            await withTaskGroup(of: [String].self) { group in
                // ACC 1, Big 12 4, Big Ten 5, SEC 8, Pac-12 9, CUSA 12,
                // MAC 15, MWC 17, Independents 18, Sun Belt 37, American 151
                for groupID in groups {
                    group.addTask {
                        let urlString = "https://sports.core.api.espn.com/v2/sports/football/leagues/college-football/seasons/\(seasonYear)/types/2/groups/\(groupID)/teams?limit=40"
                        guard let url = URL(string: urlString),
                              let (data, response) = try? await self.session.data(from: url),
                              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let items = json["items"] as? [[String: Any]] else { return [] }
                        return items.compactMap { item in
                            guard let ref = item["$ref"] as? String,
                                  let idPart = ref.split(separator: "?").first?.split(separator: "/").last else { return nil }
                            return String(idPart)
                        }
                    }
                }
                for await batch in group {
                    ids.formUnion(batch)
                }
            }
            if !ids.isEmpty { return ids }
        }
        return []
    }

    private func fetchTeamsPage(sport: String, league: String, query: String) async throws -> [BBTeamRef] {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(sport)/\(league)/teams?\(query)") else { return [] }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let teamsList = json["sports"] as? [[String: Any]],
              let sportObj = teamsList.first,
              let leagues = sportObj["leagues"] as? [[String: Any]],
              let leagueObj = leagues.first,
              let teams = leagueObj["teams"] as? [[String: Any]] else { return [] }

        return teams.compactMap { wrapper in
            guard let team = wrapper["team"] as? [String: Any],
                  let id = team["id"] as? String ?? (team["id"] as? Int).map({ String($0) }),
                  let abbr = team["abbreviation"] as? String else { return nil }
            return BBTeamRef(id: id, abbreviation: abbr)
        }
    }

    private func fetchRoster(sport: String, league: String, teamID: String, teamAbbr: String, sportName: String, ratings: [String: Double]) async throws -> [BestBallPlayer] {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(sport)/\(league)/teams/\(teamID)/roster") else { return [] }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let athletes = json["athletes"] as? [[String: Any]] else { return [] }

        var players: [BestBallPlayer] = []
        let flatAthletes: [[String: Any]]
        if let firstGroup = athletes.first, firstGroup["items"] != nil {
            flatAthletes = athletes.flatMap { ($0["items"] as? [[String: Any]]) ?? [] }
        } else {
            flatAthletes = athletes
        }

        for athlete in flatAthletes {
            guard let id = athlete["id"] as? String ?? (athlete["id"] as? Int).map({ String($0) }),
                  let fullName = athlete["fullName"] as? String ?? athlete["displayName"] as? String else { continue }
            var positionAbbr: String
            if let pos = athlete["position"] as? [String: Any] {
                positionAbbr = pos["abbreviation"] as? String ?? pos["displayName"] as? String ?? "UTIL"
            } else {
                positionAbbr = "UTIL"
            }
            // ESPN soccer rosters use "G"/"D"/"M"/"F" — map to the
            // GK/DEF/MID/FWD slots the lineup config expects.
            if sportName == "EPL" {
                positionAbbr = bbSoccerPosition(positionAbbr)
            }

            // Skip relief pitchers for MLB — they aren't useful in best ball
            if sportName == "MLB" && positionAbbr == "RP" { continue }
            // Skip non-skill positions for NFL — the lineup config has
            // no K / DEF / OL slot, so they'd just clutter the draft
            // board. Without this, kickers dominate the top of the
            // projection ranking because their raw stat totals (FG made,
            // points scored, etc.) parse out higher than any skill
            // player's per-game fantasy projection.
            if sportName == "NFL" || sportName == "CFB" {
                let skillPositions: Set<String> = ["QB", "RB", "FB", "WR", "TE"]
                if !skillPositions.contains(positionAbbr) { continue }
            }

            let projection: Double
            if let leagueProj = cache.leagueProjections[id] {
                // Use real stat-based projection from league-wide leaders
                projection = leagueProj
            } else {
                // Fallback: use team-level rating scaled to a lower range (these are non-elite players)
                let rating = ratings[id] ?? 0.0
                projection = fallbackProjection(rating: rating, sport: sportName, position: positionAbbr, playerID: id)
            }

            let hrCount = cache.leagueHRCounts[id] ?? 0

            players.append(BestBallPlayer(
                id: "\(sportName.lowercased())-\(id)",
                name: fullName, team: teamAbbr,
                position: positionAbbr, projectedPoints: projection,
                sport: sportName, lastSeasonHR: hrCount
            ))
        }
        return players
    }

    // MARK: - League-Wide Projections from ESPN Leaders

    /// Fetches league-wide stat leaders and computes season-long fantasy point projections.
    /// Uses the ESPN core API leaders endpoint which returns top ~50 players per stat category
    /// with full season stat lines in the displayValue field.
    private func fetchLeagueWideProjections(sport: String, league: String, sportName: String) async throws {
        let cacheKey = "\(sport)-\(league)"
        guard !cache.leagueProjectionsFetched.contains(cacheKey) else { return }
        cache.leagueProjectionsFetched.insert(cacheKey)

        let primarySeason = espnSeasonYear(for: sportName)
        let fallbackSeason = primarySeason - 1

        // For MLB, fetch BOTH current and previous season leaders to maximize player coverage.
        // Early in the season, current-year data is sparse — previous season provides a baseline.
        if sportName == "MLB" {
            await fetchPreviousSeasonHRs(sport: sport, league: league, sportName: sportName)

            // Fetch previous season first as baseline
            if let prevData = await fetchLeadersData(sport: sport, league: league, season: fallbackSeason) {
                parseMLBLeaders(data: prevData, sportName: sportName)
            }

            // Then overlay current season (overwrites previous season projections where available)
            if let currentData = await fetchLeadersData(sport: sport, league: league, season: primarySeason) {
                // Clear previous-season projections for players who have current data
                let prevProjections = cache.leagueProjections
                parseMLBLeaders(data: currentData, sportName: sportName)
                // For players only in previous season (not in current leaders), keep their projection
                for (id, proj) in prevProjections where cache.leagueProjections[id] == nil {
                    cache.leagueProjections[id] = proj
                }
            }
            return
        }

        // EPL: soccer leaders live under season type 1 (types/2 responds
        // 200 with zero categories), and the new season's leaders are
        // empty until matches are played — so parse each season in turn
        // and stop at the first one that yields projections.
        if sportName == "EPL" {
            for season in [primarySeason, fallbackSeason] {
                guard let data = await fetchLeadersData(sport: sport, league: league, season: season, seasonType: 1),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let categories = json["categories"] as? [[String: Any]],
                      !categories.isEmpty else { continue }
                parseSoccerLeaders(categories: categories)
                if !cache.leagueProjections.isEmpty {
                    cache.eplLeadersSeason = season
                    return
                }
            }
            return
        }

        // Non-MLB: try current season first, fall back to previous year.
        // Require non-empty categories — a new season's leaders endpoint
        // can 200 with zero categories before games are played, which
        // used to short-circuit the fallback.
        var fetchedCategories: [[String: Any]]?
        var fetchedSeason: Int?
        for season in [primarySeason, fallbackSeason] {
            if let data = await fetchLeadersData(sport: sport, league: league, season: season),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let cats = json["categories"] as? [[String: Any]], !cats.isEmpty {
                fetchedCategories = cats
                fetchedSeason = season
                break
            }
        }

        guard let categories = fetchedCategories else { return }
        if sportName == "CFB" { cache.cfbLeadersSeason = fetchedSeason }

        if sportName == "NBA" {
            parseNBALeaders(categories: categories)
        } else if sportName == "NFL" || sportName == "CFB" {
            // NFL/CFB: SUM each category's fantasy-point contribution across
            // the player's appearances in different leaderboards. The
            // earlier "first category wins" logic produced nonsense
            // rankings (a kicker's points-scored total beat a QB's
            // passing-yards total, etc.). Now Drake Maye gets credit for
            // his passing yards AND TDs AND rushing where applicable.
            parseNFLLeaders(categories: categories)
        } else {
            for category in categories {
                let categoryName = category["name"] as? String ?? ""
                guard let leaders = category["leaders"] as? [[String: Any]] else { continue }
                for leader in leaders {
                    guard let athleteRef = leader["athlete"] as? [String: Any],
                          let refURL = athleteRef["$ref"] as? String,
                          let displayValue = leader["displayValue"] as? String else { continue }

                    let pathParts = refURL.split(separator: "?").first?.split(separator: "/") ?? []
                    guard let athleteID = pathParts.last.map(String.init) else { continue }

                    guard cache.leagueProjections[athleteID] == nil else { continue }

                    let fpts = computeSeasonProjection(sport: sportName, statLine: displayValue, category: categoryName)
                    if fpts > 0 {
                        cache.leagueProjections[athleteID] = fpts
                    }
                }
            }
        }
    }

    /// Parse NFL leaders by category. ESPN's leaders endpoint groups by
    /// stat category (Passing Yards, Passing TDs, Receiving Yards, etc.)
    /// — convert each category's value into its fantasy-point contribution
    /// using our scoring rules, then accumulate per athlete. Output is
    /// per-game (season total / 17).
    private func parseNFLLeaders(categories: [[String: Any]]) {
        // ESPN sends category identifiers BOTH as `name` (camelCase like
        // "passingYards") AND `displayName` ("Passing Yards"). Normalize
        // both by lowercasing and stripping whitespace so a single set
        // of substring checks matches either format. The earlier code
        // used `c.contains("passing yards")` against the raw lowercase
        // — which silently never matched "passingyards", so a star WR
        // got credit for ONE category at most and projected at ~7 PPG.
        func pointsPerUnit(for rawCategory: String) -> Double? {
            let c = rawCategory.lowercased().replacingOccurrences(of: " ", with: "")
            // More-specific keys first so "passingtouchdowns" doesn't
            // collide with "passing" / "touchdowns" alone.
            if c.contains("passingtouchdowns") || c.contains("passingtd") { return 4.0 }
            if c.contains("passingyards") { return 0.04 }
            if c.contains("interceptionsthrown") || c == "interceptions" { return -1.0 }
            if c.contains("rushingtouchdowns") || c.contains("rushingtd") { return 6.0 }
            if c.contains("rushingyards") { return 0.1 }
            if c.contains("receivingtouchdowns") || c.contains("receivingtd") { return 6.0 }
            if c.contains("receivingyards") { return 0.1 }
            if c.contains("receptions") { return 1.0 }
            if c.contains("fumbleslost") { return -2.0 }
            return nil
        }

        var totals: [String: Double] = [:]
        for category in categories {
            // Try BOTH name and displayName — some ESPN deployments only
            // populate one of them. The matcher tolerates whichever is
            // available.
            let nameRaw = (category["name"] as? String) ?? ""
            let displayName = (category["displayName"] as? String) ?? ""
            let multiplier = pointsPerUnit(for: nameRaw) ?? pointsPerUnit(for: displayName)
            guard let multiplier else { continue }
            guard let leaders = category["leaders"] as? [[String: Any]] else { continue }
            for leader in leaders {
                guard let athleteRef = leader["athlete"] as? [String: Any],
                      let refURL = athleteRef["$ref"] as? String,
                      let displayValue = leader["displayValue"] as? String else { continue }
                let pathParts = refURL.split(separator: "?").first?.split(separator: "/") ?? []
                guard let athleteID = pathParts.last.map(String.init) else { continue }
                // ESPN occasionally returns formatted numbers like "5,409".
                let cleaned = displayValue
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: ",", with: "")
                guard let value = Double(cleaned) else { continue }
                totals[athleteID, default: 0] += value * multiplier
            }
        }
        // Convert season totals → per-game (17 game season). Floor at 0 so
        // a player whose only ESPN-listed stat is INTs doesn't end up
        // ranking below true zero-projection role players.
        for (id, season) in totals where season > 0 {
            cache.leagueProjections[id] = season / 17.0
        }
    }

    /// Sum each leaders category's fantasy-point contribution per athlete
    /// (same accumulation shape as parseNFLLeaders), then ÷38 matches for
    /// a per-week projection. Goals double-dip slightly with the SOT and
    /// total-shots categories, but for draft-board ordering that's fine.
    private func parseSoccerLeaders(categories: [[String: Any]]) {
        func pointsPerUnit(for rawCategory: String) -> Double? {
            // DK-style weights (mirrors soccerFantasyPoints).
            switch rawCategory {
            case "goals": return 10.0
            case "assists": return 6.0
            case "shotsOnTarget": return 1.0
            case "totalShots": return 1.0
            case "saves": return 2.0
            case "foulsSuffered": return 1.0
            case "foulsCommitted": return -0.5
            case "accuratePasses": return 0.02
            case "yellowCards": return -1.5
            case "redCards": return -3.0
            default: return nil   // goalsLeaders/assistsLeaders dupes
            }
        }

        var totals: [String: Double] = [:]
        for category in categories {
            let name = (category["name"] as? String) ?? ""
            guard let multiplier = pointsPerUnit(for: name),
                  let leaders = category["leaders"] as? [[String: Any]] else { continue }
            for leader in leaders {
                guard let athleteRef = leader["athlete"] as? [String: Any],
                      let refURL = athleteRef["$ref"] as? String,
                      let displayValue = leader["displayValue"] as? String else { continue }
                let pathParts = refURL.split(separator: "?").first?.split(separator: "/") ?? []
                guard let athleteID = pathParts.last.map(String.init) else { continue }
                let cleaned = displayValue
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: ",", with: "")
                guard let value = Double(cleaned) else { continue }
                totals[athleteID, default: 0] += value * multiplier
            }
        }
        for (id, season) in totals where season > 0 {
            cache.leagueProjections[id] = season / 38.0
        }
    }

    /// Fetch leaders data for a given season; returns nil if unavailable.
    private func fetchLeadersData(sport: String, league: String, season: Int, seasonType: Int = 2) async -> Data? {
        guard let url = URL(string: "https://sports.core.api.espn.com/v2/sports/\(sport)/leagues/\(league)/seasons/\(season)/types/\(seasonType)/leaders?limit=100") else { return nil }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return data
    }

    /// Parse MLB leaders from raw data, computing projections and HR counts.
    private func parseMLBLeaders(data: Data, sportName: String) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let categories = json["categories"] as? [[String: Any]] else { return }

        for category in categories {
            let categoryName = category["name"] as? String ?? ""
            guard let leaders = category["leaders"] as? [[String: Any]] else { continue }
            for leader in leaders {
                guard let athleteRef = leader["athlete"] as? [String: Any],
                      let refURL = athleteRef["$ref"] as? String,
                      let displayValue = leader["displayValue"] as? String else { continue }

                let pathParts = refURL.split(separator: "?").first?.split(separator: "/") ?? []
                guard let athleteID = pathParts.last.map(String.init) else { continue }

                // Overwrite any existing projection (current season takes priority)
                let fpts = computeSeasonProjection(sport: sportName, statLine: displayValue, category: categoryName)
                if fpts > 0 {
                    cache.leagueProjections[athleteID] = fpts
                }

                // Extract HR count for MLB batters
                if !displayValue.contains(" IP") {
                    let hrCount = extractHRCount(from: displayValue)
                    if hrCount > 0 {
                        cache.leagueHRCounts[athleteID] = max(cache.leagueHRCounts[athleteID] ?? 0, hrCount)
                    }
                }
            }
        }
    }

    /// Fetch previous season's HR leaders for MLB to populate lastSeasonHR.
    /// The current season may have just started with very few games, so we specifically
    /// fetch last year's full-season HR data.
    private func fetchPreviousSeasonHRs(sport: String, league: String, sportName: String) async {
        guard sportName == "MLB" else { return }
        let prevSeason = espnSeasonYear(for: sportName) - 1
        guard let url = URL(string: "https://sports.core.api.espn.com/v2/sports/\(sport)/leagues/\(league)/seasons/\(prevSeason)/types/2/leaders?limit=100") else { return }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let categories = json["categories"] as? [[String: Any]] else { return }

        for category in categories {
            guard let leaders = category["leaders"] as? [[String: Any]] else { continue }
            for leader in leaders {
                guard let athleteRef = leader["athlete"] as? [String: Any],
                      let refURL = athleteRef["$ref"] as? String,
                      let displayValue = leader["displayValue"] as? String,
                      !displayValue.contains(" IP") else { continue }

                let pathParts = refURL.split(separator: "?").first?.split(separator: "/") ?? []
                guard let athleteID = pathParts.last.map(String.init) else { continue }

                let hrCount = extractHRCount(from: displayValue)
                if hrCount > 0 {
                    // Use max of current and previous season (in case current season already has data)
                    cache.leagueHRCounts[athleteID] = max(cache.leagueHRCounts[athleteID] ?? 0, hrCount)
                }
            }
        }
    }

    /// Accumulate NBA per-game stats across categories and compute full fantasy projection.
    /// NBA scoring: PTS×1.0 + REB×1.2 + AST×1.5 + STL×3.0 + BLK×3.0 + TO×−1.0
    private func parseNBALeaders(categories: [[String: Any]]) {
        // Collect per-player stats from relevant categories
        var playerStats: [String: [String: Double]] = [:]  // athleteID -> { "ppg": 30.2, "rpg": 10.1, ... }

        let relevantCategories: Set<String> = ["pointsPerGame", "reboundsPerGame", "assistsPerGame", "stealsPerGame", "blocksPerGame", "avgTurnovers"]

        for category in categories {
            let catName = category["name"] as? String ?? ""
            guard relevantCategories.contains(catName),
                  let leaders = category["leaders"] as? [[String: Any]] else { continue }

            for leader in leaders {
                guard let athleteRef = leader["athlete"] as? [String: Any],
                      let refURL = athleteRef["$ref"] as? String,
                      let displayValue = leader["displayValue"] as? String,
                      let value = Double(displayValue.trimmingCharacters(in: .whitespaces)) else { continue }

                let pathParts = refURL.split(separator: "?").first?.split(separator: "/") ?? []
                guard let athleteID = pathParts.last.map(String.init) else { continue }

                if playerStats[athleteID] == nil { playerStats[athleteID] = [:] }
                playerStats[athleteID]?[catName] = value
            }
        }

        // Compute full fantasy projection for each player
        for (athleteID, stats) in playerStats {
            let ppg = stats["pointsPerGame"] ?? 0
            let rpg = stats["reboundsPerGame"] ?? 0
            let apg = stats["assistsPerGame"] ?? 0
            let spg = stats["stealsPerGame"] ?? 0
            let bpg = stats["blocksPerGame"] ?? 0
            let tpg = stats["avgTurnovers"] ?? 0

            // NBA fantasy formula per game
            let fptsPerGame = ppg * 1.0 + rpg * 1.2 + apg * 1.5 + spg * 3.0 + bpg * 3.0 - tpg * 1.0

            // Convert to weekly: ~3.5 games/week
            let weeklyFPTS = fptsPerGame * 3.5

            // Only store if we have at least PPG (the primary stat)
            if ppg > 0 && weeklyFPTS > 0 {
                cache.leagueProjections[athleteID] = weeklyFPTS
            }
        }
    }

    /// Parse a season stat line string from ESPN leaders and compute weekly fantasy points.
    /// Called for MLB and NFL only — NBA is handled by parseNBALeaders().
    private func computeSeasonProjection(sport: String, statLine: String, category: String) -> Double {
        switch sport {
        case "MLB":
            // Pitcher categories have displayValue like "187.2 IP, 41 ER, ..."
            // Batter categories have displayValue like "179-541, 53 HR, ..."
            if statLine.contains(" IP") {
                return parseMLBPitcherProjection(statLine)
            } else {
                return parseMLBSeasonProjection(statLine)
            }
        case "NFL", "CFB": return parseNFLSeasonProjection(statLine)
        default: return 0
        }
    }

    /// Parse MLB batter stat line: "H-AB, 53 HR, 3B, 30 2B, 114 RBI, 137 R, 124 BB, 12 SB, 160 K"
    /// Note: bare stat labels like "3B" (no number) mean a count of 1.
    /// Compute weekly projected fantasy points from season totals.
    private func parseMLBSeasonProjection(_ statLine: String) -> Double {
        let parts = statLine.components(separatedBy: ", ")
        guard parts.count >= 2 else { return 0 }

        var h = 0, ab = 0, hr = 0, triples = 0, doubles = 0, rbi = 0, runs = 0, bb = 0, sb = 0, k = 0

        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("-") && !trimmed.contains(" ") {
                // H-AB format (e.g. "179-541")
                let hAb = trimmed.split(separator: "-")
                if hAb.count == 2 {
                    h = Int(hAb[0]) ?? 0
                    ab = Int(hAb[1]) ?? 0
                }
            } else if trimmed == "HR" {
                hr = 1
            } else if trimmed.hasSuffix(" HR") {
                hr = Int(trimmed.replacingOccurrences(of: " HR", with: "")) ?? 0
            } else if trimmed == "3B" {
                triples = 1
            } else if trimmed.hasSuffix(" 3B") {
                triples = Int(trimmed.replacingOccurrences(of: " 3B", with: "")) ?? 0
            } else if trimmed == "2B" {
                doubles = 1
            } else if trimmed.hasSuffix(" 2B") {
                doubles = Int(trimmed.replacingOccurrences(of: " 2B", with: "")) ?? 0
            } else if trimmed == "RBI" {
                rbi = 1
            } else if trimmed.hasSuffix(" RBI") {
                rbi = Int(trimmed.replacingOccurrences(of: " RBI", with: "")) ?? 0
            } else if trimmed == "R" {
                runs = 1
            } else if trimmed.hasSuffix(" R") {
                runs = Int(trimmed.replacingOccurrences(of: " R", with: "")) ?? 0
            } else if trimmed == "BB" {
                bb = 1
            } else if trimmed.hasSuffix(" BB") {
                bb = Int(trimmed.replacingOccurrences(of: " BB", with: "")) ?? 0
            } else if trimmed == "SB" {
                sb = 1
            } else if trimmed.hasSuffix(" SB") {
                sb = Int(trimmed.replacingOccurrences(of: " SB", with: "")) ?? 0
            } else if trimmed == "K" {
                k = 1
            } else if trimmed.hasSuffix(" K") {
                k = Int(trimmed.replacingOccurrences(of: " K", with: "")) ?? 0
            }
        }

        // If we couldn't parse H-AB, this might be a pitcher or other format — skip
        guard ab > 0 || h > 0 || hr > 0 else { return 0 }

        // Require minimum 200 AB for reliable rate stats — below this, small-sample
        // specialists (pinch runners, etc.) get inflated per-game projections
        guard ab >= 200 else { return 0 }

        let singles = max(0, h - doubles - triples - hr)
        let seasonTotal = BestBallScoringEngine.mlbHitterPoints(
            singles: singles, doubles: doubles, triples: triples, hr: hr,
            rbi: rbi, runs: runs, bb: bb, sb: sb, k: k
        )

        // Convert season total to per-week projection
        // Assume ~3.8 AB per game, ~6 games per week in best ball
        let gamesPlayed = max(1.0, Double(ab) / 3.8)
        let pointsPerGame = seasonTotal / gamesPlayed
        return pointsPerGame * 6.0  // 6 games/week for MLB
    }

    /// Extract raw HR count from an MLB batter stat line.
    private func extractHRCount(from statLine: String) -> Int {
        for part in statLine.components(separatedBy: ", ") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed == "HR" { return 1 }
            if trimmed.hasSuffix(" HR") {
                return Int(trimmed.replacingOccurrences(of: " HR", with: "")) ?? 0
            }
        }
        return 0
    }

    /// Parse MLB pitcher stat line: "187.2 IP, 41 ER, 136 H, 216 K, 42 BB"
    /// Compute weekly projected fantasy points from season totals.
    private func parseMLBPitcherProjection(_ statLine: String) -> Double {
        let parts = statLine.components(separatedBy: ", ")
        guard parts.count >= 2 else { return 0 }

        var ip = 0.0, er = 0, k = 0

        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix(" IP") {
                // IP can be fractional like "187.2" — the .2 means 2/3 of an inning
                let ipStr = trimmed.replacingOccurrences(of: " IP", with: "")
                ip = Double(ipStr) ?? 0
            } else if trimmed.hasSuffix(" ER") {
                er = Int(trimmed.replacingOccurrences(of: " ER", with: "")) ?? 0
            } else if trimmed.hasSuffix(" K") {
                k = Int(trimmed.replacingOccurrences(of: " K", with: "")) ?? 0
            } else if trimmed == "K" {
                k = 1
            }
        }

        // Require minimum 30 IP for reliable projections
        guard ip >= 30 else { return 0 }

        // Compute season total without W/SV (not available in displayValue)
        // IP×3 + K×2 − ER×2 covers the primary pitcher value
        let seasonTotal = BestBallScoringEngine.mlbPitcherPoints(ip: ip, k: k, w: 0, er: er, sv: 0)

        // Convert season total to per-week: ~26 weeks in MLB season
        return seasonTotal / 26.0
    }



    /// Parse NFL leader displayValue (season total stat).
    private func parseNFLSeasonProjection(_ statLine: String) -> Double {
        guard let value = Double(statLine.trimmingCharacters(in: .whitespaces)) else { return 0 }
        // NFL season totals: convert to per-game (17 games), 1 game/week
        return value / 17.0
    }

    /// Determine the ESPN season year for the current sport. For NFL,
    /// "the season the league will play in" — which during the Mar–Jun
    /// off-season window is the upcoming Sept kickoff (year `year`), not
    /// last fall's season (which already ended at the Super Bowl). The
    /// caller (fetchLeagueWideProjections) also pulls `primarySeason - 1`
    /// as a fallback, so if ESPN hasn't published current-year leaders
    /// yet we still get useful projections from the most recent completed
    /// season — without that fallback being treated as the canonical one.
    private func espnSeasonYear(for sport: String) -> Int {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: Date())
        let month = calendar.component(.month, from: Date())
        switch sport {
        case "NBA":
            return month >= 7 ? year + 1 : year
        case "NFL", "CFB":
            if month >= 7 { return year }
            if month <= 2 { return year - 1 }
            return year                       // Mar–Jun off-season → upcoming season
        case "MLB":
            return month >= 3 ? year : year - 1
        case "EPL":
            // ESPN labels eng.1 seasons by their August start year.
            return month >= 7 ? year : year - 1
        default:
            return year
        }
    }

    // MARK: - Per-Team Performance Ratings (fallback for non-leaders)

    /// Fetches per-team stat leaders from ESPN and computes a 0-1 performance rating for each athlete.
    /// Used as fallback for players who don't appear in league-wide leaders.
    private func fetchTeamPerformanceRatings(sport: String, league: String, teamID: String) async throws -> [String: Double] {
        if let cached = cache.teamRatings[teamID] { return cached }

        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(sport)/\(league)/teams/\(teamID)/athletes/statistics") else { return [:] }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [:] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [:] }

        var rawScores: [String: Double] = [:]
        for result in results {
            guard let leaders = result["leaders"] as? [[String: Any]] else { continue }
            for (index, leader) in leaders.enumerated() {
                guard let athlete = leader["athlete"] as? [String: Any],
                      let athleteID = athlete["id"] as? String ?? (athlete["id"] as? Int).map({ String($0) }) else { continue }
                let placementWeight = max(1.0, 20.0 - Double(index))
                rawScores[athleteID, default: 0.0] += placementWeight
            }
        }

        guard let maxScore = rawScores.values.max(), maxScore > 0 else {
            cache.teamRatings[teamID] = [:]
            return [:]
        }
        let normalized = rawScores.mapValues { $0 / maxScore }
        cache.teamRatings[teamID] = normalized
        return normalized
    }

    /// Fallback projection for players not in league-wide leaders.
    /// These are role players / bench players — projected lower than the leaders.
    private func fallbackProjection(rating: Double, sport: String, position: String, playerID: String) -> Double {
        let clamped = max(0.0, min(1.0, rating))
        // Small stable jitter so identical ratings don't produce identical projections
        let seed = playerID.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        let jitter = Double(abs(seed % 100)) / 500.0

        // These ranges represent non-elite players — below the leaders threshold.
        // The ceiling is set near the bottom of what league leaders typically produce.
        let floor: Double
        let ceiling: Double

        switch sport {
        case "NBA":
            // Non-leaders: role players below the top ~100
            // Leaders bottom out around 50-60 weekly, so cap fallback below that
            floor = 15.0; ceiling = 50.0
        case "MLB":
            // Non-leaders: low-end regulars and bench bats
            // Leader batters bottom out ~31, so cap fallback below that
            floor = 2.0; ceiling = 30.0
        case "NFL", "CFB":
            // Non-leaders: low-tier starters / backups
            floor = 2.0; ceiling = 10.0
        case "EPL":
            // No per-team ratings endpoint exists for soccer, so ratings
            // are all 0 and non-leaders land at the floor — below the
            // ~300 players the leaders pass covers.
            floor = 2.0; ceiling = 10.0
        default:
            floor = 2.0; ceiling = 15.0
        }

        return floor + clamped * (ceiling - floor) + jitter
    }

    private func deduplicatePlayers(_ players: [BestBallPlayer]) -> [BestBallPlayer] {
        var seen = Set<String>()
        return players.filter { seen.insert($0.id).inserted }
    }

    // MARK: - EPL Per-Match Averages

    /// Fetches each pool player's season stat line from the core API and
    /// computes avg fantasy points per match PLAYED. One lightweight
    /// (~20KB) request per player, concurrent, once per session — the
    /// per-team ratings/leaders endpoints don't expose appearances, so
    /// this is the only bulk-free source of a real per-match rate.
    private func attachEPLAverages(to players: inout [BestBallPlayer]) async {
        if !cache.eplAvgFetched {
            cache.eplAvgFetched = true
            // Use the season whose leaders had data (falls back to last
            // season until the new campaign has matches).
            let season = cache.eplLeadersSeason ?? (espnSeasonYear(for: "EPL") - 1)
            var avgs: [String: Double] = [:]
            await withTaskGroup(of: (String, Double)?.self) { group in
                for player in players {
                    let espnID = String(player.id.dropFirst("epl-".count))
                    group.addTask {
                        guard let avg = await self.fetchEPLSeasonAverage(espnID: espnID, season: season) else { return nil }
                        return (player.id, avg)
                    }
                }
                for await item in group {
                    if let (id, avg) = item { avgs[id] = avg }
                }
            }
            cache.eplAvgPoints = avgs
        }
        players = players.map { player in
            var player = player
            player.avgPointsPerMatch = cache.eplAvgPoints[player.id]
            return player
        }
    }

    /// Dedicated session for the per-athlete average sweeps (EPL/CFB) —
    /// hundreds of tiny requests against one host; the default
    /// 6-connections-per-host cap would stretch pool loads by ~10s.
    private static let coreStatsSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 24
        return URLSession(configuration: config)
    }()

    // MARK: - CFB Per-Game Averages

    /// Fetches season stat lines for the draft-relevant CFB players (the
    /// ones the leaders pass projected — fetching all ~1,700 pool players
    /// would be far too many requests) and computes avg fantasy points
    /// per game PLAYED. The PROJ column divides season totals by 17 (the
    /// NFL parser CFB shares), so this is the honest per-game rate for a
    /// 12-13 game college season.
    private func attachCFBAverages(to players: inout [BestBallPlayer], scope: String) async {
        if !cache.cfbAvgScopesFetched.contains(scope) {
            cache.cfbAvgScopesFetched.insert(scope)
            let season = cache.cfbLeadersSeason ?? (espnSeasonYear(for: "CFB") - 1)
            var avgs: [String: Double] = [:]
            await withTaskGroup(of: (String, Double)?.self) { group in
                // The whole pool (~900 players after per-team position
                // caps), not just leaders-projected ones — restricting to
                // leaders left most draftable players showing "–" even
                // when they played last season. ~20KB per request on the
                // 24-connection sweep session; players with no stats last
                // season 404 cheaply. Skip ids an earlier scope already
                // resolved.
                for player in players where cache.cfbAvgPoints[player.id] == nil {
                    let espnID = String(player.id.dropFirst("cfb-".count))
                    group.addTask {
                        guard let avg = await self.fetchCFBSeasonAverage(espnID: espnID, season: season) else { return nil }
                        return (player.id, avg)
                    }
                }
                for await item in group {
                    if let (id, avg) = item { avgs[id] = avg }
                }
            }
            cache.cfbAvgPoints.merge(avgs) { existing, _ in existing }
        }
        players = players.map { player in
            var player = player
            player.avgPointsPerMatch = cache.cfbAvgPoints[player.id]
            return player
        }
    }

    private func fetchCFBSeasonAverage(espnID: String, season: Int) async -> Double? {
        guard let url = URL(string: "https://sports.core.api.espn.com/v2/sports/football/leagues/college-football/seasons/\(season)/types/2/athletes/\(espnID)/statistics/0") else { return nil }
        guard let (data, response) = try? await Self.coreStatsSession.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let splits = json["splits"] as? [String: Any],
              let categories = splits["categories"] as? [[String: Any]] else { return nil }

        // Category-aware: "defensiveInterceptions" also carries a stat
        // named "interceptions", which would clobber the passing one in
        // a flat merge.
        var stats: [String: Double] = [:]
        for category in categories {
            let catName = category["name"] as? String ?? ""
            guard ["general", "passing", "rushing", "receiving"].contains(catName) else { continue }
            for stat in (category["stats"] as? [[String: Any]]) ?? [] {
                if let name = stat["name"] as? String,
                   let value = stat["value"] as? Double {
                    stats[name] = value
                }
            }
        }

        let games = stats["gamesPlayed"] ?? 0
        guard games >= 1 else { return nil }

        let seasonTotal = BestBallScoringEngine.nflFantasyPoints(
            passYds: Int(stats["passingYards"] ?? 0),
            passTD: Int(stats["passingTouchdowns"] ?? 0),
            interceptions: Int(stats["interceptions"] ?? 0),
            rushYds: Int(stats["rushingYards"] ?? 0),
            rushTD: Int(stats["rushingTouchdowns"] ?? 0),
            recYds: Int(stats["receivingYards"] ?? 0),
            receptions: Int(stats["receptions"] ?? 0),
            recTD: Int(stats["receivingTouchdowns"] ?? 0),
            fumblesLost: Int(stats["fumblesLost"] ?? 0)
        )
        guard seasonTotal > 0 else { return nil }
        return seasonTotal / games
    }

    private func fetchEPLSeasonAverage(espnID: String, season: Int) async -> Double? {
        guard let url = URL(string: "https://sports.core.api.espn.com/v2/sports/soccer/leagues/eng.1/seasons/\(season)/types/1/athletes/\(espnID)/statistics/0") else { return nil }
        guard let (data, response) = try? await Self.coreStatsSession.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let splits = json["splits"] as? [String: Any],
              let categories = splits["categories"] as? [[String: Any]] else { return nil }

        var stats: [String: Double] = [:]
        for category in categories {
            for stat in (category["stats"] as? [[String: Any]]) ?? [] {
                if let name = stat["name"] as? String,
                   let value = stat["value"] as? Double {
                    stats[name] = value
                }
            }
        }

        let appearances = stats["appearances"] ?? 0
        guard appearances >= 1 else { return nil }

        // DK-style additive stats (no clean-sheet / win / goals-against
        // context — those need per-match results).
        let goals = stats["totalGoals"] ?? 0
        let assists = stats["goalAssists"] ?? 0
        let sot = stats["shotsOnTarget"] ?? 0
        let shots = stats["totalShots"] ?? 0
        let saves = stats["saves"] ?? 0
        let foulsDrawn = stats["foulsSuffered"] ?? 0
        let foulsConceded = stats["foulsCommitted"] ?? 0
        let yc = stats["yellowCards"] ?? 0
        let rc = stats["redCards"] ?? 0
        let crosses = stats["accurateCrosses"] ?? 0
        let shotAssists = stats["shotAssists"] ?? 0
        let accuratePasses = stats["accuratePasses"] ?? 0
        let tacklesWon = stats["effectiveTackles"] ?? 0
        let interceptions = stats["interceptions"] ?? 0

        let seasonTotal = goals * 10.0 + assists * 6.0
            + shots * 1.0 + sot * 1.0
            + crosses * 0.7 + shotAssists * 1.0 + accuratePasses * 0.02
            + foulsDrawn * 1.0 - foulsConceded * 0.5
            + tacklesWon * 1.0 + interceptions * 0.5
            - yc * 1.5 - rc * 3.0 + saves * 2.0
        return seasonTotal / appearances
    }
}

// MARK: - ESPN Weekly Scoring Provider (with stat lines)

struct ESPNBestBallWeeklyScoringProvider: BestBallWeeklyScoringProvider {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // Legacy simple version
    func fetchWeeklyPoints(sport: String, playerIDs: [String], weekStartDate: Date, weekEndDate: Date) async throws -> [String: Double] {
        let result = try await fetchWeeklyPointsWithStats(sport: sport, playerIDs: playerIDs, weekStartDate: weekStartDate, weekEndDate: weekEndDate)
        return result.playerPoints
    }

    // Full version with stat lines and daily breakdown
    func fetchWeeklyPointsWithStats(sport: String, playerIDs: [String], weekStartDate: Date, weekEndDate: Date) async throws -> BestBallWeeklyStatsResult {
        guard !playerIDs.isEmpty else {
            return BestBallWeeklyStatsResult(playerPoints: [:], playerStats: [:], dailyBreakdown: [:], dailyStats: [:])
        }

        let (sportPath, leaguePath) = espnPaths(for: sport)
        guard !sportPath.isEmpty else {
            return BestBallWeeklyStatsResult(playerPoints: [:], playerStats: [:], dailyBreakdown: [:], dailyStats: [:])
        }

        let calendar = Calendar(identifier: .gregorian)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.calendar = calendar

        // Collect game IDs per date
        var gamesByDate: [String: [String]] = [:]  // dateKey -> [gameID]
        var date = weekStartDate
        while date <= weekEndDate {
            let dateKey = formatter.string(from: date)
            guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(sportPath)/\(leaguePath)/scoreboard?dates=\(dateKey)") else {
                date = calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86400)
                continue
            }
            guard let (data, response) = try? await session.data(from: url),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                date = calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86400)
                continue
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let events = json["events"] as? [[String: Any]] {
                for event in events {
                    if let comp = (event["competitions"] as? [[String: Any]])?.first,
                       let status = (comp["status"] as? [String: Any])?["type"] as? [String: Any],
                       let state = status["state"] as? String,
                       (state == "post" || state == "in"),
                       let eventID = event["id"] as? String {
                        gamesByDate[dateKey, default: []].append(eventID)
                    }
                }
            }
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86400)
        }

        let playerIDSet = Set(playerIDs)
        let prefix = sport.lowercased() + "-"
        var totalPoints: [String: Double] = [:]
        var totalStats: [String: [String: Double]] = [:]
        var dailyBreakdown: [String: [String: Double]] = [:]  // dateKey -> {fullID: pts}
        var dailyStats: [String: [String: [String: Double]]] = [:]  // dateKey -> {fullID: {stat: val}}

        for (dateKey, gameIDs) in gamesByDate {
            for gameID in gameIDs {
                guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(sportPath)/\(leaguePath)/summary?event=\(gameID)") else { continue }
                guard let (data, response) = try? await session.data(from: url),
                      let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { continue }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                // Soccer summaries have no boxscore.players — stats live
                // under rosters[] in a different shape entirely.
                if sport == "EPL" {
                    for entry in await Self.parseSoccerSummaryEntries(
                        json: json, prefix: prefix,
                        eventID: gameID, leaguePath: leaguePath,
                        restrictTo: playerIDSet, session: session
                    ) {
                        guard playerIDSet.contains(entry.fullID) else { continue }
                        totalPoints[entry.fullID, default: 0] += entry.fpts
                        for (key, val) in entry.lookup {
                            totalStats[entry.fullID, default: [:]][key, default: 0] += val
                        }
                        dailyBreakdown[dateKey, default: [:]][entry.fullID, default: 0] += entry.fpts
                        for (key, val) in entry.lookup {
                            dailyStats[dateKey, default: [:]][entry.fullID, default: [:]][key, default: 0] += val
                        }
                    }
                    continue
                }

                guard let boxscore = json["boxscore"] as? [String: Any],
                      let playerGroups = boxscore["players"] as? [[String: Any]] else { continue }

                for group in playerGroups {
                    guard let statistics = group["statistics"] as? [[String: Any]] else { continue }
                    for stat in statistics {
                        guard let labels = stat["labels"] as? [String],
                              let athletes = stat["athletes"] as? [[String: Any]] else { continue }
                        for athlete in athletes {
                            guard let athleteInfo = athlete["athlete"] as? [String: Any],
                                  let athleteID = athleteInfo["id"] as? String ?? (athleteInfo["id"] as? Int).map({ String($0) }) else { continue }
                            let fullID = prefix + athleteID
                            guard playerIDSet.contains(fullID) else { continue }
                            guard let stats = athlete["stats"] as? [String] else { continue }

                            // Build stat lookup
                            var lookup: [String: Double] = [:]
                            for (i, label) in labels.enumerated() where i < stats.count {
                                lookup[label] = Double(stats[i]) ?? 0
                            }

                            let fpts = Self.computeFantasyPoints(sport: sport, labels: labels, stats: stats)
                            totalPoints[fullID, default: 0] += fpts

                            // Merge stat lines (accumulate across games)
                            for (key, val) in lookup {
                                totalStats[fullID, default: [:]][key, default: 0] += val
                            }

                            // Daily breakdown
                            dailyBreakdown[dateKey, default: [:]][fullID, default: 0] += fpts
                            for (key, val) in lookup {
                                dailyStats[dateKey, default: [:]][fullID, default: [:]][key, default: 0] += val
                            }
                        }
                    }
                }
            }
        }

        return BestBallWeeklyStatsResult(
            playerPoints: totalPoints,
            playerStats: totalStats,
            dailyBreakdown: dailyBreakdown,
            dailyStats: dailyStats
        )
    }

    /// Bulk fetch: fetches all ESPN box scores for a week with concurrent requests,
    /// returning stats for every player found. Call once per week, then filter per member locally.
    func fetchWeeklyAllPlayerStats(sport: String, weekStartDate: Date, weekEndDate: Date, restrictToPlayerIDs: Set<String>? = nil) async throws -> BestBallWeeklyStatsResult {
        let (sportPath, leaguePath) = espnPaths(for: sport)
        guard !sportPath.isEmpty else {
            return BestBallWeeklyStatsResult(playerPoints: [:], playerStats: [:], dailyBreakdown: [:], dailyStats: [:])
        }

        let calendar = Calendar(identifier: .gregorian)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.calendar = calendar

        let prefix = sport.lowercased() + "-"

        // Build list of dates in the week
        var dates: [Date] = []
        var date = weekStartDate
        while date <= weekEndDate {
            dates.append(date)
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86400)
        }

        // Phase 1: Fetch all scoreboards concurrently to collect game IDs
        var gamesByDate: [String: [String]] = [:]  // dateKey -> [gameID]
        await withTaskGroup(of: (String, [String]).self) { group in
            for d in dates {
                let dateKey = formatter.string(from: d)
                group.addTask {
                    guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(sportPath)/\(leaguePath)/scoreboard?dates=\(dateKey)") else {
                        return (dateKey, [])
                    }
                    guard let (data, response) = try? await self.session.data(from: url),
                          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        return (dateKey, [])
                    }
                    var ids: [String] = []
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let events = json["events"] as? [[String: Any]] {
                        for event in events {
                            if let comp = (event["competitions"] as? [[String: Any]])?.first,
                               let status = (comp["status"] as? [String: Any])?["type"] as? [String: Any],
                               let state = status["state"] as? String,
                               (state == "post" || state == "in"),
                               let eventID = event["id"] as? String {
                                ids.append(eventID)
                            }
                        }
                    }
                    return (dateKey, ids)
                }
            }
            for await (dateKey, ids) in group {
                if !ids.isEmpty {
                    gamesByDate[dateKey] = ids
                }
            }
        }

        // Phase 2: Fetch all box scores concurrently
        struct BoxScoreResult: Sendable {
            let dateKey: String
            let playerEntries: [(fullID: String, fpts: Double, lookup: [String: Double])]
        }

        // Flatten all (dateKey, gameID) pairs for concurrent fetch
        var allGameFetches: [(dateKey: String, gameID: String)] = []
        for (dateKey, gameIDs) in gamesByDate {
            for gameID in gameIDs {
                allGameFetches.append((dateKey, gameID))
            }
        }

        var totalPoints: [String: Double] = [:]
        var totalStats: [String: [String: Double]] = [:]
        var dailyBreakdown: [String: [String: Double]] = [:]
        var dailyStats: [String: [String: [String: Double]]] = [:]

        await withTaskGroup(of: BoxScoreResult.self) { group in
            for fetch in allGameFetches {
                group.addTask {
                    guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(sportPath)/\(leaguePath)/summary?event=\(fetch.gameID)") else {
                        return BoxScoreResult(dateKey: fetch.dateKey, playerEntries: [])
                    }
                    guard let (data, response) = try? await self.session.data(from: url),
                          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        return BoxScoreResult(dateKey: fetch.dateKey, playerEntries: [])
                    }
                    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        return BoxScoreResult(dateKey: fetch.dateKey, playerEntries: [])
                    }

                    if sport == "EPL" {
                        return BoxScoreResult(
                            dateKey: fetch.dateKey,
                            playerEntries: await Self.parseSoccerSummaryEntries(
                                json: json, prefix: prefix,
                                eventID: fetch.gameID, leaguePath: leaguePath,
                                restrictTo: restrictToPlayerIDs, session: self.session
                            )
                        )
                    }

                    guard let boxscore = json["boxscore"] as? [String: Any],
                          let playerGroups = boxscore["players"] as? [[String: Any]] else {
                        return BoxScoreResult(dateKey: fetch.dateKey, playerEntries: [])
                    }

                    var entries: [(fullID: String, fpts: Double, lookup: [String: Double])] = []
                    for playerGroup in playerGroups {
                        guard let statistics = playerGroup["statistics"] as? [[String: Any]] else { continue }
                        for stat in statistics {
                            guard let labels = stat["labels"] as? [String],
                                  let athletes = stat["athletes"] as? [[String: Any]] else { continue }
                            for athlete in athletes {
                                guard let athleteInfo = athlete["athlete"] as? [String: Any],
                                      let athleteID = athleteInfo["id"] as? String ?? (athleteInfo["id"] as? Int).map({ String($0) }) else { continue }
                                let fullID = prefix + athleteID
                                guard let stats = athlete["stats"] as? [String] else { continue }
                                var lookup: [String: Double] = [:]
                                for (i, label) in labels.enumerated() where i < stats.count {
                                    lookup[label] = Double(stats[i]) ?? 0
                                }
                                let fpts = Self.computeFantasyPoints(sport: sport, labels: labels, stats: stats)
                                entries.append((fullID, fpts, lookup))
                            }
                        }
                    }
                    return BoxScoreResult(dateKey: fetch.dateKey, playerEntries: entries)
                }
            }

            for await result in group {
                for entry in result.playerEntries {
                    totalPoints[entry.fullID, default: 0] += entry.fpts
                    for (key, val) in entry.lookup {
                        totalStats[entry.fullID, default: [:]][key, default: 0] += val
                    }
                    dailyBreakdown[result.dateKey, default: [:]][entry.fullID, default: 0] += entry.fpts
                    for (key, val) in entry.lookup {
                        dailyStats[result.dateKey, default: [:]][entry.fullID, default: [:]][key, default: 0] += val
                    }
                }
            }
        }

        return BestBallWeeklyStatsResult(
            playerPoints: totalPoints,
            playerStats: totalStats,
            dailyBreakdown: dailyBreakdown,
            dailyStats: dailyStats
        )
    }

    /// Fetches season HR counts by hitting each player's ESPN athlete stats endpoint.
    /// This is ~1 lightweight call per unique player instead of fetching every box score of the season.
    func fetchSeasonHRCounts(playerIDs: [String]) async -> [String: Int] {
        let prefix = "mlb-"
        var result: [String: Int] = [:]

        // Deduplicate and extract ESPN IDs
        let uniqueIDs = Array(Set(playerIDs))

        let currentYear = Calendar.current.component(.year, from: Date())

        // Use TaskGroup for concurrent fetches
        await withTaskGroup(of: (String, Int)?.self) { group in
            for fullID in uniqueIDs {
                guard fullID.hasPrefix(prefix) else { continue }
                let espnID = String(fullID.dropFirst(prefix.count))

                group.addTask {
                    // ESPN athlete stats endpoint — returns career/season statistics
                    guard let url = URL(string: "https://site.web.api.espn.com/apis/common/v3/sports/baseball/mlb/athletes/\(espnID)/stats") else {
                        return nil
                    }
                    guard let (data, response) = try? await self.session.data(from: url),
                          let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode) else {
                        return nil
                    }
                    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let categories = json["categories"] as? [[String: Any]],
                          let battingCategory = categories.first else {
                        return nil
                    }

                    // Find HR index from labels array
                    guard let labels = battingCategory["labels"] as? [String],
                          let hrIndex = labels.firstIndex(of: "HR"),
                          let statistics = battingCategory["statistics"] as? [[String: Any]] else {
                        return nil
                    }

                    // Find the current season entry (most recent year)
                    // Each statistics entry has a "season" with "year" and a "stats" array
                    var totalHR = 0
                    for seasonEntry in statistics {
                        let season = seasonEntry["season"] as? [String: Any]
                        let year = season?["year"] as? Int ?? 0
                        guard year == currentYear else { continue }
                        if let stats = seasonEntry["stats"] as? [String],
                           hrIndex < stats.count,
                           let hr = Int(stats[hrIndex]) {
                            totalHR += hr
                        }
                    }

                    return totalHR > 0 ? (fullID, totalHR) : nil
                }
            }

            for await item in group {
                if let (id, hr) = item {
                    result[id] = hr
                }
            }
        }

        return result
    }

    private func espnPaths(for sport: String) -> (String, String) {
        switch sport {
        case "NBA": return ("basketball", "nba")
        case "MLB": return ("baseball", "mlb")
        case "NFL": return ("football", "nfl")
        case "CFB": return ("football", "college-football")
        case "EPL": return ("soccer", "eng.1")
        default: return ("", "")
        }
    }

    /// Parse an ESPN soccer summary into per-player scoring entries.
    /// Stats are `rosters[].roster[].stats` as {name, value} dicts (NOT
    /// the labels/stats string arrays every other sport uses), and the
    /// clean-sheet / win context comes from the header competitors.
    /// DK "detail" stats not present in the match summary — fetched from the
    /// core per-athlete statistics endpoint, one request per (kept) player.
    private nonisolated static func fetchSoccerDetailStatValues(
        eventID: String, leaguePath: String, teamID: String, athleteID: String,
        session: URLSession
    ) async -> [String: Double] {
        let urlString = "https://sports.core.api.espn.com/v2/sports/soccer/leagues/\(leaguePath)/events/\(eventID)/competitions/\(eventID)/competitors/\(teamID)/roster/\(athleteID)/statistics/0"
        guard let url = URL(string: urlString) else { return [:] }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let splits = json["splits"] as? [String: Any],
              let categories = splits["categories"] as? [[String: Any]] else {
            return [:]
        }
        var values: [String: Double] = [:]
        for cat in categories {
            for s in (cat["stats"] as? [[String: Any]]) ?? [] {
                guard let name = s["name"] as? String else { continue }
                values[name] = s["value"] as? Double ?? (s["value"] as? Int).map(Double.init) ?? 0
            }
        }
        return values
    }

    private nonisolated static func parseSoccerSummaryEntries(
        json: [String: Any], prefix: String,
        eventID: String, leaguePath: String,
        restrictTo: Set<String>?, session: URLSession
    ) async -> [(fullID: String, fpts: Double, lookup: [String: Double])] {
        guard let rostersArr = json["rosters"] as? [[String: Any]] else { return [] }

        var gameFinal = false
        var scoreByHomeAway: [String: Int] = [:]
        if let header = json["header"] as? [String: Any],
           let comp = (header["competitions"] as? [[String: Any]])?.first {
            if let status = comp["status"] as? [String: Any],
               let type = status["type"] as? [String: Any],
               let state = type["state"] as? String {
                gameFinal = state == "post"
            }
            for competitor in (comp["competitors"] as? [[String: Any]]) ?? [] {
                guard let homeAway = competitor["homeAway"] as? String else { continue }
                let score = (competitor["score"] as? String).flatMap { Int($0) }
                    ?? competitor["score"] as? Int ?? 0
                scoreByHomeAway[homeAway] = score
            }
        }

        struct RawSoccerEntry: Sendable {
            let athleteID: String
            let fullID: String
            let teamID: String
            let position: String
            let statMap: [String: Double]
            let cleanSheet: Bool
            let teamWon: Bool
        }
        var raws: [RawSoccerEntry] = []
        for rosterBlock in rostersArr {
            let homeAway = rosterBlock["homeAway"] as? String ?? ""
            let teamScore = scoreByHomeAway[homeAway] ?? 0
            let oppScore = scoreByHomeAway[homeAway == "home" ? "away" : "home"] ?? 0
            let cleanSheet = gameFinal && oppScore == 0
            let teamWon = gameFinal && teamScore > oppScore
            let teamDict = rosterBlock["team"] as? [String: Any]
            let teamID = teamDict?["id"] as? String ?? (teamDict?["id"] as? Int).map({ String($0) }) ?? ""

            guard let rosterEntries = rosterBlock["roster"] as? [[String: Any]] else { continue }
            for entry in rosterEntries {
                let isActive = entry["active"] as? Bool ?? false
                let isStarter = entry["starter"] as? Bool ?? false
                let subbedIn = entry["subbedIn"] as? Bool ?? false
                // Skip players who never got on the pitch.
                guard isActive || isStarter || subbedIn else { continue }
                guard let athleteDict = entry["athlete"] as? [String: Any],
                      let athleteID = athleteDict["id"] as? String ?? (athleteDict["id"] as? Int).map({ String($0) }) else { continue }
                let fullID = prefix + athleteID
                if let restrictTo, !restrictTo.contains(fullID) { continue }

                let posDict = entry["position"] as? [String: Any]
                let position = bbSoccerPosition(
                    posDict?["abbreviation"] as? String ?? posDict?["displayName"] as? String ?? "M"
                )

                var statMap: [String: Double] = [:]
                for stat in (entry["stats"] as? [[String: Any]]) ?? [] {
                    if let name = stat["name"] as? String {
                        statMap[name] = stat["value"] as? Double
                            ?? (stat["displayValue"] as? String).flatMap { Double($0) }
                            ?? 0
                    }
                }
                raws.append(RawSoccerEntry(
                    athleteID: athleteID, fullID: fullID, teamID: teamID,
                    position: position, statMap: statMap,
                    cleanSheet: cleanSheet, teamWon: teamWon
                ))
            }
        }

        // DK detail stats (crosses, shot assists, accurate passes, tackles,
        // interceptions) live on the core per-athlete endpoint — fan out one
        // request per kept player. A failed fetch scores that player from
        // summary stats alone.
        var detailByID: [String: [String: Double]] = [:]
        await withTaskGroup(of: (String, [String: Double]).self) { group in
            for raw in raws where !raw.teamID.isEmpty {
                group.addTask {
                    let values = await Self.fetchSoccerDetailStatValues(
                        eventID: eventID, leaguePath: leaguePath,
                        teamID: raw.teamID, athleteID: raw.athleteID,
                        session: session
                    )
                    return (raw.fullID, values)
                }
            }
            for await (fullID, values) in group {
                detailByID[fullID] = values
            }
        }

        var entries: [(fullID: String, fpts: Double, lookup: [String: Double])] = []
        for raw in raws {
            let statMap = raw.statMap
            let detail = detailByID[raw.fullID] ?? [:]
            let goals = Int(statMap["totalGoals"] ?? 0)
            let assists = Int(statMap["goalAssists"] ?? 0)
            let sot = Int(statMap["shotsOnTarget"] ?? 0)
            let shots = Int(statMap["totalShots"] ?? 0)
            let saves = Int(statMap["saves"] ?? 0)
            let yc = Int(statMap["yellowCards"] ?? 0)
            let rc = Int(statMap["redCards"] ?? 0)
            let foulsDrawn = Int(statMap["foulsSuffered"] ?? 0)
            let foulsConceded = Int(statMap["foulsCommitted"] ?? 0)
            let goalsAgainst = Int(statMap["goalsConceded"] ?? 0)
            let crosses = Int(detail["accurateCrosses"] ?? 0)
            let shotAssists = Int(detail["shotAssists"] ?? 0)
            let accuratePasses = Int(detail["accuratePasses"] ?? 0)
            let tacklesWon = Int(detail["effectiveTackles"] ?? 0)
            let interceptions = Int(detail["interceptions"] ?? 0)

            let fpts = BestBallScoringEngine.soccerFantasyPoints(
                position: raw.position,
                goals: goals, assists: assists, shotsOnTarget: sot, totalShots: shots,
                saves: saves, yellowCards: yc, redCards: rc,
                foulsDrawn: foulsDrawn, foulsConceded: foulsConceded, goalsAgainst: goalsAgainst,
                crosses: crosses, shotAssists: shotAssists, accuratePasses: accuratePasses,
                tacklesWon: tacklesWon, interceptions: interceptions,
                cleanSheet: raw.cleanSheet, gameFinal: gameFinal, teamWon: raw.teamWon
            )

            let lookup: [String: Double] = [
                "G": Double(goals), "A": Double(assists),
                "SOT": Double(sot), "SH": Double(shots),
                "SV": Double(saves), "YC": Double(yc), "RC": Double(rc),
                "TKL": Double(tacklesWon), "INT": Double(interceptions),
            ]
            entries.append((raw.fullID, fpts, lookup))
        }
        return entries
    }

    private nonisolated static func computeFantasyPoints(sport: String, labels: [String], stats: [String]) -> Double {
        var lookup: [String: Double] = [:]
        for (i, label) in labels.enumerated() where i < stats.count {
            lookup[label] = Double(stats[i]) ?? 0
        }

        switch sport {
        case "NBA":
            return BestBallScoringEngine.nbaFantasyPoints(
                pts: Int(lookup["PTS"] ?? 0), reb: Int(lookup["REB"] ?? 0),
                ast: Int(lookup["AST"] ?? 0), stl: Int(lookup["STL"] ?? 0),
                blk: Int(lookup["BLK"] ?? 0), tov: Int(lookup["TO"] ?? 0)
            )
        case "MLB":
            let h = Int(lookup["H"] ?? 0)
            let doubles = Int(lookup["2B"] ?? 0)
            let triples = Int(lookup["3B"] ?? 0)
            let hr = Int(lookup["HR"] ?? 0)
            let singles = h - doubles - triples - hr
            if lookup["IP"] != nil {
                return BestBallScoringEngine.mlbPitcherPoints(
                    ip: lookup["IP"] ?? 0, k: Int(lookup["K"] ?? lookup["SO"] ?? 0),
                    w: Int(lookup["W"] ?? 0), er: Int(lookup["ER"] ?? 0), sv: Int(lookup["SV"] ?? 0)
                )
            } else {
                return BestBallScoringEngine.mlbHitterPoints(
                    singles: max(0, singles), doubles: doubles, triples: triples, hr: hr,
                    rbi: Int(lookup["RBI"] ?? 0), runs: Int(lookup["R"] ?? 0),
                    bb: Int(lookup["BB"] ?? 0), sb: Int(lookup["SB"] ?? 0),
                    k: Int(lookup["K"] ?? lookup["SO"] ?? 0)
                )
            }
        case "NFL", "CFB":
            return BestBallScoringEngine.nflFantasyPoints(
                passYds: Int(lookup["YDS"] ?? 0), passTD: Int(lookup["TD"] ?? 0),
                interceptions: Int(lookup["INT"] ?? 0),
                rushYds: Int(lookup["RYDS"] ?? lookup["YDS"] ?? 0), rushTD: Int(lookup["RTD"] ?? 0),
                recYds: Int(lookup["RECYDS"] ?? 0), receptions: Int(lookup["REC"] ?? 0),
                recTD: Int(lookup["RECTD"] ?? 0), fumblesLost: Int(lookup["FUM"] ?? 0)
            )
        default:
            return 0
        }
    }
}

// MARK: - Season Helpers

enum BestBallSeasonHelper {
    static func totalWeeks(for sport: String) -> Int {
        switch sport {
        case "NBA": return 24
        case "MLB": return 26
        case "NFL": return 18
        case "CFB": return 15   // Week 1 (Labor Day weekend) → conference championships
        case "EPL": return 41   // Aug 17 2026 → final day Sun May 30 2027, Mon–Sun weeks (international breaks score 0)
        default: return 20
        }
    }

    /// Season label for a Best Ball league created today. Pivots forward
    /// in the off-season window so a league created in (e.g.) June 2026
    /// is labeled "2026-27" — the upcoming season — not the just-ended
    /// 2025-26. Sport-aware because the off-season month windows differ.
    static func currentSeason(sport: String = "MLB") -> String {
        let year = Calendar.current.component(.year, from: Date())
        let month = Calendar.current.component(.month, from: Date())
        switch sport {
        case "NFL", "CFB":
            // Sep–Dec: current `year` season. Jan–Feb: prior season
            // playoffs (still labeled with last fall's start year).
            // Mar–Aug: pivot to upcoming `year` kickoff.
            if month >= 7 || (month >= 3 && month <= 6) {
                return "\(year)-\(String(year + 1).suffix(2))"
            } else if month <= 2 {
                return "\(year - 1)-\(String(year).suffix(2))"
            }
            return "\(year)-\(String(year + 1).suffix(2))"
        case "NBA":
            // Oct–Jun: same logic as before. Jul–Sep is off-season →
            // upcoming season starts in Oct of current year.
            if month >= 7 {
                return "\(year)-\(String(year + 1).suffix(2))"
            }
            return "\(year - 1)-\(String(year).suffix(2))"
        default:
            // MLB and other sports whose season is underway or upcoming
            // by July (EPL's Aug→May season labels correctly here too:
            // Jul–Dec → "year-(year+1)", Jan–Jun → "(year-1)-year").
            if month >= 7 {
                return "\(year)-\(String(year + 1).suffix(2))"
            }
            return "\(year - 1)-\(String(year).suffix(2))"
        }
    }

    static func weekDateRange(sport: String, week: Int) -> (start: Date, end: Date) {
        let calendar = Calendar(identifier: .gregorian)

        let seasonStart = seasonStartDate(for: sport)

        if sport == "MLB" {
            // MLB: Week 1 is a short opening week ending on Sunday.
            // Week 2+ are standard Mon–Sun.
            let firstSunday = sundayOnOrAfter(seasonStart, calendar: calendar)
            if week == 1 {
                return (seasonStart, firstSunday)
            }
            // Week 2 starts the Monday after the first Sunday
            let week2Start = calendar.date(byAdding: .day, value: 1, to: firstSunday) ?? firstSunday
            let weekStart = calendar.date(byAdding: .day, value: (week - 2) * 7, to: week2Start) ?? week2Start
            let weekEnd = calendar.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart  // Mon→Sun
            return (weekStart, weekEnd)
        }

        let weekStart = calendar.date(byAdding: .day, value: (week - 1) * 7, to: seasonStart) ?? seasonStart
        let weekEnd: Date
        if sport == "NFL" {
            weekEnd = calendar.date(byAdding: .day, value: 4, to: weekStart) ?? weekStart  // Thu→Mon
        } else {
            weekEnd = calendar.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart  // Mon→Sun
        }
        return (weekStart, weekEnd)
    }

    /// Determines the correct season start date based on current date and sport schedule.
    /// NBA/NFL: season starts in fall of previous year if we're currently before July.
    /// MLB: season starts in spring of current year.
    static func seasonStartDate(for sport: String) -> Date {
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: Date())
        let month = calendar.component(.month, from: Date())

        switch sport {
        case "NBA":
            // NBA runs Oct→Apr. If before July, the season started last October.
            let startYear = month < 7 ? year - 1 : year
            return mondayOnOrAfter(calendar.date(from: DateComponents(year: startYear, month: 10, day: 22)) ?? Date(), calendar: calendar)
        case "MLB":
            // MLB runs late Mar→Sep. 2026 Opening Day is Wed March 25.
            // Use the actual date without rounding so all opening week games are included.
            let startYear = month < 3 ? year - 1 : year
            let raw = calendar.date(from: DateComponents(year: startYear, month: 3, day: 25)) ?? Date()
            return calendar.startOfDay(for: raw)
        case "NFL":
            // NFL runs Sep→Feb. From March through August the season has
            // wrapped (Super Bowl is early February) and the "current"
            // season should pivot forward to the upcoming September
            // kickoff. Otherwise off-season leagues would score against
            // last year's box scores — exactly the bug a user saw when
            // a June-created NFL Best Ball graded itself against the
            // prior season's Week 18.
            let startYear: Int
            if month >= 7 {
                startYear = year                  // Jul–Dec: this year's season
            } else if month <= 2 {
                startYear = year - 1              // Jan–Feb: last year's playoffs
            } else {
                startYear = year                  // Mar–Jun: upcoming season starts Sep `year`
            }
            return thursdayOnOrAfter(calendar.date(from: DateComponents(year: startYear, month: 9, day: 4)) ?? Date(), calendar: calendar)
        case "CFB":
            // CFB runs late Aug→early Dec. Weeks are the default Mon–Sun
            // window (games land Tue–Sat), anchored to the Monday before
            // the Labor-Day-weekend Saturday slate — Week 0's handful of
            // games is deliberately left out. Same forward pivot as NFL
            // for off-season league creation.
            let startYear: Int
            if month >= 7 {
                startYear = year
            } else if month <= 1 {
                startYear = year - 1
            } else {
                startYear = year
            }
            return mondayOnOrAfter(calendar.date(from: DateComponents(year: startYear, month: 8, day: 28)) ?? Date(), calendar: calendar)
        case "EPL":
            // EPL runs Aug→May; the season label pivots in July. 2026-27
            // opens Friday Aug 21 (a week later than usual after the World
            // Cup), so week 1 anchors to the Monday of opening week —
            // mondayOnOrAfter(Aug 12) = Aug 17. Revisit the anchor if a
            // future season opens on the second weekend of August.
            let startYear = month >= 7 ? year : year - 1
            return mondayOnOrAfter(calendar.date(from: DateComponents(year: startYear, month: 8, day: 12)) ?? Date(), calendar: calendar)
        default:
            return Date()
        }
    }

    /// The moment new joins/creates close for a sport. Usually the week-1
    /// anchor date, but EPL's anchor is the MONDAY of opening week while
    /// the first match is that FRIDAY evening — joining Tue–Thu of opening
    /// week is fine (nothing has scored yet). Closing at the Monday anchor
    /// hid EPL from Browse four days before a ball was kicked.
    static func joinDeadline(for sport: String) -> Date {
        let start = seasonStartDate(for: sport)
        if sport == "EPL" {
            let calendar = Calendar(identifier: .gregorian)
            // Friday of opening week, ~kickoff time (early evening UK).
            return calendar.date(byAdding: DateComponents(day: 4, hour: 14), to: start) ?? start
        }
        return start
    }

    /// Returns the current week number for a sport based on today's date
    static func currentWeekNumber(for sport: String) -> Int {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())

        if sport == "MLB" {
            // Week 1 ends on the first Sunday after season start.
            // Week 2+ are standard Mon-Sun.
            let seasonStart = seasonStartDate(for: sport)
            let firstSunday = sundayOnOrAfter(seasonStart, calendar: calendar)
            if today <= firstSunday {
                return 1
            }
            let week2Start = calendar.date(byAdding: .day, value: 1, to: firstSunday) ?? firstSunday
            let days = calendar.dateComponents([.day], from: week2Start, to: today).day ?? 0
            return 2 + (days / 7)
        }

        let (start, _) = weekDateRange(sport: sport, week: 1)
        let days = calendar.dateComponents([.day], from: start, to: today).day ?? 0
        // If we're before the season's Week 1 (off-season period after
        // the prior season ended), days will be negative; floor at week
        // 1 so the UI shows "Week 1 of N" until kickoff instead of a
        // negative or huge-week number.
        if days < 0 { return 1 }
        return max(1, (days / 7) + 1)
    }

    private static func mondayOnOrAfter(_ date: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: date)
        // weekday: 1=Sun, 2=Mon, ...
        let daysToAdd = weekday == 2 ? 0 : ((9 - weekday) % 7)
        return calendar.date(byAdding: .day, value: daysToAdd, to: date) ?? date
    }

    private static func thursdayOnOrAfter(_ date: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: date)
        // weekday: 5=Thu
        let daysToAdd = weekday == 5 ? 0 : ((12 - weekday) % 7)
        return calendar.date(byAdding: .day, value: daysToAdd, to: date) ?? date
    }

    private static func sundayOnOrAfter(_ date: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: date)
        // weekday: 1=Sun
        let daysToAdd = weekday == 1 ? 0 : (8 - weekday)
        return calendar.date(byAdding: .day, value: daysToAdd, to: date) ?? date
    }
}

// MARK: - Private Types

private struct BBTeamRef {
    let id: String
    let abbreviation: String
}
