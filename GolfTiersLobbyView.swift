import SwiftUI

struct GolfTiersLobbyView: View {
    @Bindable var viewModel: GolfTiersViewModel
    @State private var selectedTier: Int = 1
    @State private var showCreateGroup = false
    @State private var showJoinGroup = false
    @State private var showGroupsList = false
    @State private var newGroupName = ""
    @State private var joinCode = ""

    private var darkGreen: Color {
        Color(red: 0.05, green: 0.45, blue: 0.25)
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isLoading && !viewModel.hasAttemptedLoad {
                loadingView
            } else if viewModel.noActiveMajor {
                noActiveMajorView
            } else if viewModel.awaitingField {
                awaitingFieldView
            } else if viewModel.isSettled {
                settledView
            } else if viewModel.isLocked {
                GolfTiersLiveView(viewModel: viewModel)
            } else if let error = viewModel.error, viewModel.tiers.isEmpty {
                errorView(error)
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        heroCard
                        picksOverview
                        tierSelector
                        playerList
                        submitButton
                        groupsSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
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
        .toolbar {
            // Groups stay reachable after lock — the lobby swaps its body to
            // the live view during the tournament, which used to strand the
            // in-scroll groups section (same bug WC had).
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showGroupsList = true
                } label: {
                    Image(systemName: "person.3.fill")
                        .foregroundStyle(darkGreen)
                }
            }
        }
        .task {
            if !viewModel.hasAttemptedLoad {
                await viewModel.loadTournament()
            } else {
                await viewModel.recheckStatusIfNeeded()
            }
            await viewModel.loadMyGroups()
            if viewModel.isSettled {
                await viewModel.loadSettledHistory()
            }
        }
        .sheet(isPresented: $showCreateGroup) {
            createGroupSheet
        }
        .sheet(isPresented: $showJoinGroup) {
            joinGroupSheet
        }
        .sheet(isPresented: $showGroupsList) { groupsListSheet }
    }

    // MARK: - Groups List Sheet (toolbar-accessed quick view)

    private var groupsListSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if viewModel.myGroups.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "person.3")
                                .font(.system(size: 40))
                                .foregroundStyle(.secondary)
                            Text("No private groups yet")
                                .font(.headline)
                            Text("Create or join a group to track standings against friends.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                    } else {
                        ForEach(viewModel.myGroups) { group in
                            NavigationLink {
                                GolfTiersGroupDetailView(viewModel: viewModel, group: group)
                            } label: {
                                HStack {
                                    Image(systemName: "person.3.fill")
                                        .foregroundStyle(darkGreen)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(group.name)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)
                                        Text("Code \(group.inviteCode)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(12)
                                .background(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    HStack(spacing: 10) {
                        Button {
                            showGroupsList = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                showCreateGroup = true
                            }
                        } label: {
                            Label("Create", systemImage: "plus.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(darkGreen.opacity(0.1))
                                .foregroundStyle(darkGreen)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }

                        Button {
                            showGroupsList = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                showJoinGroup = true
                            }
                        } label: {
                            Label("Join", systemImage: "link.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.blue.opacity(0.1))
                                .foregroundStyle(.blue)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .padding(.top, 8)
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Private Groups")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showGroupsList = false }
                }
            }
        }
    }

    // MARK: - Hero Card

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("PGA MAJOR")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(darkGreen)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: "person.2.fill")
                        .font(.caption2)
                    Text("\(viewModel.tournament?.entryCount ?? 1000) entries")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(.white.opacity(0.8))
            }

            Text(viewModel.tournament?.title ?? "Golf Major Tiers")
                .font(.title2.bold())
                .foregroundStyle(.white)

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("FORMAT")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("Pick 1 per tier")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("SCORING")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("Best 4 of 6")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }

                Spacer()

                if let remaining = viewModel.lockTimeRemaining {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("LOCKS IN")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.6))
                        Text(remaining)
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                    }
                }
            }

            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.caption2)
                Text("Thu-Sun  \u{2022}  Lowest score-to-par wins")
                    .font(.caption)
            }
            .foregroundStyle(.white.opacity(0.7))
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

    // MARK: - Picks Overview

    private var picksOverview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("YOUR PICKS")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(1...6, id: \.self) { tier in
                    pickSlot(tier: tier)
                }
            }
        }
    }

    private func pickSlot(tier: Int) -> some View {
        let golfer = viewModel.userPicks[tier]
        let isFilled = golfer != nil

        return VStack(spacing: 4) {
            Text("T\(tier)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isFilled ? .white : .secondary)

            if let golfer {
                Text(lastName(golfer.name))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            } else {
                Image(systemName: "plus")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .background(isFilled ? darkGreen : Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture {
            selectedTier = tier
        }
    }

    // MARK: - Tier Selector

    private var tierSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(1...6, id: \.self) { tier in
                    let isSelected = selectedTier == tier
                    let tierGolfers = tier <= viewModel.tiers.count ? viewModel.tiers[tier - 1] : []

                    Button {
                        Haptics.light()
                        selectedTier = tier
                    } label: {
                        VStack(spacing: 2) {
                            Text("Tier \(tier)")
                                .font(.subheadline.weight(isSelected ? .bold : .medium))
                            Text("\(tierGolfers.count) golfers")
                                .font(.system(size: 9))
                        }
                        .foregroundStyle(isSelected ? .white : .primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(isSelected ? darkGreen : Color(.systemGray6))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Player List

    private var playerList: some View {
        let tierIndex = selectedTier - 1
        let golfers = tierIndex < viewModel.tiers.count ? viewModel.tiers[tierIndex] : []
        let selectedGolferID = viewModel.userPicks[selectedTier]?.id

        return LazyVStack(spacing: 0) {
            ForEach(Array(golfers.enumerated()), id: \.element.id) { index, golfer in
                golferRow(golfer: golfer, isSelected: golfer.id == selectedGolferID, rank: index + 1)
            }
        }
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
    }

    private func golferRow(golfer: GolfTiersGolfer, isSelected: Bool, rank: Int) -> some View {
        Button {
            Haptics.light()
            if isSelected {
                viewModel.removePlayer(tier: selectedTier)
            } else {
                viewModel.selectPlayer(tier: selectedTier, golfer: golfer)
            }
        } label: {
            HStack(spacing: 12) {
                // Rank
                Text("\(rank)")
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .center)

                // Golfer headshot
                if let imageURL = golfer.imageURL, let url = URL(string: imageURL) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 36, height: 36)
                    .clipShape(Circle())
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                }

                // Golfer info
                VStack(alignment: .leading, spacing: 2) {
                    Text(golfer.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(golfer.country)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("OWGR #\(golfer.owgrRank)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Selection indicator
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? darkGreen : Color(.systemGray4))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isSelected ? darkGreen.opacity(0.08) : .clear)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Submit Button

    @ViewBuilder
    private var submitButton: some View {
        if !viewModel.isLocked {
            Button {
                Haptics.medium()
                Task {
                    await viewModel.submitPicks()
                }
            } label: {
                HStack(spacing: 8) {
                    if viewModel.isSubmitting {
                        ProgressView()
                            .tint(.white)
                    }
                    Text(viewModel.hasSubmitted ? "Update Picks" : "Lock In Picks")
                        .font(.headline.weight(.bold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(viewModel.allPicksMade ? darkGreen : Color(.systemGray4))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(!viewModel.allPicksMade || viewModel.isSubmitting)

            if !viewModel.allPicksMade {
                Text("Select 1 golfer from each of the 6 tiers to submit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let error = viewModel.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Loading & Error

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading major field...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Shown when today isn't inside any major's pick/play/results window.
    /// Tells the user the next upcoming major and a rough countdown, without
    /// dragging them into a tiers UI for whichever regular Tour event ESPN
    /// happens to be running.
    /// Inside a major's pick window, but ESPN hasn't published the field yet
    /// (its scoreboard is still on the previous Tour event).
    private var awaitingFieldView: some View {
        let majorID = GolfTiersTournament.activeMajorID(now: Date()) ?? GolfTiersTournament.currentMajorID()
        let title = GolfTiersTournament.majorTitle(for: majorID)
        return VStack(spacing: 16) {
            Image(systemName: "hourglass")
                .font(.system(size: 44))
                .foregroundStyle(darkGreen.opacity(0.7))
            Text(title)
                .font(.title3.weight(.semibold))
            Text("Signups will open when the tournament field is announced. Check back closer to the event!")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var noActiveMajorView: some View {
        let upcomingID: String? = {
            let now = Date()
            let cal = Calendar.current
            let year = cal.component(.year, from: now)
            let mmdd = cal.component(.month, from: now) * 100 + cal.component(.day, from: now)
            let sequence: [(id: String, opens: Int)] = [
                ("masters-\(year)", 402),
                ("pga-championship-\(year)", 507),
                ("us-open-\(year)", 611),
                ("the-open-\(year)", 709),
                ("masters-\(year + 1)", 402 + 10000)
            ]
            return sequence.first(where: { $0.opens > mmdd })?.id
        }()
        let upcomingTitle = upcomingID.map { GolfTiersTournament.majorTitle(for: $0) } ?? "Next Major"
        return VStack(spacing: 16) {
            Image(systemName: "flag.checkered")
                .font(.system(size: 44))
                .foregroundStyle(darkGreen.opacity(0.7))
            Text("No Major This Week")
                .font(.title3.weight(.semibold))
            Text("Golf Tiers is only active during the four PGA majors. Check back when \(upcomingTitle) opens for picks.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await viewModel.loadTournament() }
            }
            .buttonStyle(.borderedProminent)
            .tint(darkGreen)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Settled View (History)

    private var settledView: some View {
        ScrollView {
            VStack(spacing: 16) {
                // ── Current settled tournament hero ──
                // Only show the big FINAL banner when the major just wrapped (within ~5 days
                // of lockTime). After that the result belongs in the MAJOR RESULTS history
                // list below — keeping the hero around makes the lobby feel stuck on a
                // tournament that ended weeks ago.
                if let tournament = viewModel.tournament, tournament.isSettled,
                   let lock = tournament.lockTime,
                   Date().timeIntervalSince(lock) < 5 * 24 * 3600 {
                    settledHeroCard(tournament)
                }

                // ── Past major results ──
                if !viewModel.settledTournaments.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text("MAJOR RESULTS")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(viewModel.settledTournaments.count) major\(viewModel.settledTournaments.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }

                        VStack(spacing: 0) {
                            ForEach(Array(viewModel.settledTournaments.enumerated()), id: \.element.id) { index, tournament in
                                NavigationLink {
                                    GolfTiersSettledDetailView(viewModel: viewModel, tournamentRecord: tournament)
                                } label: {
                                    settledHistoryRow(tournament)
                                }
                                .buttonStyle(.plain)
                                if index < viewModel.settledTournaments.count - 1 {
                                    Divider().padding(.leading, 40)
                                }
                            }
                        }
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
                    }
                } else if viewModel.isLoadingHistory {
                    VStack(spacing: 8) {
                        ProgressView().tint(.secondary)
                        Text("Loading history...")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                } else if !(viewModel.tournament?.isSettled ?? false) {
                    // Only show the empty "no results yet" state when there isn't already a
                    // current-settled hero card above — otherwise the hero IS the result.
                    HStack(spacing: 10) {
                        Image(systemName: "trophy")
                            .foregroundStyle(.secondary)
                        Text("No major results yet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(14)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                // ── Groups ──
                groupsSection

                // ── Next Major section ──
                if let nextID = GolfTiersTournament.nextMajorID() {
                    nextMajorCard(nextID)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
    }

    private func settledHeroCard(_ tournament: GolfTiersTournament) -> some View {
        let result = viewModel.settledResults[tournament.id]
        let lbEntry = viewModel.leaderboardEntries.first(where: { $0.isCurrentUser })
        let rank = result?.rank ?? lbEntry?.rank ?? viewModel.userRank
        let totalEntries = tournament.entryCount
        let rrDelta = result?.rrDelta ?? 0
        let scoreDisplay: String = {
            if let result { return GolfTiersEngine.scoreToParDisplay(Int(result.totalPoints)) }
            if let lbEntry { return GolfTiersEngine.scoreToParDisplay(lbEntry.totalScore) }
            return viewModel.userTotalScoreDisplay
        }()

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.white)
                    Text("FINAL")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                }
                Spacer()
                Text(tournament.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))
            }

            HStack(spacing: 24) {
                VStack(spacing: 2) {
                    Text("YOUR RANK")
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
                        Text("--")
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

                Spacer()

                VStack(spacing: 2) {
                    Text("RR")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("\(rrDelta >= 0 ? "+" : "")\(rrDelta)")
                        .font(.title.weight(.bold).monospacedDigit())
                        .foregroundStyle(rrDelta >= 0 ? Color(red: 0.4, green: 1.0, blue: 0.5) : Color(red: 1.0, green: 0.5, blue: 0.5))
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

    private func settledHistoryRow(_ tournament: GolfTiersTournamentRecord) -> some View {
        let result = viewModel.settledResults[tournament.id]
        let totalEntries = tournament.entryCount ?? 1000
        let date = tournament.lockTime ?? tournament.createdAt

        return HStack(spacing: 10) {
            Image(systemName: "figure.golf")
                .font(.caption)
                .foregroundStyle(darkGreen)
                .frame(width: 24, height: 24)
                .background(darkGreen.opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("GOLF")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(darkGreen.opacity(0.15))
                        .foregroundStyle(darkGreen)
                        .clipShape(Capsule())
                    Text(tournament.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    if let result {
                        Text("#\(result.rank)/\(totalEntries)")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                        Text("\u{2022}")
                            .foregroundStyle(.tertiary)
                        Text(GolfTiersEngine.scoreToParDisplay(Int(result.totalPoints)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No entry")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let date {
                        Text("\u{2022}")
                            .foregroundStyle(.tertiary)
                        Text(date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if let result {
                Text("\(result.rrDelta >= 0 ? "+" : "")\(result.rrDelta)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(result.rrDelta >= 0 ? .green : .red)
            }

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func nextMajorCard(_ majorID: String) -> some View {
        let title = GolfTiersTournament.majorTitle(for: majorID)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("UP NEXT")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(darkGreen)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())

                Spacer()
            }

            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)

            Text("Signups will open when the tournament field is announced. Check back closer to the event!")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Groups Section

    private var groupsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("MY GROUPS")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                if viewModel.canCreateGroups {
                    Button {
                        showCreateGroup = true
                    } label: {
                        Label("Create", systemImage: "plus.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(darkGreen)
                    }
                }
                Button {
                    showJoinGroup = true
                } label: {
                    Label("Join", systemImage: "person.badge.plus")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(darkGreen)
                }
            }
            if !viewModel.canCreateGroups, let reason = viewModel.groupCreationLockReason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }

            if viewModel.myGroups.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "person.3")
                        .foregroundStyle(.secondary)
                    Text("No groups yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(14)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(spacing: 0) {
                    ForEach(viewModel.myGroups) { group in
                        NavigationLink {
                            GolfTiersGroupDetailView(viewModel: viewModel, group: group)
                        } label: {
                            groupRow(group)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
            }

            if let error = viewModel.groupError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func groupRow(_ group: GolfTiersGroup) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.3.fill")
                .font(.title3)
                .foregroundStyle(darkGreen)
                .frame(width: 36, height: 36)
                .background(darkGreen.opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Code: \(group.inviteCode)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Create Group Sheet

    private var createGroupSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Create a private group to compete with friends in Golf Major Tiers.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                TextField("Group name", text: $newGroupName)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)

                Button {
                    Task {
                        if let _ = await viewModel.createGroup(name: newGroupName) {
                            newGroupName = ""
                            showCreateGroup = false
                        }
                    }
                } label: {
                    HStack {
                        if viewModel.isCreatingGroup {
                            ProgressView().tint(.white)
                        }
                        Text("Create Group")
                            .font(.headline.weight(.bold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(newGroupName.trimmingCharacters(in: .whitespaces).isEmpty ? Color(.systemGray4) : darkGreen)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(newGroupName.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isCreatingGroup)
                .padding(.horizontal)

                if let error = viewModel.groupError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }

                Spacer()
            }
            .padding(.top, 20)
            .navigationTitle("New Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showCreateGroup = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Join Group Sheet

    private var joinGroupSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Enter the 6-character invite code from your friend to join their group.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                TextField("Invite code", text: $joinCode)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.characters)
                    .padding(.horizontal)

                Button {
                    Task {
                        let success = await viewModel.joinGroupByCode(joinCode)
                        if success {
                            joinCode = ""
                            showJoinGroup = false
                        }
                    }
                } label: {
                    HStack {
                        if viewModel.isJoiningGroup {
                            ProgressView().tint(.white)
                        }
                        Text("Join Group")
                            .font(.headline.weight(.bold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(joinCode.trimmingCharacters(in: .whitespaces).isEmpty ? Color(.systemGray4) : darkGreen)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(joinCode.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isJoiningGroup)
                .padding(.horizontal)

                if let error = viewModel.groupError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }

                Spacer()
            }
            .padding(.top, 20)
            .navigationTitle("Join Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showJoinGroup = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Helpers

    private func lastName(_ fullName: String) -> String {
        let parts = fullName.components(separatedBy: " ")
        guard parts.count >= 2 else { return fullName }
        let suffixes: Set<String> = ["Jr.", "Jr", "Sr.", "Sr", "II", "III", "IV", "V"]
        if let last = parts.last, suffixes.contains(last), parts.count >= 3 {
            return parts[parts.count - 2]
        }
        return parts.last ?? fullName
    }
}
