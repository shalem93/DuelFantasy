import SwiftUI

struct BestBallDraftView: View {
    @Bindable var viewModel: BestBallViewModel
    @EnvironmentObject private var auth: AuthViewModel
    @State private var searchText: String = ""
    @State private var selectedPosition: String? = nil
    @State private var showRoster: Bool = false
    @State private var pickTimer: Int = 30
    @State private var timerTask: Task<Void, Never>? = nil

    private var brandPurple: Color {
        Color(red: 0.48, green: 0.23, blue: 0.93)
    }

    private var state: BestBallDraftState? { viewModel.draftState }

    var body: some View {
        VStack(spacing: 0) {
            if let state {
                // Draft header
                draftHeader(state)

                // Recent picks ticker
                recentPicksTicker(state)

                Divider()

                // Player list
                playerList(state)
            } else {
                ProgressView("Loading draft...")
            }
        }
        .sheet(isPresented: $showRoster) {
            rosterSheet
        }
        .onAppear {
            if let league = viewModel.currentLeague {
                viewModel.startDraftPolling(leagueID: league.id)
            }
            startTimer()
        }
        .onDisappear {
            viewModel.stopDraftPolling()
            timerTask?.cancel()
        }
        .onChange(of: viewModel.draftState?.currentPickNumber) { _, _ in
            resetTimer()
        }
    }

    // MARK: - Draft Header

    private func draftHeader(_ state: BestBallDraftState) -> some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Round \(state.currentRound) • Pick \(state.currentPickNumber)/\(state.totalPicks)")
                        .font(.subheadline.weight(.semibold))
                    if let onClockID = state.onTheClockMemberID {
                        let name = viewModel.memberName(for: onClockID)
                        let isMe = viewModel.isMyTurn
                        Text(isMe ? "YOUR PICK" : "\(name) is picking...")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(isMe ? brandPurple : .orange)
                    }
                }

                Spacer()

                // Timer
                ZStack {
                    Circle()
                        .stroke(Color(.systemGray4), lineWidth: 3)
                        .frame(width: 44, height: 44)
                    Circle()
                        .trim(from: 0, to: CGFloat(pickTimer) / 30.0)
                        .stroke(pickTimer <= 10 ? .red : brandPurple, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 44, height: 44)
                        .rotationEffect(.degrees(-90))
                    Text("\(pickTimer)")
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(pickTimer <= 10 ? .red : .primary)
                }

                // My roster button
                Button {
                    Haptics.light()
                    showRoster = true
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.title3)
                        .padding(8)
                        .background(Color(.systemGray6))
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.systemBackground))

            if state.isDraftComplete {
                Text("Draft Complete!")
                    .font(.headline)
                    .foregroundStyle(brandPurple)
                    .padding(.bottom, 8)
            }

            // Position requirement warning
            if let myID = viewModel.myMemberID, !state.isDraftComplete {
                let needed = viewModel.positionsNeeded(for: myID, sport: state.league.sport)
                let myRoster = state.roster(for: myID)
                let remainingPicks = state.league.rosterSize - myRoster.count
                if !needed.isEmpty, remainingPicks <= needed.values.reduce(0, +) + 2 {
                    let neededStr = needed.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                        Text("Need: \(neededStr) — \(remainingPicks) picks left")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(Color.orange.opacity(0.12))
                }
            }
        }
    }

    // MARK: - Recent Picks Ticker

    private func recentPicksTicker(_ state: BestBallDraftState) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(state.picks.suffix(8).reversed()), id: \.id) { pick in
                    VStack(spacing: 2) {
                        Text("R\(pick.round)P\(pick.pickNumber)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        Text(pick.playerName.components(separatedBy: " ").last ?? pick.playerName)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Text(viewModel.memberName(for: pick.memberID))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Player List

    private func playerList(_ state: BestBallDraftState) -> some View {
        VStack(spacing: 0) {
            // Search + position filter
            HStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search players", text: $searchText)
                        .font(.subheadline)
                }
                .padding(8)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Menu {
                    Button("All") { selectedPosition = nil }
                    ForEach(positionsForSport, id: \.self) { pos in
                        Button(pos) { selectedPosition = pos }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(selectedPosition ?? "POS")
                            .font(.caption.weight(.semibold))
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))
                    .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            // Column headers
            HStack {
                Text("PLAYER")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("POS")
                    .frame(width: 36)
                Text("TEAM")
                    .frame(width: 40)
                if viewModel.currentLeague?.isDingersOnly == true {
                    Text("'25 HR")
                        .frame(width: 48, alignment: .trailing)
                } else {
                    Text("PROJ")
                        .frame(width: 44, alignment: .trailing)
                }
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            Divider()

            // Players
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredPlayers(state)) { player in
                        Button {
                            Haptics.medium()
                            Task { await viewModel.makePick(player: player) }
                        } label: {
                            HStack {
                                Text(player.name)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(player.position)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 36)
                                Text(player.team)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 40)
                                if viewModel.currentLeague?.isDingersOnly == true {
                                    Text(player.lastSeasonHR > 0 ? "\(player.lastSeasonHR)" : "-")
                                        .font(.subheadline.weight(.medium).monospacedDigit())
                                        .foregroundStyle(player.lastSeasonHR >= 30 ? .orange : .primary)
                                        .frame(width: 48, alignment: .trailing)
                                } else {
                                    Text(String(format: "%.1f", player.projectedPoints))
                                        .font(.subheadline.weight(.medium).monospacedDigit())
                                        .frame(width: 44, alignment: .trailing)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color(.systemBackground))
                        }
                        .buttonStyle(.plain)
                        .disabled(!viewModel.isMyTurn || state.isDraftComplete)

                        Divider().padding(.leading, 16)
                    }
                }
            }
        }
    }

    // MARK: - Roster Sheet

    private var rosterSheet: some View {
        NavigationStack {
            Group {
                if let state, let myID = viewModel.myMemberID {
                    let roster = state.roster(for: myID)
                    if roster.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "person.3")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("No picks yet")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        List(roster) { pick in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pick.playerName)
                                        .font(.subheadline.weight(.medium))
                                    Text("\(pick.playerPosition) • \(pick.playerTeam)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("R\(pick.round)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .listStyle(.plain)
                    }
                } else {
                    Text("Loading...")
                }
            }
            .navigationTitle("My Roster")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showRoster = false }
                }
            }
        }
    }

    // MARK: - Helpers

    private var positionsForSport: [String] {
        guard let league = viewModel.currentLeague else { return [] }
        switch league.sport {
        case "NBA": return ["PG", "SG", "SF", "PF", "C"]
        case "MLB":
            if league.isDingersOnly {
                return ["C", "1B", "2B", "3B", "SS", "LF", "CF", "RF", "OF", "DH"]
            }
            return ["SP", "C", "1B", "2B", "3B", "SS", "LF", "CF", "RF", "OF", "DH"]
        case "NFL": return ["QB", "RB", "WR", "TE", "K"]
        default: return []
        }
    }

    private func filteredPlayers(_ state: BestBallDraftState) -> [BestBallPlayer] {
        let pickedIDs = state.pickedPlayerIDs()
        var players = viewModel.availablePlayers.filter { !pickedIDs.contains($0.id) }

        if let pos = selectedPosition {
            if pos == "OF" {
                players = players.filter { ["OF", "LF", "CF", "RF"].contains($0.position) }
            } else {
                players = players.filter { $0.position == pos }
            }
        }

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            players = players.filter {
                $0.name.lowercased().contains(query) ||
                $0.team.lowercased().contains(query)
            }
        }

        // Sort by last season HR for dingers-only drafts
        if viewModel.currentLeague?.isDingersOnly == true {
            players.sort { $0.lastSeasonHR > $1.lastSeasonHR }
        }

        return players
    }

    private func startTimer() {
        pickTimer = 30
        timerTask?.cancel()
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                if pickTimer > 0 {
                    pickTimer -= 1
                } else if viewModel.isMyTurn {
                    // Auto-pick
                    if let state, let first = filteredPlayers(state).first {
                        await viewModel.makePick(player: first)
                    }
                    resetTimer()
                }
            }
        }
    }

    private func resetTimer() {
        pickTimer = viewModel.currentLeague?.pickTimerSeconds ?? 30
    }
}
