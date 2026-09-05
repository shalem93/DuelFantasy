import Foundation

// MARK: - NFL Best Ball Tournament
//
// Season-long, salary-cap best ball. Every entrant builds a 15-player
// roster under a $200 budget where each player is priced at his average
// auction value, then each week the optimal lineup (QB/RB/RB/WR/WR/WR/TE/
// FLEX) scores automatically and season totals rank the field. One
// global tournament per season, 2,000 bots, up to 10 entries per user.
//
// Tournament id: "bbt-nfl-<season>". The "bbt-" prefix deliberately
// avoids every DFS sport prefix so the DFS history sync never mistakes a
// tournament row for a slate contest.

nonisolated enum BBTConfig {
    static let season = 2026
    static let tournamentID = "bbt-nfl-\(season)"
    static let title = "NFL Best Ball Tournament"
    static let rosterSize = 15
    static let budget = 200
    static let botCount = 2000
    static let maxEntriesPerUser = 10
    static let entryFeeRR = 10
    static let totalWeeks = 18
    /// Entries lock at the Week 1 opener's kickoff (ET) — 2026: NE @ SEA,
    /// Wednesday Sep 9, 8:20 PM ET (ESPN 2026-09-10T00:20Z). Rosters are
    /// editable and bots are not loaded until then.
    static var lockTime: Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal.date(from: DateComponents(year: season, month: 9, day: 9, hour: 20, minute: 20)) ?? .distantFuture
    }
    /// Positional floors/ceilings for a legal 15-man roster.
    static let minByPosition: [String: Int] = ["QB": 1, "RB": 2, "WR": 3, "TE": 1]
    static let maxByPosition: [String: Int] = ["QB": 3, "RB": 7, "WR": 8, "TE": 3]
    static let positions = ["QB", "RB", "WR", "TE"]
    /// Weekly best-ball lineup: QB, RB, RB, WR, WR, WR, TE, FLEX.
    static var lineupConstraints: [BestBallPositionRequirement] {
        BestBallLineupConfig.requirements(for: "NFL", nflQB: 1, nflRB: 2, nflWR: 3, nflTE: 1, nflFLEX: 1, nflSFLEX: 0).constraints
    }
}

// MARK: - Models

struct BBTPlayer: Identifiable, Hashable, Codable {
    let id: String          // "nfl-<espnID>"
    let name: String
    let team: String
    let position: String
    let price: Int          // auction dollars
    let adp: Double?        // consensus draft position (PPR)
    let projectedPoints: Double
}

struct BBTPick: Codable, Hashable {
    let playerID: String
    let name: String
    let team: String
    let position: String
    let price: Int
}

struct BBTEntry: Identifiable, Hashable {
    let id: String
    let userID: String?
    let entryName: String
    let entryNumber: Int
    let picks: [BBTPick]
    let isBot: Bool
    let isCurrentUser: Bool
    var spent: Int { picks.reduce(0) { $0 + $1.price } }
}

struct BBTStanding: Identifiable {
    let entry: BBTEntry
    let totalPoints: Double
    let weeklyPoints: [Int: Double]
    let rank: Int
    var id: String { entry.id }
}

// MARK: - Pricing

nonisolated enum BBTPricing {
    /// Average $200/12-team auction values by consensus draft position —
    /// the standard curve auction calculators converge on. Interpolated
    /// linearly between anchors; anything past the last anchor is $1.
    private static let anchors: [(adp: Double, price: Double)] = [
        (1, 68), (3, 62), (6, 54), (12, 43), (18, 35), (24, 29), (36, 21),
        (48, 15), (60, 11), (72, 8), (96, 5), (120, 3), (150, 2), (180, 1)
    ]

    static func price(forADP adp: Double?) -> Int {
        guard let adp, adp > 0 else { return 1 }
        if adp <= anchors[0].adp { return Int(anchors[0].price) }
        for i in 1..<anchors.count {
            let (a0, p0) = anchors[i - 1]
            let (a1, p1) = anchors[i]
            if adp <= a1 {
                let t = (adp - a0) / (a1 - a0)
                return max(1, Int((p0 + (p1 - p0) * t).rounded()))
            }
        }
        return 1
    }

    /// The full priced pool from the Best Ball NFL player provider (ESPN
    /// rosters + FFC market ADP). Unranked deep-bench players cost $1.
    static func pricedPool(from players: [BestBallPlayer]) -> [BBTPlayer] {
        players
            .filter { BBTConfig.positions.contains($0.position) }
            .map { p in
                BBTPlayer(
                    id: p.id, name: p.name, team: p.team, position: p.position,
                    price: price(forADP: p.adpPPR), adp: p.adpPPR,
                    projectedPoints: p.projectedPoints
                )
            }
            .sorted { a, b in
                if a.price != b.price { return a.price > b.price }
                return (a.adp ?? 999) < (b.adp ?? 999)
            }
    }
}

// MARK: - Roster Rules

nonisolated enum BBTRosterRules {
    /// nil = legal; otherwise the first violation, phrased for the UI.
    static func violation(for picks: [BBTPlayer]) -> String? {
        if picks.count != BBTConfig.rosterSize {
            return "Roster needs \(BBTConfig.rosterSize) players (\(picks.count)/\(BBTConfig.rosterSize))"
        }
        let spent = picks.reduce(0) { $0 + $1.price }
        if spent > BBTConfig.budget {
            return "Over budget by $\(spent - BBTConfig.budget)"
        }
        let counts = Dictionary(grouping: picks, by: \.position).mapValues(\.count)
        for pos in BBTConfig.positions {
            let n = counts[pos] ?? 0
            if n < (BBTConfig.minByPosition[pos] ?? 0) { return "Need at least \(BBTConfig.minByPosition[pos]!) \(pos)" }
            if n > (BBTConfig.maxByPosition[pos] ?? 99) { return "Max \(BBTConfig.maxByPosition[pos]!) \(pos)" }
        }
        if Set(picks.map(\.id)).count != picks.count { return "Duplicate player" }
        return nil
    }

    /// Can this player still be added given the current selection?
    static func canAdd(_ player: BBTPlayer, to picks: [BBTPlayer]) -> String? {
        if picks.contains(where: { $0.id == player.id }) { return "Already rostered" }
        if picks.count >= BBTConfig.rosterSize { return "Roster full" }
        let posCount = picks.filter { $0.position == player.position }.count
        if posCount >= (BBTConfig.maxByPosition[player.position] ?? 99) { return "Max \(BBTConfig.maxByPosition[player.position]!) \(player.position)" }
        // Must leave $1 for every remaining slot.
        let spent = picks.reduce(0) { $0 + $1.price }
        let slotsAfter = BBTConfig.rosterSize - picks.count - 1
        if spent + player.price + slotsAfter > BBTConfig.budget {
            return "Can't afford — need $\(slotsAfter) for remaining slots"
        }
        return nil
    }
}

// MARK: - Bots

nonisolated enum BBTBotDrafter {
    struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    private static let names = [
        "AuctionAce", "CapCrusher", "NominationNate", "DollarDynasty", "BidBoss", "ValueVault",
        "StarsAndScrubs", "BalancedBudget", "ZeroRB", "HeroRB", "LateRoundQB", "TightEndTitan",
        "WaiverWarrior", "BenchMob", "SleeperSam", "ChalkTalk", "FadeTheField", "UpsideOnly",
        "FloorFinder", "BoomBust", "ContrarianCal", "StackAttack", "PPRPirate", "TargetHog"
    ]

    /// Deterministic 2,000-bot field. Personality = how hard a bot chases
    /// price (stars) vs spreads its budget: alpha 1.9 stars-and-scrubs,
    /// 1.2 balanced, 0.6 value-hunter. Every roster satisfies BBTRosterRules.
    static func generate(pool: [BBTPlayer], count: Int = BBTConfig.botCount, seedSalt: String) -> [BBTEntry] {
        let byPos = Dictionary(grouping: pool, by: \.position)
        var out: [BBTEntry] = []
        out.reserveCapacity(count)
        let saltHash = seedSalt.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        for i in 0..<count {
            var rng = SeededRNG(seed: saltHash &+ UInt64(i) &* 7919)
            let alpha: Double = [1.9, 1.2, 0.6, 1.5, 0.9][i % 5]
            guard let picks = build(byPos: byPos, alpha: alpha, rng: &rng) else { continue }
            let name = "\(names[i % names.count])\(i + 1)"
            out.append(BBTEntry(
                id: "bot-\(i)", userID: nil, entryName: name, entryNumber: 1,
                picks: picks.map { BBTPick(playerID: $0.id, name: $0.name, team: $0.team, position: $0.position, price: $0.price) },
                isBot: true, isCurrentUser: false
            ))
        }
        return out
    }

    private static func build(byPos: [String: [BBTPlayer]], alpha: Double, rng: inout SeededRNG) -> [BBTPlayer]? {
        // Slot plan: mins first, then fill the remaining 8 slots by a
        // weighted position mix (RB/WR heavy), capped by maxes.
        var slots: [String] = []
        for pos in BBTConfig.positions { slots += Array(repeating: pos, count: BBTConfig.minByPosition[pos] ?? 0) }
        let mix: [(String, Double)] = [("RB", 0.36), ("WR", 0.42), ("QB", 0.11), ("TE", 0.11)]
        while slots.count < BBTConfig.rosterSize {
            let r = Double.random(in: 0..<1, using: &rng)
            var acc = 0.0
            var chosen = "WR"
            for (pos, w) in mix { acc += w; if r < acc { chosen = pos; break } }
            if slots.filter({ $0 == chosen }).count < (BBTConfig.maxByPosition[chosen] ?? 99) { slots.append(chosen) }
        }
        slots.shuffle(using: &rng)

        var picks: [BBTPlayer] = []
        var used = Set<String>()
        var remaining = BBTConfig.budget
        for (idx, pos) in slots.enumerated() {
            let slotsLeft = slots.count - idx - 1
            let maxSpend = remaining - slotsLeft   // $1 floor per remaining slot
            let candidates = (byPos[pos] ?? []).filter { !used.contains($0.id) && $0.price <= maxSpend }
            guard !candidates.isEmpty else { return nil }
            // Weight by price^alpha with log-normal-ish noise so identical
            // personalities still diverge.
            var weights: [Double] = []
            weights.reserveCapacity(candidates.count)
            for c in candidates {
                let noise = exp(Double.random(in: -0.6...0.6, using: &rng))
                weights.append(pow(Double(c.price) + 0.5, alpha) * noise)
            }
            let total = weights.reduce(0, +)
            var r = Double.random(in: 0..<total, using: &rng)
            var chosen = candidates[candidates.count - 1]
            for (c, w) in zip(candidates, weights) { r -= w; if r <= 0 { chosen = c; break } }
            picks.append(chosen)
            used.insert(chosen.id)
            remaining -= chosen.price
        }
        return BBTRosterRules.violation(for: picks) == nil ? picks : nil
    }
}

// MARK: - Scoring Engine

nonisolated enum BBTScoringEngine {
    /// Optimal best-ball lineup points for one roster in one week.
    static func weekPoints(picks: [BBTPick], playerPoints: [String: Double]) -> Double {
        let ids = picks.map(\.playerID)
        let positions = Dictionary(uniqueKeysWithValues: picks.map { ($0.playerID, $0.position) })
        let assigned = BestBallLineupConfig.assignStartersToSlots(
            scoringIDs: ids, positions: positions, points: playerPoints,
            constraints: BBTConfig.lineupConstraints
        )
        return assigned.reduce(0.0) { $0 + (playerPoints[$1.playerID] ?? 0) }
    }

    /// Standings for the whole field from per-week player point maps.
    static func standings(entries: [BBTEntry], weekPointsByWeek: [Int: [String: Double]]) -> [BBTStanding] {
        var rows: [(BBTEntry, Double, [Int: Double])] = []
        rows.reserveCapacity(entries.count)
        for e in entries {
            var weekly: [Int: Double] = [:]
            var total = 0.0
            for (week, pts) in weekPointsByWeek where !pts.isEmpty {
                let w = weekPoints(picks: e.picks, playerPoints: pts)
                weekly[week] = w
                total += w
            }
            rows.append((e, (total * 10).rounded() / 10, weekly))
        }
        rows.sort { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            return a.0.entryName < b.0.entryName
        }
        var out: [BBTStanding] = []
        out.reserveCapacity(rows.count)
        var rank = 0
        var lastPts = -1.0
        for (i, r) in rows.enumerated() {
            if r.1 != lastPts { rank = i + 1; lastPts = r.1 }
            out.append(BBTStanding(entry: r.0, totalPoints: r.1, weeklyPoints: r.2, rank: rank))
        }
        return out
    }

    @concurrent static func standingsAsync(entries: [BBTEntry], weekPointsByWeek: [Int: [String: Double]]) async -> [BBTStanding] {
        standings(entries: entries, weekPointsByWeek: weekPointsByWeek)
    }
}

// MARK: - Supabase Records

struct BBTTournamentRecord: Codable {
    let id: String
    let title: String
    let season: Int
    let status: String          // open | live | settled
    let lockTime: Date?
    enum CodingKeys: String, CodingKey {
        case id, title, season, status
        case lockTime = "lock_time"
    }
}

struct BBTEntryRecord: Codable, Identifiable {
    let id: String
    let tournamentID: String
    let userID: String?
    let entryName: String
    let entryNumber: Int
    let picks: [BBTPick]
    let totalPoints: Double?
    let rank: Int?
    let createdAt: Date?
    enum CodingKeys: String, CodingKey {
        case id, picks, rank
        case tournamentID = "tournament_id"
        case userID = "user_id"
        case entryName = "entry_name"
        case entryNumber = "entry_number"
        case totalPoints = "total_points"
        case createdAt = "created_at"
    }
}

struct BBTWeekPointsRecord: Codable {
    let tournamentID: String
    let week: Int
    let playerPoints: [String: Double]
    let isFinal: Bool
    enum CodingKeys: String, CodingKey {
        case week
        case tournamentID = "tournament_id"
        case playerPoints = "player_points"
        case isFinal = "is_final"
    }
}

// MARK: - Supabase Access
//
// Lives in an extension because SupabaseService's request funnels are
// private; these mirror the manual-URLRequest pattern the tennis entry
// submit already uses.

extension SupabaseService {
    private static let bbtDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }
            iso.formatOptions = [.withInternetDateTime]
            if let d = iso.date(from: s) { return d }
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "bad date \(s)")
        }
        return d
    }()

    private func bbtRequest(path: String, query: [URLQueryItem], method: String, body: Data?, token: String, prefer: String? = nil) async throws -> Data {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/\(path)"), resolvingAgainstBaseURL: false)
        components?.queryItems = query.isEmpty ? nil : query
        guard let url = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let prefer { request.setValue(prefer, forHTTPHeaderField: "Prefer") }
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let text = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "SupabaseBBT", code: code, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code) \(text.prefix(200))"])
        }
        return data
    }

    func fetchBBTTournament(id: String, accessToken: String) async throws -> BBTTournamentRecord? {
        let data = try await bbtRequest(
            path: "bbt_tournaments",
            query: [URLQueryItem(name: "id", value: "eq.\(id)"), URLQueryItem(name: "select", value: "id,title,season,status,lock_time")],
            method: "GET", body: nil, token: accessToken
        )
        return try Self.bbtDecoder.decode([BBTTournamentRecord].self, from: data).first
    }

    /// Creates the season's tournament row if it doesn't exist yet
    /// (ignore-duplicates: any client can mint it, nobody overwrites it).
    func ensureBBTTournament(record: BBTTournamentRecord, accessToken: String) async throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let body = try enc.encode([record])
        _ = try await bbtRequest(
            path: "bbt_tournaments", query: [URLQueryItem(name: "on_conflict", value: "id")],
            method: "POST", body: body, token: accessToken, prefer: "resolution=ignore-duplicates"
        )
    }

    func updateBBTTournamentStatus(id: String, status: String, accessToken: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["status": status])
        _ = try await bbtRequest(
            path: "bbt_tournaments", query: [URLQueryItem(name: "id", value: "eq.\(id)")],
            method: "PATCH", body: body, token: accessToken
        )
    }

    /// Corrects a persisted lock time (the first client to mint the row
    /// wrote whatever BBTConfig said at the time).
    func updateBBTTournamentLockTime(id: String, lockTime: Date, accessToken: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["lock_time": ISO8601DateFormatter().string(from: lockTime)])
        _ = try await bbtRequest(
            path: "bbt_tournaments", query: [URLQueryItem(name: "id", value: "eq.\(id)")],
            method: "PATCH", body: body, token: accessToken
        )
    }

    /// Pre-lock roster edit (RLS: own rows only).
    func updateBBTEntryPicks(entryID: String, picks: [BBTPick], accessToken: String) async throws {
        let picksJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(picks))
        let body = try JSONSerialization.data(withJSONObject: ["picks": picksJSON])
        _ = try await bbtRequest(
            path: "bbt_entries", query: [URLQueryItem(name: "id", value: "eq.\(entryID)")],
            method: "PATCH", body: body, token: accessToken
        )
    }

    func fetchBBTBotField(id: String, accessToken: String) async throws -> [[String: Any]] {
        let data = try await bbtRequest(
            path: "bbt_tournaments",
            query: [URLQueryItem(name: "id", value: "eq.\(id)"), URLQueryItem(name: "select", value: "bot_field")],
            method: "GET", body: nil, token: accessToken
        )
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let bots = rows.first?["bot_field"] as? [[String: Any]] else { return [] }
        return bots
    }

    func saveBBTBotField(id: String, botField: [[String: Any]], accessToken: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["bot_field": botField])
        _ = try await bbtRequest(
            path: "bbt_tournaments", query: [URLQueryItem(name: "id", value: "eq.\(id)")],
            method: "PATCH", body: body, token: accessToken
        )
    }

    func fetchBBTEntries(tournamentID: String, accessToken: String) async throws -> [BBTEntryRecord] {
        var all: [BBTEntryRecord] = []
        for page in 0..<5 {
            let data = try await bbtRequest(
                path: "bbt_entries",
                query: [
                    URLQueryItem(name: "tournament_id", value: "eq.\(tournamentID)"),
                    URLQueryItem(name: "select", value: "*"),
                    URLQueryItem(name: "order", value: "id.asc"),
                    URLQueryItem(name: "limit", value: "1000"),
                    URLQueryItem(name: "offset", value: "\(page * 1000)")
                ],
                method: "GET", body: nil, token: accessToken
            )
            let batch = try Self.bbtDecoder.decode([BBTEntryRecord].self, from: data)
            all.append(contentsOf: batch)
            if batch.count < 1000 { break }
        }
        return all
    }

    func insertBBTEntry(tournamentID: String, userID: String, entryName: String, entryNumber: Int, picks: [BBTPick], accessToken: String) async throws -> BBTEntryRecord {
        let enc = JSONEncoder()
        let picksData = try enc.encode(picks)
        let picksJSON = try JSONSerialization.jsonObject(with: picksData)
        let payload: [[String: Any]] = [[
            "tournament_id": tournamentID,
            "user_id": userID,
            "entry_name": entryName,
            "entry_number": entryNumber,
            "picks": picksJSON
        ]]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await bbtRequest(
            path: "bbt_entries", query: [URLQueryItem(name: "select", value: "*")],
            method: "POST", body: body, token: accessToken, prefer: "return=representation"
        )
        guard let rec = try Self.bbtDecoder.decode([BBTEntryRecord].self, from: data).first else {
            throw URLError(.badServerResponse)
        }
        return rec
    }

    func updateBBTEntryScore(entryID: String, totalPoints: Double, rank: Int, accessToken: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["total_points": totalPoints, "rank": rank])
        _ = try await bbtRequest(
            path: "bbt_entries", query: [URLQueryItem(name: "id", value: "eq.\(entryID)")],
            method: "PATCH", body: body, token: accessToken
        )
    }

    func fetchBBTWeekPoints(tournamentID: String, accessToken: String) async throws -> [BBTWeekPointsRecord] {
        let data = try await bbtRequest(
            path: "bbt_week_points",
            query: [URLQueryItem(name: "tournament_id", value: "eq.\(tournamentID)"), URLQueryItem(name: "select", value: "*")],
            method: "GET", body: nil, token: accessToken
        )
        return try Self.bbtDecoder.decode([BBTWeekPointsRecord].self, from: data)
    }

    func upsertBBTWeekPoints(record: BBTWeekPointsRecord, accessToken: String) async throws {
        let body = try JSONEncoder().encode([record])
        _ = try await bbtRequest(
            path: "bbt_week_points", query: [URLQueryItem(name: "on_conflict", value: "tournament_id,week")],
            method: "POST", body: body, token: accessToken, prefer: "resolution=merge-duplicates"
        )
    }
}
