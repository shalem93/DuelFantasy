import SwiftUI

struct BestBallDraftView: View {
    @Bindable var viewModel: BestBallViewModel
    @EnvironmentObject private var auth: AuthViewModel
    @State private var searchText: String = ""
    @State private var selectedPosition: String? = nil
    @State private var selectedTeam: String? = nil
    @State private var showRoster: Bool = false
    /// Available vs already-drafted list.
    private enum DraftListMode { case available, drafted }
    @State private var listMode: DraftListMode = .available
    /// Tappable column sort. nil = the board's default order.
    private enum DraftSortColumn { case adp, avg, proj }
    @State private var sortColumn: DraftSortColumn? = nil
    @State private var sortAscending = false
    @State private var showTeamPicker = false
    @State private var teamPickerSearch = ""
    @FocusState private var searchFocused: Bool
    @State private var pickTimer: Int = 30
    @State private var timerTask: Task<Void, Never>? = nil
    @State private var isAutoPicking: Bool = false
    /// Set when the user taps a team pill in the recent-picks ticker —
    /// presents a sheet listing that member's drafted players so far.
    @State private var inspectMemberID: String? = nil
    /// Player game-log sheets. One state per presentation context —
    /// the roster/inspect sheets must present the detail from within
    /// their own sheet, not from the root view.
    @State private var listDetail: BBPlayerRef? = nil
    @State private var rosterDetail: BBPlayerRef? = nil
    @State private var inspectDetail: BBPlayerRef? = nil

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
        .sheet(isPresented: $showTeamPicker) {
            teamPickerSheet
        }
        .sheet(item: Binding(
            get: { inspectMemberID.map(InspectMemberID.init(id:)) },
            set: { inspectMemberID = $0?.id }
        )) { wrapper in
            inspectTeamSheet(memberID: wrapper.id)
        }
        .sheet(item: $listDetail) { ref in
            let canDraft = viewModel.isMyTurn && state?.isDraftComplete == false && viewModel.draftHasOpened
            BestBallPlayerDetailSheet(
                viewModel: viewModel, player: ref,
                onDraft: canDraft ? {
                    if let player = viewModel.availablePlayers.first(where: { $0.id == ref.playerID }) {
                        Task { await viewModel.makePick(player: player) }
                    }
                } : nil
            )
        }
        .onAppear {
            if let league = viewModel.currentLeague {
                viewModel.startDraftPolling(leagueID: league.id)
            }
            // Solo leagues get a fresh clock on re-entry; multi-human
            // leagues keep the continuous clock from the VM.
            viewModel.restartPickClockIfSolo()
            startTimer()
        }
        .onDisappear {
            viewModel.stopDraftPolling()
            timerTask?.cancel()
        }
    }

    // MARK: - Draft Header

    private func draftHeader(_ state: BestBallDraftState) -> some View {
        VStack(spacing: 8) {
            // Pre-draft countdown INSIDE the draft screen: everyone
            // transitions in first, then pick 1's clock starts — so
            // nobody loses seconds to the lobby → draft transition.
            if let opens = viewModel.currentLeague?.draftStartTime, opens > Date() {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, Int(opens.timeIntervalSince(context.date).rounded(.up)))
                    HStack(spacing: 8) {
                        Image(systemName: "hourglass")
                            .font(.subheadline.weight(.bold))
                        Text(remaining > 0 ? "DRAFT BEGINS IN \(remaining)s" : "HERE WE GO!")
                            .font(.subheadline.weight(.heavy))
                            .tracking(0.5)
                            .monospacedDigit()
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.orange)
                }
            }
            // Big gold "ON THE CLOCK" banner when it's the user's pick.
            // The previous "YOUR PICK" caption was easy to miss when the
            // draft was flying by at bot speed.
            if viewModel.isMyTurn && !state.isDraftComplete {
                HStack(spacing: 8) {
                    Image(systemName: "target")
                        .font(.subheadline.weight(.bold))
                    Text("YOU'RE ON THE CLOCK")
                        .font(.subheadline.weight(.heavy))
                        .tracking(0.5)
                }
                .foregroundStyle(Color.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    LinearGradient(
                        colors: [
                            Color(red: 1.00, green: 0.84, blue: 0.20),
                            Color(red: 0.98, green: 0.74, blue: 0.10)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            }
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
                        // Countdown to the user's next turn so the snake
                        // order isn't a mystery mid-round.
                        if !isMe, let untilMe = picksUntilMyTurn(state) {
                            Text(untilMe == 1 ? "You're up next!" : "You're up in \(untilMe) picks")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(untilMe <= 2 ? brandPurple : .secondary)
                        }
                    }
                }

                Spacer()

                // Timer
                ZStack {
                    Circle()
                        .stroke(Color(.systemGray4), lineWidth: 3)
                        .frame(width: 44, height: 44)
                    Circle()
                        .trim(from: 0, to: CGFloat(pickTimer) / CGFloat(max(viewModel.currentLeague?.pickTimerSeconds ?? 30, 1)))
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
            // Every pick of the draft, newest first. Plain HStack — a
            // LazyHStack here greedily claims all proposed height and
            // blew the ticker up to half the screen.
            HStack(spacing: 8) {
                ForEach(Array(state.picks.reversed()), id: \.id) { pick in
                    Button {
                        Haptics.light()
                        inspectMemberID = pick.memberID
                    } label: {
                        VStack(spacing: 2) {
                            Text("R\(pick.round)P\(pick.pickNumber)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                            Text(tickerLastName(pick.playerName))
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Text(viewModel.memberName(for: pick.memberID))
                                .font(.caption2)
                                .foregroundStyle(pick.memberID == viewModel.myMemberID ? brandPurple : .secondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
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
                    TextField("Search players or teams", text: $searchText)
                        .font(.subheadline)
                        .focused($searchFocused)
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

                // Sheet, not Menu: the 2s draft-poll refresh re-rendered
                // an open Menu and snapped its scroll back to the top —
                // a 130-team list was unusable.
                Button {
                    Haptics.light()
                    showTeamPicker = true
                } label: {
                    HStack(spacing: 4) {
                        Text(selectedTeam ?? "TEAM")
                            .font(.caption.weight(.semibold))
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            // Available / Drafted toggle
            Picker("", selection: $listMode) {
                Text("Available").tag(DraftListMode.available)
                Text("Drafted (\(state.picks.count))").tag(DraftListMode.drafted)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)

            // Queue strip
            let queue = queuedAvailablePlayers(state)
            if !queue.isEmpty, listMode == .available {
                queueStrip(queue)
            }

            // Column headers
            HStack {
                Text("PLAYER")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("POS")
                    .frame(width: 36)
                Text("TEAM")
                    .frame(width: 40)
                if viewModel.currentLeague?.sport == "NFL" {
                    Text("BYE")
                        .frame(width: 30)
                }
                if viewModel.currentLeague?.sport == "CFB" {
                    Text("BYE")
                        .frame(width: 40)
                }
                if viewModel.currentLeague?.isDingersOnly == true {
                    Text("'25 HR")
                        .frame(width: 48, alignment: .trailing)
                } else {
                    if viewModel.currentLeague?.sport == "NFL" {
                        sortableHeader(isSuperflexLeague ? "ADP·2QB" : "ADP", column: .adp, width: 52)
                    }
                    if viewModel.currentLeague?.sport == "EPL" || viewModel.currentLeague?.sport == "CFB" {
                        sortableHeader("AVG", column: .avg, width: 44)
                    }
                    sortableHeader("PROJ", column: .proj, width: 52)
                }
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .padding(.leading, 16)
            // Rows always reserve trailing queue-star (28) + quick-draft
            // (34 + 6) slots; the header carries the same inset so the
            // columns line up.
            .padding(.trailing, 68)
            .padding(.vertical, 6)

            Divider()

            // Players
            ScrollView {
                LazyVStack(spacing: 0) {
                    if listMode == .drafted {
                        draftedRows(state)
                    } else {
                    ForEach(filteredPlayers(state)) { player in
                        // Row tap opens the player card (game logs); the
                        // trailing + is the one-tap draft when it's the
                        // user's turn.
                        HStack(spacing: 0) {
                        Button {
                            Haptics.light()
                            listDetail = BBPlayerRef(
                                playerID: player.id, name: player.name,
                                team: player.team, position: player.position
                            )
                        } label: {
                            HStack {
                                Text(player.name)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.5)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(player.position)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 36)
                                Text(player.team)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 40)
                                if viewModel.currentLeague?.sport == "NFL" {
                                    Text(viewModel.byeWeek(forTeam: player.team).map(String.init) ?? "–")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 30)
                                }
                                if viewModel.currentLeague?.sport == "CFB" {
                                    // Can be multiple open weeks ("6,12").
                                    Text(viewModel.byeLabel(forTeam: player.team) ?? "–")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                        .frame(width: 40)
                                }
                                if viewModel.currentLeague?.isDingersOnly == true {
                                    Text(player.lastSeasonHR > 0 ? "\(player.lastSeasonHR)" : "-")
                                        .font(.subheadline.weight(.medium).monospacedDigit())
                                        .foregroundStyle(player.lastSeasonHR >= 30 ? .orange : .primary)
                                        .frame(width: 48, alignment: .trailing)
                                } else {
                                    if viewModel.currentLeague?.sport == "NFL" {
                                        // Market ADP — the league-format board
                                        // (2QB when superflex). "-" = undrafted
                                        // in public drafts.
                                        let adp = player.adp(superflex: isSuperflexLeague)
                                        Text(adp.map { String(format: "%.1f", $0) } ?? "–")
                                            .font(.caption.weight(.semibold).monospacedDigit())
                                            .foregroundStyle(adp != nil ? brandPurple : Color(.systemGray3))
                                            .frame(width: 52, alignment: .trailing)
                                    }
                                    if viewModel.currentLeague?.sport == "EPL" || viewModel.currentLeague?.sport == "CFB" {
                                        // Avg fantasy pts per game actually
                                        // played last season — catches high-rate
                                        // players the season-total projection
                                        // dilutes.
                                        let avg = player.avgPointsPerMatch
                                        Text(avg.map { String(format: "%.1f", $0) } ?? "–")
                                            .font(.caption.weight(.semibold).monospacedDigit())
                                            .foregroundStyle(avg != nil ? brandPurple : Color(.systemGray3))
                                            .frame(width: 44, alignment: .trailing)
                                    }
                                    // Display season-total projection (PPG × games).
                                    // Internal `projectedPoints` is per-game so the
                                    // bot drafter and scoring engine stay consistent;
                                    // the draft board reads better in season-long
                                    // totals because that's how Yahoo / ESPN /
                                    // Sleeper rank the players.
                                    let gamesPerSeason: Double = {
                                        switch player.sport {
                                        case "NFL": return 17
                                        case "CFB": return 12
                                        case "NBA": return 82
                                        case "MLB": return 162
                                        case "EPL": return 38
                                        default: return 17
                                        }
                                    }()
                                    Text(String(format: "%.0f", player.projectedPoints * gamesPerSeason))
                                        .font(.subheadline.weight(.medium).monospacedDigit())
                                        .frame(width: 52, alignment: .trailing)
                                }
                            }
                            .padding(.leading, 16)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)

                        // Queue star — add to / remove from the auto-pick
                        // queue (VM-held so it survives leaving the screen).
                        let isQueued = viewModel.draftQueue.contains(player.id)
                        Button {
                            Haptics.light()
                            if isQueued {
                                viewModel.draftQueue.removeAll { $0 == player.id }
                            } else {
                                viewModel.draftQueue.append(player.id)
                            }
                        } label: {
                            Image(systemName: isQueued ? "star.fill" : "star")
                                .font(.subheadline)
                                .foregroundStyle(isQueued ? .yellow : Color(.systemGray3))
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .frame(width: 28)

                        // Quick-draft slot is ALWAYS reserved so the stat
                        // columns never shift when the clock flips to the
                        // user — the button just fades in. Greyed when
                        // drafting this position would leave a starting
                        // slot unfillable (position cap).
                        let fillable = viewModel.pickKeepsLineupFillable(player)
                        let canDraft = viewModel.isMyTurn && !state.isDraftComplete && viewModel.draftHasOpened && fillable
                        Button {
                            Haptics.medium()
                            Task { await viewModel.makePick(player: player) }
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                                .foregroundStyle(brandPurple)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .frame(width: 34)
                        .padding(.trailing, 6)
                        .opacity(canDraft ? 1 : 0)
                        .disabled(!canDraft)
                        }
                        .background(Color(.systemBackground))

                        Divider().padding(.leading, 16)
                    }
                    }
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .simultaneousGesture(TapGesture().onEnded { searchFocused = false })
        }
    }

    /// Drafted picks run through the same search / POS / TEAM filters as
    /// the available list, newest first.
    private func filteredPicks(_ state: BestBallDraftState) -> [BestBallPick] {
        var picks = Array(state.picks.reversed())
        if let pos = selectedPosition { picks = picks.filter { $0.playerPosition == pos } }
        if let team = selectedTeam { picks = picks.filter { $0.playerTeam == team } }
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            picks = picks.filter {
                $0.playerName.lowercased().contains(query)
                    || $0.playerTeam.lowercased().contains(query)
                    || viewModel.memberName(for: $0.memberID).lowercased().contains(query)
            }
        }
        return picks
    }

    /// The drafted-so-far list: who took whom, and where. Rows open the
    /// player's card (game logs) like the available list.
    @ViewBuilder
    private func draftedRows(_ state: BestBallDraftState) -> some View {
        ForEach(filteredPicks(state), id: \.id) { pick in
            Button {
                Haptics.light()
                listDetail = BBPlayerRef(
                    playerID: pick.playerID, name: pick.playerName,
                    team: pick.playerTeam, position: pick.playerPosition
                )
            } label: {
                HStack(spacing: 8) {
                    Text("R\(pick.round)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 20)
                        .background(brandPurple.opacity(0.7))
                        .clipShape(Capsule())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pick.playerName)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        Text("\(pick.playerPosition) • \(pick.playerTeam)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(viewModel.memberName(for: pick.memberID))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(pick.memberID == viewModel.myMemberID ? brandPurple : .primary)
                            .lineLimit(1)
                        Text("Pick \(pick.pickNumber)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 16)
        }
    }

    /// Scrollable, searchable team picker — a Menu re-rendered by the 2s
    /// draft poll kept snapping back to the top of the alphabet.
    private var teamPickerSheet: some View {
        NavigationStack {
            List {
                Button {
                    selectedTeam = nil
                    showTeamPicker = false
                } label: {
                    HStack {
                        Text("All Teams")
                        Spacer()
                        if selectedTeam == nil {
                            Image(systemName: "checkmark").foregroundStyle(brandPurple)
                        }
                    }
                }
                let teams = teamsInPool().filter {
                    teamPickerSearch.isEmpty || $0.lowercased().contains(teamPickerSearch.lowercased())
                }
                ForEach(teams, id: \.self) { team in
                    Button {
                        selectedTeam = team
                        showTeamPicker = false
                    } label: {
                        HStack {
                            Text(team)
                            Spacer()
                            if selectedTeam == team {
                                Image(systemName: "checkmark").foregroundStyle(brandPurple)
                            }
                        }
                    }
                }
            }
            .searchable(text: $teamPickerSearch, prompt: "Search teams")
            .navigationTitle("Filter by Team")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { showTeamPicker = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Queued players still on the board, in priority order.
    private func queuedAvailablePlayers(_ state: BestBallDraftState) -> [BestBallPlayer] {
        let pickedIDs = state.pickedPlayerIDs()
        return viewModel.draftQueue.compactMap { id in
            guard !pickedIDs.contains(id) else { return nil }
            return viewModel.availablePlayers.first(where: { $0.id == id })
        }
    }

    private func queueStrip(_ queue: [BestBallPlayer]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
                ForEach(Array(queue.enumerated()), id: \.element.id) { index, player in
                    HStack(spacing: 4) {
                        Text("\(index + 1). \(tickerLastName(player.name))")
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Button {
                            viewModel.draftQueue.removeAll { $0 == player.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.yellow.opacity(0.12))
                    .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
    }

    private func teamsInPool() -> [String] {
        Set(viewModel.availablePlayers.map(\.team)).subtracting([""]).sorted()
    }

    /// Tappable sort header: first tap sorts best-first, second flips,
    /// third returns to the board's default order.
    private func sortableHeader(_ title: String, column: DraftSortColumn, width: CGFloat) -> some View {
        Button {
            Haptics.light()
            let bestFirstAscending = (column == .adp)   // low ADP = best
            if sortColumn != column {
                sortColumn = column
                sortAscending = bestFirstAscending
            } else if sortAscending == bestFirstAscending {
                sortAscending = !bestFirstAscending
            } else {
                sortColumn = nil
            }
        } label: {
            HStack(spacing: 1) {
                Text(title)
                if sortColumn == column {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                }
            }
            .foregroundStyle(sortColumn == column ? brandPurple : .secondary)
            .frame(width: width, alignment: .trailing)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Inspect Other Member Sheet

    /// Wrapper around a memberID so it can drive a SwiftUI `.sheet(item:)`.
    private struct InspectMemberID: Identifiable, Hashable { let id: String }

    @ViewBuilder
    private func inspectTeamSheet(memberID: String) -> some View {
        NavigationStack {
            let name = viewModel.memberName(for: memberID)
            let picks = state?.roster(for: memberID) ?? []
            let sport = viewModel.currentLeague?.sport ?? "NFL"
            let sortOrder: [String] = {
                switch sport {
                case "NFL", "CFB": return ["QB", "RB", "FB", "WR", "TE", "K"]
                case "NBA": return ["PG", "SG", "SF", "PF", "C"]
                case "MLB": return ["SP", "RP", "P", "C", "1B", "2B", "3B", "SS", "LF", "CF", "RF", "OF", "DH"]
                case "EPL": return ["GK", "DEF", "MID", "FWD"]
                default:    return []
                }
            }()
            let sorted = picks.sorted { a, b in
                let aRank = sortOrder.firstIndex(of: a.playerPosition) ?? Int.max
                let bRank = sortOrder.firstIndex(of: b.playerPosition) ?? Int.max
                if aRank != bRank { return aRank < bRank }
                return a.pickNumber < b.pickNumber
            }
            Group {
                if sorted.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "person")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("\(name) hasn't drafted yet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    List(sorted) { pick in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pick.playerName)
                                    .font(.subheadline.weight(.medium))
                                Text(posTeamLine(pick))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("R\(pick.round) P\(pick.pickNumber)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            Haptics.light()
                            inspectDetail = BBPlayerRef(
                                playerID: pick.playerID, name: pick.playerName,
                                team: pick.playerTeam, position: pick.playerPosition
                            )
                        }
                    }
                }
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { inspectMemberID = nil }
                }
            }
        }
        .sheet(item: $inspectDetail) { ref in
            BestBallPlayerDetailSheet(viewModel: viewModel, player: ref)
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Roster Sheet

    /// Fills the league's lineup slots with drafted players (dedicated
    /// slots first, FLEX-style slots after — the constraints array is
    /// already in that order) and returns the leftovers as bench. Earlier
    /// picks fill first, so slot assignment mirrors draft priority.
    private func slotAssignments(
        _ state: BestBallDraftState, roster: [BestBallPick]
    ) -> (starters: [(slot: String, pick: BestBallPick?)], bench: [BestBallPick]) {
        let (_, constraints) = BestBallLineupConfig.requirements(for: state.league)
        var remaining = roster.sorted { $0.pickNumber < $1.pickNumber }
        var starters: [(String, BestBallPick?)] = []
        for requirement in constraints {
            for _ in 0..<requirement.count {
                if let idx = remaining.firstIndex(where: { requirement.eligible.contains($0.playerPosition) }) {
                    starters.append((requirement.label, remaining.remove(at: idx)))
                } else {
                    starters.append((requirement.label, nil))
                }
            }
        }
        return (starters, remaining)
    }

    /// "1/3 WR"-style chips: drafted count vs the league's draft minimum
    /// for each constrained position.
    private func positionCountChips(_ state: BestBallDraftState, roster: [BestBallPick]) -> some View {
        let league = state.league
        let minimums = BestBallLineupConfig.draftMinimums(
            for: league.sport,
            pitcherSlots: league.pitcherSlots, batterSlots: league.batterSlots,
            nflQB: league.nflQbStarters, nflRB: league.nflRbStarters,
            nflWR: league.nflWrStarters, nflTE: league.nflTeStarters
        )
        let counts = Dictionary(grouping: roster, by: \.playerPosition).mapValues { $0.count }
        let ordered = minimums.sorted { a, b in
            let order = ["QB", "RB", "WR", "TE", "SP", "PG", "SG", "SF", "PF", "C"]
            return (order.firstIndex(of: a.key) ?? 99) < (order.firstIndex(of: b.key) ?? 99)
        }
        return HStack(spacing: 8) {
            ForEach(ordered, id: \.key) { position, need in
                let have = counts[position] ?? 0
                let met = have >= need
                Text("\(have)/\(need) \(position)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(met ? Color.green : Color.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background((met ? Color.green : Color.orange).opacity(0.12))
                    .clipShape(Capsule())
            }
            Spacer()
            Text("\(roster.count)/\(league.rosterSize) drafted")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var rosterSheet: some View {
        NavigationStack {
            Group {
                if let state, let myID = viewModel.myMemberID {
                    let roster = state.roster(for: myID)
                    let (starters, bench) = slotAssignments(state, roster: roster)
                    let benchSlots = max(0, state.league.rosterSize - starters.count)
                    List {
                        Section("Starters") {
                            ForEach(Array(starters.enumerated()), id: \.offset) { _, entry in
                                rosterSlotRow(slot: entry.slot, pick: entry.pick)
                            }
                        }
                        Section("Bench") {
                            ForEach(bench) { pick in
                                rosterSlotRow(slot: "BN", pick: pick)
                            }
                            ForEach(0..<max(0, benchSlots - bench.count), id: \.self) { _ in
                                rosterSlotRow(slot: "BN", pick: nil)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .safeAreaInset(edge: .bottom) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            positionCountChips(state, roster: roster)
                                .padding(.horizontal, 16)
                        }
                        .padding(.vertical, 10)
                        .background(.thinMaterial)
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
        .sheet(item: $rosterDetail) { ref in
            BestBallPlayerDetailSheet(viewModel: viewModel, player: ref)
        }
    }

    private func rosterSlotRow(slot: String, pick: BestBallPick?) -> some View {
        rosterSlotRowContent(slot: slot, pick: pick)
            .contentShape(Rectangle())
            .onTapGesture {
                guard let pick else { return }
                Haptics.light()
                rosterDetail = BBPlayerRef(
                    playerID: pick.playerID, name: pick.playerName,
                    team: pick.playerTeam, position: pick.playerPosition
                )
            }
    }

    private func rosterSlotRowContent(slot: String, pick: BestBallPick?) -> some View {
        HStack(spacing: 12) {
            Text(slot)
                .font(.caption.weight(.bold))
                .foregroundStyle(pick == nil ? Color.secondary : .white)
                .frame(width: 46, height: 24)
                .background(pick == nil ? Color(.systemGray5) : brandPurple)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            if let pick {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pick.playerName)
                        .font(.subheadline.weight(.medium))
                    Text(posTeamLine(pick))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("R\(pick.round)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                Text("Empty")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
    }

    // MARK: - Helpers

    /// Surname for the ticker pill, skipping generational suffixes so
    /// "Deebo Samuel Sr." shows "Samuel", not "Sr.".
    private func tickerLastName(_ fullName: String) -> String {
        let suffixes: Set<String> = ["jr", "sr", "ii", "iii", "iv", "v"]
        let parts = fullName.split(separator: " ")
        if let surname = parts.last(where: { part in
            let cleaned = String(part).lowercased().trimmingCharacters(in: .punctuationCharacters)
            return !suffixes.contains(cleaned)
        }) {
            return String(surname)
        }
        return fullName
    }

    /// "RB • PHI • Bye 10" — the bye segment appears for NFL/CFB teams
    /// with a loaded bye table (CFB can list several: "Bye 6,12").
    private func posTeamLine(_ pick: BestBallPick) -> String {
        var line = "\(pick.playerPosition) • \(pick.playerTeam)"
        if let bye = viewModel.byeLabel(forTeam: pick.playerTeam) {
            line += " • Bye \(bye)"
        }
        return line
    }

    /// Number of picks before the user's next turn (1 = up next). nil when
    /// the user has no remaining pick. Walks the snake order forward from
    /// the current pick using the same order logic as onTheClockMemberID.
    private func picksUntilMyTurn(_ state: BestBallDraftState) -> Int? {
        guard let myID = viewModel.myMemberID, !state.isDraftComplete else { return nil }
        let memberCount = state.members.count
        guard memberCount > 0 else { return nil }
        func memberID(forPick pickNumber: Int) -> String? {
            let round = ((pickNumber - 1) / memberCount) + 1
            let indexInRound = (pickNumber - 1) % memberCount
            let position = (round % 2 == 0) ? (memberCount - 1 - indexInRound) : indexInRound
            if !state.league.draftOrder.isEmpty, position < state.league.draftOrder.count {
                return state.league.draftOrder[position]
            }
            return state.members.first(where: { $0.slotIndex == position })?.id
        }
        // A full snake cycle (there and back) is the farthest a next turn
        // can be; scanning two rounds' worth covers it.
        for offset in 0..<(2 * memberCount) {
            let pick = state.currentPickNumber + offset
            guard pick <= state.totalPicks else { return nil }
            if memberID(forPick: pick) == myID { return offset }
        }
        return nil
    }

    private var positionsForSport: [String] {
        guard let league = viewModel.currentLeague else { return [] }
        switch league.sport {
        case "NBA": return ["PG", "SG", "SF", "PF", "C"]
        case "MLB":
            if league.isDingersOnly {
                return ["C", "1B", "2B", "3B", "SS", "LF", "CF", "RF", "OF", "DH"]
            }
            return ["SP", "C", "1B", "2B", "3B", "SS", "LF", "CF", "RF", "OF", "DH"]
        // Best Ball lineups have no kicker slot, so K is removed from
        // the filter dropdown. The player pool already filters them out
        // upstream — the dropdown is the only place a leftover "K"
        // option could appear.
        case "NFL", "CFB": return ["QB", "RB", "WR", "TE"]
        case "EPL": return ["GK", "DEF", "MID", "FWD"]
        default: return []
        }
    }

    /// 2+ QB starters (dedicated or superflex) reorder the draft board —
    /// QBs rise dramatically on the 2QB ADP market.
    private var isSuperflexLeague: Bool {
        guard let league = viewModel.currentLeague else { return false }
        return league.nflSflexStarters >= 1 || league.nflQbStarters >= 2
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

        if let team = selectedTeam {
            players = players.filter { $0.team == team }
        }

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            players = players.filter {
                $0.name.lowercased().contains(query) ||
                $0.team.lowercased().contains(query)
            }
        }

        // NFL: order by the league-format market ADP (2QB board for
        // superflex), projections for anyone the market doesn't draft.
        if viewModel.currentLeague?.sport == "NFL" {
            let superflex = isSuperflexLeague
            players.sort { a, b in
                switch (a.adp(superflex: superflex), b.adp(superflex: superflex)) {
                case let (x?, y?): return x < y
                case (.some, .none): return true
                case (.none, .some): return false
                default: return a.projectedPoints > b.projectedPoints
                }
            }
        }

        // Sort by last season HR for dingers-only drafts
        if viewModel.currentLeague?.isDingersOnly == true {
            players.sort { $0.lastSeasonHR > $1.lastSeasonHR }
        }

        // Tapped-column sort overrides the board's default order.
        if let column = sortColumn {
            switch column {
            case .adp:
                let superflex = isSuperflexLeague
                players.sort { a, b in
                    switch (a.adp(superflex: superflex), b.adp(superflex: superflex)) {
                    case let (x?, y?): return sortAscending ? x < y : x > y
                    case (.some, .none): return true
                    case (.none, .some): return false
                    default: return a.projectedPoints > b.projectedPoints
                    }
                }
            case .avg:
                players.sort { a, b in
                    let x = a.avgPointsPerMatch ?? -1
                    let y = b.avgPointsPerMatch ?? -1
                    return sortAscending ? x < y : x > y
                }
            case .proj:
                players.sort {
                    sortAscending
                        ? $0.projectedPoints < $1.projectedPoints
                        : $0.projectedPoints > $1.projectedPoints
                }
            }
        }

        return players
    }

    /// Seconds left on the current pick, derived from the VM's pick
    /// clock (last pick landing, or draft-open time during the pre-pick
    /// countdown) — so backing out of the draft and re-entering doesn't
    /// restart the countdown, and pick 1 gets its full clock after the
    /// in-draft countdown.
    private func remainingSeconds() -> Int {
        let total = viewModel.currentLeague?.pickTimerSeconds ?? 30
        let elapsed = Int(Date().timeIntervalSince(viewModel.pickClockStart))
        return max(0, min(total, total - elapsed))
    }

    private func startTimer() {
        pickTimer = remainingSeconds()
        timerTask?.cancel()
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                pickTimer = remainingSeconds()
                if pickTimer <= 0, viewModel.isMyTurn, !isAutoPicking {
                    isAutoPicking = true
                    if let state {
                        // Auto-pick honors the queue first, then falls
                        // back to the best visible player — skipping any
                        // player the position caps would reject.
                        let queued = queuedAvailablePlayers(state)
                            .first(where: { viewModel.pickKeepsLineupFillable($0) })
                        let fallback = filteredPlayers(state)
                            .first(where: { viewModel.pickKeepsLineupFillable($0) })
                        if let pick = queued ?? fallback {
                            await viewModel.makePick(player: pick)
                        }
                    }
                    isAutoPicking = false
                }
            }
        }
    }
}
