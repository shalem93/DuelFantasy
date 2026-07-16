import Foundation

// MARK: - Core Models

struct SoccerTiersTournament: Equatable {
    let id: String                          // "world-cup-2026"
    let title: String
    let season: String
    let status: String                      // open, locked, live, settled
    let lockTime: Date?                     // first World Cup match (June 11, 2026)
    let entryCount: Int
    let isSettled: Bool
    let createdAt: Date
}

struct SoccerTiersPlayer: Identifiable, Hashable {
    let id: String                          // "wc-{name-slug}-{countryCode}"
    let name: String
    let country: String                     // "France"
    let countryCode: String                 // "FRA"
    let position: String                    // GK, DEF, MID, FWD
    let tier: Int                           // 1-6 (0 before assignment)
    let projectedPoints: Double             // composite score for tier assignment
    var matchesPlayed: Int
    var totalFantasyPoints: Double
    var perMatchAvg: Double
    let imageURL: String?
    var isEliminated: Bool                  // true when nation knocked out

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: SoccerTiersPlayer, rhs: SoccerTiersPlayer) -> Bool { lhs.id == rhs.id }
}

struct SoccerTiersPick: Codable, Hashable {
    let tier: Int
    let playerID: String
    let playerName: String
    let playerCountry: String               // country code (FRA, BRA, etc.)
}

struct SoccerTiersEntry: Identifiable, Equatable {
    let id: UUID
    let tournamentID: String
    let userID: String?
    let entryName: String
    let picks: [SoccerTiersPick]            // 6 picks (one per tier)
    var totalPoints: Double
    var rank: Int
    let isBot: Bool
    let isCurrentUser: Bool

    static func == (lhs: SoccerTiersEntry, rhs: SoccerTiersEntry) -> Bool {
        lhs.id == rhs.id && lhs.totalPoints == rhs.totalPoints && lhs.rank == rhs.rank
    }
}

struct SoccerTiersLeaderboardEntry: Identifiable {
    let id: UUID
    let entryName: String
    let picks: [SoccerTiersPick]
    let totalPoints: Double
    let rank: Int
    let isCurrentUser: Bool
    /// Breakdown: playerID → accumulated FPTS
    let playerPoints: [String: Double]
}

struct SoccerTiersScoreSnapshot {
    /// playerID → accumulated WC FPTS across all matches
    let playerFantasyPoints: [String: Double]
    /// playerID → total matches played
    let playerMatchesPlayed: [String: Int]
    /// Country codes of eliminated nations
    let eliminatedNations: Set<String>
    let isTournamentComplete: Bool
}

// MARK: - Private Groups

struct SoccerTiersGroup: Identifiable, Equatable {
    let id: UUID
    let tournamentID: String
    let name: String
    let createdBy: String
    let inviteCode: String
    let maxMembers: Int
    let createdAt: Date
}

struct SoccerTiersGroupMember: Identifiable, Equatable {
    let id: UUID
    let groupID: UUID
    let userID: String
    let displayName: String
    let joinedAt: Date
}

// MARK: - Tournament ID Helpers

extension SoccerTiersTournament {
    static func currentTournamentID() -> String { "world-cup-2026" }
    static func currentTitle() -> String { "FIFA World Cup 2026 Tiers" }
    static func currentSeason() -> String { "2026" }

    /// June 11, 2026, 12:00 PM ET — approximate first match time
    static func lockTime() -> Date {
        var components = DateComponents()
        components.year = 2026; components.month = 6; components.day = 11
        components.hour = 12; components.minute = 0
        components.timeZone = TimeZone(identifier: "America/New_York")
        return Calendar.current.date(from: components) ?? Date()
    }
}

// MARK: - Tier Generation Engine

struct SoccerTiersEngine {
    /// Tier sizes: T1 = 8 elite superstars, T6 = remainder (depth players)
    static let tierSizes = [8, 12, 18, 25, 35, 0]  // 0 = remainder goes to T6

    /// Distribute players into 6 tiers based on composite score (descending).
    static func generateTiers(from players: [SoccerTiersPlayer]) -> [[SoccerTiersPlayer]] {
        let sorted = players.sorted { $0.projectedPoints > $1.projectedPoints }
        var tiers: [[SoccerTiersPlayer]] = []
        var offset = 0

        for (tierIndex, size) in tierSizes.enumerated() {
            let actualSize = size == 0 ? max(0, sorted.count - offset) : size
            let end = min(offset + actualSize, sorted.count)
            guard offset < end else {
                tiers.append([])
                continue
            }
            let tierPlayers = sorted[offset..<end].map { player in
                SoccerTiersPlayer(
                    id: player.id, name: player.name,
                    country: player.country, countryCode: player.countryCode,
                    position: player.position, tier: tierIndex + 1,
                    projectedPoints: player.projectedPoints,
                    matchesPlayed: player.matchesPlayed,
                    totalFantasyPoints: player.totalFantasyPoints,
                    perMatchAvg: player.perMatchAvg,
                    imageURL: player.imageURL, isEliminated: player.isEliminated
                )
            }
            tiers.append(tierPlayers)
            offset = end
        }

        while tiers.count < 6 { tiers.append([]) }
        return tiers
    }

    /// Soccer fantasy scoring (FanDuel-style). Identical to the DFS soccer
    /// scoring in SoccerDFSData.swift — includes the defensive-stats fix
    /// (interceptions/blocks/clearances) so CBs like Marquinhos aren't
    /// stuck averaging ~1.7 FPTS per match.
    static func soccerFantasyPoints(
        position: String,
        goals: Int, assists: Int, shotsOnTarget: Int, totalShots: Int,
        tackles: Int, interceptions: Int, blockedShots: Int, clearances: Int,
        saves: Int, yellowCards: Int, redCards: Int,
        foulsDrawn: Int, goalsAgainst: Int,
        cleanSheet: Bool, gameFinal: Bool, teamWon: Bool
    ) -> Double {
        var pts = 0.0
        pts += Double(goals) * 15.0
        pts += Double(assists) * 7.0
        pts += Double(shotsOnTarget) * 4.0
        let nonTargetShots = max(0, totalShots - shotsOnTarget)
        pts += Double(nonTargetShots) * 1.0
        pts += Double(tackles) * 1.6
        pts += Double(foulsDrawn) * 1.0
        pts -= Double(yellowCards) * 1.0
        pts -= Double(redCards) * 3.0
        // Defensive actions — applied to every position but disproportionately
        // benefit DEF/CDM players who rack these up without scoring goals.
        pts += Double(interceptions) * 1.0
        pts += Double(blockedShots) * 1.5
        pts += Double(clearances) * 0.3
        if position == "DEF" {
            if cleanSheet && gameFinal { pts += 5.0 }
            pts -= Double(goalsAgainst) * 0.6
        }
        if position == "GK" {
            pts += Double(saves) * 2.5
            if cleanSheet && gameFinal { pts += 8.0 }
            if gameFinal && teamWon { pts += 6.0 }
            pts -= Double(goalsAgainst) * 2.5
        }
        return pts
    }

    /// Compute leaderboard from entries + live scores
    static func computeLeaderboard(
        entries: [SoccerTiersEntry],
        playerPoints: [String: Double],
        currentUserID: String?
    ) -> [SoccerTiersLeaderboardEntry] {
        var scored: [(entry: SoccerTiersEntry, total: Double, breakdown: [String: Double])] = []

        for entry in entries {
            var total = 0.0
            var breakdown: [String: Double] = [:]
            for pick in entry.picks {
                let pts = playerPoints[pick.playerID] ?? 0
                total += pts
                breakdown[pick.playerID] = pts
            }
            scored.append((entry, total, breakdown))
        }

        scored.sort { $0.total > $1.total }

        return scored.enumerated().map { index, item in
            SoccerTiersLeaderboardEntry(
                id: item.entry.id,
                entryName: item.entry.entryName,
                picks: item.entry.picks,
                totalPoints: item.total,
                rank: index + 1,
                isCurrentUser: item.entry.userID == currentUserID,
                playerPoints: item.breakdown
            )
        }
    }

    /// RR delta calculation (same tiers as DFS/Playoff Tiers)
    static func rrDelta(forRank rank: Int, totalEntries: Int) -> Int {
        switch rank {
        case 1:         return 700
        case 2:         return 500
        case 3:         return 350
        case 4:         return 250
        case 5:         return 200
        case 6:         return 160
        case 7:         return 130
        case 8:         return 110
        case 9:         return 100
        case 10...12:   return 80
        case 13...15:   return 70
        case 16...18:   return 60
        case 19...27:   return 50
        case 28...36:   return 40
        case 37...54:   return 35
        case 55...81:   return 30
        case 82...126:  return 25
        case 127...300: return 20
        default:        return -10
        }
    }
}

// MARK: - Hardcoded World Cup 2026 Squad Data

struct SoccerTiersSquadData {

    /// Composite score: (marketValue × 0.85) + (fifaRankWeight × 0.15)
    /// Higher score = higher tier placement. Individual ability is the
    /// dominant factor — team strength is only a small tiebreaker. The
    /// previous 60/40 split dragged elite individual stars down too far
    /// when their nation's rank was middling (e.g. Haaland with Norway
    /// at FRW 70 ended up in T4 instead of T1).
    private static func composite(_ marketValue: Double, _ fifaRankWeight: Double) -> Double {
        marketValue * 0.85 + fifaRankWeight * 0.15
    }

    /// Generate the full player pool for World Cup 2026 Tiers
    static func worldCup2026() -> [SoccerTiersPlayer] {
        var players: [SoccerTiersPlayer] = []

        func add(_ name: String, _ country: String, _ code: String, _ pos: String, _ mv: Double, _ frw: Double) {
            let slug = name.lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .replacingOccurrences(of: "'", with: "")
            let id = "wc-\(slug)-\(code.lowercased())"
            players.append(SoccerTiersPlayer(
                id: id, name: name, country: country, countryCode: code,
                position: pos, tier: 0,
                projectedPoints: composite(mv, frw),
                matchesPlayed: 0, totalFantasyPoints: 0, perMatchAvg: 0,
                imageURL: nil, isEliminated: false
            ))
        }

        // ═══════════════════════════════════════
        // ARGENTINA (FIFA #1) — frw: 98
        // ═══════════════════════════════════════
        add("Lionel Messi",         "Argentina", "ARG", "FWD", 90, 98)
        add("Julian Alvarez",       "Argentina", "ARG", "FWD", 86, 98)
        add("Lautaro Martinez",     "Argentina", "ARG", "FWD", 84, 98)
        add("Rodrigo De Paul",      "Argentina", "ARG", "MID", 72, 98)
        add("Enzo Fernandez",       "Argentina", "ARG", "MID", 80, 98)
        add("Alexis Mac Allister",  "Argentina", "ARG", "MID", 78, 98)
        add("Cristian Romero",      "Argentina", "ARG", "DEF", 76, 98)
        add("Lisandro Martinez",    "Argentina", "ARG", "DEF", 74, 98)
        add("Emiliano Martinez",    "Argentina", "ARG", "GK",  75, 98)
        add("Nahuel Molina",        "Argentina", "ARG", "DEF", 68, 98)

        // ═══════════════════════════════════════
        // FRANCE (FIFA #2) — frw: 96
        // ═══════════════════════════════════════
        add("Kylian Mbappe",        "France", "FRA", "FWD", 98, 96)
        add("Antoine Griezmann",    "France", "FRA", "FWD", 80, 96)
        add("Ousmane Dembele",      "France", "FRA", "FWD", 82, 96)
        add("Aurelien Tchouameni",  "France", "FRA", "MID", 80, 96)
        add("Eduardo Camavinga",    "France", "FRA", "MID", 78, 96)
        add("William Saliba",       "France", "FRA", "DEF", 82, 96)
        add("Theo Hernandez",       "France", "FRA", "DEF", 78, 96)
        add("Jules Kounde",         "France", "FRA", "DEF", 76, 96)
        add("Mike Maignan",         "France", "FRA", "GK",  76, 96)
        add("Randal Kolo Muani",    "France", "FRA", "FWD", 72, 96)

        // ═══════════════════════════════════════
        // ENGLAND (FIFA #3) — frw: 94
        // ═══════════════════════════════════════
        add("Jude Bellingham",      "England", "ENG", "MID", 95, 94)
        add("Bukayo Saka",          "England", "ENG", "FWD", 88, 94)
        add("Phil Foden",           "England", "ENG", "MID", 87, 94)
        add("Harry Kane",           "England", "ENG", "FWD", 85, 94)
        add("Declan Rice",          "England", "ENG", "MID", 82, 94)
        add("Trent Alexander-Arnold", "England", "ENG", "DEF", 80, 94)
        add("Kobbie Mainoo",        "England", "ENG", "MID", 74, 94)
        add("Marc Guehi",           "England", "ENG", "DEF", 72, 94)
        add("Jordan Pickford",      "England", "ENG", "GK",  68, 94)

        // ═══════════════════════════════════════
        // SPAIN (FIFA #4) — frw: 92
        // ═══════════════════════════════════════
        add("Lamine Yamal",         "Spain", "ESP", "FWD", 92, 92)
        add("Rodri",                "Spain", "ESP", "MID", 90, 92)
        add("Pedri",                "Spain", "ESP", "MID", 84, 92)
        add("Nico Williams",        "Spain", "ESP", "FWD", 84, 92)
        add("Gavi",                 "Spain", "ESP", "MID", 78, 92)
        add("Dani Olmo",            "Spain", "ESP", "MID", 80, 92)
        add("Marc Cucurella",       "Spain", "ESP", "DEF", 72, 92)
        add("Unai Simon",           "Spain", "ESP", "GK",  70, 92)
        add("Robin Le Normand",     "Spain", "ESP", "DEF", 70, 92)
        add("Mikel Oyarzabal",      "Spain", "ESP", "FWD", 72, 92)

        // ═══════════════════════════════════════
        // BRAZIL (FIFA #5) — frw: 90
        // ═══════════════════════════════════════
        add("Vinicius Junior",      "Brazil", "BRA", "FWD", 96, 90)
        add("Rodrygo",              "Brazil", "BRA", "FWD", 84, 90)
        add("Raphinha",             "Brazil", "BRA", "FWD", 82, 90)
        add("Bruno Guimaraes",      "Brazil", "BRA", "MID", 78, 90)
        add("Joao Gomes",           "Brazil", "BRA", "MID", 72, 90)
        add("Marquinhos",           "Brazil", "BRA", "DEF", 74, 90)
        add("Militao",              "Brazil", "BRA", "DEF", 72, 90)
        add("Endrick",              "Brazil", "BRA", "FWD", 76, 90)
        add("Alisson",              "Brazil", "BRA", "GK",  76, 90)
        add("Savinho",              "Brazil", "BRA", "FWD", 74, 90)

        // ═══════════════════════════════════════
        // PORTUGAL (FIFA #6) — frw: 88
        // ═══════════════════════════════════════
        add("Cristiano Ronaldo",    "Portugal", "POR", "FWD", 78, 88)
        add("Bruno Fernandes",      "Portugal", "POR", "MID", 82, 88)
        add("Bernardo Silva",       "Portugal", "POR", "MID", 82, 88)
        add("Rafael Leao",          "Portugal", "POR", "FWD", 82, 88)
        add("Ruben Dias",           "Portugal", "POR", "DEF", 78, 88)
        add("Joao Neves",           "Portugal", "POR", "MID", 78, 88)
        add("Vitinha",              "Portugal", "POR", "MID", 76, 88)
        add("Diogo Jota",           "Portugal", "POR", "FWD", 78, 88)
        add("Diogo Costa",          "Portugal", "POR", "GK",  70, 88)

        // ═══════════════════════════════════════
        // NETHERLANDS (FIFA #7) — frw: 86
        // ═══════════════════════════════════════
        add("Xavi Simons",          "Netherlands", "NED", "MID", 86, 86)
        add("Cody Gakpo",           "Netherlands", "NED", "FWD", 80, 86)
        add("Virgil van Dijk",      "Netherlands", "NED", "DEF", 78, 86)
        add("Frenkie de Jong",      "Netherlands", "NED", "MID", 76, 86)
        add("Ryan Gravenberch",     "Netherlands", "NED", "MID", 76, 86)
        add("Nathan Ake",           "Netherlands", "NED", "DEF", 72, 86)
        add("Denzel Dumfries",      "Netherlands", "NED", "DEF", 70, 86)
        add("Memphis Depay",        "Netherlands", "NED", "FWD", 68, 86)

        // ═══════════════════════════════════════
        // GERMANY (FIFA #8) — frw: 84
        // ═══════════════════════════════════════
        add("Florian Wirtz",        "Germany", "GER", "MID", 92, 84)
        add("Jamal Musiala",        "Germany", "GER", "MID", 90, 84)
        add("Kai Havertz",          "Germany", "GER", "FWD", 78, 84)
        add("Leroy Sane",           "Germany", "GER", "FWD", 74, 84)
        add("Toni Kroos",           "Germany", "GER", "MID", 72, 84)
        add("Antonio Rudiger",      "Germany", "GER", "DEF", 74, 84)
        add("Joshua Kimmich",       "Germany", "GER", "DEF", 78, 84)
        add("Manuel Neuer",         "Germany", "GER", "GK",  68, 84)
        add("Niclas Fullkrug",      "Germany", "GER", "FWD", 70, 84)

        // ═══════════════════════════════════════
        // BELGIUM (FIFA #9) — frw: 82
        // ═══════════════════════════════════════
        add("Kevin De Bruyne",      "Belgium", "BEL", "MID", 86, 82)
        add("Jeremy Doku",          "Belgium", "BEL", "FWD", 78, 82)
        add("Romelu Lukaku",        "Belgium", "BEL", "FWD", 72, 82)
        add("Amadou Onana",         "Belgium", "BEL", "MID", 72, 82)
        add("Youri Tielemans",      "Belgium", "BEL", "MID", 68, 82)
        add("Timothy Castagne",     "Belgium", "BEL", "DEF", 64, 82)
        add("Thibaut Courtois",     "Belgium", "BEL", "GK",  76, 82)

        // ═══════════════════════════════════════
        // COLOMBIA (FIFA #10) — frw: 80
        // ═══════════════════════════════════════
        add("Luis Diaz",            "Colombia", "COL", "FWD", 82, 80)
        add("James Rodriguez",      "Colombia", "COL", "MID", 68, 80)
        add("Jhon Arias",           "Colombia", "COL", "FWD", 70, 80)
        add("Jefferson Lerma",      "Colombia", "COL", "MID", 64, 80)
        add("Davinson Sanchez",     "Colombia", "COL", "DEF", 66, 80)
        add("Daniel Munoz",         "Colombia", "COL", "DEF", 66, 80)
        add("Camilo Vargas",        "Colombia", "COL", "GK",  60, 80)

        // ═══════════════════════════════════════
        // CROATIA (FIFA #11) — frw: 78
        // ═══════════════════════════════════════
        add("Luka Modric",          "Croatia", "CRO", "MID", 72, 78)
        add("Mateo Kovacic",        "Croatia", "CRO", "MID", 72, 78)
        add("Josko Gvardiol",       "Croatia", "CRO", "DEF", 78, 78)
        add("Andrej Kramaric",      "Croatia", "CRO", "FWD", 66, 78)
        add("Marcelo Brozovic",     "Croatia", "CRO", "MID", 64, 78)
        add("Ivan Perisic",         "Croatia", "CRO", "FWD", 60, 78)
        add("Dominik Livakovic",    "Croatia", "CRO", "GK",  64, 78)

        // ═══════════════════════════════════════
        // URUGUAY (FIFA #12) — frw: 76
        // ═══════════════════════════════════════
        add("Federico Valverde",    "Uruguay", "URU", "MID", 86, 76)
        add("Darwin Nunez",         "Uruguay", "URU", "FWD", 78, 76)
        add("Ronald Araujo",        "Uruguay", "URU", "DEF", 76, 76)
        add("Rodrigo Bentancur",    "Uruguay", "URU", "MID", 66, 76)
        add("Manuel Ugarte",        "Uruguay", "URU", "MID", 72, 76)
        add("Facundo Pellistri",    "Uruguay", "URU", "FWD", 62, 76)
        add("Sergio Rochet",        "Uruguay", "URU", "GK",  56, 76)

        // ═══════════════════════════════════════
        // JAPAN (FIFA #13) — frw: 74
        // ═══════════════════════════════════════
        add("Takefusa Kubo",        "Japan", "JPN", "FWD", 76, 74)
        add("Kaoru Mitoma",         "Japan", "JPN", "FWD", 74, 74)
        add("Wataru Endo",          "Japan", "JPN", "MID", 68, 74)
        add("Daichi Kamada",        "Japan", "JPN", "MID", 68, 74)
        add("Takehiro Tomiyasu",    "Japan", "JPN", "DEF", 68, 74)
        add("Ko Itakura",           "Japan", "JPN", "DEF", 62, 74)
        add("Shuichi Gonda",        "Japan", "JPN", "GK",  56, 74)

        // ═══════════════════════════════════════
        // MOROCCO (FIFA #14) — frw: 72
        // ═══════════════════════════════════════
        add("Achraf Hakimi",        "Morocco", "MAR", "DEF", 82, 72)
        add("Hakim Ziyech",         "Morocco", "MAR", "MID", 68, 72)
        add("Sofyan Amrabat",       "Morocco", "MAR", "MID", 66, 72)
        add("Youssef En-Nesyri",    "Morocco", "MAR", "FWD", 66, 72)
        add("Azzedine Ounahi",      "Morocco", "MAR", "MID", 62, 72)
        add("Noussair Mazraoui",    "Morocco", "MAR", "DEF", 70, 72)
        add("Yassine Bounou",       "Morocco", "MAR", "GK",  68, 72)

        // ═══════════════════════════════════════
        // NORWAY (FIFA #15) — frw: 70
        // ═══════════════════════════════════════
        add("Erling Haaland",       "Norway", "NOR", "FWD", 97, 70)
        add("Martin Odegaard",      "Norway", "NOR", "MID", 88, 70)
        add("Alexander Sorloth",    "Norway", "NOR", "FWD", 70, 70)
        add("Sander Berge",         "Norway", "NOR", "MID", 66, 70)
        add("Antonio Nusa",         "Norway", "NOR", "FWD", 64, 70)
        add("Kristoffer Ajer",      "Norway", "NOR", "DEF", 60, 70)

        // ═══════════════════════════════════════
        // USA (FIFA #16) — frw: 68
        // ═══════════════════════════════════════
        add("Christian Pulisic",    "USA", "USA", "FWD", 80, 68)
        add("Weston McKennie",      "USA", "USA", "MID", 68, 68)
        add("Tyler Adams",          "USA", "USA", "MID", 66, 68)
        add("Gio Reyna",            "USA", "USA", "MID", 68, 68)
        add("Sergino Dest",         "USA", "USA", "DEF", 62, 68)
        add("Tim Weah",             "USA", "USA", "FWD", 64, 68)
        add("Matt Turner",          "USA", "USA", "GK",  58, 68)
        add("Folarin Balogun",      "USA", "USA", "FWD", 66, 68)

        // ═══════════════════════════════════════
        // MEXICO (FIFA #17) — frw: 66
        // ═══════════════════════════════════════
        add("Hirving Lozano",       "Mexico", "MEX", "FWD", 68, 66)
        add("Edson Alvarez",        "Mexico", "MEX", "MID", 70, 66)
        add("Santiago Gimenez",     "Mexico", "MEX", "FWD", 72, 66)
        add("Cesar Montes",         "Mexico", "MEX", "DEF", 58, 66)
        add("Jesus Corona",         "Mexico", "MEX", "FWD", 56, 66)
        add("Guillermo Ochoa",      "Mexico", "MEX", "GK",  56, 66)

        // ═══════════════════════════════════════
        // SOUTH KOREA (FIFA #18) — frw: 64
        // ═══════════════════════════════════════
        add("Son Heung-min",        "South Korea", "KOR", "FWD", 82, 64)
        add("Lee Kang-in",          "South Korea", "KOR", "MID", 74, 64)
        add("Kim Min-jae",          "South Korea", "KOR", "DEF", 76, 64)
        add("Hwang Hee-chan",       "South Korea", "KOR", "FWD", 66, 64)
        add("Jeong Woo-yeong",     "South Korea", "KOR", "MID", 58, 64)
        add("Kim Seung-gyu",        "South Korea", "KOR", "GK",  50, 64)

        // ═══════════════════════════════════════
        // SENEGAL (FIFA #19) — frw: 62
        // ═══════════════════════════════════════
        add("Sadio Mane",           "Senegal", "SEN", "FWD", 72, 62)
        add("Ismaila Sarr",         "Senegal", "SEN", "FWD", 66, 62)
        add("Idrissa Gueye",        "Senegal", "SEN", "MID", 60, 62)
        add("Kalidou Koulibaly",    "Senegal", "SEN", "DEF", 64, 62)
        add("Pape Matar Sarr",      "Senegal", "SEN", "MID", 64, 62)
        add("Edouard Mendy",        "Senegal", "SEN", "GK",  62, 62)

        // ═══════════════════════════════════════
        // SWITZERLAND (FIFA #20) — frw: 60
        // ═══════════════════════════════════════
        add("Granit Xhaka",         "Switzerland", "SUI", "MID", 74, 60)
        add("Xherdan Shaqiri",      "Switzerland", "SUI", "FWD", 58, 60)
        add("Breel Embolo",         "Switzerland", "SUI", "FWD", 62, 60)
        add("Manuel Akanji",        "Switzerland", "SUI", "DEF", 74, 60)
        add("Denis Zakaria",        "Switzerland", "SUI", "MID", 64, 60)
        add("Yann Sommer",          "Switzerland", "SUI", "GK",  64, 60)

        // ═══════════════════════════════════════
        // AUSTRIA (FIFA #21) — frw: 58
        // ═══════════════════════════════════════
        add("David Alaba",          "Austria", "AUT", "DEF", 72, 58)
        add("Marcel Sabitzer",      "Austria", "AUT", "MID", 68, 58)
        add("Konrad Laimer",        "Austria", "AUT", "MID", 66, 58)
        add("Marko Arnautovic",     "Austria", "AUT", "FWD", 56, 58)
        add("Patrick Pentz",        "Austria", "AUT", "GK",  50, 58)

        // ═══════════════════════════════════════
        // TURKEY (FIFA #22) — frw: 56
        // ═══════════════════════════════════════
        add("Hakan Calhanoglu",     "Turkey", "TUR", "MID", 78, 56)
        add("Arda Guler",           "Turkey", "TUR", "MID", 78, 56)
        add("Kenan Yildiz",         "Turkey", "TUR", "FWD", 72, 56)
        add("Ferdi Kadioglu",       "Turkey", "TUR", "DEF", 66, 56)
        add("Altay Bayindir",       "Turkey", "TUR", "GK",  54, 56)

        // ═══════════════════════════════════════
        // ECUADOR (FIFA #23) — frw: 54
        // ═══════════════════════════════════════
        add("Moises Caicedo",       "Ecuador", "ECU", "MID", 80, 54)
        add("Enner Valencia",       "Ecuador", "ECU", "FWD", 58, 54)
        add("Piero Hincapie",       "Ecuador", "ECU", "DEF", 68, 54)
        add("Gonzalo Plata",        "Ecuador", "ECU", "FWD", 60, 54)
        add("Hernan Galindez",      "Ecuador", "ECU", "GK",  48, 54)

        // ═══════════════════════════════════════
        // CANADA (FIFA #24) — frw: 52
        // ═══════════════════════════════════════
        add("Alphonso Davies",      "Canada", "CAN", "DEF", 78, 52)
        add("Jonathan David",       "Canada", "CAN", "FWD", 76, 52)
        add("Tajon Buchanan",       "Canada", "CAN", "FWD", 62, 52)
        add("Stephen Eustaquio",    "Canada", "CAN", "MID", 60, 52)
        add("Cyle Larin",           "Canada", "CAN", "FWD", 56, 52)

        // ═══════════════════════════════════════
        // IVORY COAST (FIFA #25) — frw: 50
        // ═══════════════════════════════════════
        add("Sebastien Haller",     "Ivory Coast", "CIV", "FWD", 64, 50)
        add("Franck Kessie",        "Ivory Coast", "CIV", "MID", 66, 50)
        add("Nicolas Pepe",         "Ivory Coast", "CIV", "FWD", 58, 50)
        add("Simon Adingra",        "Ivory Coast", "CIV", "FWD", 62, 50)
        add("Odilon Kossounou",     "Ivory Coast", "CIV", "DEF", 58, 50)

        // ═══════════════════════════════════════
        // EGYPT (FIFA #26) — frw: 48
        // ═══════════════════════════════════════
        add("Mohamed Salah",        "Egypt", "EGY", "FWD", 88, 48)
        add("Omar Marmoush",        "Egypt", "EGY", "FWD", 76, 48)
        add("Mostafa Mohamed",      "Egypt", "EGY", "FWD", 58, 48)
        add("Mohamed Elneny",       "Egypt", "EGY", "MID", 52, 48)
        add("Mohamed El Shenawy",   "Egypt", "EGY", "GK",  50, 48)

        // ═══════════════════════════════════════
        // ALGERIA (FIFA #27) — frw: 46
        // ═══════════════════════════════════════
        add("Riyad Mahrez",         "Algeria", "ALG", "FWD", 68, 46)
        add("Ismael Bennacer",      "Algeria", "ALG", "MID", 68, 46)
        add("Said Benrahma",        "Algeria", "ALG", "FWD", 62, 46)
        add("Aissa Mandi",          "Algeria", "ALG", "DEF", 56, 46)

        // ═══════════════════════════════════════
        // TUNISIA (FIFA #28) — frw: 44
        // ═══════════════════════════════════════
        add("Hannibal Mejbri",      "Tunisia", "TUN", "MID", 58, 44)
        add("Youssef Msakni",       "Tunisia", "TUN", "FWD", 52, 44)
        add("Ellyes Skhiri",        "Tunisia", "TUN", "MID", 60, 44)
        add("Montassar Talbi",      "Tunisia", "TUN", "DEF", 52, 44)

        // ═══════════════════════════════════════
        // AUSTRALIA (FIFA #29) — frw: 42
        // ═══════════════════════════════════════
        add("Mathew Leckie",        "Australia", "AUS", "FWD", 50, 42)
        add("Jackson Irvine",       "Australia", "AUS", "MID", 50, 42)
        add("Aziz Behich",          "Australia", "AUS", "DEF", 46, 42)
        add("Awer Mabil",           "Australia", "AUS", "FWD", 48, 42)

        // ═══════════════════════════════════════
        // PARAGUAY (FIFA #30) — frw: 40
        // ═══════════════════════════════════════
        add("Miguel Almiron",       "Paraguay", "PAR", "MID", 62, 40)
        add("Julio Enciso",         "Paraguay", "PAR", "FWD", 60, 40)
        add("Gustavo Gomez",        "Paraguay", "PAR", "DEF", 56, 40)
        add("Antonio Sanabria",     "Paraguay", "PAR", "FWD", 54, 40)

        // ═══════════════════════════════════════
        // SWEDEN (FIFA #31) — frw: 38
        // ═══════════════════════════════════════
        add("Viktor Gyokeres",      "Sweden", "SWE", "FWD", 84, 38)
        add("Alexander Isak",       "Sweden", "SWE", "FWD", 86, 38)
        add("Dejan Kulusevski",     "Sweden", "SWE", "MID", 78, 38)
        add("Emil Krafth",          "Sweden", "SWE", "DEF", 52, 38)

        // ═══════════════════════════════════════
        // GHANA (FIFA #32) — frw: 36
        // ═══════════════════════════════════════
        add("Mohammed Kudus",       "Ghana", "GHA", "MID", 76, 36)
        add("Thomas Partey",        "Ghana", "GHA", "MID", 70, 36)
        add("Inaki Williams",       "Ghana", "GHA", "FWD", 60, 36)
        add("Tariq Lamptey",        "Ghana", "GHA", "DEF", 56, 36)

        // ═══════════════════════════════════════
        // IRAN (FIFA #33) — frw: 34
        // ═══════════════════════════════════════
        add("Mehdi Taremi",         "Iran", "IRN", "FWD", 68, 34)
        add("Sardar Azmoun",        "Iran", "IRN", "FWD", 64, 34)
        add("Alireza Jahanbakhsh",  "Iran", "IRN", "FWD", 52, 34)
        add("Alireza Beiranvand",   "Iran", "IRN", "GK",  52, 34)

        // ═══════════════════════════════════════
        // SCOTLAND (FIFA #34) — frw: 32
        // ═══════════════════════════════════════
        add("Andy Robertson",       "Scotland", "SCO", "DEF", 72, 32)
        add("John McGinn",          "Scotland", "SCO", "MID", 62, 32)
        add("Scott McTominay",      "Scotland", "SCO", "MID", 66, 32)
        add("Che Adams",            "Scotland", "SCO", "FWD", 56, 32)

        // ═══════════════════════════════════════
        // SAUDI ARABIA (FIFA #35) — frw: 30
        // ═══════════════════════════════════════
        add("Salem Al-Dawsari",     "Saudi Arabia", "KSA", "FWD", 52, 30)
        add("Firas Al-Buraikan",    "Saudi Arabia", "KSA", "FWD", 46, 30)
        add("Mohammed Al-Owais",    "Saudi Arabia", "KSA", "GK",  44, 30)

        // ═══════════════════════════════════════
        // QATAR (FIFA #36) — frw: 28
        // ═══════════════════════════════════════
        add("Akram Afif",           "Qatar", "QAT", "FWD", 56, 28)
        add("Almoez Ali",           "Qatar", "QAT", "FWD", 48, 28)
        add("Hassan Al-Haydos",     "Qatar", "QAT", "MID", 40, 28)

        return players
    }
}

// MARK: - ESPN World Cup Data Provider (Stub)

/// Actor that caches World Cup match events
private actor WorldCupMatchCache {
    var events: [[String: Any]] = []
    var fetchedAt: Date = .distantPast

    func get() -> [[String: Any]]? {
        guard Date().timeIntervalSince(fetchedAt) < 30 else { return nil }
        return events.isEmpty ? nil : events
    }

    func set(_ events: [[String: Any]]) {
        self.events = events
        self.fetchedAt = Date()
    }
}

struct ESPNSoccerTiersDataProvider: Sendable {
    private let session: URLSession
    private let matchCache = WorldCupMatchCache()

    /// ESPN league slug for FIFA World Cup
    private let leagueSlug = "fifa.world"

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Fetch World Cup Matches

    /// Fetch all World Cup matches (completed + in-progress) across the tournament window.
    func fetchWorldCupMatches() async -> [[String: Any]] {
        if let cached = await matchCache.get() { return cached }

        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"

        // Scan the full WC window: June 11 - July 19, ±3 days
        let dates = (-45...3).compactMap { offset -> String? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: Date()) else { return nil }
            return formatter.string(from: date)
        }

        var allEvents: [[String: Any]] = []
        var seenIDs = Set<String>()
        let batchSize = 15

        for batchStart in stride(from: 0, to: dates.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, dates.count)
            let batch = Array(dates[batchStart..<batchEnd])

            let batchResults = await withTaskGroup(of: [[String: Any]].self) { group in
                for dateKey in batch {
                    group.addTask {
                        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/soccer/\(self.leagueSlug)/scoreboard?dates=\(dateKey)") else { return [] }
                        guard let (data, response) = try? await self.session.data(from: url),
                              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [] }
                        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let events = json["events"] as? [[String: Any]] else { return [] }
                        return events
                    }
                }
                var results: [[[String: Any]]] = []
                for await events in group { results.append(events) }
                return results.flatMap { $0 }
            }

            for event in batchResults {
                if let id = event["id"] as? String, seenIDs.insert(id).inserted {
                    allEvents.append(event)
                }
            }
        }

        await matchCache.set(allEvents)
        return allEvents
    }

    // MARK: - Fetch Accumulated Scores

    /// Fetch accumulated fantasy points for the player pool across every
    /// completed or in-progress World Cup match. Mirrors the DFS soccer
    /// scoring pipeline (`ESPNSoccerDFSLiveScoringProvider`) but
    /// accumulates per-player FPTS across the whole tournament instead
    /// of a single slate.
    ///
    /// Match flow per event:
    ///   1. Fetch the `/summary?event=` payload for goals/assists/shots/cards
    ///   2. Fetch each picked player's core-API stats line for defensive
    ///      actions (tackles / interceptions / blocks / clearances) — the
    ///      `/summary` response intentionally omits those stats
    ///   3. Pass everything into `SoccerTiersEngine.soccerFantasyPoints`
    ///      (the updated formula that gives defenders credit for the
    ///      defensive actions Marquinhos-style)
    ///   4. Sum per playerID across every event
    func fetchWorldCupScores(players: [SoccerTiersPlayer]) async -> SoccerTiersScoreSnapshot {
        let events = await fetchWorldCupMatches()

        // Filter to completed or in-progress matches
        var matchIDs: [String] = []
        for event in events {
            guard let id = event["id"] as? String,
                  let competitions = event["competitions"] as? [[String: Any]],
                  let competition = competitions.first,
                  let status = competition["status"] as? [String: Any],
                  let statusType = status["type"] as? [String: Any],
                  let state = statusType["state"] as? String else { continue }
            if state == "in" || state == "post" {
                matchIDs.append(id)
            }
        }

        guard !matchIDs.isEmpty else {
            return SoccerTiersScoreSnapshot(
                playerFantasyPoints: [:], playerMatchesPlayed: [:],
                eliminatedNations: [], isTournamentComplete: false
            )
        }

        // Build a name → SoccerTiersPlayer lookup so we can map ESPN's
        // athlete payloads back to our pool. Names are lowercased and
        // accent-folded so "Vinícius Júnior" matches "Vinicius Junior".
        func normalize(_ s: String) -> String {
            s.lowercased().folding(options: .diacriticInsensitive, locale: .current)
        }
        var playerByName: [String: SoccerTiersPlayer] = [:]
        for p in players {
            playerByName[normalize(p.name)] = p
        }
        let allowedCountryCodes: Set<String> = Set(players.map { $0.countryCode.uppercased() })

        // Accumulators (concurrent-safe via TaskGroup serialization at receive)
        var fantasyPointsByID: [String: Double] = [:]
        var matchesPlayedByID: [String: Int] = [:]

        // Batch the per-match work so we don't open hundreds of sockets
        // at once on a tournament with 60+ completed matches.
        let batchSize = 8
        for batchStart in stride(from: 0, to: matchIDs.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, matchIDs.count)
            let batch = Array(matchIDs[batchStart..<batchEnd])

            let batchResults = await withTaskGroup(of: [(String, Double)].self) { group in
                for matchID in batch {
                    group.addTask {
                        await self.scoreMatchForPool(
                            matchID: matchID,
                            playerByName: playerByName,
                            allowedCountryCodes: allowedCountryCodes
                        )
                    }
                }
                var all: [(String, Double)] = []
                for await partial in group { all.append(contentsOf: partial) }
                return all
            }
            for (playerID, fpts) in batchResults {
                fantasyPointsByID[playerID, default: 0] += fpts
                matchesPlayedByID[playerID, default: 0] += 1
            }
        }

        return SoccerTiersScoreSnapshot(
            playerFantasyPoints: fantasyPointsByID,
            playerMatchesPlayed: matchesPlayedByID,
            eliminatedNations: [],
            isTournamentComplete: false
        )
    }

    /// Score a single WC match against our pool. Returns one (playerID, fpts)
    /// tuple for each pool player who participated in this match. Players
    /// not in our pool are silently skipped — the goal is per-pool scoring,
    /// not a full leaderboard for the match.
    private func scoreMatchForPool(
        matchID: String,
        playerByName: [String: SoccerTiersPlayer],
        allowedCountryCodes: Set<String>
    ) async -> [(String, Double)] {
        let urlString = "https://site.api.espn.com/apis/site/v2/sports/soccer/\(self.leagueSlug)/summary?event=\(matchID)"
        guard let url = URL(string: urlString) else { return [] }
        guard let (data, response) = try? await self.session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        // Pull match-level context: state, teams, scores, clean sheets
        let header = json["header"] as? [String: Any]
        let headerCompetitions = header?["competitions"] as? [[String: Any]]
        let headerCompetition = headerCompetitions?.first
        let status = headerCompetition?["status"] as? [String: Any]
        let statusType = status?["type"] as? [String: Any]
        let state = statusType?["state"] as? String ?? "in"
        let gameFinal = (statusType?["completed"] as? Bool) ?? (state == "post")

        // Map teamID → (score, country abbreviation)
        struct TeamInfo {
            let score: Int
            let abbr: String
        }
        var teamInfoByID: [String: TeamInfo] = [:]
        let competitors = (headerCompetition?["competitors"] as? [[String: Any]]) ?? []
        for comp in competitors {
            guard let team = comp["team"] as? [String: Any],
                  let teamID = team["id"] as? String else { continue }
            let abbr = (team["abbreviation"] as? String)?.uppercased() ?? ""
            let scoreStr = (comp["score"] as? String) ?? "0"
            teamInfoByID[teamID] = TeamInfo(score: Int(scoreStr) ?? 0, abbr: abbr)
        }

        // First pass: collect every (athlete, team) we need stats for,
        // then fan out defensive-stats fetches in parallel.
        struct PendingPlayer {
            let poolPlayer: SoccerTiersPlayer
            let athleteID: String
            let teamID: String
            let goals: Int
            let assists: Int
            let shotsOnTarget: Int
            let totalShots: Int
            let saves: Int
            let yellowCards: Int
            let redCards: Int
            let foulsDrawn: Int
        }
        var pending: [PendingPlayer] = []

        func parseStatMap(_ statsArr: [[String: Any]]) -> [String: Double] {
            var statMap: [String: Double] = [:]
            for stat in statsArr {
                if let name = stat["name"] as? String {
                    let value = stat["value"] as? Double
                        ?? (stat["displayValue"] as? String).flatMap { Double($0) }
                        ?? 0
                    statMap[name] = value
                }
            }
            return statMap
        }
        func appendCandidate(athlete: [String: Any], teamID: String, teamAbbr: String, statMap: [String: Double]) {
            guard let athleteID = athlete["id"] as? String,
                  let displayName = athlete["displayName"] as? String else { return }
            let normName = displayName.lowercased()
                .folding(options: .diacriticInsensitive, locale: .current)
            guard let poolPlayer = playerByName[normName],
                  poolPlayer.countryCode.uppercased() == teamAbbr else { return }
            pending.append(PendingPlayer(
                poolPlayer: poolPlayer,
                athleteID: athleteID,
                teamID: teamID,
                goals: Int(statMap["totalGoals"] ?? 0),
                assists: Int(statMap["goalAssists"] ?? 0),
                shotsOnTarget: Int(statMap["shotsOnTarget"] ?? 0),
                totalShots: Int(statMap["totalShots"] ?? 0),
                saves: Int(statMap["saves"] ?? 0),
                yellowCards: Int(statMap["yellowCards"] ?? 0),
                redCards: Int(statMap["redCards"] ?? 0),
                foulsDrawn: Int(statMap["foulsSuffered"] ?? 0)
            ))
        }

        // ESPN does NOT publish `boxscore.players` for fifa.world — it's an
        // empty array even for finished matches, which left every tiers
        // entry at 0.0 all matchday. Per-player stats live in the summary's
        // `rosters[].roster[].stats` (the structure the soccer DFS scorer
        // reads). Parse rosters first; keep the boxscore path as a fallback
        // for any competition that publishes it.
        let rostersArr = json["rosters"] as? [[String: Any]] ?? []
        for teamRoster in rostersArr {
            guard let team = teamRoster["team"] as? [String: Any],
                  let teamID = team["id"] as? String,
                  let teamInfo = teamInfoByID[teamID],
                  allowedCountryCodes.contains(teamInfo.abbr) else { continue }
            let entries = teamRoster["roster"] as? [[String: Any]] ?? []
            for entry in entries {
                guard let athlete = entry["athlete"] as? [String: Any] else { continue }
                let statMap = parseStatMap(entry["stats"] as? [[String: Any]] ?? [])
                // Only players who actually appeared — unused subs must not
                // bank clean-sheet/win bonuses.
                let appeared = (statMap["appearances"] ?? 0) > 0
                    || (entry["starter"] as? Bool ?? false)
                    || (entry["subbedIn"] as? Bool ?? false)
                guard appeared else { continue }
                appendCandidate(athlete: athlete, teamID: teamID, teamAbbr: teamInfo.abbr, statMap: statMap)
            }
        }

        if pending.isEmpty {
            let boxscore = json["boxscore"] as? [String: Any]
            let boxPlayers = boxscore?["players"] as? [[String: Any]] ?? []
            for teamGroup in boxPlayers {
                guard let team = teamGroup["team"] as? [String: Any],
                      let teamID = team["id"] as? String,
                      let teamInfo = teamInfoByID[teamID],
                      allowedCountryCodes.contains(teamInfo.abbr) else { continue }
                let statistics = teamGroup["statistics"] as? [[String: Any]] ?? []
                for statCat in statistics {
                    let athletes = statCat["athletes"] as? [[String: Any]] ?? []
                    for entry in athletes {
                        guard let athlete = entry["athlete"] as? [String: Any] else { continue }
                        let statMap = parseStatMap(entry["stats"] as? [[String: Any]] ?? [])
                        appendCandidate(athlete: athlete, teamID: teamID, teamAbbr: teamInfo.abbr, statMap: statMap)
                    }
                }
            }
        }

        // Fan-out defensive-stats fetches per player (one extra core-API
        // request each). For ~6 picked players per match this is cheap;
        // we only iterate athletes that matched our pool above.
        let defStatsByAthleteID: [String: (tackles: Int, interceptions: Int, blockedShots: Int, clearances: Int)] = await withTaskGroup(of: (String, (Int, Int, Int, Int)).self) { group in
            for p in pending {
                let aid = p.athleteID
                let tid = p.teamID
                group.addTask {
                    let stats = await self.fetchTiersDefensiveStats(
                        eventID: matchID, teamID: tid, athleteID: aid
                    )
                    return (aid, stats)
                }
            }
            var dict: [String: (Int, Int, Int, Int)] = [:]
            for await (id, stats) in group { dict[id] = stats }
            return dict.mapValues { (tackles: $0.0, interceptions: $0.1, blockedShots: $0.2, clearances: $0.3) }
        }

        // Final compute pass
        var output: [(String, Double)] = []
        for p in pending {
            let teamInfo = teamInfoByID[p.teamID]!
            let opponent = teamInfoByID.first(where: { $0.key != p.teamID })?.value
            let opponentScore = opponent?.score ?? 0
            let cleanSheet = opponentScore == 0
            let teamWon = teamInfo.score > opponentScore
            let def = defStatsByAthleteID[p.athleteID] ?? (0, 0, 0, 0)

            let fpts = SoccerTiersEngine.soccerFantasyPoints(
                position: p.poolPlayer.position,
                goals: p.goals, assists: p.assists,
                shotsOnTarget: p.shotsOnTarget, totalShots: p.totalShots,
                tackles: def.tackles, interceptions: def.interceptions,
                blockedShots: def.blockedShots, clearances: def.clearances,
                saves: p.saves, yellowCards: p.yellowCards, redCards: p.redCards,
                foulsDrawn: p.foulsDrawn, goalsAgainst: opponentScore,
                cleanSheet: cleanSheet, gameFinal: gameFinal, teamWon: teamWon
            )
            output.append((p.poolPlayer.id, fpts))
        }
        return output
    }

    /// Per-player core-API defensive-stats fetch. Identical to the DFS
    /// version but namespaced to avoid the actor-isolation requirements
    /// of the DFS provider — this struct already runs Sendable so it's
    /// safe to call from a TaskGroup.
    private func fetchTiersDefensiveStats(
        eventID: String, teamID: String, athleteID: String
    ) async -> (tackles: Int, interceptions: Int, blockedShots: Int, clearances: Int) {
        let urlString = "https://sports.core.api.espn.com/v2/sports/soccer/leagues/\(self.leagueSlug)/events/\(eventID)/competitions/\(eventID)/competitors/\(teamID)/roster/\(athleteID)/statistics/0"
        guard let url = URL(string: urlString) else { return (0, 0, 0, 0) }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await self.session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let splits = json["splits"] as? [String: Any],
              let categories = splits["categories"] as? [[String: Any]] else {
            return (0, 0, 0, 0)
        }
        var values: [String: Double] = [:]
        for cat in categories {
            guard let stats = cat["stats"] as? [[String: Any]] else { continue }
            for s in stats {
                guard let name = s["name"] as? String else { continue }
                if let v = s["value"] as? Double {
                    values[name] = v
                } else if let v = s["value"] as? Int {
                    values[name] = Double(v)
                }
            }
        }
        let tackles = Int(values["totalTackles"] ?? values["effectiveTackles"] ?? 0)
        let interceptions = Int(values["interceptions"] ?? 0)
        let blockedShots = Int(values["blockedShots"] ?? 0)
        let clearances = Int(values["totalClearance"] ?? values["effectiveClearance"] ?? 0)
        return (tackles, interceptions, blockedShots, clearances)
    }

    /// Has any World Cup match started? (for locked → live transition)
    func hasMatchesStarted() async -> Bool {
        let events = await fetchWorldCupMatches()
        return events.contains { event in
            guard let competitions = event["competitions"] as? [[String: Any]],
                  let competition = competitions.first,
                  let status = competition["status"] as? [String: Any],
                  let statusType = status["type"] as? [String: Any],
                  let state = statusType["state"] as? String else { return false }
            return state == "in" || state == "post"
        }
    }

    /// Check if the World Cup is complete (final has been played)
    func checkTournamentComplete() async -> Bool {
        let events = await fetchWorldCupMatches()
        // Complete ONLY when the FINAL itself has been played. The old
        // ">=100 of 104 completed" heuristic tripped right after the semis
        // (102 done) and settled the tournament with the 3rd-place game and
        // the final still to play.
        for event in events {
            guard let competitions = event["competitions"] as? [[String: Any]],
                  let competition = competitions.first,
                  let status = competition["status"] as? [String: Any],
                  let statusType = status["type"] as? [String: Any],
                  (statusType["completed"] as? Bool) == true else { continue }
            let notes = (competition["notes"] as? [[String: Any]] ?? [])
            let noteText = notes.compactMap { $0["headline"] as? String }.joined(separator: " ")
            let seasonType = (event["season"] as? [String: Any])?["slug"] as? String ?? ""
            let combined = (noteText + " " + seasonType).lowercased()
                .replacingOccurrences(of: "-", with: " ")
            let isTheFinal = combined.contains("final")
                && !combined.contains("semifinal") && !combined.contains("semi final")
                && !combined.contains("quarterfinal") && !combined.contains("quarter final")
                && !combined.contains("third") && !combined.contains("3rd")
            if isTheFinal { return true }
        }
        return false
    }

    /// Detect which nations have been eliminated from the World Cup.
    /// Two sources:
    ///   1. **Knockout losses** — once the tournament reaches Round of 32,
    ///      every completed match's loser is eliminated. ESPN flags the
    ///      winner explicitly via `competitor.winner=true`, which handles
    ///      penalty shootout outcomes correctly (the loser of regulation
    ///      vs. losing on PKs both surface the same way).
    ///   2. **Group-stage elimination** — after a team has played all 3 of
    ///      its group matches AND they're all "post", the team is
    ///      eliminated if they're in the bottom 2 of the group by points
    ///      (with goal-diff and goals-scored tiebreakers). The top 2
    ///      advance and 8 of 12 third-place teams also advance, so the
    ///      strict "guaranteed eliminated" set is: any 3-game team that
    ///      finished 4th (last) in their group. We don't try to compute
    ///      best-third tiebreakers here — those teams stay non-eliminated
    ///      until they lose their knockout match.
    func fetchEliminatedNations() async -> Set<String> {
        let events = await fetchWorldCupMatches()
        var eliminated = Set<String>()

        // Group-stage tracking: per group, per team → (played, points, GF, GA)
        struct GroupStanding {
            var played: Int = 0
            var points: Int = 0
            var goalsFor: Int = 0
            var goalsAgainst: Int = 0
        }
        var groupStandings: [String: [String: GroupStanding]] = [:]

        for event in events {
            guard let competitions = event["competitions"] as? [[String: Any]],
                  let competition = competitions.first,
                  let status = competition["status"] as? [String: Any],
                  let statusType = status["type"] as? [String: Any],
                  let completed = statusType["completed"] as? Bool, completed,
                  let competitors = competition["competitors"] as? [[String: Any]],
                  competitors.count == 2 else { continue }

            // Determine the stage/round of this match from the season slug,
            // event notes, or competition type. ESPN tags WC matches with
            // headlines like "FIFA World Cup - Group A" or "FIFA World Cup -
            // Round of 32".
            let notes = (competition["notes"] as? [[String: Any]] ?? [])
            let noteText = notes.compactMap { $0["headline"] as? String }
                .joined(separator: " ").lowercased()
            let seasonType = (event["season"] as? [String: Any])?["slug"] as? String ?? ""
            // Normalize hyphens: ESPN often leaves `notes` EMPTY and carries
            // the round only in season.slug as "round-of-32"/"round-of-16" —
            // the space-form keywords below never matched those, so knockout
            // losers from slug-only matches (Senegal, 7/1) were never marked
            // eliminated while notes-tagged matches worked.
            let combined = (noteText + " " + seasonType).lowercased()
                .replacingOccurrences(of: "-", with: " ")

            let isKnockout = combined.contains("round of 32")
                || combined.contains("round of 16")
                || combined.contains("quarterfinal")
                || combined.contains("semifinal")
                || combined.contains("final")
                || combined.contains("knockout")

            let isGroupStage = combined.contains("group ")
                || combined.contains("group-stage")

            if isKnockout {
                // SEMIFINAL losers are NOT eliminated — they still play the
                // 3rd-place game, and its goals count officially (golden
                // boot, records), so their players can still score here too.
                let isSemifinal = combined.contains("semifinal") || combined.contains("semi final")
                let isThirdPlace = combined.contains("third") || combined.contains("3rd")
                if isSemifinal { continue }
                if isThirdPlace {
                    // After the 3rd-place game BOTH teams are done.
                    for c in competitors {
                        let team = c["team"] as? [String: Any]
                        guard let abbr = team?["abbreviation"] as? String else { continue }
                        eliminated.insert(abbr.uppercased())
                    }
                    continue
                }
                // The team flagged winner=false (or whose score is lower
                // with no winner flag) is eliminated.
                for c in competitors {
                    let team = c["team"] as? [String: Any]
                    guard let abbr = team?["abbreviation"] as? String else { continue }
                    if let winner = c["winner"] as? Bool {
                        if !winner { eliminated.insert(abbr.uppercased()) }
                    }
                }
                continue
            }

            if isGroupStage {
                // Extract the group letter ("Group A" → "A").
                let groupKey: String = {
                    let lc = noteText
                    if let range = lc.range(of: "group ") {
                        let after = lc[range.upperBound...]
                        return String(after.prefix(1)).uppercased()
                    }
                    return ""
                }()
                guard !groupKey.isEmpty else { continue }

                // Parse scores
                let score0 = Int((competitors[0]["score"] as? String) ?? "0") ?? 0
                let score1 = Int((competitors[1]["score"] as? String) ?? "0") ?? 0
                let abbr0 = ((competitors[0]["team"] as? [String: Any])?["abbreviation"] as? String)?.uppercased() ?? ""
                let abbr1 = ((competitors[1]["team"] as? [String: Any])?["abbreviation"] as? String)?.uppercased() ?? ""
                guard !abbr0.isEmpty, !abbr1.isEmpty else { continue }

                var standings = groupStandings[groupKey] ?? [:]
                var s0 = standings[abbr0] ?? GroupStanding()
                var s1 = standings[abbr1] ?? GroupStanding()
                s0.played += 1
                s1.played += 1
                s0.goalsFor += score0; s0.goalsAgainst += score1
                s1.goalsFor += score1; s1.goalsAgainst += score0
                if score0 > score1 { s0.points += 3 }
                else if score1 > score0 { s1.points += 3 }
                else { s0.points += 1; s1.points += 1 }
                standings[abbr0] = s0
                standings[abbr1] = s1
                groupStandings[groupKey] = standings
            }
        }

        // For each group where every team has played 3 matches, eliminate
        // the LAST-placed team (4th by points → GD → GF tiebreak). The
        // 3rd-place teams stay alive because 8 of 12 advance; we'd need
        // cross-group comparisons to identify the bottom 4 thirds, which
        // ESPN's `/standings` endpoint would provide cleaner. Keep it
        // conservative for now — guaranteed-out teams only.
        for (_, teams) in groupStandings {
            guard teams.values.allSatisfy({ $0.played >= 3 }) else { continue }
            let sorted = teams.sorted { a, b in
                if a.value.points != b.value.points { return a.value.points > b.value.points }
                let aDiff = a.value.goalsFor - a.value.goalsAgainst
                let bDiff = b.value.goalsFor - b.value.goalsAgainst
                if aDiff != bDiff { return aDiff > bDiff }
                return a.value.goalsFor > b.value.goalsFor
            }
            if let last = sorted.last {
                eliminated.insert(last.key)
            }
        }

        return eliminated
    }
}

// MARK: - Bot Generation

struct SoccerTiersBotDrafter {
    enum BotPersonality: CaseIterable {
        case starsFocused       // Picks highest-rated in each tier
        case nationDiversifier  // Spreads across many nations
        case upsideChaser       // Extra noise, loves high-ceiling picks
        case depthSeeker        // Prefers players from strong nations
        case balanced           // Standard weighted random

        var noiseMultiplier: Double {
            switch self {
            case .starsFocused: return 0.15
            case .nationDiversifier: return 0.25
            case .upsideChaser: return 0.40
            case .depthSeeker: return 0.20
            case .balanced: return 0.25
            }
        }
    }

    static let botNames = [
        "GoalMachine", "SetPieceKing", "PitchVision", "TikiTaka", "CounterAttack",
        "WCDreamer", "GoldenBoot", "FreeKickPro", "CupFever", "GroupStage",
        "KnockoutKing", "PenaltyHero", "ExtraTime", "WorldClass", "TopBins",
        "NutmegKing", "PressHigher", "BuildUpPlay", "WingPlay", "TargetMan",
        "BoxToBox", "Sweeper", "PlayMaker", "AnchorMan", "FalseNine",
        "WallOfSteel", "GoldenGlove", "CupGlory", "GroupWinner", "DarkHorse",
        "Underdog", "FavoriteToWin", "ClutchGoal", "InjuryTime", "StopperPro",
        "CrossMaster", "HeadingKing", "ThroughBall", "OverlapRun", "DeepBlock",
        "HighLine", "GegenpressKing", "CatenaccioFan", "JogaBonito", "TotalFootball"
    ]

    /// Deterministic RNG seeded from a tournament ID so all clients generate the same bots.
    private struct SeededRNG: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            // SplitMix64
            state &+= 0x9e3779b97f4a7c15
            var z = state
            z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
            z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
            return z ^ (z >> 31)
        }
    }

    private static func seed(from tournamentID: String) -> UInt64 {
        var hash: UInt64 = 14695981039346656037
        for byte in tournamentID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return hash
    }

    /// Generate 999 bot entries with diversified picks.
    static func generateBotEntries(
        tiers: [[SoccerTiersPlayer]],
        count: Int = 999,
        tournamentID: String? = nil
    ) -> [SoccerTiersEntry] {
        guard tiers.count == 6, tiers.allSatisfy({ !$0.isEmpty }) else {
            print("[SoccerTiers] Cannot generate bots: invalid tier data")
            return []
        }

        var rng: SeededRNG? = tournamentID.map { SeededRNG(seed: seed(from: $0)) }
        var entries: [SoccerTiersEntry] = []

        for i in 0..<count {
            let personality = BotPersonality.allCases[i % BotPersonality.allCases.count]
            let nameIndex = i % botNames.count
            let nameSuffix = i / botNames.count
            let botName = nameSuffix == 0 ? botNames[nameIndex] : "\(botNames[nameIndex])\(nameSuffix + 1)"

            if let picks = generateBotPicks(tiers: tiers, personality: personality, rng: &rng) {
                entries.append(SoccerTiersEntry(
                    id: UUID(),
                    tournamentID: "",
                    userID: nil,
                    entryName: botName,
                    picks: picks,
                    totalPoints: 0,
                    rank: 0,
                    isBot: true,
                    isCurrentUser: false
                ))
            }
        }

        print("[SoccerTiers] Generated \(entries.count) bot entries")
        return entries
    }

    private static func randomDouble(in range: Range<Double>, rng: inout SeededRNG?) -> Double {
        if var r = rng {
            let result = Double.random(in: range, using: &r)
            rng = r
            return result
        }
        return Double.random(in: range)
    }

    private static func randomDouble(in range: ClosedRange<Double>, rng: inout SeededRNG?) -> Double {
        if var r = rng {
            let result = Double.random(in: range, using: &r)
            rng = r
            return result
        }
        return Double.random(in: range)
    }

    /// Generate 6 picks (one per tier) for a bot with the given personality
    private static func generateBotPicks(
        tiers: [[SoccerTiersPlayer]],
        personality: BotPersonality,
        rng: inout SeededRNG?
    ) -> [SoccerTiersPick]? {
        var picks: [SoccerTiersPick] = []
        var nationCounts: [String: Int] = [:]  // max 2 players from same nation

        for tierIndex in 0..<6 {
            let tierPlayers = tiers[tierIndex]
            guard !tierPlayers.isEmpty else { return nil }

            let noiseRange = personality.noiseMultiplier
            var candidates: [(player: SoccerTiersPlayer, weight: Double)] = []

            for player in tierPlayers {
                // Nation constraint: max 2 from same country
                if (nationCounts[player.countryCode] ?? 0) >= 2 { continue }

                let noise = randomDouble(in: (1.0 - noiseRange)...(1.0 + noiseRange), rng: &rng)
                var weight = max(player.projectedPoints * noise, 0.1)

                switch personality {
                case .starsFocused:
                    if player.projectedPoints >= tierPlayers.first!.projectedPoints * 0.85 {
                        weight *= 1.5
                    }
                case .nationDiversifier:
                    let existing = nationCounts[player.countryCode] ?? 0
                    if existing > 0 { weight *= 0.3 }
                case .upsideChaser:
                    break
                case .depthSeeker:
                    // Boost players from strong nations (higher fifaRankWeight → higher projectedPoints for given marketValue)
                    if player.projectedPoints > 60 { weight *= 1.3 }
                case .balanced:
                    break
                }

                candidates.append((player, weight))
            }

            guard !candidates.isEmpty else { return nil }

            let totalWeight = candidates.reduce(0) { $0 + $1.weight }
            var roll = randomDouble(in: 0..<totalWeight, rng: &rng)
            var selected = candidates.last!.player

            for candidate in candidates {
                roll -= candidate.weight
                if roll <= 0 {
                    selected = candidate.player
                    break
                }
            }

            picks.append(SoccerTiersPick(
                tier: tierIndex + 1,
                playerID: selected.id,
                playerName: selected.name,
                playerCountry: selected.countryCode
            ))
            nationCounts[selected.countryCode, default: 0] += 1
        }

        return picks.count == 6 ? picks : nil
    }
}

// MARK: - Date Parsing

enum SoccerTiersDateParsers {
    static let noSecondsUTC: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mmZ"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static let withSecondsUTC: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static let withFractionalSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let iso8601Basic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseDate(_ string: String) -> Date? {
        withFractionalSeconds.date(from: string)
            ?? iso8601Basic.date(from: string)
            ?? withSecondsUTC.date(from: string)
            ?? noSecondsUTC.date(from: string)
    }
}
