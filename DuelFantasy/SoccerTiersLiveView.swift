import SwiftUI

struct SoccerTiersLiveView: View {
    @Bindable var viewModel: SoccerTiersViewModel
    @State private var refreshTick: Int = 0
    @State private var selectedEntry: SoccerTiersLeaderboardEntry?
    @State private var visibleCount: Int = 25

    private var brandPurple: Color {
        Color(red: 0.48, green: 0.23, blue: 0.93)
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
                    Color(red: 0.93, green: 0.98, blue: 0.93),
                    Color(red: 0.95, green: 0.97, blue: 1.00),
                    Color(red: 0.98, green: 0.99, blue: 1.00)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        .navigationTitle("World Cup Tiers")
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
            try? await Task.sleep(for: .seconds(60))
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
                    }
                } else if viewModel.livePlayerPoints.isEmpty {
                    // Locked but nothing has scored yet — the tournament
                    // hasn't kicked off. "LOCKED · #1 · 0.0" read like it
                    // already started.
                    HStack(spacing: 6) {
                        Image(systemName: "clock.fill")
                            .font(.caption)
                            .foregroundStyle(.white)
                        Text("KICKS OFF SOON")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    }
                } else {
                    Text("LOCKED")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                }

                Spacer()

                Text(viewModel.tournament?.title ?? "FIFA World Cup 2026 Tiers")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))
            }

            // User rank and points. Rank/score are meaningless before any
            // match has been scored (everyone is tied at 0.0) — show dashes
            // until real points exist.
            HStack(spacing: 24) {
                VStack(spacing: 2) {
                    Text("YOUR RANK")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    if let rank = viewModel.userRank, !viewModel.livePlayerPoints.isEmpty {
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
                    Text("TOTAL FPTS")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    if let points = viewModel.userTotalPoints, !viewModel.livePlayerPoints.isEmpty {
                        Text(String(format: "%.1f", points))
                            .font(.title.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                    } else {
                        Text("--")
                            .font(.title.weight(.bold))
                            .foregroundStyle(.white.opacity(0.5))
                    }
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
                colors: [Color(red: 0.05, green: 0.35, blue: 0.15), Color(red: 0.10, green: 0.50, blue: 0.25)],
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
            Text("YOUR PICKS")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            ForEach(1...6, id: \.self) { tier in
                if let player = viewModel.userPicks[tier] {
                    pickRow(tier: tier, player: player)
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

    private func pickRow(tier: Int, player: SoccerTiersPlayer) -> some View {
        let points = viewModel.livePlayerPoints[player.id] ?? 0
        let isEliminated = viewModel.eliminatedNations.contains(player.countryCode)

        return HStack(spacing: 10) {
            // Tier badge
            Text("T\(tier)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tierColor(tier))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            // Player headshot
            if let imageURL = player.imageURL, let url = URL(string: imageURL) {
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

            // Player info
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(player.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isEliminated ? .secondary : .primary)
                        .lineLimit(1)
                    if isEliminated {
                        Text("ELIM")
                            .font(.system(size: 8, weight: .heavy))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.red.opacity(0.15))
                            .foregroundStyle(.red)
                            .clipShape(Capsule())
                    }
                }
                Text("\(player.countryCode) \u{00B7} \(player.position)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Fantasy points
            VStack(alignment: .trailing, spacing: 1) {
                Text(String(format: "%.1f", points))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(isEliminated ? .secondary : .primary)
                Text("FPTS")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
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
                        Text("FPTS")
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

                    // Load More button
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
                                .foregroundStyle(brandPurple)
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

    private func leaderboardRow(_ entry: SoccerTiersLeaderboardEntry) -> some View {
        HStack {
            Text("\(entry.rank)")
                .font(.subheadline.weight(.medium).monospacedDigit())
                .foregroundStyle(entry.rank <= 3 ? Color(red: 0.95, green: 0.78, blue: 0.20) : .secondary)
                .frame(width: 30, alignment: .leading)

            HStack(spacing: 4) {
                if entry.isCurrentUser {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(brandPurple)
                }
                Text(entry.entryName)
                    .font(.subheadline.weight(entry.isCurrentUser ? .bold : .regular))
                    .foregroundStyle(entry.isCurrentUser ? brandPurple : .primary)
                    .lineLimit(1)
            }

            Spacer()

            Text(String(format: "%.1f", entry.totalPoints))
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(.primary)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(entry.isCurrentUser ? brandPurple.opacity(0.06) : .clear)
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

    private func entryDetailSheet(_ entry: SoccerTiersLeaderboardEntry) -> some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Rank & Points header
                    HStack(spacing: 24) {
                        VStack(spacing: 2) {
                            Text("RANK")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text("#\(entry.rank)")
                                .font(.title2.weight(.bold).monospacedDigit())
                        }
                        VStack(spacing: 2) {
                            Text("TOTAL FPTS")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.1f", entry.totalPoints))
                                .font(.title2.weight(.bold).monospacedDigit())
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)

                    // Picks list
                    VStack(spacing: 0) {
                        ForEach(entry.picks.sorted(by: { $0.tier < $1.tier }), id: \.tier) { pick in
                            let pts = entry.playerPoints[pick.playerID] ?? viewModel.livePlayerPoints[pick.playerID] ?? 0
                            let isEliminated = viewModel.eliminatedNations.contains(pick.playerCountry)
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
                                            .foregroundStyle(isEliminated ? .secondary : .primary)
                                            .lineLimit(1)
                                        if isEliminated {
                                            Text("ELIM")
                                                .font(.system(size: 8, weight: .heavy))
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(Color.red.opacity(0.15))
                                                .foregroundStyle(.red)
                                                .clipShape(Capsule())
                                        }
                                    }
                                    Text("\(pick.playerCountry) \u{00B7} \(positionForPlayer(pick.playerID))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: 1) {
                                    Text(String(format: "%.1f", pts))
                                        .font(.subheadline.weight(.bold).monospacedDigit())
                                        .foregroundStyle(isEliminated ? .secondary : .primary)
                                    Text("FPTS")
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)

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
                        Color(red: 0.93, green: 0.98, blue: 0.93),
                        Color(red: 0.95, green: 0.97, blue: 1.00),
                        Color(red: 0.98, green: 0.99, blue: 1.00)
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

    /// Look up a player's position from the tier data by player ID
    private func positionForPlayer(_ playerID: String) -> String {
        for tier in viewModel.tiers {
            if let player = tier.first(where: { $0.id == playerID }) {
                return player.position
            }
        }
        return ""
    }
}
