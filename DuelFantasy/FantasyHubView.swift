import SwiftUI

/// Hashable destinations for past-result NavigationLink rows.
enum PastResultDestination: Hashable {
    case tennis(slamRaw: String, drawRaw: String)
    case playoffTiers
    case soccerTiers
    case golfTiers
    case bestBall(leagueID: String)
}

/// Wraps `TennisBracketLobbyView` so we can switch the underlying VM to
/// the slam/draw the user tapped before the view loads. Without this
/// the tap on "2026 French Open ATP" past result would land on whatever
/// slam was already selected (Wimbledon, by default this week).
struct TennisBracketPastResultDestination: View {
    @Bindable var viewModel: TennisBracketViewModel
    let slam: GrandSlam
    let draw: DrawType

    var body: some View {
        TennisBracketLobbyView(viewModel: viewModel)
            .task {
                if viewModel.selectedGrandSlam != slam || viewModel.selectedDrawType != draw {
                    viewModel.selectedGrandSlam = slam
                    viewModel.selectedDrawType = draw
                    viewModel.hasAttemptedLoad = false
                    await viewModel.loadTournament()
                }
            }
    }
}

struct FantasyHubView: View {
    @Bindable var bestBallViewModel: BestBallViewModel
    @Bindable var playoffTiersViewModel: PlayoffTiersViewModel
    @Bindable var tennisBracketViewModel: TennisBracketViewModel
    @Bindable var golfTiersViewModel: GolfTiersViewModel
    @Bindable var soccerTiersViewModel: SoccerTiersViewModel

    /// Past Fantasy-hub results fetched directly from the server. Backed
    /// by @AppStorage so the rows survive tab switches and view
    /// recreations — otherwise the @State would reset on every mount and
    /// the section flickered to empty for the duration of the next fetch.
    /// We still refresh in the background on each appearance, but the
    /// UI renders the cached blob instantly.
    @AppStorage("fantasyPastResultsCache") private var fantasyPastResultsCache: Data = Data()
    /// True only when we have neither cached data nor a completed fetch.
    /// Used to show a loading indicator instead of the "No past results"
    /// empty state during the cold-load window.
    @State private var pastResultsLoading = false
    @State private var hasCompletedAtLeastOneFetch = false

    private var brandPurple: Color {
        Color(red: 0.48, green: 0.23, blue: 0.93)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Active contests section
                    activeContestsSection

                    // Game type cards
                    gameTypeCardsSection

                    // Past results across every Fantasy-hub game
                    pastResultsSection

                    // Coming soon section
                    comingSoonSection
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
            .navigationTitle("Fantasy")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                // Preload playoff tiers data so navigation can correctly route
                // to LobbyView vs LiveView when the user taps the card.
                if !playoffTiersViewModel.hasAttemptedLoad {
                    await playoffTiersViewModel.loadTournament()
                }
                if !tennisBracketViewModel.hasAttemptedLoad {
                    await tennisBracketViewModel.loadTournament()
                }
                tennisBracketViewModel.hasAttemptedLoad = true
                if !golfTiersViewModel.hasAttemptedLoad {
                    await golfTiersViewModel.loadTournament()
                }
                golfTiersViewModel.hasAttemptedLoad = true
                if !soccerTiersViewModel.hasAttemptedLoad {
                    await soccerTiersViewModel.loadTournament()
                }
                soccerTiersViewModel.hasAttemptedLoad = true
            }
            // Load past results keyed on accessToken — `.task(id:)` fires
            // both on initial appearance AND every time the id changes,
            // so it's the right primitive for "fetch when auth lands"
            // without juggling separate .task + .onChange paths.
            .task(id: tennisBracketViewModel.accessToken) {
                await loadServerFantasyResults()
            }
            .navigationDestination(for: PastResultDestination.self) { dest in
                pastResultDestinationView(for: dest)
            }
        }
    }

    @ViewBuilder
    private func pastResultDestinationView(for dest: PastResultDestination) -> some View {
        switch dest {
        case .tennis(let slamRaw, let drawRaw):
            TennisBracketPastResultDestination(
                viewModel: tennisBracketViewModel,
                slam: GrandSlam(rawValue: slamRaw) ?? .frenchOpen,
                draw: DrawType(rawValue: drawRaw) ?? .atp
            )
        case .playoffTiers:
            PlayoffTiersLobbyView(viewModel: playoffTiersViewModel)
        case .soccerTiers:
            SoccerTiersLobbyView(viewModel: soccerTiersViewModel)
        case .golfTiers:
            GolfTiersLobbyView(viewModel: golfTiersViewModel)
        case .bestBall(let leagueID):
            BestBallLeagueDetailView(viewModel: bestBallViewModel, leagueID: leagueID)
        }
    }

    // MARK: - Active Contests

    @ViewBuilder
    private var activeContestsSection: some View {
        let hasActiveBestBall = !bestBallViewModel.myLeagues.isEmpty
        let hasActivePlayoffTiers = playoffTiersViewModel.hasSubmitted && !playoffTiersViewModel.isSettled
        let hasActiveTennisBracket = tennisBracketViewModel.hasSubmitted && !tennisBracketViewModel.isSettled
        let hasActiveGolfTiers = golfTiersViewModel.hasSubmitted && !golfTiersViewModel.isSettled
        let hasActiveSoccerTiers = soccerTiersViewModel.hasSubmitted && !soccerTiersViewModel.isSettled

        if hasActiveBestBall || hasActivePlayoffTiers || hasActiveTennisBracket || hasActiveGolfTiers || hasActiveSoccerTiers {
            VStack(alignment: .leading, spacing: 12) {
                Text("ACTIVE CONTESTS")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)

                if hasActivePlayoffTiers {
                    NavigationLink {
                        PlayoffTiersLobbyView(viewModel: playoffTiersViewModel)
                    } label: {
                        activeContestCard(
                            title: playoffTiersViewModel.tournament?.title ?? "NBA Playoff Tiers",
                            subtitle: playoffTiersViewModel.isLive ? "LIVE" : (playoffTiersViewModel.isLocked ? "LOCKED" : "PICKS SUBMITTED"),
                            icon: "basketball.fill",
                            isLive: playoffTiersViewModel.isLive,
                            detail: playoffTiersViewModel.userRank.map { "Rank #\($0)" }
                        )
                    }
                    .buttonStyle(.plain)
                }

                // Show ATP and WTA brackets as separate cards when the user has
                // submitted both AND the slam isn't settled yet. Without the
                // `!isSettled` gate, navigating into a past-result French
                // Open row leaves the VM pointed at the settled slam, and
                // the Fantasy tab then re-renders showing it as if it were
                // still active.
                if tennisBracketViewModel.hasSubmittedATP && !tennisBracketViewModel.isSettled {
                    NavigationLink {
                        if tennisBracketViewModel.isLocked {
                            TennisBracketLiveView(viewModel: tennisBracketViewModel)
                        } else {
                            TennisBracketLobbyView(viewModel: tennisBracketViewModel)
                        }
                    } label: {
                        let isAtpLoaded = tennisBracketViewModel.selectedDrawType == .atp
                        let live = isAtpLoaded ? tennisBracketViewModel.isLive : tennisBracketViewModel.atpIsLive
                        let rank = isAtpLoaded ? tennisBracketViewModel.userRank : tennisBracketViewModel.atpUserRank
                        activeContestCard(
                            title: "\(Calendar.current.component(.year, from: Date())) \(tennisBracketViewModel.selectedGrandSlam.displayName) — ATP",
                            subtitle: live ? "LIVE" : "PICKS SUBMITTED",
                            icon: "tennisball.fill",
                            isLive: live,
                            detail: rank.map { "Rank #\($0)" }
                        )
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded {
                        if tennisBracketViewModel.selectedDrawType != .atp {
                            tennisBracketViewModel.selectedDrawType = .atp
                            tennisBracketViewModel.hasAttemptedLoad = false
                            Task { await tennisBracketViewModel.loadTournament() }
                        }
                    })
                }
                if tennisBracketViewModel.hasSubmittedWTA && !tennisBracketViewModel.isSettled {
                    NavigationLink {
                        if tennisBracketViewModel.isLocked {
                            TennisBracketLiveView(viewModel: tennisBracketViewModel)
                        } else {
                            TennisBracketLobbyView(viewModel: tennisBracketViewModel)
                        }
                    } label: {
                        let isWtaLoaded = tennisBracketViewModel.selectedDrawType == .wta
                        let live = isWtaLoaded ? tennisBracketViewModel.isLive : tennisBracketViewModel.wtaIsLive
                        let rank = isWtaLoaded ? tennisBracketViewModel.userRank : tennisBracketViewModel.wtaUserRank
                        activeContestCard(
                            title: "\(Calendar.current.component(.year, from: Date())) \(tennisBracketViewModel.selectedGrandSlam.displayName) — WTA",
                            subtitle: live ? "LIVE" : "PICKS SUBMITTED",
                            icon: "tennisball.fill",
                            isLive: live,
                            detail: rank.map { "Rank #\($0)" }
                        )
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded {
                        if tennisBracketViewModel.selectedDrawType != .wta {
                            tennisBracketViewModel.selectedDrawType = .wta
                            tennisBracketViewModel.hasAttemptedLoad = false
                            Task { await tennisBracketViewModel.loadTournament() }
                        }
                    })
                }
                // Fallback: if neither dual flag is set but the active flag says yes, show one card.
                if !tennisBracketViewModel.hasSubmittedATP && !tennisBracketViewModel.hasSubmittedWTA && hasActiveTennisBracket {
                    NavigationLink {
                        if tennisBracketViewModel.isLocked {
                            TennisBracketLiveView(viewModel: tennisBracketViewModel)
                        } else {
                            TennisBracketLobbyView(viewModel: tennisBracketViewModel)
                        }
                    } label: {
                        activeContestCard(
                            title: tennisBracketViewModel.tournament?.title ?? "Tennis Grand Slam Brackets",
                            subtitle: tennisBracketViewModel.isLive ? "LIVE" : (tennisBracketViewModel.isLocked ? "LOCKED" : "PICKS SUBMITTED"),
                            icon: "tennisball.fill",
                            isLive: tennisBracketViewModel.isLive,
                            detail: tennisBracketViewModel.userRank.map { "Rank #\($0)" }
                        )
                    }
                    .buttonStyle(.plain)
                }

                if hasActiveGolfTiers {
                    NavigationLink {
                        GolfTiersLobbyView(viewModel: golfTiersViewModel)
                    } label: {
                        activeContestCard(
                            title: golfTiersViewModel.tournament?.title ?? "Golf Major Tiers",
                            subtitle: golfTiersViewModel.isLive ? "LIVE" : (golfTiersViewModel.isLocked ? "LOCKED" : "PICKS SUBMITTED"),
                            icon: "figure.golf",
                            isLive: golfTiersViewModel.isLive,
                            detail: golfTiersViewModel.userRank.map { "Rank #\($0)" }
                        )
                    }
                    .buttonStyle(.plain)
                }

                if hasActiveSoccerTiers {
                    NavigationLink {
                        SoccerTiersLobbyView(viewModel: soccerTiersViewModel)
                    } label: {
                        activeContestCard(
                            title: soccerTiersViewModel.tournament?.title ?? "World Cup Tiers",
                            subtitle: soccerTiersViewModel.isLive ? "LIVE" : (soccerTiersViewModel.isLocked ? "LOCKED" : "PICKS SUBMITTED"),
                            icon: "soccerball",
                            isLive: soccerTiersViewModel.isLive,
                            detail: soccerTiersViewModel.userRank.map { "Rank #\($0)" }
                        )
                    }
                    .buttonStyle(.plain)
                }

                if hasActiveBestBall {
                    NavigationLink {
                        BestBallContestView(viewModel: bestBallViewModel)
                    } label: {
                        activeContestCard(
                            title: "Best Ball Fantasy",
                            subtitle: "\(bestBallViewModel.myLeagues.count) active league\(bestBallViewModel.myLeagues.count == 1 ? "" : "s")",
                            icon: bestBallIcon(for: bestBallViewModel.myLeagues),
                            isLive: false,
                            detail: nil
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func activeContestCard(title: String, subtitle: String, icon: String, isLive: Bool, detail: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(brandPurple)
                .frame(width: 44, height: 44)
                .background(brandPurple.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    if isLive {
                        Circle()
                            .fill(.red)
                            .frame(width: 6, height: 6)
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(isLive ? .red : .secondary)
                }
            }

            Spacer()

            if let detail {
                Text(detail)
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(brandPurple)
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
    }

    // MARK: - Game Type Cards

    private var gameTypeCardsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GAME TYPES")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            // NBA Playoff Tiers
            NavigationLink {
                PlayoffTiersLobbyView(viewModel: playoffTiersViewModel)
            } label: {
                gameTypeCard(
                    title: "NBA Playoff Tiers",
                    subtitle: "Pick 1 player from each of 6 tiers for the entire NBA postseason",
                    icon: "basketball.fill",
                    gradient: [Color(red: 0.10, green: 0.15, blue: 0.30), Color(red: 0.15, green: 0.25, blue: 0.50)],
                    status: playoffTiersCardStatus
                )
            }
            .buttonStyle(.plain)

            // Best Ball Fantasy (season-long, multi-sport)
            NavigationLink {
                BestBallContestView(viewModel: bestBallViewModel)
            } label: {
                gameTypeCard(
                    title: "Best Ball Fantasy",
                    subtitle: "Season-long: draft a roster across MLB, NFL, or NBA and the best lineup auto-sets each week",
                    icon: "figure.baseball",
                    gradient: [Color(red: 0.12, green: 0.28, blue: 0.12), Color(red: 0.18, green: 0.42, blue: 0.18)],
                    status: .open,
                    extraIcons: ["football.fill", "basketball.fill"]
                )
            }
            .buttonStyle(.plain)

            // Tennis Grand Slam Brackets
            NavigationLink {
                TennisBracketLobbyView(viewModel: tennisBracketViewModel)
            } label: {
                gameTypeCard(
                    title: "Tennis Grand Slam Brackets",
                    subtitle: "Pick every match winner across 7 rounds of a Grand Slam draw",
                    icon: "tennisball.fill",
                    gradient: [Color(red: 0.15, green: 0.30, blue: 0.15), Color(red: 0.25, green: 0.50, blue: 0.20)],
                    status: tennisBracketCardStatus
                )
            }
            .buttonStyle(.plain)

            // Golf Major Tiers
            NavigationLink {
                GolfTiersLobbyView(viewModel: golfTiersViewModel)
            } label: {
                gameTypeCard(
                    title: "Golf Major Tiers",
                    subtitle: "Pick 1 golfer from each of 6 tiers — best 4 of 6 scores count, lowest wins",
                    icon: "figure.golf",
                    gradient: [Color(red: 0.05, green: 0.25, blue: 0.10), Color(red: 0.10, green: 0.40, blue: 0.18)],
                    status: golfTiersCardStatus
                )
            }
            .buttonStyle(.plain)

            // World Cup Tiers
            NavigationLink {
                SoccerTiersLobbyView(viewModel: soccerTiersViewModel)
            } label: {
                gameTypeCard(
                    title: "World Cup Tiers",
                    subtitle: "Pick 1 player from each of 6 tiers for the entire FIFA World Cup",
                    icon: "soccerball",
                    gradient: [Color(red: 0.05, green: 0.30, blue: 0.12), Color(red: 0.10, green: 0.48, blue: 0.22)],
                    status: soccerTiersCardStatus
                )
            }
            .buttonStyle(.plain)
        }
    }

    private enum GameStatus {
        case open, live, locked, settled, comingSoon

        var label: String {
            switch self {
            case .open: return "OPEN"
            case .live: return "LIVE"
            case .locked: return "LOCKED"
            case .settled: return "FINAL"
            case .comingSoon: return "COMING SOON"
            }
        }

        var color: Color {
            switch self {
            case .open: return Color(red: 0.48, green: 0.23, blue: 0.93)
            case .live: return .red
            case .locked: return .orange
            case .settled: return .secondary
            case .comingSoon: return .secondary
            }
        }
    }

    private var tennisBracketCardStatus: GameStatus {
        guard let tournament = tennisBracketViewModel.tournament else { return .open }
        switch tournament.status {
        case "live": return .live
        case "locked": return .locked
        case "settled": return .settled
        default: return .open
        }
    }

    private var playoffTiersCardStatus: GameStatus {
        guard let tournament = playoffTiersViewModel.tournament else { return .open }
        switch tournament.status {
        case "live": return .live
        case "locked": return .locked
        case "settled": return .settled
        default: return .open
        }
    }

    private var golfTiersCardStatus: GameStatus {
        guard let tournament = golfTiersViewModel.tournament else { return .open }
        switch tournament.status {
        case "live": return .live
        case "locked": return .locked
        case "settled": return .settled
        default: return .open
        }
    }

    private var soccerTiersCardStatus: GameStatus {
        guard let tournament = soccerTiersViewModel.tournament else { return .open }
        switch tournament.status {
        case "live": return .live
        case "locked": return .locked
        case "settled": return .settled
        default: return .open
        }
    }

    /// Pick a representative SF Symbol for the active-best-ball card
    /// based on which sports the user actually has leagues in. Single
    /// sport gets the obvious symbol; mixed leagues default to the
    /// football icon since the active-contest card only shows one.
    private func bestBallIcon(for leagues: [BestBallLeague]) -> String {
        let sports = Set(leagues.map(\.sport))
        if sports.count == 1, let only = sports.first {
            switch only {
            case "NBA": return "basketball.fill"
            case "NFL": return "football.fill"
            case "MLB": return "figure.baseball"
            default: return "figure.baseball"
            }
        }
        return "football.fill"
    }

    private func gameTypeCard(title: String, subtitle: String, icon: String, gradient: [Color], status: GameStatus, extraIcons: [String] = []) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                ForEach(extraIcons, id: \.self) { extra in
                    Image(systemName: extra)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }

                Spacer()

                Text(status.label)
                    .font(.caption.weight(.heavy))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(status.color)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }

            Text(title)
                .font(.title3.bold())
                .foregroundStyle(.white)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(2)

            HStack {
                Spacer()
                HStack(spacing: 4) {
                    Text("Enter")
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "arrow.right")
                        .font(.caption)
                }
                .foregroundStyle(.white)
            }
        }
        .padding(16)
        .background(
            LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }

    // MARK: - Coming Soon

    private var comingSoonSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("COMING SOON")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            comingSoonCard(title: "NFL Survivor Pool", icon: "football.fill", sport: "NFL")
        }
    }

    // MARK: - Past Results (Fantasy)

    /// Identifies a tournament ID as belonging to one of the Fantasy
    /// hub game types (tennis bracket, playoff tiers, soccer tiers,
    /// golf tiers, best ball) rather than the DFS lobby. Both kinds
    /// flow through the same `dfs_tournament_results` table and into
    /// the shared `dfsHistoryData` blob, so we have to look at the tid
    /// shape to separate them.
    private func fantasyKind(for tid: String) -> (label: String, icon: String, color: Color)? {
        let lower = tid.lowercased()
        // Tennis bracket: "<grandSlam>-(atp|wta)-YYYY"
        if lower.contains("-atp-") || lower.contains("-wta-") {
            return ("Tennis Bracket", "tennisball.fill", Color(red: 0.85, green: 0.50, blue: 0.20))
        }
        // Playoff Tiers (NBA): "nba-playoffs-YYYY"
        if lower.contains("-playoffs-") {
            return ("Playoff Tiers", "figure.basketball", .orange)
        }
        // World Cup / Soccer Tiers: "world-cup-YYYY"
        if lower.hasPrefix("world-cup-") {
            return ("Soccer Tiers", "soccerball", .green)
        }
        // Golf Tiers: tournament-named IDs we know are golf majors.
        // Note: tid uses "masters-" (no leading "the-").
        let golfPrefixes = ["masters-", "the-masters-", "us-open-", "the-open-", "pga-championship-"]
        if golfPrefixes.contains(where: { lower.hasPrefix($0) }) {
            return ("Golf Tiers", "figure.golf", Color(red: 0.05, green: 0.45, blue: 0.25))
        }
        // Best Ball league: synthetic tid `bestball-<leagueID>` we mint
        // when surfacing completed leagues in Past Results.
        if lower.hasPrefix("bestball-") {
            return ("Best Ball", "football.fill", Color(red: 0.20, green: 0.45, blue: 0.85))
        }
        return nil
    }

    /// Union of (1) locally-cached results from `dfsHistoryData` and
    /// (2) results freshly fetched from the server, filtered to just
    /// the Fantasy-hub games. Deduped by `tournamentId`; the locally-
    /// cached row wins (it has accurate `totalEntries` from the VM's
    /// own computation) and server-only rows fill the gaps.
    private var fantasyPastResults: [DFSResult] {
        let local: [DFSResult] = {
            guard let decoded = try? JSONDecoder().decode([DFSResult].self, from: tennisBracketViewModel.dfsHistoryData) else {
                return []
            }
            return decoded.filter { result in
                guard let tid = result.tournamentId else { return false }
                return fantasyKind(for: tid) != nil
            }
        }()
        let serverCached: [DFSResult] = {
            guard !fantasyPastResultsCache.isEmpty,
                  let decoded = try? JSONDecoder().decode([DFSResult].self, from: fantasyPastResultsCache) else {
                return []
            }
            return decoded
        }()
        let localTids = Set(local.compactMap { $0.tournamentId })
        let serverOnly = serverCached.filter { result in
            guard let tid = result.tournamentId else { return false }
            return !localTids.contains(tid)
        }
        let combined = local + serverOnly
        return combined.sorted { $0.loggedAt > $1.loggedAt }
    }

    /// Fetch the user's past Fantasy-hub results directly from server
    /// tables. Two sources:
    ///   1. `dfs_tournament_results` — covers playoff/golf/soccer tiers
    ///      and any tennis bracket whose `settle()` upserted here.
    ///   2. `tennis_bracket_entries` — fallback for graded brackets
    ///      that never made it to `dfs_tournament_results`.
    private func loadServerFantasyResults() async {
        print("[FantasyHub] loadServerFantasyResults: enter — userID=\(tennisBracketViewModel.userID ?? "nil"), token=\(tennisBracketViewModel.accessToken == nil ? "nil" : "set")")
        guard let userID = tennisBracketViewModel.userID,
              let token = tennisBracketViewModel.accessToken else {
            print("[FantasyHub] loadServerFantasyResults: bailing — auth not ready")
            return
        }
        if pastResultsLoading {
            print("[FantasyHub] loadServerFantasyResults: bailing — already loading")
            return
        }
        pastResultsLoading = true
        defer { pastResultsLoading = false }

        var collected: [String: DFSResult] = [:]   // tid → result

        // SOURCE 1: dfs_tournament_results
        let dfsRowsResult: [DFSTournamentResultRecord]?
        do {
            dfsRowsResult = try await SupabaseService.shared.fetchUserDFSHistory(
                userID: userID, limit: 200, offset: 0, accessToken: token
            )
            print("[FantasyHub] Source 1: fetched \(dfsRowsResult?.count ?? 0) DFS history rows")
        } catch {
            print("[FantasyHub] Source 1 FAILED: \(error.localizedDescription)")
            dfsRowsResult = nil
        }
        if let rows = dfsRowsResult {
            // Look up tournament titles (and total entries) in batch.
            let fantasyRows = rows.filter { r in
                fantasyKind(for: r.tournamentID) != nil && r.userID == userID && !r.isBot
            }
            // Best-effort: pull recent DFS tournaments for titles.
            let metaList = (try? await SupabaseService.shared.fetchRecentTournaments(
                limit: 200, accessToken: token
            )) ?? []
            let metaByID = Dictionary(uniqueKeysWithValues: metaList.map { ($0.id, $0) })
            for row in fantasyRows {
                let title = metaByID[row.tournamentID]?.title ?? derivedFantasyTitle(row.tournamentID)
                let totalEntries = metaByID[row.tournamentID]?.totalEntries ?? 0
                collected[row.tournamentID] = DFSResult(
                    id: UUID(),
                    tournamentTitle: title,
                    rank: row.rank,
                    totalEntries: totalEntries,
                    lineupPoints: row.totalPoints,
                    rrDelta: row.rrDelta,
                    loggedAt: row.createdAt ?? Date(),
                    tournamentId: row.tournamentID
                )
            }
        }

        // SOURCE 2: tennis_bracket_entries (entries-table fallback)
        let currentYear = Calendar.current.component(.year, from: Date())
        var candidates: [String] = []
        for y in (currentYear - 1)...currentYear {
            for slam in GrandSlam.allCases {
                for draw in DrawType.allCases {
                    candidates.append("\(slam.rawValue)-\(draw.rawValue)-\(y)")
                }
            }
        }
        for tid in candidates where collected[tid] == nil {
            let entryOpt: TennisBracketEntryRecord?
            do {
                entryOpt = try await SupabaseService.shared.fetchUserTennisBracketEntry(
                    tournamentID: tid, userID: userID, accessToken: token
                )
            } catch {
                print("[FantasyHub] tennis entry fetch failed for \(tid): \(error.localizedDescription)")
                continue
            }
            guard let entry = entryOpt, !entry.picks.isEmpty else { continue }

            // Always compute the leaderboard locally — the server's
            // `rank`/`total_points` columns aren't reliably populated
            // (settle() runs on whichever device gets there first and
            // can skip rows that weren't in its `fieldEntries` at that
            // moment). Local computation is the source of truth.
            let matchResults = (try? await SupabaseService.shared.fetchTennisBracketResults(
                tournamentID: tid, accessToken: token
            )) ?? [:]
            guard !matchResults.isEmpty else {
                print("[FantasyHub] \(tid): no results yet on server — skipping")
                continue
            }
            let allFieldRecords = (try? await SupabaseService.shared.fetchTennisBracketEntries(
                tournamentID: tid, accessToken: token
            )) ?? []
            guard !allFieldRecords.isEmpty else {
                print("[FantasyHub] \(tid): no entries fetched — skipping")
                continue
            }
            let asEntries: [TennisBracketEntry] = allFieldRecords.map { rec in
                TennisBracketEntry(
                    id: UUID(uuidString: rec.id) ?? UUID(),
                    tournamentID: rec.tournamentID,
                    userID: rec.userID,
                    entryName: rec.entryName,
                    picks: rec.picks,
                    totalPoints: rec.totalPoints ?? 0,
                    rank: rec.rank ?? 0,
                    isBot: rec.isBot ?? false,
                    isCurrentUser: rec.userID == userID
                )
            }
            let leaderboard = TennisBracketEngine.computeLeaderboard(
                entries: asEntries, results: matchResults, currentUserID: userID
            )
            guard let me = leaderboard.first(where: { $0.isCurrentUser }) else {
                print("[FantasyHub] \(tid): user not in computed leaderboard, skipping")
                continue
            }

            let tRec = try? await SupabaseService.shared.fetchTennisBracketTournament(
                tournamentID: tid, accessToken: token
            )
            let title = (tRec?.title.isEmpty == false ? tRec!.title : derivedFantasyTitle(tid))

            // Main public bracket result.
            collected[tid] = DFSResult(
                id: UUID(),
                tournamentTitle: title,
                rank: me.rank,
                totalEntries: leaderboard.count,
                lineupPoints: me.totalPoints,
                rrDelta: 0,                                   // no RR for fantasy
                loggedAt: entry.createdAt ?? Date(),
                tournamentId: tid
            )
            print("[FantasyHub] \(tid): COMPUTED public rank=\(me.rank)/\(leaderboard.count) pts=\(me.totalPoints)")

            // Private group results for this tournament.
            let groups = (try? await SupabaseService.shared.fetchMyTennisBracketGroups(
                userID: userID, tournamentID: tid, accessToken: token
            )) ?? []
            for group in groups {
                let members = (try? await SupabaseService.shared.fetchTennisBracketGroupMembers(
                    groupID: group.id, accessToken: token
                )) ?? []
                let memberUserIDs = Set(members.map { $0.userID })
                let groupEntries = asEntries.filter { e in
                    guard let uid = e.userID else { return false }
                    return memberUserIDs.contains(uid)
                }
                guard groupEntries.count >= 2 else { continue }
                let groupLeaderboard = TennisBracketEngine.computeLeaderboard(
                    entries: groupEntries, results: matchResults, currentUserID: userID
                )
                guard let meGroup = groupLeaderboard.first(where: { $0.isCurrentUser }) else { continue }
                // Synthetic tid so the dedupe map treats each group as
                // its own row, and the display path can still recognize
                // the underlying slam via the prefix.
                let syntheticTid = "\(tid)#group-\(group.id)"
                collected[syntheticTid] = DFSResult(
                    id: UUID(),
                    tournamentTitle: group.name,
                    rank: meGroup.rank,
                    totalEntries: groupLeaderboard.count,
                    lineupPoints: meGroup.totalPoints,
                    rrDelta: 0,
                    loggedAt: entry.createdAt ?? Date(),
                    tournamentId: syntheticTid
                )
                print("[FantasyHub] \(tid) group '\(group.name)': COMPUTED rank=\(meGroup.rank)/\(groupLeaderboard.count) pts=\(meGroup.totalPoints)")
            }
        }

        // SOURCE 3: NBA Playoff Tiers
        let playoffTids = [(currentYear - 1), currentYear].map { "nba-playoffs-\($0)" }
        for tid in playoffTids where collected[tid] == nil {
            guard let myEntry = try? await SupabaseService.shared.fetchUserPlayoffTiersEntry(
                tournamentID: tid, userID: userID, accessToken: token
            ), myEntry.totalPoints > 0 else { continue }
            let allEntries = (try? await SupabaseService.shared.fetchPlayoffTiersEntries(
                tournamentID: tid, accessToken: token
            )) ?? []
            let sorted = allEntries.sorted { $0.totalPoints > $1.totalPoints }
            let rank = (sorted.firstIndex { $0.userID == userID }).map { $0 + 1 } ?? myEntry.rank
            let totalEntries = max(sorted.count, 1)
            let title = derivedFantasyTitle(tid)
            collected[tid] = DFSResult(
                id: UUID(), tournamentTitle: title, rank: rank,
                totalEntries: totalEntries, lineupPoints: myEntry.totalPoints,
                rrDelta: 0, loggedAt: myEntry.createdAt ?? Date(), tournamentId: tid
            )
            print("[FantasyHub] \(tid): rank=\(rank)/\(totalEntries) pts=\(myEntry.totalPoints)")

            let groups = (try? await SupabaseService.shared.fetchMyPlayoffTiersGroups(
                userID: userID, tournamentID: tid, accessToken: token
            )) ?? []
            for group in groups {
                let members = (try? await SupabaseService.shared.fetchPlayoffTiersGroupMembers(
                    groupID: group.id, accessToken: token
                )) ?? []
                let memberUserIDs = Set(members.map { $0.userID })
                let groupSorted = sorted.filter { memberUserIDs.contains($0.userID ?? "") }
                guard groupSorted.count >= 2,
                      let myIdx = groupSorted.firstIndex(where: { $0.userID == userID })
                else { continue }
                let syntheticTid = "\(tid)#group-\(group.id)"
                collected[syntheticTid] = DFSResult(
                    id: UUID(),
                    tournamentTitle: group.name,
                    rank: myIdx + 1, totalEntries: groupSorted.count,
                    lineupPoints: myEntry.totalPoints, rrDelta: 0,
                    loggedAt: myEntry.createdAt ?? Date(),
                    tournamentId: syntheticTid
                )
            }
        }

        // SOURCE 4: World Cup Tiers (soccer_tiers_entries)
        let soccerTids = [(currentYear - 1), currentYear, currentYear + 1].map { "world-cup-\($0)" }
        for tid in soccerTids where collected[tid] == nil {
            guard let myEntry = try? await SupabaseService.shared.fetchUserSoccerTiersEntry(
                tournamentID: tid, userID: userID, accessToken: token
            ), myEntry.totalPoints > 0 else { continue }
            let allEntries = (try? await SupabaseService.shared.fetchSoccerTiersEntries(
                tournamentID: tid, accessToken: token
            )) ?? []
            let sorted = allEntries.sorted { $0.totalPoints > $1.totalPoints }
            let rank = (sorted.firstIndex { $0.userID == userID }).map { $0 + 1 } ?? myEntry.rank
            let totalEntries = max(sorted.count, 1)
            let title = derivedFantasyTitle(tid)
            collected[tid] = DFSResult(
                id: UUID(), tournamentTitle: title, rank: rank,
                totalEntries: totalEntries, lineupPoints: myEntry.totalPoints,
                rrDelta: 0, loggedAt: myEntry.createdAt ?? Date(), tournamentId: tid
            )
            print("[FantasyHub] \(tid): rank=\(rank)/\(totalEntries) pts=\(myEntry.totalPoints)")

            let groups = (try? await SupabaseService.shared.fetchMySoccerTiersGroups(
                userID: userID, tournamentID: tid, accessToken: token
            )) ?? []
            for group in groups {
                let members = (try? await SupabaseService.shared.fetchSoccerTiersGroupMembers(
                    groupID: group.id, accessToken: token
                )) ?? []
                let memberUserIDs = Set(members.map { $0.userID })
                let groupSorted = sorted.filter { memberUserIDs.contains($0.userID ?? "") }
                guard groupSorted.count >= 2,
                      let myIdx = groupSorted.firstIndex(where: { $0.userID == userID })
                else { continue }
                let syntheticTid = "\(tid)#group-\(group.id)"
                collected[syntheticTid] = DFSResult(
                    id: UUID(),
                    tournamentTitle: group.name,
                    rank: myIdx + 1, totalEntries: groupSorted.count,
                    lineupPoints: myEntry.totalPoints, rrDelta: 0,
                    loggedAt: myEntry.createdAt ?? Date(),
                    tournamentId: syntheticTid
                )
            }
        }

        // SOURCE 5: Golf Tiers (golf_tiers_entries). 4 majors × current
        // year + prior year. The Masters tid uses bare "masters-" not
        // "the-masters-".
        let golfMajors = ["masters", "pga-championship", "us-open", "the-open"]
        var golfTids: [String] = []
        for y in [currentYear - 1, currentYear] {
            for major in golfMajors { golfTids.append("\(major)-\(y)") }
        }
        for tid in golfTids where collected[tid] == nil {
            guard let myEntry = try? await SupabaseService.shared.fetchUserGolfTiersEntry(
                tournamentID: tid, userID: userID, accessToken: token
            ), myEntry.totalPoints > 0 else { continue }
            let allEntries = (try? await SupabaseService.shared.fetchGolfTiersEntries(
                tournamentID: tid, accessToken: token
            )) ?? []
            let sorted = allEntries.sorted { $0.totalPoints > $1.totalPoints }
            let rank = (sorted.firstIndex { $0.userID == userID }).map { $0 + 1 } ?? myEntry.rank
            let totalEntries = max(sorted.count, 1)
            let title = derivedFantasyTitle(tid)
            collected[tid] = DFSResult(
                id: UUID(), tournamentTitle: title, rank: rank,
                totalEntries: totalEntries, lineupPoints: myEntry.totalPoints,
                rrDelta: 0, loggedAt: myEntry.createdAt ?? Date(), tournamentId: tid
            )
            print("[FantasyHub] \(tid): rank=\(rank)/\(totalEntries) pts=\(myEntry.totalPoints)")

            let groups = (try? await SupabaseService.shared.fetchMyGolfTiersGroups(
                userID: userID, tournamentID: tid, accessToken: token
            )) ?? []
            for group in groups {
                let members = (try? await SupabaseService.shared.fetchGolfTiersGroupMembers(
                    groupID: group.id, accessToken: token
                )) ?? []
                let memberUserIDs = Set(members.map { $0.userID })
                let groupSorted = sorted.filter { memberUserIDs.contains($0.userID ?? "") }
                guard groupSorted.count >= 2,
                      let myIdx = groupSorted.firstIndex(where: { $0.userID == userID })
                else { continue }
                let syntheticTid = "\(tid)#group-\(group.id)"
                collected[syntheticTid] = DFSResult(
                    id: UUID(),
                    tournamentTitle: group.name,
                    rank: myIdx + 1, totalEntries: groupSorted.count,
                    lineupPoints: myEntry.totalPoints, rrDelta: 0,
                    loggedAt: myEntry.createdAt ?? Date(),
                    tournamentId: syntheticTid
                )
            }
        }

        // SOURCE 6: Best Ball completed leagues. Memberships → leagues
        // → standings, find user's standing by memberID. Synthetic tid
        // is `bestball-<leagueID>` so the dedupe + fantasyKind paths
        // recognize it without colliding with any sport prefix.
        let memberships = (try? await SupabaseService.shared.fetchUserMemberships(
            userID: userID, accessToken: token
        )) ?? []
        let memberByLeague: [String: String] = Dictionary(
            memberships.map { ($0.leagueId, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        if !memberByLeague.isEmpty {
            let allLeagues = (try? await SupabaseService.shared.fetchLeaguesByIDs(
                Array(memberByLeague.keys), accessToken: token
            )) ?? []
            let completedLeagues = allLeagues.filter { $0.status == "completed" }
            for leagueRec in completedLeagues {
                let syntheticTid = "bestball-\(leagueRec.id)"
                guard collected[syntheticTid] == nil else { continue }
                guard let myMemberID = memberByLeague[leagueRec.id] else { continue }
                let standings = (try? await SupabaseService.shared.fetchStandings(
                    leagueID: leagueRec.id, accessToken: token
                )) ?? []
                guard let mine = standings.first(where: { $0.memberId == myMemberID }) else {
                    continue
                }
                let totalEntries = max(standings.count, leagueRec.maxMembers ?? 1)
                let loggedAt: Date = mine.updatedAt ?? Date()
                collected[syntheticTid] = DFSResult(
                    id: UUID(),
                    tournamentTitle: leagueRec.title,
                    rank: mine.rank,
                    totalEntries: totalEntries,
                    lineupPoints: mine.totalPoints,
                    rrDelta: 0,
                    loggedAt: loggedAt,
                    tournamentId: syntheticTid
                )
                print("[FantasyHub] bestball \(leagueRec.id): rank=\(mine.rank)/\(totalEntries) pts=\(mine.totalPoints)")
            }
        }

        let results = Array(collected.values).sorted { $0.loggedAt > $1.loggedAt }
        print("[FantasyHub] loadServerFantasyResults: \(results.count) result(s) — tids: \(results.compactMap { $0.tournamentId }.joined(separator: ", "))")
        // Encode and persist to @AppStorage so a tab switch (which can
        // tear down + remount this view) doesn't blank the section.
        if let encoded = try? JSONEncoder().encode(results) {
            fantasyPastResultsCache = encoded
        }
        hasCompletedAtLeastOneFetch = true
    }

    /// Title fallback when no tournament metadata row is available.
    private func derivedFantasyTitle(_ tid: String) -> String {
        let lower = tid.lowercased()
        if lower.contains("-atp-") || lower.contains("-wta-") {
            // french_open-atp-2026 → "2026 French Open ATP"
            let parts = tid.split(separator: "-")
            guard parts.count >= 3 else { return "Tennis Bracket" }
            let slamRaw = String(parts.dropLast(2).joined(separator: "-"))
            let draw = String(parts[parts.count - 2]).uppercased()
            let year = String(parts.last ?? "")
            let slam = GrandSlam(rawValue: slamRaw)?.displayName
                ?? slamRaw.replacingOccurrences(of: "_", with: " ").capitalized
            return "\(year) \(slam) \(draw)"
        }
        if lower.contains("-playoffs-") { return "NBA Playoff Tiers" }
        if lower.hasPrefix("world-cup-") { return "World Cup Tiers" }
        if lower.hasPrefix("masters-") || lower.hasPrefix("the-masters-") { return "The Masters" }
        if lower.hasPrefix("us-open-") { return "US Open" }
        if lower.hasPrefix("the-open-") { return "The Open" }
        if lower.hasPrefix("pga-championship-") { return "PGA Championship" }
        if lower.hasPrefix("bestball-") { return "Best Ball League" }
        return "Tournament"
    }

    @ViewBuilder
    private var pastResultsSection: some View {
        let results = fantasyPastResults
        VStack(alignment: .leading, spacing: 12) {
            Text("PAST RESULTS")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            if results.isEmpty && (pastResultsLoading || !hasCompletedAtLeastOneFetch) {
                // Cold-load: cache is empty AND we haven't finished a
                // server fetch yet. Show a progress indicator instead of
                // the "No past results" empty state so the user doesn't
                // see false-negative copy for the first ~10s.
                HStack(spacing: 12) {
                    ProgressView()
                        .frame(width: 44, height: 44)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Loading past results…")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Pulling settled brackets and tiers from server")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(12)
                .background(.white.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else if results.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No past Fantasy results yet")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Settled brackets and tiers will appear here")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(12)
                .background(.white.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(spacing: 8) {
                    ForEach(results) { result in
                        pastResultRow(result)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func pastResultRow(_ result: DFSResult) -> some View {
        let tid = result.tournamentId ?? ""
        let dest = destination(for: tid)
        if let dest {
            NavigationLink(value: dest) { pastResultRowContent(result, tid: tid) }
                .buttonStyle(.plain)
        } else {
            pastResultRowContent(result, tid: tid)
        }
    }

    private func pastResultRowContent(_ result: DFSResult, tid: String) -> some View {
        let kind = fantasyKind(for: tid)
        let drawPill = drawTypePill(for: tid)
        let isPrivate = tid.contains("#group-")
        return HStack(spacing: 12) {
            Image(systemName: kind?.icon ?? "trophy.fill")
                .font(.title3)
                .foregroundStyle(kind?.color ?? brandPurple)
                .frame(width: 44, height: 44)
                .background((kind?.color ?? brandPurple).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(result.tournamentTitle.isEmpty ? "Tournament" : result.tournamentTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let kind {
                        smallPill(text: kind.label, color: kind.color)
                    }
                    if let drawPill {
                        smallPill(text: drawPill, color: Color(red: 0.20, green: 0.45, blue: 0.85))
                    }
                    if isPrivate {
                        smallPill(text: "PRIVATE", color: brandPurple)
                    }
                }
                HStack(spacing: 8) {
                    Text("#\(result.rank) of \(result.totalEntries)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("•")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(String(format: "%.1f pts", result.lineupPoints))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("•")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(result.loggedAt.formatted(.dateTime.month(.abbreviated).day()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            // RR is intentionally not displayed for Fantasy-hub games —
            // there's no RR ledger associated with brackets/tiers yet.
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
    }

    private func smallPill(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func drawTypePill(for tid: String) -> String? {
        let lower = tid.lowercased()
        if lower.contains("-atp-") { return "ATP" }
        if lower.contains("-wta-") { return "WTA" }
        return nil
    }

    /// Map a result tid to a hashable navigation destination. Returns nil
    /// if the row isn't tied to a known Fantasy-hub destination (e.g.,
    /// when a future game type is added but no view is wired yet).
    private func destination(for tid: String) -> PastResultDestination? {
        // Strip the synthetic `#group-…` suffix before pattern matching.
        let base = tid.split(separator: "#").first.map(String.init) ?? tid
        let lower = base.lowercased()
        if lower.contains("-atp-") || lower.contains("-wta-") {
            let parts = base.split(separator: "-").map(String.init)
            guard parts.count >= 3 else { return nil }
            let drawRaw = parts[parts.count - 2]
            let slamRaw = parts.dropLast(2).joined(separator: "-")
            return .tennis(slamRaw: slamRaw, drawRaw: drawRaw)
        }
        if lower.contains("-playoffs-") { return .playoffTiers }
        if lower.hasPrefix("world-cup-") { return .soccerTiers }
        let golfPrefixes = ["masters-", "the-masters-", "us-open-", "the-open-", "pga-championship-"]
        if golfPrefixes.contains(where: { lower.hasPrefix($0) }) {
            return .golfTiers
        }
        if lower.hasPrefix("bestball-") {
            let leagueID = String(base.dropFirst("bestball-".count))
            return .bestBall(leagueID: leagueID)
        }
        return nil
    }

    private func comingSoonCard(title: String, icon: String, sport: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Stay tuned")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("COMING SOON")
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(.systemGray5))
                .foregroundStyle(.secondary)
                .clipShape(Capsule())
        }
        .padding(12)
        .background(.white.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
