import Foundation

struct SupabaseConfig {
    static let url = URL(string: "https://myhyzjfsyfvwmzknjdof.supabase.co")!
    static let publishableKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im15aHl6amZzeWZ2d216a25qZG9mIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzI2MzYyMjUsImV4cCI6MjA4ODIxMjIyNX0.7_YQ1nZ2BBRbng5FE46TfqOOraiB5VCFkZ4aGW6pOI0"
}

struct SupabaseAuthSession: Codable {
    let accessToken: String
    let refreshToken: String?
    let user: SupabaseAuthUser

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case user
    }
}

struct SupabaseAuthUser: Codable {
    let id: String
    let email: String?
}

private struct SupabaseAuthEnvelope: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let user: SupabaseAuthUser?
    let session: SupabaseAuthNestedSession?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case user
        case session
    }
}

private struct SupabaseAuthNestedSession: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let user: SupabaseAuthUser?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case user
    }
}

enum SupabaseServiceError: LocalizedError, Equatable {
    case emailConfirmationRequired
    case userAlreadyExists
    case rateLimited
    case invalidAuthResponse
    case authMessage(String)

    var errorDescription: String? {
        switch self {
        case .emailConfirmationRequired:
            return "Account created. Please check your email for a confirmation code."
        case .userAlreadyExists:
            return "An account with this email already exists. Please sign in instead."
        case .rateLimited:
            return "Too many requests. Please wait a minute and try again."
        case .invalidAuthResponse:
            return "Unable to read authentication response from server."
        case .authMessage(let message):
            return message
        }
    }
}

struct DFSEntryRecord: Codable, Identifiable {
    let id: String
    let tournamentID: String
    let userID: String
    let lineupPlayerIDs: [String]
    let submittedAt: Date?
    let lineupTotalPoints: Double?
    let displayName: String?
    let lineupPlayerSalaries: [String: Int]?
    let lineupPlayerNames: [String]?
    let lineupNumber: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case tournamentID = "tournament_id"
        case userID = "user_id"
        case lineupPlayerIDs = "lineup_player_ids"
        case submittedAt = "submitted_at"
        case lineupTotalPoints = "lineup_total_points"
        case displayName = "display_name"
        case lineupPlayerSalaries = "lineup_player_salaries"
        case lineupPlayerNames = "lineup_player_names"
        case lineupNumber = "lineup_number"
    }
}

struct DFSProfileRecord: Codable, Identifiable {
    let id: String
    let username: String
    let rrScore: Int?
    let wins: Int?
    let losses: Int?

    enum CodingKeys: String, CodingKey {
        case id, username
        case rrScore = "rr_score"
        case wins, losses
    }
}

struct FriendshipRecord: Codable, Identifiable {
    let id: String
    let requesterID: String
    let addresseeID: String
    let status: String
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case requesterID = "requester_id"
        case addresseeID = "addressee_id"
        case status
        case createdAt = "created_at"
    }
}

struct DFSTournamentInviteRecord: Codable, Identifiable {
    let id: String
    let tournamentID: String
    let inviterID: String
    let inviteeID: String
    let status: String
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case tournamentID = "tournament_id"
        case inviterID = "inviter_id"
        case inviteeID = "invitee_id"
        case status
        case createdAt = "created_at"
    }
}

struct LeaderboardProfile: Codable, Identifiable {
    let id: String
    let username: String
    let rrScore: Int
    let wins: Int
    let losses: Int

    enum CodingKeys: String, CodingKey {
        case id, username, wins, losses
        case rrScore = "rr_score"
    }
}

struct PickemPickRecord: Codable {
    let matchId: String
    let pickedTeam: String
    let matchName: String
    let gainRr: Int
    let lossRr: Int

    enum CodingKeys: String, CodingKey {
        case matchId = "match_id"
        case pickedTeam = "picked_team"
        case matchName = "match_name"
        case gainRr = "gain_rr"
        case lossRr = "loss_rr"
    }
}

struct SettledPickRecord: Codable, Identifiable {
    var id: String { matchId }
    let matchId: String
    let pickedTeam: String
    let matchName: String
    let gainRr: Int
    let lossRr: Int
    let result: String
    let rrDelta: Int
    let settledAt: Date?
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case matchId = "match_id"
        case pickedTeam = "picked_team"
        case matchName = "match_name"
        case gainRr = "gain_rr"
        case lossRr = "loss_rr"
        case result
        case rrDelta = "rr_delta"
        case settledAt = "settled_at"
        case createdAt = "created_at"
    }
}

/// Lightweight record for aggregating all users' Pick'em results in a time window.
struct AllUserSettledPick: Codable {
    let userID: String
    let result: String
    let rrDelta: Int

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case result
        case rrDelta = "rr_delta"
    }
}

/// Lightweight record for aggregating all users' DFS results in a time window.
struct AllUserDFSResult: Codable {
    let userID: String
    let rrDelta: Int

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case rrDelta = "rr_delta"
    }
}

struct ActivePickRecord: Codable, Identifiable {
    var id: String { matchId }
    let matchId: String
    let pickedTeam: String
    let matchName: String
    let gainRr: Int
    let lossRr: Int
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case matchId = "match_id"
        case pickedTeam = "picked_team"
        case matchName = "match_name"
        case gainRr = "gain_rr"
        case lossRr = "loss_rr"
        case createdAt = "created_at"
    }
}

struct UnsettledPickRecord: Codable {
    let userId: String
    let matchId: String
    let pickedTeam: String
    let matchName: String
    let gainRr: Int
    let lossRr: Int
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case matchId = "match_id"
        case pickedTeam = "picked_team"
        case matchName = "match_name"
        case gainRr = "gain_rr"
        case lossRr = "loss_rr"
        case createdAt = "created_at"
    }
}

// MARK: - Best Ball Records

struct BestBallLeagueRecord: Codable, Identifiable {
    let id: String
    let title: String
    let sport: String
    let season: String
    let status: String
    let draftStartTime: Date?
    let draftOrder: [String]
    let currentPickNumber: Int
    let pickTimerSeconds: Int
    let rosterSize: Int
    let scoringSlots: Int
    let currentWeek: Int
    let totalWeeks: Int
    let createdAt: Date
    let schedule: [[[String]]]?
    let weekStructure: String?
    let isPrivate: Bool?
    let createdBy: String?
    let maxMembers: Int?
    let inviteCode: String?
    let pitcherSlots: Int?
    let batterSlots: Int?
    let scoringMode: String?

    enum CodingKeys: String, CodingKey {
        case id, title, sport, season, status, schedule
        case draftStartTime = "draft_start_time"
        case draftOrder = "draft_order"
        case currentPickNumber = "current_pick_number"
        case pickTimerSeconds = "pick_timer_seconds"
        case rosterSize = "roster_size"
        case scoringSlots = "scoring_slots"
        case currentWeek = "current_week"
        case totalWeeks = "total_weeks"
        case createdAt = "created_at"
        case weekStructure = "week_structure"
        case isPrivate = "is_private"
        case createdBy = "created_by"
        case maxMembers = "max_members"
        case inviteCode = "invite_code"
        case pitcherSlots = "pitcher_slots"
        case batterSlots = "batter_slots"
        case scoringMode = "scoring_mode"
    }

    func toModel() -> BestBallLeague {
        BestBallLeague(
            id: id, title: title, sport: sport, season: season,
            status: status, draftStartTime: draftStartTime,
            draftOrder: draftOrder, currentPickNumber: currentPickNumber,
            pickTimerSeconds: pickTimerSeconds, rosterSize: rosterSize,
            scoringSlots: scoringSlots, currentWeek: currentWeek,
            totalWeeks: totalWeeks, createdAt: createdAt,
            schedule: schedule ?? [],
            weekStructure: weekStructure ?? "mon_sun",
            isPrivate: isPrivate ?? false,
            createdBy: createdBy,
            maxMembers: maxMembers ?? 12,
            inviteCode: inviteCode,
            pitcherSlots: pitcherSlots ?? 2,
            batterSlots: batterSlots ?? 6,
            scoringMode: BestBallScoringMode(rawValue: scoringMode ?? "normal") ?? .normal
        )
    }
}

struct BestBallMemberRecord: Codable, Identifiable {
    let id: String
    let leagueId: String
    let userId: String?
    let slotIndex: Int
    let displayName: String
    let isBot: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case leagueId = "league_id"
        case userId = "user_id"
        case slotIndex = "slot_index"
        case displayName = "display_name"
        case isBot = "is_bot"
    }

    func toModel() -> BestBallMember {
        BestBallMember(
            id: id, leagueID: leagueId, userID: userId,
            slotIndex: slotIndex, displayName: displayName, isBot: isBot
        )
    }
}

struct BestBallPickRecord: Codable, Identifiable {
    let id: String
    let leagueId: String
    let memberId: String
    let pickNumber: Int
    let round: Int
    let playerId: String
    let playerName: String
    let playerTeam: String
    let playerPosition: String
    let pickedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case leagueId = "league_id"
        case memberId = "member_id"
        case pickNumber = "pick_number"
        case round
        case playerId = "player_id"
        case playerName = "player_name"
        case playerTeam = "player_team"
        case playerPosition = "player_position"
        case pickedAt = "picked_at"
    }

    func toModel() -> BestBallPick {
        BestBallPick(
            id: id, leagueID: leagueId, memberID: memberId,
            pickNumber: pickNumber, round: round,
            playerID: playerId, playerName: playerName,
            playerTeam: playerTeam, playerPosition: playerPosition,
            pickedAt: pickedAt
        )
    }
}

struct BestBallWeeklyScoreRecord: Codable, Identifiable {
    let id: String
    let leagueId: String
    let memberId: String
    let week: Int
    let totalPoints: Double
    let scoringPlayerIds: [String]
    let playerPoints: [String: Double]
    let computedAt: Date?
    let playerStats: [String: [String: Double]]?
    let opponentMemberId: String?
    let matchupResult: String?

    enum CodingKeys: String, CodingKey {
        case id
        case leagueId = "league_id"
        case memberId = "member_id"
        case week
        case totalPoints = "total_points"
        case scoringPlayerIds = "scoring_player_ids"
        case playerPoints = "player_points"
        case computedAt = "computed_at"
        case playerStats = "player_stats"
        case opponentMemberId = "opponent_member_id"
        case matchupResult = "matchup_result"
    }

    func toModel() -> BestBallWeeklyScore {
        BestBallWeeklyScore(
            id: id, leagueID: leagueId, memberID: memberId,
            week: week, totalPoints: totalPoints,
            scoringPlayerIDs: scoringPlayerIds,
            playerPoints: playerPoints,
            playerStats: playerStats ?? [:],
            opponentMemberID: opponentMemberId,
            matchupResult: matchupResult
        )
    }
}

struct BestBallStandingRecord: Codable, Identifiable {
    let id: String
    let leagueId: String
    let memberId: String
    let totalPoints: Double
    let weeksScored: Int
    let rank: Int
    let updatedAt: Date?
    let wins: Int?
    let losses: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case leagueId = "league_id"
        case memberId = "member_id"
        case totalPoints = "total_points"
        case weeksScored = "weeks_scored"
        case rank, wins, losses
        case updatedAt = "updated_at"
    }

    func toModel() -> BestBallStanding {
        BestBallStanding(
            id: id, leagueID: leagueId, memberID: memberId,
            totalPoints: totalPoints, weeksScored: weeksScored, rank: rank,
            wins: wins ?? 0, losses: losses ?? 0
        )
    }
}

struct BestBallDailyScoreRecord: Codable, Identifiable {
    let id: String
    let leagueId: String
    let memberId: String
    let week: Int
    let gameDate: String
    let playerPoints: [String: Double]
    let playerStats: [String: [String: Double]]
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case leagueId = "league_id"
        case memberId = "member_id"
        case week
        case gameDate = "game_date"
        case playerPoints = "player_points"
        case playerStats = "player_stats"
        case updatedAt = "updated_at"
    }

    func toModel() -> BestBallDailyScore {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.date(from: gameDate) ?? Date()
        return BestBallDailyScore(
            id: id, leagueID: leagueId, memberID: memberId,
            week: week, gameDate: date,
            playerPoints: playerPoints, playerStats: playerStats
        )
    }
}

// MARK: - Chat

struct ChatMessageRecord: Codable, Identifiable {
    let id: String
    let userId: String
    let username: String
    let body: String
    let createdAt: Date
    let leagueId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case username
        case body
        case createdAt = "created_at"
        case leagueId = "league_id"
    }
}

/// A single bot entry in the saved field: just a name and player IDs.
struct BotFieldEntry: Codable {
    let name: String
    let playerIDs: [String]

    enum CodingKeys: String, CodingKey {
        case name
        case playerIDs = "player_ids"
    }
}

struct DFSTournamentRecord: Codable {
    let id: String
    let title: String
    let league: String
    let lockTime: Date
    let isSettled: Bool?
    let totalEntries: Int?
    let playerSalaries: [String: Int]?
    let botField: [BotFieldEntry]?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case league
        case lockTime = "lock_time"
        case isSettled = "is_settled"
        case totalEntries = "total_entries"
        case playerSalaries = "player_salaries"
        case botField = "bot_field"
    }

    init(id: String, title: String, league: String, lockTime: Date, isSettled: Bool? = nil, totalEntries: Int? = nil, playerSalaries: [String: Int]? = nil, botField: [BotFieldEntry]? = nil) {
        self.id = id
        self.title = title
        self.league = league
        self.lockTime = lockTime
        self.isSettled = isSettled
        self.totalEntries = totalEntries
        self.playerSalaries = playerSalaries
        self.botField = botField
    }

    // Custom encode to skip nil fields — prevents upsert from overwriting existing values with null
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(league, forKey: .league)
        try container.encode(lockTime, forKey: .lockTime)
        try container.encodeIfPresent(isSettled, forKey: .isSettled)
        try container.encodeIfPresent(totalEntries, forKey: .totalEntries)
        try container.encodeIfPresent(playerSalaries, forKey: .playerSalaries)
        try container.encodeIfPresent(botField, forKey: .botField)
    }
}

struct DFSTournamentResultRecord: Codable, Identifiable {
    let id: String
    let tournamentID: String
    let userID: String?
    let entryName: String
    let lineupPlayerIDs: [String]
    let lineupPlayerNames: [String]
    let totalPoints: Double
    let playerPoints: [String: Double]?
    let playerSalaries: [String: Int]?
    let rank: Int
    let rrDelta: Int
    let isCurrentUser: Bool
    let isBot: Bool
    let createdAt: Date?

    init(id: String, tournamentID: String, userID: String?, entryName: String,
         lineupPlayerIDs: [String], lineupPlayerNames: [String], totalPoints: Double,
         playerPoints: [String: Double]?, playerSalaries: [String: Int]?,
         rank: Int, rrDelta: Int, isCurrentUser: Bool, isBot: Bool,
         createdAt: Date? = nil) {
        self.id = id
        self.tournamentID = tournamentID
        self.userID = userID
        self.entryName = entryName
        self.lineupPlayerIDs = lineupPlayerIDs
        self.lineupPlayerNames = lineupPlayerNames
        self.totalPoints = totalPoints
        self.playerPoints = playerPoints
        self.playerSalaries = playerSalaries
        self.rank = rank
        self.rrDelta = rrDelta
        self.isCurrentUser = isCurrentUser
        self.isBot = isBot
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case tournamentID = "tournament_id"
        case userID = "user_id"
        case entryName = "entry_name"
        case lineupPlayerIDs = "lineup_player_ids"
        case lineupPlayerNames = "lineup_player_names"
        case totalPoints = "total_points"
        case playerPoints = "player_points"
        case playerSalaries = "player_salaries"
        case rank
        case rrDelta = "rr_delta"
        case isCurrentUser = "is_current_user"
        case isBot = "is_bot"
        case createdAt = "created_at"
    }
}

// MARK: - Playoff Tiers Records

struct PlayoffTiersTournamentRecord: Codable {
    let id: String
    let title: String
    let season: String
    let status: String
    let lockTime: Date?
    let entryCount: Int?
    let playoffRound: String?
    let botField: [[String: Any]]?  // raw JSON
    let isSettled: Bool?
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, title, season, status
        case lockTime = "lock_time"
        case entryCount = "entry_count"
        case playoffRound = "playoff_round"
        case botField = "bot_field"
        case isSettled = "is_settled"
        case createdAt = "created_at"
    }

    init(id: String, title: String, season: String, status: String, lockTime: Date?,
         entryCount: Int? = nil, playoffRound: String? = nil, botField: [[String: Any]]? = nil,
         isSettled: Bool? = nil, createdAt: Date? = nil) {
        self.id = id; self.title = title; self.season = season; self.status = status
        self.lockTime = lockTime; self.entryCount = entryCount; self.playoffRound = playoffRound
        self.botField = botField; self.isSettled = isSettled; self.createdAt = createdAt
    }

    // Custom encode to skip nil/complex fields
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(season, forKey: .season)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(lockTime, forKey: .lockTime)
        try container.encodeIfPresent(entryCount, forKey: .entryCount)
        try container.encodeIfPresent(playoffRound, forKey: .playoffRound)
        try container.encodeIfPresent(isSettled, forKey: .isSettled)
        // botField is handled separately via saveBotField — skip encoding complex Any
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        season = try container.decode(String.self, forKey: .season)
        status = try container.decode(String.self, forKey: .status)
        lockTime = try container.decodeIfPresent(Date.self, forKey: .lockTime)
        entryCount = try container.decodeIfPresent(Int.self, forKey: .entryCount)
        playoffRound = try container.decodeIfPresent(String.self, forKey: .playoffRound)
        isSettled = try container.decodeIfPresent(Bool.self, forKey: .isSettled)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        botField = nil  // Decoded separately if needed
    }
}

struct PlayoffTiersEntryRecord: Codable, Identifiable {
    let id: String
    let tournamentID: String
    let userID: String?
    let entryName: String
    let picks: [PlayoffTiersPickData]
    let totalPoints: Double
    let rank: Int
    let isBot: Bool
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case tournamentID = "tournament_id"
        case userID = "user_id"
        case entryName = "entry_name"
        case picks
        case totalPoints = "total_points"
        case rank
        case isBot = "is_bot"
        case createdAt = "created_at"
    }
}

struct PlayoffTiersPickData: Codable, Hashable {
    let tier: Int
    let playerID: String
    let playerName: String
    let playerTeam: String

    enum CodingKeys: String, CodingKey {
        case tier
        case playerID = "player_id"
        case playerName = "player_name"
        case playerTeam = "player_team"
    }

    init(from pick: PlayoffTiersPick) {
        self.tier = pick.tier
        self.playerID = pick.playerID
        self.playerName = pick.playerName
        self.playerTeam = pick.playerTeam
    }

    init(tier: Int, playerID: String, playerName: String, playerTeam: String) {
        self.tier = tier; self.playerID = playerID
        self.playerName = playerName; self.playerTeam = playerTeam
    }

    func toModel() -> PlayoffTiersPick {
        PlayoffTiersPick(tier: tier, playerID: playerID, playerName: playerName, playerTeam: playerTeam)
    }
}

// MARK: - Playoff Tiers Group Records

struct PlayoffTiersGroupRecord: Codable, Identifiable {
    let id: String
    let tournamentID: String
    let name: String
    let createdBy: String
    let inviteCode: String
    let maxMembers: Int
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name
        case tournamentID = "tournament_id"
        case createdBy = "created_by"
        case inviteCode = "invite_code"
        case maxMembers = "max_members"
        case createdAt = "created_at"
    }

    func toModel() -> PlayoffTiersGroup {
        PlayoffTiersGroup(
            id: UUID(uuidString: id) ?? UUID(),
            tournamentID: tournamentID,
            name: name,
            createdBy: createdBy,
            inviteCode: inviteCode,
            maxMembers: maxMembers,
            createdAt: createdAt ?? Date()
        )
    }
}

struct PlayoffTiersGroupMemberRecord: Codable, Identifiable {
    let id: String
    let groupID: String
    let userID: String
    let displayName: String
    let joinedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case groupID = "group_id"
        case userID = "user_id"
        case displayName = "display_name"
        case joinedAt = "joined_at"
    }

    func toModel() -> PlayoffTiersGroupMember {
        PlayoffTiersGroupMember(
            id: UUID(uuidString: id) ?? UUID(),
            groupID: UUID(uuidString: groupID) ?? UUID(),
            userID: userID,
            displayName: displayName,
            joinedAt: joinedAt ?? Date()
        )
    }
}

// MARK: - Soccer Tiers Records

struct SoccerTiersTournamentRecord: Codable {
    let id: String
    let title: String
    let season: String
    let status: String
    let lockTime: Date?
    let entryCount: Int?
    let botField: [[String: Any]]?
    let isSettled: Bool?
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, title, season, status
        case lockTime = "lock_time"
        case entryCount = "entry_count"
        case botField = "bot_field"
        case isSettled = "is_settled"
        case createdAt = "created_at"
    }

    init(id: String, title: String, season: String, status: String, lockTime: Date?,
         entryCount: Int? = nil, botField: [[String: Any]]? = nil,
         isSettled: Bool? = nil, createdAt: Date? = nil) {
        self.id = id; self.title = title; self.season = season; self.status = status
        self.lockTime = lockTime; self.entryCount = entryCount
        self.botField = botField; self.isSettled = isSettled; self.createdAt = createdAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(season, forKey: .season)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(lockTime, forKey: .lockTime)
        try container.encodeIfPresent(entryCount, forKey: .entryCount)
        try container.encodeIfPresent(isSettled, forKey: .isSettled)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        season = try container.decode(String.self, forKey: .season)
        status = try container.decode(String.self, forKey: .status)
        lockTime = try container.decodeIfPresent(Date.self, forKey: .lockTime)
        entryCount = try container.decodeIfPresent(Int.self, forKey: .entryCount)
        isSettled = try container.decodeIfPresent(Bool.self, forKey: .isSettled)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        botField = nil
    }
}

struct SoccerTiersEntryRecord: Codable, Identifiable {
    let id: String
    let tournamentID: String
    let userID: String?
    let entryName: String
    let picks: [SoccerTiersPickData]
    let totalPoints: Double
    let rank: Int
    let isBot: Bool
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case tournamentID = "tournament_id"
        case userID = "user_id"
        case entryName = "entry_name"
        case picks
        case totalPoints = "total_points"
        case rank
        case isBot = "is_bot"
        case createdAt = "created_at"
    }
}

struct SoccerTiersPickData: Codable, Hashable {
    let tier: Int
    let playerID: String
    let playerName: String
    let playerCountry: String

    enum CodingKeys: String, CodingKey {
        case tier
        case playerID = "player_id"
        case playerName = "player_name"
        case playerCountry = "player_country"
    }

    init(from pick: SoccerTiersPick) {
        self.tier = pick.tier
        self.playerID = pick.playerID
        self.playerName = pick.playerName
        self.playerCountry = pick.playerCountry
    }

    init(tier: Int, playerID: String, playerName: String, playerCountry: String) {
        self.tier = tier; self.playerID = playerID
        self.playerName = playerName; self.playerCountry = playerCountry
    }

    func toModel() -> SoccerTiersPick {
        SoccerTiersPick(tier: tier, playerID: playerID, playerName: playerName, playerCountry: playerCountry)
    }
}

struct SoccerTiersGroupRecord: Codable, Identifiable {
    let id: String
    let tournamentID: String
    let name: String
    let createdBy: String
    let inviteCode: String
    let maxMembers: Int
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name
        case tournamentID = "tournament_id"
        case createdBy = "created_by"
        case inviteCode = "invite_code"
        case maxMembers = "max_members"
        case createdAt = "created_at"
    }

    func toModel() -> SoccerTiersGroup {
        SoccerTiersGroup(
            id: UUID(uuidString: id) ?? UUID(),
            tournamentID: tournamentID,
            name: name,
            createdBy: createdBy,
            inviteCode: inviteCode,
            maxMembers: maxMembers,
            createdAt: createdAt ?? Date()
        )
    }
}

struct SoccerTiersGroupMemberRecord: Codable, Identifiable {
    let id: String
    let groupID: String
    let userID: String
    let displayName: String
    let joinedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case groupID = "group_id"
        case userID = "user_id"
        case displayName = "display_name"
        case joinedAt = "joined_at"
    }

    func toModel() -> SoccerTiersGroupMember {
        SoccerTiersGroupMember(
            id: UUID(uuidString: id) ?? UUID(),
            groupID: UUID(uuidString: groupID) ?? UUID(),
            userID: userID,
            displayName: displayName,
            joinedAt: joinedAt ?? Date()
        )
    }
}

// MARK: - Tennis Bracket Records

struct TennisBracketTournamentRecord: Codable {
    let id: String
    let title: String
    let grandSlam: String
    let drawType: String
    let season: String
    let status: String
    let lockTime: Date?
    let entryCount: Int?
    let isSettled: Bool?
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, title, season, status
        case grandSlam = "grand_slam"
        case drawType = "draw_type"
        case lockTime = "lock_time"
        case entryCount = "entry_count"
        case isSettled = "is_settled"
        case createdAt = "created_at"
    }

    init(id: String, title: String, grandSlam: String, drawType: String, season: String,
         status: String, lockTime: Date?, entryCount: Int? = nil,
         isSettled: Bool? = nil, createdAt: Date? = nil) {
        self.id = id; self.title = title; self.grandSlam = grandSlam
        self.drawType = drawType; self.season = season; self.status = status
        self.lockTime = lockTime; self.entryCount = entryCount
        self.isSettled = isSettled; self.createdAt = createdAt
    }
}

struct TennisBracketEntryRecord: Codable, Identifiable {
    let id: String
    let tournamentID: String
    let userID: String?
    let entryName: String
    let picks: [String: String]
    let totalPoints: Double?
    let rank: Int?
    let isBot: Bool?
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, picks, rank
        case tournamentID = "tournament_id"
        case userID = "user_id"
        case entryName = "entry_name"
        case totalPoints = "total_points"
        case isBot = "is_bot"
        case createdAt = "created_at"
    }
}

struct TennisBracketGroupRecord: Codable, Identifiable {
    let id: String
    let tournamentID: String
    let name: String
    let createdBy: String
    let inviteCode: String
    let maxMembers: Int
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name
        case tournamentID = "tournament_id"
        case createdBy = "created_by"
        case inviteCode = "invite_code"
        case maxMembers = "max_members"
        case createdAt = "created_at"
    }

    func toModel() -> TennisBracketGroup {
        TennisBracketGroup(
            id: UUID(uuidString: id) ?? UUID(),
            tournamentID: tournamentID,
            name: name,
            createdBy: createdBy,
            inviteCode: inviteCode,
            maxMembers: maxMembers,
            createdAt: createdAt ?? Date()
        )
    }
}

struct TennisBracketGroupMemberRecord: Codable, Identifiable {
    let id: String
    let groupID: String
    let userID: String
    let displayName: String
    let joinedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case groupID = "group_id"
        case userID = "user_id"
        case displayName = "display_name"
        case joinedAt = "joined_at"
    }

    func toModel() -> TennisBracketGroupMember {
        TennisBracketGroupMember(
            id: UUID(uuidString: id) ?? UUID(),
            groupID: UUID(uuidString: groupID) ?? UUID(),
            userID: userID,
            displayName: displayName,
            joinedAt: joinedAt ?? Date()
        )
    }
}

// MARK: - Golf Tiers Records

struct GolfTiersTournamentRecord: Codable {
    let id: String
    let title: String
    let majorName: String
    let season: String
    let status: String
    let lockTime: Date?
    let espnEventID: String?
    let entryCount: Int?
    let botField: [[String: Any]]?
    let isSettled: Bool?
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, title, season, status
        case majorName = "major_name"
        case lockTime = "lock_time"
        case espnEventID = "espn_event_id"
        case entryCount = "entry_count"
        case botField = "bot_field"
        case isSettled = "is_settled"
        case createdAt = "created_at"
    }

    init(id: String, title: String, majorName: String, season: String, status: String,
         lockTime: Date?, espnEventID: String? = nil, entryCount: Int? = nil,
         botField: [[String: Any]]? = nil, isSettled: Bool? = nil, createdAt: Date? = nil) {
        self.id = id; self.title = title; self.majorName = majorName
        self.season = season; self.status = status; self.lockTime = lockTime
        self.espnEventID = espnEventID; self.entryCount = entryCount
        self.botField = botField; self.isSettled = isSettled; self.createdAt = createdAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(majorName, forKey: .majorName)
        try container.encode(season, forKey: .season)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(lockTime, forKey: .lockTime)
        try container.encodeIfPresent(espnEventID, forKey: .espnEventID)
        try container.encodeIfPresent(entryCount, forKey: .entryCount)
        try container.encodeIfPresent(isSettled, forKey: .isSettled)
        // botField handled separately via saveBotField
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        majorName = try container.decodeIfPresent(String.self, forKey: .majorName) ?? ""
        season = try container.decode(String.self, forKey: .season)
        status = try container.decode(String.self, forKey: .status)
        lockTime = try container.decodeIfPresent(Date.self, forKey: .lockTime)
        espnEventID = try container.decodeIfPresent(String.self, forKey: .espnEventID)
        entryCount = try container.decodeIfPresent(Int.self, forKey: .entryCount)
        isSettled = try container.decodeIfPresent(Bool.self, forKey: .isSettled)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        botField = nil
    }
}

struct GolfTiersEntryRecord: Codable, Identifiable {
    let id: String
    let tournamentID: String
    let userID: String?
    let entryName: String
    let picks: [GolfTiersPickData]
    let totalPoints: Double
    let rank: Int
    let isBot: Bool
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case tournamentID = "tournament_id"
        case userID = "user_id"
        case entryName = "entry_name"
        case picks
        case totalPoints = "total_points"
        case rank
        case isBot = "is_bot"
        case createdAt = "created_at"
    }
}

struct GolfTiersPickData: Codable, Hashable {
    let tier: Int
    let playerID: String
    let playerName: String
    let playerCountry: String

    enum CodingKeys: String, CodingKey {
        case tier
        case playerID = "player_id"
        case playerName = "player_name"
        case playerCountry = "player_country"
    }

    init(from pick: GolfTiersPick) {
        self.tier = pick.tier
        self.playerID = pick.playerID
        self.playerName = pick.playerName
        self.playerCountry = pick.playerCountry
    }

    init(tier: Int, playerID: String, playerName: String, playerCountry: String) {
        self.tier = tier; self.playerID = playerID
        self.playerName = playerName; self.playerCountry = playerCountry
    }

    func toModel() -> GolfTiersPick {
        GolfTiersPick(tier: tier, playerID: playerID, playerName: playerName, playerCountry: playerCountry)
    }
}

// MARK: - Golf Tiers Group Records

struct GolfTiersGroupRecord: Codable, Identifiable {
    let id: String
    let tournamentID: String
    let name: String
    let createdBy: String
    let inviteCode: String
    let maxMembers: Int
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name
        case tournamentID = "tournament_id"
        case createdBy = "created_by"
        case inviteCode = "invite_code"
        case maxMembers = "max_members"
        case createdAt = "created_at"
    }

    func toModel() -> GolfTiersGroup {
        GolfTiersGroup(
            id: UUID(uuidString: id) ?? UUID(),
            tournamentID: tournamentID,
            name: name,
            createdBy: createdBy,
            inviteCode: inviteCode,
            maxMembers: maxMembers,
            createdAt: createdAt ?? Date()
        )
    }
}

struct GolfTiersGroupMemberRecord: Codable, Identifiable {
    let id: String
    let groupID: String
    let userID: String
    let displayName: String
    let joinedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case groupID = "group_id"
        case userID = "user_id"
        case displayName = "display_name"
        case joinedAt = "joined_at"
    }

    func toModel() -> GolfTiersGroupMember {
        GolfTiersGroupMember(
            id: UUID(uuidString: id) ?? UUID(),
            groupID: UUID(uuidString: groupID) ?? UUID(),
            userID: userID,
            displayName: displayName,
            joinedAt: joinedAt ?? Date()
        )
    }
}

final class SupabaseService {
    static let shared = SupabaseService()

    private let session = URLSession.shared

    /// Callback that refreshes the auth session and returns a fresh access token.
    /// Set by AuthViewModel on init / sign-in. Called automatically on 401 responses.
    var tokenRefreshProvider: (() async -> String?)?

    private init() {}

    func signUp(email: String, password: String) async throws -> SupabaseAuthSession {
        let url = SupabaseConfig.url.appending(path: "/auth/v1/signup")
        let body: [String: String] = ["email": email, "password": password]
        let data: Data
        do {
            data = try await requestData(url: url, method: "POST", body: body, bearerToken: nil)
        } catch {
            let nsError = error as NSError
            let code = nsError.code
            let msg = nsError.localizedDescription.lowercased()
            let userInfoMsg = (nsError.userInfo[NSLocalizedDescriptionKey] as? String ?? "").lowercased()
            let combined = msg + " " + userInfoMsg
            // 429 = rate limit — no user created, no email sent
            if code == 429 || combined.contains("rate limit") || combined.contains("over_email_send") {
                throw SupabaseServiceError.rateLimited
            }
            // User already exists with unconfirmed email
            if combined.contains("already") || combined.contains("confirmation") {
                throw SupabaseServiceError.emailConfirmationRequired
            }
            throw error
        }
        let parsed = parseAuthPayload(data)
        if let session = parsed.session {
            return session
        }
        if parsed.hasUser {
            // Supabase returns a user with empty identities when the email is already
            // registered and confirmed. No confirmation email is sent in this case.
            if parsed.identitiesEmpty {
                throw SupabaseServiceError.userAlreadyExists
            }
            // User created successfully, needs email confirmation
            throw SupabaseServiceError.emailConfirmationRequired
        }
        if let message = parsed.message {
            throw SupabaseServiceError.authMessage(message)
        }
        throw SupabaseServiceError.invalidAuthResponse
    }

    func signIn(email: String, password: String) async throws -> SupabaseAuthSession {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/auth/v1/token"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "grant_type", value: "password")]
        guard let url = components?.url else { throw URLError(.badURL) }
        let body: [String: String] = ["email": email, "password": password]
        let data = try await requestData(url: url, method: "POST", body: body, bearerToken: nil)
        let parsed = parseAuthPayload(data)
        if let session = parsed.session { return session }
        if let message = parsed.message { throw SupabaseServiceError.authMessage(message) }
        throw SupabaseServiceError.invalidAuthResponse
    }

    func refreshSession(refreshToken: String) async throws -> SupabaseAuthSession {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/auth/v1/token"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
        guard let url = components?.url else { throw URLError(.badURL) }
        let body: [String: String] = ["refresh_token": refreshToken]
        let data = try await requestData(url: url, method: "POST", body: body, bearerToken: nil)
        let parsed = parseAuthPayload(data)
        if let session = parsed.session { return session }
        if let message = parsed.message { throw SupabaseServiceError.authMessage(message) }
        throw SupabaseServiceError.invalidAuthResponse
    }

    func resendConfirmationEmail(email: String) async throws {
        let url = SupabaseConfig.url.appending(path: "/auth/v1/resend")
        let body: [String: String] = ["email": email, "type": "signup"]
        _ = try await requestData(url: url, method: "POST", body: body, bearerToken: nil)
    }

    func verifyOTP(email: String, token: String) async throws -> SupabaseAuthSession {
        let url = SupabaseConfig.url.appending(path: "/auth/v1/verify")
        let body: [String: String] = ["email": email, "token": token, "type": "signup"]
        let data = try await requestData(url: url, method: "POST", body: body, bearerToken: nil)
        let parsed = parseAuthPayload(data)
        if let session = parsed.session { return session }
        if let message = parsed.message { throw SupabaseServiceError.authMessage(message) }
        throw SupabaseServiceError.invalidAuthResponse
    }

    func signOut(accessToken: String) async {
        let url = SupabaseConfig.url.appending(path: "/auth/v1/logout")
        _ = try? await requestNoResponse(url: url, method: "POST", body: Optional<String>.none, bearerToken: accessToken)
    }

    func upsertProfile(userID: String, username: String, accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/profiles"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "on_conflict", value: "id")]
        guard let url = components?.url else { throw URLError(.badURL) }
        struct Payload: Codable {
            let id: String
            let username: String
        }
        let payload = [Payload(id: userID, username: username)]
        try await requestNoResponse(url: url, method: "POST", body: payload, bearerToken: accessToken, preferUpsert: true)
    }

    func upsertTournament(record: DFSTournamentRecord, accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/dfs_tournaments"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "on_conflict", value: "id")]
        guard let url = components?.url else { throw URLError(.badURL) }
        try await requestNoResponse(url: url, method: "POST", body: [record], bearerToken: accessToken, preferUpsert: true)
    }

    func submitEntry(
        tournamentID: String,
        userID: String,
        lineupPlayerIDs: [String],
        lineupPlayerSalaries: [String: Int] = [:],
        lineupPlayerNames: [String] = [],
        lineupNumber: Int = 1,
        accessToken: String
    ) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/dfs_entries"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "on_conflict", value: "tournament_id,user_id,lineup_number")]
        guard let url = components?.url else { throw URLError(.badURL) }
        struct Payload: Codable {
            let tournamentID: String
            let userID: String
            let lineupPlayerIDs: [String]
            let lineupPlayerSalaries: [String: Int]
            let lineupPlayerNames: [String]
            let lineupNumber: Int

            enum CodingKeys: String, CodingKey {
                case tournamentID = "tournament_id"
                case userID = "user_id"
                case lineupPlayerIDs = "lineup_player_ids"
                case lineupPlayerSalaries = "lineup_player_salaries"
                case lineupPlayerNames = "lineup_player_names"
                case lineupNumber = "lineup_number"
            }
        }
        let payload = [Payload(tournamentID: tournamentID, userID: userID, lineupPlayerIDs: lineupPlayerIDs, lineupPlayerSalaries: lineupPlayerSalaries, lineupPlayerNames: lineupPlayerNames, lineupNumber: lineupNumber)]
        try await requestNoResponse(url: url, method: "POST", body: payload, bearerToken: accessToken, preferUpsert: true)
    }

    func unregisterEntry(tournamentID: String, userID: String, lineupNumber: Int = 1, accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/dfs_entries"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "tournament_id", value: "eq.\(tournamentID)"),
            URLQueryItem(name: "user_id", value: "eq.\(userID)"),
            URLQueryItem(name: "lineup_number", value: "eq.\(lineupNumber)")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        try await requestNoResponse(url: url, method: "DELETE", body: Optional<String>.none, bearerToken: accessToken)
    }

    /// Fetches the user's recent entries across all tournaments (last 100).
    func fetchUserRecentEntries(userID: String, accessToken: String) async throws -> [DFSEntryRecord] {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/dfs_entries"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "user_id", value: "eq.\(userID)"),
            URLQueryItem(name: "select", value: "id,tournament_id,user_id,lineup_player_ids,submitted_at,lineup_total_points,display_name,lineup_player_salaries,lineup_player_names,lineup_number"),
            URLQueryItem(name: "order", value: "submitted_at.desc"),
            URLQueryItem(name: "limit", value: "100")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        return try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    func fetchEntries(tournamentID: String, accessToken: String) async throws -> [DFSEntryRecord] {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/dfs_entries"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "tournament_id", value: "eq.\(tournamentID)"),
            URLQueryItem(name: "select", value: "id,tournament_id,user_id,lineup_player_ids,submitted_at,lineup_total_points,display_name,lineup_player_salaries,lineup_player_names,lineup_number")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        return try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    func updateEntryScore(entryID: String, totalPoints: Double, displayName: String, accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/dfs_entries"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(entryID)")]
        guard let url = components?.url else { throw URLError(.badURL) }
        struct Payload: Codable {
            let lineupTotalPoints: Double
            let displayName: String
            enum CodingKeys: String, CodingKey {
                case lineupTotalPoints = "lineup_total_points"
                case displayName = "display_name"
            }
        }
        try await requestNoResponse(url: url, method: "PATCH", body: Payload(lineupTotalPoints: totalPoints, displayName: displayName), bearerToken: accessToken)
    }

    // MARK: - DFS Tournament Results (full leaderboard persistence)

    func upsertTournamentResults(tournamentID: String, results: [DFSTournamentResultRecord], accessToken: String) async throws {
        guard !results.isEmpty else { return }
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/dfs_tournament_results"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "on_conflict", value: "tournament_id,entry_name")]
        guard let url = components?.url else { throw URLError(.badURL) }
        struct Payload: Encodable {
            let tournamentID: String
            let userID: String?
            let entryName: String
            let lineupPlayerIDs: [String]
            let lineupPlayerNames: [String]
            let totalPoints: Double
            let playerPoints: [String: Double]
            let playerSalaries: [String: Int]
            let rank: Int
            let rrDelta: Int
            let isCurrentUser: Bool
            let isBot: Bool
            enum CodingKeys: String, CodingKey {
                case tournamentID = "tournament_id"
                case userID = "user_id"
                case entryName = "entry_name"
                case lineupPlayerIDs = "lineup_player_ids"
                case lineupPlayerNames = "lineup_player_names"
                case totalPoints = "total_points"
                case playerPoints = "player_points"
                case playerSalaries = "player_salaries"
                case rank
                case rrDelta = "rr_delta"
                case isCurrentUser = "is_current_user"
                case isBot = "is_bot"
            }
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(tournamentID, forKey: .tournamentID)
                // Always encode user_id (even when nil) so all objects have the same keys
                try container.encode(userID, forKey: .userID)
                try container.encode(entryName, forKey: .entryName)
                try container.encode(lineupPlayerIDs, forKey: .lineupPlayerIDs)
                try container.encode(lineupPlayerNames, forKey: .lineupPlayerNames)
                try container.encode(totalPoints, forKey: .totalPoints)
                try container.encode(playerPoints, forKey: .playerPoints)
                try container.encode(playerSalaries, forKey: .playerSalaries)
                try container.encode(rank, forKey: .rank)
                try container.encode(rrDelta, forKey: .rrDelta)
                try container.encode(isCurrentUser, forKey: .isCurrentUser)
                try container.encode(isBot, forKey: .isBot)
            }
        }
        let payloads = results.map { r in
            Payload(
                tournamentID: tournamentID,
                userID: r.userID,
                entryName: r.entryName,
                lineupPlayerIDs: r.lineupPlayerIDs,
                lineupPlayerNames: r.lineupPlayerNames,
                totalPoints: r.totalPoints,
                playerPoints: r.playerPoints ?? [:],
                playerSalaries: r.playerSalaries ?? [:],
                rank: r.rank,
                rrDelta: r.rrDelta,
                isCurrentUser: r.isCurrentUser,
                isBot: r.isBot
            )
        }
        // Supabase PostgREST limits bulk inserts to ~1000 rows per request.
        // Chunk into batches of 500 to ensure all results are persisted.
        let chunkSize = 500
        for startIndex in stride(from: 0, to: payloads.count, by: chunkSize) {
            let endIndex = min(startIndex + chunkSize, payloads.count)
            let chunk = Array(payloads[startIndex..<endIndex])
            try await requestNoResponse(url: url, method: "POST", body: chunk, bearerToken: accessToken, preferUpsert: true)
        }
    }

    /// Deletes all tournament result records for a given tournament ID.
    func deleteTournamentResults(tournamentID: String, accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/dfs_tournament_results"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "tournament_id", value: "eq.\(tournamentID)")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        try await requestNoResponse(url: url, method: "DELETE", body: Optional<String>.none, bearerToken: accessToken)
    }

    func fetchTournamentResults(tournamentID: String, accessToken: String) async throws -> [DFSTournamentResultRecord] {
        // Supabase's default max-rows is 1000. For tournaments with >1000 entries
        // (e.g., 2000-entry tournaments), we must paginate to get all results.
        let pageSize = 1000
        var allResults: [DFSTournamentResultRecord] = []
        var offset = 0

        while true {
            var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/dfs_tournament_results"), resolvingAgainstBaseURL: false)
            components?.queryItems = [
                URLQueryItem(name: "tournament_id", value: "eq.\(tournamentID)"),
                URLQueryItem(name: "select", value: "*"),
                URLQueryItem(name: "order", value: "rank.asc"),
                URLQueryItem(name: "limit", value: "\(pageSize)"),
                URLQueryItem(name: "offset", value: "\(offset)")
            ]
            guard let url = components?.url else { throw URLError(.badURL) }
            let page: [DFSTournamentResultRecord] = try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
            allResults.append(contentsOf: page)
            if page.count < pageSize { break }  // Last page — no more results
            offset += pageSize
            if offset >= 5000 { break }  // Safety cap
        }
        return allResults
    }

    func markTournamentSettled(tournamentID: String, totalEntries: Int, accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/dfs_tournaments"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(tournamentID)")]
        guard let url = components?.url else { throw URLError(.badURL) }
        struct Payload: Codable {
            let isSettled: Bool
            let totalEntries: Int
            enum CodingKeys: String, CodingKey {
                case isSettled = "is_settled"
                case totalEntries = "total_entries"
            }
        }
        try await requestNoResponse(url: url, method: "PATCH", body: Payload(isSettled: true, totalEntries: totalEntries), bearerToken: accessToken)
    }

    /// Saves the bot field lineups to the tournament record so post-match settlement
    /// can reuse the original pre-game lineups instead of regenerating with hindsight.
    func saveBotField(tournamentID: String, botField: [BotFieldEntry], accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/dfs_tournaments"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(tournamentID)")]
        guard let url = components?.url else { throw URLError(.badURL) }
        struct Payload: Codable {
            let botField: [BotFieldEntry]
            enum CodingKeys: String, CodingKey {
                case botField = "bot_field"
            }
        }
        try await requestNoResponse(url: url, method: "PATCH", body: Payload(botField: botField), bearerToken: accessToken)
    }

    func fetchTournament(tournamentID: String, accessToken: String) async throws -> DFSTournamentRecord? {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/dfs_tournaments"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(tournamentID)"),
            URLQueryItem(name: "select", value: "*")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        let results: [DFSTournamentRecord] = try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
        return results.first
    }

    func fetchUserDFSHistory(userID: String, limit: Int = 100, offset: Int = 0, accessToken: String) async throws -> [DFSTournamentResultRecord] {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/dfs_tournament_results"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "user_id", value: "eq.\(userID)"),
            URLQueryItem(name: "is_current_user", value: "eq.true"),
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        return try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    func fetchRecentTournaments(limit: Int = 200, accessToken: String) async throws -> [DFSTournamentRecord] {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/dfs_tournaments"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "order", value: "lock_time.desc"),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        return try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    func fetchProfiles(userIDs: [String], accessToken: String) async throws -> [DFSProfileRecord] {
        guard !userIDs.isEmpty else { return [] }
        let joined = userIDs.joined(separator: ",")
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/profiles"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "id", value: "in.(\(joined))"),
            URLQueryItem(name: "select", value: "id,username,rr_score,wins,losses")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        return try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    // MARK: - Leaderboard

    func fetchTopProfiles(limit: Int = 100, accessToken: String) async throws -> [LeaderboardProfile] {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/profiles"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "select", value: "id,username,rr_score,wins,losses"),
            URLQueryItem(name: "order", value: "rr_score.desc"),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        return try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    /// Fetch all users' settled picks since a given date (for time-filtered leaderboard).
    func fetchAllSettledPicksSince(sinceISO: String, accessToken: String) async throws -> [AllUserSettledPick] {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/pickem_picks"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "result", value: "not.is.null"),
            URLQueryItem(name: "settled_at", value: "gte.\(sinceISO)"),
            URLQueryItem(name: "select", value: "user_id,result,rr_delta")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        return try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    /// Fetch all users' DFS results since a given date (for time-filtered leaderboard).
    func fetchAllDFSResultsSince(sinceISO: String, accessToken: String) async throws -> [AllUserDFSResult] {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/dfs_tournament_results"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "is_current_user", value: "eq.true"),
            URLQueryItem(name: "created_at", value: "gte.\(sinceISO)"),
            URLQueryItem(name: "select", value: "user_id,rr_delta")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        return try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    // MARK: - Friends

    func sendFriendRequest(fromUserID: String, toUserID: String, accessToken: String) async throws {
        let url = SupabaseConfig.url.appending(path: "/rest/v1/friendships")
        struct Payload: Codable {
            let requesterID: String
            let addresseeID: String
            enum CodingKeys: String, CodingKey {
                case requesterID = "requester_id"
                case addresseeID = "addressee_id"
            }
        }
        try await requestNoResponse(url: url, method: "POST", body: [Payload(requesterID: fromUserID, addresseeID: toUserID)], bearerToken: accessToken)
    }

    func acceptFriendRequest(friendshipID: String, accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/friendships"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(friendshipID)")]
        guard let url = components?.url else { throw URLError(.badURL) }
        struct Payload: Codable { let status: String }
        try await requestNoResponse(url: url, method: "PATCH", body: Payload(status: "accepted"), bearerToken: accessToken)
    }

    func removeFriend(friendshipID: String, accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/friendships"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(friendshipID)")]
        guard let url = components?.url else { throw URLError(.badURL) }
        try await requestNoResponse(url: url, method: "DELETE", body: Optional<String>.none, bearerToken: accessToken)
    }

    func fetchFriendships(userID: String, accessToken: String) async throws -> [FriendshipRecord] {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/friendships"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "or", value: "(requester_id.eq.\(userID),addressee_id.eq.\(userID))"),
            URLQueryItem(name: "select", value: "id,requester_id,addressee_id,status,created_at")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        return try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    // MARK: - Tournament Invites

    func sendTournamentInvite(tournamentID: String, inviterID: String, inviteeID: String, accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/dfs_tournament_invites"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "on_conflict", value: "tournament_id,inviter_id,invitee_id")]
        guard let url = components?.url else { throw URLError(.badURL) }
        struct Payload: Codable {
            let tournamentID: String
            let inviterID: String
            let inviteeID: String
            enum CodingKeys: String, CodingKey {
                case tournamentID = "tournament_id"
                case inviterID = "inviter_id"
                case inviteeID = "invitee_id"
            }
        }
        try await requestNoResponse(url: url, method: "POST", body: [Payload(tournamentID: tournamentID, inviterID: inviterID, inviteeID: inviteeID)], bearerToken: accessToken, preferUpsert: true)
    }

    func respondToTournamentInvite(inviteID: String, status: String, accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/dfs_tournament_invites"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(inviteID)")]
        guard let url = components?.url else { throw URLError(.badURL) }
        struct Payload: Codable { let status: String }
        try await requestNoResponse(url: url, method: "PATCH", body: Payload(status: status), bearerToken: accessToken)
    }

    func fetchPendingInvites(userID: String, accessToken: String) async throws -> [DFSTournamentInviteRecord] {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/dfs_tournament_invites"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "invitee_id", value: "eq.\(userID)"),
            URLQueryItem(name: "status", value: "eq.pending"),
            URLQueryItem(name: "select", value: "id,tournament_id,inviter_id,invitee_id,status,created_at"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: "50")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        return try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    func fetchSentInvites(tournamentID: String, inviterID: String, accessToken: String) async throws -> [DFSTournamentInviteRecord] {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/dfs_tournament_invites"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "tournament_id", value: "eq.\(tournamentID)"),
            URLQueryItem(name: "inviter_id", value: "eq.\(inviterID)"),
            URLQueryItem(name: "select", value: "id,tournament_id,inviter_id,invitee_id,status,created_at")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        return try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    func findUserByUsername(username: String, accessToken: String) async throws -> [LeaderboardProfile] {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/profiles"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "username", value: "ilike.*\(username)*"),
            URLQueryItem(name: "select", value: "id,username,rr_score,wins,losses"),
            URLQueryItem(name: "limit", value: "20")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        return try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    func syncProfileStats(userID: String, rrScore: Int, wins: Int, losses: Int, accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/profiles"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(userID)")]
        guard let url = components?.url else { throw URLError(.badURL) }
        struct Payload: Codable {
            let rrScore: Int
            let wins: Int
            let losses: Int
            enum CodingKeys: String, CodingKey {
                case rrScore = "rr_score"
                case wins, losses
            }
        }
        try await requestNoResponse(url: url, method: "PATCH", body: Payload(rrScore: rrScore, wins: wins, losses: losses), bearerToken: accessToken)
    }

    /// Atomically adjust another user's profile stats via Postgres RPC (for global pick settlement)
    func adjustProfileStats(userID: String, rrDelta: Int, winsDelta: Int, lossesDelta: Int, accessToken: String) async throws {
        let url = SupabaseConfig.url.appending(path: "/rest/v1/rpc/adjust_profile_stats")
        struct Payload: Codable {
            let pUserId: String
            let pRrDelta: Int
            let pWinsDelta: Int
            let pLossesDelta: Int
            enum CodingKeys: String, CodingKey {
                case pUserId = "p_user_id"
                case pRrDelta = "p_rr_delta"
                case pWinsDelta = "p_wins_delta"
                case pLossesDelta = "p_losses_delta"
            }
        }
        try await requestNoResponse(
            url: url, method: "POST",
            body: Payload(pUserId: userID, pRrDelta: rrDelta, pWinsDelta: winsDelta, pLossesDelta: lossesDelta),
            bearerToken: accessToken
        )
    }

    // MARK: - Best Ball Leagues

    func fetchOpenLeagues(sport: String? = nil, accessToken: String) async throws -> [BestBallLeagueRecord] {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/bestball_leagues"), resolvingAgainstBaseURL: false)
        var queries: [URLQueryItem] = [
            URLQueryItem(name: "status", value: "eq.open"),
            URLQueryItem(name: "is_private", value: "eq.false"),
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: "50")
        ]
        if let sport {
            queries.append(URLQueryItem(name: "sport", value: "eq.\(sport)"))
        }
        components?.queryItems = queries
        guard let url = components?.url else { throw URLError(.badURL) }
        return try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    func fetchLeague(id: String, accessToken: String) async throws -> BestBallLeagueRecord? {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/bestball_leagues"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(id)"),
            URLQueryItem(name: "select", value: "*")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        let results: [BestBallLeagueRecord] = try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
        return results.first
    }

    func createLeague(
        title: String, sport: String, season: String,
        isPrivate: Bool = false, maxMembers: Int = 12, rosterSize: Int = 12,
        pitcherSlots: Int = 2, batterSlots: Int = 6,
        scoringMode: String = "normal",
        createdBy: String, accessToken: String
    ) async throws -> BestBallLeagueRecord {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/bestball_leagues"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "select", value: "*")]
        guard let url = components?.url else { throw URLError(.badURL) }

        // Generate invite code for private leagues
        let inviteCode: String? = isPrivate ? Self.generateInviteCode() : nil

        struct Payload: Codable {
            let title: String
            let sport: String
            let season: String
            let totalWeeks: Int
            let isPrivate: Bool
            let createdBy: String
            let maxMembers: Int
            let rosterSize: Int
            let inviteCode: String?
            let pitcherSlots: Int
            let batterSlots: Int
            let scoringMode: String
            enum CodingKeys: String, CodingKey {
                case title, sport, season
                case totalWeeks = "total_weeks"
                case isPrivate = "is_private"
                case createdBy = "created_by"
                case maxMembers = "max_members"
                case rosterSize = "roster_size"
                case inviteCode = "invite_code"
                case pitcherSlots = "pitcher_slots"
                case batterSlots = "batter_slots"
                case scoringMode = "scoring_mode"
            }
        }
        let payload = Payload(
            title: title, sport: sport, season: season,
            totalWeeks: BestBallSeasonHelper.totalWeeks(for: sport),
            isPrivate: isPrivate, createdBy: createdBy,
            maxMembers: maxMembers, rosterSize: rosterSize,
            inviteCode: inviteCode,
            pitcherSlots: pitcherSlots, batterSlots: batterSlots,
            scoringMode: scoringMode
        )
        let results: [BestBallLeagueRecord] = try await request(url: url, method: "POST", body: payload, bearerToken: accessToken, preferReturn: "representation")
        guard let league = results.first else { throw URLError(.badServerResponse) }
        return league
    }

    private static func generateInviteCode() -> String {
        let chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789" // no I/O/0/1 to avoid confusion
        return String((0..<6).map { _ in chars.randomElement()! })
    }

    func updateLeagueSettings(
        leagueID: String, title: String, maxMembers: Int, rosterSize: Int, isPrivate: Bool,
        pitcherSlots: Int = 2, batterSlots: Int = 6,
        scoringMode: String = "normal",
        accessToken: String
    ) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/bestball_leagues"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(leagueID)")]
        guard let url = components?.url else { throw URLError(.badURL) }
        struct Payload: Codable {
            let title: String
            let maxMembers: Int
            let rosterSize: Int
            let isPrivate: Bool
            let inviteCode: String?
            let pitcherSlots: Int
            let batterSlots: Int
            let scoringMode: String
            enum CodingKeys: String, CodingKey {
                case title
                case maxMembers = "max_members"
                case rosterSize = "roster_size"
                case isPrivate = "is_private"
                case inviteCode = "invite_code"
                case pitcherSlots = "pitcher_slots"
                case batterSlots = "batter_slots"
                case scoringMode = "scoring_mode"
            }
        }
        // Generate invite code if switching to private and none exists
        let inviteCode: String? = isPrivate ? Self.generateInviteCode() : nil
        try await requestNoResponse(
            url: url, method: "PATCH",
            body: Payload(title: title, maxMembers: maxMembers, rosterSize: rosterSize, isPrivate: isPrivate, inviteCode: inviteCode, pitcherSlots: pitcherSlots, batterSlots: batterSlots, scoringMode: scoringMode),
            bearerToken: accessToken
        )
    }

    func fetchLeagueByInviteCode(code: String, accessToken: String) async throws -> BestBallLeagueRecord? {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/bestball_leagues"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "invite_code", value: "eq.\(code.uppercased())"),
            URLQueryItem(name: "select", value: "*")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        let results: [BestBallLeagueRecord] = try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
        return results.first
    }

    func updateLeagueStatus(leagueID: String, status: String, accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/bestball_leagues"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(leagueID)")]
        guard let url = components?.url else { throw URLError(.badURL) }
        struct Payload: Codable { let status: String }
        try await requestNoResponse(url: url, method: "PATCH", body: Payload(status: status), bearerToken: accessToken)
    }

    func updateLeagueDraft(leagueID: String, draftOrder: [String], currentPickNumber: Int, status: String, accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/bestball_leagues"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(leagueID)")]
        guard let url = components?.url else { throw URLError(.badURL) }
        struct Payload: Codable {
            let draftOrder: [String]
            let currentPickNumber: Int
            let status: String
            enum CodingKeys: String, CodingKey {
                case draftOrder = "draft_order"
                case currentPickNumber = "current_pick_number"
                case status
            }
        }
        try await requestNoResponse(url: url, method: "PATCH", body: Payload(draftOrder: draftOrder, currentPickNumber: currentPickNumber, status: status), bearerToken: accessToken)
    }

    func updateLeaguePickNumber(leagueID: String, pickNumber: Int, accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/bestball_leagues"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(leagueID)")]
        guard let url = components?.url else { throw URLError(.badURL) }
        struct Payload: Codable {
            let currentPickNumber: Int
            enum CodingKeys: String, CodingKey {
                case currentPickNumber = "current_pick_number"
            }
        }
        try await requestNoResponse(url: url, method: "PATCH", body: Payload(currentPickNumber: pickNumber), bearerToken: accessToken)
    }

    func updateLeagueWeek(leagueID: String, week: Int, accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/bestball_leagues"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(leagueID)")]
        guard let url = components?.url else { throw URLError(.badURL) }
        struct Payload: Codable {
            let currentWeek: Int
            enum CodingKeys: String, CodingKey {
                case currentWeek = "current_week"
            }
        }
        try await requestNoResponse(url: url, method: "PATCH", body: Payload(currentWeek: week), bearerToken: accessToken)
    }

    // MARK: - Best Ball Members

    func fetchLeagueMembers(leagueID: String, accessToken: String) async throws -> [BestBallMemberRecord] {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/bestball_members"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "league_id", value: "eq.\(leagueID)"),
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "order", value: "slot_index.asc")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        return try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    /// Fetch member counts for a list of league IDs in a single query.
    func fetchMemberCounts(leagueIDs: [String], accessToken: String) async throws -> [String: Int] {
        guard !leagueIDs.isEmpty else { return [:] }
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/bestball_members"), resolvingAgainstBaseURL: false)
        let idList = "(\(leagueIDs.joined(separator: ",")))"
        components?.queryItems = [
            URLQueryItem(name: "league_id", value: "in.\(idList)"),
            URLQueryItem(name: "select", value: "league_id")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        struct MemberStub: Codable {
            let leagueId: String
            enum CodingKeys: String, CodingKey {
                case leagueId = "league_id"
            }
        }
        let stubs: [MemberStub] = try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
        var counts: [String: Int] = [:]
        for stub in stubs {
            counts[stub.leagueId, default: 0] += 1
        }
        return counts
    }

    func joinLeague(leagueID: String, userID: String, displayName: String, slotIndex: Int, accessToken: String) async throws -> BestBallMemberRecord {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/bestball_members"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "select", value: "*")]
        guard let url = components?.url else { throw URLError(.badURL) }
        struct Payload: Codable {
            let leagueId: String
            let userId: String
            let slotIndex: Int
            let displayName: String
            let isBot: Bool
            enum CodingKeys: String, CodingKey {
                case leagueId = "league_id"
                case userId = "user_id"
                case slotIndex = "slot_index"
                case displayName = "display_name"
                case isBot = "is_bot"
            }
        }
        let payload = Payload(leagueId: leagueID, userId: userID, slotIndex: slotIndex, displayName: displayName, isBot: false)
        let results: [BestBallMemberRecord] = try await request(url: url, method: "POST", body: payload, bearerToken: accessToken, preferReturn: "representation")
        guard let member = results.first else { throw URLError(.badServerResponse) }
        return member
    }

    func addBot(leagueID: String, slotIndex: Int, displayName: String, accessToken: String) async throws -> BestBallMemberRecord {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/bestball_members"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "select", value: "*")]
        guard let url = components?.url else { throw URLError(.badURL) }
        struct Payload: Codable {
            let leagueId: String
            let slotIndex: Int
            let displayName: String
            let isBot: Bool
            enum CodingKeys: String, CodingKey {
                case leagueId = "league_id"
                case slotIndex = "slot_index"
                case displayName = "display_name"
                case isBot = "is_bot"
            }
        }
        let payload = Payload(leagueId: leagueID, slotIndex: slotIndex, displayName: displayName, isBot: true)
        let results: [BestBallMemberRecord] = try await request(url: url, method: "POST", body: payload, bearerToken: accessToken, preferReturn: "representation")
        guard let member = results.first else { throw URLError(.badServerResponse) }
        return member
    }

    func fetchUserMemberships(userID: String, accessToken: String) async throws -> [BestBallMemberRecord] {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/bestball_members"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "user_id", value: "eq.\(userID)"),
            URLQueryItem(name: "select", value: "*")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        return try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    // MARK: - Best Ball Draft Picks

    func fetchDraftPicks(leagueID: String, accessToken: String) async throws -> [BestBallPickRecord] {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/bestball_picks"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "league_id", value: "eq.\(leagueID)"),
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "order", value: "pick_number.asc")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        return try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    func submitDraftPick(
        leagueID: String, memberID: String, pickNumber: Int, round: Int,
        playerID: String, playerName: String, playerTeam: String, playerPosition: String,
        accessToken: String
    ) async throws -> BestBallPickRecord {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/bestball_picks"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "select", value: "*")]
        guard let url = components?.url else { throw URLError(.badURL) }
        struct Payload: Codable {
            let leagueId: String
            let memberId: String
            let pickNumber: Int
            let round: Int
            let playerId: String
            let playerName: String
            let playerTeam: String
            let playerPosition: String
            enum CodingKeys: String, CodingKey {
                case leagueId = "league_id"
                case memberId = "member_id"
                case pickNumber = "pick_number"
                case round
                case playerId = "player_id"
                case playerName = "player_name"
                case playerTeam = "player_team"
                case playerPosition = "player_position"
            }
        }
        let payload = Payload(
            leagueId: leagueID, memberId: memberID, pickNumber: pickNumber, round: round,
            playerId: playerID, playerName: playerName, playerTeam: playerTeam, playerPosition: playerPosition
        )
        let results: [BestBallPickRecord] = try await request(url: url, method: "POST", body: payload, bearerToken: accessToken, preferReturn: "representation")
        guard let pick = results.first else { throw URLError(.badServerResponse) }
        return pick
    }

    // MARK: - Best Ball Scoring

    func fetchWeeklyScores(leagueID: String, accessToken: String) async throws -> [BestBallWeeklyScoreRecord] {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/bestball_weekly_scores"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "league_id", value: "eq.\(leagueID)"),
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "order", value: "week.asc")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        return try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    func upsertWeeklyScore(
        leagueID: String, memberID: String, week: Int,
        totalPoints: Double, scoringPlayerIDs: [String], playerPoints: [String: Double],
        playerStats: [String: [String: Double]] = [:],
        opponentMemberID: String? = nil, matchupResult: String? = nil,
        accessToken: String
    ) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/bestball_weekly_scores"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "on_conflict", value: "league_id,member_id,week")]
        guard let url = components?.url else { throw URLError(.badURL) }
        struct Payload: Codable {
            let leagueId: String
            let memberId: String
            let week: Int
            let totalPoints: Double
            let scoringPlayerIds: [String]
            let playerPoints: [String: Double]
            let playerStats: [String: [String: Double]]
            let opponentMemberId: String?
            let matchupResult: String?
            enum CodingKeys: String, CodingKey {
                case leagueId = "league_id"
                case memberId = "member_id"
                case week
                case totalPoints = "total_points"
                case scoringPlayerIds = "scoring_player_ids"
                case playerPoints = "player_points"
                case playerStats = "player_stats"
                case opponentMemberId = "opponent_member_id"
                case matchupResult = "matchup_result"
            }
        }
        let payload = Payload(
            leagueId: leagueID, memberId: memberID, week: week,
            totalPoints: totalPoints, scoringPlayerIds: scoringPlayerIDs,
            playerPoints: playerPoints, playerStats: playerStats,
            opponentMemberId: opponentMemberID, matchupResult: matchupResult
        )
        try await requestNoResponse(url: url, method: "POST", body: payload, bearerToken: accessToken, preferUpsert: true)
    }

    // MARK: - Best Ball Standings

    func fetchStandings(leagueID: String, accessToken: String) async throws -> [BestBallStandingRecord] {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/bestball_standings"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "league_id", value: "eq.\(leagueID)"),
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "order", value: "rank.asc")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        return try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    func upsertStanding(
        leagueID: String, memberID: String, totalPoints: Double, weeksScored: Int, rank: Int,
        wins: Int = 0, losses: Int = 0,
        accessToken: String
    ) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/bestball_standings"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "on_conflict", value: "league_id,member_id")]
        guard let url = components?.url else { throw URLError(.badURL) }
        struct Payload: Codable {
            let leagueId: String
            let memberId: String
            let totalPoints: Double
            let weeksScored: Int
            let rank: Int
            let wins: Int
            let losses: Int
            enum CodingKeys: String, CodingKey {
                case leagueId = "league_id"
                case memberId = "member_id"
                case totalPoints = "total_points"
                case weeksScored = "weeks_scored"
                case rank, wins, losses
            }
        }
        try await requestNoResponse(
            url: url, method: "POST",
            body: Payload(leagueId: leagueID, memberId: memberID, totalPoints: totalPoints, weeksScored: weeksScored, rank: rank, wins: wins, losses: losses),
            bearerToken: accessToken, preferUpsert: true
        )
    }

    // MARK: - Best Ball Schedule

    func updateLeagueSchedule(leagueID: String, schedule: [[[String]]], weekStructure: String, accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/bestball_leagues"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(leagueID)")]
        guard let url = components?.url else { throw URLError(.badURL) }
        struct Payload: Codable {
            let schedule: [[[String]]]
            let weekStructure: String
            enum CodingKeys: String, CodingKey {
                case schedule
                case weekStructure = "week_structure"
            }
        }
        try await requestNoResponse(url: url, method: "PATCH", body: Payload(schedule: schedule, weekStructure: weekStructure), bearerToken: accessToken)
    }

    // MARK: - Best Ball Daily Scores

    func upsertDailyScore(
        leagueID: String, memberID: String, week: Int, gameDate: String,
        playerPoints: [String: Double], playerStats: [String: [String: Double]],
        accessToken: String
    ) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/bestball_daily_scores"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "on_conflict", value: "league_id,member_id,week,game_date")]
        guard let url = components?.url else { throw URLError(.badURL) }
        struct Payload: Codable {
            let leagueId: String
            let memberId: String
            let week: Int
            let gameDate: String
            let playerPoints: [String: Double]
            let playerStats: [String: [String: Double]]
            enum CodingKeys: String, CodingKey {
                case leagueId = "league_id"
                case memberId = "member_id"
                case week
                case gameDate = "game_date"
                case playerPoints = "player_points"
                case playerStats = "player_stats"
            }
        }
        try await requestNoResponse(
            url: url, method: "POST",
            body: Payload(leagueId: leagueID, memberId: memberID, week: week, gameDate: gameDate, playerPoints: playerPoints, playerStats: playerStats),
            bearerToken: accessToken, preferUpsert: true
        )
    }

    /// Batch upsert weekly scores — sends all members' scores in a single POST.
    func batchUpsertWeeklyScores(
        leagueID: String, week: Int,
        memberScores: [(memberID: String, totalPoints: Double, scoringPlayerIDs: [String],
                         playerPoints: [String: Double], playerStats: [String: [String: Double]],
                         opponentMemberID: String?, matchupResult: String?)],
        accessToken: String
    ) async throws {
        guard !memberScores.isEmpty else { return }
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/bestball_weekly_scores"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "on_conflict", value: "league_id,member_id,week")]
        guard let url = components?.url else { throw URLError(.badURL) }
        struct Payload: Codable {
            let leagueId: String
            let memberId: String
            let week: Int
            let totalPoints: Double
            let scoringPlayerIds: [String]
            let playerPoints: [String: Double]
            let playerStats: [String: [String: Double]]
            let opponentMemberId: String?
            let matchupResult: String?
            enum CodingKeys: String, CodingKey {
                case leagueId = "league_id"
                case memberId = "member_id"
                case week
                case totalPoints = "total_points"
                case scoringPlayerIds = "scoring_player_ids"
                case playerPoints = "player_points"
                case playerStats = "player_stats"
                case opponentMemberId = "opponent_member_id"
                case matchupResult = "matchup_result"
            }
        }
        let payloads = memberScores.map {
            Payload(leagueId: leagueID, memberId: $0.memberID, week: week,
                    totalPoints: $0.totalPoints, scoringPlayerIds: $0.scoringPlayerIDs,
                    playerPoints: $0.playerPoints, playerStats: $0.playerStats,
                    opponentMemberId: $0.opponentMemberID, matchupResult: $0.matchupResult)
        }
        try await requestNoResponse(url: url, method: "POST", body: payloads, bearerToken: accessToken, preferUpsert: true)
    }

    /// Batch upsert daily scores — sends all daily score rows in a single POST.
    func batchUpsertDailyScores(
        entries: [(leagueID: String, memberID: String, week: Int, gameDate: String,
                    playerPoints: [String: Double], playerStats: [String: [String: Double]])],
        accessToken: String
    ) async throws {
        guard !entries.isEmpty else { return }
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/bestball_daily_scores"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "on_conflict", value: "league_id,member_id,week,game_date")]
        guard let url = components?.url else { throw URLError(.badURL) }
        struct Payload: Codable {
            let leagueId: String
            let memberId: String
            let week: Int
            let gameDate: String
            let playerPoints: [String: Double]
            let playerStats: [String: [String: Double]]
            enum CodingKeys: String, CodingKey {
                case leagueId = "league_id"
                case memberId = "member_id"
                case week
                case gameDate = "game_date"
                case playerPoints = "player_points"
                case playerStats = "player_stats"
            }
        }
        let payloads = entries.map {
            Payload(leagueId: $0.leagueID, memberId: $0.memberID, week: $0.week,
                    gameDate: $0.gameDate, playerPoints: $0.playerPoints, playerStats: $0.playerStats)
        }
        try await requestNoResponse(url: url, method: "POST", body: payloads, bearerToken: accessToken, preferUpsert: true)
    }

    /// Batch upsert standings — sends all standings rows in a single POST.
    func batchUpsertStandings(
        standings: [(leagueID: String, memberID: String, totalPoints: Double, weeksScored: Int, rank: Int, wins: Int, losses: Int)],
        accessToken: String
    ) async throws {
        guard !standings.isEmpty else { return }
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/bestball_standings"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "on_conflict", value: "league_id,member_id")]
        guard let url = components?.url else { throw URLError(.badURL) }
        struct Payload: Codable {
            let leagueId: String
            let memberId: String
            let totalPoints: Double
            let weeksScored: Int
            let rank: Int
            let wins: Int
            let losses: Int
            enum CodingKeys: String, CodingKey {
                case leagueId = "league_id"
                case memberId = "member_id"
                case totalPoints = "total_points"
                case weeksScored = "weeks_scored"
                case rank, wins, losses
            }
        }
        let payloads = standings.map {
            Payload(leagueId: $0.leagueID, memberId: $0.memberID, totalPoints: $0.totalPoints,
                    weeksScored: $0.weeksScored, rank: $0.rank, wins: $0.wins, losses: $0.losses)
        }
        try await requestNoResponse(url: url, method: "POST", body: payloads, bearerToken: accessToken, preferUpsert: true)
    }

    func fetchDailyScores(leagueID: String, week: Int, accessToken: String) async throws -> [BestBallDailyScoreRecord] {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/bestball_daily_scores"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "league_id", value: "eq.\(leagueID)"),
            URLQueryItem(name: "week", value: "eq.\(week)"),
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "order", value: "game_date.asc")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        return try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    // MARK: - Pick'em Picks

    func upsertPick(userID: String, matchID: String, pickedTeam: String, matchName: String, gainRR: Int, lossRR: Int, accessToken: String) async throws {
        let url = SupabaseConfig.url.appending(path: "/rest/v1/pickem_picks")
        struct Payload: Codable {
            let userId: String
            let matchId: String
            let pickedTeam: String
            let matchName: String
            let gainRr: Int
            let lossRr: Int
            enum CodingKeys: String, CodingKey {
                case userId = "user_id"
                case matchId = "match_id"
                case pickedTeam = "picked_team"
                case matchName = "match_name"
                case gainRr = "gain_rr"
                case lossRr = "loss_rr"
            }
        }
        try await requestNoResponse(
            url: url, method: "POST",
            body: Payload(userId: userID, matchId: matchID, pickedTeam: pickedTeam, matchName: matchName, gainRr: gainRR, lossRr: lossRR),
            bearerToken: accessToken,
            preferUpsert: true
        )
    }

    func deletePick(userID: String, matchID: String, accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/pickem_picks"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "user_id", value: "eq.\(userID)"),
            URLQueryItem(name: "match_id", value: "eq.\(matchID)")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        try await requestNoResponse(url: url, method: "DELETE", body: Optional<String>.none, bearerToken: accessToken)
    }

    /// Settle a pick. Returns `true` if the pick was actually settled, `false` if already settled by another client.
    @discardableResult
    func settlePick(userID: String, matchID: String, result: String, rrDelta: Int, accessToken: String) async throws -> Bool {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/pickem_picks"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "user_id", value: "eq.\(userID)"),
            URLQueryItem(name: "match_id", value: "eq.\(matchID)"),
            URLQueryItem(name: "result", value: "is.null")  // Only settle unsettled picks
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        struct Payload: Codable {
            let result: String
            let rrDelta: Int
            let settledAt: String
            enum CodingKeys: String, CodingKey {
                case result
                case rrDelta = "rr_delta"
                case settledAt = "settled_at"
            }
        }
        let iso = ISO8601DateFormatter()
        let rows: [SettledPickRecord] = try await request(
            url: url, method: "PATCH",
            body: Payload(result: result, rrDelta: rrDelta, settledAt: iso.string(from: Date())),
            bearerToken: accessToken,
            preferReturn: "representation"
        )
        return !rows.isEmpty
    }

    func fetchUserPicks(userID: String, accessToken: String) async throws -> [PickemPickRecord] {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/pickem_picks"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "user_id", value: "eq.\(userID)"),
            URLQueryItem(name: "result", value: "is.null"),
            URLQueryItem(name: "select", value: "match_id,picked_team,match_name,gain_rr,loss_rr")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        return try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    func fetchSettledPicks(userID: String, limit: Int = 50, offset: Int = 0, accessToken: String) async throws -> [SettledPickRecord] {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/pickem_picks"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "user_id", value: "eq.\(userID)"),
            URLQueryItem(name: "result", value: "neq.null"),
            URLQueryItem(name: "select", value: "match_id,picked_team,match_name,gain_rr,loss_rr,result,rr_delta,settled_at,created_at"),
            URLQueryItem(name: "order", value: "settled_at.desc"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        return try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    func fetchActivePicks(userID: String, accessToken: String) async throws -> [ActivePickRecord] {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/pickem_picks"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "user_id", value: "eq.\(userID)"),
            URLQueryItem(name: "result", value: "is.null"),
            URLQueryItem(name: "select", value: "match_id,picked_team,match_name,gain_rr,loss_rr,created_at")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        return try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    /// Fetch ALL unsettled picks across all users (for global settlement)
    func fetchAllUnsettledPicks(accessToken: String) async throws -> [UnsettledPickRecord] {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/pickem_picks"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "result", value: "is.null"),
            URLQueryItem(name: "select", value: "user_id,match_id,picked_team,match_name,gain_rr,loss_rr,created_at")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        return try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    private func request<T: Decodable, Body: Encodable>(
        url: URL,
        method: String,
        body: Body?,
        bearerToken: String?,
        preferUpsert: Bool = false,
        preferReturn: String? = nil
    ) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        var preferParts: [String] = []
        if preferUpsert { preferParts.append("resolution=merge-duplicates") }
        if let preferReturn { preferParts.append("return=\(preferReturn)") }
        if !preferParts.isEmpty {
            request.setValue(preferParts.joined(separator: ","), forHTTPHeaderField: "Prefer")
        }
        if let body {
            request.httpBody = try JSONEncoder.supabaseEncoder.encode(body)
        }

        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse

        // Auto-refresh on 401 and retry once
        if http?.statusCode == 401, bearerToken != nil, let refresher = tokenRefreshProvider {
            if let freshToken = await refresher() {
                request.setValue("Bearer \(freshToken)", forHTTPHeaderField: "Authorization")
                let (retryData, retryResponse) = try await session.data(for: request)
                guard let retryHttp = retryResponse as? HTTPURLResponse, (200..<300).contains(retryHttp.statusCode) else {
                    let message = String(data: retryData, encoding: .utf8) ?? "unknown"
                    throw NSError(domain: "Supabase", code: (retryResponse as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: message])
                }
                if retryData.isEmpty, let empty = [] as? T { return empty }
                return try JSONDecoder.supabaseDecoder.decode(T.self, from: retryData)
            }
        }

        guard let http, (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "unknown"
            throw NSError(domain: "Supabase", code: http?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        if data.isEmpty, let empty = [] as? T {
            return empty
        }
        return try JSONDecoder.supabaseDecoder.decode(T.self, from: data)
    }

    private func requestData<Body: Encodable>(
        url: URL,
        method: String,
        body: Body?,
        bearerToken: String?,
        preferUpsert: Bool = false
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        if preferUpsert {
            request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        }
        if let body {
            request.httpBody = try JSONEncoder.supabaseEncoder.encode(body)
        }

        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse

        // Auto-refresh on 401 and retry once
        if http?.statusCode == 401, bearerToken != nil, let refresher = tokenRefreshProvider {
            if let freshToken = await refresher() {
                request.setValue("Bearer \(freshToken)", forHTTPHeaderField: "Authorization")
                let (retryData, retryResponse) = try await session.data(for: request)
                guard let retryHttp = retryResponse as? HTTPURLResponse, (200..<300).contains(retryHttp.statusCode) else {
                    let message = String(data: retryData, encoding: .utf8) ?? "unknown"
                    throw NSError(domain: "Supabase", code: (retryResponse as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: message])
                }
                return retryData
            }
        }

        guard let http, (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "unknown"
            throw NSError(domain: "Supabase", code: http?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return data
    }

    private func authSession(from envelope: SupabaseAuthEnvelope) -> SupabaseAuthSession? {
        if let accessToken = envelope.accessToken, let user = envelope.user {
            return SupabaseAuthSession(accessToken: accessToken, refreshToken: envelope.refreshToken, user: user)
        }
        if let nested = envelope.session,
           let accessToken = nested.accessToken,
           let user = nested.user {
            return SupabaseAuthSession(accessToken: accessToken, refreshToken: nested.refreshToken, user: user)
        }
        return nil
    }

    private func parseAuthPayload(_ data: Data) -> (session: SupabaseAuthSession?, hasUser: Bool, identitiesEmpty: Bool, message: String?) {
        if let envelope = try? JSONDecoder.supabaseDecoder.decode(SupabaseAuthEnvelope.self, from: data),
           let session = authSession(from: envelope) {
            return (session, true, false, nil)
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, false, false, nil)
        }
        let root = (object["data"] as? [String: Any]) ?? object

        let sessionDict = (root["session"] as? [String: Any]) ?? root
        let userDict = (sessionDict["user"] as? [String: Any]) ?? (root["user"] as? [String: Any])

        if let accessToken = sessionDict["access_token"] as? String,
           let userID = (userDict?["id"] as? String ?? userDict?["sub"] as? String) {
            let refreshToken = sessionDict["refresh_token"] as? String
            let user = SupabaseAuthUser(id: userID, email: userDict?["email"] as? String)
            return (SupabaseAuthSession(accessToken: accessToken, refreshToken: refreshToken, user: user), true, false, nil)
        }

        let message = (root["msg"] as? String)
            ?? (root["message"] as? String)
            ?? (root["error_description"] as? String)
            ?? (root["error"] as? String)
        // Supabase signup with email confirmation returns the user object at root level
        // (no "user" wrapper, no access_token). Detect this by checking for "id" + "email".
        let hasUser = userDict != nil
            || (root["id"] as? String != nil && root["email"] as? String != nil)

        // Detect already-confirmed user: Supabase returns user with empty identities array
        let userNode = userDict ?? (hasUser ? root : nil)
        let identities = userNode?["identities"] as? [[String: Any]]
        let identitiesEmpty = hasUser && (identities?.isEmpty == true)

        return (nil, hasUser, identitiesEmpty, message)
    }

    // MARK: - Chat

    func fetchRecentMessages(leagueId: String? = nil, limit: Int = 50, accessToken: String) async throws -> [ChatMessageRecord] {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/chat_messages"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "select", value: "id,user_id,username,body,created_at,league_id"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]
        // Filter by league: null = All Chat, non-null = league-specific
        if let leagueId {
            components?.queryItems?.append(URLQueryItem(name: "league_id", value: "eq.\(leagueId)"))
        } else {
            components?.queryItems?.append(URLQueryItem(name: "league_id", value: "is.null"))
        }
        guard let url = components?.url else { throw URLError(.badURL) }
        let messages: [ChatMessageRecord] = try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
        return messages.reversed()  // oldest first for display
    }

    /// Deterministic DM conversation ID for two users
    static func dmConversationID(userA: String, userB: String) -> String {
        let sorted = [userA, userB].sorted()
        return "dm-\(sorted[0])-\(sorted[1])"
    }

    /// Fetch the most recent message from each DM conversation the user is involved in
    func fetchDMConversations(userID: String, accessToken: String) async throws -> [ChatMessageRecord] {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/chat_messages"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "select", value: "id,user_id,username,body,created_at,league_id"),
            URLQueryItem(name: "league_id", value: "like.dm-*"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: "100")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        let messages: [ChatMessageRecord] = try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)

        // Keep only conversations involving this user, deduplicate by league_id (most recent first)
        var seen = Set<String>()
        return messages.filter { msg in
            guard let lid = msg.leagueId, lid.contains(userID) else { return false }
            return seen.insert(lid).inserted
        }
    }

    /// Fetch the latest message timestamp for each given chat room (by league_id).
    /// Pass `nil` inside the array to query "All Chat" (league_id IS NULL).
    func fetchLatestMessageDates(leagueIds: [String?], accessToken: String) async throws -> [String?: Date] {
        var result: [String?: Date] = [:]
        // Fetch in parallel-ish — one request per room, but they're tiny (limit 1)
        await withTaskGroup(of: (String?, Date?).self) { group in
            for lid in leagueIds {
                group.addTask {
                    var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/chat_messages"), resolvingAgainstBaseURL: false)
                    components?.queryItems = [
                        URLQueryItem(name: "select", value: "created_at"),
                        URLQueryItem(name: "order", value: "created_at.desc"),
                        URLQueryItem(name: "limit", value: "1")
                    ]
                    if let lid {
                        components?.queryItems?.append(URLQueryItem(name: "league_id", value: "eq.\(lid)"))
                    } else {
                        components?.queryItems?.append(URLQueryItem(name: "league_id", value: "is.null"))
                    }
                    guard let url = components?.url else { return (lid, nil) }
                    struct Row: Codable { let createdAt: Date; enum CodingKeys: String, CodingKey { case createdAt = "created_at" } }
                    let rows: [Row]? = try? await self.request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
                    return (lid, rows?.first?.createdAt)
                }
            }
            for await (lid, date) in group {
                if let date { result[lid] = date }
            }
        }
        return result
    }

    func sendMessage(userId: String, username: String, body: String, leagueId: String? = nil, accessToken: String) async throws {
        let url = SupabaseConfig.url.appending(path: "/rest/v1/chat_messages")
        struct Payload: Codable {
            let userId: String
            let username: String
            let body: String
            let leagueId: String?
            enum CodingKeys: String, CodingKey {
                case userId = "user_id"
                case username
                case body
                case leagueId = "league_id"
            }
        }
        let payload = Payload(userId: userId, username: username, body: body, leagueId: leagueId)
        try await requestNoResponse(url: url, method: "POST", body: payload, bearerToken: accessToken)
    }

    // MARK: - Playoff Tiers CRUD

    func upsertPlayoffTiersTournament(record: PlayoffTiersTournamentRecord, accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/playoff_tiers_tournaments"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "on_conflict", value: "id")]
        guard let url = components?.url else { throw URLError(.badURL) }
        try await requestNoResponse(url: url, method: "POST", body: [record], bearerToken: accessToken, preferUpsert: true)
    }

    func fetchPlayoffTiersTournament(tournamentID: String, accessToken: String) async throws -> PlayoffTiersTournamentRecord? {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/playoff_tiers_tournaments"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(tournamentID)"),
            URLQueryItem(name: "select", value: "*")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        let results: [PlayoffTiersTournamentRecord] = try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
        return results.first
    }

    func submitPlayoffTiersEntry(
        tournamentID: String,
        userID: String,
        entryName: String,
        picks: [PlayoffTiersPickData],
        accessToken: String
    ) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/playoff_tiers_entries"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "on_conflict", value: "tournament_id,user_id")]
        guard let url = components?.url else { throw URLError(.badURL) }
        struct Payload: Codable {
            let tournamentID: String
            let userID: String
            let entryName: String
            let picks: [PlayoffTiersPickData]
            enum CodingKeys: String, CodingKey {
                case tournamentID = "tournament_id"
                case userID = "user_id"
                case entryName = "entry_name"
                case picks
            }
        }
        let payload = [Payload(tournamentID: tournamentID, userID: userID, entryName: entryName, picks: picks)]
        try await requestNoResponse(url: url, method: "POST", body: payload, bearerToken: accessToken, preferUpsert: true)
    }

    /// Batch-insert bot entries into the playoff_tiers_entries table.
    /// Inserts in chunks to avoid request-size limits.
    func batchInsertPlayoffTiersBotEntries(
        tournamentID: String,
        bots: [(name: String, picks: [PlayoffTiersPickData])],
        accessToken: String
    ) async throws {
        let url = SupabaseConfig.url.appending(path: "/rest/v1/playoff_tiers_entries")
        struct BotPayload: Codable {
            let tournamentID: String
            let entryName: String
            let picks: [PlayoffTiersPickData]
            let isBot: Bool
            enum CodingKeys: String, CodingKey {
                case tournamentID = "tournament_id"
                case entryName = "entry_name"
                case picks
                case isBot = "is_bot"
            }
        }
        let chunkSize = 100
        for startIndex in stride(from: 0, to: bots.count, by: chunkSize) {
            let endIndex = min(startIndex + chunkSize, bots.count)
            let chunk = bots[startIndex..<endIndex]
            let payload = chunk.map { bot in
                BotPayload(tournamentID: tournamentID, entryName: bot.name, picks: bot.picks, isBot: true)
            }
            try await requestNoResponse(url: url, method: "POST", body: payload, bearerToken: accessToken)
        }
    }

    /// Delete all bot entries for a tournament (used before re-inserting fresh bots).
    func deletePlayoffTiersBotEntries(tournamentID: String, accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/playoff_tiers_entries"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "tournament_id", value: "eq.\(tournamentID)"),
            URLQueryItem(name: "is_bot", value: "eq.true")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        try await requestNoResponse(url: url, method: "DELETE", body: Optional<String>.none, bearerToken: accessToken)
    }

    func fetchPlayoffTiersEntries(tournamentID: String, accessToken: String) async throws -> [PlayoffTiersEntryRecord] {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/playoff_tiers_entries"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "tournament_id", value: "eq.\(tournamentID)"),
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "order", value: "total_points.desc"),
            URLQueryItem(name: "limit", value: "1100")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        return try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    func fetchUserPlayoffTiersEntry(tournamentID: String, userID: String, accessToken: String) async throws -> PlayoffTiersEntryRecord? {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/playoff_tiers_entries"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "tournament_id", value: "eq.\(tournamentID)"),
            URLQueryItem(name: "user_id", value: "eq.\(userID)"),
            URLQueryItem(name: "select", value: "*")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        let results: [PlayoffTiersEntryRecord] = try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
        return results.first
    }

    func updatePlayoffTiersEntryScores(entries: [(id: String, totalPoints: Double, rank: Int)], accessToken: String) async throws {
        for entry in entries {
            var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/playoff_tiers_entries"), resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(entry.id)")]
            guard let url = components?.url else { continue }
            struct Payload: Codable {
                let totalPoints: Double
                let rank: Int
                enum CodingKeys: String, CodingKey {
                    case totalPoints = "total_points"
                    case rank
                }
            }
            try await requestNoResponse(url: url, method: "PATCH", body: Payload(totalPoints: entry.totalPoints, rank: entry.rank), bearerToken: accessToken)
        }
    }

    func savePlayoffTiersBotField(tournamentID: String, botField: [[String: Any]], accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/playoff_tiers_tournaments"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(tournamentID)")]
        guard let url = components?.url else { throw URLError(.badURL) }
        // Use raw JSON since bot_field contains [[String: Any]]
        guard JSONSerialization.isValidJSONObject(botField) else { throw URLError(.badURL) }
        let botFieldData = try JSONSerialization.data(withJSONObject: botField)
        let botFieldJSON = String(data: botFieldData, encoding: .utf8) ?? "[]"
        let bodyString = "{\"bot_field\":\(botFieldJSON)}"
        guard let bodyData = bodyString.data(using: .utf8) else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) || http.statusCode == 204 else {
            throw NSError(domain: "Supabase", code: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    /// Fetch the bot_field JSON directly for a Playoff Tiers tournament.
    /// Returns raw [[String: Any]] since bot_field isn't Codable via the standard record decoder.
    func fetchPlayoffTiersBotField(tournamentID: String, accessToken: String) async throws -> [[String: Any]] {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/playoff_tiers_tournaments"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(tournamentID)"),
            URLQueryItem(name: "select", value: "bot_field")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            print("[SupabaseService] fetchPlayoffTiersBotField HTTP \(status)")
            return []
        }
        print("[SupabaseService] fetchPlayoffTiersBotField response: \(data.count) bytes")
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = rows.first,
              let botField = first["bot_field"] as? [[String: Any]] else {
            // Log what we actually got to diagnose parse failures
            if let preview = String(data: data.prefix(500), encoding: .utf8) {
                print("[SupabaseService] fetchPlayoffTiersBotField parse failed, preview: \(preview)")
            }
            return []
        }
        return botField
    }

    func updatePlayoffTiersTournamentStatus(tournamentID: String, status: String, accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/playoff_tiers_tournaments"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(tournamentID)")]
        guard let url = components?.url else { throw URLError(.badURL) }
        struct Payload: Codable { let status: String }
        try await requestNoResponse(url: url, method: "PATCH", body: Payload(status: status), bearerToken: accessToken)
    }

    func markPlayoffTiersTournamentSettled(tournamentID: String, accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/playoff_tiers_tournaments"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(tournamentID)")]
        guard let url = components?.url else { throw URLError(.badURL) }
        struct Payload: Codable {
            let status: String
            let isSettled: Bool
            enum CodingKeys: String, CodingKey {
                case status
                case isSettled = "is_settled"
            }
        }
        try await requestNoResponse(url: url, method: "PATCH", body: Payload(status: "settled", isSettled: true), bearerToken: accessToken)
    }

    // MARK: - Playoff Tiers Groups

    func createPlayoffTiersGroup(
        tournamentID: String,
        name: String,
        createdBy: String,
        inviteCode: String,
        maxMembers: Int,
        accessToken: String
    ) async throws -> PlayoffTiersGroupRecord {
        let url = SupabaseConfig.url.appending(path: "/rest/v1/playoff_tiers_groups")
        struct Payload: Codable {
            let tournamentID: String
            let name: String
            let createdBy: String
            let inviteCode: String
            let maxMembers: Int
            enum CodingKeys: String, CodingKey {
                case name
                case tournamentID = "tournament_id"
                case createdBy = "created_by"
                case inviteCode = "invite_code"
                case maxMembers = "max_members"
            }
        }
        let payload = Payload(tournamentID: tournamentID, name: name, createdBy: createdBy, inviteCode: inviteCode, maxMembers: maxMembers)
        let results: [PlayoffTiersGroupRecord] = try await request(url: url, method: "POST", body: payload, bearerToken: accessToken, preferReturn: "representation")
        guard let group = results.first else {
            throw NSError(domain: "Supabase", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create group"])
        }
        return group
    }

    func fetchMyPlayoffTiersGroups(userID: String, tournamentID: String, accessToken: String) async throws -> [PlayoffTiersGroupRecord] {
        // Fetch group IDs the user is a member of
        let membersURL = SupabaseConfig.url.appending(path: "/rest/v1/playoff_tiers_group_members")
            .appending(queryItems: [
                URLQueryItem(name: "user_id", value: "eq.\(userID)"),
                URLQueryItem(name: "select", value: "group_id")
            ])
        let memberships: [PlayoffTiersGroupMemberRecord] = try await request(url: membersURL, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
        guard !memberships.isEmpty else { return [] }

        let groupIDs = memberships.map { $0.groupID }
        // Fetch groups that match these IDs and the tournament
        let groupsURL = SupabaseConfig.url.appending(path: "/rest/v1/playoff_tiers_groups")
            .appending(queryItems: [
                URLQueryItem(name: "id", value: "in.(\(groupIDs.joined(separator: ",")))"),
                URLQueryItem(name: "tournament_id", value: "eq.\(tournamentID)"),
                URLQueryItem(name: "select", value: "*"),
                URLQueryItem(name: "order", value: "created_at.desc")
            ])
        return try await request(url: groupsURL, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    func fetchPlayoffTiersGroupByInviteCode(code: String, accessToken: String) async throws -> PlayoffTiersGroupRecord? {
        let url = SupabaseConfig.url.appending(path: "/rest/v1/playoff_tiers_groups")
            .appending(queryItems: [
                URLQueryItem(name: "invite_code", value: "eq.\(code)"),
                URLQueryItem(name: "select", value: "*")
            ])
        let results: [PlayoffTiersGroupRecord] = try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
        return results.first
    }

    func joinPlayoffTiersGroup(groupID: String, userID: String, displayName: String, accessToken: String) async throws {
        let url = SupabaseConfig.url.appending(path: "/rest/v1/playoff_tiers_group_members")
        struct Payload: Codable {
            let groupID: String
            let userID: String
            let displayName: String
            enum CodingKeys: String, CodingKey {
                case groupID = "group_id"
                case userID = "user_id"
                case displayName = "display_name"
            }
        }
        try await requestNoResponse(url: url, method: "POST", body: Payload(groupID: groupID, userID: userID, displayName: displayName), bearerToken: accessToken, preferUpsert: true)
    }

    func fetchPlayoffTiersGroupMembers(groupID: String, accessToken: String) async throws -> [PlayoffTiersGroupMemberRecord] {
        let url = SupabaseConfig.url.appending(path: "/rest/v1/playoff_tiers_group_members")
            .appending(queryItems: [
                URLQueryItem(name: "group_id", value: "eq.\(groupID)"),
                URLQueryItem(name: "select", value: "*"),
                URLQueryItem(name: "order", value: "joined_at.asc")
            ])
        return try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    func leavePlayoffTiersGroup(groupID: String, userID: String, accessToken: String) async throws {
        let url = SupabaseConfig.url.appending(path: "/rest/v1/playoff_tiers_group_members")
            .appending(queryItems: [
                URLQueryItem(name: "group_id", value: "eq.\(groupID)"),
                URLQueryItem(name: "user_id", value: "eq.\(userID)")
            ])
        try await requestNoResponse(url: url, method: "DELETE", body: Optional<String>.none, bearerToken: accessToken)
    }

    func deletePlayoffTiersGroup(groupID: String, accessToken: String) async throws {
        let url = SupabaseConfig.url.appending(path: "/rest/v1/playoff_tiers_groups")
            .appending(queryItems: [
                URLQueryItem(name: "id", value: "eq.\(groupID)")
            ])
        try await requestNoResponse(url: url, method: "DELETE", body: Optional<String>.none, bearerToken: accessToken)
    }

    func fetchPlayoffTiersGroupMemberCount(groupID: String, accessToken: String) async throws -> Int {
        let url = SupabaseConfig.url.appending(path: "/rest/v1/playoff_tiers_group_members")
            .appending(queryItems: [
                URLQueryItem(name: "group_id", value: "eq.\(groupID)"),
                URLQueryItem(name: "select", value: "id")
            ])
        let results: [PlayoffTiersGroupMemberRecord] = try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
        return results.count
    }

    // MARK: - Soccer Tiers CRUD

    func upsertSoccerTiersTournament(record: SoccerTiersTournamentRecord, accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/soccer_tiers_tournaments"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "on_conflict", value: "id")]
        guard let url = components?.url else { throw URLError(.badURL) }
        try await requestNoResponse(url: url, method: "POST", body: [record], bearerToken: accessToken, preferUpsert: true)
    }

    func fetchSoccerTiersTournament(tournamentID: String, accessToken: String) async throws -> SoccerTiersTournamentRecord? {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/soccer_tiers_tournaments"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(tournamentID)"),
            URLQueryItem(name: "select", value: "*")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        let results: [SoccerTiersTournamentRecord] = try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
        return results.first
    }

    func submitSoccerTiersEntry(
        tournamentID: String,
        userID: String,
        entryName: String,
        picks: [SoccerTiersPickData],
        accessToken: String
    ) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/soccer_tiers_entries"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "on_conflict", value: "tournament_id,user_id")]
        guard let url = components?.url else { throw URLError(.badURL) }
        struct Payload: Codable {
            let tournamentID: String
            let userID: String
            let entryName: String
            let picks: [SoccerTiersPickData]
            enum CodingKeys: String, CodingKey {
                case tournamentID = "tournament_id"
                case userID = "user_id"
                case entryName = "entry_name"
                case picks
            }
        }
        let payload = [Payload(tournamentID: tournamentID, userID: userID, entryName: entryName, picks: picks)]
        try await requestNoResponse(url: url, method: "POST", body: payload, bearerToken: accessToken, preferUpsert: true)
    }

    /// Batch-insert bot entries into the soccer_tiers_entries table.
    /// Inserts in chunks to avoid request-size limits.
    func batchInsertSoccerTiersBotEntries(
        tournamentID: String,
        bots: [(name: String, picks: [SoccerTiersPickData])],
        accessToken: String
    ) async throws {
        let url = SupabaseConfig.url.appending(path: "/rest/v1/soccer_tiers_entries")
        struct BotPayload: Codable {
            let tournamentID: String
            let entryName: String
            let picks: [SoccerTiersPickData]
            let isBot: Bool
            enum CodingKeys: String, CodingKey {
                case tournamentID = "tournament_id"
                case entryName = "entry_name"
                case picks
                case isBot = "is_bot"
            }
        }
        let chunkSize = 100
        for startIndex in stride(from: 0, to: bots.count, by: chunkSize) {
            let endIndex = min(startIndex + chunkSize, bots.count)
            let chunk = bots[startIndex..<endIndex]
            let payload = chunk.map { bot in
                BotPayload(tournamentID: tournamentID, entryName: bot.name, picks: bot.picks, isBot: true)
            }
            try await requestNoResponse(url: url, method: "POST", body: payload, bearerToken: accessToken)
        }
    }

    /// Delete all bot entries for a tournament (used before re-inserting fresh bots).
    func deleteSoccerTiersBotEntries(tournamentID: String, accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/soccer_tiers_entries"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "tournament_id", value: "eq.\(tournamentID)"),
            URLQueryItem(name: "is_bot", value: "eq.true")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        try await requestNoResponse(url: url, method: "DELETE", body: Optional<String>.none, bearerToken: accessToken)
    }

    func fetchSoccerTiersEntries(tournamentID: String, accessToken: String) async throws -> [SoccerTiersEntryRecord] {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/soccer_tiers_entries"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "tournament_id", value: "eq.\(tournamentID)"),
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "order", value: "total_points.desc"),
            URLQueryItem(name: "limit", value: "1100")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        return try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    func fetchUserSoccerTiersEntry(tournamentID: String, userID: String, accessToken: String) async throws -> SoccerTiersEntryRecord? {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/soccer_tiers_entries"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "tournament_id", value: "eq.\(tournamentID)"),
            URLQueryItem(name: "user_id", value: "eq.\(userID)"),
            URLQueryItem(name: "select", value: "*")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        let results: [SoccerTiersEntryRecord] = try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
        return results.first
    }

    func updateSoccerTiersEntryScores(entries: [(id: String, totalPoints: Double, rank: Int)], accessToken: String) async throws {
        for entry in entries {
            var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/soccer_tiers_entries"), resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(entry.id)")]
            guard let url = components?.url else { continue }
            struct Payload: Codable {
                let totalPoints: Double
                let rank: Int
                enum CodingKeys: String, CodingKey {
                    case totalPoints = "total_points"
                    case rank
                }
            }
            try await requestNoResponse(url: url, method: "PATCH", body: Payload(totalPoints: entry.totalPoints, rank: entry.rank), bearerToken: accessToken)
        }
    }

    func saveSoccerTiersBotField(tournamentID: String, botField: [[String: Any]], accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/soccer_tiers_tournaments"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(tournamentID)")]
        guard let url = components?.url else { throw URLError(.badURL) }
        // Use raw JSON since bot_field contains [[String: Any]]
        guard JSONSerialization.isValidJSONObject(botField) else { throw URLError(.badURL) }
        let botFieldData = try JSONSerialization.data(withJSONObject: botField)
        let botFieldJSON = String(data: botFieldData, encoding: .utf8) ?? "[]"
        let bodyString = "{\"bot_field\":\(botFieldJSON)}"
        guard let bodyData = bodyString.data(using: .utf8) else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) || http.statusCode == 204 else {
            throw NSError(domain: "Supabase", code: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    /// Fetch the bot_field JSON directly for a Soccer Tiers tournament.
    /// Returns raw [[String: Any]] since bot_field isn't Codable via the standard record decoder.
    func fetchSoccerTiersBotField(tournamentID: String, accessToken: String) async throws -> [[String: Any]] {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/soccer_tiers_tournaments"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(tournamentID)"),
            URLQueryItem(name: "select", value: "bot_field")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            print("[SupabaseService] fetchSoccerTiersBotField HTTP \(status)")
            return []
        }
        print("[SupabaseService] fetchSoccerTiersBotField response: \(data.count) bytes")
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = rows.first,
              let botField = first["bot_field"] as? [[String: Any]] else {
            // Log what we actually got to diagnose parse failures
            if let preview = String(data: data.prefix(500), encoding: .utf8) {
                print("[SupabaseService] fetchSoccerTiersBotField parse failed, preview: \(preview)")
            }
            return []
        }
        return botField
    }

    func updateSoccerTiersTournamentStatus(tournamentID: String, status: String, accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/soccer_tiers_tournaments"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(tournamentID)")]
        guard let url = components?.url else { throw URLError(.badURL) }
        struct Payload: Codable { let status: String }
        try await requestNoResponse(url: url, method: "PATCH", body: Payload(status: status), bearerToken: accessToken)
    }

    func markSoccerTiersTournamentSettled(tournamentID: String, accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/soccer_tiers_tournaments"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(tournamentID)")]
        guard let url = components?.url else { throw URLError(.badURL) }
        struct Payload: Codable {
            let status: String
            let isSettled: Bool
            enum CodingKeys: String, CodingKey {
                case status
                case isSettled = "is_settled"
            }
        }
        try await requestNoResponse(url: url, method: "PATCH", body: Payload(status: "settled", isSettled: true), bearerToken: accessToken)
    }

    // MARK: - Soccer Tiers Groups

    func createSoccerTiersGroup(
        tournamentID: String,
        name: String,
        createdBy: String,
        inviteCode: String,
        maxMembers: Int,
        accessToken: String
    ) async throws -> SoccerTiersGroupRecord {
        let url = SupabaseConfig.url.appending(path: "/rest/v1/soccer_tiers_groups")
        struct Payload: Codable {
            let tournamentID: String
            let name: String
            let createdBy: String
            let inviteCode: String
            let maxMembers: Int
            enum CodingKeys: String, CodingKey {
                case name
                case tournamentID = "tournament_id"
                case createdBy = "created_by"
                case inviteCode = "invite_code"
                case maxMembers = "max_members"
            }
        }
        let payload = Payload(tournamentID: tournamentID, name: name, createdBy: createdBy, inviteCode: inviteCode, maxMembers: maxMembers)
        let results: [SoccerTiersGroupRecord] = try await request(url: url, method: "POST", body: payload, bearerToken: accessToken, preferReturn: "representation")
        guard let group = results.first else {
            throw NSError(domain: "Supabase", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create group"])
        }
        return group
    }

    func fetchMySoccerTiersGroups(userID: String, tournamentID: String, accessToken: String) async throws -> [SoccerTiersGroupRecord] {
        // Fetch group IDs the user is a member of
        let membersURL = SupabaseConfig.url.appending(path: "/rest/v1/soccer_tiers_group_members")
            .appending(queryItems: [
                URLQueryItem(name: "user_id", value: "eq.\(userID)"),
                URLQueryItem(name: "select", value: "group_id")
            ])
        let memberships: [SoccerTiersGroupMemberRecord] = try await request(url: membersURL, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
        guard !memberships.isEmpty else { return [] }

        let groupIDs = memberships.map { $0.groupID }
        // Fetch groups that match these IDs and the tournament
        let groupsURL = SupabaseConfig.url.appending(path: "/rest/v1/soccer_tiers_groups")
            .appending(queryItems: [
                URLQueryItem(name: "id", value: "in.(\(groupIDs.joined(separator: ",")))"),
                URLQueryItem(name: "tournament_id", value: "eq.\(tournamentID)"),
                URLQueryItem(name: "select", value: "*"),
                URLQueryItem(name: "order", value: "created_at.desc")
            ])
        return try await request(url: groupsURL, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    func fetchSoccerTiersGroupByInviteCode(code: String, accessToken: String) async throws -> SoccerTiersGroupRecord? {
        let url = SupabaseConfig.url.appending(path: "/rest/v1/soccer_tiers_groups")
            .appending(queryItems: [
                URLQueryItem(name: "invite_code", value: "eq.\(code)"),
                URLQueryItem(name: "select", value: "*")
            ])
        let results: [SoccerTiersGroupRecord] = try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
        return results.first
    }

    func joinSoccerTiersGroup(groupID: String, userID: String, displayName: String, accessToken: String) async throws {
        let url = SupabaseConfig.url.appending(path: "/rest/v1/soccer_tiers_group_members")
        struct Payload: Codable {
            let groupID: String
            let userID: String
            let displayName: String
            enum CodingKeys: String, CodingKey {
                case groupID = "group_id"
                case userID = "user_id"
                case displayName = "display_name"
            }
        }
        try await requestNoResponse(url: url, method: "POST", body: Payload(groupID: groupID, userID: userID, displayName: displayName), bearerToken: accessToken, preferUpsert: true)
    }

    func fetchSoccerTiersGroupMembers(groupID: String, accessToken: String) async throws -> [SoccerTiersGroupMemberRecord] {
        let url = SupabaseConfig.url.appending(path: "/rest/v1/soccer_tiers_group_members")
            .appending(queryItems: [
                URLQueryItem(name: "group_id", value: "eq.\(groupID)"),
                URLQueryItem(name: "select", value: "*"),
                URLQueryItem(name: "order", value: "joined_at.asc")
            ])
        return try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    func leaveSoccerTiersGroup(groupID: String, userID: String, accessToken: String) async throws {
        let url = SupabaseConfig.url.appending(path: "/rest/v1/soccer_tiers_group_members")
            .appending(queryItems: [
                URLQueryItem(name: "group_id", value: "eq.\(groupID)"),
                URLQueryItem(name: "user_id", value: "eq.\(userID)")
            ])
        try await requestNoResponse(url: url, method: "DELETE", body: Optional<String>.none, bearerToken: accessToken)
    }

    func deleteSoccerTiersGroup(groupID: String, accessToken: String) async throws {
        let url = SupabaseConfig.url.appending(path: "/rest/v1/soccer_tiers_groups")
            .appending(queryItems: [
                URLQueryItem(name: "id", value: "eq.\(groupID)")
            ])
        try await requestNoResponse(url: url, method: "DELETE", body: Optional<String>.none, bearerToken: accessToken)
    }

    func fetchSoccerTiersGroupMemberCount(groupID: String, accessToken: String) async throws -> Int {
        let url = SupabaseConfig.url.appending(path: "/rest/v1/soccer_tiers_group_members")
            .appending(queryItems: [
                URLQueryItem(name: "group_id", value: "eq.\(groupID)"),
                URLQueryItem(name: "select", value: "id")
            ])
        let results: [SoccerTiersGroupMemberRecord] = try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
        return results.count
    }

    // MARK: - Tennis Bracket Tournaments

    func upsertTennisBracketTournament(record: TennisBracketTournamentRecord, accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/tennis_bracket_tournaments"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "on_conflict", value: "id")]
        guard let url = components?.url else { throw URLError(.badURL) }
        try await requestNoResponse(url: url, method: "POST", body: [record], bearerToken: accessToken, preferUpsert: true)
    }

    func fetchTennisBracketTournament(tournamentID: String, accessToken: String) async throws -> TennisBracketTournamentRecord? {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/tennis_bracket_tournaments"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(tournamentID)"),
            URLQueryItem(name: "select", value: "id,title,grand_slam,draw_type,season,status,lock_time,entry_count,is_settled,created_at")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        let results: [TennisBracketTournamentRecord] = try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
        return results.first
    }

    func updateTennisBracketTournamentStatus(tournamentID: String, status: String, accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/tennis_bracket_tournaments"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(tournamentID)")]
        guard let url = components?.url else { throw URLError(.badURL) }
        struct Payload: Codable { let status: String }
        try await requestNoResponse(url: url, method: "PATCH", body: Payload(status: status), bearerToken: accessToken)
    }

    func markTennisBracketTournamentSettled(tournamentID: String, accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/tennis_bracket_tournaments"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(tournamentID)")]
        guard let url = components?.url else { throw URLError(.badURL) }
        struct Payload: Codable {
            let status: String
            let isSettled: Bool
            enum CodingKeys: String, CodingKey { case status; case isSettled = "is_settled" }
        }
        try await requestNoResponse(url: url, method: "PATCH", body: Payload(status: "settled", isSettled: true), bearerToken: accessToken)
    }

    /// Fetch draw_data JSON from a tennis bracket tournament.
    func fetchTennisBracketDrawData(tournamentID: String, accessToken: String) async throws -> [TennisBracketPlayer] {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/tennis_bracket_tournaments"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(tournamentID)"),
            URLQueryItem(name: "select", value: "draw_data")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [] }

        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = rows.first,
              let drawData = first["draw_data"] else { return [] }

        guard JSONSerialization.isValidJSONObject(drawData) else { return [] }
        let drawJSON = try JSONSerialization.data(withJSONObject: drawData)
        return (try? JSONDecoder().decode([TennisBracketPlayer].self, from: drawJSON)) ?? []
    }

    /// Fetch results_data JSON from a tennis bracket tournament.
    func fetchTennisBracketResults(tournamentID: String, accessToken: String) async throws -> [String: String] {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/tennis_bracket_tournaments"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(tournamentID)"),
            URLQueryItem(name: "select", value: "results_data")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [:] }

        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = rows.first,
              let resultsData = first["results_data"] as? [String: String] else { return [:] }

        return resultsData
    }

    /// Update results_data on a tennis bracket tournament.
    func updateTennisBracketResults(tournamentID: String, results: [String: String], accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/tennis_bracket_tournaments"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(tournamentID)")]
        guard let url = components?.url else { throw URLError(.badURL) }

        guard JSONSerialization.isValidJSONObject(results) else { throw URLError(.badURL) }
        let resultsData = try JSONSerialization.data(withJSONObject: results)
        let resultsJSON = String(data: resultsData, encoding: .utf8) ?? "{}"
        let bodyString = "{\"results_data\":\(resultsJSON)}"
        guard let bodyData = bodyString.data(using: .utf8) else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData

        let (_, resp) = try await session.data(for: request)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) || http.statusCode == 204 else {
            throw NSError(domain: "Supabase", code: (resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    /// Update draw_data on a tennis bracket tournament.
    func updateTennisBracketDrawData(tournamentID: String, draw: [TennisBracketPlayer], accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/tennis_bracket_tournaments"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(tournamentID)")]
        guard let url = components?.url else { throw URLError(.badURL) }

        let drawData = try JSONEncoder().encode(draw)
        let drawJSON = String(data: drawData, encoding: .utf8) ?? "[]"
        let bodyString = "{\"draw_data\":\(drawJSON)}"
        guard let bodyData = bodyString.data(using: .utf8) else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData

        let (_, resp) = try await session.data(for: request)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) || http.statusCode == 204 else {
            throw NSError(domain: "Supabase", code: (resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        print("[Supabase] Updated draw_data for \(tournamentID) with \(draw.count) players")
    }

    // MARK: - Tennis Bracket Entries

    func submitTennisBracketEntry(
        tournamentID: String,
        userID: String,
        entryName: String,
        picks: [String: String],
        accessToken: String
    ) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/tennis_bracket_entries"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "on_conflict", value: "tournament_id,user_id")]
        guard let url = components?.url else { throw URLError(.badURL) }

        // Build JSON payload using JSONSerialization to properly escape all values
        let payload: [[String: Any]] = [[
            "tournament_id": tournamentID,
            "user_id": userID,
            "entry_name": entryName,
            "picks": picks
        ]]
        let bodyData = try JSONSerialization.data(withJSONObject: payload)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        request.httpBody = bodyData

        let (_, resp) = try await session.data(for: request)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) || http.statusCode == 204 else {
            throw NSError(domain: "Supabase", code: (resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    func fetchTennisBracketEntries(tournamentID: String, accessToken: String) async throws -> [TennisBracketEntryRecord] {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/tennis_bracket_entries"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "tournament_id", value: "eq.\(tournamentID)"),
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "order", value: "total_points.desc"),
            URLQueryItem(name: "limit", value: "1100")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        return try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    func fetchUserTennisBracketEntry(tournamentID: String, userID: String, accessToken: String) async throws -> TennisBracketEntryRecord? {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/tennis_bracket_entries"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "tournament_id", value: "eq.\(tournamentID)"),
            URLQueryItem(name: "user_id", value: "eq.\(userID)"),
            URLQueryItem(name: "select", value: "*")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        let results: [TennisBracketEntryRecord] = try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
        return results.first
    }

    func batchInsertTennisBracketBotEntries(
        tournamentID: String,
        bots: [(name: String, picks: [String: String])],
        accessToken: String
    ) async throws {
        let url = SupabaseConfig.url.appending(path: "/rest/v1/tennis_bracket_entries")
        let chunkSize = 100
        for startIndex in stride(from: 0, to: bots.count, by: chunkSize) {
            let endIndex = min(startIndex + chunkSize, bots.count)
            let chunk = bots[startIndex..<endIndex]

            var payloadArray: [[String: Any]] = []
            for bot in chunk {
                payloadArray.append([
                    "tournament_id": tournamentID,
                    "entry_name": bot.name,
                    "picks": bot.picks,
                    "is_bot": true
                ])
            }

            guard JSONSerialization.isValidJSONObject(payloadArray) else { continue }
            let bodyData = try JSONSerialization.data(withJSONObject: payloadArray)
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.httpBody = bodyData

            let (_, resp) = try await session.data(for: request)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) || http.statusCode == 204 else {
                throw NSError(domain: "Supabase", code: (resp as? HTTPURLResponse)?.statusCode ?? -1)
            }
        }
    }

    func deleteTennisBracketBotEntries(tournamentID: String, accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/tennis_bracket_entries"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "tournament_id", value: "eq.\(tournamentID)"),
            URLQueryItem(name: "is_bot", value: "eq.true")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        try await requestNoResponse(url: url, method: "DELETE", body: Optional<String>.none, bearerToken: accessToken)
    }

    func updateTennisBracketEntryScores(entries: [(id: String, totalPoints: Double, rank: Int)], accessToken: String) async throws {
        for entry in entries {
            var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/tennis_bracket_entries"), resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(entry.id)")]
            guard let url = components?.url else { continue }
            struct Payload: Codable {
                let totalPoints: Double
                let rank: Int
                enum CodingKeys: String, CodingKey { case totalPoints = "total_points"; case rank }
            }
            try await requestNoResponse(url: url, method: "PATCH", body: Payload(totalPoints: entry.totalPoints, rank: entry.rank), bearerToken: accessToken)
        }
    }

    // MARK: - Tennis Bracket Bot Field

    func saveTennisBracketBotField(tournamentID: String, botField: [[String: Any]], accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/tennis_bracket_tournaments"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(tournamentID)")]
        guard let url = components?.url else { throw URLError(.badURL) }
        guard JSONSerialization.isValidJSONObject(botField) else { throw URLError(.badURL) }
        let botFieldData = try JSONSerialization.data(withJSONObject: botField)
        let botFieldJSON = String(data: botFieldData, encoding: .utf8) ?? "[]"
        let bodyString = "{\"bot_field\":\(botFieldJSON)}"
        guard let bodyData = bodyString.data(using: .utf8) else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData

        let (_, resp) = try await session.data(for: request)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) || http.statusCode == 204 else {
            throw NSError(domain: "Supabase", code: (resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    func fetchTennisBracketBotField(tournamentID: String, accessToken: String) async throws -> [[String: Any]] {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/tennis_bracket_tournaments"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(tournamentID)"),
            URLQueryItem(name: "select", value: "bot_field")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [] }
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = rows.first,
              let botField = first["bot_field"] as? [[String: Any]] else { return [] }
        return botField
    }

    // MARK: - Tennis Bracket Groups

    func createTennisBracketGroup(
        tournamentID: String,
        name: String,
        createdBy: String,
        inviteCode: String,
        maxMembers: Int,
        accessToken: String
    ) async throws -> TennisBracketGroupRecord {
        let url = SupabaseConfig.url.appending(path: "/rest/v1/tennis_bracket_groups")
        struct Payload: Codable {
            let tournamentID: String
            let name: String
            let createdBy: String
            let inviteCode: String
            let maxMembers: Int
            enum CodingKeys: String, CodingKey {
                case name
                case tournamentID = "tournament_id"
                case createdBy = "created_by"
                case inviteCode = "invite_code"
                case maxMembers = "max_members"
            }
        }
        let payload = Payload(tournamentID: tournamentID, name: name, createdBy: createdBy, inviteCode: inviteCode, maxMembers: maxMembers)
        let results: [TennisBracketGroupRecord] = try await request(url: url, method: "POST", body: payload, bearerToken: accessToken, preferReturn: "representation")
        guard let group = results.first else {
            throw NSError(domain: "Supabase", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create group"])
        }
        return group
    }

    func fetchMyTennisBracketGroups(userID: String, tournamentID: String, accessToken: String) async throws -> [TennisBracketGroupRecord] {
        struct MemberGroupID: Codable {
            let groupID: String
            enum CodingKeys: String, CodingKey { case groupID = "group_id" }
        }
        let membersURL = SupabaseConfig.url.appending(path: "/rest/v1/tennis_bracket_group_members")
            .appending(queryItems: [
                URLQueryItem(name: "user_id", value: "eq.\(userID)"),
                URLQueryItem(name: "select", value: "group_id")
            ])
        let memberships: [MemberGroupID] = try await request(url: membersURL, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
        guard !memberships.isEmpty else { return [] }

        let groupIDs = memberships.map { $0.groupID }
        let groupsURL = SupabaseConfig.url.appending(path: "/rest/v1/tennis_bracket_groups")
            .appending(queryItems: [
                URLQueryItem(name: "id", value: "in.(\(groupIDs.joined(separator: ",")))"),
                URLQueryItem(name: "tournament_id", value: "eq.\(tournamentID)"),
                URLQueryItem(name: "select", value: "*"),
                URLQueryItem(name: "order", value: "created_at.desc")
            ])
        return try await request(url: groupsURL, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    func fetchTennisBracketGroupByInviteCode(code: String, accessToken: String) async throws -> TennisBracketGroupRecord? {
        let url = SupabaseConfig.url.appending(path: "/rest/v1/tennis_bracket_groups")
            .appending(queryItems: [
                URLQueryItem(name: "invite_code", value: "eq.\(code)"),
                URLQueryItem(name: "select", value: "*")
            ])
        let results: [TennisBracketGroupRecord] = try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
        return results.first
    }

    func joinTennisBracketGroup(groupID: String, userID: String, displayName: String, accessToken: String) async throws {
        let url = SupabaseConfig.url.appending(path: "/rest/v1/tennis_bracket_group_members")
        struct Payload: Codable {
            let groupID: String
            let userID: String
            let displayName: String
            enum CodingKeys: String, CodingKey {
                case groupID = "group_id"
                case userID = "user_id"
                case displayName = "display_name"
            }
        }
        try await requestNoResponse(url: url, method: "POST", body: Payload(groupID: groupID, userID: userID, displayName: displayName), bearerToken: accessToken, preferUpsert: true)
    }

    func fetchTennisBracketGroupMembers(groupID: String, accessToken: String) async throws -> [TennisBracketGroupMemberRecord] {
        let url = SupabaseConfig.url.appending(path: "/rest/v1/tennis_bracket_group_members")
            .appending(queryItems: [
                URLQueryItem(name: "group_id", value: "eq.\(groupID)"),
                URLQueryItem(name: "select", value: "*"),
                URLQueryItem(name: "order", value: "joined_at.asc")
            ])
        return try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    func leaveTennisBracketGroup(groupID: String, userID: String, accessToken: String) async throws {
        let url = SupabaseConfig.url.appending(path: "/rest/v1/tennis_bracket_group_members")
            .appending(queryItems: [
                URLQueryItem(name: "group_id", value: "eq.\(groupID)"),
                URLQueryItem(name: "user_id", value: "eq.\(userID)")
            ])
        try await requestNoResponse(url: url, method: "DELETE", body: Optional<String>.none, bearerToken: accessToken)
    }

    func deleteTennisBracketGroup(groupID: String, accessToken: String) async throws {
        let url = SupabaseConfig.url.appending(path: "/rest/v1/tennis_bracket_groups")
            .appending(queryItems: [
                URLQueryItem(name: "id", value: "eq.\(groupID)")
            ])
        try await requestNoResponse(url: url, method: "DELETE", body: Optional<String>.none, bearerToken: accessToken)
    }

    // MARK: - Golf Tiers Tournament

    func upsertGolfTiersTournament(record: GolfTiersTournamentRecord, accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/golf_tiers_tournaments"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "on_conflict", value: "id")]
        guard let url = components?.url else { throw URLError(.badURL) }
        try await requestNoResponse(url: url, method: "POST", body: [record], bearerToken: accessToken, preferUpsert: true)
    }

    func fetchGolfTiersTournament(tournamentID: String, accessToken: String) async throws -> GolfTiersTournamentRecord? {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/golf_tiers_tournaments"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(tournamentID)"),
            URLQueryItem(name: "select", value: "id,title,major_name,season,status,lock_time,espn_event_id,entry_count,is_settled,created_at")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        let results: [GolfTiersTournamentRecord] = try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
        return results.first
    }

    func updateGolfTiersTournamentStatus(tournamentID: String, status: String, accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/golf_tiers_tournaments"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(tournamentID)")]
        guard let url = components?.url else { throw URLError(.badURL) }
        struct Payload: Codable { let status: String }
        try await requestNoResponse(url: url, method: "PATCH", body: Payload(status: status), bearerToken: accessToken)
    }

    func markGolfTiersTournamentSettled(tournamentID: String, accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/golf_tiers_tournaments"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(tournamentID)")]
        guard let url = components?.url else { throw URLError(.badURL) }
        struct Payload: Codable {
            let status: String
            let isSettled: Bool
            enum CodingKeys: String, CodingKey { case status; case isSettled = "is_settled" }
        }
        try await requestNoResponse(url: url, method: "PATCH", body: Payload(status: "settled", isSettled: true), bearerToken: accessToken)
    }

    func fetchSettledGolfTiersTournaments(accessToken: String) async throws -> [GolfTiersTournamentRecord] {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/golf_tiers_tournaments"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "is_settled", value: "eq.true"),
            URLQueryItem(name: "select", value: "id,title,major_name,season,status,lock_time,espn_event_id,entry_count,is_settled,created_at"),
            URLQueryItem(name: "order", value: "created_at.desc")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        return try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    func fetchUserGolfTiersResult(tournamentID: String, userID: String, accessToken: String) async throws -> DFSTournamentResultRecord? {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/dfs_tournament_results"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "tournament_id", value: "eq.\(tournamentID)"),
            URLQueryItem(name: "user_id", value: "eq.\(userID)"),
            URLQueryItem(name: "is_bot", value: "eq.false"),
            URLQueryItem(name: "select", value: "*")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        let results: [DFSTournamentResultRecord] = try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
        return results.first
    }

    // MARK: - Golf Tiers Entries

    func submitGolfTiersEntry(
        tournamentID: String,
        userID: String,
        entryName: String,
        picks: [GolfTiersPickData],
        accessToken: String
    ) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/golf_tiers_entries"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "on_conflict", value: "tournament_id,user_id")]
        guard let url = components?.url else { throw URLError(.badURL) }
        struct Payload: Codable {
            let tournamentID: String
            let userID: String
            let entryName: String
            let picks: [GolfTiersPickData]
            enum CodingKeys: String, CodingKey {
                case tournamentID = "tournament_id"
                case userID = "user_id"
                case entryName = "entry_name"
                case picks
            }
        }
        let payload = [Payload(tournamentID: tournamentID, userID: userID, entryName: entryName, picks: picks)]
        try await requestNoResponse(url: url, method: "POST", body: payload, bearerToken: accessToken, preferUpsert: true)
    }

    func batchInsertGolfTiersBotEntries(
        tournamentID: String,
        bots: [(name: String, picks: [GolfTiersPickData])],
        accessToken: String
    ) async throws {
        let url = SupabaseConfig.url.appending(path: "/rest/v1/golf_tiers_entries")
        struct BotPayload: Codable {
            let tournamentID: String
            let entryName: String
            let picks: [GolfTiersPickData]
            let isBot: Bool
            enum CodingKeys: String, CodingKey {
                case tournamentID = "tournament_id"
                case entryName = "entry_name"
                case picks
                case isBot = "is_bot"
            }
        }
        let chunkSize = 100
        for startIndex in stride(from: 0, to: bots.count, by: chunkSize) {
            let endIndex = min(startIndex + chunkSize, bots.count)
            let chunk = bots[startIndex..<endIndex]
            let payload = chunk.map { bot in
                BotPayload(tournamentID: tournamentID, entryName: bot.name, picks: bot.picks, isBot: true)
            }
            try await requestNoResponse(url: url, method: "POST", body: payload, bearerToken: accessToken)
        }
    }

    func deleteGolfTiersBotEntries(tournamentID: String, accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/golf_tiers_entries"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "tournament_id", value: "eq.\(tournamentID)"),
            URLQueryItem(name: "is_bot", value: "eq.true")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        try await requestNoResponse(url: url, method: "DELETE", body: Optional<String>.none, bearerToken: accessToken)
    }

    func fetchGolfTiersEntries(tournamentID: String, accessToken: String) async throws -> [GolfTiersEntryRecord] {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/golf_tiers_entries"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "tournament_id", value: "eq.\(tournamentID)"),
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "order", value: "total_points.asc"),
            URLQueryItem(name: "limit", value: "1100")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        return try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    func fetchUserGolfTiersEntry(tournamentID: String, userID: String, accessToken: String) async throws -> GolfTiersEntryRecord? {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/golf_tiers_entries"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "tournament_id", value: "eq.\(tournamentID)"),
            URLQueryItem(name: "user_id", value: "eq.\(userID)"),
            URLQueryItem(name: "select", value: "*")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        let results: [GolfTiersEntryRecord] = try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
        return results.first
    }

    func updateGolfTiersEntryScores(entries: [(id: String, totalPoints: Double, rank: Int)], accessToken: String) async throws {
        for entry in entries {
            var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/golf_tiers_entries"), resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(entry.id)")]
            guard let url = components?.url else { continue }
            struct Payload: Codable {
                let totalPoints: Double
                let rank: Int
                enum CodingKeys: String, CodingKey { case totalPoints = "total_points"; case rank }
            }
            try await requestNoResponse(url: url, method: "PATCH", body: Payload(totalPoints: entry.totalPoints, rank: entry.rank), bearerToken: accessToken)
        }
    }

    // MARK: - Golf Tiers Bot Field

    func saveGolfTiersBotField(tournamentID: String, botField: [[String: Any]], accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/golf_tiers_tournaments"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(tournamentID)")]
        guard let url = components?.url else { throw URLError(.badURL) }
        guard JSONSerialization.isValidJSONObject(botField) else { throw URLError(.badURL) }
        let botFieldData = try JSONSerialization.data(withJSONObject: botField)
        let botFieldJSON = String(data: botFieldData, encoding: .utf8) ?? "[]"
        let bodyString = "{\"bot_field\":\(botFieldJSON)}"
        guard let bodyData = bodyString.data(using: .utf8) else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData

        let (_, resp) = try await session.data(for: request)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) || http.statusCode == 204 else {
            throw NSError(domain: "Supabase", code: (resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    func fetchGolfTiersBotField(tournamentID: String, accessToken: String) async throws -> [[String: Any]] {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/golf_tiers_tournaments"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(tournamentID)"),
            URLQueryItem(name: "select", value: "bot_field")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [] }
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = rows.first,
              let botField = first["bot_field"] as? [[String: Any]] else { return [] }
        return botField
    }

    // MARK: - Golf Tiers Groups

    func createGolfTiersGroup(
        tournamentID: String,
        name: String,
        createdBy: String,
        inviteCode: String,
        maxMembers: Int,
        accessToken: String
    ) async throws -> GolfTiersGroupRecord {
        let url = SupabaseConfig.url.appending(path: "/rest/v1/golf_tiers_groups")
        struct Payload: Codable {
            let tournamentID: String
            let name: String
            let createdBy: String
            let inviteCode: String
            let maxMembers: Int
            enum CodingKeys: String, CodingKey {
                case name
                case tournamentID = "tournament_id"
                case createdBy = "created_by"
                case inviteCode = "invite_code"
                case maxMembers = "max_members"
            }
        }
        let payload = Payload(tournamentID: tournamentID, name: name, createdBy: createdBy, inviteCode: inviteCode, maxMembers: maxMembers)
        let results: [GolfTiersGroupRecord] = try await request(url: url, method: "POST", body: payload, bearerToken: accessToken, preferReturn: "representation")
        guard let group = results.first else {
            throw NSError(domain: "Supabase", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create group"])
        }
        return group
    }

    func fetchMyGolfTiersGroups(userID: String, tournamentID: String, accessToken: String) async throws -> [GolfTiersGroupRecord] {
        struct MemberGroupID: Codable {
            let groupID: String
            enum CodingKeys: String, CodingKey { case groupID = "group_id" }
        }
        let membersURL = SupabaseConfig.url.appending(path: "/rest/v1/golf_tiers_group_members")
            .appending(queryItems: [
                URLQueryItem(name: "user_id", value: "eq.\(userID)"),
                URLQueryItem(name: "select", value: "group_id")
            ])
        let memberships: [MemberGroupID] = try await request(url: membersURL, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
        guard !memberships.isEmpty else { return [] }

        let groupIDs = memberships.map { $0.groupID }
        let groupsURL = SupabaseConfig.url.appending(path: "/rest/v1/golf_tiers_groups")
            .appending(queryItems: [
                URLQueryItem(name: "id", value: "in.(\(groupIDs.joined(separator: ",")))"),
                URLQueryItem(name: "tournament_id", value: "eq.\(tournamentID)"),
                URLQueryItem(name: "select", value: "*"),
                URLQueryItem(name: "order", value: "created_at.desc")
            ])
        return try await request(url: groupsURL, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    // MARK: - Fetch ALL groups across tournaments (for group chat list)

    func fetchAllMyGolfTiersGroups(userID: String, accessToken: String) async throws -> [GolfTiersGroupRecord] {
        struct MemberGroupID: Codable {
            let groupID: String
            enum CodingKeys: String, CodingKey { case groupID = "group_id" }
        }
        let membersURL = SupabaseConfig.url.appending(path: "/rest/v1/golf_tiers_group_members")
            .appending(queryItems: [
                URLQueryItem(name: "user_id", value: "eq.\(userID)"),
                URLQueryItem(name: "select", value: "group_id")
            ])
        let memberships: [MemberGroupID] = try await request(url: membersURL, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
        guard !memberships.isEmpty else { return [] }

        let groupIDs = memberships.map { $0.groupID }
        let groupsURL = SupabaseConfig.url.appending(path: "/rest/v1/golf_tiers_groups")
            .appending(queryItems: [
                URLQueryItem(name: "id", value: "in.(\(groupIDs.joined(separator: ",")))"),
                URLQueryItem(name: "select", value: "*"),
                URLQueryItem(name: "order", value: "created_at.desc")
            ])
        return try await request(url: groupsURL, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    func fetchAllMyPlayoffTiersGroups(userID: String, accessToken: String) async throws -> [PlayoffTiersGroupRecord] {
        struct MemberGroupID: Codable {
            let groupID: String
            enum CodingKeys: String, CodingKey { case groupID = "group_id" }
        }
        let membersURL = SupabaseConfig.url.appending(path: "/rest/v1/playoff_tiers_group_members")
            .appending(queryItems: [
                URLQueryItem(name: "user_id", value: "eq.\(userID)"),
                URLQueryItem(name: "select", value: "group_id")
            ])
        let memberships: [MemberGroupID] = try await request(url: membersURL, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
        guard !memberships.isEmpty else { return [] }

        let groupIDs = memberships.map { $0.groupID }
        let groupsURL = SupabaseConfig.url.appending(path: "/rest/v1/playoff_tiers_groups")
            .appending(queryItems: [
                URLQueryItem(name: "id", value: "in.(\(groupIDs.joined(separator: ",")))"),
                URLQueryItem(name: "select", value: "*"),
                URLQueryItem(name: "order", value: "created_at.desc")
            ])
        return try await request(url: groupsURL, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    func fetchAllMySoccerTiersGroups(userID: String, accessToken: String) async throws -> [SoccerTiersGroupRecord] {
        struct MemberGroupID: Codable {
            let groupID: String
            enum CodingKeys: String, CodingKey { case groupID = "group_id" }
        }
        let membersURL = SupabaseConfig.url.appending(path: "/rest/v1/soccer_tiers_group_members")
            .appending(queryItems: [
                URLQueryItem(name: "user_id", value: "eq.\(userID)"),
                URLQueryItem(name: "select", value: "group_id")
            ])
        let memberships: [MemberGroupID] = try await request(url: membersURL, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
        guard !memberships.isEmpty else { return [] }

        let groupIDs = memberships.map { $0.groupID }
        let groupsURL = SupabaseConfig.url.appending(path: "/rest/v1/soccer_tiers_groups")
            .appending(queryItems: [
                URLQueryItem(name: "id", value: "in.(\(groupIDs.joined(separator: ",")))"),
                URLQueryItem(name: "select", value: "*"),
                URLQueryItem(name: "order", value: "created_at.desc")
            ])
        return try await request(url: groupsURL, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    func fetchAllMyTennisBracketGroups(userID: String, accessToken: String) async throws -> [TennisBracketGroupRecord] {
        struct MemberGroupID: Codable {
            let groupID: String
            enum CodingKeys: String, CodingKey { case groupID = "group_id" }
        }
        let membersURL = SupabaseConfig.url.appending(path: "/rest/v1/tennis_bracket_group_members")
            .appending(queryItems: [
                URLQueryItem(name: "user_id", value: "eq.\(userID)"),
                URLQueryItem(name: "select", value: "group_id")
            ])
        let memberships: [MemberGroupID] = try await request(url: membersURL, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
        guard !memberships.isEmpty else { return [] }

        let groupIDs = memberships.map { $0.groupID }
        let groupsURL = SupabaseConfig.url.appending(path: "/rest/v1/tennis_bracket_groups")
            .appending(queryItems: [
                URLQueryItem(name: "id", value: "in.(\(groupIDs.joined(separator: ",")))"),
                URLQueryItem(name: "select", value: "*"),
                URLQueryItem(name: "order", value: "created_at.desc")
            ])
        return try await request(url: groupsURL, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    func fetchGolfTiersGroupByInviteCode(code: String, accessToken: String) async throws -> GolfTiersGroupRecord? {
        let url = SupabaseConfig.url.appending(path: "/rest/v1/golf_tiers_groups")
            .appending(queryItems: [
                URLQueryItem(name: "invite_code", value: "eq.\(code)"),
                URLQueryItem(name: "select", value: "*")
            ])
        let results: [GolfTiersGroupRecord] = try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
        return results.first
    }

    func joinGolfTiersGroup(groupID: String, userID: String, displayName: String, accessToken: String) async throws {
        let url = SupabaseConfig.url.appending(path: "/rest/v1/golf_tiers_group_members")
        struct Payload: Codable {
            let groupID: String
            let userID: String
            let displayName: String
            enum CodingKeys: String, CodingKey {
                case groupID = "group_id"
                case userID = "user_id"
                case displayName = "display_name"
            }
        }
        try await requestNoResponse(url: url, method: "POST", body: Payload(groupID: groupID, userID: userID, displayName: displayName), bearerToken: accessToken, preferUpsert: true)
    }

    func fetchGolfTiersGroupMembers(groupID: String, accessToken: String) async throws -> [GolfTiersGroupMemberRecord] {
        let url = SupabaseConfig.url.appending(path: "/rest/v1/golf_tiers_group_members")
            .appending(queryItems: [
                URLQueryItem(name: "group_id", value: "eq.\(groupID)"),
                URLQueryItem(name: "select", value: "*"),
                URLQueryItem(name: "order", value: "joined_at.asc")
            ])
        return try await request(url: url, method: "GET", body: Optional<String>.none, bearerToken: accessToken)
    }

    func leaveGolfTiersGroup(groupID: String, userID: String, accessToken: String) async throws {
        let url = SupabaseConfig.url.appending(path: "/rest/v1/golf_tiers_group_members")
            .appending(queryItems: [
                URLQueryItem(name: "group_id", value: "eq.\(groupID)"),
                URLQueryItem(name: "user_id", value: "eq.\(userID)")
            ])
        try await requestNoResponse(url: url, method: "DELETE", body: Optional<String>.none, bearerToken: accessToken)
    }

    func deleteGolfTiersGroup(groupID: String, accessToken: String) async throws {
        let url = SupabaseConfig.url.appending(path: "/rest/v1/golf_tiers_groups")
            .appending(queryItems: [
                URLQueryItem(name: "id", value: "eq.\(groupID)")
            ])
        try await requestNoResponse(url: url, method: "DELETE", body: Optional<String>.none, bearerToken: accessToken)
    }

    private func requestNoResponse<Body: Encodable>(
        url: URL,
        method: String,
        body: Body?,
        bearerToken: String?,
        preferUpsert: Bool = false
    ) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        if preferUpsert {
            request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        }
        if let body {
            request.httpBody = try JSONEncoder.supabaseEncoder.encode(body)
        }

        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse

        // Auto-refresh on 401 and retry once
        if http?.statusCode == 401, bearerToken != nil, let refresher = tokenRefreshProvider {
            if let freshToken = await refresher() {
                request.setValue("Bearer \(freshToken)", forHTTPHeaderField: "Authorization")
                let (retryData, retryResponse) = try await session.data(for: request)
                guard let retryHttp = retryResponse as? HTTPURLResponse,
                      (200..<300).contains(retryHttp.statusCode) || retryHttp.statusCode == 204 else {
                    let message = String(data: retryData, encoding: .utf8) ?? "unknown"
                    throw NSError(domain: "Supabase", code: (retryResponse as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: message])
                }
                return
            }
        }

        guard let http, (200..<300).contains(http.statusCode) || http.statusCode == 204 else {
            let message = String(data: data, encoding: .utf8) ?? "unknown"
            throw NSError(domain: "Supabase", code: http?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}

private extension JSONEncoder {
    static var supabaseEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var supabaseDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
