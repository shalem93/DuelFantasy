import SwiftUI

    enum DFSSport: String, CaseIterable {
        case nba = "NBA"
        case nhl = "NHL"
        case mlb = "MLB"
        case pga = "PGA"
        case epl = "EPL"
        case ucl = "UCL"
        case wc = "WC"
        case ufc = "UFC"
        case nfl = "NFL"
        case cfb = "CFB"
    }

struct DFSContestView: View {
    @Bindable var viewModel: DFSViewModel
    @Bindable var nhlViewModel: DFSViewModel
    @Bindable var mlbViewModel: DFSViewModel
    @Bindable var pgaViewModel: DFSViewModel
    @Bindable var eplViewModel: DFSViewModel
    @Bindable var uclViewModel: DFSViewModel
    @Bindable var wcViewModel: DFSViewModel
    @Bindable var ufcViewModel: DFSViewModel
    @Bindable var nflViewModel: DFSViewModel
    @Bindable var cfbViewModel: DFSViewModel
    @EnvironmentObject private var auth: AuthViewModel
    @State private var selectedTab: DFSTab = .today
    @State private var selectedSport: DFSSport = .nba
    /// Entries from previous tournaments that are still in progress (not yet settled)
    @State private var previousInProgressEntries: [DFSEntryRecord] = []
    @State private var statsSportFilter: String = "All"

    private enum DFSTab: String, CaseIterable {
        case today = "Today"
        case myContests = "My Contests"
    }

    private var brandPurple: Color {
        Color(red: 0.48, green: 0.23, blue: 0.93)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab selector
                HStack(spacing: 0) {
                    ForEach(DFSTab.allCases, id: \.self) { tab in
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

                // Sport selector (only shown on Today tab)
                if selectedTab == .today {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(DFSSport.allCases, id: \.self) { sport in
                                Button {
                                    Haptics.light()
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        selectedSport = sport
                                    }
                                } label: {
                                    Text(sport.rawValue)
                                        .font(.subheadline.weight(.semibold))
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 8)
                                        .background(selectedSport == sport ? brandPurple : Color(.systemGray5))
                                        .foregroundStyle(selectedSport == sport ? .white : .secondary)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                }

                // Content
                Group {
                    if selectedTab == .myContests {
                        unifiedMyContestsContent
                    } else if selectedSport == .pga {
                        pgaTodayContent
                    } else if selectedSport == .mlb {
                        mlbTodayContent
                    } else if selectedSport == .nhl {
                        nhlTodayContent
                    } else if selectedSport == .epl {
                        soccerTodayContent(viewModel: eplViewModel, sport: "EPL")
                    } else if selectedSport == .ucl {
                        soccerTodayContent(viewModel: uclViewModel, sport: "UCL")
                    } else if selectedSport == .wc {
                        soccerTodayContent(viewModel: wcViewModel, sport: "WC")
                    } else if selectedSport == .ufc {
                        ufcTodayContent
                    } else if selectedSport == .nfl {
                        nflTodayContent
                    } else if selectedSport == .cfb {
                        cfbTodayContent
                    } else {
                        todayContent
                    }
                }
            }
            .navigationTitle("DFS")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: DFSResult.self) { result in
                DFSPastStandingsView(viewModel: viewModelForResult(result), result: result)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.light()
                        Task {
                            await refreshAuthAndSync()
                            switch selectedSport {
                            case .pga:
                                await pgaViewModel.loadSlate(force: true)
                                await pgaViewModel.refreshLive()
                            case .mlb:
                                await mlbViewModel.loadSlate(force: true)
                                await mlbViewModel.refreshLive()
                            case .nhl:
                                await nhlViewModel.loadSlate(force: true)
                                await nhlViewModel.refreshLive()
                            case .epl:
                                await eplViewModel.loadSlate(force: true)
                                await eplViewModel.refreshLive()
                            case .ucl:
                                await uclViewModel.loadSlate(force: true)
                                await uclViewModel.refreshLive()
                            case .wc:
                                await wcViewModel.loadSlate(force: true)
                                await wcViewModel.refreshLive()
                            case .ufc:
                                await ufcViewModel.loadSlate(force: true)
                                await ufcViewModel.refreshLive()
                            case .nfl:
                                await nflViewModel.loadSlate(force: true)
                                await nflViewModel.refreshLive()
                            case .cfb:
                                await cfbViewModel.loadSlate(force: true)
                                await cfbViewModel.refreshLive()
                            case .nba:
                                await viewModel.loadSlate(force: true)
                                await viewModel.refreshLive()
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .task {
            await refreshAuthAndSync()

            // Restore each sport's cached private-contest list synchronously
            // so the Active Contests view renders the right number of cards
            // (in shimmer) on the very first frame, instead of going 2 → 3
            // when the network fetch eventually returns the private contest.
            for vm in [viewModel, nhlViewModel, mlbViewModel, pgaViewModel,
                       eplViewModel, uclViewModel, wcViewModel,
                       ufcViewModel, nflViewModel, cfbViewModel] {
                vm.loadCachedPrivateContests()
            }

            // Sync history once and propagate to all sport viewmodels — the
            // history payload is the same regardless of which sport calls it,
            // so doing it 9 times sequentially is wasted time.
            await viewModel.syncHistoryFromServer()
            propagateHistory(from: viewModel)

            // Per-sport init pipelines run in PARALLEL. Previously these were
            // sequential, so MLB / PGA / later sports stayed empty for 10+
            // seconds after launch — long enough for a user to tap into an
            // MLB SG contest and see raw IDs + an empty leaderboard.
            async let nba: Void  = initSportPipeline(viewModel)
            async let nhl: Void  = initSportPipeline(nhlViewModel)
            async let mlb: Void  = initSportPipeline(mlbViewModel)
            async let pga: Void  = initSportPipeline(pgaViewModel)
            async let epl: Void  = initSportPipeline(eplViewModel)
            async let ucl: Void  = initSportPipeline(uclViewModel)
            async let wc: Void   = initSportPipeline(wcViewModel)
            async let ufc: Void  = initSportPipeline(ufcViewModel)
            async let nfl: Void  = initSportPipeline(nflViewModel)
            async let cfb: Void  = initSportPipeline(cfbViewModel)
            _ = await (nba, nhl, mlb, pga, epl, ucl, wc, ufc, nfl, cfb)

            // Load previous in-progress entries for My Contests
            await loadPreviousInProgressEntries()
        }
        .task(id: "nba-polling") {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 35_000_000_000)
                await refreshAuthAndSync()
                await viewModel.refreshLive()
            }
        }
        .task(id: "nhl-polling") {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 35_000_000_000)
                await refreshAuthAndSync()
                await nhlViewModel.refreshLive()
            }
        }
        .task(id: "mlb-polling") {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 35_000_000_000)
                await refreshAuthAndSync()
                await mlbViewModel.refreshLive()
            }
        }
        .task(id: "pga-polling") {
            while !Task.isCancelled {
                let interval = UInt64(pgaViewModel.pollingInterval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: interval)
                await refreshAuthAndSync()
                await pgaViewModel.refreshLive()
            }
        }
        .task(id: "epl-polling") {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 35_000_000_000)
                await refreshAuthAndSync()
                await eplViewModel.refreshLive()
            }
        }
        .task(id: "ucl-polling") {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 35_000_000_000)
                await refreshAuthAndSync()
                await uclViewModel.refreshLive()
            }
        }
        .task(id: "wc-polling") {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 35_000_000_000)
                await refreshAuthAndSync()
                await wcViewModel.refreshLive()
            }
        }
        .task(id: "ufc-polling") {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 35_000_000_000)
                await refreshAuthAndSync()
                await ufcViewModel.refreshLive()
            }
        }
        .task(id: "nfl-polling") {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 35_000_000_000)
                await refreshAuthAndSync()
                await nflViewModel.refreshLive()
            }
        }
        .task(id: "cfb-polling") {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 35_000_000_000)
                await refreshAuthAndSync()
                await cfbViewModel.refreshLive()
            }
        }
    }

    // MARK: - PGA Today Content

    private var pgaTodayContent: some View {
        Group {
            if pgaViewModel.tournament == nil && (pgaViewModel.isLoading || !pgaViewModel.hasAttemptedLoad) {
                pgaLoadingView
            } else if pgaViewModel.noActiveEvent {
                pgaEmptyStateView
            } else if pgaViewModel.isFullyLocked {
                lockedContestList(viewModel: pgaViewModel)
            } else if pgaViewModel.isPartiallyLocked {
                partiallyLockedView(viewModel: pgaViewModel)
            } else {
                DFSLobbyView(viewModel: pgaViewModel)
            }
        }
    }

    private var pgaLoadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading PGA tournament...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.93, green: 0.97, blue: 0.93),
                    Color(red: 0.95, green: 0.97, blue: 1.00),
                    Color(red: 0.98, green: 0.99, blue: 1.00)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
    }

    private var pgaEmptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "figure.golf")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("No PGA Event This Week")
                .font(.title3.weight(.semibold))

            Text("There's no active PGA Tour event right now. Check back next week!")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                Task {
                    await pgaViewModel.loadSlate(force: true)
                }
            } label: {
                Text("Try Again")
                    .font(.headline)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(brandPurple)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.93, green: 0.97, blue: 0.93),
                    Color(red: 0.95, green: 0.97, blue: 1.00),
                    Color(red: 0.98, green: 0.99, blue: 1.00)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
    }

    // MARK: - MLB Today Content

    private var mlbTodayContent: some View {
        Group {
            if mlbViewModel.tournament == nil && (mlbViewModel.isLoading || !mlbViewModel.hasAttemptedLoad) {
                mlbLoadingView
            } else if mlbViewModel.tournament == nil {
                mlbEmptyStateView
            } else if mlbViewModel.isFullyLocked {
                lockedContestList(viewModel: mlbViewModel)
            } else if mlbViewModel.isPartiallyLocked {
                partiallyLockedView(viewModel: mlbViewModel)
            } else {
                DFSLobbyView(viewModel: mlbViewModel)
            }
        }
    }

    // MARK: - MLB My Contests Content

    private var mlbGradientBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.93, green: 0.95, blue: 0.98),
                Color(red: 0.95, green: 0.97, blue: 1.00),
                Color(red: 0.98, green: 0.99, blue: 1.00)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var mlbMyContestsContent: some View {
        ZStack {
            mlbGradientBackground
            if mlbViewModel.dfsHistory.isEmpty && mlbViewModel.currentUserEntry == nil {
                VStack(spacing: 14) {
                    Image(systemName: "figure.baseball")
                        .font(.system(size: 44))
                        .foregroundStyle(brandPurple.opacity(0.35))
                    Text("No Past Results")
                        .font(.title3.weight(.semibold))
                    Text("Enter today's MLB tournament\nto see your results here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Button {
                        Haptics.light()
                        selectedTab = .today
                    } label: {
                        Text("View Today's Slate")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                            .background(brandPurple)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                    .padding(.top, 4)
                }
                .offset(y: -30)
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        // Show a card for each entered MLB tournament
                        ForEach(mlbActiveEntries, id: \.tournamentID) { entry in
                            inProgressContestCard(entry)
                        }

                        if !mlbViewModel.dfsHistory.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Past Results")
                                    .font(.headline)

                                ForEach(mlbViewModel.dfsHistory.filter { $0.tournamentId?.hasPrefix("mlb-") == true }) { result in
                                    resultRow(result)
                                }
                            }
                            .padding(16)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private func mlbActiveContestCard(_ tournament: DFSTournament) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 6) {
                    if mlbViewModel.isTournamentLocked {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                        Text("LIVE")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    } else {
                        Image(systemName: "clock.fill")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                        Text("UPCOMING")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
                Spacer()
                Text("MLB")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color(red: 0.0, green: 0.2, blue: 0.5))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }

            Text(tournament.title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)

            if let result = mlbViewModel.latestResult {
                HStack(spacing: 20) {
                    VStack(spacing: 2) {
                        Text("RANK")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.6))
                        Text("#\(result.rank)")
                            .font(.title2.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    VStack(spacing: 2) {
                        Text("SCORE")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.6))
                        Text(String(format: "%.1f", result.lineupPoints))
                            .font(.title2.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    Spacer()
                }
            }

            Button {
                Haptics.light()
                selectedSport = .mlb
                selectedTab = .today
            } label: {
                Text(mlbViewModel.isTournamentLocked ? "View Live Contest" : "View Lobby")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(.white.opacity(0.2))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.10, blue: 0.25),
                    Color(red: 0.10, green: 0.18, blue: 0.35)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
    }

    private var mlbLoadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading MLB games...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.93, green: 0.95, blue: 0.98),
                    Color(red: 0.95, green: 0.97, blue: 1.00),
                    Color(red: 0.98, green: 0.99, blue: 1.00)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
    }

    private var mlbEmptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "figure.baseball")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("No MLB Games Today")
                .font(.title3.weight(.semibold))

            Text("There are no MLB games scheduled today. Check back when the season starts!")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                Task {
                    await mlbViewModel.loadSlate(force: true)
                }
            } label: {
                Text("Try Again")
                    .font(.headline)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(brandPurple)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.93, green: 0.95, blue: 0.98),
                    Color(red: 0.95, green: 0.97, blue: 1.00),
                    Color(red: 0.98, green: 0.99, blue: 1.00)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
    }

    // MARK: - NHL Today Content

    private var nhlTodayContent: some View {
        Group {
            if nhlViewModel.tournament == nil && (nhlViewModel.isLoading || !nhlViewModel.hasAttemptedLoad) {
                nhlLoadingView
            } else if nhlViewModel.tournament == nil {
                nhlEmptyStateView
            } else if nhlViewModel.isFullyLocked {
                lockedContestList(viewModel: nhlViewModel)
            } else if nhlViewModel.isPartiallyLocked {
                partiallyLockedView(viewModel: nhlViewModel)
            } else {
                DFSLobbyView(viewModel: nhlViewModel)
            }
        }
    }

    // MARK: - NHL My Contests Content

    private var nhlGradientBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.93, green: 0.95, blue: 0.98),
                Color(red: 0.95, green: 0.96, blue: 1.00),
                Color(red: 0.98, green: 0.99, blue: 1.00)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var nhlMyContestsContent: some View {
        ZStack {
            nhlGradientBackground
            if nhlViewModel.dfsHistory.isEmpty && nhlViewModel.currentUserEntry == nil {
                VStack(spacing: 14) {
                    Image(systemName: "hockey.puck")
                        .font(.system(size: 44))
                        .foregroundStyle(brandPurple.opacity(0.35))
                    Text("No Past Results")
                        .font(.title3.weight(.semibold))
                    Text("Enter today's NHL tournament\nto see your results here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Button {
                        Haptics.light()
                        selectedTab = .today
                    } label: {
                        Text("View Today's Slate")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                            .background(brandPurple)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                    .padding(.top, 4)
                }
                .offset(y: -30)
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        // Show a card for each entered NHL tournament
                        ForEach(nhlActiveEntries, id: \.tournamentID) { entry in
                            inProgressContestCard(entry)
                        }

                        if !nhlViewModel.dfsHistory.isEmpty {
                            nhlContestStatsCard

                            VStack(alignment: .leading, spacing: 10) {
                                Text("Past Results")
                                    .font(.headline)

                                ForEach(nhlViewModel.dfsHistory) { result in
                                    NavigationLink(value: result) {
                                        resultRow(result)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(16)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private func nhlActiveContestCard(_ tournament: DFSTournament) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 6) {
                    if nhlViewModel.isTournamentLocked {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                        Text("LIVE")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    } else {
                        Image(systemName: "clock.fill")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                        Text("UPCOMING")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
                Spacer()
                Text("NHL")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color(red: 0.1, green: 0.3, blue: 0.6))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }

            Text(tournament.title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)

            if let result = nhlViewModel.latestResult {
                HStack(spacing: 20) {
                    VStack(spacing: 2) {
                        Text("RANK")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.6))
                        Text("#\(result.rank)")
                            .font(.title2.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    VStack(spacing: 2) {
                        Text("SCORE")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.6))
                        Text(String(format: "%.1f", result.lineupPoints))
                            .font(.title2.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    Spacer()
                }
            }

            Button {
                Haptics.light()
                selectedSport = .nhl
                selectedTab = .today
            } label: {
                Text(nhlViewModel.isTournamentLocked ? "View Live Contest" : "View Lobby")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(.white.opacity(0.2))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.15, blue: 0.35),
                    Color(red: 0.12, green: 0.25, blue: 0.50)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
    }

    private var nhlContestStatsCard: some View {
        let history = nhlViewModel.dfsHistory
        let totalPlayed = history.count
        let totalRR = history.reduce(0) { $0 + recalculatedRR($1) }
        let bestRank = history.map { $0.rank }.min() ?? 0
        let avgPts = history.isEmpty ? 0.0 : history.reduce(0.0) { $0 + $1.lineupPoints } / Double(history.count)

        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            contestStatBox(title: "Played", value: "\(totalPlayed)", icon: "gamecontroller.fill", color: .blue)
            contestStatBox(title: "Net RR", value: "\(totalRR >= 0 ? "+" : "")\(totalRR)", icon: "arrow.up.arrow.down", color: totalRR >= 0 ? .green : .red)
            contestStatBox(title: "Best Rank", value: bestRank > 0 ? "#\(bestRank)" : "-", icon: "star.fill", color: .yellow)
            contestStatBox(title: "Avg Score", value: String(format: "%.1f", avgPts), icon: "chart.line.uptrend.xyaxis", color: .purple)
        }
    }

    private var nhlLoadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading NHL games...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.93, green: 0.95, blue: 0.98),
                    Color(red: 0.95, green: 0.96, blue: 1.00),
                    Color(red: 0.98, green: 0.99, blue: 1.00)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
    }

    private var nhlEmptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "hockey.puck")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("No NHL Games Today")
                .font(.title3.weight(.semibold))

            Text("There are no NHL games scheduled today. Check back later!")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                Task {
                    await nhlViewModel.loadSlate(force: true)
                }
            } label: {
                Text("Try Again")
                    .font(.headline)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(brandPurple)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.93, green: 0.95, blue: 0.98),
                    Color(red: 0.95, green: 0.96, blue: 1.00),
                    Color(red: 0.98, green: 0.99, blue: 1.00)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
    }

    // MARK: - UFC Today Content

    private var ufcTodayContent: some View {
        Group {
            if ufcViewModel.tournament == nil && (ufcViewModel.isLoading || !ufcViewModel.hasAttemptedLoad) {
                ufcLoadingView
            } else if ufcViewModel.tournament == nil {
                ufcEmptyStateView
            } else if ufcViewModel.isFullyLocked {
                lockedContestList(viewModel: ufcViewModel)
            } else if ufcViewModel.isPartiallyLocked {
                partiallyLockedView(viewModel: ufcViewModel)
            } else {
                DFSLobbyView(viewModel: ufcViewModel)
            }
        }
    }

    private var ufcLoadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading UFC card...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.95, green: 0.93, blue: 0.93),
                    Color(red: 0.97, green: 0.95, blue: 0.95),
                    Color(red: 0.99, green: 0.98, blue: 0.98)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
    }

    private var ufcEmptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "figure.martial.arts")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("No UFC Card Today")
                .font(.title3.weight(.semibold))

            Text("There is no UFC event scheduled today. Check back later!")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                Task {
                    await ufcViewModel.loadSlate(force: true)
                }
            } label: {
                Text("Try Again")
                    .font(.headline)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(brandPurple)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.95, green: 0.93, blue: 0.93),
                    Color(red: 0.97, green: 0.95, blue: 0.95),
                    Color(red: 0.99, green: 0.98, blue: 0.98)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
    }

    // MARK: - NFL Today Content

    private var nflTodayContent: some View {
        Group {
            if nflViewModel.tournament == nil && (nflViewModel.isLoading || !nflViewModel.hasAttemptedLoad) {
                nflLoadingView
            } else if nflViewModel.tournament == nil {
                nflEmptyStateView
            } else if nflViewModel.isFullyLocked {
                lockedContestList(viewModel: nflViewModel)
            } else if nflViewModel.isPartiallyLocked {
                partiallyLockedView(viewModel: nflViewModel)
            } else {
                DFSLobbyView(viewModel: nflViewModel)
            }
        }
    }

    private var nflLoadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading NFL slate...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.92, green: 0.93, blue: 0.96),
                    Color(red: 0.94, green: 0.95, blue: 0.98),
                    Color(red: 0.97, green: 0.98, blue: 0.99)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
    }

    private var nflEmptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "football.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("No NFL Games Today")
                .font(.title3.weight(.semibold))

            Text("There are no NFL games scheduled today. Check back on game day!")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                Task {
                    await nflViewModel.loadSlate(force: true)
                }
            } label: {
                Text("Try Again")
                    .font(.headline)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(brandPurple)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.92, green: 0.93, blue: 0.96),
                    Color(red: 0.94, green: 0.95, blue: 0.98),
                    Color(red: 0.97, green: 0.98, blue: 0.99)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
    }

    // MARK: - CFB Today Content

    private var cfbTodayContent: some View {
        Group {
            if cfbViewModel.tournament == nil && (cfbViewModel.isLoading || !cfbViewModel.hasAttemptedLoad) {
                cfbLoadingView
            } else if cfbViewModel.tournament == nil {
                cfbEmptyStateView
            } else if cfbViewModel.isFullyLocked {
                lockedContestList(viewModel: cfbViewModel)
            } else if cfbViewModel.isPartiallyLocked {
                partiallyLockedView(viewModel: cfbViewModel)
            } else {
                DFSLobbyView(viewModel: cfbViewModel)
            }
        }
    }

    private var cfbLoadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading college football slate...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.93, green: 0.92, blue: 0.95),
                    Color(red: 0.95, green: 0.94, blue: 0.97),
                    Color(red: 0.98, green: 0.97, blue: 0.99)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
    }

    private var cfbEmptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "football.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("No College Football Games Today")
                .font(.title3.weight(.semibold))

            Text("There are no college football games scheduled today. Check back on Saturday!")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                Task {
                    await cfbViewModel.loadSlate(force: true)
                }
            } label: {
                Text("Try Again")
                    .font(.headline)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(brandPurple)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.93, green: 0.92, blue: 0.95),
                    Color(red: 0.95, green: 0.94, blue: 0.97),
                    Color(red: 0.98, green: 0.97, blue: 0.99)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
    }

    // MARK: - Soccer Today Content

    private func soccerTodayContent(viewModel vm: DFSViewModel, sport: String) -> some View {
        Group {
            if vm.tournament == nil && (vm.isLoading || !vm.hasAttemptedLoad) {
                soccerLoadingView(sport: sport)
            } else if vm.tournament == nil {
                soccerEmptyStateView(sport: sport, viewModel: vm)
            } else if vm.isFullyLocked {
                lockedContestList(viewModel: vm)
            } else if vm.isPartiallyLocked {
                partiallyLockedView(viewModel: vm)
            } else {
                DFSLobbyView(viewModel: vm)
            }
        }
    }

    private func soccerLoadingView(sport: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading \(sport) fixtures...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.93, green: 0.97, blue: 0.93),
                    Color(red: 0.95, green: 0.97, blue: 1.00),
                    Color(red: 0.98, green: 0.99, blue: 1.00)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
    }

    private func soccerEmptyStateView(sport: String, viewModel vm: DFSViewModel) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "sportscourt")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("No \(sport) Fixtures Today")
                .font(.title3.weight(.semibold))

            Text("There are no \(sport) matches scheduled today. Check back on matchday!")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                Task {
                    await vm.loadSlate(force: true)
                }
            } label: {
                Text("Try Again")
                    .font(.headline)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(brandPurple)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.93, green: 0.97, blue: 0.93),
                    Color(red: 0.95, green: 0.97, blue: 1.00),
                    Color(red: 0.98, green: 0.99, blue: 1.00)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
    }

    // MARK: - Today Content

    private var todayContent: some View {
        Group {
            if viewModel.tournament == nil && (viewModel.isLoading || !viewModel.hasAttemptedLoad) {
                loadingView
            } else if viewModel.tournament == nil {
                emptyStateView
            } else if viewModel.isFullyLocked {
                lockedContestList(viewModel: viewModel)
            } else if viewModel.isPartiallyLocked {
                partiallyLockedView(viewModel: viewModel)
            } else {
                DFSLobbyView(viewModel: viewModel)
            }
        }
    }

    /// When the slate is locked, show a list of entered tournament cards.
    /// Tapping a card sets the active tournament and navigates to the live view.
    private func lockedContestList(viewModel vm: DFSViewModel) -> some View {
        // Build a flat list of (tournament, lineupNumber) for each entry.
        // Iterate `enteredTournamentIDs` directly — NOT `vm.tournaments.filter`
        // — because `loadSlate(force: true)` (the refresh button) replaces
        // `tournaments` and may not include yesterday's / in-progress SG IDs.
        // If a tournament isn't in the slate anymore, synthesize a stub from
        // the entry's metadata so the card still appears.
        let settledIDs = vm.settledTournaments
        let tournamentByID = Dictionary(uniqueKeysWithValues: vm.tournaments.map { ($0.id, $0) })
        // Any tournament IDs the user references as the parent of a private
        // contest are NOT public contests they joined — they're slates used
        // as the basis for a private contest's player pool. Hide those from
        // the public Active Contests list to prevent ghost "H2H" cards from
        // showing up when the underlying `dfs_tournaments` row was created
        // solely as a private contest's parent reference.
        // Only hide private-contest parents that the user hasn't actually
        // entered as a public contest. If they DID submit a public entry,
        // it should appear in Active Contests even when the same slate is
        // referenced as a private contest's parent.
        let unenteredPrivateParents: Set<String> = {
            var set = Set<String>()
            for contest in vm.myPrivateContests {
                let pid = contest.parentTournamentID
                let hasPublicEntry = (vm.userEntryRecords[pid]?.isEmpty == false)
                if !hasPublicEntry { set.insert(pid) }
            }
            return set
        }()
        let enteredTournaments: [DFSTournament] = vm.enteredTournamentIDs
            .filter { !settledIDs.contains($0) && !unenteredPrivateParents.contains($0) }
            .compactMap { tid -> DFSTournament? in
                if let existing = tournamentByID[tid] { return existing }
                // Synthesize from entry data (best-effort — preserves the card
                // through slate refreshes even when the SG ID rotates out).
                guard let entry = vm.userEntryRecords[tid]?.first else { return nil }
                let entryCount = DFSViewModel.entryCountFromTournamentID(tid)
                let lineupSize = entry.lineupPlayerIDs.count
                let isSG = tid.contains("-sg-")
                return DFSTournament(
                    id: tid,
                    title: "\(vm.sport) Contest",
                    league: vm.sport,
                    entryCount: entryCount,
                    lineupSize: lineupSize,
                    salaryCap: 50000,
                    isSingleGame: isSG,
                    tournamentType: DFSTournamentType.from(tournamentID: tid)
                )
            }
        struct EntryItem: Identifiable {
            let id: String  // unique key for ForEach
            let tournament: DFSTournament
            let lineupNumber: Int
        }
        var rawEntries: [(tournament: DFSTournament, entry: DFSEntryRecord)] = []
        for tournament in enteredTournaments {
            let entries = vm.userEntryRecords[tournament.id] ?? []
            guard !entries.isEmpty else { continue }
            // Skip entries whose lineup size doesn't match the tournament's
            // expected lineup size (catches malformed cross-format submissions).
            let validEntries = entries.filter { entry in
                let actual = entry.lineupPlayerIDs.count
                let expected = tournament.lineupSize
                return expected == 0 || actual == expected
            }
            for entry in validEntries {
                rawEntries.append((tournament, entry))
            }
        }

        // Deduplicate cross-size shadow entries. The user has been seeing
        // "phantom" small contests (H2H, 3-Man, etc.) auto-created alongside
        // intended large contest submissions. To prevent these from cluttering
        // the active list, group entries by (slate, slate-type, lineupNumber)
        // — i.e. all entries for the same slate identity with the same lineup
        // number — and keep only the LARGEST entry count.
        //
        // Slate identity = tournament ID with the trailing "-<entryCount>" stripped
        // (e.g. "mlb-20260528-sg-401815525-2000" → "mlb-20260528-sg-401815525").
        // This groups H2H + 3-Man + 2000-Entry for the same slate together.
        func slateIdentity(_ tid: String) -> String {
            var id = tid
            if let range = id.range(of: #"-i\d+$"#, options: .regularExpression) {
                id.removeSubrange(range)
            }
            let parts = id.components(separatedBy: "-")
            if let last = parts.last, let n = Int(last),
               [2, 3, 5, 10, 100, 500, 1000, 2000].contains(n) {
                return parts.dropLast().joined(separator: "-")
            }
            return id
        }
        let dedupedByLineup: [(tournament: DFSTournament, entry: DFSEntryRecord)] = {
            let grouped = Dictionary(grouping: rawEntries, by: { row -> String in
                let slate = slateIdentity(row.tournament.id)
                let ln = row.entry.lineupNumber ?? 1
                return "\(slate)#\(ln)"
            })
            var kept: [(tournament: DFSTournament, entry: DFSEntryRecord)] = []
            for (_, rows) in grouped {
                // If all rows have the same entry count, keep them all.
                let counts = Set(rows.map { $0.tournament.entryCount })
                if counts.count == 1 {
                    kept.append(contentsOf: rows)
                    continue
                }
                // Multiple sizes for the same slate+lineup → keep only the largest.
                let maxCount = counts.max() ?? 0
                kept.append(contentsOf: rows.filter { $0.tournament.entryCount == maxCount })
            }
            return kept
        }()

        // Sort by (tournament.id, lineupNumber) for a stable order so the
        // Active Contests list doesn't visibly reshuffle on every return
        // from a navigation (root cause: enteredTournamentIDs is a Set).
        let sortedEntries = dedupedByLineup.sorted { lhs, rhs in
            if lhs.tournament.id != rhs.tournament.id {
                return lhs.tournament.id < rhs.tournament.id
            }
            return (lhs.entry.lineupNumber ?? 1) < (rhs.entry.lineupNumber ?? 1)
        }
        let allEntries: [EntryItem] = sortedEntries.enumerated().map { idx, row in
            let num = row.entry.lineupNumber ?? (idx + 1)
            return EntryItem(id: "\(row.tournament.id)-\(num)", tournament: row.tournament, lineupNumber: num)
        }

        // Private contests for the current sport. Show anything that
        // hasn't been settled AND isn't more than 6 hours past its parent
        // slate's lock time. The 6-hour cutoff mirrors the past-section
        // filter (`allPastPrivateContests`) so a single contest never shows
        // in both sections. Dropping the strict same-day check unblocks
        // cases where the slate provider rotated (e.g. UFC card finishes
        // and the provider returns tomorrow's upcoming card — today's
        // contest would otherwise vanish from Active Contests).
        let sportPrefix = vm.sport.lowercased() + "-"
        let activePrivateContests: [DFSPrivateContest] = vm.myPrivateContests.filter { contest in
            guard contest.parentTournamentID.hasPrefix(sportPrefix) else { return false }
            guard !settledIDs.contains(contest.parentTournamentID) else { return false }
            if let parent = vm.tournaments.first(where: { $0.id == contest.parentTournamentID }) {
                let lockTime = vm.lockTimeForTournament(parent)
                if Date().timeIntervalSince(lockTime) > 6 * 3600 { return false }
            }
            return true
        }

        let totalItems = allEntries.count + activePrivateContests.count
        // Per-card readiness: each card flips out of shimmer as soon as its
        // own data is loaded. The previous all-or-nothing gate made every
        // card wait for the slowest one (typically a non-active contest
        // stuck in background bot generation), so the user's active contest
        // — which was already populated by refreshLive — was held behind
        // shimmer for the full pre-cache cycle.
        return Group {
            if totalItems == 0 {
                noEntriesTodayView(viewModel: vm)
            } else if allEntries.count == 1 && activePrivateContests.isEmpty {
                DFSLiveContestView(viewModel: vm,
                                   expectedTournamentID: allEntries[0].tournament.id,
                                   expectedLineupNumber: allEntries[0].lineupNumber)
                    .task {
                        let item = allEntries[0]
                        vm.selectTournament(item.tournament.id, lineupNumber: item.lineupNumber)
                        if vm.leaderboardEntries.isEmpty {
                            await vm.refreshLive()
                        }
                    }
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        Text("Active Contests")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)

                        ForEach(allEntries) { item in
                            NavigationLink {
                                DFSLiveContestView(viewModel: vm,
                                                   expectedTournamentID: item.tournament.id,
                                                   expectedLineupNumber: item.lineupNumber)
                                    .task {
                                        vm.selectTournament(item.tournament.id, lineupNumber: item.lineupNumber)
                                        if vm.leaderboardEntries.isEmpty {
                                            await vm.refreshLive()
                                        }
                                    }
                            } label: {
                                Group {
                                    if vm.isTournamentReady(item.tournament.id) {
                                        lockedContestCard(tournament: item.tournament, lineupNumber: item.lineupNumber, viewModel: vm)
                                    } else {
                                        activeContestShimmer
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }

                        ForEach(activePrivateContests) { contest in
                            NavigationLink {
                                DFSPrivateContestDetailView(viewModel: vm, contest: contest)
                            } label: {
                                Group {
                                    if vm.isPrivateContestReady(contest.id) {
                                        activePrivateContestCard(contest: contest, viewModel: vm)
                                    } else {
                                        activeContestShimmer
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
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
            }
        }
    }

    /// Shown when all games are locked and the user has no active entries
    /// (either they didn't enter or all their entries have settled).
    private func noEntriesTodayView(viewModel vm: DFSViewModel) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "sportscourt")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("No Active Entries")
                .font(.title3.weight(.semibold))

            Text(vm.sport == "PGA"
                 ? "This week's PGA tournament has locked.\nCheck back for next week's event!"
                 : "Today's \(vm.sport) games have locked.\nCheck back for tomorrow's slate!")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                Task { await vm.loadSlate(force: true) }
            } label: {
                Text("Refresh Slate")
                    .font(.headline)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(brandPurple)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.93, green: 0.95, blue: 0.98),
                    Color(red: 0.95, green: 0.96, blue: 1.00),
                    Color(red: 0.98, green: 0.99, blue: 1.00)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
    }

    /// When some games have started but others haven't, show live contests at top
    /// and the lobby (filtered to available tournaments) below.
    private func partiallyLockedView(viewModel vm: DFSViewModel) -> some View {
        let settledIDs = vm.settledTournaments
        let enteredLocked = vm.lockedTournaments.filter { vm.enteredTournamentIDs.contains($0.id) && !settledIDs.contains($0.id) }
        // Build per-entry items for locked tournaments
        struct LockedEntryItem: Identifiable {
            let id: String
            let tournament: DFSTournament
            let lineupNumber: Int
        }

        // Collect raw (tournament, entry) pairs first so we can dedup phantom
        // small contests (H2H, 3-Man, 5-Man) that occasionally get auto-created
        // alongside the user's real large-contest submission. Without this,
        // the same lineup shows up as multiple rows (H2H + 2000-Entry).
        var rawPairs: [(tournament: DFSTournament, entry: DFSEntryRecord?, lineupNumber: Int)] = []
        for tournament in enteredLocked {
            let entries = vm.userEntryRecords[tournament.id] ?? []
            if entries.isEmpty {
                rawPairs.append((tournament, nil, 1))
            } else {
                for (idx, entry) in entries.enumerated() {
                    rawPairs.append((tournament, entry, entry.lineupNumber ?? (idx + 1)))
                }
            }
        }

        // Strip trailing entry-count + instance suffix so contests like
        // "mlb-20260529-2" (H2H) and "mlb-20260529-2000" (Grand Tourn.) on the
        // same slate + same lineup number get grouped together.
        func slateIdentity(_ tid: String) -> String {
            var id = tid
            if let range = id.range(of: #"-i\d+$"#, options: .regularExpression) {
                id.removeSubrange(range)
            }
            let parts = id.components(separatedBy: "-")
            if let last = parts.last, let n = Int(last),
               [2, 3, 5, 10, 100, 500, 1000, 2000].contains(n) {
                return parts.dropLast().joined(separator: "-")
            }
            return id
        }
        let grouped = Dictionary(grouping: rawPairs) { row in
            "\(slateIdentity(row.tournament.id))#\(row.lineupNumber)"
        }
        var deduped: [(tournament: DFSTournament, lineupNumber: Int)] = []
        for (_, rows) in grouped {
            let counts = Set(rows.map { $0.tournament.entryCount })
            // Keep only the largest entry-count contest for each
            // (slate, lineup number) pair — drops the phantom small ones.
            let maxCount = counts.max() ?? 0
            for row in rows where row.tournament.entryCount == maxCount {
                deduped.append((row.tournament, row.lineupNumber))
            }
        }
        let lockedEntryItems: [LockedEntryItem] = deduped
            // Sort by (tournament.id, lineupNumber) for a stable order — without
            // this, `enteredTournamentIDs` (a Set) yields a different iteration
            // order on every render and the cards visibly reshuffle each time
            // the user returns from a navigation.
            .sorted { lhs, rhs in
                if lhs.tournament.id != rhs.tournament.id {
                    return lhs.tournament.id < rhs.tournament.id
                }
                return lhs.lineupNumber < rhs.lineupNumber
            }
            .map { row in
                LockedEntryItem(id: "\(row.tournament.id)-\(row.lineupNumber)",
                                tournament: row.tournament, lineupNumber: row.lineupNumber)
            }

        // Private contests for the current sport — same filter as
        // `lockedContestList` so contests appear consistently regardless of
        // whether the slate is fully locked or only partially locked. Without
        // this, MLB users sitting in the mid-afternoon partial-lock state
        // (some games started, others haven't) couldn't see any of their
        // private contests until the entire slate locked.
        let sportPrefixForPartial = vm.sport.lowercased() + "-"
        let partialActivePrivateContests: [DFSPrivateContest] = vm.myPrivateContests.filter { contest in
            guard contest.parentTournamentID.hasPrefix(sportPrefixForPartial) else { return false }
            guard !settledIDs.contains(contest.parentTournamentID) else { return false }
            if let parent = vm.tournaments.first(where: { $0.id == contest.parentTournamentID }) {
                let lockTime = vm.lockTimeForTournament(parent)
                if Date().timeIntervalSince(lockTime) > 6 * 3600 { return false }
            }
            return true
        }

        return ScrollView {
            VStack(spacing: 16) {
                // MARK: Live contests section (entered tournaments that have locked)
                if !lockedEntryItems.isEmpty || !partialActivePrivateContests.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(.red)
                                .frame(width: 8, height: 8)
                            Text("LIVE")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.red)
                            Text("Active Contests")
                                .font(.headline)
                        }
                        .padding(.horizontal, 16)

                        ForEach(lockedEntryItems) { item in
                            NavigationLink {
                                DFSLiveContestView(viewModel: vm,
                                                   expectedTournamentID: item.tournament.id,
                                                   expectedLineupNumber: item.lineupNumber)
                                    .task {
                                        vm.selectTournament(item.tournament.id, lineupNumber: item.lineupNumber)
                                        if vm.leaderboardEntries.isEmpty {
                                            await vm.refreshLive()
                                        }
                                    }
                            } label: {
                                lockedContestCard(tournament: item.tournament, lineupNumber: item.lineupNumber, viewModel: vm)
                            }
                            .buttonStyle(.plain)
                        }

                        ForEach(partialActivePrivateContests) { contest in
                            NavigationLink {
                                DFSPrivateContestDetailView(viewModel: vm, contest: contest)
                            } label: {
                                if vm.isPrivateContestReady(contest.id) {
                                    activePrivateContestCard(contest: contest, viewModel: vm)
                                } else {
                                    activeContestShimmer
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Divider()
                        .padding(.horizontal, 16)
                }

                // MARK: Available tournaments section
                VStack(alignment: .leading, spacing: 10) {
                    Text("Available Contests")
                        .font(.headline)
                        .padding(.horizontal, 16)

                    // Re-use the lobby but it will only show available (unlocked) tournaments
                    DFSLobbyView(viewModel: vm)
                }
            }
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
    }

    /// Skeleton placeholder for an active-contest card while the tournament's
    /// data is still loading. Matches the layout of `lockedContestCard` so the
    /// row doesn't jump when the real data lands.
    private var activeContestShimmer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    shimmerBox(width: 60, height: 18)
                    shimmerBox(width: 30, height: 14)
                }
                shimmerBox(width: 140, height: 16)
                shimmerBox(width: 100, height: 12)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                shimmerBox(width: 50, height: 18)
                shimmerBox(width: 36, height: 14)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
        .padding(.horizontal, 16)
    }

    private func shimmerBox(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color(.systemGray5))
            .frame(width: width, height: height)
            .shimmering()
    }

    /// Active-contest card for a private contest. Mirrors `lockedContestCard`'s
    /// layout so both card types sit comfortably in the same list.
    private func activePrivateContestCard(contest: DFSPrivateContest, viewModel vm: DFSViewModel) -> some View {
        let memberCount = vm.privateContestMembers[contest.id]?.count ?? 0
        let parentTitle = vm.tournaments.first(where: { $0.id == contest.parentTournamentID })?.title ?? "Private Contest"

        // Compute live FPTS directly from the user's submitted entry + current
        // live points — don't rely on `privateContestLeaderboards`, which only
        // uses live points when the active tournament IS this contest's parent.
        let isSG = vm.tournaments.first(where: { $0.id == contest.parentTournamentID })?.isSingleGame
            ?? contest.parentTournamentID.contains("-sg-")
        let myUUID = vm.userID.flatMap(UUID.init(uuidString:))
        let myEntry: DFSPrivateContestEntry? = {
            guard let me = myUUID else { return nil }
            return (vm.privateContestEntries[contest.id] ?? []).first(where: { $0.userID == me })
        }()
        let myScore: Double = {
            guard let entry = myEntry else { return 0 }
            var total = 0.0
            for (i, pid) in entry.lineupPlayerIDs.enumerated() {
                let pts = vm.livePlayerPoints[pid] ?? 0
                total += (isSG && i == 0) ? pts * 1.5 : pts
            }
            return total
        }()
        let myRank: Int? = (vm.privateContestLeaderboards[contest.id] ?? []).first(where: { $0.isCurrentUser })?.rank

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("PRIVATE")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(brandPurple)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                    Text(contest.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    Text(parentTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("· \(memberCount) member\(memberCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let rank = myRank {
                    Text("#\(rank)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(brandPurple)
                }
                Text(String(format: "%.1f", myScore))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(.primary)
                Text("FPTS")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 3)
        .padding(.horizontal, 16)
    }

    private func lockedContestCard(tournament: DFSTournament, lineupNumber: Int = 1, viewModel vm: DFSViewModel) -> some View {
        let typeLabel: String = {
            let prefix: String
            switch tournament.tournamentType {
            case .main: prefix = ""
            case .singleGame: prefix = "SG "
            case .evening: prefix = "Eve "
            }
            switch tournament.entryCount {
            case 2: return "\(prefix)H2H"
            case 3: return "\(prefix)3-Man"
            case 5: return "\(prefix)5-Man WTA"
            case 10: return "\(prefix)10-Man"
            default: return "\(prefix)\(tournament.entryCount)-Entry"
            }
        }()

        // Compute live score for this lineup from entry records + live points
        let lineupScore: Double = {
            guard let entry = vm.entryRecord(for: tournament.id, lineupNumber: lineupNumber) else { return 0 }
            let isSG = tournament.isSingleGame
            var total = 0.0
            for (i, pid) in entry.lineupPlayerIDs.enumerated() {
                let pts = vm.livePlayerPoints[pid] ?? 0
                total += (isSG && i == 0) ? pts * 1.5 : pts
            }
            return total
        }()

        // Get rank: prefer cached live rank, then live leaderboard, then history
        let lineupRank: Int? = {
            // Check cached live ranks (computed when any tournament's leaderboard is built)
            let cacheKey = "\(tournament.id)-\(lineupNumber)"
            if let cached = vm.cachedLiveRanks[cacheKey] {
                return cached
            }
            // If this tournament's leaderboard is loaded, compute rank from live scores
            if vm.activeTournamentID == tournament.id, !vm.leaderboardEntries.isEmpty {
                let higherCount = vm.leaderboardEntries.filter { $0.points > lineupScore }.count
                return higherCount + 1
            }
            // Fall back to the per-tournament cache (built by pre-cache or by a
            // previous live-view session). Lets the card show a rank for any
            // entered contest whose field has been generated, not just the
            // currently-selected one.
            if let cachedLB = vm.cachedLeaderboard(for: tournament.id), !cachedLB.isEmpty {
                let higherCount = cachedLB.filter { $0.points > lineupScore }.count
                return higherCount + 1
            }
            // Fall back to saved history result for this specific lineup
            let match = vm.dfsHistory.first(where: {
                $0.tournamentId == tournament.id && ($0.lineupNumber ?? 1) == lineupNumber
            })
            return match?.rank
        }()

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(typeLabel)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(brandPurple)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                    Text("#\(lineupNumber)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(tournament.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    Text("\(tournament.entryCount) entries")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("$\(vm.formatSalary(tournament.salaryCap)) cap")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let rank = lineupRank {
                    Text("#\(rank)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(brandPurple)
                }
                Text(String(format: "%.1f", lineupScore))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(.primary)
                Text("FPTS")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 3)
        .padding(.horizontal, 16)
    }

    // MARK: - Unified My Contests (all sports combined)

    /// Active entries for a single view model (one per entered tournament, excluding settled).
    private func activeEntries(for vm: DFSViewModel) -> [DFSEntryRecord] {
        let settled = vm.settledTournaments
        var entries: [DFSEntryRecord] = []
        for tid in vm.enteredTournamentIDs {
            guard !settled.contains(tid) else { continue }
            if let record = vm.userEntryRecords[tid]?.first {
                entries.append(record)
            }
        }
        return entries
    }

    private var nbaActiveEntries: [DFSEntryRecord] { activeEntries(for: viewModel) }
    private var nhlActiveEntries: [DFSEntryRecord] { activeEntries(for: nhlViewModel) }
    private var mlbActiveEntries: [DFSEntryRecord] { activeEntries(for: mlbViewModel) }
    private var pgaActiveEntries: [DFSEntryRecord] { activeEntries(for: pgaViewModel) }
    private var eplActiveEntries: [DFSEntryRecord] { activeEntries(for: eplViewModel) }
    private var uclActiveEntries: [DFSEntryRecord] { activeEntries(for: uclViewModel) }
    private var wcActiveEntries: [DFSEntryRecord] { activeEntries(for: wcViewModel) }

    /// All active DFS entries across all sports (one per entered tournament, excluding settled).
    private var allActiveEntries: [DFSEntryRecord] {
        nbaActiveEntries + nhlActiveEntries + mlbActiveEntries + pgaActiveEntries + eplActiveEntries + uclActiveEntries + wcActiveEntries
    }

    private var hasAnyActiveEntry: Bool {
        !allActiveEntries.isEmpty || !previousInProgressEntries.isEmpty
    }

    /// Tuple pairing a private contest with its owning sport view model so
    /// the row knows which VM to pass to the detail view (different sports
    /// hold their private contests in different DFSViewModel instances).
    private struct PrivatePastEntry: Identifiable {
        let id: UUID
        let viewModel: DFSViewModel
        let contest: DFSPrivateContest
    }

    /// One row in the unified Past Results list — either a public DFS result
    /// or a private contest entry. Sorted by date alongside each other.
    private enum MergedPastRow: Identifiable {
        case `public`(DFSResult)
        case privateContest(PrivatePastEntry)

        var id: String {
            switch self {
            case .public(let r): return "pub-\(r.id.uuidString)"
            case .privateContest(let p): return "priv-\(p.id.uuidString)"
            }
        }
    }

    private func rowDate(_ row: MergedPastRow) -> Date {
        switch row {
        case .public(let r): return r.loggedAt
        case .privateContest(let p): return parsedDate(for: p.contest)
        }
    }

    /// Returns the sport view model whose `sport` matches the prefix of the
    /// given parent tournament ID (e.g. "mlb-..." → mlbViewModel). All VMs
    /// hold the same `myPrivateContests` payload (the fetch is per user, not
    /// per sport), but the detail view's `parentTournament` lookup is per-VM
    /// — so we route each contest to the VM that's most likely to have it.
    private func viewModelForContest(_ contest: DFSPrivateContest) -> DFSViewModel {
        let id = contest.parentTournamentID.lowercased()
        if id.hasPrefix("nhl-") { return nhlViewModel }
        if id.hasPrefix("mlb-") { return mlbViewModel }
        if id.hasPrefix("pga-") { return pgaViewModel }
        if id.hasPrefix("epl-") { return eplViewModel }
        if id.hasPrefix("ucl-") { return uclViewModel }
        if id.hasPrefix("wc-") { return wcViewModel }
        if id.hasPrefix("ufc-") { return ufcViewModel }
        if id.hasPrefix("nfl-") { return nflViewModel }
        if id.hasPrefix("cfb-") { return cfbViewModel }
        return viewModel  // NBA / NCAAM default
    }

    /// Past private contests, deduped by contest ID and sorted newest first
    /// by the date embedded in the parent tournament ID. We pull from a
    /// single VM because `fetchMyDFSPrivateContests` is keyed by userID
    /// (not sport), so every VM holds the same list — iterating all 9 VMs
    /// would produce 9× duplicates.
    private var allPastPrivateContests: [PrivatePastEntry] {
        var entries: [PrivatePastEntry] = []
        var seen: Set<UUID> = []
        for contest in viewModel.myPrivateContests {
            guard !seen.contains(contest.id) else { continue }
            seen.insert(contest.id)
            let owningVM = viewModelForContest(contest)
            // A contest counts as "past" if EITHER its parent slate isn't
            // the currently-displayed one (different date), OR its parent
            // locked more than 6 hours ago (games of any sport are done by
            // then) — without the second clause, a contest entered earlier
            // today would stay pinned in "Active Contests" indefinitely
            // and never surface in Past Results.
            let isPastBySlate = !owningVM.privateContestBelongsToCurrentSlate(contest)
            let isPastByTime: Bool = {
                guard let parent = owningVM.tournaments.first(where: { $0.id == contest.parentTournamentID }) else {
                    return false
                }
                let lockTime = owningVM.lockTimeForTournament(parent)
                return Date().timeIntervalSince(lockTime) > 6 * 3600
            }()
            guard isPastBySlate || isPastByTime else { continue }
            entries.append(PrivatePastEntry(id: contest.id, viewModel: owningVM, contest: contest))
        }
        return entries.sorted { dateString(for: $0.contest) > dateString(for: $1.contest) }
    }

    private func dateString(for contest: DFSPrivateContest) -> String {
        let parts = contest.parentTournamentID.split(separator: "-")
        return parts.first(where: { $0.count == 8 && Int($0) != nil }).map(String.init) ?? ""
    }

    /// Converts a private contest's parent-ID date string to a Date for
    /// merge-sorting with public results' `loggedAt`.
    private func parsedDate(for contest: DFSPrivateContest) -> Date {
        let str = dateString(for: contest)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        return fmt.date(from: str) ?? .distantPast
    }

    private var unifiedMyContestsContent: some View {
        // Aggregate dfsHistory across every sport view model. `propagateHistory`
        // runs once at launch but each VM's own settlement (UFC, NHL, etc.)
        // writes only to its own `dfsHistory` afterwards — without merging
        // here, a UFC result settled mid-session would only appear in the
        // UFC lobby's Recent Results, never in the unified Past Results.
        // Dedupe on `id` since settlement on multiple VMs can produce
        // identical entries.
        let mergedHistory: [DFSResult] = {
            let sources: [DFSViewModel] = [
                viewModel, nhlViewModel, mlbViewModel, pgaViewModel,
                eplViewModel, uclViewModel, wcViewModel,
                ufcViewModel, nflViewModel, cfbViewModel
            ]
            var byID: [UUID: DFSResult] = [:]
            for vm in sources {
                for result in vm.dfsHistory {
                    if byID[result.id] == nil { byID[result.id] = result }
                }
            }
            return Array(byID.values)
        }()
        let allHistory = mergedHistory.sorted {
            if $0.loggedAt != $1.loggedAt { return $0.loggedAt > $1.loggedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        let filteredHistory: [DFSResult] = {
            guard statsSportFilter != "All" else { return allHistory }
            let prefix = statsSportFilter.lowercased() + "-"
            return allHistory.filter { $0.tournamentId?.hasPrefix(prefix) == true }
        }()
        let allPrivates = allPastPrivateContests
        let filteredPrivates: [PrivatePastEntry] = {
            guard statsSportFilter != "All" else { return allPrivates }
            let prefix = statsSportFilter.lowercased() + "-"
            return allPrivates.filter { $0.contest.parentTournamentID.hasPrefix(prefix) }
        }()
        let availableSports: [String] = {
            var sports = Set<String>()
            for result in allHistory {
                sports.insert(sportLabel(for: result))
            }
            return ["All"] + sports.sorted()
        }()
        return ZStack {
            nbaGradientBackground
            if allHistory.isEmpty && allPrivates.isEmpty && !hasAnyActiveEntry {
                VStack(spacing: 14) {
                    Image(systemName: "trophy")
                        .font(.system(size: 44))
                        .foregroundStyle(brandPurple.opacity(0.35))
                    Text("No Past Results")
                        .font(.title3.weight(.semibold))
                    Text("Enter a DFS tournament\nto see your results here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Button {
                        Haptics.light()
                        selectedTab = .today
                    } label: {
                        Text("View Today's Slate")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                            .background(brandPurple)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                    .padding(.top, 4)
                }
                .offset(y: -30)
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        // Active contest cards for each entered tournament per sport
                        ForEach(allActiveEntries, id: \.tournamentID) { entry in
                            inProgressContestCard(entry)
                        }

                        // In-progress entries from previous days / other sources
                        ForEach(previousInProgressEntries) { entry in
                            inProgressContestCard(entry)
                        }

                        // Sport filter pills
                        if availableSports.count > 2 {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(availableSports, id: \.self) { sport in
                                        Button {
                                            Haptics.light()
                                            withAnimation(.easeInOut(duration: 0.15)) {
                                                statsSportFilter = sport
                                            }
                                        } label: {
                                            Text(sport)
                                                .font(.subheadline.weight(.semibold))
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 7)
                                                .background(statsSportFilter == sport ? brandPurple : Color(.systemGray6))
                                                .foregroundStyle(statsSportFilter == sport ? .white : .primary)
                                                .clipShape(Capsule())
                                        }
                                    }
                                }
                            }
                        }

                        // Combined stats (filtered by sport)
                        if !filteredHistory.isEmpty {
                            unifiedContestStatsCard(filteredHistory)
                        }

                        // Merge public and private rows into one date-sorted
                        // list — yesterday's private contest belongs right
                        // next to yesterday's public results, not pinned at
                        // the bottom of the section.
                        let mergedRows: [MergedPastRow] = {
                            var rows: [MergedPastRow] = filteredHistory.map { .public($0) }
                            rows.append(contentsOf: filteredPrivates.map { .privateContest($0) })
                            rows.sort { rowDate($0) > rowDate($1) }
                            return rows
                        }()

                        if !mergedRows.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Past Results")
                                    .font(.headline)

                                ForEach(mergedRows) { row in
                                    switch row {
                                    case .public(let result):
                                        NavigationLink(value: result) {
                                            resultRowWithSport(result)
                                        }
                                        .buttonStyle(.plain)
                                    case .privateContest(let entry):
                                        NavigationLink {
                                            DFSPrivateContestDetailView(viewModel: entry.viewModel, contest: entry.contest)
                                        } label: {
                                            pastPrivateRow(entry: entry)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .padding(16)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
            }
        }
        .task {
            // Compute the user's final FPTS for each past private contest by
            // pulling the parent slate's box scores. Each VM's pool gets its
            // own scores; we kick all of them off in parallel.
            await withTaskGroup(of: Void.self) { group in
                for vm in [viewModel, nhlViewModel, mlbViewModel, pgaViewModel,
                           eplViewModel, uclViewModel, ufcViewModel, nflViewModel, cfbViewModel] {
                    group.addTask { await vm.loadAllPrivateContestFinalScores() }
                }
            }
        }
    }

    private func sportLabel(for result: DFSResult) -> String {
        guard let tid = result.tournamentId else { return "DFS" }
        if tid.hasPrefix("nhl-") { return "NHL" }
        if tid.hasPrefix("ncaam-") { return "NCAAM" }
        if tid.hasPrefix("mlb-") { return "MLB" }
        if tid.hasPrefix("pga-") { return "PGA" }
        if tid.hasPrefix("epl-") { return "EPL" }
        if tid.hasPrefix("ucl-") { return "UCL" }
        if tid.hasPrefix("wc-") { return "WC" }
        if tid.hasPrefix("ufc-") { return "UFC" }
        if tid.hasPrefix("nfl-") { return "NFL" }
        if tid.hasPrefix("cfb-") { return "CFB" }
        return "NBA"
    }

    private func sportColor(for result: DFSResult) -> Color {
        guard let tid = result.tournamentId else { return brandPurple }
        if tid.hasPrefix("nhl-") { return Color(red: 0.1, green: 0.3, blue: 0.6) }
        if tid.hasPrefix("ncaam-") { return Color(red: 0.1, green: 0.3, blue: 0.6) }
        if tid.hasPrefix("mlb-") { return Color(red: 0.0, green: 0.2, blue: 0.5) }
        if tid.hasPrefix("pga-") { return Color(red: 0.0, green: 0.5, blue: 0.2) }
        if tid.hasPrefix("epl-") { return Color(red: 0.3, green: 0.0, blue: 0.5) }
        if tid.hasPrefix("ucl-") { return Color(red: 0.0, green: 0.1, blue: 0.4) }
        if tid.hasPrefix("wc-") { return Color(red: 0.85, green: 0.55, blue: 0.05) }
        if tid.hasPrefix("ufc-") { return Color(red: 0.6, green: 0.1, blue: 0.1) }
        if tid.hasPrefix("nfl-") { return Color(red: 0.0, green: 0.2, blue: 0.5) }
        if tid.hasPrefix("cfb-") { return Color(red: 0.55, green: 0.10, blue: 0.10) }
        return brandPurple
    }

    private func resultRowWithSport(_ result: DFSResult) -> some View {
        HStack(spacing: 12) {
            // Rank badge with field context
            VStack(spacing: 1) {
                Text("#\(result.rank)")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if result.totalEntries > 0 {
                    Text("of \(result.totalEntries)")
                        .font(.system(size: 8, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(minWidth: 44, minHeight: 40)
            .padding(.horizontal, 4)
            .background(result.rank <= 3 ? Color(red: 0.95, green: 0.78, blue: 0.20) : Color(.systemGray4))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(result.tournamentTitle)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if let lineupNum = result.lineupNumber {
                        Text("#\(lineupNum)")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color(.systemGray5))
                            .clipShape(Capsule())
                    }
                    Text(sportLabel(for: result))
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(sportColor(for: result))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                Text("\(result.totalEntries) entries • \(String(format: "%.1f", result.lineupPoints)) pts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(result.loggedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            let rr = recalculatedRR(result)
            Text("\(rr >= 0 ? "+" : "")\(rr)")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(rr >= 0 ? Color.green : .red)

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
    }

    /// Row for a past private contest in the unified Past Results list.
    /// Mirrors `resultRowWithSport` layout (rank badge + title + meta + score)
    /// but reads rank/score from the private contest's own entries instead of
    /// the public `dfsHistory` payload.
    private func pastPrivateRow(entry: PrivatePastEntry) -> some View {
        let vm = entry.viewModel
        let contest = entry.contest
        let myUUID: UUID? = vm.userID.flatMap(UUID.init(uuidString:))
        let entries = vm.privateContestEntries[contest.id] ?? []
        let myEntry: DFSPrivateContestEntry? = {
            guard let me = myUUID else { return nil }
            return entries.first(where: { $0.userID == me })
        }()
        // Prefer the live leaderboard score (in-progress contests where games
        // are still playing — `lineupTotalPoints` is 0 until settlement) → then
        // the box-score-derived final FPTS for settled contests → then the
        // stored value at submission time as a last resort.
        let myLiveRow = (vm.privateContestLeaderboards[contest.id] ?? []).first(where: { $0.isCurrentUser })
        let myFinalScore: Double? = vm.privateContestFinalScores[contest.id]
        let myRank: Int? = {
            if let live = myLiveRow, live.hasSubmitted { return live.rank }
            guard let me = myUUID,
                  let myPts = entries.first(where: { $0.userID == me })?.lineupTotalPoints else { return nil }
            let higher = entries.filter { $0.lineupTotalPoints > myPts }.count
            return higher + 1
        }()
        let totalMembers = vm.privateContestMembers[contest.id]?.count ?? entries.count
        let dateLabel: String = {
            let parts = contest.parentTournamentID.split(separator: "-")
            guard let str = parts.first(where: { $0.count == 8 && Int($0) != nil }) else { return "" }
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd"
            guard let date = fmt.date(from: String(str)) else { return "" }
            return date.formatted(date: .abbreviated, time: .omitted)
        }()
        let sportLabel: String = {
            let prefix = contest.parentTournamentID.split(separator: "-").first.map(String.init) ?? ""
            return prefix.uppercased()
        }()
        return HStack(spacing: 12) {
            VStack(spacing: 1) {
                if let rank = myRank {
                    Text("#\(rank)")
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    if totalMembers > 0 {
                        Text("of \(totalMembers)")
                            .font(.system(size: 8, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                } else {
                    Text("—")
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                }
            }
            .frame(minWidth: 44, minHeight: 40)
            .padding(.horizontal, 4)
            .background((myRank ?? 99) <= 3 ? Color(red: 0.95, green: 0.78, blue: 0.20) : Color(.systemGray4))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(contest.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text("PRIVATE")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(brandPurple)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                    if !sportLabel.isEmpty {
                        Text(sportLabel)
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(.systemGray2))
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                }
                if myEntry != nil {
                    let displayScore = myLiveRow?.points ?? myFinalScore ?? myEntry?.lineupTotalPoints ?? 0
                    Text("\(totalMembers) members • \(String(format: "%.1f", displayScore)) pts")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(totalMembers) members")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !dateLabel.isEmpty {
                    Text(dateLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
    }

    private func unifiedContestStatsCard(_ history: [DFSResult]) -> some View {
        let totalPlayed = history.count
        let totalRR = history.reduce(0) { $0 + recalculatedRR($1) }
        let bestRank = history.map { $0.rank }.min() ?? 0
        let avgPts = history.isEmpty ? 0.0 : history.reduce(0.0) { $0 + $1.lineupPoints } / Double(history.count)

        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            contestStatBox(title: "Played", value: "\(totalPlayed)", icon: "gamecontroller.fill", color: .blue)
            contestStatBox(title: "Net RR", value: "\(totalRR >= 0 ? "+" : "")\(totalRR)", icon: "arrow.up.arrow.down", color: totalRR >= 0 ? .green : .red)
            contestStatBox(title: "Best Rank", value: bestRank > 0 ? "#\(bestRank)" : "-", icon: "star.fill", color: .yellow)
            contestStatBox(title: "Avg Score", value: String(format: "%.1f", avgPts), icon: "chart.line.uptrend.xyaxis", color: .purple)
        }
    }

    // MARK: - My Contests Content (NBA-specific, kept for reference)

    private var nbaGradientBackground: some View {
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
    }

    private var myContestsContent: some View {
        ZStack {
            nbaGradientBackground
            if viewModel.dfsHistory.isEmpty && viewModel.currentUserEntry == nil {
                VStack(spacing: 14) {
                    Image(systemName: "trophy")
                        .font(.system(size: 44))
                        .foregroundStyle(brandPurple.opacity(0.35))
                    Text("No Past Results")
                        .font(.title3.weight(.semibold))
                    Text("Enter today's NBA tournament\nto see your results here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Button {
                        Haptics.light()
                        selectedTab = .today
                    } label: {
                        Text("View Today's Slate")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                            .background(brandPurple)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                    .padding(.top, 4)
                }
                .offset(y: -30)
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        // Show a card for each entered NBA tournament
                        ForEach(nbaActiveEntries, id: \.tournamentID) { entry in
                            inProgressContestCard(entry)
                        }

                        if !viewModel.dfsHistory.isEmpty {
                            contestStatsCard

                            VStack(alignment: .leading, spacing: 10) {
                                Text("Past Results")
                                    .font(.headline)

                                ForEach(viewModel.dfsHistory) { result in
                                    NavigationLink(value: result) {
                                        resultRow(result)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(16)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    // MARK: - Active Contest Card

    private func activeContestCard(_ tournament: DFSTournament) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 6) {
                    if viewModel.isTournamentLocked {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                        Text("LIVE")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    } else {
                        Image(systemName: "clock.fill")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                        Text("UPCOMING")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }

                Spacer()

                Text(tournament.league)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(brandPurple)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }

            Text(tournament.title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)

            if let result = viewModel.latestResult {
                HStack(spacing: 20) {
                    VStack(spacing: 2) {
                        Text("RANK")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.6))
                        Text("#\(result.rank)")
                            .font(.title2.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    VStack(spacing: 2) {
                        Text("SCORE")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.6))
                        Text(String(format: "%.1f", result.lineupPoints))
                            .font(.title2.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    Spacer()
                    VStack(spacing: 2) {
                        Text("ENTRIES")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.6))
                        Text("\(viewModel.remoteEntries.count)")
                            .font(.title2.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            } else {
                HStack {
                    Text("Your lineup is set")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Text("\(viewModel.selectedPlayers.count) players")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                }
            }

            Button {
                Haptics.light()
                selectedSport = .nba
                selectedTab = .today
            } label: {
                Text(viewModel.isTournamentLocked ? "View Live Contest" : "View Lobby")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(.white.opacity(0.2))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.12, blue: 0.22),
                    Color(red: 0.15, green: 0.20, blue: 0.35)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
    }

    // MARK: - Contest Stats Card

    private var contestStatsCard: some View {
        let history = viewModel.dfsHistory
        let totalPlayed = history.count
        let totalRR = history.reduce(0) { $0 + recalculatedRR($1) }
        let bestRank = history.map { $0.rank }.min() ?? 0
        let avgPts = history.isEmpty ? 0.0 : history.reduce(0.0) { $0 + $1.lineupPoints } / Double(history.count)

        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            contestStatBox(title: "Played", value: "\(totalPlayed)", icon: "gamecontroller.fill", color: .blue)
            contestStatBox(title: "Net RR", value: "\(totalRR >= 0 ? "+" : "")\(totalRR)", icon: "arrow.up.arrow.down", color: totalRR >= 0 ? .green : .red)
            contestStatBox(title: "Best Rank", value: bestRank > 0 ? "#\(bestRank)" : "-", icon: "star.fill", color: .yellow)
            contestStatBox(title: "Avg Score", value: String(format: "%.1f", avgPts), icon: "chart.line.uptrend.xyaxis", color: .purple)
        }
    }

    private func contestStatBox(title: String, value: String, icon: String, color: Color) -> some View {
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

    /// Return the stored rrDelta which accounts for tie-pooling.
    /// Previously this recalculated from rank alone (non-pooled), which
    /// gave incorrect values when multiple entries tied at the same rank.
    private func recalculatedRR(_ result: DFSResult) -> Int {
        result.rrDelta
    }

    // MARK: - Result Row

    private func resultRow(_ result: DFSResult) -> some View {
        HStack(spacing: 12) {
            // Rank badge with field context
            VStack(spacing: 1) {
                Text("#\(result.rank)")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if result.totalEntries > 0 {
                    Text("of \(result.totalEntries)")
                        .font(.system(size: 8, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(minWidth: 44, minHeight: 40)
            .padding(.horizontal, 4)
            .background(result.rank <= 3 ? Color(red: 0.95, green: 0.78, blue: 0.20) : Color(.systemGray4))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(result.tournamentTitle)
                    .font(.subheadline.weight(.medium))
                Text("\(result.totalEntries) entries • \(String(format: "%.1f", result.lineupPoints)) pts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(result.loggedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            let rr = recalculatedRR(result)
            Text("\(rr >= 0 ? "+" : "")\(rr)")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(rr >= 0 ? Color.green : .red)

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
    }

    /// Returns the correct DFSViewModel for a given result based on tournament ID prefix
    private func viewModelForResult(_ result: DFSResult) -> DFSViewModel {
        if let tid = result.tournamentId {
            if tid.hasPrefix("nhl-") { return nhlViewModel }
            if tid.hasPrefix("ncaam-") { return nhlViewModel }
            if tid.hasPrefix("mlb-") { return mlbViewModel }
            if tid.hasPrefix("pga-") { return pgaViewModel }
            if tid.hasPrefix("epl-") { return eplViewModel }
            if tid.hasPrefix("ucl-") { return uclViewModel }
            if tid.hasPrefix("wc-") { return wcViewModel }
            if tid.hasPrefix("ufc-") { return ufcViewModel }
            if tid.hasPrefix("nfl-") { return nflViewModel }
            if tid.hasPrefix("cfb-") { return cfbViewModel }
        }
        return viewModel
    }

    private func refreshAuthAndSync() async {
        await auth.refreshSessionIfNeeded()
        viewModel.accessToken = auth.accessToken
        viewModel.userID = auth.userID
        viewModel.userEmail = auth.userEmail
        nhlViewModel.accessToken = auth.accessToken
        nhlViewModel.userID = auth.userID
        nhlViewModel.userEmail = auth.userEmail
        mlbViewModel.accessToken = auth.accessToken
        mlbViewModel.userID = auth.userID
        mlbViewModel.userEmail = auth.userEmail
        pgaViewModel.accessToken = auth.accessToken
        pgaViewModel.userID = auth.userID
        pgaViewModel.userEmail = auth.userEmail
        eplViewModel.accessToken = auth.accessToken
        eplViewModel.userID = auth.userID
        eplViewModel.userEmail = auth.userEmail
        uclViewModel.accessToken = auth.accessToken
        uclViewModel.userID = auth.userID
        uclViewModel.userEmail = auth.userEmail
        wcViewModel.accessToken = auth.accessToken
        wcViewModel.userID = auth.userID
        wcViewModel.userEmail = auth.userEmail
        ufcViewModel.accessToken = auth.accessToken
        ufcViewModel.userID = auth.userID
        ufcViewModel.userEmail = auth.userEmail
        nflViewModel.accessToken = auth.accessToken
        nflViewModel.userID = auth.userID
        nflViewModel.userEmail = auth.userEmail
        cfbViewModel.accessToken = auth.accessToken
        cfbViewModel.userID = auth.userID
        cfbViewModel.userEmail = auth.userEmail
    }

    /// Fetch the user's recent entries and keep only those for tournaments not currently
    /// loaded by any view model and not already settled in history.
    /// Filters out entries older than 3 days to avoid showing stale contests.
    private func loadPreviousInProgressEntries() async {
        guard let userID = auth.userID, let token = auth.accessToken else { return }
        do {
            let allEntries = try await SupabaseService.shared.fetchUserRecentEntries(userID: userID, accessToken: token)

            // IDs of tournaments already tracked by the live view models (all entered, not just active)
            let currentTournamentIDs: Set<String> = viewModel.enteredTournamentIDs
                .union(nhlViewModel.enteredTournamentIDs)
                .union(mlbViewModel.enteredTournamentIDs)
                .union(pgaViewModel.enteredTournamentIDs)
                .union(eplViewModel.enteredTournamentIDs)
                .union(uclViewModel.enteredTournamentIDs)
                .union(wcViewModel.enteredTournamentIDs)
                .union(ufcViewModel.enteredTournamentIDs)
                .union(nflViewModel.enteredTournamentIDs)
                .union(cfbViewModel.enteredTournamentIDs)

            // IDs of tournaments that are already settled (appear in history)
            let settledIDs = Set(viewModel.dfsHistory.compactMap { $0.tournamentId })

            // Also include locally-settled tournament IDs (may not yet appear in history)
            let locallySettledIDs = viewModel.settledTournaments

            // Only show entries from the last 3 days to avoid stale cards
            let staleThreshold = Date().addingTimeInterval(-3 * 24 * 3600)

            previousInProgressEntries = allEntries.filter { entry in
                !currentTournamentIDs.contains(entry.tournamentID)
                && !settledIDs.contains(entry.tournamentID)
                && !locallySettledIDs.contains(entry.tournamentID)
                && (entry.submittedAt ?? .distantPast) > staleThreshold
            }
        } catch {
            print("[DFS] Failed to load previous in-progress entries: \(error.localizedDescription)")
        }
    }

    private func sportLabelForTournament(_ tournamentID: String) -> String {
        if tournamentID.hasPrefix("nhl-") { return "NHL" }
        if tournamentID.hasPrefix("ncaam-") { return "NCAAM" }
        if tournamentID.hasPrefix("mlb-") { return "MLB" }
        if tournamentID.hasPrefix("pga-") { return "PGA" }
        if tournamentID.hasPrefix("epl-") { return "EPL" }
        if tournamentID.hasPrefix("ucl-") { return "UCL" }
        if tournamentID.hasPrefix("wc-") { return "WC" }
        if tournamentID.hasPrefix("ufc-") { return "UFC" }
        if tournamentID.hasPrefix("nfl-") { return "NFL" }
        if tournamentID.hasPrefix("cfb-") { return "CFB" }
        return "NBA"
    }

    private func sportColorForTournament(_ tournamentID: String) -> Color {
        if tournamentID.hasPrefix("nhl-") { return Color(red: 0.1, green: 0.3, blue: 0.6) }
        if tournamentID.hasPrefix("ncaam-") { return Color(red: 0.1, green: 0.3, blue: 0.6) }
        if tournamentID.hasPrefix("mlb-") { return Color(red: 0.0, green: 0.2, blue: 0.5) }
        if tournamentID.hasPrefix("pga-") { return Color(red: 0.0, green: 0.5, blue: 0.2) }
        if tournamentID.hasPrefix("epl-") { return Color(red: 0.3, green: 0.0, blue: 0.5) }
        if tournamentID.hasPrefix("ucl-") { return Color(red: 0.0, green: 0.1, blue: 0.4) }
        if tournamentID.hasPrefix("wc-") { return Color(red: 0.85, green: 0.55, blue: 0.05) }
        if tournamentID.hasPrefix("ufc-") { return Color(red: 0.6, green: 0.1, blue: 0.1) }
        if tournamentID.hasPrefix("nfl-") { return Color(red: 0.0, green: 0.2, blue: 0.5) }
        if tournamentID.hasPrefix("cfb-") { return Color(red: 0.3, green: 0.1, blue: 0.5) }
        return brandPurple
    }

    private func gradientForTournament(_ tournamentID: String) -> LinearGradient {
        if tournamentID.hasPrefix("nhl-") {
            return LinearGradient(
                colors: [Color(red: 0.08, green: 0.15, blue: 0.35), Color(red: 0.12, green: 0.25, blue: 0.50)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
        if tournamentID.hasPrefix("ncaam-") {
            return LinearGradient(
                colors: [Color(red: 0.08, green: 0.15, blue: 0.35), Color(red: 0.12, green: 0.25, blue: 0.50)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
        if tournamentID.hasPrefix("mlb-") {
            return LinearGradient(
                colors: [Color(red: 0.05, green: 0.10, blue: 0.30), Color(red: 0.08, green: 0.18, blue: 0.45)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
        if tournamentID.hasPrefix("pga-") {
            return LinearGradient(
                colors: [Color(red: 0.05, green: 0.25, blue: 0.12), Color(red: 0.08, green: 0.35, blue: 0.18)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
        if tournamentID.hasPrefix("epl-") {
            return LinearGradient(
                colors: [Color(red: 0.2, green: 0.0, blue: 0.35), Color(red: 0.35, green: 0.05, blue: 0.50)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
        if tournamentID.hasPrefix("ucl-") {
            return LinearGradient(
                colors: [Color(red: 0.0, green: 0.05, blue: 0.25), Color(red: 0.05, green: 0.10, blue: 0.40)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
        if tournamentID.hasPrefix("wc-") {
            return LinearGradient(
                colors: [Color(red: 0.55, green: 0.30, blue: 0.0), Color(red: 0.85, green: 0.55, blue: 0.05)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
        if tournamentID.hasPrefix("ufc-") {
            return LinearGradient(
                colors: [Color(red: 0.35, green: 0.05, blue: 0.05), Color(red: 0.50, green: 0.10, blue: 0.10)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
        if tournamentID.hasPrefix("nfl-") {
            return LinearGradient(
                colors: [Color(red: 0.0, green: 0.10, blue: 0.30), Color(red: 0.05, green: 0.20, blue: 0.45)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
        if tournamentID.hasPrefix("cfb-") {
            return LinearGradient(
                colors: [Color(red: 0.20, green: 0.05, blue: 0.30), Color(red: 0.30, green: 0.10, blue: 0.45)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
        return LinearGradient(
            colors: [Color(red: 0.10, green: 0.12, blue: 0.22), Color(red: 0.15, green: 0.20, blue: 0.35)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    /// Builds a human-readable title from tournament ID, e.g. "nhl-20260320" → "NHL • Mar 20" (also handles legacy "ncaam-20260320" → "NCAAM • Mar 20")
    private func titleForTournament(_ tournamentID: String) -> String {
        let sport = sportLabelForTournament(tournamentID)
        // Parse date from tournament ID suffix (format: sport-YYYYMMDD)
        let parts = tournamentID.split(separator: "-")
        if let dateStr = parts.last, dateStr.count == 8,
           let year = Int(dateStr.prefix(4)),
           let month = Int(dateStr.dropFirst(4).prefix(2)),
           let day = Int(dateStr.suffix(2)) {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "America/New_York")!
            if let date = cal.date(from: DateComponents(year: year, month: month, day: day)) {
                let fmt = DateFormatter()
                fmt.dateFormat = "MMM d"
                return "\(sport) DFS • \(fmt.string(from: date))"
            }
        }
        return "\(sport) DFS"
    }

    /// Determine whether a previous-entry tournament is still upcoming (today's date, games not started)
    private func isEntryUpcoming(_ entry: DFSEntryRecord) -> Bool {
        let tid = entry.tournamentID
        // Check if any view model knows the lock time for this tournament
        let lockTime: Date? = [viewModel, nhlViewModel, mlbViewModel, pgaViewModel, eplViewModel, uclViewModel, ufcViewModel, nflViewModel, cfbViewModel].lazy.compactMap { vm in
            vm.tournaments.first(where: { $0.id == tid }).map { vm.lockTimeForTournament($0) }
        }.first
        if let lt = lockTime {
            return Date() < lt
        }
        // Fallback: compare tournament date to today
        let prefixLen = tid.hasPrefix("ncaam-") ? 6 : (tid.components(separatedBy: "-").first?.count ?? 3) + 1
        let dateStr = String(tid.dropFirst(prefixLen).prefix(8))
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        fmt.timeZone = TimeZone(identifier: "America/New_York")
        guard let tournamentDate = fmt.date(from: dateStr) else { return false }
        let todayStr = fmt.string(from: Date())
        guard let today = fmt.date(from: todayStr) else { return false }
        // For today's tournaments, they're "upcoming" only if submitted recently
        // (within last 5 minutes — likely just submitted and game hasn't started)
        if tournamentDate == today {
            if let submitted = entry.submittedAt {
                return Date().timeIntervalSince(submitted) < 300
            }
            return false  // Today's tournament with no recent submit = already started
        }
        return tournamentDate > today
    }

    /// Returns the appropriate view model for a tournament ID based on sport prefix.
    private func viewModelForTournament(_ tournamentID: String) -> DFSViewModel? {
        if tournamentID.hasPrefix("nba-") || tournamentID.hasPrefix("ncaam-") { return viewModel }
        if tournamentID.hasPrefix("nhl-") { return nhlViewModel }
        if tournamentID.hasPrefix("mlb-") { return mlbViewModel }
        if tournamentID.hasPrefix("pga-") { return pgaViewModel }
        if tournamentID.hasPrefix("epl-") { return eplViewModel }
        if tournamentID.hasPrefix("ucl-") { return uclViewModel }
        if tournamentID.hasPrefix("wc-") { return wcViewModel }
        if tournamentID.hasPrefix("ufc-") { return ufcViewModel }
        if tournamentID.hasPrefix("nfl-") { return nflViewModel }
        if tournamentID.hasPrefix("cfb-") { return cfbViewModel }
        return nil
    }

    /// Computes a live score for a previous in-progress entry using the appropriate view model's live data.
    private func liveScoreForEntry(_ entry: DFSEntryRecord) -> Double {
        guard let vm = viewModelForTournament(entry.tournamentID) else {
            return entry.lineupTotalPoints ?? 0
        }
        // Check if this tournament is a single game (has "sg" in the ID)
        let isSG = entry.tournamentID.contains("-sg-")
        var total = 0.0
        for (i, pid) in entry.lineupPlayerIDs.enumerated() {
            let pts = vm.livePlayerPoints[pid] ?? 0
            total += (isSG && i == 0) ? pts * 1.5 : pts
        }
        // If live data returned 0 but DB has a score, use the DB score
        if total == 0 { return entry.lineupTotalPoints ?? 0 }
        return total
    }

    /// Builds a descriptive title for a tournament from its ID (e.g. "NHL H2H" or "NBA 3-Man SG").
    private func typeAndTitleForTournament(_ tournamentID: String) -> (type: String, title: String) {
        let sport = sportLabelForTournament(tournamentID)
        let entryCount = DFSViewModel.entryCountFromTournamentID(tournamentID)
        let isSG = tournamentID.contains("-sg-")
        let prefix = isSG ? "SG " : ""
        let typeLabel: String
        switch entryCount {
        case 2: typeLabel = "\(prefix)H2H"
        case 3: typeLabel = "\(prefix)3-Man"
        case 5: typeLabel = "\(prefix)5-Man WTA"
        case 10: typeLabel = "\(prefix)10-Man"
        default: typeLabel = "\(prefix)\(entryCount)-Entry"
        }
        return (typeLabel, "\(sport) \(typeLabel)")
    }

    private func inProgressContestCard(_ entry: DFSEntryRecord) -> some View {
        let upcoming = isEntryUpcoming(entry)
        let entryCount = DFSViewModel.entryCountFromTournamentID(entry.tournamentID)
        let (typeLabel, fullTitle) = typeAndTitleForTournament(entry.tournamentID)
        let liveScore = liveScoreForEntry(entry)
        let vm = viewModelForTournament(entry.tournamentID) ?? viewModel
        let lineupNumber = entry.lineupNumber ?? 1

        // Try to get rank from cached live ranks
        let rank: Int? = {
            let cacheKey = "\(entry.tournamentID)-\(lineupNumber)"
            if let cached = vm.cachedLiveRanks[cacheKey] { return cached }
            return nil
        }()

        return NavigationLink {
            DFSLiveContestView(viewModel: vm)
                .task {
                    vm.selectTournament(entry.tournamentID, lineupNumber: lineupNumber)
                    // Ensure field is rebuilt if cache didn't exist for this tournament
                    if vm.leaderboardEntries.isEmpty {
                        await vm.refreshLive()
                    }
                }
        } label: {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 6) {
                    if upcoming {
                        Image(systemName: "clock.fill")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                        Text("UPCOMING")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    } else {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                        Text("LIVE")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }

                Spacer()

                HStack(spacing: 6) {
                    Text(typeLabel)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.white.opacity(0.2))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())

                    Text(sportLabelForTournament(entry.tournamentID))
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(sportColorForTournament(entry.tournamentID))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
            }

            Text(fullTitle)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)

            HStack(spacing: 20) {
                if let rank {
                    VStack(spacing: 2) {
                        Text("RANK")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.6))
                        Text("#\(rank)")
                            .font(.title2.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                VStack(spacing: 2) {
                    Text("SCORE")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    Text(String(format: "%.1f", liveScore))
                        .font(.title2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()
                }
                VStack(spacing: 2) {
                    Text("FIELD")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("\(entryCount)")
                        .font(.title2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()
                }
                Spacer()
            }

        }
        .padding(20)
        .background(gradientForTournament(entry.tournamentID))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading today's slate...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "sportscourt")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("No DFS Slate Available")
                .font(.title3.weight(.semibold))

            if let error = viewModel.error {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            } else {
                Text("There are no NBA games on today's slate. Check back later!")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Button {
                Task {
                    await viewModel.loadSlate(force: true)
                }
            } label: {
                Text("Try Again")
                    .font(.headline)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(brandPurple)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    }

    /// After a DFSViewModel syncs history, copy its updated dfsHistoryData to all other VMs
    /// so the next sync sees the combined entries.
    /// Per-sport init pipeline — loads the slate, the user's entries, settles
    /// anything pending, refreshes live scoring, and pre-caches entered tournaments.
    /// History sync is intentionally NOT included here because it's already
    /// done once globally before this helper is called for each sport (the
    /// payload is shared, so syncing 9 times sequentially was wasted work).
    private func initSportPipeline(_ vm: DFSViewModel) async {
        // Kick off the private-contests fetch in parallel — it's a single quick
        // query and doesn't depend on the slate. Without this, private contests
        // only load when the user scrolls to the lobby's Private Contests
        // section, so they never appear in Active Contests on first launch.
        async let privates: () = vm.loadMyPrivateContests()
        await vm.loadSlateIfNeeded()
        await vm.fetchEntriesIfNeeded()
        // Settlement iterates past tournaments doing network calls (can be
        // 10–30s with many entered tournaments). It writes to history/settled
        // tables, none of which are needed to paint the active contest card,
        // so it runs in the background.
        Task.detached { [vm] in
            await vm.checkAndSettleUnsettledTournaments()
        }
        await vm.refreshLive()
        // Pre-cache OTHER entered tournaments runs in the background — it can
        // take 30–60s on a slow refresh cycle (2000-bot regeneration per
        // contest), and blocking on it kept the shimmer up far longer than
        // needed. The user-visible active contest is already populated by
        // refreshLive above; other cards' real data trickles in as pre-cache
        // finishes each one.
        Task.detached { [vm] in
            await vm.preCacheAllEnteredTournaments()
        }
        _ = await privates
    }

    private func propagateHistory(from source: DFSViewModel) {
        let data = source.dfsHistoryData
        viewModel.dfsHistoryData = data
        nhlViewModel.dfsHistoryData = data
        mlbViewModel.dfsHistoryData = data
        pgaViewModel.dfsHistoryData = data
        eplViewModel.dfsHistoryData = data
        uclViewModel.dfsHistoryData = data
        ufcViewModel.dfsHistoryData = data
        nflViewModel.dfsHistoryData = data
        cfbViewModel.dfsHistoryData = data
    }
}

// MARK: - Shimmer

private struct ShimmerModifier: ViewModifier {
    // Shared cycle duration — every shimmer in the app derives its phase from
    // the same wall clock, so cards that appear at different times still
    // animate in lockstep instead of starting their own cycle on mount.
    private static let cycle: Double = 1.4

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    TimelineView(.animation) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        let progress = (t.truncatingRemainder(dividingBy: Self.cycle)) / Self.cycle
                        let phase = CGFloat(progress * 2.5 - 1.0) // -1.0 → 1.5

                        // Gray-on-gray shimmer: stays in the gray family so the
                        // effect reads as a subtle highlight, not a white flash.
                        LinearGradient(
                            gradient: Gradient(stops: [
                                .init(color: Color(white: 0.85).opacity(0.0), location: 0.0),
                                .init(color: Color(white: 0.78).opacity(0.9), location: 0.5),
                                .init(color: Color(white: 0.85).opacity(0.0), location: 1.0)
                            ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .frame(width: geo.size.width * 2, height: geo.size.height)
                        .offset(x: geo.size.width * phase)
                    }
                }
            )
            .clipped()
    }
}

extension View {
    func shimmering() -> some View {
        modifier(ShimmerModifier())
    }
}
