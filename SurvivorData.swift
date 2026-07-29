import Foundation

// MARK: - NFL Survivor season constants

enum SurvivorSeason {
    static let year = 2026
    static let totalWeeks = 18
    /// One pool per entry-fee tier; a user may join each pool once.
    static let entryFees = [10, 20, 50, 100, 250]

    static func poolID(fee: Int) -> String { "survivor-nfl-\(year)-\(fee)" }
    static func fee(fromPoolID id: String) -> Int {
        Int(id.components(separatedBy: "-").last ?? "") ?? 10
    }
}

// MARK: - Supabase rows

struct SurvivorEntryRecord: Codable, Identifiable {
    let id: String
    let poolID: String
    let userID: String
    let entryName: String
    var status: String          // "alive" | "eliminated"
    var eliminatedWeek: Int?
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case poolID = "pool_id"
        case userID = "user_id"
        case entryName = "entry_name"
        case status
        case eliminatedWeek = "eliminated_week"
        case createdAt = "created_at"
    }
}

struct SurvivorPickRecord: Codable, Identifiable {
    let id: String
    let poolID: String
    let userID: String
    let week: Int
    var teamAbbr: String
    var teamName: String
    var result: String          // "pending" | "win" | "loss"

    enum CodingKeys: String, CodingKey {
        case id
        case poolID = "pool_id"
        case userID = "user_id"
        case week
        case teamAbbr = "team_abbr"
        case teamName = "team_name"
        case result
    }
}

// MARK: - Week schedule / results

struct SurvivorGame: Identifiable, Codable, Equatable {
    let id: String
    let week: Int
    let date: Date
    let awayAbbr: String
    let awayName: String
    let homeAbbr: String
    let homeName: String
    var state: String           // "pre" | "in" | "post"
    var awayScore: Int
    var homeScore: Int
    /// nil until final; also nil on a tie — a tie is a survivor loss.
    var winnerAbbr: String?

    func involves(_ abbr: String) -> Bool { awayAbbr == abbr || homeAbbr == abbr }
}

private func parseSurvivorESPNDate(_ raw: String) -> Date? {
    let formats = ["yyyy-MM-dd'T'HH:mm'Z'", "yyyy-MM-dd'T'HH:mm:ss'Z'"]
    for fmt in formats {
        let df = DateFormatter()
        df.dateFormat = fmt
        df.timeZone = TimeZone(identifier: "UTC")
        df.locale = Locale(identifier: "en_US_POSIX")
        if let d = df.date(from: raw) { return d }
    }
    return ISO8601DateFormatter().date(from: raw)
}

final class NFLSurvivorScheduleProvider {
    /// Regular-season week currently in progress: 1 before the season
    /// starts (and during preseason), totalWeeks once the playoffs begin.
    func fetchCurrentWeek() async -> Int {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/football/nfl/scoreboard"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 1 }
        let seasonType = ((json["season"] as? [String: Any])?["type"] as? Int) ?? 2
        let seasonYear = ((json["season"] as? [String: Any])?["year"] as? Int) ?? SurvivorSeason.year
        let week = ((json["week"] as? [String: Any])?["number"] as? Int) ?? 1
        if seasonYear < SurvivorSeason.year { return 1 }
        if seasonType < 2 { return 1 }
        if seasonType > 2 || seasonYear > SurvivorSeason.year { return SurvivorSeason.totalWeeks }
        return min(max(week, 1), SurvivorSeason.totalWeeks)
    }

    func fetchGames(week: Int) async -> [SurvivorGame] {
        let urlStr = "https://site.api.espn.com/apis/site/v2/sports/football/nfl/scoreboard?seasontype=2&week=\(week)&dates=\(SurvivorSeason.year)"
        guard let url = URL(string: urlStr),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = json["events"] as? [[String: Any]] else { return [] }

        var games: [SurvivorGame] = []
        for event in events {
            guard let eventID = event["id"] as? String,
                  let dateStr = event["date"] as? String,
                  let date = parseSurvivorESPNDate(dateStr),
                  let comp = (event["competitions"] as? [[String: Any]])?.first,
                  let competitors = comp["competitors"] as? [[String: Any]] else { continue }
            let state = (((comp["status"] as? [String: Any])?["type"] as? [String: Any])?["state"] as? String) ?? "pre"

            var homeAbbr = "", homeName = "", awayAbbr = "", awayName = ""
            var homeScore = 0, awayScore = 0
            var winnerAbbr: String?
            for c in competitors {
                guard let team = c["team"] as? [String: Any] else { continue }
                let abbr = (team["abbreviation"] as? String) ?? ""
                let name = (team["shortDisplayName"] as? String) ?? (team["displayName"] as? String) ?? abbr
                let score = Int((c["score"] as? String) ?? "") ?? 0
                let isWinner = (c["winner"] as? Bool) ?? false
                if (c["homeAway"] as? String) == "home" {
                    homeAbbr = abbr; homeName = name; homeScore = score
                } else {
                    awayAbbr = abbr; awayName = name; awayScore = score
                }
                if isWinner && state == "post" { winnerAbbr = abbr }
            }
            guard !homeAbbr.isEmpty, !awayAbbr.isEmpty else { continue }
            games.append(SurvivorGame(
                id: eventID, week: week, date: date,
                awayAbbr: awayAbbr, awayName: awayName,
                homeAbbr: homeAbbr, homeName: homeName,
                state: state, awayScore: awayScore, homeScore: homeScore,
                winnerAbbr: winnerAbbr
            ))
        }
        return games.sorted { $0.date < $1.date }
    }
}
