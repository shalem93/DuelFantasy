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
            if viewModel.tournament?.isSingleGame != true && viewModel.sport != "PGA" {
                positionFilters
            }
            if !viewModel.gameMatchupLabels.isEmpty && viewModel.tournament?.isSingleGame != true && viewModel.sport != "PGA" {
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
                            // For main slate: show all lineups of the same type
                            if DFSTournamentType.from(tournamentID: tid) == currentType {
                                entries.append(contentsOf: records)
                            }
                        }
                    }
                    return entries
                }()
                if !allSlateEntries.isEmpty {
                    Menu {
                        ForEach(Array(allSlateEntries.enumerated()), id: \.offset) { idx, entry in
                            Button {
                                viewModel.loadLineupFromEntry(entry)
                            } label: {
                                let num = entry.lineupNumber ?? (idx + 1)
                                let names = (entry.lineupPlayerNames ?? []).prefix(3).map {
                                    $0.components(separatedBy: " ").last ?? $0
                                }.joined(separator: ", ")
                                Label("Lineup #\(num) — \(names)…", systemImage: "doc.on.clipboard")
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
        List {
            ForEach(viewModel.filteredPlayers) { player in
                let isSelected = viewModel.selectedPlayerIDs.contains(player.id)
                let canAdd = isSelected || viewModel.canFillSlot(player)
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
                                    if player.isConfirmedActive && (viewModel.sport == "EPL" || viewModel.sport == "UCL") {
                                        Text("CS")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(brandPurple)
                                            .clipShape(RoundedRectangle(cornerRadius: 3))
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
                    .disabled(viewModel.isTournamentLocked || (!isSelected && !canAdd))
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
