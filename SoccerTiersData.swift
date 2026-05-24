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

    /// Soccer fantasy scoring (FanDuel-style)
    static func soccerFantasyPoints(
        position: String,
        goals: Int, assists: Int, shotsOnTarget: Int, totalShots: Int,
        tackles: Int, saves: Int, yellowCards: Int, redCards: Int,
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

    /// Composite score: (marketValue × 0.6) + (fifaRankWeight × 0.4)
    /// Higher score = higher tier placement
    private static func composite(_ marketValue: Double, _ fifaRankWeight: Double) -> Double {
        marketValue * 0.6 + fifaRankWeight * 0.4
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
        add("Cole Palmer",          "England", "ENG", "FWD", 86, 94)
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

    /// Fetch accumulated fantasy points across ALL World Cup matches.
    func fetchWorldCupScores(playerIDs: Set<String>) async -> SoccerTiersScoreSnapshot {
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

        // TODO: Fetch per-match player stats from ESPN summaries and accumulate
        // This will be implemented closer to the tournament start.
        // Pattern follows SoccerDFSData.swift ESPNSoccerDFSLiveScoringProvider.

        return SoccerTiersScoreSnapshot(
            playerFantasyPoints: [:], playerMatchesPlayed: [:],
            eliminatedNations: [], isTournamentComplete: false
        )
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
        let completedCount = events.filter { event in
            guard let competitions = event["competitions"] as? [[String: Any]],
                  let competition = competitions.first,
                  let status = competition["status"] as? [String: Any],
                  let statusType = status["type"] as? [String: Any],
                  let completed = statusType["completed"] as? Bool else { return false }
            return completed
        }.count
        // World Cup 2026: 48 teams, 104 total matches
        // If we have 100+ completed matches, tournament is likely done
        return completedCount >= 100
    }

    /// Detect which nations have been eliminated
    func fetchEliminatedNations() async -> Set<String> {
        // TODO: Parse knockout results from ESPN to determine eliminated teams
        // Will be implemented when the tournament reaches knockout stage
        return []
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
