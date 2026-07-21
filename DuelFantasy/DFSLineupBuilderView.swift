import SwiftUI

struct DFSLineupBuilderView: View {
    @Bindable var viewModel: DFSViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showSortOptions = false
    @State private var inspectedPlayer: DFSPlayer?
    @State private var showSearch = false

    private var brandPurple: Color {
        Color(red: 0.48, green: 0.23, blue: 0.93)
    }

    var body: some View {
        VStack(spacing: 0) {
            salaryBar
            lineupSlots
            if viewModel.tournament?.isSingleGame != true && viewModel.sport != "PGA" && viewModel.sport != "UFC" && viewModel.sport != "NASCAR" {
                positionFilters
            }
            if !viewModel.gameMatchupLabels.isEmpty && viewModel.tournament?.isSingleGame != true && viewModel.sport != "PGA" && viewModel.sport != "NASCAR" {
                gameFilters
            }

            if showSearch {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search players…", text: $viewModel.searchText)
                        .font(.subheadline)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if !viewModel.searchText.isEmpty {
                        Button {
                            viewModel.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))
            }

            Divider()

            playerList

            submitFooter
        }
        .onAppear { viewModel.isEditingLineup = true }
        .onDisappear {
            viewModel.isEditingLineup = false
            viewModel.editingLineupNumber = nil
            viewModel.searchText = ""
        }
        .navigationTitle("Build Lineup")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                let allSlateEntries: [DFSEntryRecord] = {
                    guard let current = viewModel.tournament else { return [] }
                    let currentBase = viewModel.baseTournamentID(current.id)
                    let currentType = current.tournamentType
                    var entries: [DFSEntryRecord] = []

                    // Slate identity = tournament ID minus the trailing field
                    // size (and any -iN instance suffix). "pga-401811949-2000"
                    // → "pga-401811949", "mlb-20260610-eve-5" → "mlb-20260610-eve".
                    @MainActor func slateIdentity(_ id: String) -> String {
                        let base = viewModel.baseTournamentID(id)
                        let parts = base.components(separatedBy: "-")
                        if let last = parts.last, Int(last) != nil, parts.count > 1 {
                            return parts.dropLast().joined(separator: "-")
                        }
                        return base
                    }
                    let currentIdentity = slateIdentity(current.id)

                    // 1. Public entries from `userEntryRecords` — the original
                    //    behavior.
                    for (tid, records) in viewModel.userEntryRecords {
                        let entryBase = viewModel.baseTournamentID(tid)
                        if current.isSingleGame {
                            // For single-game: only show lineups from the same game
                            // Single-game IDs encode the matchup, so strip the type suffix
                            // e.g. "mlb-20260511-sg-LAA@CLE-h2h" → game part is "mlb-20260511-sg-LAA@CLE"
                            let currentGamePart = currentBase.components(separatedBy: "-").dropLast().joined(separator: "-")
                            let entryGamePart = entryBase.components(separatedBy: "-").dropLast().joined(separator: "-")
                            if currentGamePart == entryGamePart {
                                entries.append(contentsOf: records)
                            }
                        } else {
                            // Same type AND same slate. Matching on type alone
                            // offered LAST week's PGA lineups (both events are
                            // `.main`) — importing those fills the builder with
                            // $0 stubs for players not in this week's field.
                            if DFSTournamentType.from(tournamentID: tid) == currentType,
                               slateIdentity(tid) == currentIdentity {
                                entries.append(contentsOf: records)
                            }
                        }
                    }

                    // 2. Private contest entries submitted by the user that
                    //    share the same slate/game as the builder. Converted
                    //    into synthetic DFSEntryRecord rows so they slot into
                    //    the same import menu and `loadLineupFromEntry` path.
                    guard let myUUID = viewModel.userID.flatMap(UUID.init(uuidString:)) else { return entries }
                    // Extract the 8-digit YYYYMMDD date prefix from a
                    // tournament ID (e.g. `mlb-20260606-2000` → `20260606`).
                    // Used to gate import suggestions to the same slate date —
                    // yesterday's private MLB main slate shouldn't get offered
                    // for import into today's main slate builder.
                    func dateKey(_ tid: String) -> String? {
                        let parts = tid.components(separatedBy: "-")
                        return parts.first(where: { $0.count == 8 && Int($0) != nil })
                    }
                    let currentDateKey = dateKey(currentBase)
                    for contest in viewModel.myPrivateContests {
                        let parentBase = viewModel.baseTournamentID(contest.parentTournamentID)
                        let parentType = DFSTournamentType.from(tournamentID: contest.parentTournamentID)
                        let matches: Bool = {
                            if current.isSingleGame {
                                let currentGamePart = currentBase.components(separatedBy: "-").dropLast().joined(separator: "-")
                                let parentGamePart = parentBase.components(separatedBy: "-").dropLast().joined(separator: "-")
                                return parentGamePart == currentGamePart
                            }
                            // Main/evening: same type AND same date. Without
                            // the date check, yesterday's main slate private
                            // contest shows up as importable into today's
                            // builder — and the player IDs may not even
                            // exist in today's slate.
                            guard parentType == currentType else { return false }
                            guard let cdk = currentDateKey, let pdk = dateKey(parentBase) else { return false }
                            return cdk == pdk
                        }()
                        guard matches else { continue }
                        guard let entry = (viewModel.privateContestEntries[contest.id] ?? []).first(where: { $0.userID == myUUID }) else { continue }
                        // Skip if we'd re-import the lineup the user is already editing
                        guard entry.lineupPlayerIDs != viewModel.selectedPlayers.map(\.id) else { continue }
                        let synthetic = DFSEntryRecord(
                            id: "priv-\(contest.id.uuidString)",
                            tournamentID: contest.parentTournamentID,
                            userID: viewModel.userID ?? "",
                            lineupPlayerIDs: entry.lineupPlayerIDs,
                            submittedAt: entry.submittedAt,
                            lineupTotalPoints: entry.lineupTotalPoints,
                            displayName: "Private: \(contest.name)",
                            lineupPlayerSalaries: nil,
                            lineupPlayerNames: nil,
                            lineupNumber: nil
                        )
                        entries.append(synthetic)
                    }
                    // Dedup by lineup-player-ID set: if a user submitted the
                    // same 6/10 players to multiple sibling tournaments
                    // (H2H + 5-Man + 2000-person, or main + evening), they
                    // shouldn't see the same lineup listed N times in the
                    // import menu — one entry per unique lineup is enough.
                    var seenLineups = Set<String>()
                    var deduped: [DFSEntryRecord] = []
                    for entry in entries {
                        let key = entry.lineupPlayerIDs.sorted().joined(separator: "|")
                        if seenLineups.insert(key).inserted {
                            deduped.append(entry)
                        }
                    }
                    return deduped
                }()
                // Hide Import during the late-swap window (slate locked): loading
                // a different saved lineup would overwrite the already-locked,
                // in-progress players and break the lineup the user is swapping.
                if !allSlateEntries.isEmpty && !viewModel.isTournamentLocked {
                    Menu {
                        ForEach(Array(allSlateEntries.enumerated()), id: \.offset) { idx, entry in
                            Button {
                                viewModel.loadLineupFromEntry(entry)
                            } label: {
                                let isPrivate = entry.id.hasPrefix("priv-")
                                let label: String = {
                                    if isPrivate, let name = entry.displayName {
                                        return name
                                    }
                                    let num = entry.lineupNumber ?? (idx + 1)
                                    let names = (entry.lineupPlayerNames ?? []).prefix(3).map {
                                        $0.components(separatedBy: " ").last ?? $0
                                    }.joined(separator: ", ")
                                    return "Lineup #\(num) — \(names)…"
                                }()
                                Label(label, systemImage: isPrivate ? "lock.shield" : "doc.on.clipboard")
                            }
                        }
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                            .font(.subheadline)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    Button {
                        showSearch.toggle()
                        if !showSearch { viewModel.searchText = "" }
                    } label: {
                        Image(systemName: showSearch ? "xmark" : "magnifyingglass")
                    }

                    Menu {
                        Button {
                            viewModel.sortOrder = .salary
                        } label: {
                            Label("Salary", systemImage: viewModel.sortOrder == .salary ? "checkmark" : "")
                        }
                        Button {
                            viewModel.sortOrder = .projected
                        } label: {
                            Label("Projected Pts", systemImage: viewModel.sortOrder == .projected ? "checkmark" : "")
                        }
                        Button {
                            viewModel.sortOrder = .name
                        } label: {
                            Label("Name", systemImage: viewModel.sortOrder == .name ? "checkmark" : "")
                        }
                        Button {
                            viewModel.sortOrder = .position
                        } label: {
                            Label("Position", systemImage: viewModel.sortOrder == .position ? "checkmark" : "")
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                }
            }
        }
        .searchable(text: $viewModel.searchText, prompt: "Search players")
    }

    // MARK: - Salary Bar

    private var salaryBar: some View {
        VStack(spacing: 6) {
            HStack {
                Text("SALARY")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("$\(viewModel.formatSalary(viewModel.selectedSalary)) / $\(viewModel.formatSalary(viewModel.salaryCap))")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(viewModel.selectedSalary > viewModel.salaryCap ? .red : .primary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.systemGray5))
                        .frame(height: 8)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(viewModel.selectedSalary > viewModel.salaryCap ? Color.red : brandPurple)
                        .frame(width: min(geo.size.width, geo.size.width * viewModel.salaryProgress), height: 8)
                        .animation(.easeInOut(duration: 0.2), value: viewModel.salaryProgress)
                }
            }
            .frame(height: 8)

            HStack {
                Text("$\(viewModel.formatSalary(viewModel.salaryRemaining)) remaining")
                    .font(.caption)
                    .foregroundStyle(viewModel.salaryRemaining < 0 ? .red : .secondary)
                Spacer()
                Text("\(viewModel.selectedPlayers.count)/\(viewModel.lineupSize) players")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
    }

    // MARK: - Lineup Slots

    private var lineupSlots: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                let status = viewModel.slotStatus
                let isSG = viewModel.tournament?.isSingleGame == true
                ForEach(0..<status.count, id: \.self) { index in
                    let slot = status[index]
                    let slotLabel = isSG ? (index == 0 ? "MVP" : "FLEX") : slot.label
                    if let player = slot.player {
                        let playerIsMVP = isSG && viewModel.mvpPlayerID == player.id
                        filledSlot(player: player, isMVP: playerIsMVP, isSingleGame: isSG)
                    } else {
                        emptySlot(index: index, label: slotLabel, isMVP: isSG && index == 0)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color(.secondarySystemBackground))
    }

    @ViewBuilder
    private func slotBadgeContent(label: String, name: String, isMVP: Bool) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(isMVP ? .black : .white)
                .frame(width: 28, height: 24)
                .background(isMVP ? Color.yellow : brandPurple)
                .clipShape(Capsule())

            Text(lastName(name))
                .font(.caption2.weight(.medium))
                .lineLimit(1)
        }
    }

    private func filledSlot(player: DFSPlayer, isMVP: Bool = false, isSingleGame: Bool = false) -> some View {
        let badgeLabel = isMVP ? "MVP" : (isSingleGame ? "FLEX" : player.position)
        // Use the player's canonical salary (already applied via selectedPlayers
        // override) so the chip matches the running cap total and the price
        // that gets stored on submit. Raw activePlayers can drift post-contest
        // creation, which would make the chip show a different price than the
        // lobby/saved view.
        let displaySalary = isMVP ? Int(Double(player.salary) * 1.5) : player.salary
        return VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                if isSingleGame && !isMVP {
                    // Tap to promote to MVP
                    Button {
                        Haptics.light()
                        viewModel.setMVP(player)
                    } label: {
                        slotBadgeContent(label: badgeLabel, name: player.name, isMVP: false)
                    }
                    .buttonStyle(.plain)
                } else {
                    slotBadgeContent(label: badgeLabel, name: player.name, isMVP: isMVP)
                }

                // Late swap: once a player's game has started, the spot is
                // frozen — show a lock instead of a removable ✕.
                if viewModel.isPlayerLocked(player) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(Color.gray)
                        .clipShape(Circle())
                        .offset(x: 8, y: -6)
                } else {
                    Button {
                        Haptics.light()
                        viewModel.removePlayer(player)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.red)
                            .background(.white)
                            .clipShape(Circle())
                    }
                    .offset(x: 8, y: -6)
                }
            }

            Text("$\(viewModel.formatSalary(displaySalary))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isMVP ? .orange : .secondary)
        }
        .frame(width: 68, height: 76)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            isMVP ? RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.yellow.opacity(0.5), lineWidth: 1.5) : nil
        )
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
    }

    private func emptySlot(index: Int, label: String? = nil, isMVP: Bool = false) -> some View {
        VStack(spacing: 4) {
            Image(systemName: isMVP ? "crown" : "plus.circle.dashed")
                .font(.title3)
                .foregroundStyle(isMVP ? .yellow : .secondary)

            Text(label ?? "SLOT \(index + 1)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(isMVP ? .yellow : .secondary)
        }
        .frame(width: 68, height: 76)
        .background(Color(.systemBackground).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: isMVP ? [] : [5]))
                .foregroundStyle(isMVP ? Color.yellow.opacity(0.5) : Color(.separator))
        )
    }

    // MARK: - Position Filters

    private var positionFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                positionPill(label: "ALL", position: nil)
                ForEach(positionList, id: \.self) { pos in
                    positionPill(label: pos, position: pos)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color(.systemBackground))
    }

    /// Unique positions from the current player pool, in a logical order.
    /// "UTIL" is a virtual pill that shows all batters (MLB) or all skaters (NHL).
    private var positionList: [String] {
        let order: [String: Int] = [
            "PG": 0, "SG": 1, "SF": 2, "PF": 3, "C": 4, "G": 5, "F": 6,  // NBA
            "SP": 3, "RP": 11, "1B": 12, "2B": 13, "3B": 14, "SS": 15, "OF": 16, "UTIL": 17,  // MLB (SP before C)
            "W": 20, "D": 21,  // NHL
            "GK": 30, "DEF": 31, "MID": 32, "FWD": 33,  // Soccer
        ]
        let excluded: Set<String> = ["—"]
        var unique = Set(viewModel.activePlayers.map(\.position)).subtracting(excluded)
        // Always include UTIL for MLB and NHL so users can browse all batters/skaters
        if viewModel.sport == "MLB" || viewModel.sport == "NHL" {
            unique.insert("UTIL")
        }
        return unique.sorted { (order[$0] ?? 99) < (order[$1] ?? 99) }
    }

    private func positionPill(label: String, position: String?) -> some View {
        let isActive = viewModel.selectedPositionFilter == position
        return Button {
            Haptics.light()
            viewModel.selectedPositionFilter = position
        } label: {
            Text(label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(isActive ? brandPurple : Color(.systemGray5))
                .foregroundStyle(isActive ? .white : .primary)
                .clipShape(Capsule())
        }
    }

    // MARK: - Game Filters

    private var gameFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                gameFilterChip(label: "ALL", gameID: nil)
                ForEach(viewModel.gameMatchupLabels, id: \.id) { game in
                    gameFilterChip(label: game.label, gameID: game.id)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .background(Color(.systemBackground))
    }

    private func gameFilterChip(label: String, gameID: String?) -> some View {
        let isActive = viewModel.selectedGameFilter == gameID
        return Button {
            Haptics.light()
            viewModel.selectedGameFilter = gameID
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isActive ? brandPurple.opacity(0.15) : Color(.systemGray6))
                .foregroundStyle(isActive ? brandPurple : .secondary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isActive ? brandPurple : Color.clear, lineWidth: 1.5)
                )
        }
    }

    // MARK: - Player List

    private var isSingleGame: Bool {
        viewModel.tournament?.isSingleGame == true
    }

    private var playerList: some View {
        // Hoisted out of the rows: `canFillSlot` and `confirmedXITeams` each
        // rebuild the full active player pool per call. Computing them once per
        // render (instead of once per row) is what keeps this list scrollable
        // on big slates — see fillablePositions in DFSViewModel.
        let players = viewModel.filteredPlayers
        let fillable = viewModel.fillablePositions(among: Set(players.map(\.position)))
        let confirmedTeams = viewModel.confirmedXITeams
        return List {
            ForEach(players) { player in
                let isSelected = viewModel.selectedPlayerIDs.contains(player.id)
                let canAdd = isSelected || fillable.contains(player.position)
                let playerIsMVP = isSingleGame && viewModel.mvpPlayerID == player.id
                HStack(spacing: 12) {
                    // Tappable area: position badge + player info → opens detail sheet
                    Button {
                        inspectedPlayer = player
                    } label: {
                        HStack(spacing: 12) {
                            Text(playerIsMVP ? "MVP" : player.position)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(playerIsMVP ? .black : .white)
                                .frame(width: 32, height: 32)
                                .background(playerIsMVP ? Color.yellow : (isSelected ? brandPurple : Color(.systemGray3)))
                                .clipShape(playerIsMVP ? AnyShape(Capsule()) : AnyShape(Circle()))

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(player.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    if let order = player.battingOrder {
                                        Text("\(order)")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(brandPurple)
                                            .clipShape(RoundedRectangle(cornerRadius: 3))
                                    }
                                    if player.isStartingGoalie {
                                        Text("GS")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Color.green)
                                            .clipShape(RoundedRectangle(cornerRadius: 3))
                                    }
                                    // Single-game MLB: flag the starting pitchers —
                                    // the most important picks on a showdown slate.
                                    if isSingleGame && viewModel.sport == "MLB" && player.position == "SP" {
                                        Label("SP", systemImage: "baseball.fill")
                                            .labelStyle(.titleAndIcon)
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Color.green)
                                            .clipShape(RoundedRectangle(cornerRadius: 3))
                                    }
                                    if viewModel.sport == "EPL" || viewModel.sport == "UCL" || viewModel.sport == "WC" {
                                        if player.isConfirmedActive {
                                            // Confirmed starter — XI announced
                                            Label("CS", systemImage: "checkmark.circle.fill")
                                                .labelStyle(.titleAndIcon)
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Color.green)
                                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                        } else if player.playedRecently,
                                                  !confirmedTeams.contains(player.team) {
                                            // Projected starter — started or subbed
                                            // into a recent match AND their team's
                                            // XI isn't out yet. Once the XI drops,
                                            // unconfirmed players are benched, so
                                            // PS would be misleading.
                                            Label("PS", systemImage: "clock.fill")
                                                .labelStyle(.titleAndIcon)
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Color.orange)
                                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                        }
                                    }
                                    if let status = player.injuryStatus {
                                        Text(status)
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(injuryColor(for: status))
                                            .clipShape(RoundedRectangle(cornerRadius: 3))
                                    }
                                }
                                HStack(spacing: 0) {
                                    if viewModel.sport == "PGA" {
                                        Text(player.team)  // country only for golf
                                    } else if viewModel.sport == "NASCAR" {
                                        Text("Driver")     // no team concept for drivers
                                    } else {
                                        Text("\(player.team) · \(player.position)")
                                        if let opp = viewModel.opponentLabel(for: player) {
                                            Text(" · \(opp)")
                                                .foregroundStyle(brandPurple)
                                        }
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    // Stats
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("$\(viewModel.formatSalary(player.salary))")
                            .font(.subheadline.weight(.medium).monospacedDigit())
                            .foregroundStyle(.primary)
                        Text("\(String(format: "%.1f", player.projectedPoints)) FPTS")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(brandPurple)
                    }

                    // MVP crown button — tap to set as MVP (single-game only)
                    if isSingleGame && isSelected {
                        Button {
                            Haptics.medium()
                            withAnimation(.easeInOut(duration: 0.15)) {
                                viewModel.setMVP(player)
                            }
                        } label: {
                            Image(systemName: playerIsMVP ? "crown.fill" : "crown")
                                .font(.system(size: 16))
                                .foregroundStyle(playerIsMVP ? .yellow : .gray)
                        }
                        .buttonStyle(.plain)
                    }

                    // Selection toggle button
                    Button {
                        Haptics.light()
                        withAnimation(.easeInOut(duration: 0.15)) {
                            viewModel.togglePlayer(player)
                        }
                    } label: {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "plus.circle")
                            .font(.title3)
                            .foregroundStyle(isSelected ? brandPurple : canAdd ? Color.secondary : Color.gray.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                    // Late swap: lock per-player by his game's start, not the
                    // whole slate. Non-late-swap slates fall back to the
                    // whole-slate lock inside isPlayerLocked().
                    .disabled(viewModel.isPlayerLocked(player) || (!isSelected && !canAdd))
                }
                .padding(.vertical, 4)
                .listRowBackground(playerIsMVP ? Color.yellow.opacity(0.08) : isSelected ? brandPurple.opacity(0.06) : Color.clear)
            }
        }
        .listStyle(.plain)
        .sheet(item: $inspectedPlayer) { player in
            let isSelected = viewModel.selectedPlayerIDs.contains(player.id)
            if viewModel.sport == "PGA" {
                GolfPlayerDetailView(player: player, isSelected: isSelected) {
                    viewModel.togglePlayer(player)
                }
            } else {
                DFSPlayerDetailView(player: player, isSelected: isSelected) {
                    viewModel.togglePlayer(player)
                }
            }
        }
    }

    // MARK: - Submit Footer

    private var submitFooter: some View {
        VStack(spacing: 6) {
            if let message = viewModel.lineupValidationMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(viewModel.selectedSalary > viewModel.salaryCap ? .red : .secondary)
            }

            // Entry fee and entries counter
            HStack {
                if let fee = viewModel.tournament?.entryFee, fee > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "ticket.fill")
                            .font(.caption2)
                            .foregroundStyle(brandPurple)
                        Text("\(fee) RR entry fee")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text("\(viewModel.totalLineupsToday)/\(viewModel.maxLineupsPerDay) lineups today")
                    .font(.caption)
                    .foregroundStyle(viewModel.canSubmitMoreLineups ? Color.secondary : Color.red)
            }

            Button {
                Haptics.medium()
                viewModel.submitLineup()
                dismiss()
            } label: {
                Text({
                    // Routing to a private contest? Use a clearer label that
                    // mentions the private contest rather than a public
                    // "Lineup #N" — the two flows store entries separately.
                    if let priv = viewModel.activePrivateContest {
                        let hasExisting: Bool = {
                            guard let me = viewModel.userID.flatMap(UUID.init(uuidString:)) else { return false }
                            return (viewModel.privateContestEntries[priv.id] ?? []).contains(where: { $0.userID == me })
                        }()
                        return hasExisting ? "Save Private Lineup" : "Submit Private Lineup"
                    }
                    if let editNum = viewModel.editingLineupNumber {
                        return "Save Lineup #\(editNum)"
                    }
                    if let t = viewModel.tournament {
                        let lineupCount = viewModel.lineupsInTournament(t.id)
                        if lineupCount > 0 {
                            return "Submit Lineup #\(lineupCount + 1)"
                        }
                    }
                    return "Join Tournament"
                }())
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(viewModel.canSubmitLineup ? brandPurple : Color(.systemGray4))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(!viewModel.canSubmitLineup)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
        .shadow(color: .black.opacity(0.08), radius: 8, y: -4)
    }

    // MARK: - Helpers

    private func lastName(_ fullName: String) -> String {
        let parts = fullName.components(separatedBy: " ").filter { !$0.isEmpty }
        guard parts.count >= 2 else { return fullName.trimmingCharacters(in: .whitespaces) }
        let suffixes: Set<String> = ["Jr.", "Jr", "Sr.", "Sr", "II", "III", "IV", "V"]
        if let last = parts.last, suffixes.contains(last), parts.count >= 3 {
            return parts[parts.count - 2] + " " + last
        }
        return parts.last ?? fullName.trimmingCharacters(in: .whitespaces)
    }

    private func injuryColor(for status: String) -> Color {
        switch status {
        case "O", "IL10", "IL15", "IL60": return .red
        case "D": return .red.opacity(0.8)
        case "Q": return .orange
        case "GTD": return .orange
        case "P": return .green
        default: return .gray
        }
    }
}
