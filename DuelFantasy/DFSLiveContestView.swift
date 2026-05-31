import SwiftUI

struct DFSLiveContestView: View {
    @Bindable var viewModel: DFSViewModel
    /// Optional expected tournament ID. When provided, the view shows the
    /// shimmer placeholder until `viewModel.activeTournamentID` matches it,
    /// preventing the brief flash of the PREVIOUS tournament's data on
    /// navigation. Callers that pass nil get the legacy behavior.
    var expectedTournamentID: String? = nil
    var expectedLineupNumber: Int? = nil

    private var brandPurple: Color {
        Color(red: 0.48, green: 0.23, blue: 0.93)
    }

    private var isPGA: Bool {
        viewModel.sport == "PGA"
    }

    private var allGamesFinal: Bool {
        guard let tournament = viewModel.tournament else { return false }
        // Check if already settled locally
        if viewModel.settledTournaments.contains(tournament.id) { return true }
        // PGA requires 3-day guard and round 4 check
        if isPGA {
            let daysSinceLock = Date().timeIntervalSince(viewModel.lockTime) / (24 * 3600)
            guard daysSinceLock >= 3.0 else { return false }
            let reportedRound = viewModel.liveGameInfo.values.first?.period ?? 1
            guard reportedRound >= 4 else { return false }
        }
        // Also check if live game info shows all games finished
        if !viewModel.liveGameInfo.isEmpty {
            let gamesFinal = viewModel.liveGameInfo.values.allSatisfy { $0.state == "post" }
            if gamesFinal { return true }
        }
        // Check if history has a non-zero RR delta (was settled on another device/session)
        let historyMatch = viewModel.dfsHistory.first(where: { $0.tournamentId == tournament.id })
        if let match = historyMatch, match.rrDelta != 0 { return true }
        return false
    }

    /// True iff the data backing this view is fully resolved. When false we
    /// render a single clean shimmer placeholder instead of partial state
    /// (raw IDs, "1 entries", "your lineup is locked in" pre-pitch, etc.).
    /// If `expectedTournamentID` was provided at construction, the view also
    /// requires the active tournament to match — otherwise we'd briefly show
    /// the previous tournament's data on navigation between contests.
    private var isReady: Bool {
        guard let tid = viewModel.activeTournamentID else { return false }
        if let expected = expectedTournamentID, expected != tid { return false }
        if let expectedLN = expectedLineupNumber, expectedLN != viewModel.activeLineupNumber { return false }
        return viewModel.isTournamentReady(tid)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if isReady {
                    liveStatusHeader
                    if let error = viewModel.error {
                        errorBanner(error)
                    }
                    yourLineupCard
                    leaderboardSection
                    if !isPGA {
                        gamesStatusSection
                    }
                } else {
                    shimmerPlaceholder
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.94, green: 0.98, blue: 0.95),
                    Color(red: 0.95, green: 0.97, blue: 1.00),
                    Color(red: 0.98, green: 0.99, blue: 1.00)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        // Trigger an immediate refresh on view appearance so the user doesn't
        // have to wait up to 35s for the parent polling cycle to publish their rank.
        .task {
            await viewModel.refreshLive()
        }
    }

    // MARK: - Live Status Header

    private var liveStatusHeader: some View {
        VStack(spacing: 14) {
            HStack {
                if allGamesFinal {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.white)
                        Text("FINAL")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    }
                } else {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                        Text("LIVE")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }

                Spacer()

                if let tournament = viewModel.tournament {
                    let badge: String = {
                        let prefix: String
                        switch tournament.tournamentType {
                        case .singleGame: prefix = "SG "
                        case .evening: prefix = "EVE "
                        case .main: prefix = ""
                        }
                        switch tournament.entryCount {
                        case 2: return "\(prefix)H2H"
                        case 3: return "\(prefix)3-MAN"
                        case 5: return "\(prefix)5-MAN WTA"
                        case 10: return "\(prefix)10-MAN"
                        default: return "\(prefix)\(tournament.entryCount)"
                        }
                    }()
                    Text(badge)
                        .font(.caption2.weight(.heavy))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.orange)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }

                Text(viewModel.tournament?.title ?? "")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }

            // PGA round indicators (R1-R4)
            if isPGA {
                HStack(spacing: 8) {
                    ForEach(1...4, id: \.self) { round in
                        let current = viewModel.currentRound
                        let isComplete = round < current || (round == current && allGamesFinal)
                        let isActive = round == current && !allGamesFinal
                        HStack(spacing: 3) {
                            Circle()
                                .fill(isComplete ? Color.green : (isActive ? Color.red : Color.gray.opacity(0.4)))
                                .frame(width: 6, height: 6)
                            Text("R\(round)")
                                .font(.caption2.weight(isActive ? .bold : .medium))
                                .foregroundStyle(isActive ? .white : .white.opacity(0.6))
                        }
                    }
                    Spacer()
                    if !viewModel.venueName.isEmpty {
                        Text(viewModel.venueName)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }
            }

            if let result = viewModel.latestResult {
                // Compute user's live total from actual live player points only (no projections)
                let sgMode = viewModel.tournament?.isSingleGame == true
                let userLiveTotal = viewModel.selectedPlayers.enumerated().reduce(0.0) { sum, pair in
                    let pts = viewModel.livePlayerPoints[pair.element.id] ?? 0.0
                    return sum + ((sgMode && pair.offset == 0) ? pts * 1.5 : pts)
                }
                let displayTotal = viewModel.livePlayerPoints.isEmpty ? result.lineupPoints : userLiveTotal

                // Time remaining for user's entry
                let userFieldEntry = viewModel.fieldEntries.first(where: { $0.isCurrentUser })
                let userTimeLabel: String = {
                    if isPGA {
                        return userFieldEntry.map { viewModel.pgaTimeRemainingLabel(for: $0) } ?? ""
                    }
                    return userFieldEntry.map { viewModel.timeRemainingLabel(for: $0) } ?? ""
                }()

                HStack(spacing: 20) {
                    VStack(spacing: 2) {
                        Text("RANK")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.6))
                        Text("#\(result.rank)")
                            .font(.title.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .fixedSize()
                        Text("of \(result.totalEntries)")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.6))
                    }

                    VStack(spacing: 2) {
                        Text("LIVE")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.6))
                        Text(String(format: "%.1f", displayTotal))
                            .font(.title.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                        Text("FPTS")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.6))
                    }

                    VStack(spacing: 2) {
                        Text("STATUS")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.6))
                        if allGamesFinal {
                            Text("\(result.rrDelta >= 0 ? "+" : "")\(result.rrDelta)")
                                .font(.title.weight(.bold).monospacedDigit())
                                .foregroundStyle(result.rrDelta >= 0 ? Color(red: 0.4, green: 1.0, blue: 0.5) : Color(red: 1.0, green: 0.5, blue: 0.5))
                            Text("RR delta")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.6))
                        } else {
                            Text(userTimeLabel.isEmpty ? "—" : userTimeLabel)
                                .font(.title3.weight(.bold))
                                .foregroundStyle(userTimeLabel.contains("live") ? Color.red : .white)
                            Text("remaining")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
            } else if viewModel.currentUserEntry != nil {
                VStack(spacing: 8) {
                    Text("Your lineup is locked in")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                    Text("Scoring in progress...")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
            } else {
                Text("You haven't entered this contest")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.12, blue: 0.22),
                    Color(red: 0.15, green: 0.20, blue: 0.35)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
    }

    // MARK: - Your Lineup Card

    @State private var showLineupDetail = false

    private var yourLineupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showLineupDetail.toggle()
                }
            } label: {
                HStack {
                    Text("Your Lineup")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    let isSG = viewModel.tournament?.isSingleGame == true
                    let userTotal = viewModel.selectedPlayers.enumerated().reduce(0.0) { sum, pair in
                        let pts = viewModel.livePlayerPoints[pair.element.id] ?? 0.0
                        return sum + ((isSG && pair.offset == 0) ? pts * 1.5 : pts)
                    }
                    if userTotal > 0 {
                        Text(String(format: "%.1f", userTotal))
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(brandPurple)
                    }
                    Image(systemName: showLineupDetail ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if showLineupDetail {
                let isSingleGame = viewModel.tournament?.isSingleGame == true
                ForEach(Array(viewModel.selectedPlayers.enumerated()), id: \.element.id) { _, player in
                    let isMVP = isSingleGame && viewModel.mvpPlayerID == player.id
                    let livePts = viewModel.livePlayerPoints[player.id]
                    let liveStats = viewModel.livePlayerStats[player.id]
                    // Check if the player's game has started/finished via game info
                    let gameState: String = {
                        guard let gid = player.gameID else { return "pre" }
                        return viewModel.liveGameInfo[gid]?.state ?? "pre"
                    }()
                    let gameStartedOrDone = gameState == "in" || gameState == "post"
                    let rawPts = livePts ?? (gameStartedOrDone ? 0.0 : player.projectedPoints)
                    let displayPts = isMVP ? rawPts * 1.5 : rawPts
                    HStack(spacing: 12) {
                        Text(isMVP ? "MVP" : player.position)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(isMVP ? .black : .white)
                            .frame(width: 28, height: 28)
                            .background(isMVP ? Color.yellow : brandPurple)
                            .clipShape(isMVP ? AnyShape(Capsule()) : AnyShape(Circle()))

                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                // If the slate hasn't fully loaded, `player.name` may be
                                // the raw ID (e.g. "mlb-41169"). Substitute a friendlier
                                // placeholder until activePlayers / entry names resolve.
                                let resolvedName: String = {
                                    let rawPrefixes = ["nba-", "pga-", "ncaam-", "mlb-", "nhl-", "epl-", "ucl-", "wc-", "ufc-", "cfb-", "nfl-"]
                                    if rawPrefixes.contains(where: { player.name.hasPrefix($0) }) {
                                        return "Loading…"
                                    }
                                    return player.name
                                }()
                                Text(resolvedName)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(resolvedName == "Loading…" ? .secondary : .primary)
                                    .lineLimit(1)
                                if player.salary > 0 {
                                    let displaySalary = isMVP ? Int(Double(player.salary) * 1.5) : player.salary
                                    Text("$\(viewModel.formatSalary(displaySalary))")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.secondary)
                                }
                                if isPGA, let stats = liveStats, !stats.minutes.isEmpty, stats.minutes != "999" {
                                    Text(stats.minutes)
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Color(red: 0.0, green: 0.5, blue: 0.2))
                                        .clipShape(Capsule())
                                }
                                if let own = ownershipPct[player.id] {
                                    Text("\(Int(own.rounded()))%")
                                        .font(.system(size: 8, weight: .medium))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(brandPurple.opacity(0.6))
                                        .clipShape(Capsule())
                                }
                            }
                            if let stats = liveStats {
                                if isPGA {
                                    pgaStatLine(stats: stats)
                                } else if isMLB {
                                    mlbStatLine(stats: stats, position: player.position)
                                } else if isNHL {
                                    nhlStatLine(stats: stats, position: player.position)
                                } else if isSoccer {
                                    Text("\(stats.points) G  \(stats.assists) A  \(stats.rebounds) SOT  \(stats.blocks) SV  \(stats.fgm) FD  \(stats.ftm) YC")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                } else if isUFC {
                                    Text("\(stats.points) SIG  \(stats.rebounds) TD  \(stats.assists) KD  \(stats.steals) SUB  \(stats.turnovers) ABS")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                } else {
                                    Text("\(stats.points) PTS  \(stats.rebounds) REB  \(stats.assists) AST  \(stats.blocks) BLK  \(stats.steals) STL  \(stats.turnovers) TO")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                if isPGA {
                                    // Show round status instead of generic game status
                                    Text("Round \(viewModel.currentRound) • Active")
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(stats.gameFinal ? .green : .red)
                                        .lineLimit(1)
                                } else {
                                    Text(stats.gameStatus)
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(stats.gameFinal ? .green : .red)
                                        .lineLimit(1)
                                }
                            } else if gameState == "post" {
                                Text("\(player.team) • DNP")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(player.team)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 1) {
                            HStack(spacing: 3) {
                                if isMVP {
                                    Text("1.5x")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.black)
                                        .padding(.horizontal, 3)
                                        .padding(.vertical, 1)
                                        .background(Color.yellow)
                                        .clipShape(RoundedRectangle(cornerRadius: 3))
                                }
                                Text(String(format: "%.1f", displayPts))
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(gameStartedOrDone ? (isMVP ? .orange : brandPurple) : .secondary)
                            }
                            if gameState == "post" {
                                Text("Final")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.green)
                            } else if gameStartedOrDone {
                                Text("FPTS")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.tertiary)
                            } else {
                                Text("proj")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                // Total row (with MVP 1.5x multiplier for single-game)
                let lineupTotal = viewModel.selectedPlayers.enumerated().reduce(0.0) { sum, pair in
                    let pts = viewModel.livePlayerPoints[pair.element.id] ?? 0.0
                    return sum + ((isSingleGame && pair.offset == 0) ? pts * 1.5 : pts)
                }
                let lineupSalary: Int = {
                    let raw: Int
                    if isSingleGame && !viewModel.selectedPlayers.isEmpty {
                        raw = Int(Double(viewModel.selectedPlayers[0].salary) * 1.5) + viewModel.selectedPlayers.dropFirst().reduce(0) { $0 + $1.salary }
                    } else {
                        raw = viewModel.selectedPlayers.reduce(0) { $0 + $1.salary }
                    }
                    // Cap at tournament salary cap (same as leaderboard display)
                    let cap = viewModel.tournament?.salaryCap ?? 50000
                    return min(raw, cap)
                }()
                Divider()
                HStack {
                    Text("TOTAL")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    if lineupSalary > 0 {
                        Text("$\(viewModel.formatSalary(lineupSalary))")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(String(format: "%.1f", lineupTotal))
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(brandPurple)
                    Text("FPTS")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            } else if !viewModel.selectedPlayers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.selectedPlayers) { player in
                            // Substitute "…" for raw-ID names while the slate is still loading.
                            let rawPrefixes = ["nba-", "pga-", "ncaam-", "mlb-", "nhl-", "epl-", "ucl-", "wc-", "ufc-", "cfb-", "nfl-"]
                            let isRaw = rawPrefixes.contains(where: { player.name.hasPrefix($0) })
                            Text(isRaw ? "…" : lastName(player.name))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(isRaw ? .secondary : .primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(brandPurple.opacity(0.12))
                                .clipShape(Capsule())
                                .redacted(reason: isRaw ? .placeholder : [])
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    // MARK: - Leaderboard

    @State private var expandedEntryID: UUID? = nil
    @State private var leaderboardPageSize: Int = 25
    @State private var showPlayerSearch: Bool = false
    @State private var playerSearchText: String = ""

    /// Entries to display: top N plus any user entries pinned at bottom if outside that range
    private var visibleLeaderboardEntries: [DFSLeaderboardEntry] {
        let all = viewModel.leaderboardEntries
        let topSlice = Array(all.prefix(leaderboardPageSize))
        let topSliceIDs = Set(topSlice.map(\.id))
        // Find user entries that aren't already in the top slice
        let missingUserEntries = all.filter { $0.isCurrentUser && !topSliceIDs.contains($0.id) }
        if missingUserEntries.isEmpty {
            return topSlice
        }
        return topSlice + missingUserEntries
    }

    private var playersByID: [String: DFSPlayer] {
        // Use the slate-wide salary snapshot saved at contest creation time as the source
        // of truth. This covers every player on the slate (not just the user's 6 picks),
        // so bot lineups display the exact same prices that were offered during lineup
        // building — even for players the user didn't draft. Falls back to the user's
        // entry-record salaries (if the slate snapshot wasn't saved), then activePlayers.
        let canonicalSalaries: [String: Int] = {
            guard let tid = viewModel.activeTournamentID else { return [:] }
            if let slate = viewModel.tournamentPlayerSalaries[tid], !slate.isEmpty {
                return slate
            }
            if let entry = viewModel.entryRecord(for: tid, lineupNumber: viewModel.activeLineupNumber),
               let saved = entry.lineupPlayerSalaries {
                return saved
            }
            return [:]
        }()
        var dict: [String: DFSPlayer] = [:]
        for p in viewModel.activePlayers {
            if let canonical = canonicalSalaries[p.id], canonical > 0, canonical != p.salary {
                var fixed = DFSPlayer(
                    id: p.id, name: p.name, team: p.team, position: p.position,
                    salary: canonical, projectedPoints: p.projectedPoints,
                    gameID: p.gameID, injuryStatus: p.injuryStatus,
                    battingOrder: p.battingOrder
                )
                fixed.gamesPlayed = p.gamesPlayed
                fixed.playedRecently = p.playedRecently
                fixed.isConfirmedActive = p.isConfirmedActive
                fixed.isStartingGoalie = p.isStartingGoalie
                dict[p.id] = fixed
            } else {
                dict[p.id] = p
            }
        }
        return dict
    }

    /// Ownership percentage for each player across all field entries.
    private var ownershipPct: [String: Double] {
        let entries = viewModel.fieldEntries
        guard !entries.isEmpty else { return [:] }
        var counts: [String: Int] = [:]
        for entry in entries {
            for pid in entry.playerIDs {
                counts[pid, default: 0] += 1
            }
        }
        let total = Double(entries.count)
        return counts.mapValues { Double($0) / total * 100.0 }
    }

    /// Resolves the display name for a player ID, trying multiple sources
    private func resolvePlayerName(_ playerID: String) -> String {
        if let player = playersByID[playerID] {
            return player.name
        }
        // Two-way player SP entries have IDs like "mlb-12345-sp" — look up the base batter entry
        if playerID.hasSuffix("-sp") {
            let baseID = String(playerID.dropLast(3))
            if let player = playersByID[baseID] {
                return player.name
            }
        }
        if let liveName = viewModel.livePlayerStats[playerID]?.name, liveName != playerID {
            return liveName
        }
        // Check the user's selected players (may have entry-record names for stubs)
        if let stubPlayer = viewModel.selectedPlayers.first(where: { $0.id == playerID }),
           stubPlayer.name != playerID {
            return stubPlayer.name
        }
        return playerID
    }

    private var leaderboardSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Leaderboard")
                    .font(.headline)
                Spacer()
                Text("\(viewModel.leaderboardEntries.count) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showPlayerSearch.toggle()
                        if !showPlayerSearch { playerSearchText = "" }
                    }
                } label: {
                    Image(systemName: showPlayerSearch ? "xmark" : "magnifyingglass")
                        .font(.subheadline)
                        .foregroundStyle(brandPurple)
                }
            }

            if showPlayerSearch {
                playerSearchBar
            }

            if viewModel.leaderboardEntries.isEmpty {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Loading leaderboard…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 16)
            } else {
                // Header row
                HStack {
                    Text("#")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .leading)
                    Text("PLAYER")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("REM")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .trailing)
                    Text("FPTS")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .trailing)
                }
                .padding(.horizontal, 12)

                ForEach(Array(visibleLeaderboardEntries.enumerated()), id: \.element.id) { idx, entry in
                    // Show separator once before pinned user entries outside the current page
                    if entry.isCurrentUser && entry.rank > leaderboardPageSize {
                        let isFirstPinned = !visibleLeaderboardEntries.prefix(idx).contains(where: { $0.isCurrentUser && $0.rank > leaderboardPageSize })
                        if isFirstPinned {
                            HStack {
                                Spacer()
                                Text("···")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.tertiary)
                                Spacer()
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    leaderboardRow(entry)
                }
            }

            if viewModel.leaderboardEntries.count > leaderboardPageSize {
                let remaining = viewModel.leaderboardEntries.count - leaderboardPageSize
                HStack(spacing: 16) {
                    Button("Show More (\(remaining))") {
                        leaderboardPageSize += 100
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(brandPurple)
                    
                    if remaining > 100 {
                        Button("Show All") {
                            leaderboardPageSize = viewModel.leaderboardEntries.count
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    private var playerSearchBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search players…", text: $playerSearchText)
                    .font(.subheadline)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !playerSearchText.isEmpty {
                    Button {
                        playerSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if !playerSearchText.isEmpty {
                let query = playerSearchText.lowercased()
                let matchingPlayers = viewModel.activePlayers.filter {
                    $0.name.lowercased().contains(query) ||
                    $0.team.lowercased().contains(query)
                }.prefix(20)

                if matchingPlayers.isEmpty {
                    Text("No players found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(Array(matchingPlayers), id: \.id) { player in
                        playerSearchRow(player)
                    }
                }
            }
        }
    }

    private func playerSearchRow(_ player: DFSPlayer) -> some View {
        let own = ownershipPct[player.id]
        let livePts = viewModel.livePlayerPoints[player.id]
        let liveStats = viewModel.livePlayerStats[player.id]
        let playerGameState: String = {
            guard let gid = player.gameID else { return "pre" }
            return viewModel.liveGameInfo[gid]?.state ?? "pre"
        }()
        let gameStartedOrDone = playerGameState == "in" || playerGameState == "post"
        let fpts = livePts ?? (gameStartedOrDone ? 0.0 : player.projectedPoints)

        return HStack(spacing: 8) {
            Text(player.position)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(brandPurple.opacity(0.7))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(player.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if isSoccer && player.isConfirmedActive {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                    }
                    if let own {
                        Text("\(Int(own.rounded()))%")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(brandPurple.opacity(0.6))
                            .clipShape(Capsule())
                    }
                }
                HStack(spacing: 4) {
                    Text(player.team)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if player.salary > 0 {
                        Text("$\(viewModel.formatSalary(player.salary))")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    if let stats = liveStats, !stats.gameStatus.isEmpty {
                        Text(stats.gameFinal ? "Final" : stats.gameStatus)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(stats.gameFinal ? .green : .red)
                    }
                }
            }

            Spacer()

            Text(String(format: "%.1f", fpts))
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(livePts != nil ? .primary : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(.systemGray6).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func leaderboardRow(_ entry: DFSLeaderboardEntry) -> some View {
        let isExpanded = expandedEntryID == entry.id
        let fieldEntry = viewModel.fieldEntries.first(where: { $0.id == entry.id })
        let timeLabel = fieldEntry.map { viewModel.timeRemainingLabel(for: $0) } ?? ""

        return VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedEntryID = isExpanded ? nil : entry.id
                }
            } label: {
                HStack {
                    Text("\(entry.rank)")
                        .font(.subheadline.weight(.medium).monospacedDigit())
                        .foregroundStyle(entry.rank <= 3 ? Color(red: 0.95, green: 0.78, blue: 0.20) : .secondary)
                        .lineLimit(1)
                        .frame(minWidth: 32, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)

                    HStack(spacing: 4) {
                        if entry.isCurrentUser {
                            Image(systemName: "star.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(brandPurple)
                        }
                        Text(entry.name)
                            .font(.subheadline.weight(entry.isCurrentUser ? .bold : .regular))
                            .foregroundStyle(entry.isCurrentUser ? brandPurple : .primary)
                            .lineLimit(1)
                    }

                    Spacer()

                    // Time remaining indicator
                    Text(timeLabel)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(timeLabel.contains("live") ? .red : .secondary)
                        .frame(width: 50, alignment: .trailing)

                    Text(String(format: "%.1f", entry.points))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(entry.isCurrentUser ? brandPurple : .primary)
                        .frame(width: 50, alignment: .trailing)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(width: 16)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            // Expanded roster view with box scores
            if isExpanded, let fieldEntry {
                expandedBoxScore(fieldEntry: fieldEntry)
            }
        }
        .background(entry.isCurrentUser ? brandPurple.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var isMLB: Bool {
        viewModel.sport == "MLB"
    }

    private var isNHL: Bool {
        viewModel.sport == "NHL"
    }

    private var isUFC: Bool {
        viewModel.sport == "UFC"
    }

    private var isSoccer: Bool {
        viewModel.sport == "EPL" || viewModel.sport == "UCL"
    }

    private func expandedBoxScore(fieldEntry: DFSFieldEntry) -> some View {
        VStack(spacing: 0) {
            // Box score header — sport-aware
            HStack(spacing: 0) {
                Text("PLAYER")
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isPGA {
                    Text("R1")
                        .frame(width: 24, alignment: .trailing)
                    Text("R2")
                        .frame(width: 24, alignment: .trailing)
                    Text("R3")
                        .frame(width: 24, alignment: .trailing)
                    Text("R4")
                        .frame(width: 24, alignment: .trailing)
                    Text("TOT")
                        .frame(width: 28, alignment: .trailing)
                } else if isMLB || isNHL {
                    // MLB/NHL use inline stat lines per player,
                    // so we just show a single STATS + FPTS header
                    Text("STATS")
                        .frame(width: 100, alignment: .trailing)
                } else if isSoccer {
                    Text("G")
                        .frame(width: 22, alignment: .trailing)
                    Text("A")
                        .frame(width: 22, alignment: .trailing)
                    Text("SOT")
                        .frame(width: 28, alignment: .trailing)
                    Text("SV")
                        .frame(width: 22, alignment: .trailing)
                    Text("FD")
                        .frame(width: 22, alignment: .trailing)
                } else if isUFC {
                    Text("SIG")
                        .frame(width: 28, alignment: .trailing)
                    Text("TD")
                        .frame(width: 24, alignment: .trailing)
                    Text("KD")
                        .frame(width: 24, alignment: .trailing)
                    Text("SUB")
                        .frame(width: 28, alignment: .trailing)
                    Text("CTRL")
                        .frame(width: 32, alignment: .trailing)
                } else {
                    Text("PTS")
                        .frame(width: 28, alignment: .trailing)
                    Text("REB")
                        .frame(width: 28, alignment: .trailing)
                    Text("AST")
                        .frame(width: 28, alignment: .trailing)
                    Text("STL")
                        .frame(width: 24, alignment: .trailing)
                    Text("BLK")
                        .frame(width: 24, alignment: .trailing)
                }
                Text("FPTS")
                    .frame(width: 36, alignment: .trailing)
            }
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            let isSingleGame = viewModel.tournament?.isSingleGame == true

            ForEach(Array(fieldEntry.playerIDs.enumerated()), id: \.element) { index, playerID in
                let player = playersByID[playerID]
                let liveStats = viewModel.livePlayerStats[playerID]
                let livePts = viewModel.livePlayerPoints[playerID]
                let isMVP = isSingleGame && index == 0
                // Check game state for this player's game
                let playerGameState: String = {
                    guard let gid = player?.gameID else { return "pre" }
                    return viewModel.liveGameInfo[gid]?.state ?? "pre"
                }()
                let gameStartedOrDone = playerGameState == "in" || playerGameState == "post"
                let rawFPTS = livePts ?? (gameStartedOrDone ? 0.0 : player?.projectedPoints ?? 0)
                let displayFPTS = isMVP ? rawFPTS * 1.5 : rawFPTS

                HStack(spacing: 0) {
                    // Player name + game status
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            let slotText = isMVP ? "MVP" : (player?.position ?? "—")
                            let isWideLiveSlot = isMVP || slotText.count > 2
                            Text(slotText)
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(isMVP ? .black : .white)
                                .lineLimit(1)
                                .frame(width: isWideLiveSlot ? 28 : 18, height: 18)
                                .background(isMVP ? Color.yellow : brandPurple.opacity(0.7))
                                .clipShape(isWideLiveSlot ? AnyShape(Capsule()) : AnyShape(Circle()))

                            Text(lastName(resolvePlayerName(playerID)))
                                .font(.caption.weight(.medium))
                                .lineLimit(1)

                            // Confirmed starting XI icon — only meaningful for
                            // soccer where `isConfirmedActive` is set from
                            // ESPN's published lineup ~1h before kickoff.
                            if isSoccer, let p = player, p.isConfirmedActive {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.green)
                            }

                            if isPGA, let stats = liveStats, !stats.minutes.isEmpty, stats.minutes != "999" {
                                Text(stats.minutes)
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color(red: 0.0, green: 0.5, blue: 0.2))
                                    .clipShape(Capsule())
                            }

                            if let sal = player?.salary, sal > 0 {
                                let displaySal = isMVP ? Int(Double(sal) * 1.5) : sal
                                Text("$\(viewModel.formatSalary(displaySal))")
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }

                            if let own = ownershipPct[playerID] {
                                Text("\(Int(own.rounded()))%")
                                    .font(.system(size: 7, weight: .medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 3)
                                    .padding(.vertical, 1)
                                    .background(brandPurple.opacity(0.6))
                                    .clipShape(Capsule())
                            }
                        }

                        // Game status line
                        if isPGA, let stats = liveStats {
                            // Golf: show MC/WD status or round status
                            if stats.gameStatus == "MC" || stats.gameStatus == "WD" || stats.gameStatus == "CUT" {
                                Text(stats.gameStatus)
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.orange)
                            } else if stats.gameFinal {
                                Text("Final")
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(.green)
                            } else {
                                Text("R\(viewModel.currentRound)")
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(.red)
                            }
                        } else if let stats = liveStats {
                            Text(stats.gameStatus)
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(stats.gameFinal ? .green : .red)
                        } else if playerGameState == "post" {
                            Text("Final")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(.green)
                        } else if playerGameState == "in" {
                            Text("Live")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(.red)
                        } else {
                            Text("proj")
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if let stats = liveStats {
                        if isPGA {
                            // Golf scorecard: R1/R2/R3/R4 round scores stored in fgm/fga/threePM/threePA
                            let r1 = stats.fgm > 0 ? "\(stats.fgm)" : "-"
                            let r2 = stats.fga > 0 ? "\(stats.fga)" : "-"
                            let r3 = stats.threePM > 0 ? "\(stats.threePM)" : "-"
                            let r4 = stats.threePA > 0 ? "\(stats.threePA)" : "-"
                            let scoreToPar = stats.points  // score-to-par stored in points
                            Text(r1).frame(width: 24, alignment: .trailing)
                            Text(r2).frame(width: 24, alignment: .trailing)
                            Text(r3).frame(width: 24, alignment: .trailing)
                            Text(r4).frame(width: 24, alignment: .trailing)
                            let parLabel = scoreToPar == 0 ? "E" : (scoreToPar > 0 ? "+\(scoreToPar)" : "\(scoreToPar)")
                            Text(parLabel)
                                .foregroundStyle(scoreToPar < 0 ? .red : (scoreToPar == 0 ? .primary : .secondary))
                                .frame(width: 28, alignment: .trailing)
                        } else if isMLB {
                            // MLB: show compact stat line adapted for pitcher vs batter
                            Text(mlbCompactStats(stats: stats, position: player?.position ?? ""))
                                .font(.system(size: 9).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: 100, alignment: .trailing)
                        } else if isNHL {
                            // NHL: show compact stat line adapted for skater vs goalie
                            Text(nhlCompactStats(stats: stats, position: player?.position ?? ""))
                                .font(.system(size: 9).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: 100, alignment: .trailing)
                        } else if isSoccer {
                            // Soccer: G, A, SOT, SV, FD
                            Text("\(stats.points)")
                                .frame(width: 22, alignment: .trailing)
                            Text("\(stats.assists)")
                                .frame(width: 22, alignment: .trailing)
                            Text("\(stats.rebounds)")
                                .frame(width: 28, alignment: .trailing)
                            Text("\(stats.blocks)")
                                .frame(width: 22, alignment: .trailing)
                            Text("\(stats.fgm)")
                                .frame(width: 22, alignment: .trailing)
                        } else if isUFC {
                            // UFC: SIG, TD, KD, SUB, CTRL
                            Text("\(stats.points)")
                                .frame(width: 28, alignment: .trailing)
                            Text("\(stats.rebounds)")
                                .frame(width: 24, alignment: .trailing)
                            Text("\(stats.assists)")
                                .frame(width: 24, alignment: .trailing)
                            Text("\(stats.steals)")
                                .frame(width: 28, alignment: .trailing)
                            let ctrlMin = stats.blocks / 60
                            let ctrlSec = stats.blocks % 60
                            Text("\(ctrlMin):\(String(format: "%02d", ctrlSec))")
                                .frame(width: 32, alignment: .trailing)
                        } else {
                            Text("\(stats.points)")
                                .frame(width: 28, alignment: .trailing)
                            Text("\(stats.rebounds)")
                                .frame(width: 28, alignment: .trailing)
                            Text("\(stats.assists)")
                                .frame(width: 28, alignment: .trailing)
                            Text("\(stats.steals)")
                                .frame(width: 24, alignment: .trailing)
                            Text("\(stats.blocks)")
                                .frame(width: 24, alignment: .trailing)
                        }
                    } else if isPGA {
                        // No live stats yet for this golfer
                        Text("-").frame(width: 24, alignment: .trailing)
                        Text("-").frame(width: 24, alignment: .trailing)
                        Text("-").frame(width: 24, alignment: .trailing)
                        Text("-").frame(width: 24, alignment: .trailing)
                        Text("-").frame(width: 28, alignment: .trailing)
                    } else if isMLB || isNHL {
                        Text(gameStartedOrDone ? "—" : "")
                            .frame(width: 100, alignment: .trailing)
                    } else if isSoccer {
                        if gameStartedOrDone {
                            Text("0").frame(width: 22, alignment: .trailing)
                            Text("0").frame(width: 22, alignment: .trailing)
                            Text("0").frame(width: 28, alignment: .trailing)
                            Text("0").frame(width: 22, alignment: .trailing)
                            Text("0").frame(width: 22, alignment: .trailing)
                        } else {
                            Text("-").frame(width: 22, alignment: .trailing)
                            Text("-").frame(width: 22, alignment: .trailing)
                            Text("-").frame(width: 28, alignment: .trailing)
                            Text("-").frame(width: 22, alignment: .trailing)
                            Text("-").frame(width: 22, alignment: .trailing)
                        }
                    } else if isUFC {
                        if gameStartedOrDone {
                            Text("0").frame(width: 28, alignment: .trailing)
                            Text("0").frame(width: 24, alignment: .trailing)
                            Text("0").frame(width: 24, alignment: .trailing)
                            Text("0").frame(width: 28, alignment: .trailing)
                            Text("0:00").frame(width: 32, alignment: .trailing)
                        } else {
                            Text("-").frame(width: 28, alignment: .trailing)
                            Text("-").frame(width: 24, alignment: .trailing)
                            Text("-").frame(width: 24, alignment: .trailing)
                            Text("-").frame(width: 28, alignment: .trailing)
                            Text("-").frame(width: 32, alignment: .trailing)
                        }
                    } else if gameStartedOrDone {
                        Text("0").frame(width: 28, alignment: .trailing)
                        Text("0").frame(width: 28, alignment: .trailing)
                        Text("0").frame(width: 28, alignment: .trailing)
                        Text("0").frame(width: 24, alignment: .trailing)
                        Text("0").frame(width: 24, alignment: .trailing)
                    } else {
                        Text("-").frame(width: 28, alignment: .trailing)
                        Text("-").frame(width: 28, alignment: .trailing)
                        Text("-").frame(width: 28, alignment: .trailing)
                        Text("-").frame(width: 24, alignment: .trailing)
                        Text("-").frame(width: 24, alignment: .trailing)
                    }

                    Text(String(format: "%.1f", displayFPTS))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(gameStartedOrDone ? brandPurple : .secondary)
                        .frame(width: 36, alignment: .trailing)
                }
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }

            // Totals row — only count actual live points, not projections
            // In single-game mode, MVP (index 0) gets 1.5x points
            let totalFPTS: Double = {
                var total = 0.0
                for (i, pid) in fieldEntry.playerIDs.enumerated() {
                    let pts = viewModel.livePlayerPoints[pid] ?? 0
                    total += (isSingleGame && i == 0) ? pts * 1.5 : pts
                }
                return total
            }()
            let rawTotalSalary: Int = {
                var total = 0
                for (i, pid) in fieldEntry.playerIDs.enumerated() {
                    let sal = playersByID[pid]?.salary ?? 0
                    total += (isSingleGame && i == 0) ? Int(Double(sal) * 1.5) : sal
                }
                return total
            }()
            // Cap displayed salary at the sport's salary cap
            let liveSalaryCap = viewModel.tournament?.salaryCap ?? 50000
            let totalSalary = min(rawTotalSalary, liveSalaryCap)
            Divider().padding(.horizontal, 12)
            HStack(spacing: 0) {
                Text("TOTAL")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                if totalSalary > 0 {
                    Text("$\(viewModel.formatSalary(totalSalary))")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
                Spacer()
                Text(String(format: "%.1f", totalFPTS))
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(brandPurple)
                    .frame(width: 38, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(Color(.systemGray6).opacity(0.5))
    }

    // MARK: - Games Status

    private var gamesStatusSection: some View {
        let liveInfo = viewModel.liveGameInfo
        let finalCount = viewModel.slateGames.filter { game in
            liveInfo[game.id]?.state == "post" || game.state == "post"
        }.count
        let totalCount = viewModel.slateGames.count

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Games")
                    .font(.headline)
                Spacer()
                Text("\(finalCount)/\(totalCount) final")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(viewModel.slateGames) { game in
                let info = liveInfo[game.id]
                let isUFCGame = info?.sportType == "ufc"
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(game.awayTeam)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                                .fixedSize()
                                .frame(minWidth: 36, alignment: .leading)
                            if let info {
                                if isUFCGame {
                                    if info.awayScore == 1 {
                                        Image(systemName: "checkmark.seal.fill")
                                            .font(.caption)
                                            .foregroundStyle(.green)
                                    }
                                } else {
                                    Text("\(info.awayScore)")
                                        .font(.subheadline.weight(.bold).monospacedDigit())
                                }
                            }
                        }
                        HStack(spacing: 6) {
                            Text(game.homeTeam)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                                .fixedSize()
                                .frame(minWidth: 36, alignment: .leading)
                            if let info {
                                if isUFCGame {
                                    if info.homeScore == 1 {
                                        Image(systemName: "checkmark.seal.fill")
                                            .font(.caption)
                                            .foregroundStyle(.green)
                                    }
                                } else {
                                    Text("\(info.homeScore)")
                                        .font(.subheadline.weight(.bold).monospacedDigit())
                                }
                            }
                        }
                    }

                    Spacer()

                    let state = info?.state ?? game.state
                    if state == "post" {
                        // UFC: surface the finish method (e.g. "U Dec",
                        // "Sub R3 2:32", "TKO R1 4:30") which we stash in
                        // `info.clock`. Other sports keep the simple "Final".
                        let ufcFinish: String? = {
                            guard info?.sportType == "ufc",
                                  let c = info?.clock, !c.isEmpty else { return nil }
                            return c
                        }()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Final")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.green)
                            if let ufcFinish {
                                Text(ufcFinish)
                                    .font(.caption2.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else if state == "in", let info {
                        VStack(spacing: 2) {
                            Text(info.displayStatus)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.red)
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 5, height: 5)
                                Text("LIVE")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.red)
                            }
                        }
                    } else {
                        Text(game.startTime.formatted(date: .omitted, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
            Spacer()
            Button {
                viewModel.dismissError()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Helpers

    private func lastName(_ fullName: String) -> String {
        let parts = fullName.components(separatedBy: " ").filter { !$0.isEmpty }
        guard parts.count >= 2 else { return fullName.trimmingCharacters(in: .whitespaces) }
        let suffixes: Set<String> = ["Jr.", "Jr", "Sr.", "Sr", "II", "III", "IV", "V"]
        if let last = parts.last, suffixes.contains(last), parts.count >= 3 {
            return parts[parts.count - 2] + " " + last
        }
        return parts.last ?? fullName.trimmingCharacters(in: .whitespaces)
    }

    /// Returns true if the given position is a pitcher (SP or RP).
    private func isPitcher(_ position: String) -> Bool {
        position == "SP" || position == "RP" || position == "P"
    }

    /// Returns true if the given position is an NHL goalie.
    private func isNHLGoalie(_ position: String) -> Bool {
        position == "G"
    }

    /// Compact one-line stats string for the leaderboard box score rows.
    private func mlbCompactStats(stats: DFSPlayerLiveStats, position: String) -> String {
        if isPitcher(position) {
            // Pitcher: IP K ER W
            let ip = stats.minutes
            let k = stats.points
            let er = stats.rebounds
            let w = stats.assists
            var parts = ["\(ip)", "\(k)K", "\(er)ER"]
            if w > 0 { parts.append("W") }
            return parts.joined(separator: " ")
        } else {
            // Batter: H/AB - hit types, extras
            let ab = stats.minutes.replacingOccurrences(of: " AB", with: "")
            let h = stats.points
            let hr = stats.rebounds
            let rbi = stats.assists
            let r = stats.steals
            let bb = stats.blocks
            let sb = stats.turnovers
            let doubles = stats.fga
            let triples = stats.threePM

            var hitTypes: [String] = []
            if doubles > 0 { hitTypes.append(doubles == 1 ? "2B" : "\(doubles)x2B") }
            if triples > 0 { hitTypes.append(triples == 1 ? "3B" : "\(triples)x3B") }
            if hr > 0 { hitTypes.append(hr == 1 ? "HR" : "\(hr)HR") }
            let hitDetail = hitTypes.isEmpty ? "" : " \(hitTypes.joined(separator: " "))"

            var extras: [String] = []
            if rbi > 0 { extras.append("\(rbi)RBI") }
            if r > 0 { extras.append("\(r)R") }
            if bb > 0 { extras.append("\(bb)BB") }
            if sb > 0 { extras.append("\(sb)SB") }
            let extrasStr = extras.isEmpty ? "" : " \(extras.joined(separator: " "))"

            return "\(h)/\(ab)\(hitDetail)\(extrasStr)"
        }
    }

    /// MLB stat line string for "Your Lineup" detail — shows baseball-appropriate stats.
    private func mlbStatLineText(stats: DFSPlayerLiveStats, position: String) -> String {
        if isPitcher(position) {
            // Pitcher: IP, K, ER, W
            // Mapped as: minutes = IP, points = K, rebounds = ER, assists = W
            var parts = [stats.minutes, "\(stats.points) K", "\(stats.rebounds) ER"]
            if stats.assists > 0 { parts.append("W") }
            return parts.joined(separator: "  ")
        } else {
            // Batter: H/AB (hit types)  RBI  R  BB  SB
            let ab = stats.minutes.replacingOccurrences(of: " AB", with: "")
            let h = stats.points
            let hr = stats.rebounds
            let rbi = stats.assists
            let r = stats.steals
            let bb = stats.blocks
            let sb = stats.turnovers
            let singles = stats.fgm
            let doubles = stats.fga
            let triples = stats.threePM

            // Build hit detail: e.g. "1B, 2B, HR"
            var hitParts: [String] = []
            if singles > 0 { hitParts.append(singles == 1 ? "1B" : "\(singles) 1B") }
            if doubles > 0 { hitParts.append(doubles == 1 ? "2B" : "\(doubles) 2B") }
            if triples > 0 { hitParts.append(triples == 1 ? "3B" : "\(triples) 3B") }
            if hr > 0 { hitParts.append(hr == 1 ? "HR" : "\(hr) HR") }
            let hitDetail = hitParts.isEmpty ? "" : " (\(hitParts.joined(separator: ", ")))"

            var extras: [String] = []
            if rbi > 0 { extras.append("\(rbi) RBI") }
            if r > 0 { extras.append("\(r) R") }
            if bb > 0 { extras.append("\(bb) BB") }
            if sb > 0 { extras.append("\(sb) SB") }
            let extrasStr = extras.isEmpty ? "" : "  \(extras.joined(separator: "  "))"

            return "\(h)/\(ab)\(hitDetail)\(extrasStr)"
        }
    }

    /// MLB stat line view for "Your Lineup" detail.
    private func mlbStatLine(stats: DFSPlayerLiveStats, position: String) -> some View {
        Text(mlbStatLineText(stats: stats, position: position))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    // MARK: - NHL Helpers

    /// Compact one-line stats string for the leaderboard box score rows (NHL).
    private func nhlCompactStats(stats: DFSPlayerLiveStats, position: String) -> String {
        if isNHLGoalie(position) {
            // Goalie: SV GA W SO
            let sv = stats.points
            let ga = stats.rebounds
            var parts = ["\(sv)SV", "\(ga)GA"]
            if stats.assists > 0 { parts.append("W") }
            if stats.steals > 0 { parts.append("SO") }
            return parts.joined(separator: " ")
        } else {
            // Skater: G A SOG
            let g = stats.fgm
            let a = stats.fga
            let sog = stats.threePM
            return "\(g)G \(a)A \(sog)SOG"
        }
    }

    /// NHL stat line string for "Your Lineup" detail — shows hockey-appropriate stats.
    private func nhlStatLineText(stats: DFSPlayerLiveStats, position: String) -> String {
        if isNHLGoalie(position) {
            // Goalie: Saves, Goals Against, Win, Shutout
            let sv = stats.points
            let ga = stats.rebounds
            var parts = ["\(sv) SV", "\(ga) GA"]
            if stats.assists > 0 { parts.append("W") }
            if stats.steals > 0 { parts.append("SO") }
            return parts.joined(separator: "  ")
        } else {
            // Skater: Goals, Assists, SOG, BLK
            let g = stats.fgm
            let a = stats.fga
            let sog = stats.threePM
            let blk = stats.threePA
            return "\(g) G  \(a) A  \(sog) SOG  \(blk) BLK"
        }
    }

    /// NHL stat line view for "Your Lineup" detail.
    private func nhlStatLine(stats: DFSPlayerLiveStats, position: String) -> some View {
        Text(nhlStatLineText(stats: stats, position: position))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    /// PGA stat line view for "Your Lineup" detail — shows round scores and score-to-par.
    private func pgaStatLine(stats: DFSPlayerLiveStats) -> some View {
        let r1 = stats.fgm > 0 ? "\(stats.fgm)" : "-"
        let r2 = stats.fga > 0 ? "\(stats.fga)" : "-"
        let r3 = stats.threePM > 0 ? "\(stats.threePM)" : "-"
        let r4 = stats.threePA > 0 ? "\(stats.threePA)" : "-"
        let scoreToPar = stats.points
        let parLabel = scoreToPar == 0 ? "E" : (scoreToPar > 0 ? "+\(scoreToPar)" : "\(scoreToPar)")

        // Check for cut/withdrawn
        let isCut = stats.steals == 1
        let isWD = stats.blocks == 1

        return HStack(spacing: 6) {
            Text("R1:\(r1)  R2:\(r2)  R3:\(r3)  R4:\(r4)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(parLabel)
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(scoreToPar < 0 ? .red : (scoreToPar == 0 ? .primary : .secondary))
            if isCut {
                Text("MC")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.orange)
                    .clipShape(Capsule())
            } else if isWD {
                Text("WD")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.gray)
                    .clipShape(Capsule())
            }
        }
    }

    // MARK: - Shimmer Placeholder

    /// Skeleton layout shown while `isTournamentReady` is false. Mimics the
    /// real card structure so the layout doesn't jump when data lands.
    private var shimmerPlaceholder: some View {
        VStack(spacing: 16) {
            // Status header skeleton (dark card)
            VStack(spacing: 16) {
                HStack(spacing: 24) {
                    shimmerBox(width: 60, height: 32)
                    shimmerBox(width: 60, height: 32)
                    shimmerBox(width: 60, height: 32)
                }
                .padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity)
            .padding(20)
            .background(Color(red: 0.10, green: 0.12, blue: 0.22))
            .clipShape(RoundedRectangle(cornerRadius: 16))

            // Your Lineup skeleton
            VStack(alignment: .leading, spacing: 10) {
                shimmerBox(width: 100, height: 18)
                HStack(spacing: 8) {
                    ForEach(0..<5, id: \.self) { _ in
                        shimmerBox(width: 60, height: 26)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.05), radius: 4, y: 2)

            // Leaderboard skeleton
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    shimmerBox(width: 100, height: 18)
                    Spacer()
                    shimmerBox(width: 60, height: 12)
                }
                ForEach(0..<6, id: \.self) { _ in
                    HStack {
                        shimmerBox(width: 20, height: 14)
                        shimmerBox(width: 140, height: 16)
                        Spacer()
                        shimmerBox(width: 40, height: 14)
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(16)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.05), radius: 4, y: 2)

            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.75)
                Text("Loading contest…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }

    private func shimmerBox(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color(.systemGray5))
            .frame(width: width, height: height)
            .shimmering()
    }
}
