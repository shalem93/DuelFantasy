import SwiftUI

struct BestBallContestView: View {
    @Bindable var viewModel: BestBallViewModel
    @EnvironmentObject private var auth: AuthViewModel
    @State private var selectedTab: BBTab = .browse

    private enum BBTab: String, CaseIterable {
        case browse = "Browse"
        case myLeagues = "My Leagues"
    }

    private var brandPurple: Color {
        Color(red: 0.48, green: 0.23, blue: 0.93)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab selector
            HStack(spacing: 0) {
                ForEach(BBTab.allCases, id: \.self) { tab in
                    Button {
                        Haptics.light()
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedTab = tab
                        }
                    } label: {
                        VStack(spacing: 6) {
                            Text(tab.rawValue)
                                .font(.subheadline.weight(selectedTab == tab ? .bold : .medium))
                                .foregroundStyle(selectedTab == tab ? brandPurple : .secondary)
                            Rectangle()
                                .fill(selectedTab == tab ? brandPurple : .clear)
                                .frame(height: 2)
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)

            Group {
                if selectedTab == .browse {
                    BestBallBrowseView(viewModel: viewModel)
                } else {
                    myLeaguesContent
                }
            }
        }
        .navigationTitle("Best Ball")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.light()
                    Task {
                        await viewModel.loadOpenLeagues()
                        await viewModel.loadMyLeagues()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .task {
            await viewModel.loadOpenLeagues()
            await viewModel.loadMyLeagues()
        }
    }

    // MARK: - My Leagues

    private var myLeaguesContent: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if viewModel.myLeagues.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "trophy")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No leagues yet")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("Browse open leagues or create your own")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, 60)
                } else {
                    ForEach(viewModel.myLeagues) { league in
                        NavigationLink {
                            BestBallLeagueDetailView(viewModel: viewModel, leagueID: league.id)
                        } label: {
                            leagueCard(league)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
    }

    private func leagueCard(_ league: BestBallLeague) -> some View {
        let isWinner = viewModel.wonLeagueIDs.contains(league.id)
        let preview = viewModel.leagueMatchupPreviews[league.id]
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                if isWinner {
                    Image(systemName: "trophy.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color(red: 0.95, green: 0.78, blue: 0.20))
                }
                Text(league.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if league.isDingersOnly {
                    Text("HR")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.15))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
                if isWinner {
                    Text("Champion")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(red: 0.95, green: 0.78, blue: 0.20).opacity(0.15))
                        .foregroundStyle(Color(red: 0.85, green: 0.65, blue: 0.10))
                        .clipShape(Capsule())
                } else {
                    statusBadge(league.status)
                }
            }
            HStack(spacing: 12) {
                Label(league.sport, systemImage: sportIcon(league.sport))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(league.season, systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if league.isDingersOnly {
                    Text("Dingers Only")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if league.status == "active" || league.status == "completed" {
                    Text("Week \(league.currentWeek)/\(league.totalWeeks)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Live matchup scoreboard for active H2H leagues
            if let preview, league.status == "active" {
                Divider()
                matchupPreviewRow(preview)
            }
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    private func matchupPreviewRow(_ preview: LeagueMatchupPreview) -> some View {
        HStack(spacing: 0) {
            // My team
            VStack(spacing: 2) {
                Text(preview.myName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(String(format: "%.1f", preview.myScore))
                    .font(.system(size: 22, weight: .bold).monospacedDigit())
                    .foregroundStyle(preview.myScore >= preview.opponentScore ? brandPurple : .primary)
                Text("\(preview.myGamesPlayed) games")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)

            // VS divider
            VStack(spacing: 2) {
                if preview.myScore > preview.opponentScore {
                    Image(systemName: "arrowtriangle.left.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(brandPurple)
                } else if preview.opponentScore > preview.myScore {
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(brandPurple)
                }
                Text("vs")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.quaternary)
            }

            // Opponent
            VStack(spacing: 2) {
                Text(preview.opponentName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(String(format: "%.1f", preview.opponentScore))
                    .font(.system(size: 22, weight: .bold).monospacedDigit())
                    .foregroundStyle(preview.opponentScore > preview.myScore ? brandPurple : .primary)
                Text("\(preview.opponentGamesPlayed) games")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 6)
    }

    private func statusBadge(_ status: String) -> some View {
        Text(status.capitalized)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(statusColor(status).opacity(0.15))
            .foregroundStyle(statusColor(status))
            .clipShape(Capsule())
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "open": return .blue
        case "drafting": return .orange
        case "active": return brandPurple
        case "completed": return .secondary
        default: return .secondary
        }
    }

    func sportIcon(_ sport: String) -> String {
        switch sport {
        case "NBA": return "basketball"
        case "MLB": return "baseball"
        case "NFL": return "football"
        default: return "sportscourt"
        }
    }
}
