import Foundation
import SwiftUI

/// Lightweight matchup summary for the league list cards.
struct LeagueMatchupPreview {
    let myName: String
    let opponentName: String
    let myScore: Double
    let opponentScore: Double
    let myGamesPlayed: Int
    let opponentGamesPlayed: Int
    let week: Int
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
    var isLoading: Bool = false
    var isStartingDraft: Bool = false
    var error: String?

    // League Detail
    var currentLeague: BestBallLeague?
    var currentMembers: [BestBallMember] = []
    var draftState: BestBallDraftState?
    var availablePlayers: [BestBallPlayer] = []
    var isDraftPolling: Bool = false

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

    // Draft polling
    private var draftPollTask: Task<Void, Never>?

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

    func loadMyLeagues() async {
        guard let uid = userID, let token = accessToken else { return }
        do {
            let memberships = try await SupabaseService.shared.fetchUserMemberships(userID: uid, accessToken: token)
            myMemberships = memberships
            let leagueIDs = Set(memberships.map { $0.leagueId })
            var leagues: [BestBallLeague] = []
            for id in leagueIDs {
                if let record = try? await SupabaseService.shared.fetchLeague(id: id, accessToken: token) {
                    leagues.append(record.toModel())
                }
            }
            myLeagues = leagues.sorted { $0.createdAt > $1.createdAt }

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
                let week = min(league.currentWeek, realWeek)
                guard week > 0, week <= league.schedule.count else { continue }

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

                    previews[league.id] = LeagueMatchupPreview(
                        myName: myName,
                        opponentName: oppName,
                        myScore: myScore?.totalPoints ?? 0,
                        opponentScore: oppScore?.totalPoints ?? 0,
                        myGamesPlayed: myScore?.playerPoints.count ?? 0,
                        opponentGamesPlayed: oppScore?.playerPoints.count ?? 0,
                        week: week
                    )
                }
            }
            leagueMatchupPreviews = previews
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Create & Join

    func createLeague(title: String, sport: String, isPrivate: Bool = false, maxMembers: Int = 12, rosterSize: Int = 12, pitcherSlots: Int = 2, batterSlots: Int = 6, scoringMode: BestBallScoringMode = .normal, nflQB: Int = 1, nflRB: Int = 2, nflWR: Int = 2, nflTE: Int = 1, nflFLEX: Int = 2, nflSFLEX: Int = 0) async -> BestBallLeague? {
        guard let uid = userID, let token = accessToken else { return nil }
        do {
            let season = BestBallSeasonHelper.currentSeason(sport: sport)
            let record = try await SupabaseService.shared.createLeague(
                title: title, sport: sport, season: season,
                isPrivate: isPrivate, maxMembers: maxMembers, rosterSize: rosterSize,
                pitcherSlots: pitcherSlots, batterSlots: batterSlots,
                scoringMode: scoringMode.rawValue,
                nflQB: nflQB, nflRB: nflRB, nflWR: nflWR, nflTE: nflTE, nflFLEX: nflFLEX, nflSFLEX: nflSFLEX,
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

            // Cache so the detail view has the correct values right away
            currentLeague = league

            // Auto-join as first member
            _ = try await SupabaseService.shared.joinLeague(
                leagueID: league.id, userID: uid,
                displayName: profileName.isEmpty ? "Player" : profileName,
                slotIndex: 0, accessToken: token
            )

            await loadOpenLeagues()
            await loadMyLeagues()
            return league
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func joinLeague(_ league: BestBallLeague) async -> Bool {
        guard let uid = userID, let token = accessToken else { return false }
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
                    if availablePlayers.isEmpty, let sport = currentLeague?.sport {
                        var players = (try? await playerProvider.fetchPlayers(sport: sport)) ?? []
                        if currentLeague?.isDingersOnly == true {
                            players = players.filter { !BestBallLineupConfig.isPitcher($0.position) }
                        }
                        availablePlayers = players
                    }
                    let state = BestBallDraftState(
                        league: currentLeague!,
                        members: currentMembers,
                        picks: picks,
                        availablePlayers: availablePlayers
                    )
                    draftState = state

                    // Auto-recover: if all picks are in but status is still "drafting", transition to active
                    if state.isDraftComplete {
                        try await SupabaseService.shared.updateLeagueStatus(
                            leagueID: leagueID, status: "active",
                            accessToken: token
                        )
                        currentLeague?.status = "active"
                        stopDraftPolling()
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
                let standingRecords = try await SupabaseService.shared.fetchStandings(leagueID: leagueID, accessToken: token)
                standings = standingRecords.map { $0.toModel() }

                // Set selected week to current (capped to real calendar week to avoid showing future weeks)
                if let league = currentLeague {
                    let realWeek = BestBallSeasonHelper.currentWeekNumber(for: league.sport)
                    selectedWeek = min(league.currentWeek, realWeek)
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
                var players = (try? await playerProvider.fetchPlayers(sport: league.sport)) ?? []
                if league.isDingersOnly {
                    players = players.filter { !BestBallLineupConfig.isPitcher($0.position) }
                }
                availablePlayers = players
            }

            await loadLeagueDetail(leagueID: leagueID)
            startDraftPolling(leagueID: leagueID)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func makePick(player: BestBallPlayer) async {
        guard let state = draftState, !state.isDraftComplete,
              let token = accessToken, let uid = userID else { return }

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

        // Only the first non-bot member (draft host) executes bot picks
        let nonBotMembers = currentMembers.filter { !$0.isBot }.sorted(by: { $0.slotIndex < $1.slotIndex })
        guard nonBotMembers.first?.userID == uid else { return }

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
            } catch {
                self.error = error.localizedDescription
            }
            return
        }

        let sport = state.league.sport
        let rosterSize = state.league.rosterSize
        var currentState = state
        while !currentState.isDraftComplete {
            guard let onClockID = currentState.onTheClockMemberID,
                  let onClockMember = currentMembers.first(where: { $0.id == onClockID }),
                  onClockMember.isBot else {
                break // Not a bot's turn
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
                nflSFLEX: currentLeague?.nflSflexStarters ?? 0
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
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: - Schedule Generation

    private func generateScheduleAfterDraft(leagueID: String) async {
        guard let token = accessToken, let league = currentLeague else { return }
        // Skip schedule for dingers-only leagues (no H2H matchups)
        guard !league.isDingersOnly else { return }
        let memberIDs = currentMembers.map { $0.id }
        let schedule = BestBallScheduleGenerator.generateSchedule(
            memberIDs: memberIDs, totalWeeks: league.totalWeeks
        )
        let weekStructure = league.sport == "NFL" ? "thu_mon" : "mon_sun"
        do {
            try await SupabaseService.shared.updateLeagueSchedule(
                leagueID: leagueID, schedule: schedule,
                weekStructure: weekStructure, accessToken: token
            )
        } catch {
            self.error = error.localizedDescription
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
                sport: league.sport, weekStartDate: start, weekEndDate: end
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
                    nflSFLEX: league.nflSflexStarters
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
                    nflSFLEX: league.nflSflexStarters
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

    func updateLeagueSettings(leagueID: String, title: String, maxMembers: Int, rosterSize: Int, isPrivate: Bool, pitcherSlots: Int = 2, batterSlots: Int = 6, nflQB: Int = 1, nflRB: Int = 2, nflWR: Int = 2, nflTE: Int = 1, nflFLEX: Int = 2, nflSFLEX: Int = 0) async {
        guard let token = accessToken else { return }
        do {
            try await SupabaseService.shared.updateLeagueSettings(
                leagueID: leagueID, title: title, maxMembers: maxMembers,
                rosterSize: rosterSize, isPrivate: isPrivate,
                pitcherSlots: pitcherSlots, batterSlots: batterSlots,
                nflQB: nflQB, nflRB: nflRB, nflWR: nflWR, nflTE: nflTE, nflFLEX: nflFLEX, nflSFLEX: nflSFLEX,
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
            nflTE: league?.nflTeStarters ?? 1
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
