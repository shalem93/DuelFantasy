import SwiftUI

struct FullHistoryView: View {
    let userID: String
    let accessToken: String
    let profileName: String
    var initialTab: Int = 0

    @State private var selectedTab: Int = 0
    @State private var settledPicks: [SettledPickRecord] = []
    @State private var dfsResults: [DFSTournamentResultRecord] = []
    @State private var dfsTournaments: [String: DFSTournamentRecord] = [:]
    @State private var picksOffset: Int = 0
    @State private var dfsOffset: Int = 0
    @State private var hasMorePicks: Bool = true
    @State private var hasMoreDFS: Bool = true
    @State private var isLoadingPicks: Bool = false
    @State private var isLoadingDFS: Bool = false
    @State private var isInitialLoad: Bool = true

    private let pageSize = 50

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

    var body: some View {
        VStack(spacing: 0) {
            Picker("Category", selection: $selectedTab) {
                Text("Pick'em").tag(0)
                Text("DFS").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if isInitialLoad {
                Spacer()
                ProgressView()
                Spacer()
            } else if selectedTab == 0 {
                pickemList
            } else {
                dfsList
            }
        }
        .background(appBackground.ignoresSafeArea())
        .navigationTitle("\(profileName.isEmpty ? "Player" : profileName)'s History")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { selectedTab = initialTab }
        .task {
            await loadInitialData()
        }
    }

    // MARK: - Pick'em List

    private var pickemList: some View {
        Group {
            if settledPicks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sportscourt")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No settled picks")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(settledPicks.enumerated()), id: \.element.id) { index, pick in
                            pickRow(pick)
                            if index < settledPicks.count - 1 {
                                Divider()
                                    .padding(.horizontal, 16)
                            }
                        }

                        if hasMorePicks {
                            Button {
                                Task { await loadMorePicks() }
                            } label: {
                                if isLoadingPicks {
                                    ProgressView()
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 16)
                                } else {
                                    Text("Load More")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(brandPurple)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 16)
                                }
                            }
                            .disabled(isLoadingPicks)
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private func pickRow(_ pick: SettledPickRecord) -> some View {
        HStack {
            Image(systemName: pick.result == "win" ? "checkmark.circle.fill" : (pick.result == "expired" ? "clock.fill" : "xmark.circle.fill"))
                .font(.caption)
                .foregroundStyle(pick.result == "win" ? brandPurple : (pick.result == "expired" ? .secondary : .red))
            VStack(alignment: .leading, spacing: 1) {
                Text(pick.matchName)
                    .font(.subheadline)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text("Picked \(pick.pickedTeam)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let date = pick.createdAt ?? pick.settledAt {
                        Text("•")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            Text("\(pick.rrDelta >= 0 ? "+" : "")\(pick.rrDelta)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(pick.rrDelta >= 0 ? .green : .red)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - DFS List

    private var dfsList: some View {
        Group {
            if dfsResults.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.3")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No DFS results")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        HStack {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text("Most Recent")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(dfsResults.count)\(hasMoreDFS ? "+" : "") results")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)

                        ForEach(Array(dfsResults.enumerated()), id: \.element.id) { index, result in
                            dfsRow(result)
                            if index < dfsResults.count - 1 {
                                Divider()
                                    .padding(.horizontal, 16)
                            }
                        }

                        if hasMoreDFS {
                            Button {
                                Task { await loadMoreDFS() }
                            } label: {
                                if isLoadingDFS {
                                    ProgressView()
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 16)
                                } else {
                                    Text("Load More")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(brandPurple)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 16)
                                }
                            }
                            .disabled(isLoadingDFS)
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private func dfsRow(_ result: DFSTournamentResultRecord) -> some View {
        let sport = dfsResultSport(result.tournamentID)
        let tournament = dfsTournaments[result.tournamentID]
        let totalEntries = tournament?.totalEntries ?? 1000
        let title = tournament?.title
        let date = result.createdAt ?? tournament?.lockTime ?? dateFromTournamentID(result.tournamentID)

        return HStack {
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
                    if let date {
                        Text("•")
                            .foregroundStyle(.tertiary)
                        Text(date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Text("\(result.rrDelta >= 0 ? "+" : "")\(result.rrDelta)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(result.rrDelta >= 0 ? .green : .red)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// Extract date from tournament ID patterns like "nba-2025-04-15" or "mlb-2025-04-15"
    private func dateFromTournamentID(_ tournamentID: String) -> Date? {
        let parts = tournamentID.split(separator: "-")
        // Expected: prefix-YYYY-MM-DD (4 parts)
        guard parts.count >= 4,
              let year = Int(parts[1]), let month = Int(parts[2]), let day = Int(parts[3]) else {
            return nil
        }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return Calendar.current.date(from: components)
    }

    // MARK: - Data Loading

    private func loadInitialData() async {
        isInitialLoad = true
        async let picksTask: () = loadMorePicks()
        async let dfsTask: () = loadMoreDFS()
        async let tournamentsTask = SupabaseService.shared.fetchRecentTournaments(accessToken: accessToken)
        _ = await (picksTask, dfsTask)
        if let tournaments = try? await tournamentsTask {
            dfsTournaments = Dictionary(uniqueKeysWithValues: tournaments.map { ($0.id, $0) })
        }
        isInitialLoad = false
    }

    private func loadMorePicks() async {
        guard !isLoadingPicks else { return }
        isLoadingPicks = true
        do {
            let fetched = try await SupabaseService.shared.fetchSettledPicks(
                userID: userID, limit: pageSize, offset: picksOffset, accessToken: accessToken
            )
            settledPicks.append(contentsOf: fetched)
            picksOffset += fetched.count
            if fetched.count < pageSize {
                hasMorePicks = false
            }
        } catch {
            print("[FullHistory] Failed to load picks: \(error.localizedDescription)")
        }
        isLoadingPicks = false
    }

    private func loadMoreDFS() async {
        guard !isLoadingDFS else { return }
        isLoadingDFS = true
        do {
            let fetched = try await SupabaseService.shared.fetchUserDFSHistory(
                userID: userID, limit: pageSize, offset: dfsOffset, accessToken: accessToken
            )
            dfsResults.append(contentsOf: fetched)
            dfsOffset += fetched.count
            if fetched.count < pageSize {
                hasMoreDFS = false
            }
        } catch {
            print("[FullHistory] Failed to load DFS history: \(error.localizedDescription)")
        }
        isLoadingDFS = false
    }

    // MARK: - Helpers

    private func dfsResultSport(_ tournamentID: String) -> String {
        if tournamentID.hasPrefix("nba-") { return "NBA" }
        if tournamentID.hasPrefix("ncaam-") { return "NCAAM" }
        if tournamentID.hasPrefix("mlb-") { return "MLB" }
        if tournamentID.hasPrefix("pga-") { return "PGA" }
        return "DFS"
    }

    private func dfsResultIcon(_ sport: String) -> String {
        switch sport {
        case "NBA", "NCAAM": return "basketball.fill"
        case "MLB": return "baseball.fill"
        case "PGA": return "figure.golf"
        default: return "trophy.fill"
        }
    }

    private func dfsResultColor(_ sport: String) -> Color {
        switch sport {
        case "NBA": return .orange
        case "NCAAM": return .blue
        case "MLB": return .red
        case "PGA": return .green
        default: return brandPurple
        }
    }
}
