import SwiftUI

struct UserProfileView: View {
    let profile: LeaderboardProfile
    let accessToken: String

    @EnvironmentObject private var auth: AuthViewModel
    @State private var settledPicks: [SettledPickRecord] = []
    @State private var activePicks: [ActivePickRecord] = []
    @State private var dfsResults: [DFSTournamentResultRecord] = []
    @State private var dfsTournaments: [String: DFSTournamentRecord] = [:]
    @State private var isLoading: Bool = true

    private var brandPurple: Color {
        Color(red: 0.48, green: 0.23, blue: 0.93)
    }

    private var appBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.94, green: 0.98, blue: 0.95),
                Color(red: 0.95, green: 0.97, blue: 1.00),
                Color(red: 0.98, green: 0.99, blue: 1.00)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var winRate: Int {
        let total = profile.wins + profile.losses
        guard total > 0 else { return 0 }
        return Int((Double(profile.wins) / Double(total)) * 100.0)
    }

    private var streakText: String {
        guard !settledPicks.isEmpty else { return "-" }
        let firstResult = settledPicks.first!.rrDelta >= 0
        var count = 0
        for pick in settledPicks {
            if (pick.rrDelta >= 0) == firstResult {
                count += 1
            } else {
                break
            }
        }
        return "\(firstResult ? "W" : "L")\(count)"
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 16) {
                // Profile hero
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(brandPurple)
                            .frame(width: 72, height: 72)
                        Text(String(profile.username.prefix(1)).uppercased())
                            .font(.title.weight(.bold))
                            .foregroundStyle(.white)
                    }

                    Text(profile.username)
                        .font(.title2.weight(.bold))

                    HStack(spacing: 6) {
                        Image(systemName: "trophy.fill")
                            .foregroundStyle(.yellow)
                        Text("\(profile.rrScore) RR")
                            .font(.headline.monospacedDigit())
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))
                    .clipShape(Capsule())

                    // Message button — only shown for other users
                    if let currentUserID = auth.userID, currentUserID != profile.id {
                        let dmID = SupabaseService.dmConversationID(userA: currentUserID, userB: profile.id)
                        NavigationLink {
                            ChatRoomView(leagueId: dmID, title: profile.username)
                        } label: {
                            Label("Message", systemImage: "bubble.left.fill")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 20)
                                .padding(.vertical, 8)
                                .background(brandPurple)
                                .foregroundStyle(.white)
                                .clipShape(Capsule())
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(24)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.06), radius: 8, y: 4)

                // Stats grid
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    statCard(title: "Record", value: "\(profile.wins)-\(profile.losses)", icon: "chart.bar.fill", color: .blue)
                    statCard(title: "Win Rate", value: "\(winRate)%", icon: "percent", color: .purple)
                    statCard(title: "Streak", value: streakText, icon: "flame.fill", color: .orange)
                }

                // Analytics
                NavigationLink {
                    AnalyticsView(userID: profile.id, accessToken: accessToken)
                } label: {
                    HStack {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .foregroundStyle(brandPurple)
                        Text("Analytics")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(16)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
                }

                // Active picks
                if isLoading {
                    ProgressView()
                        .padding(.vertical, 20)
                } else {
                    if !activePicks.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Active Picks")
                                .font(.headline)

                            ForEach(activePicks) { pick in
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(.orange)
                                        .frame(width: 6, height: 6)
                                    Text(Self.cleanMatchName(pick.matchName))
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(pick.pickedTeam)
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(brandPurple.opacity(0.15))
                                        .foregroundStyle(brandPurple)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                        .padding(16)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
                    }

                    // Recent results
                    if !settledPicks.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Recent Results")
                                .font(.headline)

                            ForEach(settledPicks.prefix(20)) { pick in
                                HStack {
                                    Image(systemName: pick.result == "win" ? "checkmark.circle.fill" : pick.result == "expired" ? "clock.fill" : "xmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(pick.result == "win" ? .green : pick.result == "expired" ? .secondary : .red)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(Self.cleanMatchName(pick.matchName))
                                            .font(.subheadline)
                                            .lineLimit(1)
                                        Text("Picked \(pick.pickedTeam)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Text("\(pick.rrDelta >= 0 ? "+" : "")\(pick.rrDelta)")
                                        .font(.subheadline.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(pick.rrDelta >= 0 ? .green : .red)
                                }
                                .padding(.vertical, 2)
                            }

                            if settledPicks.count > 3 {
                                NavigationLink {
                                    AnalyticsView(userID: profile.id, accessToken: accessToken)
                                } label: {
                                    Text("See All Picks")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(brandPurple)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                }
                            }
                        }
                        .padding(16)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
                    }

                    // DFS Results
                    if !dfsResults.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Fantasy Results")
                                .font(.headline)

                            ForEach(dfsResults.prefix(20)) { result in
                                let sport = dfsResultSport(result.tournamentID)
                                let tournament = dfsTournaments[result.tournamentID]
                                let totalEntries = tournament?.totalEntries ?? 500
                                let title = tournament?.title
                                let date = result.createdAt ?? tournament?.lockTime

                                HStack {
                                    Image(systemName: dfsResultIcon(sport))
                                        .font(.caption)
                                        .foregroundStyle(dfsResultColor(sport))
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 4) {
                                            Text(sport)
                                                .font(.system(size: 9, weight: .bold))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(dfsResultColor(sport).opacity(0.15))
                                                .foregroundStyle(dfsResultColor(sport))
                                                .clipShape(Capsule())
                                            if let title {
                                                Text(title)
                                                    .font(.caption.weight(.medium))
                                                    .lineLimit(1)
                                            }
                                        }
                                        HStack(spacing: 4) {
                                            Text("#\(result.rank)/\(totalEntries)")
                                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                            Text("•")
                                                .foregroundStyle(.tertiary)
                                            Text(String(format: "%.1f pts", result.totalPoints))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        if let date {
                                            Text(date.formatted(date: .abbreviated, time: .omitted))
                                                .font(.system(size: 10))
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    Spacer()
                                    Text("\(result.rrDelta >= 0 ? "+" : "")\(result.rrDelta)")
                                        .font(.subheadline.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(result.rrDelta >= 0 ? .green : .red)
                                }
                                .padding(.vertical, 2)
                            }

                            if dfsResults.count > 3 {
                                NavigationLink {
                                    AnalyticsView(userID: profile.id, accessToken: accessToken, initialTab: 1)
                                } label: {
                                    Text("See All Fantasy Results")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(brandPurple)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                }
                            }
                        }
                        .padding(16)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
                    }

                    if activePicks.isEmpty && settledPicks.isEmpty && dfsResults.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "sportscourt")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text("No pick history")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(appBackground.ignoresSafeArea())
        .navigationTitle(profile.username)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadUserPicks()
        }
        .refreshable {
            await loadUserPicks()
        }
    }

    private func statCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text(value)
                .font(.title2.weight(.bold).monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    private func dfsResultSport(_ tournamentID: String) -> String {
        if tournamentID.hasPrefix("nba-playoffs") { return "NBA Tiers" }
        if tournamentID.hasPrefix("nba-") { return "NBA" }
        if tournamentID.hasPrefix("ncaam-") { return "NCAAM" }
        if tournamentID.hasPrefix("mlb-") { return "MLB" }
        if tournamentID.contains("masters") || tournamentID.contains("pga-championship")
            || tournamentID.contains("us-open") || tournamentID.contains("the-open") { return "Golf Tiers" }
        if tournamentID.hasPrefix("pga-") { return "PGA" }
        if tournamentID.contains("french-open") || tournamentID.contains("wimbledon")
            || tournamentID.contains("us-open-tennis") || tournamentID.contains("australian-open")
            || tournamentID.contains("tennis") { return "Tennis" }
        if tournamentID.hasPrefix("epl-") || tournamentID.hasPrefix("soccer-") { return "Soccer" }
        return "DFS"
    }

    private func dfsResultIcon(_ sport: String) -> String {
        switch sport {
        case "NBA", "NCAAM", "NBA Tiers": return "basketball.fill"
        case "MLB": return "baseball.fill"
        case "PGA", "Golf Tiers": return "figure.golf"
        case "Tennis": return "tennisball.fill"
        case "Soccer": return "soccerball"
        default: return "trophy.fill"
        }
    }

    private func dfsResultColor(_ sport: String) -> Color {
        switch sport {
        case "NBA": return .orange
        case "NBA Tiers": return .orange
        case "NCAAM": return .blue
        case "MLB": return .red
        case "PGA", "Golf Tiers": return .green
        case "Tennis": return .yellow
        case "Soccer": return .mint
        default: return brandPurple
        }
    }

    /// Cleans up matchName if it's a raw ID (odds- or espn-) instead of a display name.
    static func cleanMatchName(_ name: String) -> String {
        if name.hasPrefix("odds-") || name.hasPrefix("espn-") {
            return "Pending Match"
        }
        return name
    }

    private func loadUserPicks() async {
        isLoading = true
        async let fetchedSettled = SupabaseService.shared.fetchSettledPicks(
            userID: profile.id, limit: 50, accessToken: accessToken
        )
        async let fetchedActive = SupabaseService.shared.fetchActivePicks(
            userID: profile.id, accessToken: accessToken
        )
        async let fetchedDFS = SupabaseService.shared.fetchUserDFSHistory(
            userID: profile.id, accessToken: accessToken
        )
        async let fetchedTournaments = SupabaseService.shared.fetchRecentTournaments(
            accessToken: accessToken
        )
        do {
            let (settled, active, dfs, tournaments) = try await (fetchedSettled, fetchedActive, fetchedDFS, fetchedTournaments)
            settledPicks = settled
            // Filter out stale active picks older than 7 days — these are unsettleable
            // (the ESPN lookback is 7 days, so they'll never resolve).
            let staleThreshold: TimeInterval = 7 * 24 * 3600
            let now = Date()
            activePicks = active.filter { pick in
                guard let createdAt = pick.createdAt else { return false }
                return now.timeIntervalSince(createdAt) < staleThreshold
            }
            dfsResults = dfs
            dfsTournaments = Dictionary(uniqueKeysWithValues: tournaments.map { ($0.id, $0) })
        } catch {
            print("[UserProfile] Failed to load picks: \(error.localizedDescription)")
        }
        isLoading = false
    }
}
