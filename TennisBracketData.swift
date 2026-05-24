import Foundation

// MARK: - Enums

enum GrandSlam: String, Codable, CaseIterable, Identifiable {
    case australianOpen = "australian_open"
    case frenchOpen = "french_open"
    case wimbledon = "wimbledon"
    case usOpen = "us_open"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .australianOpen: return "Australian Open"
        case .frenchOpen: return "French Open"
        case .wimbledon: return "Wimbledon"
        case .usOpen: return "US Open"
        }
    }

    var shortName: String {
        switch self {
        case .australianOpen: return "AO"
        case .frenchOpen: return "RG"
        case .wimbledon: return "WIM"
        case .usOpen: return "USO"
        }
    }

    var hostCountry: String {
        switch self {
        case .australianOpen: return "AUS"
        case .frenchOpen: return "FRA"
        case .wimbledon: return "GBR"
        case .usOpen: return "USA"
        }
    }

    var surface: String {
        switch self {
        case .australianOpen: return "Hard"
        case .frenchOpen: return "Clay"
        case .wimbledon: return "Grass"
        case .usOpen: return "Hard"
        }
    }

    /// Approximate start month/day for the Grand Slam (used for display purposes).
    var approximateDateRange: String {
        switch self {
        case .australianOpen: return "January"
        case .frenchOpen: return "Late May – Early June"
        case .wimbledon: return "Late June – Early July"
        case .usOpen: return "Late August – Early September"
        }
    }
}

enum DrawType: String, Codable, CaseIterable, Identifiable {
    case atp, wta

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .atp: return "ATP (Men's)"
        case .wta: return "WTA (Women's)"
        }
    }

    var shortName: String {
        switch self {
        case .atp: return "ATP"
        case .wta: return "WTA"
        }
    }

    var espnLeague: String {
        switch self {
        case .atp: return "atp"
        case .wta: return "wta"
        }
    }
}

// MARK: - Core Models

struct TennisBracketTournament: Equatable {
    let id: String                          // "french_open-atp-2026"
    let title: String
    let grandSlam: GrandSlam
    let drawType: DrawType
    let season: String
    let status: String                      // open, locked, live, settled
    let lockTime: Date?
    let entryCount: Int
    let isSettled: Bool
    let createdAt: Date
}

struct TennisBracketPlayer: Identifiable, Hashable, Codable {
    let seed: Int?                          // 1-32 for seeded, nil for unseeded
    let drawPosition: Int                   // 1-128 position in draw
    let name: String
    let country: String
    let rank: Int                           // ATP/WTA ranking

    var id: String { "\(drawPosition)" }

    func hash(into hasher: inout Hasher) { hasher.combine(drawPosition) }
    static func == (lhs: TennisBracketPlayer, rhs: TennisBracketPlayer) -> Bool {
        lhs.drawPosition == rhs.drawPosition
    }

    enum CodingKeys: String, CodingKey {
        case seed, drawPosition = "draw_position", name, country, rank
    }
}

struct TennisBracketEntry: Identifiable, Equatable {
    let id: UUID
    let tournamentID: String
    let userID: String?
    let entryName: String
    let picks: [String: String]             // "R1-1" → "Sinner", 127 total
    var totalPoints: Double
    var rank: Int
    let isBot: Bool
    let isCurrentUser: Bool

    static func == (lhs: TennisBracketEntry, rhs: TennisBracketEntry) -> Bool {
        lhs.id == rhs.id && lhs.totalPoints == rhs.totalPoints && lhs.rank == rhs.rank
    }
}

struct TennisBracketLeaderboardEntry: Identifiable {
    let id: UUID
    let entryName: String
    let picks: [String: String]
    let totalPoints: Double
    let rank: Int
    let isCurrentUser: Bool
    let roundBreakdown: [String: Int]       // "R1" → points from R1
}

// MARK: - Private Groups

struct TennisBracketGroup: Identifiable, Equatable {
    let id: UUID
    let tournamentID: String
    let name: String
    let createdBy: String
    let inviteCode: String
    let maxMembers: Int
    let createdAt: Date
}

struct TennisBracketGroupMember: Identifiable, Equatable {
    let id: UUID
    let groupID: UUID
    let userID: String
    let displayName: String
    let joinedAt: Date
}

// MARK: - Bracket Engine

struct TennisBracketEngine {

    static let rounds = ["R1", "R2", "R3", "R4", "QF", "SF", "F"]
    static let matchesPerRound = [64, 32, 16, 8, 4, 2, 1]
    static let pointsPerRound = [1, 2, 4, 8, 16, 32, 64]
    static let totalPicks = 127

    /// Generate Round 1 matchups from the 128-player draw.
    /// Positions are paired sequentially: 1v2, 3v4, 5v6, ... 127v128.
    static func generateR1Matchups(from draw: [TennisBracketPlayer]) -> [(TennisBracketPlayer, TennisBracketPlayer)] {
        guard draw.count == 128 else { return [] }
        let sorted = draw.sorted { $0.drawPosition < $1.drawPosition }
        var matchups: [(TennisBracketPlayer, TennisBracketPlayer)] = []
        for i in stride(from: 0, to: 128, by: 2) {
            matchups.append((sorted[i], sorted[i + 1]))
        }
        return matchups
    }

    /// Build the match slot key for a given round and 1-based match number.
    static func matchSlot(round: String, matchNumber: Int) -> String {
        "\(round)-\(matchNumber)"
    }

    /// Which slot does the winner of `slot` advance to?
    /// R1-1 → R2-1, R1-2 → R2-1, R1-3 → R2-2, R1-4 → R2-2, ...
    static func advancementSlot(from slot: String) -> String? {
        let parts = slot.split(separator: "-")
        guard parts.count == 2,
              let roundStr = parts.first,
              let matchNum = Int(parts.last ?? "") else { return nil }

        guard let roundIndex = rounds.firstIndex(of: String(roundStr)),
              roundIndex + 1 < rounds.count else { return nil }

        let nextRound = rounds[roundIndex + 1]
        let nextMatch = (matchNum + 1) / 2
        return matchSlot(round: nextRound, matchNumber: nextMatch)
    }

    /// The two source slots that feed into a given slot.
    /// R2-1 is fed by R1-1 and R1-2.
    static func sourceSlots(for slot: String) -> (String, String)? {
        let parts = slot.split(separator: "-")
        guard parts.count == 2,
              let roundStr = parts.first,
              let matchNum = Int(parts.last ?? "") else { return nil }

        guard let roundIndex = rounds.firstIndex(of: String(roundStr)),
              roundIndex > 0 else { return nil }

        let prevRound = rounds[roundIndex - 1]
        let firstSource = matchSlot(round: prevRound, matchNumber: matchNum * 2 - 1)
        let secondSource = matchSlot(round: prevRound, matchNumber: matchNum * 2)
        return (firstSource, secondSource)
    }

    /// Score a bracket by comparing picks to results.
    static func scoreBracket(picks: [String: String], results: [String: String]) -> (total: Double, breakdown: [String: Int]) {
        var total = 0.0
        var breakdown: [String: Int] = [:]

        for (roundIndex, round) in rounds.enumerated() {
            let matchCount = matchesPerRound[roundIndex]
            let ptsPerCorrect = pointsPerRound[roundIndex]
            var roundPoints = 0

            for matchNum in 1...matchCount {
                let slot = matchSlot(round: round, matchNumber: matchNum)
                if let picked = picks[slot],
                   let actual = results[slot],
                   normalizedName(picked) == normalizedName(actual) {
                    roundPoints += ptsPerCorrect
                }
            }

            total += Double(roundPoints)
            breakdown[round] = roundPoints
        }

        return (total, breakdown)
    }

    /// Compute leaderboard from entries + results.
    static func computeLeaderboard(
        entries: [TennisBracketEntry],
        results: [String: String],
        currentUserID: String?
    ) -> [TennisBracketLeaderboardEntry] {
        var scored: [(entry: TennisBracketEntry, total: Double, breakdown: [String: Int])] = []

        for entry in entries {
            let (total, breakdown) = scoreBracket(picks: entry.picks, results: results)
            scored.append((entry, total, breakdown))
        }

        scored.sort { $0.total > $1.total }

        return scored.enumerated().map { index, item in
            TennisBracketLeaderboardEntry(
                id: item.entry.id,
                entryName: item.entry.entryName,
                picks: item.entry.picks,
                totalPoints: item.total,
                rank: index + 1,
                isCurrentUser: item.entry.userID == currentUserID,
                roundBreakdown: item.breakdown
            )
        }
    }

    /// RR delta calculation (same tiers as DFS).
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

    /// Validate that picks cascade correctly: every later-round pick
    /// must also appear as the pick in a preceding round that feeds it.
    static func validatePickCascade(picks: [String: String]) -> Bool {
        for (roundIndex, round) in rounds.enumerated() where roundIndex > 0 {
            let matchCount = matchesPerRound[roundIndex]
            for matchNum in 1...matchCount {
                let slot = matchSlot(round: round, matchNumber: matchNum)
                guard let picked = picks[slot] else { continue }
                // This player must have been picked as the winner in one of the two source slots
                guard let (src1, src2) = sourceSlots(for: slot) else { return false }
                let srcPick1 = picks[src1]
                let srcPick2 = picks[src2]
                if normalizedName(srcPick1 ?? "") != normalizedName(picked) &&
                   normalizedName(srcPick2 ?? "") != normalizedName(picked) {
                    return false
                }
            }
        }
        return true
    }

    /// Normalize player name for comparison (lowercase, strip diacritics).
    static func normalizedName(_ name: String) -> String {
        name.lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Clear all downstream picks that depended on a specific player
    /// being picked at a given slot. Called when user changes a pick.
    static func clearDownstreamPicks(from slot: String, playerName: String, picks: inout [String: String]) {
        guard let nextSlot = advancementSlot(from: slot) else { return }
        if let current = picks[nextSlot], normalizedName(current) == normalizedName(playerName) {
            picks.removeValue(forKey: nextSlot)
            // Recurse to clear further downstream
            clearDownstreamPicks(from: nextSlot, playerName: playerName, picks: &picks)
        }
    }
}

// MARK: - ESPN Tennis Results Provider

struct ESPNTennisResultsProvider: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    /// Fetch completed match results from ESPN tennis scoreboard.
    /// Maps each completed match to a draw slot using player names.
    func fetchMatchResults(
        drawType: DrawType,
        drawPlayers: [TennisBracketPlayer]
    ) async -> [String: String] {
        var results: [String: String] = [:]

        let league = drawType.espnLeague
        // Fetch last 14 days of scoreboard data to cover the whole slam
        let calendar = Calendar.current
        let today = Date()

        for dayOffset in 0..<16 {
            guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: today) else { continue }
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd"
            let dateKey = fmt.string(from: date)

            guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/tennis/\(league)/scoreboard?dates=\(dateKey)") else { continue }

            do {
                let (data, _) = try await session.data(from: url)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let events = json["events"] as? [[String: Any]] else { continue }

                for event in events {
                    guard let competitions = event["competitions"] as? [[String: Any]],
                          let comp = competitions.first,
                          let competitors = comp["competitors"] as? [[String: Any]],
                          competitors.count == 2 else { continue }

                    // Check state is post (completed)
                    guard let status = comp["status"] as? [String: Any],
                          let statusType = status["type"] as? [String: Any],
                          let state = statusType["state"] as? String,
                          state == "post" else { continue }

                    // Skip doubles
                    let names = competitors.compactMap { $0["athlete"] as? [String: Any] }.compactMap { $0["displayName"] as? String }
                    guard names.count == 2, !names.contains(where: { $0.contains(" / ") }) else { continue }

                    // Find winner
                    guard let winner = competitors.first(where: { ($0["winner"] as? Bool) == true }),
                          let winnerAthlete = winner["athlete"] as? [String: Any],
                          let winnerName = winnerAthlete["displayName"] as? String else { continue }

                    let loser = competitors.first(where: { ($0["winner"] as? Bool) != true })
                    let loserAthlete = loser?["athlete"] as? [String: Any]
                    let loserName = loserAthlete?["displayName"] as? String ?? ""

                    // Match to draw positions
                    let winnerPos = findDrawPosition(name: winnerName, in: drawPlayers)
                    let loserPos = findDrawPosition(name: loserName, in: drawPlayers)

                    guard let wPos = winnerPos, let lPos = loserPos else { continue }

                    // Determine the slot
                    if let slot = determineSlot(winnerPos: wPos, loserPos: lPos) {
                        results[slot] = drawPlayers.first(where: { $0.drawPosition == wPos })?.name ?? winnerName
                    }
                }
            } catch {
                continue
            }
        }

        return results
    }

    /// Find draw position by fuzzy name match.
    private func findDrawPosition(name: String, in draw: [TennisBracketPlayer]) -> Int? {
        let normalized = TennisBracketEngine.normalizedName(name)

        // Exact match first
        if let player = draw.first(where: { TennisBracketEngine.normalizedName($0.name) == normalized }) {
            return player.drawPosition
        }

        // Last name match
        let lastName = normalized.split(separator: " ").last.map(String.init) ?? normalized
        let matches = draw.filter { player in
            let playerLastName = TennisBracketEngine.normalizedName(player.name).split(separator: " ").last.map(String.init) ?? ""
            return playerLastName == lastName
        }
        if matches.count == 1 {
            return matches[0].drawPosition
        }

        return nil
    }

    /// Given two draw positions of match participants, determine the bracket slot.
    /// R1: positions 1,2 → R1-1; positions 3,4 → R1-2; etc.
    /// R2: winner of R1-1 vs winner of R1-2 → R2-1; etc.
    private func determineSlot(winnerPos: Int, loserPos: Int) -> String? {
        // Find which R1 match each position belongs to
        let r1Match1 = (winnerPos - 1) / 2 + 1  // 1-based R1 match number
        let r1Match2 = (loserPos - 1) / 2 + 1

        if r1Match1 == r1Match2 {
            // Both in the same R1 match
            return TennisBracketEngine.matchSlot(round: "R1", matchNumber: r1Match1)
        }

        // They met in a later round. Walk up the bracket.
        for (roundIndex, round) in TennisBracketEngine.rounds.enumerated() where roundIndex > 0 {
            let matchCount = TennisBracketEngine.matchesPerRound[roundIndex]
            let divisor = Int(pow(2.0, Double(roundIndex + 1)))

            let m1 = (winnerPos - 1) / divisor + 1
            let m2 = (loserPos - 1) / divisor + 1

            if m1 == m2 && m1 >= 1 && m1 <= matchCount {
                return TennisBracketEngine.matchSlot(round: round, matchNumber: m1)
            }
        }

        return nil
    }
}

// MARK: - Hardcoded Draw Data

/// Pre-loaded draw data for Grand Slams. ESPN bracket pages are client-rendered
/// and unreliable for HTML scraping, so we hardcode draws when available.
struct TennisBracketDrawData {

    /// Returns the hardcoded draw for a given Grand Slam, draw type, and year if available.
    static func hardcodedDraw(grandSlam: GrandSlam, drawType: DrawType, year: Int) -> [TennisBracketPlayer]? {
        switch (grandSlam, drawType, year) {
        case (.frenchOpen, .atp, 2026): return frenchOpen2026ATP()
        case (.frenchOpen, .wta, 2026): return frenchOpen2026WTA()
        default: return nil
        }
    }

    // MARK: - 2026 Roland Garros ATP Men's Singles

    private static func frenchOpen2026ATP() -> [TennisBracketPlayer] {
        // Draw positions 1-128, paired as matchups: 1v2, 3v4, 5v6, ... 127v128
        let drawEntries: [(name: String, seed: Int?, country: String, rank: Int)] = [
            // Match 1: [1] Sinner vs Tabur
            ("Jannik Sinner", 1, "ITA", 1),
            ("Constant Tabur", nil, "FRA", 95),
            // Match 2: Fearnley vs J.M. Cerundolo
            ("Jack Fearnley", nil, "GBR", 58),
            ("Juan Manuel Cerundolo", nil, "ARG", 75),
            // Match 3: Landaluce vs Prado Angelo
            ("Martin Landaluce", nil, "ESP", 80),
            ("Juan Pablo Prado Angelo", nil, "BOL", 130),
            // Match 4: Kopriva vs [30] Moutet
            ("Vit Kopriva", nil, "CZE", 110),
            ("Corentin Moutet", 30, "FRA", 30),
            // Match 5: [22] Rinderknech vs Rodionov
            ("Arthur Rinderknech", 22, "FRA", 22),
            ("Jurij Rodionov", nil, "AUT", 88),
            // Match 6: Fucsovics vs Berrettini
            ("Marton Fucsovics", nil, "HUN", 78),
            ("Matteo Berrettini", nil, "ITA", 42),
            // Match 7: Quinn vs Comesana
            ("Ethan Quinn", nil, "USA", 90),
            ("Federico Comesana", nil, "ARG", 72),
            // Match 8: Ofner vs [14] Darderi
            ("Sebastian Ofner", nil, "AUT", 62),
            ("Luciano Darderi", 14, "ITA", 14),
            // Match 9: [9] Bublik vs Struff
            ("Alexander Bublik", 9, "KAZ", 9),
            ("Jan-Lennard Struff", nil, "GER", 55),
            // Match 10: Faria vs Shapovalov
            ("Joao Faria", nil, "POR", 105),
            ("Denis Shapovalov", nil, "CAN", 65),
            // Match 11: Munar vs Hurkacz
            ("Jaume Munar", nil, "ESP", 68),
            ("Hubert Hurkacz", nil, "POL", 38),
            // Match 12: Spizzirri vs [19] Tiafoe
            ("Ethan Spizzirri", nil, "USA", 115),
            ("Frances Tiafoe", 19, "USA", 19),
            // Match 13: [29] Griekspoor vs Arnaldi
            ("Tallon Griekspoor", 29, "NED", 29),
            ("Matteo Arnaldi", nil, "ITA", 36),
            // Match 14: Muller vs Tsitsipas
            ("Alexandre Muller", nil, "FRA", 53),
            ("Stefanos Tsitsipas", nil, "GRE", 40),
            // Match 15: Collignon vs Vukic
            ("Romain Collignon", nil, "BEL", 120),
            ("Aleksandar Vukic", nil, "AUS", 60),
            // Match 16: Merida vs [5] Shelton
            ("Daniel Merida", nil, "ESP", 125),
            ("Ben Shelton", 5, "USA", 5),
            // Match 17: [4] Auger-Aliassime vs Altmaier
            ("Felix Auger-Aliassime", 4, "CAN", 4),
            ("Daniel Altmaier", nil, "GER", 82),
            // Match 18: Baez vs Burruchaga
            ("Sebastian Baez", nil, "ARG", 44),
            ("Roman Burruchaga", nil, "ARG", 100),
            // Match 19: Van Assche vs Kypson
            ("Luca Van Assche", nil, "FRA", 85),
            ("Peter Kypson", nil, "USA", 128),
            // Match 20: Bautista Agut vs [31] Nakashima
            ("Roberto Bautista Agut", nil, "ESP", 50),
            ("Brandon Nakashima", 31, "USA", 31),
            // Match 21: [20] Norrie vs Vallejo
            ("Cameron Norrie", 20, "GBR", 20),
            ("Andres Vallejo", nil, "PAR", 118),
            // Match 22: Cilic vs Kouame
            ("Marin Cilic", nil, "CRO", 92),
            ("Mathieu Kouame", nil, "FRA", 135),
            // Match 23: Tabilo vs Majchrzak
            ("Alejandro Tabilo", nil, "CHI", 48),
            ("Kamil Majchrzak", nil, "POL", 108),
            // Match 24: Faurel vs [16] Vacherot
            ("Theo Faurel", nil, "FRA", 112),
            ("Valentin Vacherot", 16, "MON", 16),
            // Match 25: [10] Cobolli vs Pellegrino
            ("Flavio Cobolli", 10, "ITA", 10),
            ("Andrea Pellegrino", nil, "ITA", 70),
            // Match 26: Wu vs Giron
            ("Yibing Wu", nil, "CHN", 98),
            ("Marcos Giron", nil, "USA", 64),
            // Match 27: Diaz Acosta vs Zhang
            ("Facundo Diaz Acosta", nil, "ARG", 56),
            ("Zhizhen Zhang", nil, "CHN", 46),
            // Match 28: Garin vs [18] Tien
            ("Cristian Garin", nil, "CHI", 76),
            ("Learner Tien", 18, "USA", 18),
            // Match 29: [25] F. Cerundolo vs Van De Zandschulp
            ("Francisco Cerundolo", 25, "ARG", 25),
            ("Botic Van De Zandschulp", nil, "NED", 52),
            // Match 30: Gaston vs Monfils
            ("Hugo Gaston", nil, "FRA", 88),
            ("Gael Monfils", nil, "FRA", 35),
            // Match 31: Popyrin vs Svajda
            ("Alexei Popyrin", nil, "AUS", 34),
            ("Zachary Svajda", nil, "USA", 122),
            // Match 32: Walton vs [6] Medvedev
            ("Adam Walton", nil, "AUS", 102),
            ("Daniil Medvedev", 6, "RUS", 6),
            // Match 33: [8] de Minaur vs Samuel
            ("Alex de Minaur", 8, "AUS", 8),
            ("Tommy Samuel", nil, "GBR", 132),
            // Match 34: Blockx vs Wong
            ("Alexander Blockx", nil, "BEL", 96),
            ("Coleman Wong", nil, "HKG", 116),
            // Match 35: Navone vs Brooksby
            ("Mariano Navone", nil, "ARG", 47),
            ("Jenson Brooksby", nil, "USA", 84),
            // Match 36: Droguet vs [26] Mensik
            ("Terence Droguet", nil, "FRA", 106),
            ("Jakub Mensik", 26, "CZE", 26),
            // Match 37: [23] Etcheverry vs Borges
            ("Tomas Martin Etcheverry", 23, "ARG", 23),
            ("Nuno Borges", nil, "POR", 33),
            // Match 38: Kecmanovic vs Marozsan
            ("Miomir Kecmanovic", nil, "SRB", 54),
            ("Fabian Marozsan", nil, "HUN", 66),
            // Match 39: Nava vs Ugo Carabelli
            ("Emilio Nava", nil, "USA", 74),
            ("Camilo Ugo Carabelli", nil, "ARG", 86),
            // Match 40: Buse vs [11] Rublev
            ("Ignacio Buse", nil, "PER", 138),
            ("Andrey Rublev", 11, "RUS", 11),
            // Match 41: [15] Ruud vs Safiullin
            ("Casper Ruud", 15, "NOR", 15),
            ("Roman Safiullin", nil, "RUS", 78),
            // Match 42: Medjedovic vs Hanfmann
            ("Hamad Medjedovic", nil, "SRB", 57),
            ("Yannick Hanfmann", nil, "GER", 94),
            // Match 43: Sonego vs Herbert
            ("Lorenzo Sonego", nil, "ITA", 49),
            ("Pierre-Hugues Herbert", nil, "FRA", 140),
            // Match 44: Hijikata vs [24] Paul
            ("Rinky Hijikata", nil, "AUS", 60),
            ("Tommy Paul", 24, "USA", 24),
            // Match 45: [28] Fonseca vs Pavlovic
            ("Joao Fonseca", 28, "BRA", 28),
            ("Luka Pavlovic", nil, "FRA", 104),
            // Match 46: Zheng vs Prizmic
            ("Mackenzie Zheng", nil, "USA", 98),
            ("Dino Prizmic", nil, "CRO", 114),
            // Match 47: Dellien vs Royer
            ("Hugo Dellien", nil, "BOL", 88),
            ("Victor Royer", nil, "FRA", 130),
            // Match 48: Mpetshi Perricard vs [3] Djokovic
            ("Giovanni Mpetshi Perricard", nil, "FRA", 32),
            ("Novak Djokovic", 3, "SRB", 3),
            // Match 49: [7] Fritz vs Basavareddy
            ("Taylor Fritz", 7, "USA", 7),
            ("Nishesh Basavareddy", nil, "USA", 108),
            // Match 50: Shevchenko vs Michelsen
            ("Alexander Shevchenko", nil, "KAZ", 58),
            ("Alex Michelsen", nil, "USA", 39),
            // Match 51: Duckworth vs Diallo
            ("James Duckworth", nil, "AUS", 90),
            ("Gabriel Diallo", nil, "CAN", 72),
            // Match 52: Kovacevic vs [27] Jodar
            ("Aleksandar Kovacevic", nil, "USA", 82),
            ("Roberto Jodar", 27, "ESP", 27),
            // Match 53: [21] Davidovich Fokina vs Dzumhur
            ("Alejandro Davidovich Fokina", 21, "ESP", 21),
            ("Damir Dzumhur", nil, "BIH", 120),
            // Match 54: Llamas Ruiz vs Tirante
            ("Pablo Llamas Ruiz", nil, "ESP", 96),
            ("Thiago Tirante", nil, "ARG", 64),
            // Match 55: Kokkinakis vs Atmane
            ("Thanasi Kokkinakis", nil, "AUS", 70),
            ("Terence Atmane", nil, "FRA", 100),
            // Match 56: Carreno Busta vs [12] Lehecka
            ("Pablo Carreno Busta", nil, "ESP", 50),
            ("Jiri Lehecka", 12, "CZE", 12),
            // Match 57: [13] Khachanov vs Gea
            ("Karen Khachanov", 13, "RUS", 13),
            ("Alexis Gea", nil, "FRA", 134),
            // Match 58: Jacquet vs Trungelliti
            ("Kyrian Jacquet", nil, "FRA", 110),
            ("Marco Trungelliti", nil, "ARG", 92),
            // Match 59: Cina vs Opelka
            ("Francesco Cina", nil, "ITA", 126),
            ("Reilly Opelka", nil, "USA", 42),
            // Match 60: Wawrinka vs [17] Fils
            ("Stan Wawrinka", nil, "SUI", 148),
            ("Arthur Fils", 17, "FRA", 17),
            // Match 61: [32] Humbert vs Mannarino
            ("Ugo Humbert", 32, "FRA", 32),
            ("Adrian Mannarino", nil, "FRA", 45),
            // Match 62: Halys vs Bellucci
            ("Quentin Halys", nil, "FRA", 78),
            ("Mattia Bellucci", nil, "ITA", 56),
            // Match 63: Machac vs Bergs
            ("Tomas Machac", nil, "CZE", 37),
            ("Zizou Bergs", nil, "BEL", 68),
            // Match 64: Bonzi vs [2] Zverev
            ("Benjamin Bonzi", nil, "FRA", 74),
            ("Alexander Zverev", 2, "GER", 2),
        ]

        return drawEntries.enumerated().map { index, entry in
            TennisBracketPlayer(
                seed: entry.seed,
                drawPosition: index + 1,
                name: entry.name,
                country: entry.country,
                rank: entry.rank
            )
        }
    }

    // MARK: - 2026 Roland Garros WTA Women's Singles

    private static func frenchOpen2026WTA() -> [TennisBracketPlayer] {
        // Draw positions 1-128, paired as matchups: 1v2, 3v4, 5v6, ... 127v128
        let drawEntries: [(name: String, seed: Int?, country: String, rank: Int)] = [
            // Match 1: [1] Sabalenka vs Bouzas Maneiro
            ("Aryna Sabalenka", 1, "BLR", 1),
            ("Jessica Bouzas Maneiro", nil, "ESP", 60),
            // Match 2: Fruhvirtova vs Jacquemot
            ("Linda Fruhvirtova", nil, "CZE", 55),
            ("Elsa Jacquemot", nil, "FRA", 85),
            // Match 3: Kasatkina vs Sonmez
            ("Daria Kasatkina", nil, "AUS", 52),
            ("Zeynep Sonmez", nil, "TUR", 95),
            // Match 4: Bandecchi vs [31] Bucsa
            ("Susan Bandecchi", nil, "SUI", 70),
            ("Cristina Bucsa", 31, "ESP", 31),
            // Match 5: [17] Jovic vs Eala
            ("Iva Jovic", 17, "USA", 17),
            ("Alexandra Eala", nil, "PHI", 38),
            // Match 6: Navarro vs Tjen
            ("Emma Navarro", nil, "USA", 39),
            ("Janice Tjen", nil, "INA", 41),
            // Match 7: Vekic vs Tubello
            ("Donna Vekic", nil, "CRO", 56),
            ("Alice Tubello", nil, "FRA", 110),
            // Match 8: Siegemund vs [16] Osaka
            ("Laura Siegemund", nil, "GER", 46),
            ("Naomi Osaka", 16, "JPN", 16),
            // Match 9: [9] Mboko vs Bartunkova
            ("Victoria Mboko", 9, "CAN", 9),
            ("Nikola Bartunkova", nil, "CZE", 75),
            // Match 10: Waltert vs Siniakova
            ("Simona Waltert", nil, "SUI", 80),
            ("Katerina Siniakova", nil, "CZE", 36),
            // Match 11: Ruzic vs Krueger
            ("Antonia Ruzic", nil, "CRO", 90),
            ("Ashlyn Krueger", nil, "USA", 65),
            // Match 12: Vandewinkel vs [19] Keys
            ("Hanne Vandewinkel", nil, "BEL", 100),
            ("Madison Keys", 19, "USA", 19),
            // Match 13: [25] Shnaider vs Zarazua
            ("Diana Shnaider", 25, "RUS", 25),
            ("Renata Zarazua", nil, "MEX", 88),
            // Match 14: Guo vs Kessler
            ("Haiyu Guo", nil, "CHN", 105),
            ("McCartney Kessler", nil, "USA", 47),
            // Match 15: Pridankina vs Oliynykova
            ("Ekaterina Pridankina", nil, "RUS", 115),
            ("Olesya Oliynykova", nil, "UKR", 120),
            // Match 16: Birrell vs [5] Pegula
            ("Kimberly Birrell", nil, "AUS", 68),
            ("Jessica Pegula", 5, "USA", 5),
            // Match 17: [4] Gauff vs Townsend
            ("Coco Gauff", 4, "USA", 4),
            ("Taylor Townsend", nil, "USA", 62),
            // Match 18: Galfi vs Sherif
            ("Dalma Galfi", nil, "HUN", 72),
            ("Mayar Sherif", nil, "EGY", 78),
            // Match 19: Urhobo vs Boulter
            ("Alycia Urhobo", nil, "USA", 125),
            ("Katie Boulter", nil, "GBR", 58),
            // Match 20: Joint vs [28] Potapova
            ("Maya Joint", nil, "AUS", 34),
            ("Anastasia Potapova", 28, "AUT", 28),
            // Match 21: [22] Kalinskaya vs Boisson
            ("Anna Kalinskaya", 22, "RUS", 22),
            ("Lois Boisson", nil, "FRA", 50),
            // Match 22: Korneeva vs Cocciaretto
            ("Alina Korneeva", nil, "RUS", 64),
            ("Elisabetta Cocciaretto", nil, "ITA", 40),
            // Match 23: Gibson vs Putintseva
            ("Tina Gibson", nil, "AUS", 98),
            ("Yulia Putintseva", nil, "KAZ", 54),
            // Match 24: Osorio vs [14] Alexandrova
            ("Camila Osorio", nil, "COL", 82),
            ("Ekaterina Alexandrova", 14, "RUS", 14),
            // Match 25: [12] Noskova vs Sakkari
            ("Linda Noskova", 12, "CZE", 12),
            ("Maria Sakkari", nil, "GRE", 48),
            // Match 26: Liu vs Uchijima
            ("Claire Liu", nil, "USA", 74),
            ("Moyuka Uchijima", nil, "JPN", 66),
            // Match 27: Chwalinska vs Zheng
            ("Maja Chwalinska", nil, "POL", 116),
            ("Qinwen Zheng", nil, "CHN", 53),
            // Match 28: Maria vs [23] Mertens
            ("Tatjana Maria", nil, "GER", 92),
            ("Elise Mertens", 23, "BEL", 23),
            // Match 29: [30] Li vs Zhang
            ("Ann Li", 30, "USA", 30),
            ("Shuai Zhang", nil, "CHN", 108),
            // Match 30: Kalinina vs Parry
            ("Anhelina Kalinina", nil, "UKR", 76),
            ("Diane Parry", nil, "FRA", 63),
            // Match 31: Grabher vs Sramkova
            ("Julia Grabher", nil, "AUT", 84),
            ("Rebecca Sramkova", nil, "SVK", 57),
            // Match 32: Rakotomanga Rajaonah vs [6] Anisimova
            ("Tessah Rakotomanga Rajaonah", nil, "FRA", 130),
            ("Amanda Anisimova", 6, "USA", 6),
            // Match 33: [7] Svitolina vs Bondar
            ("Elina Svitolina", 7, "UKR", 7),
            ("Anna Bondar", nil, "HUN", 71),
            // Match 34: Quevedo vs Jeanjean
            ("Karen Quevedo", nil, "ESP", 112),
            ("Leolia Jeanjean", nil, "FRA", 86),
            // Match 35: Sorribes Tormo vs Korpatsch
            ("Sara Sorribes Tormo", nil, "ESP", 73),
            ("Tamara Korpatsch", nil, "GER", 77),
            // Match 36: Tagger vs [32] Wang Xinyu
            ("Lina Tagger", nil, "AUT", 102),
            ("Wang Xinyu", 32, "CHN", 32),
            // Match 37: [21] Tauson vs Snigur
            ("Clara Tauson", 21, "DEN", 21),
            ("Daria Snigur", nil, "UKR", 96),
            // Match 38: Kenin vs Stearns
            ("Sofia Kenin", nil, "USA", 69),
            ("Peyton Stearns", nil, "USA", 67),
            // Match 39: Tomljanovic vs McNally
            ("Ajla Tomljanovic", nil, "AUS", 79),
            ("Catherine McNally", nil, "USA", 83),
            // Match 40: Kraus vs [11] Bencic
            ("Sinja Kraus", nil, "AUT", 104),
            ("Belinda Bencic", 11, "SUI", 11),
            // Match 41: [15] Kostyuk vs Selekhmeteva
            ("Marta Kostyuk", 15, "UKR", 15),
            ("Oksana Selekhmeteva", nil, "RUS", 87),
            // Match 42: Volynets vs Burel
            ("Katie Volynets", nil, "USA", 61),
            ("Clara Burel", nil, "FRA", 59),
            // Match 43: Udvardy vs Golubic
            ("Panna Udvardy", nil, "HUN", 81),
            ("Viktorija Golubic", nil, "SUI", 93),
            // Match 44: Parks vs [24] Fernandez
            ("Alycia Parks", nil, "USA", 89),
            ("Leylah Fernandez", 24, "CAN", 24),
            // Match 45: [29] Ostapenko vs Seidel
            ("Jelena Ostapenko", 29, "LAT", 29),
            ("Ella Seidel", nil, "GER", 107),
            // Match 46: Valentova vs Linette
            ("Tereza Valentova", nil, "CZE", 43),
            ("Magda Linette", nil, "POL", 94),
            // Match 47: Bejlek vs Stephens
            ("Sara Bejlek", nil, "CZE", 35),
            ("Sloane Stephens", nil, "USA", 99),
            // Match 48: Jones vs [3] Swiatek
            ("Emerson Jones", nil, "AUS", 91),
            ("Iga Swiatek", 3, "POL", 3),
            // Match 49: [8] Andreeva vs Ferro
            ("Mirra Andreeva", 8, "RUS", 8),
            ("Fiona Ferro", nil, "FRA", 118),
            // Match 50: Bassols Ribera vs Arango
            ("Marina Bassols Ribera", nil, "ESP", 97),
            ("Emiliana Arango", nil, "COL", 103),
            // Match 51: F. Jones vs Haddad Maia
            ("Francesca Jones", nil, "GBR", 106),
            ("Beatriz Haddad Maia", nil, "BRA", 51),
            // Match 52: Bronzetti vs [27] Bouzkova
            ("Lucia Bronzetti", nil, "ITA", 74),
            ("Marie Bouzkova", 27, "CZE", 27),
            // Match 53: [20] Samsonova vs Teichmann
            ("Liudmila Samsonova", 20, "RUS", 20),
            ("Jil Teichmann", nil, "SUI", 101),
            // Match 54: Frech vs Ruse
            ("Magdalena Frech", nil, "POL", 49),
            ("Elena-Gabriela Ruse", nil, "ROU", 109),
            // Match 55: Rakhimova vs Cristian
            ("Kamilla Rakhimova", nil, "UZB", 111),
            ("Jaqueline Cristian", nil, "ROU", 33),
            // Match 56: Zakharova vs [10] Muchova
            ("Anastasia Zakharova", nil, "RUS", 114),
            ("Karolina Muchova", 10, "CZE", 10),
            // Match 57: [13] Paolini vs Yastremska
            ("Jasmine Paolini", 13, "ITA", 13),
            ("Dayana Yastremska", nil, "UKR", 45),
            // Match 58: Raducanu vs Sierra
            ("Emma Raducanu", nil, "GBR", 37),
            ("Solana Sierra", nil, "ARG", 113),
            // Match 59: Marcinko vs Lys
            ("Petra Marcinko", nil, "CRO", 117),
            ("Eva Lys", nil, "GER", 70),
            // Match 60: Efremova vs [18] Cirstea
            ("Karina Efremova", nil, "FRA", 122),
            ("Sorana Cirstea", 18, "ROU", 18),
            // Match 61: [26] Baptiste vs Krejcikova
            ("Hailey Baptiste", 26, "USA", 26),
            ("Barbora Krejcikova", nil, "CZE", 42),
            // Match 62: Kovinic vs Wang Xiyu
            ("Danka Kovinic", nil, "MNE", 100),
            ("Wang Xiyu", nil, "CHN", 44),
            // Match 63: Blinkova vs Starodubtseva
            ("Anna Blinkova", nil, "RUS", 82),
            ("Yuliya Starodubtseva", nil, "UKR", 76),
            // Match 64: Erjavec vs [2] Rybakina
            ("Veronika Erjavec", nil, "SLO", 128),
            ("Elena Rybakina", 2, "KAZ", 2),
        ]

        return drawEntries.enumerated().map { index, entry in
            TennisBracketPlayer(
                seed: entry.seed,
                drawPosition: index + 1,
                name: entry.name,
                country: entry.country,
                rank: entry.rank
            )
        }
    }
}

// MARK: - ESPN Draw Fetcher

struct ESPNTennisDrawFetcher: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    /// Fetch the 128-player main draw from ESPN's bracket page HTML.
    /// Parses player names, seeds, countries, and draw positions from the rendered bracket.
    func fetchDraw(grandSlam: GrandSlam, drawType: DrawType) async -> [TennisBracketPlayer] {
        let bracketPath: String
        switch grandSlam {
        case .australianOpen: bracketPath = "australian-open"
        case .frenchOpen: bracketPath = "french-open"
        case .wimbledon: bracketPath = "wimbledon"
        case .usOpen: bracketPath = "us-open"
        }

        let urlString: String
        switch drawType {
        case .atp:
            urlString = "https://www.espn.com/tennis/\(bracketPath)/bracket"
        case .wta:
            urlString = "https://www.espn.com/tennis/\(bracketPath)/bracket/_/type/wta"
        }

        guard let url = URL(string: urlString) else { return [] }

        do {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await session.data(for: request)
            guard let html = String(data: data, encoding: .utf8) else { return [] }

            return parseDrawFromHTML(html: html)
        } catch {
            print("[TennisDraw] Error fetching bracket page: \(error)")
            return []
        }
    }

    /// Parse the ESPN bracket HTML to extract draw positions 1-128.
    /// ESPN renders first-round matchups in draw order. We extract player names,
    /// seeds, and country abbreviations from the bracket markup.
    private func parseDrawFromHTML(html: String) -> [TennisBracketPlayer] {
        var players: [TennisBracketPlayer] = []
        var seenNames = Set<String>()

        // ESPN bracket uses "Bracket__Match" containers with two competitors per match.
        // Each competitor has a name, seed badge, and country flag/abbrev.
        // We'll extract using regex patterns on the HTML.

        // Pattern 1: Extract competitor data blocks — look for player name + seed + country
        // ESPN uses patterns like: data-competitor-id, athlete display name, seed, flag

        // Strategy: Find all first-round matchup blocks, extract the two players from each.
        // ESPN renders R1 matchups first in the bracket, with 64 matches (128 competitors).

        // Look for competitor entries in the bracket HTML
        // ESPN format: class="Bracket__Competitor" with nested name and seed info

        // Try multiple extraction patterns
        let extracted = extractPlayersFromBracketHTML(html)
        if extracted.count >= 128 {
            return Array(extracted.prefix(128))
        }

        // Fallback: simpler regex-based extraction
        // ESPN bracket HTML typically has patterns like:
        // <span class="...truncate...">[seed] PlayerName</span>
        // and country info nearby

        // Extract all player name instances with optional seed prefix
        let namePattern = #"class=\"[^\"]*truncate[^\"]*\"[^>]*>(?:\s*<[^>]+>)*\s*(?:\[(\d+)\]\s*)?([A-Z][a-zÀ-ÿ\-']+(?:\s+[A-Za-zÀ-ÿ\-']+)+)"#
        if let regex = try? NSRegularExpression(pattern: namePattern, options: []) {
            let range = NSRange(html.startIndex..., in: html)
            let matches = regex.matches(in: html, options: [], range: range)

            for match in matches {
                var seed: Int? = nil
                if let seedRange = Range(match.range(at: 1), in: html) {
                    seed = Int(html[seedRange])
                }
                if let nameRange = Range(match.range(at: 2), in: html) {
                    let name = String(html[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let normalized = TennisBracketEngine.normalizedName(name)
                    if !seenNames.contains(normalized) {
                        seenNames.insert(normalized)
                        let position = players.count + 1
                        players.append(TennisBracketPlayer(
                            seed: seed,
                            drawPosition: position,
                            name: name,
                            country: "---",
                            rank: seed ?? (position + 32)
                        ))
                    }
                }
                if players.count >= 128 { break }
            }
        }

        if players.count >= 128 {
            return Array(players.prefix(128))
        }

        print("[TennisDraw] Extracted \(players.count) players from HTML (need 128)")
        return players
    }

    /// More structured extraction from ESPN bracket HTML.
    private func extractPlayersFromBracketHTML(_ html: String) -> [TennisBracketPlayer] {
        var players: [TennisBracketPlayer] = []
        var seenNames = Set<String>()

        // ESPN's bracket page embeds data in __espnfitt__ or window.__espnfitt__ JSON
        // Try to extract structured data first
        if let jsonStart = html.range(of: "\"competitors\":[{"),
           let jsonData = extractJSONArray(from: html, startingNear: jsonStart.lowerBound) {
            // Parse competitor objects
            for item in jsonData {
                guard let name = item["displayName"] as? String ?? item["name"] as? String else { continue }
                let normalized = TennisBracketEngine.normalizedName(name)
                guard !seenNames.contains(normalized) else { continue }
                seenNames.insert(normalized)

                let seed = item["seed"] as? Int ?? (item["seed"] as? String).flatMap { Int($0) }
                let country = item["country"] as? String ?? item["flag"] as? String ?? "---"
                let rank = item["rank"] as? Int ?? seed ?? (players.count + 33)

                players.append(TennisBracketPlayer(
                    seed: seed,
                    drawPosition: players.count + 1,
                    name: name,
                    country: country,
                    rank: rank
                ))

                if players.count >= 128 { break }
            }
        }

        return players
    }

    /// Try to extract a JSON array from HTML near a given position.
    private func extractJSONArray(from html: String, startingNear: String.Index) -> [[String: Any]]? {
        // Find the nearest '[' before or after the position
        let searchRange = html.index(startingNear, offsetBy: -100, limitedBy: html.startIndex) ?? html.startIndex
        let substring = html[searchRange...]
        guard let bracketStart = substring.firstIndex(of: "[") else { return nil }

        var depth = 0
        var bracketEnd: String.Index?
        var idx = bracketStart
        while idx < html.endIndex {
            let char = html[idx]
            if char == "[" { depth += 1 }
            if char == "]" { depth -= 1 }
            if depth == 0 { bracketEnd = idx; break }
            idx = html.index(after: idx)
        }

        guard let end = bracketEnd else { return nil }
        let jsonStr = String(html[bracketStart...end])
        guard let data = jsonStr.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return parsed
    }
}

// MARK: - Bot Bracket Generator

struct TennisBracketBotDrafter {

    enum BotPersonality: CaseIterable {
        case chalkPicker
        case upsetHunter
        case darkHorse
        case balanced
        case homeAdvantage

        var noiseMultiplier: Double {
            switch self {
            case .chalkPicker: return 0.10
            case .upsetHunter: return 0.40
            case .darkHorse: return 0.25
            case .balanced: return 0.20
            case .homeAdvantage: return 0.25
            }
        }
    }

    static let botNames = [
        "AceServe", "BreakPoint", "NetRusher", "BaselinePro", "GrandSlamFan",
        "TennisGuru", "VolleyKing", "DropShotPro", "MatchPoint", "SetPoint",
        "TieBreaker", "DoubleFault", "TopSpin", "SliceServe", "ClayKing",
        "GrassCourtPro", "HardCourtHero", "RallyMaster", "ServiceAce", "CourtCraft",
        "Forecaster", "BracketBoss", "SlamPicker", "DeuceDropper", "WildCard",
        "Qualifier", "SeedBuster", "ChampPick", "DrawMaster", "GameSetMatch",
        "LobShot", "PassingShot", "BackhandAce", "ForehandKing", "PointBuilder",
        "ReturnAce", "SmashHit", "BallBasher", "SpinDoctor", "CourtMaster",
        "NetWinner", "LinePainter", "AngleFinder", "PowerServe", "TennisBrain"
    ]

    /// Generate bot entries with varied bracket picks.
    static func generateBotEntries(
        draw: [TennisBracketPlayer],
        grandSlam: GrandSlam,
        count: Int = 999
    ) -> [TennisBracketEntry] {
        guard draw.count == 128 else { return [] }

        var entries: [TennisBracketEntry] = []
        let personalities = BotPersonality.allCases

        for i in 0..<count {
            let personality = personalities[i % personalities.count]
            let nameIndex = i / personalities.count
            let baseName = botNames[nameIndex % botNames.count]
            let botName = nameIndex < botNames.count ? baseName : "\(baseName)\(nameIndex / botNames.count)"

            guard let picks = generateBotPicks(draw: draw, personality: personality, grandSlam: grandSlam) else { continue }

            entries.append(TennisBracketEntry(
                id: UUID(),
                tournamentID: "",  // set by caller
                userID: nil,
                entryName: botName,
                picks: picks,
                totalPoints: 0,
                rank: 0,
                isBot: true,
                isCurrentUser: false
            ))
        }

        return entries
    }

    /// Generate a full 127-pick bracket for one bot.
    private static func generateBotPicks(
        draw: [TennisBracketPlayer],
        personality: BotPersonality,
        grandSlam: GrandSlam
    ) -> [String: String]? {
        guard draw.count == 128 else { return nil }

        let sorted = draw.sorted { $0.drawPosition < $1.drawPosition }
        var picks: [String: String] = [:]

        // R1: simulate each of 64 matches
        var r1Winners: [Int: TennisBracketPlayer] = [:]  // match number → winner
        for matchNum in 1...64 {
            let p1 = sorted[(matchNum - 1) * 2]
            let p2 = sorted[(matchNum - 1) * 2 + 1]
            let prob = winProbability(player1: p1, player2: p2, personality: personality, grandSlam: grandSlam)
            let winner = Double.random(in: 0...1) < prob ? p1 : p2
            let slot = TennisBracketEngine.matchSlot(round: "R1", matchNumber: matchNum)
            picks[slot] = winner.name
            r1Winners[matchNum] = winner
        }

        // Subsequent rounds
        var prevWinners = r1Winners
        for roundIndex in 1..<TennisBracketEngine.rounds.count {
            let round = TennisBracketEngine.rounds[roundIndex]
            let matchCount = TennisBracketEngine.matchesPerRound[roundIndex]
            var currentWinners: [Int: TennisBracketPlayer] = [:]

            for matchNum in 1...matchCount {
                let src1 = matchNum * 2 - 1
                let src2 = matchNum * 2
                guard let p1 = prevWinners[src1], let p2 = prevWinners[src2] else { continue }

                let prob = winProbability(player1: p1, player2: p2, personality: personality, grandSlam: grandSlam)
                let winner = Double.random(in: 0...1) < prob ? p1 : p2
                let slot = TennisBracketEngine.matchSlot(round: round, matchNumber: matchNum)
                picks[slot] = winner.name
                currentWinners[matchNum] = winner
            }

            prevWinners = currentWinners
        }

        return picks.count == TennisBracketEngine.totalPicks ? picks : nil
    }

    /// Probability that player1 wins, adjusted for personality.
    private static func winProbability(
        player1: TennisBracketPlayer,
        player2: TennisBracketPlayer,
        personality: BotPersonality,
        grandSlam: GrandSlam
    ) -> Double {
        let rank1 = max(1, Double(player1.rank))
        let rank2 = max(1, Double(player2.rank))
        let total = rank1 + rank2
        // Higher rank number = worse player, so rank2/total favors player1 when rank2 > rank1
        var prob = rank2 / total

        // Personality noise
        let noise = Double.random(in: -personality.noiseMultiplier...personality.noiseMultiplier)

        switch personality {
        case .upsetHunter:
            // Flatten probabilities toward 50/50
            prob = 0.5 + (prob - 0.5) * 0.5 + noise
        case .chalkPicker:
            // Strengthen favorite's advantage
            prob = 0.5 + (prob - 0.5) * 1.5 + noise
        case .homeAdvantage:
            prob += noise
            if player1.country == grandSlam.hostCountry { prob += 0.06 }
            if player2.country == grandSlam.hostCountry { prob -= 0.06 }
        default:
            prob += noise
        }

        return max(0.05, min(0.95, prob))
    }
}
