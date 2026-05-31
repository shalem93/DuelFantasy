import SwiftUI

struct FantasyHubView: View {
    @Bindable var bestBallViewModel: BestBallViewModel
    @Bindable var playoffTiersViewModel: PlayoffTiersViewModel
    @Bindable var tennisBracketViewModel: TennisBracketViewModel
    @Bindable var golfTiersViewModel: GolfTiersViewModel
    @Bindable var soccerTiersViewModel: SoccerTiersViewModel

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
                // Mark as attempted even if loadTournament somehow fails
                // to prevent re-triggering on every view appearance
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
                        if playoffTiersViewModel.isLocked {
                            PlayoffTiersLiveView(viewModel: playoffTiersViewModel)
                        } else {
                            PlayoffTiersLobbyView(viewModel: playoffTiersViewModel)
                        }
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

                // Show ATP and WTA brackets as separate cards when the user has submitted
                // both. Tapping switches the viewModel's draw type, then navigates.
                if tennisBracketViewModel.hasSubmittedATP {
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
                if tennisBracketViewModel.hasSubmittedWTA {
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
                        if golfTiersViewModel.isLocked {
                            GolfTiersLiveView(viewModel: golfTiersViewModel)
                        } else {
                            GolfTiersLobbyView(viewModel: golfTiersViewModel)
                        }
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
                        if soccerTiersViewModel.isLocked {
                            SoccerTiersLiveView(viewModel: soccerTiersViewModel)
                        } else {
                            SoccerTiersLobbyView(viewModel: soccerTiersViewModel)
                        }
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
                            title: "Best Ball MLB",
                            subtitle: "\(bestBallViewModel.myLeagues.count) active league\(bestBallViewModel.myLeagues.count == 1 ? "" : "s")",
                            icon: "figure.baseball",
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
                if playoffTiersViewModel.isLocked && playoffTiersViewModel.hasSubmitted {
                    PlayoffTiersLiveView(viewModel: playoffTiersViewModel)
                } else {
                    PlayoffTiersLobbyView(viewModel: playoffTiersViewModel)
                }
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

            // Best Ball MLB
            NavigationLink {
                BestBallContestView(viewModel: bestBallViewModel)
            } label: {
                gameTypeCard(
                    title: "Best Ball MLB",
                    subtitle: "Draft a roster and let the best lineup auto-set each week",
                    icon: "figure.baseball",
                    gradient: [Color(red: 0.12, green: 0.28, blue: 0.12), Color(red: 0.18, green: 0.42, blue: 0.18)],
                    status: .open
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
                if golfTiersViewModel.isLocked && !golfTiersViewModel.isSettled && golfTiersViewModel.hasSubmitted {
                    GolfTiersLiveView(viewModel: golfTiersViewModel)
                } else {
                    GolfTiersLobbyView(viewModel: golfTiersViewModel)
                }
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
                if soccerTiersViewModel.isLocked && !soccerTiersViewModel.isSettled && soccerTiersViewModel.hasSubmitted {
                    SoccerTiersLiveView(viewModel: soccerTiersViewModel)
                } else {
                    SoccerTiersLobbyView(viewModel: soccerTiersViewModel)
                }
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

    private func gameTypeCard(title: String, subtitle: String, icon: String, gradient: [Color], status: GameStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))

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
