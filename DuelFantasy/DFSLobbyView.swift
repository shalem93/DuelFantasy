import SwiftUI

struct DFSLobbyView: View {
    @Bindable var viewModel: DFSViewModel
    @State private var selectedMainSize: Int = 2000
    @State private var selectedEveningSize: Int = 2000
    @State private var selectedSingleGameSizes: [String: Int] = [:]  // gameID → selected size

    private let fieldSizes = [2, 3, 5, 10, 2000]

    private var brandPurple: Color {
        Color(red: 0.48, green: 0.23, blue: 0.93)
    }

    /// True when the slate's underlying event has already finished — i.e.
    /// the prior tournament went `post` and the next event hasn't yet
    /// materialized in ESPN's scoreboard (typically Sunday night → Tuesday
    /// for PGA). In this window nothing in the lobby is actionable, so we
    /// collapse it to a friendly empty state instead of advertising a
    /// completed tournament as if it were live.
    ///
    /// Every game must be `post` — checking only the FIRST game broke
    /// multi-game slates (MLB): once the 1pm game finished, the lobby
    /// collapsed even though the evening slate and 6:35pm+ single-game
    /// contests were still open for entry.
    private var slateEventFinished: Bool {
        !viewModel.slateGames.isEmpty && viewModel.slateGames.allSatisfy { $0.state == "post" }
    }

    var body: some View {
        Group {
            if slateEventFinished {
                // Standalone (non-scrolling) container so `maxHeight: .infinity`
                // actually centers the empty state vertically — matching the
                // EPL/MLB "No Fixtures Today" view in DFSContestView.
                betweenEventsEmptyState
            } else {
                ScrollView {
                    VStack(spacing: 20) {
                        // Lineup counter
                        lineupCounterBanner

                        // Pending tournament invites from friends
                        if !viewModel.pendingInvites.isEmpty {
                            pendingInvitesSection
                        }

                        // Main Slate section
                        mainSlateSection

                        // Evening Slate section
                        eveningSlateSection

                        // Single Game section
                        singleGameSection

                        if !viewModel.enteredTournamentIDs.isEmpty {
                            enteredLineupsSection
                        }

                        // Private contests (invite-code only, no bots)
                        DFSPrivateContestsSection(viewModel: viewModel)

                        slateGamesSection
                        scoringSection
                        payoutTiersSection
                        if let error = viewModel.error {
                            errorBanner(error)
                        }
                        recentResultsSection
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
                    Color(red: 0.94, green: 0.98, blue: 0.95),
                    Color(red: 0.95, green: 0.97, blue: 1.00),
                    Color(red: 0.98, green: 0.99, blue: 1.00)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        .navigationDestination(isPresented: $viewModel.showLineupBuilder) {
            DFSLineupBuilderView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showAllResults) {
            allResultsSheet
        }
        .sheet(isPresented: $viewModel.showInviteFriends) {
            if let tournamentID = viewModel.inviteTournamentID {
                InviteFriendsSheet(viewModel: viewModel, tournamentID: tournamentID)
            }
        }
        .task {
            // Compute final scores for past private contests so Recent Results
            // shows the user's actual FPTS instead of the 0 that was stored
            // at submission time.
            await viewModel.loadAllPrivateContestFinalScores()
        }
    }

    // MARK: - Between-Events Empty State

    /// Matches the `noEntriesTodayView` style in DFSContestView so PGA's
    /// between-events state looks identical to NHL/MLB's "games have locked"
    /// view instead of introducing a separate UI dialect.
    private var betweenEventsEmptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "sportscourt")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("No Active Entries")
                .font(.title3.weight(.semibold))

            Text(viewModel.sport == "PGA"
                 ? "This week's PGA tournament has locked.\nCheck back for next week's event!"
                 : "Today's \(viewModel.sport) games have locked.\nCheck back for tomorrow's slate!")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                Task { await viewModel.loadSlate(force: true) }
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
    }

    // MARK: - Lineup Counter

    private var lineupCounterBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "ticket.fill")
                .foregroundStyle(brandPurple)
            Text("Lineups Today")
                .font(.subheadline.weight(.medium))
            Spacer()
            Text("\(viewModel.totalLineupsToday)/\(viewModel.maxLineupsPerDay)")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(viewModel.canSubmitMoreLineups ? brandPurple : .red)
            Text("10 RR each")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
    }

    // MARK: - Pending Invites

    private var pendingInvitesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "envelope.fill")
                    .foregroundStyle(.orange)
                Text("Tournament Invites")
                    .font(.headline)
                Spacer()
                Text("\(viewModel.pendingInvites.count)")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.orange)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
            ForEach(viewModel.pendingInvites) { invite in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.remoteProfileNames[invite.inviterID] ?? "Friend")
                            .font(.subheadline.weight(.medium))
                        Text(tournamentTitleForInvite(invite))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        Task {
                            await viewModel.acceptInvite(invite)
                            // Navigate to the tournament's lineup builder
                            if let t = viewModel.tournaments.first(where: { $0.id == invite.tournamentID }) {
                                viewModel.selectTournament(t.id)
                                viewModel.editingLineupNumber = nil
                                viewModel.showLineupBuilder = true
                            }
                        }
                    } label: {
                        Text("Join")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(brandPurple)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                    Button {
                        Task { await viewModel.declineInvite(invite) }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(12)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    private func tournamentTitleForInvite(_ invite: DFSTournamentInviteRecord) -> String {
        if let t = viewModel.tournaments.first(where: { $0.id == invite.tournamentID }) {
            return t.title
        }
        // Extract a readable title from the tournament ID (e.g. "nba-20260507-main-2000")
        return invite.tournamentID
    }

    // MARK: - Main Slate Section

    private var mainSlateSection: some View {
        let mainTournaments = viewModel.availableTournaments.filter { $0.tournamentType == .main }
        // Lock time = first game start; show it like the Evening Slate card
        // does so users know exactly when entries close.
        let mainSubtitle: String? = {
            guard let firstStart = viewModel.slateGames.map(\.startTime).min(),
                  firstStart > Date() else { return nil }
            return "Locks \(firstStart.formatted(date: .omitted, time: .shortened))"
        }()
        return Group {
            if !mainTournaments.isEmpty {
                slateCard(
                    title: "Main Slate",
                    subtitle: mainSubtitle,
                    icon: "sportscourt.fill",
                    iconColor: brandPurple,
                    tournaments: mainTournaments,
                    selectedSize: $selectedMainSize
                )
            }
        }
    }

    // MARK: - Evening Slate Section

    private var eveningSlateSection: some View {
        let eveningTournaments = viewModel.availableTournaments.filter { $0.tournamentType == .evening }
        // First evening game's start time (6pm ET+ cutoff) for a more useful
        // subtitle than the generic "6pm ET+" label.
        let eveningSubtitle: String = {
            let cal = Calendar(identifier: .gregorian)
            let tz = TimeZone(identifier: "America/New_York")!
            var comps = cal.dateComponents(in: tz, from: Date())
            comps.hour = 18
            comps.minute = 0
            comps.second = 0
            let cutoff = cal.date(from: comps) ?? .distantFuture
            let firstEvening = viewModel.slateGames
                .filter { $0.startTime >= cutoff }
                .min(by: { $0.startTime < $1.startTime })
            if let game = firstEvening {
                return "First pitch \(game.startTime.formatted(date: .omitted, time: .shortened))"
            }
            return "6pm ET+"
        }()
        return Group {
            if !eveningTournaments.isEmpty {
                slateCard(
                    title: "Evening Slate",
                    subtitle: eveningSubtitle,
                    icon: "moon.stars.fill",
                    iconColor: .indigo,
                    tournaments: eveningTournaments,
                    selectedSize: $selectedEveningSize
                )
            }
        }
    }

    // MARK: - Single Game Section

    private var singleGameSection: some View {
        let sgTournaments = viewModel.availableTournaments.filter { $0.tournamentType == .singleGame }
        // Group by gameID to show one card per matchup with size picker.
        // Sort by start time, then by gameID for a stable tiebreak — without
        // the secondary key, two games at the same start time (e.g. multiple
        // 6:35pm MLB matchups) shuffled order on every re-render because
        // `Set` iteration order is hash-randomized.
        let gameIDs = Array(Set(sgTournaments.compactMap(\.gameID))).sorted { a, b in
            let timeA = viewModel.slateGames.first(where: { $0.id == a })?.startTime ?? .distantFuture
            let timeB = viewModel.slateGames.first(where: { $0.id == b })?.startTime ?? .distantFuture
            if timeA != timeB { return timeA < timeB }
            return a < b
        }
        return Group {
            if !gameIDs.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Single Game")
                        .font(.headline)

                    ForEach(gameIDs, id: \.self) { gameID in
                        let gameTournaments = sgTournaments.filter { $0.gameID == gameID }
                        if let first = gameTournaments.first {
                            singleGameCard(gameID: gameID, matchupTitle: first.title, tournaments: gameTournaments)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Slate Card (Main/Evening with Size Picker)

    private func slateCard(
        title: String,
        subtitle: String? = nil,
        icon: String,
        iconColor: Color,
        tournaments: [DFSTournament],
        selectedSize: Binding<Int>
    ) -> some View {
        let selectedTournament = tournaments.first(where: { $0.entryCount == selectedSize.wrappedValue }) ?? tournaments.first
        let lineupsInSelected = selectedTournament.map { viewModel.lineupsInTournament($0.id) } ?? 0
        let canAddMore = lineupsInSelected < viewModel.maxLineupsPerTournament && viewModel.canSubmitMoreLineups
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .foregroundStyle(iconColor)
                    Text(title)
                        .font(.headline)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let t = selectedTournament {
                    Text("$\(viewModel.formatSalary(t.salaryCap))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("\(t.lineupSize) players")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Size pills
            HStack(spacing: 8) {
                ForEach(fieldSizes, id: \.self) { size in
                    let isSelected = selectedSize.wrappedValue == size
                    let hasTournament = tournaments.contains(where: { $0.entryCount == size })
                    let tournamentForSize = tournaments.first(where: { $0.entryCount == size })
                    let enteredCount = tournamentForSize.map { viewModel.lineupsInTournament($0.id) } ?? 0
                    Button {
                        selectedSize.wrappedValue = size
                    } label: {
                        VStack(spacing: 2) {
                            Text(sizeLabel(size))
                                .font(.caption.weight(isSelected ? .bold : .medium))
                            if enteredCount > 0 {
                                Text("\(enteredCount)/5")
                                    .font(.system(size: 9).monospacedDigit())
                                    .foregroundStyle(.green)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(isSelected ? brandPurple : Color(.systemGray6))
                        .foregroundStyle(isSelected ? .white : .primary)
                        .clipShape(Capsule())
                        .opacity(hasTournament ? 1 : 0.4)
                    }
                    .disabled(!hasTournament)
                }
            }

            // Enter button
            if let t = selectedTournament {
                Button {
                    Haptics.medium()
                    viewModel.selectTournament(t.id)
                    viewModel.editingLineupNumber = nil
                    // Clear lineup for a fresh start (selectTournament skips clear if same ID)
                    viewModel.clearLineupForNewEntry()
                    viewModel.showLineupBuilder = true
                } label: {
                    HStack {
                        Text(lineupsInSelected > 0
                            ? "Add Lineup #\(lineupsInSelected + 1)"
                            : "Enter \(sizeLabel(t.entryCount))")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("10 RR")
                            .font(.caption.weight(.medium).monospacedDigit())
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(canAddMore ? brandPurple : Color.gray)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(!canAddMore)
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
    }

    // MARK: - Single Game Card (with Size Picker)

    private func singleGameCard(gameID: String, matchupTitle: String, tournaments: [DFSTournament]) -> some View {
        let currentSize = selectedSingleGameSizes[gameID] ?? 2000
        let selectedTournament = tournaments.first(where: { $0.entryCount == currentSize }) ?? tournaments.first
        let gameLockTime = selectedTournament.map { viewModel.lockTimeForTournament($0) } ?? .distantFuture
        let lineupsInSelected = selectedTournament.map { viewModel.lineupsInTournament($0.id) } ?? 0
        let canAddMore = lineupsInSelected < viewModel.maxLineupsPerTournament && viewModel.canSubmitMoreLineups
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(matchupTitle)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                DFSCountdownLabel(lockTime: gameLockTime)
            }

            HStack(spacing: 8) {
                Text("MVP + 5 FLEX")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("$\(viewModel.formatSalary(selectedTournament?.salaryCap ?? 50000))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if let game = viewModel.slateGames.first(where: { $0.id == gameID }) {
                    Text(game.startTime.formatted(date: .omitted, time: .shortened))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            // Size pills
            HStack(spacing: 6) {
                ForEach(fieldSizes, id: \.self) { size in
                    let isSelected = currentSize == size
                    let hasTournament = tournaments.contains(where: { $0.entryCount == size })
                    let tournamentForSize = tournaments.first(where: { $0.entryCount == size })
                    let enteredCount = tournamentForSize.map { viewModel.lineupsInTournament($0.id) } ?? 0
                    Button {
                        selectedSingleGameSizes[gameID] = size
                    } label: {
                        VStack(spacing: 2) {
                            Text(sizeLabel(size))
                                .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                            if enteredCount > 0 {
                                Text("\(enteredCount)/5")
                                    .font(.system(size: 8).monospacedDigit())
                                    .foregroundStyle(.green)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(isSelected ? brandPurple : Color(.systemGray6))
                        .foregroundStyle(isSelected ? .white : .primary)
                        .clipShape(Capsule())
                        .opacity(hasTournament ? 1 : 0.4)
                    }
                    .disabled(!hasTournament)
                }
            }

            if let t = selectedTournament {
                Button {
                    Haptics.medium()
                    viewModel.selectTournament(t.id)
                    viewModel.editingLineupNumber = nil
                    // Clear lineup for a fresh start (selectTournament skips clear if same ID)
                    viewModel.clearLineupForNewEntry()
                    viewModel.showLineupBuilder = true
                } label: {
                    HStack {
                        Text(lineupsInSelected > 0
                            ? "Add Lineup #\(lineupsInSelected + 1)"
                            : "Enter \(sizeLabel(t.entryCount))")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text("10 RR")
                            .font(.caption.weight(.medium).monospacedDigit())
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(canAddMore ? brandPurple : Color.gray)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .disabled(!canAddMore)
            }
        }
        .padding(14)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
    }

    /// Short label for field size
    private func sizeLabel(_ size: Int) -> String {
        switch size {
        case 2: return "H2H"
        case 3: return "3-Man"
        case 5: return "5-Man"
        case 10: return "10-Man"
        case 2000: return "2K"
        default: return "\(size)"
        }
    }

    // MARK: - Lineup Preview

    // MARK: - Entered Lineups (Multi-Tournament, Multi-Lineup)

    private var enteredLineupsSection: some View {
        // Only show unlocked (upcoming) entries — locked ones already appear in Active Contests
        let upcomingTournaments = viewModel.tournaments.filter {
            viewModel.enteredTournamentIDs.contains($0.id) && !viewModel.isTournamentLocked($0)
        }
        // Build a global lineup number for each entry across all instances of the same base type.
        // Group entries by base tournament ID, sort by submission time, assign sequential numbers.
        let globalLineupNumbers: [String: Int] = {
            var byBase: [String: [(entry: DFSEntryRecord, tournamentID: String)]] = [:]
            for (tid, entries) in viewModel.userEntryRecords {
                let base = viewModel.baseTournamentID(tid)
                for entry in entries {
                    byBase[base, default: []].append((entry, tid))
                }
            }
            var result: [String: Int] = [:]
            for (_, entries) in byBase {
                let sorted = entries.sorted { ($0.entry.submittedAt ?? .distantPast) < ($1.entry.submittedAt ?? .distantPast) }
                for (idx, item) in sorted.enumerated() {
                    result[item.entry.id] = idx + 1
                }
            }
            return result
        }()

        return VStack(alignment: .leading, spacing: 12) {
            if !upcomingTournaments.isEmpty {
                Text("Upcoming Lineups")
                    .font(.headline)

                ForEach(upcomingTournaments, id: \.id) { tournament in
                    let entries = viewModel.userEntryRecords[tournament.id] ?? []
                    ForEach(Array(entries.enumerated()), id: \.offset) { idx, entry in
                        let num = globalLineupNumbers[entry.id] ?? entry.lineupNumber ?? (idx + 1)
                        enteredLineupCard(tournament: tournament, entry: entry, lineupNumber: num)
                    }
                    if entries.isEmpty {
                        enteredLineupPlaceholderCard(tournament: tournament)
                    }
                }
            }
        }
    }

    private func enteredLineupCard(tournament: DFSTournament, entry: DFSEntryRecord, lineupNumber: Int) -> some View {
        let typeLabel = dynamicTypeLabel(tournament: tournament)
        let isLocked = viewModel.isTournamentLocked(tournament)
        let playerNames = entry.lineupPlayerNames ?? []
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
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
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
                if !isLocked {
                    Button("Invite") {
                        viewModel.inviteTournamentID = tournament.id
                        viewModel.showInviteFriends = true
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(brandPurple)
                    Button("Edit") {
                        if viewModel.activeTournamentID != tournament.id {
                            viewModel.selectTournament(tournament.id)
                        }
                        viewModel.loadLineupFromEntry(entry)
                        viewModel.editingLineupNumber = lineupNumber
                        viewModel.showLineupBuilder = true
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(brandPurple)
                } else {
                    Text("Locked")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.red)
                }
            }
            if !playerNames.isEmpty {
                let salaries = entry.lineupPlayerSalaries ?? [:]
                let playerIDs = entry.lineupPlayerIDs
                let isSG = tournament.isSingleGame
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(playerNames.enumerated()), id: \.offset) { index, name in
                            let pid = index < playerIDs.count ? playerIDs[index] : ""
                            let sal = salaries[pid]
                            let player = viewModel.players.first(where: { $0.id == pid })
                            let lastName = name.components(separatedBy: " ").last ?? name
                            let isMVP = isSG && index == 0
                            let displaySal = isMVP ? sal.map { Int(Double($0) * 1.5) } : sal
                            VStack(spacing: 1) {
                                if let pos = player?.position {
                                    Text(isMVP ? "MVP" : pos)
                                        .font(.system(size: 7, weight: .bold))
                                        .foregroundStyle(isMVP ? .orange : .secondary)
                                }
                                Text(lastName)
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(isMVP ? .black : .primary)
                                    .lineLimit(1)
                                if let ds = displaySal {
                                    Text("$\(viewModel.formatSalary(ds))")
                                        .font(.system(size: 7, weight: .medium))
                                        .foregroundStyle(isMVP ? .black.opacity(0.5) : .secondary)
                                } else if let team = player?.team {
                                    Text(team)
                                        .font(.system(size: 7, weight: .medium))
                                        .foregroundStyle(isMVP ? .black.opacity(0.5) : .secondary)
                                }
                            }
                            .frame(width: 56, height: 56)
                            .background(isMVP ? Color.yellow.opacity(0.35) : Color(.systemGray6))
                            .clipShape(Circle())
                            .overlay(
                                Circle().strokeBorder(isMVP ? Color.yellow : Color.clear, lineWidth: 2.5)
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }

                // Salary total
                let totalSalary: Int = {
                    var sum = 0
                    for (index, pid) in playerIDs.enumerated() {
                        if let s = salaries[pid] {
                            sum += (isSG && index == 0) ? Int(Double(s) * 1.5) : s
                        }
                    }
                    return sum
                }()
                if totalSalary > 0 {
                    HStack {
                        Spacer()
                        Text("$\(viewModel.formatSalary(totalSalary)) / $\(viewModel.formatSalary(tournament.salaryCap))")
                            .font(.caption2.weight(.medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    private func enteredLineupPlaceholderCard(tournament: DFSTournament) -> some View {
        let typeLabel = dynamicTypeLabel(tournament: tournament)
        return HStack {
            Text(typeLabel)
                .font(.caption.weight(.bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(brandPurple)
                .foregroundStyle(.white)
                .clipShape(Capsule())
            Text(tournament.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Spacer()
            Text("Lineup submitted")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    /// Dynamic label based on tournament type and entry count
    private func dynamicTypeLabel(tournament: DFSTournament) -> String {
        let prefix: String
        switch tournament.tournamentType {
        case .main: prefix = ""
        case .singleGame: prefix = "SG "
        case .evening: prefix = "Eve "
        }
        return "\(prefix)\(sizeLabel(tournament.entryCount))"
    }

    // MARK: - Slate Games

    private var slateGamesSection: some View {
        DisclosureGroup {
            if viewModel.slateGames.isEmpty {
                Text("No games loaded yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(viewModel.slateGames) { game in
                            VStack(spacing: 6) {
                                Text("\(game.awayTeam) @ \(game.homeTeam)")
                                    .font(.subheadline.weight(.semibold))
                                Text(game.startTime.formatted(date: .omitted, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(Color(.systemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .foregroundStyle(brandPurple)
                if let eventDate = viewModel.slateGames.first?.startTime,
                   !Calendar.current.isDateInToday(eventDate) {
                    let noun = viewModel.sport == "UFC" ? "Fights" : "Games"
                    Text("Upcoming \(noun) (\(viewModel.slateGames.count)) — \(eventDate.formatted(.dateTime.month(.abbreviated).day()))")
                        .font(.headline)
                } else {
                    Text("Today's Games (\(viewModel.slateGames.count))")
                        .font(.headline)
                }
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    // MARK: - Payout Tiers

    // MARK: - Scoring System

    private var scoringSection: some View {
        DisclosureGroup {
            VStack(spacing: 8) {
                switch viewModel.sport {
                case "NBA":
                    scoringRow(label: "Point", value: "+1 FPTS")
                    scoringRow(label: "Rebound", value: "+1.25 FPTS")
                    scoringRow(label: "Assist", value: "+1.5 FPTS")
                    scoringRow(label: "Steal", value: "+2 FPTS")
                    scoringRow(label: "Block", value: "+2 FPTS")
                    scoringRow(label: "Turnover", value: "-0.5 FPTS")
                    scoringRow(label: "3-Point Made", value: "+0.5 FPTS")
                case "MLB":
                    Text("Batting")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    scoringRow(label: "Single", value: "+3 FPTS")
                    scoringRow(label: "Double", value: "+6 FPTS")
                    scoringRow(label: "Triple", value: "+9 FPTS")
                    scoringRow(label: "Home Run", value: "+12 FPTS")
                    scoringRow(label: "RBI", value: "+3 FPTS")
                    scoringRow(label: "Run", value: "+3 FPTS")
                    scoringRow(label: "Walk", value: "+3 FPTS")
                    scoringRow(label: "Stolen Base", value: "+6 FPTS")
                    scoringRow(label: "Hit By Pitch", value: "+3 FPTS")
                    Divider()
                    Text("Pitching")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    scoringRow(label: "Inning Pitched", value: "+3 FPTS")
                    scoringRow(label: "Strikeout", value: "+3 FPTS")
                    scoringRow(label: "Win", value: "+6 FPTS")
                    scoringRow(label: "Earned Run", value: "-3 FPTS")
                case "NHL":
                    Text("Skater Scoring")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    scoringRow(label: "Goal", value: "+12 FPTS")
                    scoringRow(label: "Assist", value: "+8 FPTS")
                    scoringRow(label: "Shot on Goal", value: "+1.6 FPTS")
                    scoringRow(label: "Blocked Shot", value: "+1.6 FPTS")
                    scoringRow(label: "PP Goal Bonus", value: "+0.5 FPTS")
                    scoringRow(label: "PP Assist Bonus", value: "+0.5 FPTS")
                    scoringRow(label: "SH Goal Bonus", value: "+2 FPTS")
                    scoringRow(label: "SH Assist Bonus", value: "+2 FPTS")
                    Divider()
                    Text("Goalie Scoring")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    scoringRow(label: "Win", value: "+12 FPTS")
                    scoringRow(label: "Shutout", value: "+8 FPTS")
                    scoringRow(label: "Save", value: "+0.8 FPTS")
                    scoringRow(label: "Goal Against", value: "-4 FPTS")
                case "PGA":
                    Text("Hole Scoring")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    scoringRow(label: "Albatross", value: "+20 FPTS")
                    scoringRow(label: "Eagle", value: "+8 FPTS")
                    scoringRow(label: "Birdie", value: "+3 FPTS")
                    scoringRow(label: "Par", value: "+0.5 FPTS")
                    scoringRow(label: "Bogey", value: "-0.5 FPTS")
                    scoringRow(label: "Double Bogey+", value: "-1 FPTS")
                    Divider()
                    Text("Bonuses")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    scoringRow(label: "Hole-in-One", value: "+10 FPTS")
                    scoringRow(label: "3 Birdies in Row", value: "+3 FPTS")
                    scoringRow(label: "Bogey-Free Round", value: "+3 FPTS")
                    scoringRow(label: "All 4 Rounds <70", value: "+5 FPTS")
                    Divider()
                    Text("Placement (1st–50th)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    scoringRow(label: "1st Place", value: "+30 FPTS")
                    scoringRow(label: "2nd Place", value: "+20 FPTS")
                    scoringRow(label: "3rd Place", value: "+18 FPTS")
                    scoringRow(label: "Top 10", value: "+7–16 FPTS")
                    scoringRow(label: "Top 50", value: "+1–6 FPTS")
                case "EPL", "UCL", "WC":
                    Text("Outfield (DEF / MID / FWD)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    scoringRow(label: "Goal", value: "+15 FPTS")
                    scoringRow(label: "Assist", value: "+7 FPTS")
                    scoringRow(label: "Shot on Goal", value: "+4 FPTS")
                    scoringRow(label: "Chance Created", value: "+2.5 FPTS")
                    scoringRow(label: "Clearance", value: "+1.6 FPTS")
                    scoringRow(label: "Interception", value: "+1.6 FPTS")
                    scoringRow(label: "Blocked Shot", value: "+1.6 FPTS")
                    scoringRow(label: "Tackle", value: "+1.6 FPTS")
                    scoringRow(label: "Shot", value: "+1 FPTS")
                    scoringRow(label: "Foul Drawn", value: "+1 FPTS")
                    scoringRow(label: "Yellow Card", value: "-1 FPTS")
                    scoringRow(label: "Red Card", value: "-3 FPTS")
                    scoringRow(label: "Missed Penalty", value: "-3 FPTS")
                    Divider()
                    Text("Defenders Only")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    scoringRow(label: "Clean Sheet", value: "+5 FPTS")
                    scoringRow(label: "Goal Against", value: "-0.6 FPTS")
                    Divider()
                    Text("Goalkeeper")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    scoringRow(label: "Clean Sheet", value: "+8 FPTS")
                    scoringRow(label: "Win Bonus", value: "+6 FPTS")
                    scoringRow(label: "Save", value: "+2.5 FPTS")
                    scoringRow(label: "Saved Penalty", value: "+2.5 FPTS")
                    scoringRow(label: "Goal Against", value: "-2.5 FPTS")
                case "UFC":
                    Text("Striking")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    scoringRow(label: "Significant Strike", value: "+0.6 FPTS")
                    scoringRow(label: "Knockdown", value: "+10 FPTS")
                    Divider()
                    Text("Grappling")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    scoringRow(label: "Takedown", value: "+5 FPTS")
                    scoringRow(label: "Submission Attempt", value: "+3 FPTS")
                    scoringRow(label: "Reversal", value: "+3 FPTS")
                    scoringRow(label: "Advance (Mount/Back)", value: "+5 FPTS")
                    Divider()
                    Text("Win Bonuses")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    scoringRow(label: "Win", value: "+30 FPTS")
                    scoringRow(label: "KO/TKO Finish", value: "+30 FPTS")
                    scoringRow(label: "Submission Finish", value: "+20 FPTS")
                default:
                    scoringRow(label: "Point", value: "+1 FPTS")
                    scoringRow(label: "Rebound", value: "+1.25 FPTS")
                    scoringRow(label: "Assist", value: "+1.5 FPTS")
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.fill")
                    .foregroundStyle(brandPurple)
                Text("Scoring System")
                    .font(.headline)
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    private func scoringRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(value.contains("-") ? .red : brandPurple)
        }
    }

    // MARK: - Payout Tiers

    private var payoutTiersSection: some View {
        let gold = Color(red: 0.95, green: 0.78, blue: 0.20)
        // Always show 2K payouts — the most detailed payout structure
        let tiers = DFSEngine.payoutTiers(forEntryCount: 2000)
        return DisclosureGroup {
            VStack(spacing: 6) {
                ForEach(Array(tiers.enumerated()), id: \.offset) { _, tier in
                    let valueStr = tier.rrDelta >= 0 ? "+\(tier.rrDelta) RR" : "\(tier.rrDelta) RR"
                    let color: Color = tier.rrDelta >= 100 ? gold : (tier.rrDelta > 0 ? .green : .red)
                    payoutRow(label: tier.rankLabel, value: valueStr, color: color)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "trophy.fill")
                    .foregroundStyle(gold)
                Text("Payouts — 2K")
                    .font(.headline)
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    private func payoutRow(label: String, value: String, color: Color) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
        }
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            Text(message)
                .font(.caption)
                .foregroundStyle(.primary)

            Spacer()

            Button {
                viewModel.dismissError()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - All Results Sheet

    private var allResultsSheet: some View {
        let sportPrefix = viewModel.sport.lowercased() + "-"
        let sportResults = viewModel.dfsHistory.filter { $0.tournamentId?.hasPrefix(sportPrefix) == true }
        return NavigationStack {
            List(sportResults) { result in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.tournamentTitle)
                            .font(.subheadline.weight(.medium))
                        HStack(spacing: 4) {
                            Text("#\(result.rank)/\(result.totalEntries) • \(String(format: "%.1f", result.lineupPoints)) pts")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let date = dateFromResult(result) {
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
                    Text("\(result.rrDelta >= 0 ? "+" : "")\(result.rrDelta) RR")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(result.rrDelta >= 0 ? .green : .red)
                }
            }
            .navigationTitle("\(viewModel.sport) Results")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { viewModel.showAllResults = false }
                }
            }
        }
    }

    private func dateFromResult(_ result: DFSResult) -> Date? {
        let loggedAt = result.loggedAt
        // If loggedAt is a real date (not epoch 0), use it
        if loggedAt.timeIntervalSince1970 > 86400 {
            return loggedAt
        }
        // Fallback: parse from tournament ID like "nba-2025-04-15"
        if let tid = result.tournamentId {
            return dateFromTournamentID(tid)
        }
        return nil
    }

    private func dateFromTournamentID(_ tournamentID: String) -> Date? {
        let parts = tournamentID.split(separator: "-")
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

    // MARK: - Recent Results

    /// Private contests whose parent slate's date has passed (i.e. not the
    /// currently-displayed slate). These get folded into Recent Results so
    /// they don't disappear from the lobby once their game day rolls over.
    private var pastPrivateContests: [DFSPrivateContest] {
        let sportPrefix = viewModel.sport.lowercased() + "-"
        return viewModel.myPrivateContests.filter { contest in
            guard contest.parentTournamentID.hasPrefix(sportPrefix) else { return false }
            return !viewModel.privateContestBelongsToCurrentSlate(contest)
        }
    }

    private var recentResultsSection: some View {
        let sportPrefix = viewModel.sport.lowercased() + "-"
        let sportHistory = viewModel.dfsHistory.filter { $0.tournamentId?.hasPrefix(sportPrefix) == true }
        let pastPrivates = pastPrivateContests
        let totalCount = sportHistory.count + pastPrivates.count
        return DisclosureGroup {
            if totalCount == 0 {
                Text("No results yet. Enter a tournament to get started!")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(sportHistory.prefix(3)) { result in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.tournamentTitle)
                                .font(.subheadline.weight(.medium))
                            HStack(spacing: 4) {
                                Text("#\(result.rank)/\(result.totalEntries) • \(String(format: "%.1f", result.lineupPoints)) pts")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let date = dateFromResult(result) {
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
                        Text("\(result.rrDelta >= 0 ? "+" : "")\(result.rrDelta) RR")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(result.rrDelta >= 0 ? .green : .red)
                    }
                    .padding(12)
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
                }
                ForEach(pastPrivates) { contest in
                    NavigationLink {
                        DFSPrivateContestDetailView(viewModel: viewModel, contest: contest)
                    } label: {
                        pastPrivateContestRow(contest: contest)
                    }
                    .buttonStyle(.plain)
                }
                if sportHistory.count > 3 {
                    Button("See All") {
                        viewModel.showAllResults = true
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(brandPurple)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        } label: {
            Text("Recent Results (\(totalCount))")
                .font(.headline)
                .foregroundStyle(.primary)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .tint(.primary)
    }

    /// Row used to render a past private contest inside Recent Results.
    /// Mirrors the public result row's layout: title + rank/pts + date.
    private func pastPrivateContestRow(contest: DFSPrivateContest) -> some View {
        let myUUID: UUID? = viewModel.userID.flatMap(UUID.init(uuidString:))
        let myEntry: DFSPrivateContestEntry? = {
            guard let me = myUUID else { return nil }
            return (viewModel.privateContestEntries[contest.id] ?? []).first(where: { $0.userID == me })
        }()
        let entries = viewModel.privateContestEntries[contest.id] ?? []
        let myRank: Int? = {
            guard let me = myUUID,
                  let myPoints = entries.first(where: { $0.userID == me })?.lineupTotalPoints else { return nil }
            let higher = entries.filter { $0.lineupTotalPoints > myPoints }.count
            return higher + 1
        }()
        let totalMembers = viewModel.privateContestMembers[contest.id]?.count ?? entries.count
        let dateString: String? = {
            let parts = contest.parentTournamentID.split(separator: "-")
            guard let dateStr = parts.first(where: { $0.count == 8 && Int($0) != nil }) else { return nil }
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd"
            guard let date = fmt.date(from: String(dateStr)) else { return nil }
            return date.formatted(date: .abbreviated, time: .omitted)
        }()
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("PRIVATE")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(brandPurple)
                        .clipShape(Capsule())
                    Text(contest.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    if let rank = myRank, myEntry != nil {
                        // Prefer the box-score-derived final FPTS over the
                        // stored 0 that was set when the lineup was submitted.
                        let score = viewModel.privateContestFinalScores[contest.id]
                            ?? myEntry?.lineupTotalPoints ?? 0
                        Text("#\(rank)/\(totalMembers) • \(String(format: "%.1f", score)) pts")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Tap to view")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let dateString {
                        Text("•")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(dateString)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
    }
}

// MARK: - Countdown Label

struct DFSCountdownLabel: View {
    let lockTime: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let remaining = lockTime.timeIntervalSince(context.date)
            if remaining <= 0 {
                Text("Locked")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.red)
            } else {
                let hours = Int(remaining) / 3600
                let minutes = (Int(remaining) % 3600) / 60
                if hours > 0 {
                    Text("\(hours)h \(minutes)m")
                        .font(.callout.weight(.medium).monospacedDigit())
                        .foregroundStyle(.white)
                } else {
                    Text("\(minutes)m")
                        .font(.callout.weight(.medium).monospacedDigit())
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}
