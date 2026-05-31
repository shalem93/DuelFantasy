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
            // Refresh on every appearance. The bracket runs across two weeks of slams
            // and matches finish hourly — the prior cached state goes stale fast, so
            // unconditionally re-fetch when the user opens the view.
            await viewModel.refreshLive()
        }
        .refreshable {
            // Pull-to-refresh for explicit re-fetch.
            await viewModel.refreshLive()
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
                if let rank = viewModel.userRank {
                    Text("Rank #\(rank)")
                        .font(.title3.weight(.bold))
                }
            }

            HStack {
                if let pts = viewModel.userTotalPoints {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your Points")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.0f", pts))
                            .font(.title2.weight(.bold))
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Field Size")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                                        pickStatusBadge(slot: pick.slot, name: pick.name)
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

    private func pickStatusBadge(slot: String, name: String) -> some View {
        let result = viewModel.results[slot]
        let status: PickStatus = {
            guard let result else { return .pending }
            if TennisBracketEngine.normalizedName(result) == TennisBracketEngine.normalizedName(name) {
                return .correct
            }
            return .wrong
        }()

        return HStack(spacing: 4) {
            Image(systemName: status.icon)
                .font(.system(size: 10))
                .foregroundStyle(status.color)
            Text(name)
                .font(.system(size: 11))
                .foregroundStyle(status == .wrong ? .secondary : .primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(status.bgColor)
        .clipShape(Capsule())
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private enum PickStatus {
        case correct, wrong, pending

        var icon: String {
            switch self {
            case .correct: return "checkmark.circle.fill"
            case .wrong: return "xmark.circle.fill"
            case .pending: return "clock"
            }
        }

        var color: Color {
            switch self {
            case .correct: return .green
            case .wrong: return .red
            case .pending: return .gray
            }
        }

        var bgColor: Color {
            switch self {
            case .correct: return .green.opacity(0.1)
            case .wrong: return .red.opacity(0.08)
            case .pending: return .gray.opacity(0.08)
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
                    .frame(width: 50, alignment: .trailing)
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
                .font(.subheadline.weight(.semibold))
                .frame(width: 50, alignment: .trailing)
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
                                pickStatusBadge(slot: pick.slot, name: pick.name)
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
