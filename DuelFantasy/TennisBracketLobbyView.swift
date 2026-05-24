import SwiftUI

struct TennisBracketLobbyView: View {
    @Bindable var viewModel: TennisBracketViewModel
    @State private var selectedRound: Int = 0       // 0=R1, 1=R2, ..., 6=F
    @State private var selectedQuarter: Int = 0      // R1 sub-quarter (0-3)
    @State private var showCreateGroup = false
    @State private var showJoinGroup = false
    @State private var newGroupName = ""
    @State private var joinCode = ""

    private var brandPurple: Color {
        Color(red: 0.48, green: 0.23, blue: 0.93)
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isLoading && !viewModel.hasAttemptedLoad {
                loadingView
            } else if viewModel.isLocked {
                TennisBracketLiveView(viewModel: viewModel)
            } else if !viewModel.drawAvailable {
                drawNotAvailableView
            } else if let error = viewModel.error {
                errorView(error)
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        grandSlamSelector
                        heroCard
                        picksProgress
                        roundSelector
                        if selectedRound == 0 {
                            quarterSelector
                        }
                        bracketSectionForCurrentRound
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
                    Color(red: 0.94, green: 0.97, blue: 0.94),
                    Color(red: 0.95, green: 0.97, blue: 1.00),
                    Color(red: 0.98, green: 0.99, blue: 1.00)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        .navigationTitle("Tennis Brackets")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                if !viewModel.hasAttemptedLoad {
                    await viewModel.loadTournament()
                } else {
                    await viewModel.recheckStatusIfNeeded()
                }
                await viewModel.loadMyGroups()
            } catch {
                print("[TennisBracket] Unexpected error in task: \(error)")
            }
        }
        .sheet(isPresented: $showCreateGroup) { createGroupSheet }
        .sheet(isPresented: $showJoinGroup) { joinGroupSheet }
    }

    // MARK: - Grand Slam Selector

    private var grandSlamSelector: some View {
        VStack(spacing: 10) {
            // Slam picker
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(GrandSlam.allCases) { slam in
                        Button {
                            if viewModel.selectedGrandSlam != slam {
                                viewModel.selectedGrandSlam = slam
                                viewModel.hasAttemptedLoad = false
                                Task { await viewModel.loadTournament() }
                            }
                        } label: {
                            Text(slam.shortName)
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(viewModel.selectedGrandSlam == slam ? brandPurple : Color.gray.opacity(0.15))
                                .foregroundStyle(viewModel.selectedGrandSlam == slam ? .white : .primary)
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            // ATP / WTA toggle
            HStack(spacing: 8) {
                ForEach(DrawType.allCases) { dt in
                    Button {
                        if viewModel.selectedDrawType != dt {
                            viewModel.selectedDrawType = dt
                            viewModel.hasAttemptedLoad = false
                            Task { await viewModel.loadTournament() }
                        }
                    } label: {
                        Text(dt.shortName)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(viewModel.selectedDrawType == dt ? Color.blue : Color.gray.opacity(0.12))
                            .foregroundStyle(viewModel.selectedDrawType == dt ? .white : .primary)
                            .clipShape(Capsule())
                    }
                }
                Spacer()
            }
        }
    }

    // MARK: - Hero Card

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(viewModel.selectedGrandSlam.shortName)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.2))
                    .clipShape(Capsule())

                Spacer()

                if let remaining = viewModel.lockTimeRemaining {
                    Label("Locks in \(remaining)", systemImage: "clock")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }

            Text(viewModel.tournament?.title ?? "\(viewModel.selectedGrandSlam.displayName) Bracket")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)

            HStack(spacing: 16) {
                Label("128 Players", systemImage: "person.2.fill")
                Label("7 Rounds", systemImage: "trophy")
                Label(viewModel.selectedDrawType.displayName, systemImage: "tennisball")
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.8))

            Text("Surface: \(viewModel.selectedGrandSlam.surface)")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color(red: 0.12, green: 0.25, blue: 0.12), Color(red: 0.20, green: 0.45, blue: 0.20)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Picks Progress

    private var picksProgress: some View {
        VStack(spacing: 6) {
            HStack {
                Text("\(viewModel.userPicks.count)/127 picks made")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(Int(Double(viewModel.userPicks.count) / 127.0 * 100))%")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(brandPurple)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.15))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(brandPurple)
                        .frame(width: geo.size.width * Double(viewModel.userPicks.count) / 127.0)
                }
            }
            .frame(height: 8)
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Round Selector

    private var roundSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(0..<TennisBracketEngine.rounds.count, id: \.self) { roundIndex in
                    let round = TennisBracketEngine.rounds[roundIndex]
                    let matchCount = TennisBracketEngine.matchesPerRound[roundIndex]
                    let picksForRound = roundPickCount(roundIndex: roundIndex)
                    Button {
                        selectedRound = roundIndex
                    } label: {
                        VStack(spacing: 2) {
                            Text(roundShortName(round))
                                .font(.caption.weight(.bold))
                            Text("\(picksForRound)/\(matchCount)")
                                .font(.system(size: 9))
                                .foregroundStyle(selectedRound == roundIndex ? .white.opacity(0.7) : .secondary)
                        }
                        .frame(minWidth: 44)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                        .background(selectedRound == roundIndex ? brandPurple : Color.gray.opacity(0.1))
                        .foregroundStyle(selectedRound == roundIndex ? .white : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    // MARK: - Quarter Selector (only shown for R1)

    private var quarterSelector: some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { q in
                let start = q * 16 + 1
                let end = (q + 1) * 16
                Button {
                    selectedQuarter = q
                } label: {
                    VStack(spacing: 2) {
                        Text("Q\(q + 1)")
                            .font(.caption.weight(.bold))
                        Text("\(start)-\(end)")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(selectedQuarter == q ? brandPurple.opacity(0.7) : Color.gray.opacity(0.1))
                    .foregroundStyle(selectedQuarter == q ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    // MARK: - Bracket Section (shows matchups for current round)

    @ViewBuilder
    private var bracketSectionForCurrentRound: some View {
        if selectedRound == 0 {
            // R1: show 16 matchups for the selected quarter
            r1BracketSection
        } else {
            // R2+: show all matchups for the round inline
            laterRoundBracketSection(roundIndex: selectedRound)
        }
    }

    private var r1BracketSection: some View {
        let matchups = TennisBracketEngine.generateR1Matchups(from: viewModel.drawPlayers)
        let start = selectedQuarter * 16
        let end = min(start + 16, matchups.count)
        let quarterMatchups = start < end ? Array(matchups[start..<end]) : []

        return LazyVStack(spacing: 10) {
            ForEach(Array(quarterMatchups.enumerated()), id: \.offset) { index, matchup in
                let matchNum = start + index + 1
                matchupCard(matchNumber: matchNum, player1: matchup.0, player2: matchup.1)
            }
        }
    }

    private func laterRoundBracketSection(roundIndex: Int) -> some View {
        let round = TennisBracketEngine.rounds[roundIndex]
        let matchCount = TennisBracketEngine.matchesPerRound[roundIndex]

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(roundDisplayName(round))
                    .font(.headline.weight(.bold))
                Spacer()
                Text(pointsLabel(round: round))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(brandPurple)
            }

            LazyVStack(spacing: 10) {
                ForEach(1...matchCount, id: \.self) { matchNum in
                    laterRoundMatchCard(round: round, matchNumber: matchNum)
                }
            }
        }
    }

    private func matchupCard(matchNumber: Int, player1: TennisBracketPlayer, player2: TennisBracketPlayer) -> some View {
        let slot = TennisBracketEngine.matchSlot(round: "R1", matchNumber: matchNumber)
        let winner = viewModel.userPicks[slot]

        return VStack(spacing: 0) {
            HStack {
                Text("Match \(matchNumber)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("R1 · \(pointsLabel(round: "R1"))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            playerRow(player: player1, slot: slot, isSelected: winner == player1.name)
            Divider().padding(.leading, 12)
            playerRow(player: player2, slot: slot, isSelected: winner == player2.name)
        }
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
    }

    private func playerRow(player: TennisBracketPlayer, slot: String, isSelected: Bool) -> some View {
        Button {
            viewModel.pickWinner(slot: slot, playerName: player.name)
        } label: {
            HStack(spacing: 10) {
                // Seed badge
                if let seed = player.seed {
                    Text("\(seed)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(brandPurple.opacity(0.8))
                        .clipShape(Circle())
                } else {
                    Text("\(player.drawPosition)")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Color.gray.opacity(0.1))
                        .clipShape(Circle())
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(player.name)
                        .font(.subheadline.weight(isSelected ? .bold : .regular))
                        .foregroundStyle(isSelected ? brandPurple : .primary)
                    Text("\(player.country) · #\(player.rank)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(brandPurple)
                        .font(.title3)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? brandPurple.opacity(0.06) : .clear)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Later Round Match Cards

    private func laterRoundMatchCard(round: String, matchNumber: Int) -> some View {
        let slot = TennisBracketEngine.matchSlot(round: round, matchNumber: matchNumber)
        let currentPick = viewModel.userPicks[slot]

        // Get the two candidates from source slots
        guard let (src1, src2) = TennisBracketEngine.sourceSlots(for: slot) else {
            return AnyView(EmptyView())
        }
        let candidate1 = viewModel.userPicks[src1]
        let candidate2 = viewModel.userPicks[src2]

        return AnyView(
            VStack(spacing: 0) {
                HStack {
                    Text("Match \(matchNumber)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)

                if let c1 = candidate1 {
                    candidateRow(name: c1, slot: slot, isSelected: currentPick == c1)
                } else {
                    pendingRow(source: src1)
                }
                Divider().padding(.leading, 12)
                if let c2 = candidate2 {
                    candidateRow(name: c2, slot: slot, isSelected: currentPick == c2)
                } else {
                    pendingRow(source: src2)
                }
            }
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
        )
    }

    private func candidateRow(name: String, slot: String, isSelected: Bool) -> some View {
        let player = viewModel.drawPlayers.first(where: { $0.name == name })
        return Button {
            viewModel.pickWinner(slot: slot, playerName: name)
        } label: {
            HStack(spacing: 10) {
                // Seed badge (same style as Round 1)
                if let seed = player?.seed {
                    Text("\(seed)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(brandPurple.opacity(0.8))
                        .clipShape(Circle())
                } else if let dp = player?.drawPosition {
                    Text("\(dp)")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Color.gray.opacity(0.1))
                        .clipShape(Circle())
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.subheadline.weight(isSelected ? .bold : .regular))
                        .foregroundStyle(isSelected ? brandPurple : .primary)
                    if let p = player {
                        Text("\(p.country) · #\(p.rank)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(brandPurple)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isSelected ? brandPurple.opacity(0.06) : .clear)
        }
        .buttonStyle(.plain)
    }

    private func pendingRow(source: String) -> some View {
        HStack {
            Text("Winner of \(source)")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Submit Button

    private var submitButton: some View {
        VStack(spacing: 8) {
            if let submitError = viewModel.submitError {
                Text(submitError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Button {
                Task { await viewModel.submitPicks() }
            } label: {
                HStack {
                    if viewModel.isSubmitting {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text(viewModel.hasSubmitted ? "Update Picks" : "Submit Bracket")
                            .font(.headline.weight(.bold))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(viewModel.allPicksMade ? brandPurple : Color.gray.opacity(0.3))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(!viewModel.allPicksMade || viewModel.isSubmitting)
        }
    }

    // MARK: - Groups Section

    private var groupsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Private Groups")
                    .font(.headline.weight(.bold))
                Spacer()
            }

            if viewModel.myGroups.isEmpty {
                Text("Create or join a group to compete with friends")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.myGroups) { group in
                    NavigationLink {
                        TennisBracketGroupDetailView(viewModel: viewModel, group: group)
                    } label: {
                        HStack {
                            Image(systemName: "person.3.fill")
                                .foregroundStyle(brandPurple)
                            Text(group.name)
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(12)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 10) {
                Button {
                    showCreateGroup = true
                } label: {
                    Label("Create", systemImage: "plus.circle.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(brandPurple.opacity(0.1))
                        .foregroundStyle(brandPurple)
                        .clipShape(Capsule())
                }

                Button {
                    showJoinGroup = true
                } label: {
                    Label("Join", systemImage: "link.circle.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.blue.opacity(0.1))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Sheets

    private var createGroupSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                TextField("Group Name", text: $newGroupName)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)

                if let error = viewModel.groupError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }

                Button {
                    Task {
                        if let _ = await viewModel.createGroup(name: newGroupName) {
                            newGroupName = ""
                            showCreateGroup = false
                        }
                    }
                } label: {
                    Text("Create Group")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(newGroupName.isEmpty ? Color.gray.opacity(0.3) : brandPurple)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                }
                .disabled(newGroupName.isEmpty || viewModel.isCreatingGroup)

                Spacer()
            }
            .padding(.top, 20)
            .navigationTitle("Create Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { showCreateGroup = false }
                }
            }
        }
    }

    private var joinGroupSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                TextField("Invite Code", text: $joinCode)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.characters)
                    .padding(.horizontal)

                if let error = viewModel.groupError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }

                Button {
                    Task {
                        if await viewModel.joinGroupByCode(joinCode) {
                            joinCode = ""
                            showJoinGroup = false
                        }
                    }
                } label: {
                    Text("Join Group")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(joinCode.count < 6 ? Color.gray.opacity(0.3) : brandPurple)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                }
                .disabled(joinCode.count < 6 || viewModel.isJoiningGroup)

                Spacer()
            }
            .padding(.top, 20)
            .navigationTitle("Join Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { showJoinGroup = false }
                }
            }
        }
    }

    // MARK: - Helper Views

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading bracket...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var drawNotAvailableView: some View {
        VStack(spacing: 16) {
            Image(systemName: "tennisball")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Draw Not Yet Available")
                .font(.title3.weight(.bold))
            Text("The \(viewModel.selectedGrandSlam.displayName) \(viewModel.selectedDrawType.shortName) draw hasn't been released yet. Check back closer to the tournament.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Text(viewModel.selectedGrandSlam.approximateDateRange)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.7))
                .clipShape(Capsule())

            grandSlamSelector
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await viewModel.loadTournament() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Helpers

    private func roundPickCount(roundIndex: Int) -> Int {
        let round = TennisBracketEngine.rounds[roundIndex]
        let matchCount = TennisBracketEngine.matchesPerRound[roundIndex]
        var count = 0
        for matchNum in 1...matchCount {
            let slot = TennisBracketEngine.matchSlot(round: round, matchNumber: matchNum)
            if viewModel.userPicks[slot] != nil { count += 1 }
        }
        return count
    }

    private func roundShortName(_ round: String) -> String {
        switch round {
        case "R1": return "R1"
        case "R2": return "R2"
        case "R3": return "R3"
        case "R4": return "R16"
        case "QF": return "QF"
        case "SF": return "SF"
        case "F": return "F"
        default: return round
        }
    }

    private func roundDisplayName(_ round: String) -> String {
        switch round {
        case "R1": return "Round 1"
        case "R2": return "Round 2"
        case "R3": return "Round 3"
        case "R4": return "Round of 16"
        case "QF": return "Quarterfinals"
        case "SF": return "Semifinals"
        case "F": return "Final"
        default: return round
        }
    }

    private func pointsLabel(round: String) -> String {
        guard let idx = TennisBracketEngine.rounds.firstIndex(of: round) else { return "" }
        return "\(TennisBracketEngine.pointsPerRound[idx]) pts"
    }
}
