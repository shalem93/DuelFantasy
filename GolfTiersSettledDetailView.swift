import SwiftUI

struct GolfTiersSettledDetailView: View {
    @Bindable var viewModel: GolfTiersViewModel
    let tournamentRecord: GolfTiersTournamentRecord

    @State private var entries: [GolfTiersEntryRecord] = []
    @State private var userResult: DFSTournamentResultRecord?
    @State private var isLoading = true
    @State private var visibleCount = 25
    /// Final score-to-par per golfer ID, populated from ESPN when we recompute.
    @State private var golferScores: [String: Int] = [:]
    /// Final status per golfer (cut/withdrawn/active) for display badges.
    @State private var golferStatuses: [String: GolfTiersGolfer.GolferStatus] = [:]
    /// Currently expanded leaderboard row — taps open this in a sheet.
    @State private var selectedEntry: GolfTiersEntryRecord?

    private var darkGreen: Color {
        Color(red: 0.05, green: 0.45, blue: 0.25)
    }

    /// The real ESPN date for this major, derived from its calendar window (mid
    /// point) — NOT the stored lockTime, which is wrong for a contest created
    /// prematurely against another event. e.g. "us-open-2026" → ~Jun 19 2026.
    private var canonicalMajorDate: Date? {
        guard let window = GolfTiersTournament.windowBounds(for: tournamentRecord.id),
              let yearStr = tournamentRecord.id.split(separator: "-").last.map(String.init),
              let year = Int(yearStr) else { return nil }
        let midMMDD = (window.opens + window.closes) / 2
        var comps = DateComponents()
        comps.year = year
        comps.month = midMMDD / 100
        comps.day = midMMDD % 100
        comps.hour = 18
        return Calendar(identifier: .gregorian).date(from: comps)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView().tint(.secondary)
                        Text("Loading results...")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    resultHeroCard
                    userPicksCard
                    leaderboardSection
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.93, green: 0.97, blue: 0.93),
                    Color(red: 0.95, green: 0.98, blue: 0.95),
                    Color(red: 0.98, green: 0.99, blue: 0.98)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        .navigationTitle(tournamentRecord.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadData() }
        .sheet(item: $selectedEntry) { entry in
            entryDetailSheet(entry)
        }
    }

    // MARK: - Entry Detail Sheet (bot/user roster view)

    @ViewBuilder
    private func entryDetailSheet(_ entry: GolfTiersEntryRecord) -> some View {
        let sortedPicks = entry.picks.sorted { $0.tier < $1.tier }
        // Same Best 4 of 6 highlighting as the user's own picks card.
        let scoredOnly = sortedPicks.compactMap { p -> (pickID: String, score: Int)? in
            guard let s = golferScores[p.playerID] else { return nil }
            return (p.playerID, s)
        }.sorted { $0.score < $1.score }
        let countingIDs = Set(scoredOnly.prefix(4).map { $0.pickID })

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(entry.entryName)
                            .font(.title3.weight(.bold))
                        Spacer()
                        Text(GolfTiersEngine.scoreToParDisplay(Int(entry.totalPoints)))
                            .font(.title3.weight(.heavy).monospacedDigit())
                            .foregroundStyle(golferScoreColor(Int(entry.totalPoints)))
                    }
                    HStack {
                        if entry.rank > 0 {
                            Text("Rank #\(entry.rank)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("Best 4 of 6 count")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    ForEach(sortedPicks, id: \.tier) { pick in
                        pickRow(
                            pick: pick,
                            tier: pick.tier,
                            score: golferScores[pick.playerID],
                            status: golferStatuses[pick.playerID],
                            isCounting: countingIDs.contains(pick.playerID)
                        )
                    }
                }
                .padding(16)
            }
            .navigationTitle("Lineup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { selectedEntry = nil }
                }
            }
        }
    }

    // MARK: - Data Loading

    private func loadData() async {
        guard let token = viewModel.accessToken else {
            isLoading = false
            return
        }

        // Fetch all entries for this tournament (includes bots + users with final scores)
        if let records = try? await SupabaseService.shared.fetchGolfTiersEntries(
            tournamentID: tournamentRecord.id, accessToken: token
        ) {
            entries = records
        }

        // Fetch user's result
        if let uid = viewModel.userID {
            userResult = try? await SupabaseService.shared.fetchUserGolfTiersResult(
                tournamentID: tournamentRecord.id, userID: uid, accessToken: token
            )
        }

        let placeholderCount = entries.filter { $0.totalPoints == 0 }.count
        let zeroScoreFraction = entries.isEmpty ? 0.0 : Double(placeholderCount) / Double(entries.count)
        print("[GolfTiers Detail] placeholderCount=\(placeholderCount)/\(entries.count) (\(Int(zeroScoreFraction * 100))%), espnEventID=\(tournamentRecord.espnEventID ?? "nil"), lockTime=\(tournamentRecord.lockTime?.description ?? "nil")")

        // Resolve which ESPN event + date to grade against. If the stored lock
        // date falls OUTSIDE this major's real calendar window, the contest was
        // created against the WRONG event (e.g. a "us-open-2026" that got settled
        // back in May, hence a "May 27" date + scores that don't match the real
        // U.S. Open). In that case ignore the corrupt stored event id/date and
        // resolve the real major by its canonical mid-window date so the
        // recompute grades against the ACTUAL tournament's scores.
        let (gradeEventID, gradeCenter): (String, Date?) = {
            let storedCenter = tournamentRecord.lockTime ?? tournamentRecord.createdAt
            let storedID = tournamentRecord.espnEventID ?? ""
            if let window = GolfTiersTournament.windowBounds(for: tournamentRecord.id),
               let canonical = canonicalMajorDate, let stored = storedCenter {
                let cal = Calendar(identifier: .gregorian)
                let mmdd = cal.component(.month, from: stored) * 100 + cal.component(.day, from: stored)
                if mmdd < window.opens || mmdd > window.closes {
                    print("[GolfTiers Detail] stored lock mmdd=\(mmdd) outside \(tournamentRecord.id) window \(window) — corrupt event; resolving real major by canonical date \(canonical)")
                    return ("", canonical)   // "" id forces date-based resolution
                }
            }
            return (storedID, storedCenter)
        }()

        // Phase 1: ALWAYS fetch ESPN snapshot so we have per-golfer scores for the YOUR
        // PICKS card and the bot-roster sheet, even when entries already have proper
        // totals stored in Supabase (no full recompute needed).
        var espnSnapshot: GolfTiersScoreSnapshot?
        if !entries.isEmpty, (!gradeEventID.isEmpty || gradeCenter != nil) {
            espnSnapshot = try? await ESPNGolfTiersDataProvider().fetchLiveScores(
                espnEventID: gradeEventID, searchAroundDate: gradeCenter
            )
            if let snap = espnSnapshot {
                golferScores = snap.golferScoresToPar
                golferStatuses = snap.golferStatuses
                print("[GolfTiers Detail] Populated golferScores: \(snap.golferScoresToPar.count) scores")
            }
        }

        // Phase 2: if dfs_tournament_results was empty for this user, synthesize a
        // userResult from the user's entry row so the hero card has data to render.
        if userResult == nil, let uid = viewModel.userID,
           let userEntryRec = entries.first(where: { $0.userID == uid && !$0.isBot }),
           userEntryRec.rank > 0 || userEntryRec.totalPoints != 0 {
            let rrDelta = GolfTiersEngine.rrDelta(forRank: userEntryRec.rank, totalEntries: entries.count)
            userResult = DFSTournamentResultRecord(
                id: userEntryRec.id, tournamentID: tournamentRecord.id, userID: uid,
                entryName: userEntryRec.entryName,
                lineupPlayerIDs: userEntryRec.picks.map { $0.playerID },
                lineupPlayerNames: userEntryRec.picks.map { $0.playerName },
                totalPoints: userEntryRec.totalPoints,
                playerPoints: nil, playerSalaries: nil,
                rank: userEntryRec.rank, rrDelta: rrDelta,
                isCurrentUser: true, isBot: false, createdAt: userEntryRec.createdAt
            )
            print("[GolfTiers Detail] Synthesized userResult from entry: rank=\(userEntryRec.rank), pts=\(userEntryRec.totalPoints)")
        }

        // Phase 3: recompute the final leaderboard from ESPN. This detail view
        // is only ever shown for a FINISHED major, so ESPN has the true final
        // scores. Recompute whenever we actually have a scores snapshot — not
        // only when >25% of entries are still 0 (placeholder-y). The old gate
        // left a BAD partial settle (non-zero but WRONG totals — e.g. the winner
        // shown at "+10") uncorrected; recompute + persist (below) fixes both
        // this view and the past-results card.
        let haveEspnScores = !(espnSnapshot?.golferScoresToPar.isEmpty ?? true)
        if !entries.isEmpty, (zeroScoreFraction > 0.25 || haveEspnScores),
           (!gradeEventID.isEmpty || gradeCenter != nil) {
            let eventID = gradeEventID
            let center = gradeCenter
            print("[GolfTiers Detail] Attempting recompute via ESPN event=\(eventID) center=\(center?.description ?? "nil")")
            let snapshot: GolfTiersScoreSnapshot?
            if let prefetched = espnSnapshot {
                snapshot = prefetched
            } else {
                snapshot = try? await ESPNGolfTiersDataProvider().fetchLiveScores(
                    espnEventID: eventID, searchAroundDate: center
                )
            }
            if let snapshot {
                print("[GolfTiers Detail] ESPN returned snapshot with \(snapshot.golferScoresToPar.count) golfer scores")
                golferScores = snapshot.golferScoresToPar
                golferStatuses = snapshot.golferStatuses
            let modelEntries: [GolfTiersEntry] = entries.map { rec in
                GolfTiersEntry(
                    id: UUID(uuidString: rec.id) ?? UUID(),
                    tournamentID: rec.tournamentID, userID: rec.userID,
                    entryName: rec.entryName, picks: rec.picks.map { $0.toModel() },
                    totalScore: Int(rec.totalPoints), rank: rec.rank,
                    isBot: rec.isBot, isCurrentUser: rec.userID == viewModel.userID
                )
            }
            let board = GolfTiersEngine.computeLeaderboard(
                entries: modelEntries,
                golferScores: snapshot.golferScoresToPar,
                golferStatuses: snapshot.golferStatuses,
                golferRoundScores: snapshot.golferRoundScores,
                currentUserID: viewModel.userID
            )
            // Key by lowercase UUID so Supabase's lowercase ids match (Swift UUID.uuidString
            // is uppercase). Without this, every overlay lookup missed and bots stayed at 0.
            var scoreByID: [String: (Int, Double)] = [:]
            for entry in board {
                scoreByID[entry.id.uuidString.lowercased()] = (entry.rank, Double(entry.totalScore))
            }
            entries = entries.map { rec in
                guard let recomputed = scoreByID[rec.id.lowercased()] else { return rec }
                return GolfTiersEntryRecord(
                    id: rec.id, tournamentID: rec.tournamentID, userID: rec.userID,
                    entryName: rec.entryName, picks: rec.picks,
                    totalPoints: recomputed.1, rank: recomputed.0,
                    isBot: rec.isBot, createdAt: rec.createdAt
                )
            }
            // Populate the userResult so the hero card shows real RANK/SCORE even if the
            // dfs_tournament_results upsert hasn't completed yet.
            if let userBoard = board.first(where: { $0.isCurrentUser }),
               let uid = viewModel.userID {
                let totalEntries = board.count
                let rrDelta = GolfTiersEngine.rrDelta(forRank: userBoard.rank, totalEntries: totalEntries)
                // Overwrite the locally-loaded userResult unconditionally so the hero card
                // matches the freshly recomputed leaderboard (the stored result might be
                // from an earlier partial settle with a different rank/score).
                userResult = DFSTournamentResultRecord(
                    id: userResult?.id ?? UUID().uuidString,
                    tournamentID: tournamentRecord.id, userID: uid,
                    entryName: userBoard.entryName,
                    lineupPlayerIDs: userBoard.picks.map { $0.playerID },
                    lineupPlayerNames: userBoard.picks.map { $0.playerName },
                    totalPoints: Double(userBoard.totalScore),
                    playerPoints: nil, playerSalaries: nil,
                    rank: userBoard.rank, rrDelta: rrDelta,
                    isCurrentUser: true, isBot: false, createdAt: Date()
                )
                // Persist the recomputed values so the lobby's MAJOR RESULTS row matches
                // this detail view. Without this, the history cell keeps showing the stale
                // partial-settle values forever.
                let token = viewModel.accessToken
                if let token {
                    let updates = board.map { entry in
                        (id: entry.id.uuidString.lowercased(), totalPoints: Double(entry.totalScore), rank: entry.rank)
                    }
                    Task.detached {
                        try? await SupabaseService.shared.updateGolfTiersEntryScores(
                            entries: updates, accessToken: token
                        )
                    }
                    let supabaseResult = DFSTournamentResultRecord(
                        id: UUID().uuidString, tournamentID: tournamentRecord.id, userID: uid,
                        entryName: userBoard.entryName,
                        lineupPlayerIDs: userBoard.picks.map { $0.playerID },
                        lineupPlayerNames: userBoard.picks.map { $0.playerName },
                        totalPoints: Double(userBoard.totalScore),
                        playerPoints: nil, playerSalaries: nil,
                        rank: userBoard.rank, rrDelta: rrDelta,
                        isCurrentUser: true, isBot: false, createdAt: Date()
                    )
                    let resultTid = tournamentRecord.id
                    Task.detached {
                        try? await SupabaseService.shared.upsertTournamentResults(
                            tournamentID: resultTid, results: [supabaseResult], accessToken: token
                        )
                    }
                }
            }
            } else {
                print("[GolfTiers Detail] ESPN snapshot was nil — recompute skipped")
            }
        }

        isLoading = false
    }

    // MARK: - Hero Card

    private var resultHeroCard: some View {
        let rank = userResult?.rank
        let totalEntries = tournamentRecord.entryCount ?? entries.count
        let rrDelta = userResult?.rrDelta ?? 0
        let scoreDisplay = userResult.map { GolfTiersEngine.scoreToParDisplay(Int($0.totalPoints)) } ?? "—"
        let percentile = rank.map { Int((1.0 - Double($0) / Double(max(1, totalEntries))) * 100) }

        return VStack(spacing: 14) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.white)
                    Text("FINAL")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                }
                Spacer()
                Text(tournamentRecord.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))
            }

            HStack(spacing: 20) {
                VStack(spacing: 2) {
                    Text("RANK")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    if let rank {
                        Text("#\(rank)")
                            .font(.title.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                        Text("of \(totalEntries)")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.6))
                    } else {
                        Text("—")
                            .font(.title.weight(.bold))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }

                VStack(spacing: 2) {
                    Text("SCORE")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    Text(scoreDisplay)
                        .font(.title.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                }

                VStack(spacing: 2) {
                    Text("RR")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("\(rrDelta >= 0 ? "+" : "")\(rrDelta)")
                        .font(.title.weight(.bold).monospacedDigit())
                        .foregroundStyle(rrDelta >= 0 ? Color(red: 0.4, green: 1.0, blue: 0.5) : Color(red: 1.0, green: 0.5, blue: 0.5))
                }

                Spacer()

                if let percentile {
                    VStack(spacing: 2) {
                        Text("TOP")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                        Text("\(max(1, 100 - percentile))%")
                            .font(.title3.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                    }
                }
            }

            if let date = tournamentRecord.lockTime ?? tournamentRecord.createdAt {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                        .font(.caption2)
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                }
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [Color(red: 0.04, green: 0.30, blue: 0.15), Color(red: 0.08, green: 0.50, blue: 0.28)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }

    // MARK: - User Picks Card

    private var userPicksCard: some View {
        let userEntry = entries.first(where: { $0.userID == viewModel.userID && !$0.isBot })

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("YOUR PICKS")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Best 4 of 6 count")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if let entry = userEntry {
                let sortedPicks = entry.picks.sorted { $0.tier < $1.tier }
                // Best 4 of 6: the 4 lowest scores count. Highlight them so the user
                // can see which picks carried the lineup.
                let scoredPicks = sortedPicks.map { p -> (pick: GolfTiersPickData, score: Int?) in
                    (p, golferScores[p.playerID])
                }
                let scoredOnly = scoredPicks.compactMap { item -> (pickID: String, score: Int)? in
                    guard let s = item.score else { return nil }
                    return (item.pick.playerID, s)
                }.sorted { $0.score < $1.score }
                let countingIDs = Set(scoredOnly.prefix(4).map { $0.pickID })
                ForEach(sortedPicks, id: \.tier) { pick in
                    pickRow(
                        pick: pick,
                        tier: pick.tier,
                        score: golferScores[pick.playerID],
                        status: golferStatuses[pick.playerID],
                        isCounting: countingIDs.contains(pick.playerID)
                    )
                }
            } else if let result = userResult {
                // Fall back to result data if entry not found
                let names = result.lineupPlayerNames
                ForEach(0..<min(names.count, 6), id: \.self) { i in
                    HStack(spacing: 10) {
                        Text("T\(i + 1)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(tierColor(i + 1))
                            .clipShape(RoundedRectangle(cornerRadius: 6))

                        Image(systemName: "person.crop.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)

                        Text(names[i])
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)

                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Text("No picks found")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
    }

    private func pickRow(
        pick: GolfTiersPickData,
        tier: Int,
        score: Int? = nil,
        status: GolfTiersGolfer.GolferStatus? = nil,
        isCounting: Bool = false
    ) -> some View {
        // Whole row dims when the pick doesn't count (Best 4 of 6) so the name reads
        // as "didn't help" too — not just the score.
        let dimOpacity: Double = (score != nil && !isCounting) ? 0.4 : 1.0

        return HStack(spacing: 10) {
            Text("T\(tier)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tierColor(tier))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            Image(systemName: "person.crop.circle.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text(pick.playerName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(pick.playerCountry)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Cut / withdrawn badges
            if status == .cut {
                Text("CUT")
                    .font(.system(size: 9, weight: .heavy))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.red.opacity(0.15))
                    .foregroundStyle(.red)
                    .clipShape(Capsule())
            } else if status == .withdrawn {
                Text("WD")
                    .font(.system(size: 9, weight: .heavy))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15))
                    .foregroundStyle(.orange)
                    .clipShape(Capsule())
            }

            // Score-to-par display
            if let score {
                Text(GolfTiersEngine.scoreToParDisplay(score))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(golferScoreColor(score))
                    .frame(minWidth: 36, alignment: .trailing)
            }
        }
        .padding(.vertical, 4)
        .opacity(dimOpacity)
    }

    private func golferScoreColor(_ score: Int) -> Color {
        if score < 0 { return darkGreen }
        if score == 0 { return .primary }
        return Color.red.opacity(0.85)
    }

    // MARK: - Leaderboard

    private var leaderboardSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("LEADERBOARD")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(entries.count) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if entries.isEmpty {
                Text("No leaderboard data available")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
            } else {
                VStack(spacing: 0) {
                    // Header
                    HStack {
                        Text("#")
                            .frame(width: 30, alignment: .leading)
                        Text("Entry")
                        Spacer()
                        Text("Score")
                            .frame(width: 60, alignment: .trailing)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    Divider()

                    // Sorted entries by rank
                    let sorted = entries.sorted { a, b in
                        if a.rank != b.rank { return a.rank < b.rank }
                        return a.totalPoints < b.totalPoints
                    }
                    let visible = Array(sorted.prefix(visibleCount))
                    let userEntry = sorted.first(where: { $0.userID == viewModel.userID && !$0.isBot })
                    let userInVisible = userEntry.map { u in visible.contains(where: { $0.id == u.id }) } ?? true

                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, entry in
                        Button { selectedEntry = entry } label: {
                            leaderboardRow(entry, displayRank: entry.rank > 0 ? entry.rank : index + 1)
                        }
                        .buttonStyle(.plain)
                        if index < visible.count - 1 {
                            Divider().padding(.leading, 42)
                        }
                    }

                    // Show user entry separately if outside visible range
                    if !userInVisible, let user = userEntry {
                        Divider()
                        HStack {
                            Text("···")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                        }
                        .padding(.vertical, 4)
                        Divider()
                        Button { selectedEntry = user } label: {
                            leaderboardRow(user, displayRank: user.rank > 0 ? user.rank : sorted.count)
                        }
                        .buttonStyle(.plain)
                    }

                    // Load More
                    if visibleCount < sorted.count {
                        Divider()
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                visibleCount = min(visibleCount + 50, sorted.count)
                            }
                        } label: {
                            Text("Load More (\(sorted.count - visibleCount) remaining)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(darkGreen)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                    }
                }
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
            }
        }
    }

    private func leaderboardRow(_ entry: GolfTiersEntryRecord, displayRank: Int) -> some View {
        let isUser = entry.userID == viewModel.userID && !entry.isBot

        return HStack {
            Text("\(displayRank)")
                .font(.subheadline.weight(.medium).monospacedDigit())
                .foregroundStyle(displayRank <= 3 ? Color(red: 0.95, green: 0.78, blue: 0.20) : .secondary)
                .frame(width: 30, alignment: .leading)

            HStack(spacing: 4) {
                if isUser {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(darkGreen)
                }
                Text(entry.entryName)
                    .font(.subheadline.weight(isUser ? .bold : .regular))
                    .foregroundStyle(isUser ? darkGreen : .primary)
                    .lineLimit(1)
            }

            Spacer()

            Text(GolfTiersEngine.scoreToParDisplay(Int(entry.totalPoints)))
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(scoreColor(Int(entry.totalPoints)))
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isUser ? darkGreen.opacity(0.06) : .clear)
    }

    // MARK: - Helpers

    private func tierColor(_ tier: Int) -> Color {
        switch tier {
        case 1: return Color(red: 0.85, green: 0.65, blue: 0.13)
        case 2: return Color(red: 0.60, green: 0.60, blue: 0.65)
        case 3: return Color(red: 0.70, green: 0.45, blue: 0.20)
        case 4: return Color(red: 0.30, green: 0.50, blue: 0.75)
        case 5: return Color(red: 0.45, green: 0.65, blue: 0.45)
        case 6: return Color(red: 0.55, green: 0.45, blue: 0.65)
        default: return .secondary
        }
    }

    private func scoreColor(_ score: Int) -> Color {
        if score < 0 { return Color(red: 0.85, green: 0.15, blue: 0.15) }
        return .primary
    }
}
