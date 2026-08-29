import Foundation
import SwiftUI
import UserNotifications

/// Local notifications for scheduled Best Ball drafts. There is no push
/// server — each member's own device schedules reminders whenever their
/// league list loads, so anyone who has opened the app since the draft
/// was scheduled gets "5 minutes" and "starting now" alerts even with
/// the app closed.
enum BestBallDraftNotifier {
    private static let idPrefix = "bestball-draft-"

    static func syncScheduledDraftNotifications(leagues: [BestBallLeague]) {
        let center = UNUserNotificationCenter.current()
        let upcoming = leagues.filter {
            $0.status == "open" && ($0.draftStartTime ?? .distantPast) > Date()
        }
        center.getPendingNotificationRequests { pending in
            // Drop reminders for drafts that started, were unscheduled,
            // or whose league the user left.
            let wantedIDs = Set(upcoming.flatMap {
                ["\(idPrefix)\($0.id)-5m", "\(idPrefix)\($0.id)-now"]
            })
            let stale = pending.map(\.identifier)
                .filter { $0.hasPrefix(idPrefix) && !wantedIDs.contains($0) }
            if !stale.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: stale)
            }
            guard !upcoming.isEmpty else { return }
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                guard granted else { return }
                for league in upcoming {
                    guard let start = league.draftStartTime else { continue }
                    schedule(
                        id: "\(idPrefix)\(league.id)-5m",
                        title: "Draft starts in 5 minutes",
                        body: "\"\(league.title)\" — get in the lobby!",
                        at: start.addingTimeInterval(-300)
                    )
                    schedule(
                        id: "\(idPrefix)\(league.id)-now",
                        title: "Your draft is starting!",
                        body: "\"\(league.title)\" is drafting now.",
                        at: start
                    )
                }
            }
        }
    }

    private static func schedule(id: String, title: String, body: String, at date: Date) {
        guard date > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, date.timeIntervalSinceNow), repeats: false
        )
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        )
    }
}

/// Lightweight matchup summary for the league list cards.
struct LeagueMatchupPreview {
    let myName: String
    let opponentName: String
    let myScore: Double
    let opponentScore: Double
    let myGamesPlayed: Int
    let opponentGamesPlayed: Int
    let week: Int
    /// "3-2" style H2H records from standings (nil pre-season).
    var myRecord: String? = nil
    var opponentRecord: String? = nil
    /// "4th/16" style standings (nil pre-season).
    var myStanding: String? = nil
    var opponentStanding: String? = nil
}

/// "1st", "2nd", "3rd", "4th"… for standings display.
func bestBallOrdinal(_ n: Int) -> String {
    let suffix: String
    switch n % 100 {
    case 11, 12, 13: suffix = "th"
    default:
        switch n % 10 {
        case 1: suffix = "st"
        case 2: suffix = "nd"
        case 3: suffix = "rd"
        default: suffix = "th"
        }
    }
    return "\(n)\(suffix)"
}

@MainActor
@Observable
final class BestBallViewModel {
    // MARK: - State
    var openLeagues: [BestBallLeague] = []
    var myLeagues: [BestBallLeague] = []
    var myMemberships: [BestBallMemberRecord] = []
    var leagueMemberCounts: [String: Int] = [:]
    var wonLeagueIDs: Set<String> = []
    var leagueMatchupPreviews: [String: LeagueMatchupPreview] = [:]
    /// Sum of the user's fantasy RR ledger (entry fees + payouts).
    var fantasyLedgerDelta: Int = 0
    /// Settled Tiers/Bracket results (rank, points, RR) for the Profile
    /// tab's Fantasy Results list. Built during reconcileFantasyLedger.
    var fantasyPastRows: [DFSResult] = []
    var isLoading: Bool = false
    var isStartingDraft: Bool = false
    var error: String?

    // League Detail
    var currentLeague: BestBallLeague?
    var currentMembers: [BestBallMember] = []
    var draftState: BestBallDraftState?
    var availablePlayers: [BestBallPlayer] = []
    var isDraftPolling: Bool = false
    /// NFL team abbreviation -> bye week for the current season.
    var nflByeWeeks: [String: Int] = [:]
    var cfbByeWeeks: [String: [Int]] = [:]

    // Standings & Scoring
    var weeklyScores: [BestBallWeeklyScore] = []
    var standings: [BestBallStanding] = []

    // Week navigation & Matchups
    var selectedWeek: Int = 1
    var currentWeekMatchups: [BestBallMatchup] = []
    var myMatchup: BestBallMatchup?
    var dailyScores: [BestBallDailyScore] = []

    // Date navigation for Team view
    var selectedDate: Date = Date()

    /// All dates in the current selected week (Mon-Sun or Thu-Mon)
    var weekDates: [Date] {
        guard let league = currentLeague else { return [] }
        let (start, end) = BestBallSeasonHelper.weekDateRange(sport: league.sport, week: selectedWeek)
        let calendar = Calendar.current
        var dates: [Date] = []
        var current = start
        while current <= end {
            dates.append(current)
            current = calendar.date(byAdding: .day, value: 1, to: current) ?? current
        }
        return dates
    }

    /// Player points for the selected date for a given member
    func dailyPlayerPoints(for memberID: String) -> [String: Double] {
        let dateKey = formattedDate(selectedDate)
        return dailyScores
            .first(where: { $0.memberID == memberID && formattedDate($0.gameDate) == dateKey })?
            .playerPoints ?? [:]
    }

    /// Player stats for the selected date for a given member
    func dailyPlayerStats(for memberID: String) -> [String: [String: Double]] {
        let dateKey = formattedDate(selectedDate)
        return dailyScores
            .first(where: { $0.memberID == memberID && formattedDate($0.gameDate) == dateKey })?
            .playerStats ?? [:]
    }

    func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // Catch-up progress
    var catchUpProgress: String = ""

    // Live scoring
    var isLivePolling: Bool = false
    private var livePollTask: Task<Void, Never>?

    // Filters
    var sportFilter: String? = nil

    // Auth (synced from ContentView)
    var userID: String?
    var accessToken: String?
    var profileName: String = ""

    // MARK: - Providers
    private let playerProvider: BestBallPlayerProvider
    private let scoringProvider: BestBallWeeklyScoringProvider

    // Draft queue: player ids the user has starred to draft next, in
    // priority order. Lives on the VM (not the view) so backing out of
    // the draft screen doesn't lose it; auto-pick drafts from it first.
    var draftQueue: [String] = []

    /// "sport|cfbPool" of the currently loaded availablePlayers, so
    /// switching leagues with different pools refetches.
    private var availablePlayersKey: String?

    // Draft polling
    private var draftPollTask: Task<Void, Never>?
    /// Wall-clock of the last observed pick landing (or the drafting state
    /// first appearing). Drives the multi-device failover ladder that keeps
    /// a draft moving when the host's app is backgrounded, and the pick
    /// countdown in the draft view — deriving the clock from this instead
    /// of view-local state means backing out and re-entering the draft
    /// doesn't restart the timer.
    private(set) var lastPickActivityAt = Date()
    private var lastObservedPickCount = -1

    /// Solo league (one human + bots): give a returning user a fresh
    /// clock instead of an instant auto-pick — nobody else is waiting.
    /// Multi-human leagues keep the continuous clock.
    private var soloClockRestartAt: Date?
    func restartPickClockIfSolo() {
        let humans = currentMembers.filter { !$0.isBot }
        if humans.count <= 1 {
            lastPickActivityAt = Date()
            soloClockRestartAt = Date()
        }
    }

    /// The instant the current pick's clock started. SERVER-derived:
    /// every device computes it from the last pick's persisted
    /// `picked_at` timestamp, so all screens in a multi-human draft run
    /// the SAME countdown. (The old version stamped the moment each
    /// device OBSERVED the pick land — 2s polling plus the failover
    /// stagger made each drafter's clock differ by many seconds.)
    /// Draft-open time wins before pick 1 (startDraft sets it to now+30s
    /// for the shared pre-pick countdown); the solo restart wins for a
    /// returning solo drafter.
    var pickClockStart: Date {
        var start = draftState?.picks.map(\.pickedAt).max() ?? lastPickActivityAt
        if let opens = currentLeague?.draftStartTime, opens > start { start = opens }
        if let solo = soloClockRestartAt, solo > start { start = solo }
        return start
    }

    /// False while the in-draft pre-pick countdown is still running.
    var draftHasOpened: Bool {
        guard let opens = currentLeague?.draftStartTime else { return true }
        return Date() >= opens
    }

    init(
        playerProvider: BestBallPlayerProvider? = nil,
        scoringProvider: BestBallWeeklyScoringProvider? = nil
    ) {
        self.playerProvider = playerProvider ?? ESPNBestBallPlayerProvider()
        self.scoringProvider = scoringProvider ?? ESPNBestBallWeeklyScoringProvider()
    }

    // MARK: - Browse Leagues

    func loadOpenLeagues() async {
        guard let token = accessToken else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let records = try await SupabaseService.shared.fetchOpenLeagues(sport: sportFilter, accessToken: token)
            openLeagues = records.map { $0.toModel() }
            // Fetch actual member counts from the members table
            let leagueIDs = openLeagues.map { $0.id }
            if !leagueIDs.isEmpty {
                let counts = try await SupabaseService.shared.fetchMemberCounts(leagueIDs: leagueIDs, accessToken: token)
                leagueMemberCounts.merge(counts) { _, new in new }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var myLeaguesLoadedAt: Date?

    /// Reload My Leagues when the list is empty OR stale — the old
    /// empty-only guard meant a partial/failed load could freeze a wrong
    /// list for the whole session.
    func refreshMyLeaguesIfStale(maxAge: TimeInterval = 60) async {
        if myLeagues.isEmpty
            || myLeaguesLoadedAt == nil
            || Date().timeIntervalSince(myLeaguesLoadedAt ?? .distantPast) > maxAge {
            await loadMyLeagues()
        }
    }

    func loadMyLeagues() async {
        guard let uid = userID, let token = accessToken else { return }
        // Keep the EPL matchweek table warm — week windows and "Week N of
        // 38" all read from it (24h-TTL no-op when fresh).
        // AWAITED, not fire-and-forget: every week computation below (matchup
        // previews, current-week resolution) falls back to legacy Mon-Sun
        // weeks when the FPL table isn't cached yet — which scored Chelsea's
        // Monday Aug 24 (GW1) game into "week 2" (legacy week 2 = Aug 24-30).
        await EPLMatchweekProvider.refreshIfStale()
        do {
            let memberships = try await SupabaseService.shared.fetchUserMemberships(userID: uid, accessToken: token)
            myMemberships = memberships
            let leagueIDs = Set(memberships.map { $0.leagueId })
            var fetched: [String: BestBallLeague] = [:]
            await withTaskGroup(of: BestBallLeague?.self) { group in
                for id in leagueIDs {
                    group.addTask {
                        (try? await SupabaseService.shared.fetchLeague(id: id, accessToken: token))?.toModel()
                    }
                }
                for await league in group {
                    if let league { fetched[league.id] = league }
                }
            }
            // A transient per-league fetch failure must NOT drop a league
            // from the list — replacing wholesale with the survivors once
            // left a single league in My Leagues (and the hub only
            // auto-reloads when the list is EMPTY, so it stuck). Keep the
            // previously loaded copy for any membership whose fetch failed.
            let previousByID = Dictionary(myLeagues.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var leagues: [BestBallLeague] = []
            for id in leagueIDs {
                if let league = fetched[id] {
                    leagues.append(league)
                } else if let previous = previousByID[id] {
                    leagues.append(previous)
                }
            }
            if leagues.count < leagueIDs.count {
                print("[BestBall] loadMyLeagues resolved \(leagues.count)/\(leagueIDs.count) leagues (\(fetched.count) fresh)")
            }
            myLeagues = leagues.sorted { $0.createdAt > $1.createdAt }
            myLeaguesLoadedAt = Date()
            BestBallDraftNotifier.syncScheduledDraftNotifications(leagues: myLeagues)

            // Check which completed leagues the user won (rank 1)
            let completedIDs = leagues.filter { $0.status == "completed" }.map(\.id)
            var wins: Set<String> = []
            for leagueID in completedIDs {
                guard let myMembership = memberships.first(where: { $0.leagueId == leagueID }) else { continue }
                if let standingRecords = try? await SupabaseService.shared.fetchStandings(leagueID: leagueID, accessToken: token) {
                    let rank1 = standingRecords.first(where: { $0.rank == 1 })
                    if rank1?.memberId == myMembership.id {
                        wins.insert(leagueID)
                    }
                }
            }
            wonLeagueIDs = wins

            // Fetch matchup previews for active H2H leagues
            let activeH2H = leagues.filter { $0.status == "active" && !$0.isDingersOnly && !$0.schedule.isEmpty }
            var previews: [String: LeagueMatchupPreview] = [:]
            for league in activeH2H {
                guard let myMembership = memberships.first(where: { $0.leagueId == league.id }) else { continue }
                let realWeek = BestBallSeasonHelper.currentWeekNumber(for: league.sport)
                // Show the CALENDAR week's matchup, not the stored one.
                // `league.currentWeek` only advances when last week's scoring
                // runs (someone opening the league), so the hub card sat on
                // "Wk 1" with week-1 scores after GW2 had already kicked off.
                // The calendar week is what "this week's matchup" means —
                // clamped to the schedule so late-season off-by-ones can't
                // walk past the last week.
                let week = min(realWeek, league.schedule.count)
                guard week > 0 else { continue }

                // Find my matchup pair from the schedule
                let weekPairs = league.schedule[week - 1]
                var opponentID: String?
                for pair in weekPairs where pair.count == 2 {
                    if pair[0] == myMembership.id {
                        opponentID = pair[1]; break
                    } else if pair[1] == myMembership.id {
                        opponentID = pair[0]; break
                    }
                }
                guard let oppID = opponentID else { continue }

                // Fetch weekly scores for this league+week
                if let scoreRecords = try? await SupabaseService.shared.fetchWeeklyScores(leagueID: league.id, accessToken: token) {
                    let scores = scoreRecords.map { $0.toModel() }
                    let myScore = scores.first(where: { $0.memberID == myMembership.id && $0.week == week })
                    let oppScore = scores.first(where: { $0.memberID == oppID && $0.week == week })

                    // Fetch members for display names
                    let memberRecords = (try? await SupabaseService.shared.fetchLeagueMembers(leagueID: league.id, accessToken: token)) ?? []
                    let myName = memberRecords.first(where: { $0.id == myMembership.id })?.displayName ?? "You"
                    let oppName = memberRecords.first(where: { $0.id == oppID })?.displayName ?? "Opponent"

                    // Records + standing from the standings table ("3-2 · 4th/16").
                    let standingsFetch = try? await SupabaseService.shared.fetchStandings(leagueID: league.id, accessToken: token)
                    let standings = (standingsFetch ?? []).map { $0.toModel() }
                    let myStandingRow = standings.first(where: { $0.memberID == myMembership.id })
                    let oppStandingRow = standings.first(where: { $0.memberID == oppID })
                    let memberCount = max(memberRecords.count, standings.count)

                    var preview = LeagueMatchupPreview(
                        myName: myName,
                        opponentName: oppName,
                        myScore: myScore?.totalPoints ?? 0,
                        opponentScore: oppScore?.totalPoints ?? 0,
                        myGamesPlayed: myScore?.playerPoints.count ?? 0,
                        opponentGamesPlayed: oppScore?.playerPoints.count ?? 0,
                        week: week
                    )
                    if let mine = myStandingRow {
                        preview.myRecord = "\(mine.wins)-\(mine.losses)"
                        if mine.rank > 0, memberCount > 0 {
                            preview.myStanding = "\(bestBallOrdinal(mine.rank))/\(memberCount)"
                        }
                    }
                    if let theirs = oppStandingRow {
                        preview.opponentRecord = "\(theirs.wins)-\(theirs.losses)"
                        if theirs.rank > 0, memberCount > 0 {
                            preview.opponentStanding = "\(bestBallOrdinal(theirs.rank))/\(memberCount)"
                        }
                    }
                    // Failed standings fetch (nil, not genuinely empty):
                    // carry the previous pass's records forward instead of
                    // rendering a record-less card.
                    if standingsFetch == nil, let prev = leagueMatchupPreviews[league.id] {
                        preview.myRecord = preview.myRecord ?? prev.myRecord
                        preview.myStanding = preview.myStanding ?? prev.myStanding
                        preview.opponentRecord = preview.opponentRecord ?? prev.opponentRecord
                        preview.opponentStanding = preview.opponentStanding ?? prev.opponentStanding
                    }
                    // Fresh league (drafted, nothing scored yet — no
                    // standings rows): synthesize 0-0 records and
                    // slot-order ranks from the member list so the card
                    // never renders rank-less.
                    if preview.myRecord == nil || preview.opponentRecord == nil {
                        let ordered = memberRecords.sorted { $0.slotIndex < $1.slotIndex }
                        if preview.myRecord == nil,
                           let idx = ordered.firstIndex(where: { $0.id == myMembership.id }) {
                            preview.myRecord = "0-0"
                            preview.myStanding = "\(bestBallOrdinal(idx + 1))/\(ordered.count)"
                        }
                        if preview.opponentRecord == nil,
                           let idx = ordered.firstIndex(where: { $0.id == oppID }) {
                            preview.opponentRecord = "0-0"
                            preview.opponentStanding = "\(bestBallOrdinal(idx + 1))/\(ordered.count)"
                        }
                    }
                    previews[league.id] = preview
                }
            }
            // MERGE, don't replace: a league whose weekly-scores fetch failed
            // this pass keeps its previous preview — replacing the dict made
            // that league's matchup card vanish until a later pass succeeded.
            for (id, preview) in previews {
                leagueMatchupPreviews[id] = preview
            }

            // Entry fees + payouts (idempotent; see reconcileFantasyLedger)
            await reconcileFantasyLedger(token: token)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Create & Join

    func createLeague(title: String, sport: String, isPrivate: Bool = false, maxMembers: Int = 12, rosterSize: Int = 12, pitcherSlots: Int = 2, batterSlots: Int = 6, scoringMode: BestBallScoringMode = .normal, nflQB: Int = 1, nflRB: Int = 2, nflWR: Int = 2, nflTE: Int = 1, nflFLEX: Int = 2, nflSFLEX: Int = 0, entryFee: Int = 10, nbaPG: Int? = nil, nbaSG: Int? = nil, nbaSF: Int? = nil, nbaPF: Int? = nil, nbaC: Int? = nil, nbaFLEX: Int? = nil, eplGK: Int? = nil, eplDEF: Int? = nil, eplMID: Int? = nil, eplFWD: Int? = nil, eplFLEX: Int? = nil, cfbPool: String? = nil, pickTimerSeconds: Int = 30) async -> BestBallLeague? {
        guard let uid = userID, let token = accessToken else { return nil }
        guard Self.isSportOpenForNewLeagues(sport) else {
            if sport == "NBA", Self.isSportJoinable(sport) {
                self.error = "NBA leagues open October 1 — check back closer to tip-off."
            } else {
                self.error = "The \(sport) season has already started — leagues for the next season open after it wraps."
            }
            return nil
        }
        if let reason = entryDenialReason(fee: entryFee, sport: sport) {
            self.error = reason
            return nil
        }
        do {
            let season = BestBallSeasonHelper.currentSeason(sport: sport)
            let record = try await SupabaseService.shared.createLeague(
                title: title, sport: sport, season: season,
                isPrivate: isPrivate, maxMembers: maxMembers, rosterSize: rosterSize,
                pitcherSlots: pitcherSlots, batterSlots: batterSlots,
                scoringMode: scoringMode.rawValue,
                nflQB: nflQB, nflRB: nflRB, nflWR: nflWR, nflTE: nflTE, nflFLEX: nflFLEX, nflSFLEX: nflSFLEX,
                entryFee: entryFee,
                nbaPG: nbaPG, nbaSG: nbaSG, nbaSF: nbaSF, nbaPF: nbaPF, nbaC: nbaC, nbaFLEX: nbaFLEX,
                eplGK: eplGK, eplDEF: eplDEF, eplMID: eplMID, eplFWD: eplFWD, eplFLEX: eplFLEX,
                cfbPool: cfbPool,
                pickTimerSeconds: pickTimerSeconds,
                createdBy: uid, accessToken: token
            )
            var league = record.toModel()

            // Supabase may not have the newer columns yet — ensure the model
            // reflects what the user actually requested so the detail view
            // shows the correct values immediately after creation.
            league.maxMembers = maxMembers
            league.rosterSize = rosterSize
            league.pitcherSlots = pitcherSlots
            league.batterSlots = batterSlots
            league.scoringMode = scoringMode
            league.nflQbStarters = nflQB
            league.nflRbStarters = nflRB
            league.nflWrStarters = nflWR
            league.nflTeStarters = nflTE
            league.nflFlexStarters = nflFLEX
            league.nflSflexStarters = nflSFLEX
            league.entryFee = entryFee
            league.eplGkStarters = eplGK
            league.eplDefStarters = eplDEF
            league.eplMidStarters = eplMID
            league.eplFwdStarters = eplFWD
            league.eplFlexStarters = eplFLEX
            league.cfbPool = cfbPool
            league.pickTimerSeconds = pickTimerSeconds

            // Cache so the detail view has the correct values right away
            currentLeague = league

            // Auto-join as first member
            _ = try await SupabaseService.shared.joinLeague(
                leagueID: league.id, userID: uid,
                displayName: profileName.isEmpty ? "Player" : profileName,
                slotIndex: 0, accessToken: token
            )

            // Optimistically surface the new league immediately — if the
            // loadMyLeagues refresh below hiccups (it swallows errors),
            // the league otherwise stays invisible until the next full
            // screen load, which reads as "my league vanished" (private
            // leagues especially, since Browse only lists public ones).
            if !myLeagues.contains(where: { $0.id == league.id }) {
                myLeagues.insert(league, at: 0)
            }

            await loadOpenLeagues()
            await loadMyLeagues()
            return league
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    // MARK: - Fantasy RR (entry fees)

    static let entryFeeTiers = [10, 20, 50, 100, 250, 500]

    /// How many non-completed leagues a user may hold PER SPORT at each
    /// fee level. Fantasy is a season-long commitment, so the caps step
    /// down as the stakes go up — 500 RR is a one-per-sport flagship.
    static func joinCap(forFee fee: Int) -> Int {
        switch fee {
        case ..<20: return 30
        case ..<50: return 15
        case ..<100: return 10
        case ..<250: return 5
        case ..<500: return 3
        default: return 1
        }
    }

    /// Non-completed leagues the user is in at this fee tier for a sport.
    func activeLeagueCount(atFee fee: Int, sport: String) -> Int {
        myLeagues.filter { $0.entryFee == fee && $0.sport == sport && $0.status != "completed" }.count
    }

    /// nil = allowed; otherwise a user-facing reason (shared by join+create).
    /// A sport is joinable until the day before its season starts —
    /// mid-season entries (e.g. MLB in August) draft against a schedule
    /// that's already half burned.
    static func isSportJoinable(_ sport: String) -> Bool {
        Date() < BestBallSeasonHelper.joinDeadline(for: sport)
    }

    /// Whether the sport should be offered for NEW leagues right now.
    /// Joinable is necessary but not sufficient: NBA stays hidden until
    /// Oct 1 — offering an NBA draft in August, months before rosters
    /// settle and 3+ weeks before tip-off, made no sense.
    static func isSportOpenForNewLeagues(_ sport: String) -> Bool {
        guard isSportJoinable(sport) else { return false }
        if sport == "NBA" {
            let calendar = Calendar(identifier: .gregorian)
            let year = calendar.component(.year, from: Date())
            let opens = calendar.date(from: DateComponents(year: year, month: 10, day: 1)) ?? Date()
            return Date() >= opens
        }
        return true
    }

    static func joinDeadlineNote(for sport: String) -> String {
        let deadline = BestBallSeasonHelper.joinDeadline(for: sport)
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        return "Join by \(fmt.string(from: deadline.addingTimeInterval(-24 * 3600)))"
    }

    func entryDenialReason(fee: Int, sport: String) -> String? {
        guard fee > 0 else { return nil }
        // Persisted profile RR (kept at the derived total by the
        // leaderboard sync) — this VM doesn't carry its own rrScore.
        let balance = UserDefaults.standard.integer(forKey: "rr_score")
        if balance < fee {
            return "Not enough RR — this league costs \(fee) RR to enter."
        }
        let cap = Self.joinCap(forFee: fee)
        if activeLeagueCount(atFee: fee, sport: sport) >= cap {
            if cap == 1 {
                return "You already have a \(fee) RR \(sport) league — it's limited to one per sport."
            }
            return "You're already in \(cap) \(sport) leagues at the \(fee) RR level — finish one first."
        }
        return nil
    }

    /// RR payout multiples by final standing. Season-long investment, so
    /// the top of the table pays meaningfully better than a daily contest.
    static func bestBallPayout(fee: Int, rank: Int, members: Int) -> Int {
        guard fee > 0, rank > 0 else { return 0 }
        if members >= 10 {
            switch rank {
            case 1: return fee * 5
            case 2: return fee * 2
            case 3: return fee
            default: return 0
            }
        }
        if members >= 6 {
            switch rank {
            case 1: return fee * 4
            case 2: return fee * 3 / 2
            default: return 0
            }
        }
        return rank == 1 ? fee * 3 : 0
    }

    /// Lazy self-charging + payouts. Fees are charged when a paid league
    /// has actually STARTED (drafting/active/completed) — nobody pays for
    /// an open league that might get deleted — and RLS only lets a user
    /// write their own ledger rows, so each member's own device charges
    /// them, exactly once (DB unique key makes retries idempotent).
    /// Completed leagues pay the top of the standings in fee multiples.
    private func reconcileFantasyLedger(token: String) async {
        guard let uid = userID else { return }
        // A FAILED fetch (nil) must never masquerade as an EMPTY one: with
        // `?? []` a single network hiccup computed total=0 and clobbered
        // the persisted fantasy_rr_delta — the home-pill Fantasy bucket
        // vanished until a later pass happened to succeed.
        guard let fetchedLedger = try? await SupabaseService.shared.fetchFantasyLedger(userID: uid, accessToken: token) else { return }
        var ledger = fetchedLedger
        func hasRow(_ ref: String, _ kind: String) -> Bool {
            ledger.contains { $0.refID == ref && $0.kind == kind }
        }
        var didInsert = false
        for league in myLeagues where league.entryFee > 0 && league.status != "open" {
            if !hasRow(league.id, "bestball_entry") {
                try? await SupabaseService.shared.insertFantasyLedgerRow(
                    userID: uid, refID: league.id, kind: "bestball_entry",
                    rrDelta: -league.entryFee, accessToken: token
                )
                didInsert = true
            }
            if league.status == "completed", !hasRow(league.id, "bestball_payout"),
               let membership = myMemberships.first(where: { $0.leagueId == league.id }) {
                let standingRecords = (try? await SupabaseService.shared.fetchStandings(leagueID: league.id, accessToken: token)) ?? []
                let standings = standingRecords.map { $0.toModel() }
                if let mine = standings.first(where: { $0.memberID == membership.id }) {
                    let payout = Self.bestBallPayout(
                        fee: league.entryFee, rank: mine.rank,
                        members: max(standings.count, league.maxMembers)
                    )
                    if payout > 0 {
                        try? await SupabaseService.shared.insertFantasyLedgerRow(
                            userID: uid, refID: league.id, kind: "bestball_payout",
                            rrDelta: payout, accessToken: token
                        )
                        didInsert = true
                    }
                }
            }
        }
        if didInsert {
            ledger = (try? await SupabaseService.shared.fetchFantasyLedger(userID: uid, accessToken: token)) ?? ledger
        }

        // Tiers/Bracket winnings & losses: those modes write rr_delta rows
        // into dfs_tournament_results under fantasy tids, which the DFS
        // bucket deliberately filters out — fold the newest row per contest
        // into the fantasy bucket and publish display rows for Profile.
        // limit 1000: the query is newest-first, and heavy daily DFS play can
        // push month-old tiers rows past a 500-row window — silently
        // shrinking the tiers component of the bucket.
        guard let serverRows = try? await SupabaseService.shared.fetchUserDFSHistory(userID: uid, limit: 1000, accessToken: token) else { return }
        var newestByTid: [String: DFSTournamentResultRecord] = [:]
        for row in serverRows {
            let tid = row.tournamentID
            guard DFSViewModel.isFantasyModeTid(tid), !tid.contains("#group-"),
                  !DFSViewModel.excludedTournamentIDs.contains(tid) else { continue }
            if let existing = newestByTid[tid] {
                if (row.createdAt ?? .distantPast) > (existing.createdAt ?? .distantPast) {
                    newestByTid[tid] = row
                }
            } else {
                newestByTid[tid] = row
            }
        }
        let tiersDelta = newestByTid.values.reduce(0) { $0 + $1.rrDelta }
        fantasyPastRows = newestByTid.map { (tid, row) in
            DFSResult(
                id: UUID(), tournamentTitle: Self.fantasyTitle(for: tid),
                rank: row.rank, totalEntries: max(1000, row.rank),
                lineupPoints: row.totalPoints, rrDelta: row.rrDelta,
                loggedAt: row.createdAt ?? Date(), tournamentId: tid, lineupNumber: nil
            )
        }.sorted { $0.loggedAt > $1.loggedAt }

        if UserDefaults.standard.integer(forKey: "fantasy_tiers_delta") != tiersDelta {
            UserDefaults.standard.set(tiersDelta, forKey: "fantasy_tiers_delta")
        }

        // Best Ball entry fees are committed when the league starts (the
        // row locks the fee) but only COUNT against RR once the league
        // completes — a 250 RR season-long entry shouldn't ding the pill
        // in week 1. Payouts and everything else count immediately.
        let completedLeagueIDs = Set(myLeagues.filter { $0.status == "completed" }.map(\.id))
        let bestballNet = ledger.reduce(0) { sum, row in
            guard row.kind.hasPrefix("bestball") else { return sum }
            if row.kind == "bestball_entry", !completedLeagueIDs.contains(row.refID) {
                return sum   // league still running — fee not realized yet
            }
            return sum + row.rrDelta
        }
        let survivorNet = ledger.filter { $0.kind.hasPrefix("survivor") }.reduce(0) { $0 + $1.rrDelta }
        // Persist the component so SurvivorViewModel (which can't see
        // league statuses) recomposes the same total.
        if UserDefaults.standard.integer(forKey: "fantasy_bestball_delta") != bestballNet {
            UserDefaults.standard.set(bestballNet, forKey: "fantasy_bestball_delta")
        }
        let total = bestballNet + survivorNet + tiersDelta
        fantasyLedgerDelta = total
        // Mirror into UserDefaults so ContentView's @AppStorage pill bucket
        // updates reactively; equality-guarded to avoid churn.
        if UserDefaults.standard.integer(forKey: "fantasy_rr_delta") != total {
            UserDefaults.standard.set(total, forKey: "fantasy_rr_delta")
        }
    }

    /// Display title for a fantasy-mode tid.
    private static func fantasyTitle(for tid: String) -> String {
        let base = tid.components(separatedBy: "#group-").first ?? tid
        if base.hasPrefix("world-cup-") { return "World Cup Tiers" }
        if base.hasPrefix("nba-playoffs-") { return "NBA Playoff Tiers" }
        if base.hasPrefix("masters-") { return "The Masters — Golf Tiers" }
        if base.hasPrefix("pga-championship-") { return "PGA Championship — Golf Tiers" }
        if base.hasPrefix("us-open-") { return "U.S. Open — Golf Tiers" }
        if base.hasPrefix("the-open-") { return "The Open — Golf Tiers" }
        if base.contains("-atp-") || base.contains("-wta-") {
            let tour = base.contains("-atp-") ? "ATP" : "WTA"
            if base.hasPrefix("wimbledon-") { return "Wimbledon — \(tour)" }
            if base.hasPrefix("us_open-") { return "US Open — \(tour)" }
            if base.hasPrefix("french_open-") { return "French Open — \(tour)" }
            if base.hasPrefix("australian_open-") { return "Australian Open — \(tour)" }
        }
        return "Fantasy Contest"
    }

    func joinLeague(_ league: BestBallLeague) async -> Bool {
        guard let uid = userID, let token = accessToken else { return false }
        guard Self.isSportJoinable(league.sport) else {
            self.error = "The \(league.sport) season has already started — this league can no longer be joined."
            return false
        }
        if let reason = entryDenialReason(fee: league.entryFee, sport: league.sport) {
            self.error = reason
            return false
        }
        do {
            let members = try await SupabaseService.shared.fetchLeagueMembers(leagueID: league.id, accessToken: token)
            let occupiedSlots = Set(members.map { $0.slotIndex })
            guard let nextSlot = (0..<league.maxMembers).first(where: { !occupiedSlots.contains($0) }) else {
                self.error = "League is full"
                return false
            }
            // Check not already a member
            if members.contains(where: { $0.userId == uid }) {
                self.error = "Already in this league"
                return false
            }
            _ = try await SupabaseService.shared.joinLeague(
                leagueID: league.id, userID: uid,
                displayName: profileName.isEmpty ? "Player" : profileName,
                slotIndex: nextSlot, accessToken: token
            )
            await loadOpenLeagues()
            await loadMyLeagues()
            // Refresh the detail view if it's currently showing this league —
            // otherwise the Members list and Joined count stay stale until
            // the user manually navigates away and back.
            if currentLeague?.id == league.id {
                await loadLeagueDetail(leagueID: league.id)
            }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Leave a Best Ball league. Only allowed when the league hasn't started
    /// drafting yet (status == "open"). Refreshes the detail view inline so
    /// the user's row disappears immediately.
    func leaveLeague(_ league: BestBallLeague) async -> Bool {
        guard let uid = userID, let token = accessToken else { return false }
        guard league.status == "open" else {
            self.error = "Can't leave a league that has already started drafting."
            return false
        }
        do {
            try await SupabaseService.shared.leaveLeague(
                leagueID: league.id, userID: uid, accessToken: token
            )
            await loadOpenLeagues()
            await loadMyLeagues()
            if currentLeague?.id == league.id {
                await loadLeagueDetail(leagueID: league.id)
            }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// ADMIN: force-remove a league from the account — no status/membership
    /// guards. Deletes the league outright when this user created it (RLS is
    /// creator-scoped, so the DELETE is a no-op otherwise), and always drops
    /// this user's own membership row so joined test leagues disappear too.
    /// Gated to admin emails in the UI (hub long-press).
    func adminDeleteLeague(_ league: BestBallLeague) async -> Bool {
        guard let uid = userID, let token = accessToken else { return false }
        do {
            if league.createdBy == uid {
                try await SupabaseService.shared.deleteLeague(leagueID: league.id, accessToken: token)
            } else {
                try await SupabaseService.shared.leaveLeague(leagueID: league.id, userID: uid, accessToken: token)
            }
            myLeagues.removeAll { $0.id == league.id }
            openLeagues.removeAll { $0.id == league.id }
            if currentLeague?.id == league.id {
                currentLeague = nil
                currentMembers = []
                draftState = nil
            }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Delete a Best Ball league. Restricted to the commissioner
    /// (`createdBy == userID`) AND only while the league is solo —
    /// before anyone else has joined — so we don't ever yank an active
    /// contest out from under the rest of the members. Once another
    /// human has signed up the only escape hatch is to leave (or wait
    /// for the season to finish).
    func deleteLeague(_ league: BestBallLeague) async -> Bool {
        guard let uid = userID, let token = accessToken else { return false }
        guard league.createdBy == uid else {
            self.error = "Only the league commissioner can delete this league."
            return false
        }
        let humanMembers = currentMembers.filter { !$0.isBot }
        let onlyMember = humanMembers.count <= 1 && humanMembers.allSatisfy { $0.userID == uid }
        guard onlyMember else {
            self.error = "Can't delete: other players have already joined this league."
            return false
        }
        guard league.status == "open" || league.status == "drafting" else {
            self.error = "Can't delete a league that has already started."
            return false
        }
        do {
            try await SupabaseService.shared.deleteLeague(
                leagueID: league.id, accessToken: token
            )
            // Clear local state for this league and refresh listings.
            if currentLeague?.id == league.id {
                currentLeague = nil
                currentMembers = []
                draftState = nil
                weeklyScores = []
                standings = []
            }
            await loadOpenLeagues()
            await loadMyLeagues()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    // MARK: - League Detail

    func loadLeagueDetail(leagueID: String) async {
        guard let token = accessToken else { return }
        isLoading = true
        error = nil
        // Only clear stale data when switching to a different league
        // Preserve currentLeague during reloads (e.g. after startDraft) to avoid
        // a brief nil state that causes "League not found" in the UI
        let isSameLeague = currentLeague?.id == leagueID
        if !isSameLeague {
            currentLeague = nil
            currentMembers = []
            standings = []
            weeklyScores = []
            draftState = nil
        }
        // Clear dingers HR cache only if switching to a different league
        if dingersHRCacheLeagueID != leagueID {
            liveHRByMember = [:]
        }
        defer { isLoading = false }
        do {
            if let record = try await SupabaseService.shared.fetchLeague(id: leagueID, accessToken: token) {
                var fetched = record.toModel()
                // If the DB didn't return newer columns (nil in the record),
                // preserve any user-specified values from the cached league
                // (e.g. right after createLeague before ALTER TABLE migrations run).
                if isSameLeague, let cached = currentLeague {
                    if record.maxMembers == nil { fetched.maxMembers = cached.maxMembers }
                    if record.pitcherSlots == nil { fetched.pitcherSlots = cached.pitcherSlots }
                    if record.batterSlots == nil { fetched.batterSlots = cached.batterSlots }
                    if record.scoringMode == nil { fetched.scoringMode = cached.scoringMode }
                }
                currentLeague = fetched
            }
            let memberRecords = try await SupabaseService.shared.fetchLeagueMembers(leagueID: leagueID, accessToken: token)
            currentMembers = memberRecords.map { $0.toModel() }

            if currentLeague?.status == "drafting" || currentLeague?.status == "active" || currentLeague?.status == "completed" {
                let pickRecords = try await SupabaseService.shared.fetchDraftPicks(leagueID: leagueID, accessToken: token)
                let picks = pickRecords.map { $0.toModel() }

                if currentLeague?.status == "drafting" {
                    await loadNFLByeWeeksIfNeeded()
                    await loadCFBByeWeeksIfNeeded()
                    if let sport = currentLeague?.sport {
                        // Key the cached pool by sport + CFB scope so
                        // switching between leagues with different pools
                        // (or sports) refetches instead of reusing.
                        let poolKey = "\(sport)|\(currentLeague?.cfbPool ?? "all")"
                        if availablePlayers.isEmpty || availablePlayersKey != poolKey {
                            var players = (try? await playerProvider.fetchPlayers(sport: sport, cfbPool: currentLeague?.cfbPool)) ?? []
                            if currentLeague?.isDingersOnly == true {
                                players = players.filter { !BestBallLineupConfig.isPitcher($0.position) }
                            }
                            availablePlayers = players
                            availablePlayersKey = poolKey
                        }
                    }
                    let state = BestBallDraftState(
                        league: currentLeague!,
                        members: currentMembers,
                        picks: picks,
                        availablePlayers: availablePlayers
                    )
                    draftState = state

                    if picks.count != lastObservedPickCount {
                        lastObservedPickCount = picks.count
                        lastPickActivityAt = Date()
                    }

                    // Auto-recover: if all picks are in but status is still "drafting", transition to active
                    if state.isDraftComplete {
                        try await SupabaseService.shared.updateLeagueStatus(
                            leagueID: leagueID, status: "active",
                            accessToken: token
                        )
                        currentLeague?.status = "active"
                        stopDraftPolling()
                        // Refresh the hub list so the league card stops
                        // reading DRAFTING after the draft wraps.
                        await loadMyLeagues()
                    }
                } else {
                    draftState = BestBallDraftState(
                        league: currentLeague!,
                        members: currentMembers,
                        picks: picks,
                        availablePlayers: []
                    )
                }
            }

            if currentLeague?.status == "active" || currentLeague?.status == "completed" {
                await loadNFLByeWeeksIfNeeded()
                await loadCFBByeWeeksIfNeeded()
                // Auto-generate schedule if missing (pre-V2 leagues)
                if let league = currentLeague, league.schedule.isEmpty, !currentMembers.isEmpty {
                    await generateScheduleAfterDraft(leagueID: leagueID)
                    // Re-fetch league to get the schedule
                    if let record = try await SupabaseService.shared.fetchLeague(id: leagueID, accessToken: token) {
                        currentLeague = record.toModel()
                    }
                }

                let scoreRecords = try await SupabaseService.shared.fetchWeeklyScores(leagueID: leagueID, accessToken: token)
                weeklyScores = scoreRecords.map { $0.toModel() }
                await purgeFutureWeekScores(leagueID: leagueID, token: token)
                let standingRecords = try await SupabaseService.shared.fetchStandings(leagueID: leagueID, accessToken: token)
                standings = standingRecords.map { $0.toModel() }

                // Set selected week to current (capped to real calendar week to avoid showing future weeks)
                if let league = currentLeague {
                    if league.sport == "EPL" { await EPLMatchweekProvider.refreshIfStale() }
                    let realWeek = BestBallSeasonHelper.currentWeekNumber(for: league.sport)
                    // Land on the CALENDAR week, like the hub card. The
                    // stored currentWeek is a scoring cursor that lags until
                    // last week gets graded — clamping to it opened the
                    // league on "Week 1" after gameweek 2 had kicked off.
                    selectedWeek = min(realWeek, league.totalWeeks)
                    loadMatchupsForWeek(week: selectedWeek, league: league)

                    // Also load daily scores for the current week
                    await loadDailyScores(leagueID: leagueID, week: selectedWeek)

                    // Set selected date to today if within this week, otherwise week start
                    let today = Date()
                    let (weekStart, weekEnd) = BestBallSeasonHelper.weekDateRange(sport: league.sport, week: selectedWeek)
                    if today >= weekStart && today <= weekEnd {
                        selectedDate = today
                    } else {
                        selectedDate = weekStart
                    }
                }
            }
        } catch is CancellationError {
            // Navigated away — ignore
        } catch let error as NSError where error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
            // URL request cancelled — ignore
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Matchup Loading

    func loadMatchupsForWeek(week: Int, league: BestBallLeague) {
        guard week > 0, week <= league.schedule.count else {
            currentWeekMatchups = []
            myMatchup = nil
            return
        }

        let weekPairs = league.schedule[week - 1]  // 0-indexed
        var matchups: [BestBallMatchup] = []

        for pair in weekPairs {
            guard pair.count == 2 else { continue }
            let m1 = pair[0]
            let m2 = pair[1]

            // Find scores for this week
            let m1Score = weeklyScores.first(where: { $0.memberID == m1 && $0.week == week })?.totalPoints ?? 0
            let m2Score = weeklyScores.first(where: { $0.memberID == m2 && $0.week == week })?.totalPoints ?? 0

            var winnerID: String?
            if weeklyScores.contains(where: { $0.week == week }) {
                if m1Score > m2Score {
                    winnerID = m1
                } else if m2Score > m1Score {
                    winnerID = m2
                }
                // nil means tie or not yet scored
            }

            matchups.append(BestBallMatchup(
                week: week,
                member1ID: m1, member2ID: m2,
                member1Score: m1Score, member2Score: m2Score,
                winnerID: winnerID
            ))
        }

        currentWeekMatchups = matchups

        // Find my matchup
        if let myID = myMemberID {
            myMatchup = matchups.first(where: { $0.member1ID == myID || $0.member2ID == myID })
        } else {
            myMatchup = nil
        }
    }

    // MARK: - Draft

    func startDraft(leagueID: String) async {
        guard let token = accessToken else { return }
        isStartingDraft = true
        defer { isStartingDraft = false }
        do {
            // Fetch current members
            let memberRecords = try await SupabaseService.shared.fetchLeagueMembers(leagueID: leagueID, accessToken: token)
            var members = memberRecords.map { $0.toModel() }
            let occupiedSlots = Set(members.map { $0.slotIndex })

            // Fill empty slots with bots up to maxMembers
            let maxSlots = currentLeague?.maxMembers ?? 12
            for slot in 0..<maxSlots where !occupiedSlots.contains(slot) {
                let botRecord = try await SupabaseService.shared.addBot(
                    leagueID: leagueID,
                    slotIndex: slot,
                    displayName: BestBallBotDrafter.botName(at: slot),
                    accessToken: token
                )
                members.append(botRecord.toModel())
            }

            // Randomize draft order (member IDs shuffled)
            let shuffledIDs = members.map { $0.id }.shuffled()

            // Arm the in-draft countdown BEFORE flipping status: when
            // other devices see "drafting" and transition in, the shared
            // 30s pre-pick clock is already set, so nobody loses pick
            // time to the screen transition.
            try? await SupabaseService.shared.updateLeagueDraftStartTime(
                leagueID: leagueID, date: Date().addingTimeInterval(30), accessToken: token
            )

            // Update league to drafting
            try await SupabaseService.shared.updateLeagueDraft(
                leagueID: leagueID,
                draftOrder: shuffledIDs,
                currentPickNumber: 1,
                status: "drafting",
                accessToken: token
            )

            // Load players for draft
            if let league = currentLeague {
                var players = (try? await playerProvider.fetchPlayers(sport: league.sport, cfbPool: league.cfbPool)) ?? []
                if league.isDingersOnly {
                    players = players.filter { !BestBallLineupConfig.isPitcher($0.position) }
                }
                availablePlayers = players
                availablePlayersKey = "\(league.sport)|\(league.cfbPool ?? "all")"
            }

            await loadLeagueDetail(leagueID: leagueID)
            startDraftPolling(leagueID: leagueID)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Commissioner sets (or clears) the scheduled auto-start time.
    func setDraftStartTime(leagueID: String, date: Date?) async {
        guard let token = accessToken else { return }
        do {
            try await SupabaseService.shared.updateLeagueDraftStartTime(
                leagueID: leagueID, date: date, accessToken: token
            )
            await loadLeagueDetail(leagueID: leagueID)
            // Refresh the hub list AND re-sync local draft reminders.
            await loadMyLeagues()
        } catch {
            self.error = error.localizedDescription
        }
    }


    /// Fires a scheduled draft once its start time passes while members
    /// sit in the lobby. The host's device starts it right on time; other
    /// members act as staggered backups (20s apart) so the draft still
    /// starts when the host isn't in the app. A device race is guarded by
    /// the unique (league_id, slot_index) constraint on members — the
    /// loser's bot inserts fail and it just reloads the drafting league.
    func autoStartScheduledDraftIfDue() async {
        guard let league = currentLeague, league.status == "open",
              let scheduled = league.draftStartTime,
              let uid = userID, !isStartingDraft else { return }
        let humans = currentMembers.filter { !$0.isBot }.sorted { $0.slotIndex < $1.slotIndex }
        var ladder = [league.createdBy].compactMap { $0 }
        ladder.append(contentsOf: humans.compactMap(\.userID).filter { !ladder.contains($0) })
        guard let myIndex = ladder.firstIndex(of: uid) else { return }
        let myTriggerTime = scheduled.addingTimeInterval(Double(myIndex) * 20.0)
        guard Date() >= myTriggerTime else { return }
        await startDraft(leagueID: league.id)
    }

    /// Whether drafting `player` still leaves enough roster spots to fill
    /// every starting slot. Blocks e.g. a 3rd QB in a 1-QB league when
    /// the remaining picks are needed for open RB/WR/TE/FLEX slots —
    /// works off the league's actual slot constraints, so FLEX/SFLEX and
    /// the EPL shapes are handled without per-sport hardcoding.
    func pickKeepsLineupFillable(_ player: BestBallPlayer) -> Bool {
        guard let league = currentLeague, let state = draftState,
              let myID = myMemberID else { return true }
        let constraints = BestBallLineupConfig.requirements(for: league).constraints
        guard !constraints.isEmpty else { return true }
        let roster = state.roster(for: myID)
        var positions: [String: String] = [:]
        var points: [String: Double] = [:]
        for pick in roster {
            positions[pick.playerID] = pick.playerPosition
            points[pick.playerID] = 1
        }
        positions[player.id] = player.position
        points[player.id] = 0
        let ids = roster.map(\.playerID) + [player.id]
        let assigned = BestBallLineupConfig.assignStartersToSlots(
            scoringIDs: ids, positions: positions, points: points, constraints: constraints
        )
        let starters = constraints.reduce(0) { $0 + $1.count }
        let unfilledSlots = starters - assigned.count
        let remainingPicksAfter = league.rosterSize - ids.count
        return unfilledSlots <= remainingPicksAfter
    }

    func makePick(player: BestBallPlayer) async {
        // Drafted (by anyone) or drafting now — either way it leaves the queue.
        draftQueue.removeAll { $0 == player.id }
        guard let state = draftState, !state.isDraftComplete,
              let token = accessToken, let uid = userID else { return }
        guard pickKeepsLineupFillable(player) else {
            self.error = "Can't draft another \(player.position) — your remaining picks are needed to fill your open starting slots."
            return
        }
        guard draftHasOpened else {
            self.error = "Draft starts in a few seconds…"
            return
        }

        // Verify it's the user's turn
        let myMemberID = currentMembers.first(where: { $0.userID == uid })?.id
        guard let myID = myMemberID, state.onTheClockMemberID == myID else {
            self.error = "Not your turn"
            return
        }

        do {
            let pickNumber = state.currentPickNumber
            let round = state.currentRound

            _ = try await SupabaseService.shared.submitDraftPick(
                leagueID: state.league.id, memberID: myID,
                pickNumber: pickNumber, round: round,
                playerID: player.id, playerName: player.name,
                playerTeam: player.team, playerPosition: player.position,
                accessToken: token
            )

            try await SupabaseService.shared.updateLeaguePickNumber(
                leagueID: state.league.id, pickNumber: pickNumber + 1,
                accessToken: token
            )

            await loadLeagueDetail(leagueID: state.league.id)
            await executeBotPicksIfNeeded()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func executeBotPicksIfNeeded() async {
        guard let state = draftState,
              let token = accessToken, let uid = userID else { return }

        // Any human's device can advance the draft, on a staggered failover
        // ladder: the first human acts immediately, later humans only step
        // in after picks stop advancing (host backgrounded the app
        // mid-draft — without failover the whole draft froze at 0 seconds
        // for everyone else). A race between two devices is harmless:
        // bestball_picks has a unique (league_id, pick_number) constraint,
        // so the loser's insert fails and the next 2s poll resyncs.
        let humans = currentMembers.filter { !$0.isBot }.sorted(by: { $0.slotIndex < $1.slotIndex })
        guard let myHumanIndex = humans.firstIndex(where: { $0.userID == uid }) else { return }

        // Nobody (bots included) picks during the in-draft countdown.
        guard draftHasOpened else { return }

        // If draft is already complete (e.g. last pick was human), transition immediately
        if state.isDraftComplete {
            do {
                try await SupabaseService.shared.updateLeagueStatus(
                    leagueID: state.league.id, status: "active",
                    accessToken: token
                )
                stopDraftPolling()

                // Generate round-robin schedule
                await generateScheduleAfterDraft(leagueID: state.league.id)

                await loadLeagueDetail(leagueID: state.league.id)
                await loadMyLeagues()
            } catch {
                self.error = error.localizedDescription
            }
            return
        }

        let sport = state.league.sport
        let rosterSize = state.league.rosterSize
        var currentState = state
        var actedThisRun = false
        while !currentState.isDraftComplete {
            guard let onClockID = currentState.onTheClockMemberID,
                  let onClockMember = currentMembers.first(where: { $0.id == onClockID }) else {
                break
            }

            let stalledFor = Date().timeIntervalSince(pickClockStart)
            if onClockMember.isBot {
                // Ladder index 0 picks for bots right away; other devices
                // wait out their failover delay before taking over. Once a
                // device has started acting this run it keeps going — the
                // activity clock resets on every pick it lands.
                if !actedThisRun, stalledFor < Double(myHumanIndex) * 12.0 { break }
            } else {
                // Human on the clock — their own device drives the pick
                // (a tap, or its local auto-pick when the timer hits 0).
                // Another device only picks for them once they've clearly
                // gone away: full pick timer plus grace, staggered per
                // device so two failover devices don't collide.
                if onClockMember.userID == uid { break }
                let timerSeconds = Double(currentLeague?.pickTimerSeconds ?? 30)
                if stalledFor < timerSeconds + 10.0 + Double(myHumanIndex) * 12.0 { break }
            }

            let pickedIDs = currentState.pickedPlayerIDs()
            let available = availablePlayers.filter { !pickedIDs.contains($0.id) }
            let botRoster = currentState.roster(for: onClockID)

            guard let pick = BestBallBotDrafter.pickForBot(
                available: available, existingRoster: botRoster,
                sport: sport, rosterSize: rosterSize,
                scoringMode: currentLeague?.scoringMode ?? .normal,
                pitcherSlots: currentLeague?.pitcherSlots ?? 2,
                batterSlots: currentLeague?.batterSlots ?? 6,
                nflQB: currentLeague?.nflQbStarters ?? 1,
                nflRB: currentLeague?.nflRbStarters ?? 2,
                nflWR: currentLeague?.nflWrStarters ?? 2,
                nflTE: currentLeague?.nflTeStarters ?? 1,
                nflFLEX: currentLeague?.nflFlexStarters ?? 2,
                nflSFLEX: currentLeague?.nflSflexStarters ?? 0,
                eplGK: currentLeague?.eplGkStarters ?? 1,
                eplDEF: currentLeague?.eplDefStarters ?? 3,
                eplMID: currentLeague?.eplMidStarters ?? 4,
                eplFWD: currentLeague?.eplFwdStarters ?? 2,
                eplFLEX: currentLeague?.eplFlexStarters ?? 1
            ) else { break }

            let pickNumber = currentState.currentPickNumber
            let round = currentState.currentRound

            do {
                _ = try await SupabaseService.shared.submitDraftPick(
                    leagueID: currentState.league.id, memberID: onClockID,
                    pickNumber: pickNumber, round: round,
                    playerID: pick.id, playerName: pick.name,
                    playerTeam: pick.team, playerPosition: pick.position,
                    accessToken: token
                )

                let newPickNumber = pickNumber + 1
                try await SupabaseService.shared.updateLeaguePickNumber(
                    leagueID: currentState.league.id, pickNumber: newPickNumber,
                    accessToken: token
                )

                actedThisRun = true
                await loadLeagueDetail(leagueID: currentState.league.id)
                guard let updated = draftState else { break }
                currentState = updated

                // Pace bot picks so the user can follow the ticker
                // instead of the draft blurring past in milliseconds.
                // Humans still get the full 30s timer; bots intentionally
                // move quickly but not instantly.
                if !currentState.isDraftComplete,
                   let nextID = currentState.onTheClockMemberID,
                   let nextMember = currentMembers.first(where: { $0.id == nextID }),
                   nextMember.isBot {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)   // 3s between bot picks
                }
            } catch {
                break
            }
        }

        // Check if draft is complete
        if currentState.isDraftComplete {
            do {
                try await SupabaseService.shared.updateLeagueStatus(
                    leagueID: currentState.league.id, status: "active",
                    accessToken: token
                )
                stopDraftPolling()

                // Generate round-robin schedule
                await generateScheduleAfterDraft(leagueID: currentState.league.id)

                await loadLeagueDetail(leagueID: currentState.league.id)
                await loadMyLeagues()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: - Schedule Generation

    /// Seed 0-0 standings rows the moment a draft completes so the hub
    /// card and standings tab show rank/record before any scoring runs.
    /// No-op once standings exist (safe across racing devices — upsert
    /// on (league_id, member_id)).
    private func seedInitialStandings(leagueID: String) async {
        guard let token = accessToken, !currentMembers.isEmpty else { return }
        let existing = (try? await SupabaseService.shared.fetchStandings(leagueID: leagueID, accessToken: token)) ?? []
        guard existing.isEmpty else { return }
        let ordered = currentMembers.sorted { $0.slotIndex < $1.slotIndex }
        let rows = ordered.enumerated().map { idx, member in
            (leagueID: leagueID, memberID: member.id, totalPoints: 0.0,
             weeksScored: 0, rank: idx + 1, wins: 0, losses: 0)
        }
        try? await SupabaseService.shared.batchUpsertStandings(standings: rows, accessToken: token)
    }

    private func generateScheduleAfterDraft(leagueID: String) async {
        guard let token = accessToken, let league = currentLeague else { return }
        // Skip schedule for dingers-only leagues (no H2H matchups)
        guard !league.isDingersOnly else { return }
        await seedInitialStandings(leagueID: leagueID)
        let memberIDs = currentMembers.map { $0.id }
        let schedule = BestBallScheduleGenerator.generateSchedule(
            memberIDs: memberIDs, totalWeeks: league.totalWeeks
        )
        // NEVER persist an empty schedule — an empty write poisons the
        // league (the Matchup tab reads [] forever and the auto-heal keeps
        // regenerating the same emptiness). With bye support in the
        // generator, empty here means inputs were genuinely broken.
        guard !schedule.isEmpty else {
            print("[BestBall] Schedule generation produced 0 weeks for \(leagueID) (members=\(memberIDs.count), totalWeeks=\(league.totalWeeks)) — not persisting")
            return
        }
        let weekStructure = league.sport == "NFL" ? "thu_mon" : "mon_sun"
        // Retry the write: a cancelled/failed PATCH here used to strand the
        // league schedule-less until the next full league open.
        for attempt in 1...3 {
            do {
                try await SupabaseService.shared.updateLeagueSchedule(
                    leagueID: leagueID, schedule: schedule,
                    weekStructure: weekStructure, accessToken: token
                )
                // Reflect locally so the Matchup tab works immediately.
                currentLeague?.schedule = schedule
                return
            } catch {
                if attempt == 3 {
                    self.error = error.localizedDescription
                } else {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                }
            }
        }
    }

    // MARK: - Draft Polling

    func startDraftPolling(leagueID: String) {
        stopDraftPolling()
        isDraftPolling = true
        draftPollTask = Task {
            while !Task.isCancelled && isDraftPolling {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { break }
                await loadLeagueDetail(leagueID: leagueID)
                if currentLeague?.status != "drafting" {
                    isDraftPolling = false
                    break
                }
                await executeBotPicksIfNeeded()
            }
        }
    }

    func stopDraftPolling() {
        isDraftPolling = false
        draftPollTask?.cancel()
        draftPollTask = nil
    }

    // MARK: - Weekly Scoring (Enhanced with H2H)

    func computeWeeklyScores(leagueID: String) async {
        guard let league = currentLeague, let state = draftState,
              let token = accessToken else { return }

        // EPL weeks are official matchweeks — never score against the legacy
        // Mon-Sun fallback (it mis-filed Monday games into the next week).
        if league.sport == "EPL" { await EPLMatchweekProvider.refreshIfStale() }
        let realWeek = BestBallSeasonHelper.currentWeekNumber(for: league.sport)
        // Score the calendar week (not the stored week) to avoid scoring a future week
        let week = min(league.currentWeek, realWeek)
        // Only advance the week if its end date has passed (+ 1 day buffer for late game results)
        let (_, weekEnd) = BestBallSeasonHelper.weekDateRange(sport: league.sport, week: week)
        let weekHasEnded = Date() > (Calendar.current.date(byAdding: .day, value: 1, to: weekEnd) ?? weekEnd)
        await computeWeeklyScoresForWeek(leagueID: leagueID, week: week, league: league, state: state, token: token, advanceWeek: weekHasEnded)
        await loadLeagueDetail(leagueID: leagueID)
    }

    /// Score a specific week. If advanceWeek is true, advances the league to the next week after scoring.
    private func computeWeeklyScoresForWeek(
        leagueID: String, week: Int,
        league: BestBallLeague, state: BestBallDraftState,
        token: String, advanceWeek: Bool
    ) async {
        let (start, end) = BestBallSeasonHelper.weekDateRange(sport: league.sport, week: week)

        do {
            // Build player positions map from draft picks
            var playerPositions: [String: String] = [:]
            for pick in state.picks {
                playerPositions[pick.playerID] = pick.playerPosition
            }

            // Phase 1: Fetch all ESPN data for this week ONCE (all players, all games)
            let allPlayerResult = try await scoringProvider.fetchWeeklyAllPlayerStats(
                sport: league.sport, weekStartDate: start, weekEndDate: end,
                // Bounds the EPL per-player detail-stat fan-out (DK crosses/
                // passes/tackles) to players someone actually drafted.
                restrictToPlayerIDs: Set(state.picks.map(\.playerID))
            )

            // Phase 1b: Extract per-member scores from the bulk result
            struct MemberScoringData {
                let total: Double
                let scoringIDs: [String]
                let playerPoints: [String: Double]
                let playerStats: [String: [String: Double]]
                let dailyBreakdown: [String: [String: Double]]
                let dailyStats: [String: [String: [String: Double]]]
            }
            var memberData: [String: MemberScoringData] = [:]

            for member in currentMembers {
                let roster = state.roster(for: member.id)
                let playerIDSet = Set(roster.map { $0.playerID })

                // Filter the bulk result to just this member's players
                let memberPoints = allPlayerResult.playerPoints.filter { playerIDSet.contains($0.key) }
                guard !memberPoints.isEmpty else { continue }

                let memberStats = allPlayerResult.playerStats.filter { playerIDSet.contains($0.key) }
                var memberDailyBreakdown: [String: [String: Double]] = [:]
                var memberDailyStats: [String: [String: [String: Double]]] = [:]
                for (dateKey, dayPlayers) in allPlayerResult.dailyBreakdown {
                    let filtered = dayPlayers.filter { playerIDSet.contains($0.key) }
                    if !filtered.isEmpty { memberDailyBreakdown[dateKey] = filtered }
                }
                for (dateKey, dayPlayers) in allPlayerResult.dailyStats {
                    let filtered = dayPlayers.filter { playerIDSet.contains($0.key) }
                    if !filtered.isEmpty { memberDailyStats[dateKey] = filtered }
                }

                // For dingers-only mode, override playerPoints with raw HR counts
                let effectivePlayerPoints: [String: Double]
                if league.isDingersOnly {
                    effectivePlayerPoints = memberStats.mapValues { $0["HR"] ?? 0 }
                } else {
                    effectivePlayerPoints = memberPoints
                }

                let (total, scoringIDs) = BestBallScoringEngine.bestBallScore(
                    playerPoints: effectivePlayerPoints,
                    playerPositions: playerPositions,
                    sport: league.sport,
                    scoringSlots: league.scoringSlots,
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

                memberData[member.id] = MemberScoringData(
                    total: total, scoringIDs: scoringIDs,
                    playerPoints: effectivePlayerPoints, playerStats: memberStats,
                    dailyBreakdown: memberDailyBreakdown, dailyStats: memberDailyStats
                )
            }

            // Phase 2: Resolve H2H matchup results (skip for dingers-only)
            var memberMatchupResult: [String: String] = [:]  // memberID -> "win"/"loss"
            var memberOpponent: [String: String] = [:]        // memberID -> opponentMemberID
            if league.scoringMode == .normal, week > 0, week <= league.schedule.count {
                let weekPairs = league.schedule[week - 1]
                for pair in weekPairs {
                    guard pair.count == 2 else { continue }
                    let m1 = pair[0], m2 = pair[1]
                    let s1 = memberData[m1]?.total ?? 0
                    let s2 = memberData[m2]?.total ?? 0

                    memberOpponent[m1] = m2
                    memberOpponent[m2] = m1
                    if s1 > s2 {
                        memberMatchupResult[m1] = "win"
                        memberMatchupResult[m2] = "loss"
                    } else if s2 > s1 {
                        memberMatchupResult[m1] = "loss"
                        memberMatchupResult[m2] = "win"
                    } else {
                        // Tie — both get a "tie" (count as neither win nor loss)
                        memberMatchupResult[m1] = "tie"
                        memberMatchupResult[m2] = "tie"
                    }
                }
            }

            // Phase 3: Batch write all weekly scores in a single POST
            let weeklyScoreEntries = currentMembers.compactMap { member -> (memberID: String, totalPoints: Double, scoringPlayerIDs: [String], playerPoints: [String: Double], playerStats: [String: [String: Double]], opponentMemberID: String?, matchupResult: String?)? in
                guard let data = memberData[member.id] else { return nil }
                return (member.id, data.total, data.scoringIDs, data.playerPoints, data.playerStats, memberOpponent[member.id], memberMatchupResult[member.id])
            }
            try await SupabaseService.shared.batchUpsertWeeklyScores(
                leagueID: leagueID, week: week,
                memberScores: weeklyScoreEntries,
                accessToken: token
            )

            // Batch write all daily scores in a single POST
            var dailyEntries: [(leagueID: String, memberID: String, week: Int, gameDate: String, playerPoints: [String: Double], playerStats: [String: [String: Double]])] = []
            for member in currentMembers {
                guard let data = memberData[member.id] else { continue }
                for (dateKey, dayPoints) in data.dailyBreakdown {
                    let dayStats = data.dailyStats[dateKey] ?? [:]
                    dailyEntries.append((leagueID, member.id, week, dateKey, dayPoints, dayStats))
                }
            }
            try await SupabaseService.shared.batchUpsertDailyScores(entries: dailyEntries, accessToken: token)

            // Recompute standings locally from what we just computed + existing scores
            // Build updated weeklyScores from DB + this week's new data
            var updatedScores = weeklyScores.filter { $0.week != week }
            for member in currentMembers {
                guard let data = memberData[member.id] else { continue }
                updatedScores.append(BestBallWeeklyScore(
                    id: "\(leagueID)-\(member.id)-\(week)",
                    leagueID: leagueID, memberID: member.id, week: week,
                    totalPoints: data.total, scoringPlayerIDs: data.scoringIDs,
                    playerPoints: data.playerPoints, playerStats: data.playerStats,
                    opponentMemberID: memberOpponent[member.id],
                    matchupResult: memberMatchupResult[member.id]
                ))
            }
            weeklyScores = updatedScores

            let newStandings = BestBallScoringEngine.computeStandings(weeklyScores: updatedScores, members: currentMembers, scoringMode: league.scoringMode)

            // Batch write standings in a single POST
            let standingEntries = newStandings.map { s in
                (leagueID: leagueID, memberID: s.memberID, totalPoints: s.totalPoints, weeksScored: s.weeksScored, rank: s.rank, wins: s.wins, losses: s.losses)
            }
            try await SupabaseService.shared.batchUpsertStandings(standings: standingEntries, accessToken: token)

            // Advance week if applicable
            if advanceWeek {
                if week < league.totalWeeks {
                    try await SupabaseService.shared.updateLeagueWeek(
                        leagueID: leagueID, week: week + 1, accessToken: token
                    )
                } else {
                    try await SupabaseService.shared.updateLeagueStatus(
                        leagueID: leagueID, status: "completed", accessToken: token
                    )
                }
            }
        } catch is CancellationError {
            // Task was cancelled (e.g. user navigated away) — don't show error
        } catch let error as NSError where error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
            // URLSession request was cancelled — don't show error
        } catch {
            self.error = "Week \(week) scoring error: \(error.localizedDescription)"
            print("[BestBall] Scoring error for week \(week): \(error)")
        }
    }

    /// Catches up scoring for all past weeks that haven't been scored yet, up to the real current week.
    /// Also re-scores weeks that have incomplete data (0 points or missing matchup results).
    func catchUpScoring(leagueID: String) async {
        guard let league = currentLeague, let state = draftState,
              let token = accessToken, league.status == "active" else {
            catchUpProgress = "Cannot score: league or draft data not loaded"
            return
        }

        if league.sport == "EPL" { await EPLMatchweekProvider.refreshIfStale() }
        let realWeek = BestBallSeasonHelper.currentWeekNumber(for: league.sport)
        let targetWeek = min(realWeek, league.totalWeeks)

        // Figure out which weeks actually need scoring BEFORE starting any work
        var weeksToScore: [Int] = []
        for week in 1...targetWeek {
            let weekScores = weeklyScores.filter { $0.week == week }
            let (_, catchUpWeekEnd) = BestBallSeasonHelper.weekDateRange(sport: league.sport, week: week)
            let weekEndedLongEnough = Date() > (Calendar.current.date(byAdding: .day, value: 1, to: catchUpWeekEnd) ?? catchUpWeekEnd)
            let isFullyScored = weekEndedLongEnough
                && !weekScores.isEmpty
                && weekScores.allSatisfy { $0.matchupResult != nil && !$0.matchupResult!.isEmpty }
                && weekScores.contains(where: { $0.totalPoints > 0 })

            if !isFullyScored {
                weeksToScore.append(week)
            }
        }

        guard !weeksToScore.isEmpty else {
            catchUpProgress = ""
            return
        }

        // Score only the weeks that need it
        for (idx, week) in weeksToScore.enumerated() {
            guard !Task.isCancelled else { break }

            catchUpProgress = "Scoring week \(week) of \(targetWeek) (\(idx + 1)/\(weeksToScore.count))..."

            let (_, catchUpWeekEnd) = BestBallSeasonHelper.weekDateRange(sport: league.sport, week: week)
            let weekEndedLongEnough = Date() > (Calendar.current.date(byAdding: .day, value: 1, to: catchUpWeekEnd) ?? catchUpWeekEnd)
            let shouldAdvance = week >= league.currentWeek && weekEndedLongEnough

            await computeWeeklyScoresForWeek(
                leagueID: leagueID, week: week,
                league: league, state: state,
                token: token, advanceWeek: shouldAdvance
            )
        }

        catchUpProgress = ""
        // Single reload at the end to pick up all new data
        await loadLeagueDetail(leagueID: leagueID)
    }

    // MARK: - Live Scoring

    func startLiveScoring(leagueID: String) {
        stopLiveScoring()
        isLivePolling = true
        livePollTask = Task {
            while !Task.isCancelled && isLivePolling {
                await refreshLiveScores(leagueID: leagueID)
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s
            }
        }
    }

    func stopLiveScoring() {
        isLivePolling = false
        livePollTask?.cancel()
        livePollTask = nil
    }

    private func refreshLiveScores(leagueID: String) async {
        guard let league = currentLeague, let state = draftState,
              let token = accessToken else { return }

        let week = selectedWeek
        let (start, end) = BestBallSeasonHelper.weekDateRange(sport: league.sport, week: week)

        var playerPositions: [String: String] = [:]
        for pick in state.picks {
            playerPositions[pick.playerID] = pick.playerPosition
        }

        do {
            for member in currentMembers {
                let roster = state.roster(for: member.id)
                let playerIDs = roster.map { $0.playerID }

                let result = try await scoringProvider.fetchWeeklyPointsWithStats(
                    sport: league.sport, playerIDs: playerIDs,
                    weekStartDate: start, weekEndDate: end
                )

                guard !result.playerPoints.isEmpty else { continue }

                // For dingers-only mode, override playerPoints with raw HR counts
                let effectivePlayerPoints: [String: Double]
                if league.isDingersOnly {
                    effectivePlayerPoints = result.playerStats.mapValues { $0["HR"] ?? 0 }
                } else {
                    effectivePlayerPoints = result.playerPoints
                }

                let (total, scoringIDs) = BestBallScoringEngine.bestBallScore(
                    playerPoints: effectivePlayerPoints,
                    playerPositions: playerPositions,
                    sport: league.sport,
                    scoringSlots: league.scoringSlots,
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

                // Find opponent (skip for dingers-only)
                var opponentID: String?
                if league.scoringMode == .normal, week > 0, week <= league.schedule.count {
                    let weekPairs = league.schedule[week - 1]
                    for pair in weekPairs {
                        if pair.contains(member.id), let other = pair.first(where: { $0 != member.id }) {
                            opponentID = other
                            break
                        }
                    }
                }

                try await SupabaseService.shared.upsertWeeklyScore(
                    leagueID: leagueID, memberID: member.id, week: week,
                    totalPoints: total, scoringPlayerIDs: scoringIDs,
                    playerPoints: result.playerPoints,
                    playerStats: result.playerStats,
                    opponentMemberID: opponentID,
                    accessToken: token
                )
            }

            // Reload scores
            let scoreRecords = try await SupabaseService.shared.fetchWeeklyScores(leagueID: leagueID, accessToken: token)
            weeklyScores = scoreRecords.map { $0.toModel() }

            if let league = currentLeague {
                loadMatchupsForWeek(week: selectedWeek, league: league)
            }
        } catch {
            // Silently continue on live poll errors
        }
    }

    // MARK: - Daily Scores

    /// Delete stored scores for any week whose window hasn't STARTED yet.
    /// Such a row is impossible by definition and only exists because it was
    /// computed against different week boundaries — EPL's legacy Mon-Sun math
    /// filed Chelsea's Monday matchweek-1 game under week 2, leaving Palmer's
    /// GW1 line (and a phantom matchup WIN) sitting in an unplayed week.
    /// Re-scoring then rewrites the correct week on the next pass.
    private func purgeFutureWeekScores(leagueID: String, token: String) async {
        guard let league = currentLeague, !weeklyScores.isEmpty else { return }
        if league.sport == "EPL" { await EPLMatchweekProvider.refreshIfStale() }
        let now = Date()
        let futureWeeks = Set(weeklyScores.map(\.week)).filter { week in
            guard week >= 1, week <= league.totalWeeks else { return false }
            let (start, _) = BestBallSeasonHelper.weekDateRange(sport: league.sport, week: week)
            return start > now
        }
        guard !futureWeeks.isEmpty else { return }
        for week in futureWeeks.sorted() {
            print("[BestBall] Purging stored scores for \(league.sport) week \(week) — that week hasn't started yet")
            try? await SupabaseService.shared.deleteWeeklyScores(leagueID: leagueID, week: week, accessToken: token)
        }
        weeklyScores.removeAll { futureWeeks.contains($0.week) }

        // Standings were computed WITH those points (and their phantom
        // matchup W/L) — rebuild from what's left.
        if !currentMembers.isEmpty {
            let rebuilt = BestBallScoringEngine.computeStandings(
                weeklyScores: weeklyScores, members: currentMembers, scoringMode: league.scoringMode
            )
            let rows = rebuilt.map { s in
                (leagueID: leagueID, memberID: s.memberID, totalPoints: s.totalPoints,
                 weeksScored: s.weeksScored, rank: s.rank, wins: s.wins, losses: s.losses)
            }
            try? await SupabaseService.shared.batchUpsertStandings(standings: rows, accessToken: token)
            standings = rebuilt
        }

        // The league's stored currentWeek advanced off those bogus scores;
        // pull it back so scoring resumes at the real matchweek.
        let realWeek = BestBallSeasonHelper.currentWeekNumber(for: league.sport)
        if league.currentWeek > realWeek {
            try? await SupabaseService.shared.updateLeagueWeek(
                leagueID: leagueID, week: realWeek, accessToken: token
            )
            if let record = try? await SupabaseService.shared.fetchLeague(id: leagueID, accessToken: token) {
                currentLeague = record.toModel()
            }
        }
    }

    /// Load the draft player pool for the RANKINGS PREVIEW shown in the
    /// pre-draft lobby — same provider, same ordering as the draft board
    /// (ADP-aware for NFL), so what people study while waiting is exactly
    /// what they'll draft from. No-op once loaded for this league's pool.
    func loadPlayerRankingsIfNeeded() async {
        guard let league = currentLeague else { return }
        let poolKey = "\(league.sport)|\(league.cfbPool ?? "all")"
        if !availablePlayers.isEmpty && availablePlayersKey == poolKey { return }
        var players = (try? await playerProvider.fetchPlayers(sport: league.sport, cfbPool: league.cfbPool)) ?? []
        if league.isDingersOnly {
            players = players.filter { !BestBallLineupConfig.isPitcher($0.position) }
        }
        availablePlayers = players
        availablePlayersKey = poolKey
    }

    /// Team → that day's opponent for the roster view's selected date, so
    /// each row can show "@MNC" / "vs ARS" and a plays-today marker.
    struct BBDayFixture { let opp: String; let home: Bool }
    var dayFixtures: [String: BBDayFixture] = [:]
    @ObservationIgnored private var dayFixturesKey: String?

    func loadDayFixtures() async {
        guard let league = currentLeague else { return }
        let sportPath: String?
        switch league.sport {
        case "EPL": sportPath = "soccer/eng.1"
        case "NFL": sportPath = "football/nfl"
        case "CFB": sportPath = "football/college-football"
        case "MLB": sportPath = "baseball/mlb"
        default: sportPath = nil
        }
        guard let sportPath else { return }
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd"
        // Football is one slate a week and has no day strip, so scope the
        // fixtures to the WHOLE WEEK — keying off selectedDate alone only
        // ever fetched the week's first day (a Tuesday for CFB, the Thursday
        // opener for NFL), leaving everyone but the Thursday game blank.
        let isWeekly = league.sport == "NFL" || league.sport == "CFB"
        let dateParam: String
        if isWeekly {
            let (start, end) = BestBallSeasonHelper.weekDateRange(sport: league.sport, week: selectedWeek)
            dateParam = "\(df.string(from: start))-\(df.string(from: end))"
        } else {
            dateParam = df.string(from: selectedDate)
        }
        let key = "\(league.sport)|\(dateParam)"
        guard dayFixturesKey != key else { return }
        // CFB scoreboard defaults to Top 25 — groups=80 covers all of FBS.
        let extra = league.sport == "CFB" ? "&groups=80&limit=400" : "&limit=100"
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(sportPath)/scoreboard?dates=\(dateParam)\(extra)") else { return }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = json["events"] as? [[String: Any]] else { return }
        var map: [String: BBDayFixture] = [:]
        for event in events {
            guard let comp = (event["competitions"] as? [[String: Any]])?.first,
                  let competitors = comp["competitors"] as? [[String: Any]] else { continue }
            var homeAb: String?
            var awayAb: String?
            for c in competitors {
                let ab = (c["team"] as? [String: Any])?["abbreviation"] as? String
                if (c["homeAway"] as? String) == "home" { homeAb = ab } else { awayAb = ab }
            }
            if let h = homeAb, let a = awayAb {
                map[h] = BBDayFixture(opp: a, home: true)
                map[a] = BBDayFixture(opp: h, home: false)
            }
        }
        dayFixturesKey = key
        dayFixtures = map
    }

    func loadDailyScores(leagueID: String, week: Int) async {
        guard let token = accessToken else { return }
        do {
            let records = try await SupabaseService.shared.fetchDailyScores(
                leagueID: leagueID, week: week, accessToken: token
            )
            dailyScores = records.map { $0.toModel() }
        } catch {
            // Silently handle
        }
    }

    // MARK: - Dingers-Only Live HR

    /// Live HR counts per member per player, fetched directly from ESPN for today.
    /// Key: memberID -> [playerID: hrCount]
    var liveHRByMember: [String: [String: Double]] = [:]

    /// Whether HR counts are currently being fetched.
    var isLoadingDingersHR: Bool = false

    /// Timestamp of last successful HR fetch, keyed by leagueID.
    private var dingersHRCacheTime: [String: Date] = [:]

    /// Cached league ID for which liveHRByMember was fetched.
    private var dingersHRCacheLeagueID: String?

    /// Fetches season HR counts for all members using lightweight per-player stats endpoint.
    /// Uses a 5-minute cache to avoid redundant refetches when switching between tabs/teams.
    func refreshDingersLive(leagueID: String, forceRefresh: Bool = false) async {
        guard let league = currentLeague, league.isDingersOnly,
              let state = draftState else { return }

        // Skip if we have a recent cache for this league (within 5 minutes)
        if !forceRefresh,
           dingersHRCacheLeagueID == leagueID,
           let lastFetch = dingersHRCacheTime[leagueID],
           Date().timeIntervalSince(lastFetch) < 300,
           !liveHRByMember.isEmpty {
            return
        }

        isLoadingDingersHR = true

        // Collect all unique player IDs across all members
        var allPlayerIDs: Set<String> = []
        var memberRosters: [String: [String]] = [:]
        for member in currentMembers {
            let roster = state.roster(for: member.id)
            let playerIDs = roster.map { $0.playerID }
            memberRosters[member.id] = playerIDs
            allPlayerIDs.formUnion(playerIDs)
        }

        // Single batch fetch of HR counts for all unique players
        let hrCounts = await scoringProvider.fetchSeasonHRCounts(playerIDs: Array(allPlayerIDs))

        // Distribute HR counts back to each member
        var result: [String: [String: Double]] = [:]
        for member in currentMembers {
            guard let playerIDs = memberRosters[member.id] else { continue }
            var memberHR: [String: Double] = [:]
            for pid in playerIDs {
                if let hr = hrCounts[pid], hr > 0 {
                    memberHR[pid] = Double(hr)
                }
            }
            result[member.id] = memberHR
        }

        liveHRByMember = result
        dingersHRCacheTime[leagueID] = Date()
        dingersHRCacheLeagueID = leagueID
        isLoadingDingersHR = false
    }

    // MARK: - Join by Invite Code

    func joinLeagueByCode(_ code: String) async -> BestBallLeague? {
        guard let token = accessToken else {
            self.error = "Not signed in"
            return nil
        }
        do {
            guard let record = try await SupabaseService.shared.fetchLeagueByInviteCode(code: code, accessToken: token) else {
                self.error = "No league found with that code"
                return nil
            }
            let league = record.toModel()
            guard league.status == "open" else {
                self.error = "League is no longer open"
                return nil
            }
            let joined = await joinLeague(league)
            return joined ? league : nil
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    // MARK: - Commissioner Settings

    func updateLeagueSettings(leagueID: String, title: String, maxMembers: Int, rosterSize: Int, isPrivate: Bool, pitcherSlots: Int = 2, batterSlots: Int = 6, nflQB: Int = 1, nflRB: Int = 2, nflWR: Int = 2, nflTE: Int = 1, nflFLEX: Int = 2, nflSFLEX: Int = 0, eplGK: Int? = nil, eplDEF: Int? = nil, eplMID: Int? = nil, eplFWD: Int? = nil, eplFLEX: Int? = nil, entryFee: Int? = nil, pickTimerSeconds: Int? = nil, cfbPool: String? = nil) async {
        guard let token = accessToken else { return }
        do {
            try await SupabaseService.shared.updateLeagueSettings(
                leagueID: leagueID, title: title, maxMembers: maxMembers,
                rosterSize: rosterSize, isPrivate: isPrivate,
                pitcherSlots: pitcherSlots, batterSlots: batterSlots,
                nflQB: nflQB, nflRB: nflRB, nflWR: nflWR, nflTE: nflTE, nflFLEX: nflFLEX, nflSFLEX: nflSFLEX,
                eplGK: eplGK, eplDEF: eplDEF, eplMID: eplMID, eplFWD: eplFWD, eplFLEX: eplFLEX,
                entryFee: entryFee,
                pickTimerSeconds: pickTimerSeconds,
                cfbPool: cfbPool,
                accessToken: token
            )
            await loadLeagueDetail(leagueID: leagueID)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Helpers

    var myMemberID: String? {
        guard let uid = userID else { return nil }
        return currentMembers.first(where: { $0.userID == uid })?.id
    }

    var isHost: Bool { isCommish }

    var isCommish: Bool {
        guard let uid = userID else { return false }
        // V3: check created_by field
        if let createdBy = currentLeague?.createdBy {
            return createdBy == uid
        }
        // Backward compat: first non-bot member is host
        let nonBots = currentMembers.filter { !$0.isBot }.sorted(by: { $0.slotIndex < $1.slotIndex })
        return nonBots.first?.userID == uid
    }

    var isMyTurn: Bool {
        guard let state = draftState, let myID = myMemberID else { return false }
        return state.onTheClockMemberID == myID
    }

    func memberName(for id: String) -> String {
        currentMembers.first(where: { $0.id == id })?.displayName ?? "Unknown"
    }

    /// Bye week for an NFL team abbreviation; nil for other sports or
    /// before the bye table has loaded.
    func byeWeek(forTeam team: String) -> Int? {
        nflByeWeeks[team.uppercased()]
    }

    /// Display string for a team's bye week(s): NFL has exactly one
    /// ("10"); CFB can have several open weeks in the Best Ball grid
    /// ("6,12"). nil when unknown or the table hasn't loaded.
    /// SPORT-GATED: one VM serves every league, and CFB/NFL team
    /// abbreviations collide ("MIA" = Hurricanes AND Dolphins) — an
    /// ungated lookup showed Dolphins byes on Hurricanes players after
    /// visiting an NFL league.
    func byeLabel(forTeam team: String) -> String? {
        switch currentLeague?.sport {
        case "NFL":
            return nflByeWeeks[team.uppercased()].map(String.init)
        case "CFB":
            if let byes = cfbByeWeeks[team.uppercased()], !byes.isEmpty {
                return byes.map(String.init).joined(separator: ",")
            }
            return nil
        default:
            return nil
        }
    }

    private var byeWeeksFetchAttempted = false
    func loadNFLByeWeeksIfNeeded() async {
        guard currentLeague?.sport == "NFL", nflByeWeeks.isEmpty,
              !byeWeeksFetchAttempted else { return }
        byeWeeksFetchAttempted = true
        nflByeWeeks = await NFLByeWeekProvider.fetchByeWeeks()
    }

    private var cfbByeWeeksFetchAttempted = false
    func loadCFBByeWeeksIfNeeded() async {
        guard currentLeague?.sport == "CFB", cfbByeWeeks.isEmpty,
              !cfbByeWeeksFetchAttempted else { return }
        cfbByeWeeksFetchAttempted = true
        cfbByeWeeks = await CFBByeWeekProvider.fetchByeWeeks()
        // A partial result (network flake mid-draft) shouldn't stick for
        // the whole session — let the next league load retry.
        if cfbByeWeeks.count < 100 {
            cfbByeWeeksFetchAttempted = false
        }
    }

    /// Positions still needed to meet draft minimums for a member
    func positionsNeeded(for memberID: String, sport: String) -> [String: Int] {
        guard let state = draftState else { return [:] }
        let roster = state.roster(for: memberID)
        let league = currentLeague
        let minimums = BestBallLineupConfig.draftMinimums(
            for: sport,
            pitcherSlots: league?.pitcherSlots ?? 2,
            batterSlots: league?.batterSlots ?? 6,
            nflQB: league?.nflQbStarters ?? 1,
            nflRB: league?.nflRbStarters ?? 2,
            nflWR: league?.nflWrStarters ?? 2,
            nflTE: league?.nflTeStarters ?? 1,
            eplGK: league?.eplGkStarters ?? 1,
            eplDEF: league?.eplDefStarters ?? 3,
            eplMID: league?.eplMidStarters ?? 4,
            eplFWD: league?.eplFwdStarters ?? 2
        )
        let pickedPositions = Dictionary(grouping: roster, by: \.playerPosition)
            .mapValues { $0.count }

        var needed: [String: Int] = [:]
        for (pos, minCount) in minimums {
            let have = pickedPositions[pos] ?? 0
            if have < minCount {
                needed[pos] = minCount - have
            }
        }
        return needed
    }
}
