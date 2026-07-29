import SwiftUI

// MARK: - Lobby: one card per entry-fee tier

struct SurvivorLobbyView: View {
    @Bindable var viewModel: SurvivorViewModel

    private var brandPurple: Color { Color(red: 0.48, green: 0.23, blue: 0.93) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                rulesCard

                ForEach(SurvivorSeason.entryFees, id: \.self) { fee in
                    NavigationLink {
                        SurvivorPoolView(viewModel: viewModel, fee: fee)
                    } label: {
                        poolCard(fee: fee)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("NFL Survivor")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.loadLobby() }
        .refreshable { await viewModel.loadLobby() }
    }

    private var rulesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "football.fill")
                    .foregroundStyle(.white)
                Text("Survive the season")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Text("\(SurvivorSeason.year)")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.2))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
            Text("Pick one team to win each week. Lose (or forget to pick) and you're out. You can only use each team once all season. Last fan standing takes the pot.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Color(red: 0.05, green: 0.22, blue: 0.12), Color(red: 0.10, green: 0.42, blue: 0.20)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }

    @ViewBuilder
    private func poolCard(fee: Int) -> some View {
        let poolID = SurvivorSeason.poolID(fee: fee)
        let entries = viewModel.entriesByPool[poolID] ?? []
        let mine = viewModel.myEntry(poolID: poolID)
        let alive = viewModel.aliveCount(poolID: poolID)
        HStack(spacing: 12) {
            Text("\(fee)")
                .font(.title3.bold().monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(
                    LinearGradient(colors: [brandPurple, brandPurple.opacity(0.7)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .bottom) {
                    Text("RR")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.bottom, 4)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text("\(fee) RR Survivor Pool")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    Text("\(entries.count) \(entries.count == 1 ? "entry" : "entries")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("•")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("Pot \(fee * entries.count) RR")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if viewModel.seasonStarted && !entries.isEmpty {
                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text("\(alive) alive")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if let mine {
                let elim = viewModel.displayedElimination(poolID: poolID, entry: mine)
                Text(elim == nil ? "ALIVE" : "OUT W\(elim ?? 0)")
                    .font(.caption2.weight(.heavy))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((elim == nil ? Color.green : Color.red).opacity(0.15))
                    .foregroundStyle(elim == nil ? .green : .red)
                    .clipShape(Capsule())
            } else if !viewModel.seasonStarted {
                Text("JOIN")
                    .font(.caption2.weight(.heavy))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(brandPurple)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 3)
    }
}

// MARK: - Pool detail

struct SurvivorPoolView: View {
    @Bindable var viewModel: SurvivorViewModel
    let fee: Int

    @State private var selectedTab = 0
    @State private var showJoinConfirm = false

    private var poolID: String { SurvivorSeason.poolID(fee: fee) }
    private var brandPurple: Color { Color(red: 0.48, green: 0.23, blue: 0.93) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                headerCard

                if let winners = viewModel.poolWinners(poolID: poolID) {
                    championBanner(winners)
                }

                if viewModel.myEntry(poolID: poolID) == nil {
                    joinSection
                }

                Picker("View", selection: $selectedTab) {
                    Text("Week \(viewModel.currentWeek) Pick").tag(0)
                    Text("Standings").tag(1)
                }
                .pickerStyle(.segmented)

                if selectedTab == 0 {
                    pickSection
                } else {
                    standingsSection
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("\(fee) RR Survivor")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.loadPool(poolID) }
        .refreshable { await viewModel.loadPool(poolID) }
        .alert("Join for \(fee) RR?", isPresented: $showJoinConfirm) {
            Button("Join", role: .none) {
                Haptics.light()
                Task { _ = await viewModel.join(fee: fee) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The \(fee) RR entry fee comes off your RR balance now. Winner takes the whole pot.")
        }
        .alert("Survivor", isPresented: Binding(
            get: { viewModel.error != nil },
            set: { if !$0 { viewModel.error = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.error = nil }
        } message: {
            Text(viewModel.error ?? "")
        }
    }

    // MARK: Header

    private var headerCard: some View {
        let entries = viewModel.entriesByPool[poolID] ?? []
        return VStack(spacing: 10) {
            HStack {
                Image(systemName: "football.fill")
                    .foregroundStyle(.white.opacity(0.9))
                Text("NFL Survivor — \(fee) RR")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                statusPill
            }
            HStack(spacing: 0) {
                statCell(value: "\(entries.count)", label: "ENTRIES")
                statCell(value: "\(fee * entries.count) RR", label: "POT")
                statCell(value: viewModel.seasonStarted ? "\(viewModel.aliveCount(poolID: poolID))" : "—", label: "ALIVE")
                statCell(value: "Wk \(viewModel.currentWeek)", label: "WEEK")
            }
        }
        .padding(16)
        .background(
            LinearGradient(colors: [Color(red: 0.10, green: 0.12, blue: 0.25), Color(red: 0.17, green: 0.20, blue: 0.38)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var statusPill: some View {
        let (label, color): (String, Color) = {
            if viewModel.poolWinners(poolID: poolID) != nil { return ("FINAL", .secondary) }
            if viewModel.seasonStarted { return ("LIVE", .red) }
            return ("OPEN", .green)
        }()
        return Text(label)
            .font(.caption2.weight(.heavy))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color)
            .foregroundStyle(.white)
            .clipShape(Capsule())
    }

    private func statCell(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
    }

    private func championBanner(_ winners: [SurvivorStanding]) -> some View {
        let share = viewModel.poolShare(poolID: poolID)
        let names = winners.map(\.entry.entryName).joined(separator: ", ")
        return HStack(spacing: 10) {
            Image(systemName: "trophy.fill")
                .font(.title3)
                .foregroundStyle(Color(red: 0.95, green: 0.78, blue: 0.20))
            VStack(alignment: .leading, spacing: 2) {
                Text(winners.count == 1 ? "Champion" : "Co-champions")
                    .font(.subheadline.weight(.bold))
                Text("\(names) — +\(share) RR")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Color(red: 0.95, green: 0.78, blue: 0.20).opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Join

    private var joinSection: some View {
        let denial = viewModel.joinDenialReason(fee: fee)
        return VStack(spacing: 8) {
            Button {
                Haptics.light()
                showJoinConfirm = true
            } label: {
                Text(viewModel.isJoining ? "Joining…" : "Join for \(fee) RR")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(denial == nil ? brandPurple : Color.gray)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(denial != nil || viewModel.isJoining)
            if let denial {
                Text(denial)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Week pick

    @ViewBuilder
    private var pickSection: some View {
        let week = viewModel.currentWeek
        let games = viewModel.gamesByWeek[week] ?? []
        let locked = viewModel.isWeekLocked(week)
        let mine = viewModel.myEntry(poolID: poolID)
        let myPick = viewModel.myPick(poolID: poolID, week: week)
        let used = viewModel.usedTeams(poolID: poolID)
        let eliminated = mine.flatMap { viewModel.displayedElimination(poolID: poolID, entry: $0) } != nil

        VStack(alignment: .leading, spacing: 10) {
            if mine == nil {
                infoRow(icon: "lock", text: "Join the pool to make picks")
            } else if eliminated {
                infoRow(icon: "xmark.circle", text: "You've been eliminated — follow the standings to see who takes the pot")
            } else if let lockDate = viewModel.weekLockDate(week), !locked {
                infoRow(icon: "clock",
                        text: "Picks lock \(lockDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))")
            } else if locked, let myPick {
                infoRow(icon: "checkmark.seal", text: "Locked in: \(myPick.teamName)")
            } else if locked {
                infoRow(icon: "exclamationmark.triangle", text: "Week locked — no pick made")
            }

            if games.isEmpty {
                HStack {
                    Spacer()
                    ProgressView("Loading Week \(week) games…")
                        .font(.caption)
                    Spacer()
                }
                .padding(.vertical, 24)
            }

            ForEach(games) { game in
                gameRow(game: game, myPick: myPick, used: used,
                        canPick: mine != nil && !eliminated && !locked)
            }
        }
    }

    private func infoRow(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(brandPurple)
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(10)
        .background(.white.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func gameRow(game: SurvivorGame, myPick: SurvivorPickRecord?, used: Set<String>, canPick: Bool) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                teamButton(abbr: game.awayAbbr, name: game.awayName, game: game,
                           myPick: myPick, used: used, canPick: canPick)
                VStack(spacing: 2) {
                    Text("@")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.tertiary)
                    if game.state != "pre" {
                        Text("\(game.awayScore)-\(game.homeScore)")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Text(game.date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 56)
                teamButton(abbr: game.homeAbbr, name: game.homeName, game: game,
                           myPick: myPick, used: used, canPick: canPick)
            }
        }
        .padding(10)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
    }

    private func teamButton(abbr: String, name: String, game: SurvivorGame,
                            myPick: SurvivorPickRecord?, used: Set<String>, canPick: Bool) -> some View {
        let isPicked = myPick?.teamAbbr == abbr
        let isUsed = used.contains(abbr) && !isPicked
        let won = game.state == "post" && game.winnerAbbr == abbr
        return Button {
            guard canPick, !isUsed else { return }
            Haptics.light()
            Task { await viewModel.makePick(poolID: poolID, week: game.week, teamAbbr: abbr, teamName: name) }
        } label: {
            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    Text(abbr)
                        .font(.subheadline.weight(.heavy))
                    if isPicked {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                    }
                    if won {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(isPicked ? .white : Color(red: 0.85, green: 0.65, blue: 0.10))
                    }
                }
                Text(isUsed ? "USED" : name)
                    .font(.system(size: 9, weight: isUsed ? .bold : .regular))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(isPicked ? brandPurple : (isUsed ? Color(.systemGray5) : Color(.systemGray6)))
            .foregroundStyle(isPicked ? .white : (isUsed ? .secondary : .primary))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!canPick || isUsed)
    }

    // MARK: Standings

    @ViewBuilder
    private var standingsSection: some View {
        let rows = viewModel.standings(poolID: poolID)
        VStack(spacing: 8) {
            if rows.isEmpty {
                Text("No entries yet — be the first to join")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 24)
            }
            ForEach(rows) { row in
                standingRow(row)
            }
        }
    }

    private func standingRow(_ row: SurvivorStanding) -> some View {
        let isMe = row.entry.userID == viewModel.userID
        let shownWeeks = viewModel.seasonStarted ? (1...viewModel.currentWeek) : (1...1)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.entry.entryName)
                    .font(.subheadline.weight(isMe ? .bold : .medium))
                if isMe {
                    Text("YOU")
                        .font(.system(size: 8, weight: .heavy))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(brandPurple.opacity(0.15))
                        .foregroundStyle(brandPurple)
                        .clipShape(Capsule())
                }
                Spacer()
                Text(row.isAlive ? "ALIVE" : "OUT W\(row.eliminatedWeek ?? 0)")
                    .font(.caption2.weight(.heavy))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((row.isAlive ? Color.green : Color.red).opacity(0.15))
                    .foregroundStyle(row.isAlive ? .green : .red)
                    .clipShape(Capsule())
            }
            if viewModel.seasonStarted {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(shownWeeks), id: \.self) { week in
                            pickChip(row: row, week: week, isMe: isMe)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
    }

    @ViewBuilder
    private func pickChip(row: SurvivorStanding, week: Int, isMe: Bool) -> some View {
        let pick = viewModel.pick(poolID: poolID, userID: row.entry.userID, week: week)
        let locked = viewModel.isWeekLocked(week)
        // Everyone's current-week pick stays hidden until kickoff — only
        // you can see your own.
        let hidden = !locked && !isMe
        let (text, color): (String, Color) = {
            guard let pick else {
                if let elimWeek = row.eliminatedWeek, week == elimWeek { return ("—", .red) }
                return ("—", .secondary)
            }
            if hidden { return ("🔒", .secondary) }
            guard locked, viewModel.isWeekComplete(week),
                  let game = viewModel.gamesByWeek[week]?.first(where: { $0.involves(pick.teamAbbr) }) else {
                return (pick.teamAbbr, .secondary)
            }
            return (pick.teamAbbr, game.winnerAbbr == pick.teamAbbr ? .green : .red)
        }()
        VStack(spacing: 1) {
            Text("W\(week)")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color)
        }
        .frame(width: 34, height: 30)
        .background(color.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
