import SwiftUI

struct GolfTiersSettledDetailView: View {
    @Bindable var viewModel: GolfTiersViewModel
    let tournamentRecord: GolfTiersTournamentRecord

    @State private var entries: [GolfTiersEntryRecord] = []
    @State private var userResult: DFSTournamentResultRecord?
    @State private var isLoading = true
    @State private var visibleCount = 25

    private var darkGreen: Color {
        Color(red: 0.05, green: 0.45, blue: 0.25)
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
                ForEach(sortedPicks, id: \.tier) { pick in
                    pickRow(pick: pick, tier: pick.tier)
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

    private func pickRow(pick: GolfTiersPickData, tier: Int) -> some View {
        HStack(spacing: 10) {
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
                        leaderboardRow(entry, displayRank: entry.rank > 0 ? entry.rank : index + 1)
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
                        leaderboardRow(user, displayRank: user.rank > 0 ? user.rank : sorted.count)
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
