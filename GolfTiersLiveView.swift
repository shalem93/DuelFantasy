import SwiftUI

struct GolfTiersLiveView: View {
    @Bindable var viewModel: GolfTiersViewModel
    @State private var refreshTick: Int = 0
    @State private var selectedEntry: GolfTiersLeaderboardEntry?
    @State private var visibleCount: Int = 25

    private var darkGreen: Color {
        Color(red: 0.05, green: 0.45, blue: 0.25)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                statusHeader
                if let error = viewModel.error {
                    errorBanner(error)
                }
                yourPicksCard
                leaderboardSection
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
        .navigationTitle("Golf Major Tiers")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if !viewModel.hasAttemptedLoad {
                await viewModel.loadTournament()
            } else {
                await viewModel.refreshLive()
            }
        }
        .task(id: refreshTick) {
            guard viewModel.isLive else { return }
            try? await Task.sleep(for: .seconds(300))  // 5-minute refresh
            refreshTick += 1
            await viewModel.refreshLive()
        }
        .sheet(item: $selectedEntry) { entry in
            entryDetailSheet(entry)
        }
    }

    // MARK: - Status Header

    private var statusHeader: some View {
        VStack(spacing: 14) {
            HStack {
                if viewModel.isSettled {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.white)
                        Text("FINAL")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    }
                } else if viewModel.isLive {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                        Text("LIVE")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                        if viewModel.currentRound > 0 {
                            Text("R\(viewModel.currentRound)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                } else {
                    Text("LOCKED")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                }

                Spacer()

                Text(viewModel.tournament?.title ?? "Golf Major Tiers")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))
            }

            // User rank and score
            HStack(spacing: 24) {
                VStack(spacing: 2) {
                    Text("YOUR RANK")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    if let rank = viewModel.userRank {
                        Text("#\(rank)")
                            .font(.title.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                    } else {
                        Text("--")
                            .font(.title.weight(.bold))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }

                VStack(spacing: 2) {
                    Text("SCORE")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    Text(viewModel.userTotalScoreDisplay)
                        .font(.title.weight(.bold).monospacedDigit())
                        .foregroundStyle(scoreColor(viewModel.userTotalScore))
                }

                Spacer()

                VStack(spacing: 2) {
                    Text("FIELD")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    if viewModel.hasLiveData {
                        Text("\(viewModel.leaderboardEntries.count)")
                            .font(.title3.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                    } else {
                        Text("--")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
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

    // MARK: - Your Picks Card

    private var yourPicksCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("YOUR PICKS")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Best 4 of 6 count")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            // Determine which picks are counting for the user
            let userLeaderboardEntry = viewModel.leaderboardEntries.first(where: { $0.isCurrentUser })
            let countingPickIDs = userLeaderboardEntry?.countingPicks ?? Set<String>()
            let hasCountingData = userLeaderboardEntry != nil && !countingPickIDs.isEmpty

            ForEach(1...6, id: \.self) { tier in
                if let golfer = viewModel.userPicks[tier] {
                    let isCounting = !hasCountingData || countingPickIDs.contains(golfer.id)
                    pickRow(tier: tier, golfer: golfer, isCounting: isCounting)
                } else {
                    emptyPickRow(tier: tier)
                }
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
    }

    private func pickRow(tier: Int, golfer: GolfTiersGolfer, isCounting: Bool) -> some View {
        let score = viewModel.liveGolferScores[golfer.id] ?? golfer.scoreToPar
        let rounds = viewModel.liveGolferRounds[golfer.id] ?? golfer.roundScores
        let status = viewModel.liveGolferStatuses[golfer.id] ?? golfer.status
        let effectiveScore = GolfTiersEngine.effectiveScoreToPar(
            golferScoreToPar: score, roundScores: rounds, status: status
        )

        return HStack(spacing: 10) {
            // Tier badge
            Text("T\(tier)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tierColor(tier))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            // Golfer headshot
            if let imageURL = golfer.imageURL, let url = URL(string: imageURL) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 32, height: 32)
                .clipShape(Circle())
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
            }

            // Golfer info
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(golfer.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isCounting ? .primary : .secondary)
                        .lineLimit(1)
                    if status == .cut {
                        Text("MC")
                            .font(.system(size: 8, weight: .heavy))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.red.opacity(0.15))
                            .foregroundStyle(.red)
                            .clipShape(Capsule())
                    } else if status == .withdrawn {
                        Text("WD")
                            .font(.system(size: 8, weight: .heavy))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    }
                    if !isCounting {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary.opacity(0.5))
                    }
                }
                // Round scores
                HStack(spacing: 4) {
                    ForEach(Array(rounds.enumerated()), id: \.offset) { idx, roundScore in
                        Text(roundScore > 0 ? "\(roundScore)" : "-")
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if rounds.count < 4 {
                        ForEach(rounds.count..<4, id: \.self) { _ in
                            Text("-")
                                .font(.system(size: 10, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary.opacity(0.4))
                        }
                    }
                }
            }

            Spacer()

            // Score-to-par
            VStack(alignment: .trailing, spacing: 1) {
                Text(GolfTiersEngine.scoreToParDisplay(effectiveScore))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(isCounting ? scoreTextColor(effectiveScore) : .secondary)
                if isCounting {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(darkGreen)
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(isCounting ? 1.0 : 0.5)
    }

    private func emptyPickRow(tier: Int) -> some View {
        HStack(spacing: 10) {
            Text("T\(tier)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color(.systemGray4))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            Text("No pick")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Leaderboard

    private var leaderboardSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("LEADERBOARD")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)

                Spacer()

                if viewModel.hasLiveData {
                    Text("\(viewModel.leaderboardEntries.count) entries")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if viewModel.hasLiveData {
                VStack(spacing: 0) {
                    // Header row
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

                    // Visible entries
                    let visibleEntries = Array(viewModel.leaderboardEntries.prefix(visibleCount))
                    ForEach(visibleEntries) { entry in
                        Button { selectedEntry = entry } label: {
                            leaderboardRow(entry)
                        }
                        .buttonStyle(.plain)
                        if entry.id != visibleEntries.last?.id {
                            Divider().padding(.leading, 42)
                        }
                    }

                    // Load More
                    let totalEntries = viewModel.leaderboardEntries.count
                    if visibleCount < totalEntries {
                        Divider()
                        Button {
                            Haptics.light()
                            withAnimation(.easeInOut(duration: 0.2)) {
                                visibleCount = min(visibleCount + 50, totalEntries)
                            }
                        } label: {
                            Text("Load More (\(totalEntries - visibleCount) remaining)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(darkGreen)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                    }

                    // User entry if not in visible range
                    if let userEntry = viewModel.leaderboardEntries.first(where: { $0.isCurrentUser }),
                       userEntry.rank > visibleCount {
                        Divider()
                        HStack {
                            Text("...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                        }
                        .padding(.vertical, 4)
                        Divider()
                        Button { selectedEntry = userEntry } label: {
                            leaderboardRow(userEntry)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.secondary)
                    Text("Loading standings...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
            }
        }
    }

    private func leaderboardRow(_ entry: GolfTiersLeaderboardEntry) -> some View {
        HStack {
            Text("\(entry.rank)")
                .font(.subheadline.weight(.medium).monospacedDigit())
                .foregroundStyle(entry.rank <= 3 ? Color(red: 0.95, green: 0.78, blue: 0.20) : .secondary)
                .frame(width: 30, alignment: .leading)

            HStack(spacing: 4) {
                if entry.isCurrentUser {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(darkGreen)
                }
                Text(entry.entryName)
                    .font(.subheadline.weight(entry.isCurrentUser ? .bold : .regular))
                    .foregroundStyle(entry.isCurrentUser ? darkGreen : .primary)
                    .lineLimit(1)
            }

            Spacer()

            Text(GolfTiersEngine.scoreToParDisplay(entry.totalScore))
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(scoreTextColor(entry.totalScore))
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(entry.isCurrentUser ? darkGreen.opacity(0.06) : .clear)
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Entry Detail Sheet

    private func entryDetailSheet(_ entry: GolfTiersLeaderboardEntry) -> some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Rank & Score header
                    HStack(spacing: 24) {
                        VStack(spacing: 2) {
                            Text("RANK")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text("#\(entry.rank)")
                                .font(.title2.weight(.bold).monospacedDigit())
                        }
                        VStack(spacing: 2) {
                            Text("SCORE")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(GolfTiersEngine.scoreToParDisplay(entry.totalScore))
                                .font(.title2.weight(.bold).monospacedDigit())
                                .foregroundStyle(scoreTextColor(entry.totalScore))
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)

                    // Picks list
                    VStack(spacing: 0) {
                        ForEach(entry.picks.sorted(by: { $0.tier < $1.tier }), id: \.tier) { pick in
                            let pickScore = entry.pickScores[pick.playerID] ?? viewModel.liveGolferScores[pick.playerID] ?? 0
                            let isCounting = entry.countingPicks.contains(pick.playerID)
                            let golferStatus = viewModel.liveGolferStatuses[pick.playerID] ?? .active
                            let rounds = viewModel.liveGolferRounds[pick.playerID] ?? []

                            HStack(spacing: 10) {
                                Text("T\(pick.tier)")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 28, height: 28)
                                    .background(tierColor(pick.tier))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))

                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 4) {
                                        Text(pick.playerName)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(isCounting ? .primary : .secondary)
                                            .lineLimit(1)
                                        if golferStatus == .cut {
                                            Text("MC")
                                                .font(.system(size: 8, weight: .heavy))
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(Color.red.opacity(0.15))
                                                .foregroundStyle(.red)
                                                .clipShape(Capsule())
                                        } else if golferStatus == .withdrawn {
                                            Text("WD")
                                                .font(.system(size: 8, weight: .heavy))
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(Color.orange.opacity(0.15))
                                                .foregroundStyle(.orange)
                                                .clipShape(Capsule())
                                        }
                                        if isCounting {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 10))
                                                .foregroundStyle(darkGreen)
                                        }
                                    }
                                    HStack(spacing: 4) {
                                        Text(pick.playerCountry)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        ForEach(Array(rounds.enumerated()), id: \.offset) { _, roundScore in
                                            Text(roundScore > 0 ? "\(roundScore)" : "-")
                                                .font(.system(size: 10, weight: .medium).monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: 1) {
                                    Text(GolfTiersEngine.scoreToParDisplay(pickScore))
                                        .font(.subheadline.weight(.bold).monospacedDigit())
                                        .foregroundStyle(isCounting ? scoreTextColor(pickScore) : .secondary)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .opacity(isCounting ? 1.0 : 0.5)

                            if pick.tier < 6 {
                                Divider().padding(.leading, 54)
                            }
                        }
                    }
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
                    .padding(.horizontal, 16)
                }
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
            .navigationTitle(entry.entryName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { selectedEntry = nil }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Helpers

    private func tierColor(_ tier: Int) -> Color {
        switch tier {
        case 1: return Color(red: 0.85, green: 0.65, blue: 0.13)  // Gold
        case 2: return Color(red: 0.60, green: 0.60, blue: 0.65)  // Silver
        case 3: return Color(red: 0.70, green: 0.45, blue: 0.20)  // Bronze
        case 4: return Color(red: 0.30, green: 0.50, blue: 0.75)  // Blue
        case 5: return Color(red: 0.45, green: 0.65, blue: 0.45)  // Green
        case 6: return Color(red: 0.55, green: 0.45, blue: 0.65)  // Purple
        default: return .secondary
        }
    }

    private func scoreTextColor(_ score: Int) -> Color {
        if score < 0 { return Color(red: 0.85, green: 0.15, blue: 0.15) }  // Under par = red (good in golf)
        if score == 0 { return .primary }  // Even = neutral
        return .primary  // Over par = normal
    }

    private func scoreColor(_ score: Int?) -> Color {
        guard let score else { return .white.opacity(0.5) }
        if score < 0 { return Color(red: 0.85, green: 0.15, blue: 0.15) }
        return .white
    }
}

