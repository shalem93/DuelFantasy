import SwiftUI

struct TennisBracketLiveView: View {
    @Bindable var viewModel: TennisBracketViewModel
    @State private var refreshTick: Int = 0
    @State private var selectedEntry: TennisBracketLeaderboardEntry?
    @State private var visibleCount: Int = 25

    private var brandPurple: Color {
        Color(red: 0.48, green: 0.23, blue: 0.93)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                drawTypeToggle
                statusHeader
                roundProgressCard
                yourPicksCard
                if !viewModel.myGroups.isEmpty {
                    groupsCard
                }
                leaderboardSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.94, green: 0.97, blue: 0.94),
                    Color(red: 0.96, green: 0.97, blue: 1.00)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        .task {
            // If the user landed here directly (e.g. from home → My Contests
            // → bracket) the lobby task never ran, so `tournament` is nil and
            // the user's saved bracket picks were never fetched. Run a full
            // load when no tournament has been loaded yet, OR when the
            // currently loaded tournament's tid doesn't match the active
            // (grandSlam, drawType) pair (i.e. user navigated in for one
            // draw, then later opened the other one on the home cards).
            // We do NOT use `.task(id:)` here because @Observable re-renders
            // would cancel and restart the in-flight load on every state
            // mutation, producing the load→cancel→reload loop visible in
            // the console.
            let expectedTID = TennisBracketViewModel.currentTournamentID(
                grandSlam: viewModel.selectedGrandSlam,
                drawType: viewModel.selectedDrawType
            )
            // Wait for any in-flight load (e.g. FantasyHubView's preload)
            // to finish before deciding whether to fire another. Without
            // this guard the live view's .task races the preload, both
            // bump `currentLoadToken`, the first aborts mid-flight, and
            // user-entry fetches can be silently lost — resulting in
            // "No bracket submitted" until the user re-toggles the draw.
            while viewModel.isLoading {
                try? await Task.sleep(nanoseconds: 80_000_000)  // 80ms
            }
            if viewModel.tournament?.id != expectedTID || !viewModel.hasAttemptedLoad {
                await viewModel.loadTournament()
            }
            // Late-bind fetch for picks: catches the case where the first
            // loadTournament ran from FantasyHubView before auth had
            // propagated, so the user-entry fetch was silently skipped
            // and "No bracket submitted" sticks until draw type is
            // toggled. Same fix as PlayoffTiers/SoccerTiers.
            await viewModel.restoreUserPicksIfMissing()
            // Refresh on every appearance. The bracket runs across two weeks of slams
            // and matches finish hourly — the prior cached state goes stale fast, so
            // unconditionally re-fetch when the user opens the view.
            await viewModel.refreshLive()
            await viewModel.loadMyGroups()
        }
        .refreshable {
            // Pull-to-refresh for explicit re-fetch.
            await viewModel.refreshLive()
            await viewModel.loadMyGroups()
        }
        .task(id: refreshTick) {
            guard viewModel.isLive else { return }
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            await viewModel.refreshLive()
            refreshTick += 1
        }
        .sheet(item: $selectedEntry) { entry in
            entryDetailSheet(entry)
        }
    }

    // MARK: - Draw Type Toggle

    private var drawTypeToggle: some View {
        HStack(spacing: 8) {
            ForEach(DrawType.allCases) { dt in
                Button {
                    if viewModel.selectedDrawType != dt {
                        viewModel.selectedDrawType = dt
                        viewModel.hasAttemptedLoad = false
                        Task { await viewModel.loadTournament() }
                    }
                } label: {
                    Text(dt.shortName)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(viewModel.selectedDrawType == dt ? brandPurple : Color.gray.opacity(0.15))
                        .foregroundStyle(viewModel.selectedDrawType == dt ? .white : .primary)
                        .clipShape(Capsule())
                }
            }
            Spacer()
        }
    }

    // MARK: - Status Header

    private var statusHeader: some View {
        VStack(spacing: 12) {
            HStack {
                statusBadge
                Spacer()
            }

            // Tournament context: e.g. "2026 French Open — ATP" / "WTA".
            // Without this the only on-screen label is the generic
            // "Tennis Brackets" nav title, leaving no indication of
            // which slam or year you're looking at.
            if let title = viewModel.tournament?.title, !title.isEmpty {
                Text(title.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .top) {
                if let rank = viewModel.userRank {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your Rank")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                        Text("#\(rank)")
                            .font(.title2.weight(.bold))
                    }
                }
                Spacer()
                if let pts = viewModel.userTotalPoints {
                    VStack(alignment: .center, spacing: 2) {
                        Text("Your Points")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                        Text(String(format: "%.0f", pts))
                            .font(.title2.weight(.bold))
                    }
                    Spacer()
                }
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Field Size")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                    Text("\(viewModel.fieldEntries.count)")
                        .font(.title2.weight(.bold))
                }
            }
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [Color(red: 0.12, green: 0.25, blue: 0.12), Color(red: 0.20, green: 0.45, blue: 0.20)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var statusBadge: some View {
        let (label, color): (String, Color) = {
            if viewModel.isSettled { return ("FINAL", .orange) }
            if viewModel.isLive { return ("LIVE", .red) }
            return ("LOCKED", .blue)
        }()

        return Text(label)
            .font(.caption.weight(.black))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color)
            .foregroundStyle(.white)
            .clipShape(Capsule())
    }

    // MARK: - Round Progress

    private var roundProgressCard: some View {
        let round = viewModel.currentRound
        let (completed, total) = viewModel.currentRoundProgress

        return VStack(spacing: 8) {
            HStack {
                Text(roundDisplayName(round))
                    .font(.subheadline.weight(.bold))
                Spacer()
                Text("\(completed)/\(total) matches")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.15))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(brandPurple)
                        .frame(width: total > 0 ? geo.size.width * Double(completed) / Double(total) : 0)
                }
            }
            .frame(height: 8)

            Text("Total completed: \(viewModel.completedMatches)/127")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Your Picks

    private var yourPicksCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your Bracket")
                .font(.headline.weight(.bold))

            if viewModel.userPicks.isEmpty {
                Text("No bracket submitted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let yourEliminated = TennisBracketEngine.eliminatedPlayerNames(results: viewModel.results)
                ForEach(0..<TennisBracketEngine.rounds.count, id: \.self) { roundIndex in
                    let round = TennisBracketEngine.rounds[roundIndex]
                    let matchCount = TennisBracketEngine.matchesPerRound[roundIndex]
                    let pts = TennisBracketEngine.pointsPerRound[roundIndex]

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(roundDisplayName(round))
                                .font(.caption.weight(.bold))
                            Spacer()
                            Text("\(pts) pts each")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }

                        let picks = (1...matchCount).compactMap { matchNum -> (slot: String, name: String)? in
                            let slot = TennisBracketEngine.matchSlot(round: round, matchNumber: matchNum)
                            guard let name = viewModel.userPicks[slot] else { return nil }
                            return (slot, name)
                        }

                        if picks.isEmpty {
                            Text("No picks for this round")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        } else {
                            let columns = round == "F" || round == "SF" ? 1 : 2
                            let rows = stride(from: 0, to: picks.count, by: columns).map {
                                Array(picks[$0..<min($0 + columns, picks.count)])
                            }

                            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                HStack(spacing: 6) {
                                    ForEach(row, id: \.slot) { pick in
                                        pickStatusBadge(slot: pick.slot, name: pick.name, eliminated: yourEliminated)
                                    }
                                    if row.count < columns {
                                        Spacer()
                                    }
                                }
                            }
                        }
                    }
                    if roundIndex < TennisBracketEngine.rounds.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func pickStatusBadge(slot: String, name: String, eliminated: Set<String>) -> some View {
        let result = viewModel.results[slot]
        let status: PickStatus = {
            if let result {
                if TennisBracketEngine.normalizedName(result) == TennisBracketEngine.normalizedName(name) {
                    return .correct
                }
                return .wrong
            }
            // O(1) lookup against the pre-computed eliminated set instead
            // of an O(results) scan per pick — kept the bracket sheet from
            // freezing while it rendered 127 rows.
            if eliminated.contains(TennisBracketEngine.normalizedName(name)) {
                return .dead
            }
            return .pending
        }()

        return HStack(spacing: 4) {
            Image(systemName: status.icon)
                .font(.system(size: 10))
                .foregroundStyle(status.color)
            Text(name)
                .font(.system(size: 11))
                .foregroundStyle(status == .wrong || status == .dead ? .secondary : .primary)
                .strikethrough(status == .dead)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(status.bgColor)
        .clipShape(Capsule())
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private enum PickStatus {
        case correct, wrong, pending, dead

        var icon: String {
            switch self {
            case .correct: return "checkmark.circle.fill"
            case .wrong: return "xmark.circle.fill"
            case .pending: return "clock"
            case .dead: return "xmark.circle"
            }
        }

        var color: Color {
            switch self {
            case .correct: return .green
            case .wrong: return .red
            case .pending: return .gray
            case .dead: return .red.opacity(0.6)
            }
        }

        var bgColor: Color {
            switch self {
            case .correct: return .green.opacity(0.1)
            case .wrong: return .red.opacity(0.08)
            case .pending: return .gray.opacity(0.08)
            case .dead: return .red.opacity(0.06)
            }
        }
    }

    // MARK: - Groups Card

    private var groupsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "person.3.fill")
                    .foregroundStyle(brandPurple)
                Text("My Groups")
                    .font(.headline.weight(.bold))
                Spacer()
            }
            ForEach(viewModel.myGroups) { group in
                NavigationLink {
                    TennisBracketGroupDetailView(viewModel: viewModel, group: group)
                } label: {
                    HStack {
                        Text(group.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("View Standings")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(brandPurple)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(brandPurple.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
    }

    // MARK: - Leaderboard

    private var leaderboardSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Leaderboard")
                .font(.headline.weight(.bold))

            // Header
            HStack {
                Text("#")
                    .frame(width: 30, alignment: .leading)
                Text("Entry")
                Spacer()
                Text("Pts")
                    .frame(width: 44, alignment: .trailing)
                Text("Max")
                    .frame(width: 44, alignment: .trailing)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)

            LazyVStack(spacing: 4) {
                let visible = Array(viewModel.leaderboardEntries.prefix(visibleCount))
                ForEach(visible) { entry in
                    Button {
                        selectedEntry = entry
                    } label: {
                        leaderboardRow(entry)
                    }
                    .buttonStyle(.plain)
                }

                if viewModel.leaderboardEntries.count > visibleCount {
                    Button {
                        visibleCount += 25
                    } label: {
                        Text("Load More")
                            .font(.caption.weight(.medium))
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                    }
                }

                // Show user entry if outside visible range
                if let userEntry = viewModel.leaderboardEntries.first(where: { $0.isCurrentUser }),
                   !viewModel.leaderboardEntries.prefix(visibleCount).contains(where: { $0.isCurrentUser }) {
                    Divider()
                    leaderboardRow(userEntry)
                }
            }
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func leaderboardRow(_ entry: TennisBracketLeaderboardEntry) -> some View {
        HStack {
            Text("\(entry.rank)")
                .font(.caption.weight(.bold))
                .frame(width: 30, alignment: .leading)
            Text(entry.entryName)
                .font(.subheadline.weight(entry.isCurrentUser ? .bold : .regular))
                .foregroundStyle(entry.isCurrentUser ? brandPurple : .primary)
                .lineLimit(1)
            Spacer()
            Text(String(format: "%.0f", entry.totalPoints))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .frame(width: 44, alignment: .trailing)
            Text(String(format: "%.0f", entry.maxPossiblePoints))
                .font(.subheadline.weight(.regular).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(entry.isCurrentUser ? brandPurple.opacity(0.06) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Entry Detail Sheet

    private func entryDetailSheet(_ entry: TennisBracketLeaderboardEntry) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(entry.entryName)
                            .font(.title3.weight(.bold))
                        Spacer()
                        Text("Rank #\(entry.rank)")
                            .font(.headline)
                            .foregroundStyle(brandPurple)
                    }

                    Text(String(format: "%.0f pts", entry.totalPoints))
                        .font(.title2.weight(.bold))

                    Divider()

                    // Pre-compute the eliminated-name set once for this
                    // render. Without this every pick row re-scanned all
                    // results, which froze the UI on 127-pick sheets.
                    let eliminated = TennisBracketEngine.eliminatedPlayerNames(results: viewModel.results)

                    ForEach(0..<TennisBracketEngine.rounds.count, id: \.self) { roundIndex in
                        let round = TennisBracketEngine.rounds[roundIndex]
                        let matchCount = TennisBracketEngine.matchesPerRound[roundIndex]
                        let roundPts = entry.roundBreakdown[round] ?? 0

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(roundDisplayName(round))
                                    .font(.caption.weight(.bold))
                                Spacer()
                                Text("\(roundPts) pts")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(roundPts > 0 ? brandPurple : .secondary)
                            }

                            let picks = (1...matchCount).compactMap { matchNum -> (slot: String, name: String)? in
                                let slot = TennisBracketEngine.matchSlot(round: round, matchNumber: matchNum)
                                guard let name = entry.picks[slot] else { return nil }
                                return (slot, name)
                            }

                            ForEach(picks, id: \.slot) { pick in
                                pickStatusBadge(slot: pick.slot, name: pick.name, eliminated: eliminated)
                            }
                        }
                        if roundIndex < TennisBracketEngine.rounds.count - 1 {
                            Divider()
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("Bracket Detail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { selectedEntry = nil }
                }
            }
        }
    }

    // MARK: - Helpers

    private func roundDisplayName(_ round: String) -> String {
        switch round {
        case "R1": return "Round 1"
        case "R2": return "Round 2"
        case "R3": return "Round 3"
        case "R4": return "Round of 16"
        case "QF": return "Quarterfinals"
        case "SF": return "Semifinals"
        case "F": return "Final"
        default: return round
        }
    }
}
