import SwiftUI

// MARK: - Lobby

struct BBTLobbyView: View {
    @Bindable var viewModel: BestBallTournamentViewModel
    @State private var showBuilder = false

    private var brandPurple: Color { Color(red: 0.48, green: 0.23, blue: 0.93) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                headerCard
                if let error = viewModel.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.red.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                rulesCard
                myEntriesCard
                leaderboardCard
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(BBTConfig.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadAll()
            viewModel.startLivePolling()
        }
        .onDisappear { viewModel.stopLivePolling() }
        .refreshable { await viewModel.loadAll(force: true) }
        .navigationDestination(isPresented: $showBuilder) {
            BBTBuilderView(viewModel: viewModel)
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(viewModel.statusLabel)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(viewModel.isLive ? Color.red : Color.white.opacity(0.2))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                Spacer()
                Text("\(String(BBTConfig.season)) Season")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            Text(BBTConfig.title)
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
            HStack(spacing: 24) {
                stat(label: viewModel.isSettled ? "Final Rank" : "Your Rank", value: viewModel.isLocked ? (viewModel.bestRank.map { "#\($0.formatted())" } ?? "—") : "—")
                stat(label: "Entries", value: "\(viewModel.myEntries.count)/\(BBTConfig.maxEntriesPerUser)")
                stat(label: "Field", value: viewModel.fieldSize.formatted())
                Spacer()
            }
            if !viewModel.isLocked {
                Text("Entries lock \(viewModel.lockTime.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
            } else if viewModel.isLive {
                Text("Week \(viewModel.currentWeek) of \(BBTConfig.totalWeeks)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
            }
            if viewModel.canAddEntry {
                Button {
                    showBuilder = true
                } label: {
                    Text(viewModel.myEntries.isEmpty ? "Build Your Roster — \(BBTConfig.entryFeeRR) RR" : "Add Entry #\(viewModel.myEntries.count + 1) — \(BBTConfig.entryFeeRR) RR")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.white)
                        .foregroundStyle(brandPurple)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(viewModel.pool.isEmpty)
            }
        }
        .padding(16)
        .background(
            LinearGradient(colors: [Color(red: 0.20, green: 0.10, blue: 0.45), Color(red: 0.48, green: 0.23, blue: 0.93)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }

    private func stat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
        }
    }

    private var rulesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How it works").font(.headline)
            ruleRow("dollarsign.circle.fill", "$\(BBTConfig.budget) budget, \(BBTConfig.rosterSize) players. Every player costs his average auction price.")
            ruleRow("person.3.fill", "1 QB · 2 RB · 3 WR · 1 TE minimum. Max 3 QB, 3 TE.")
            ruleRow("sparkles", "Best ball: your top QB, 2 RB, 3 WR, TE and FLEX score automatically every week.")
            ruleRow("trophy.fill", "\(BBTConfig.totalWeeks) weeks, \(BBTConfig.botCount.formatted()) bots, up to \(BBTConfig.maxEntriesPerUser) entries. Highest season total wins.")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
    }

    private func ruleRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(brandPurple).frame(width: 20)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var myEntriesCard: some View {
        if !viewModel.myEntries.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("My Entries")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 6)
                ForEach(viewModel.myStandings.sorted { $0.entry.entryNumber < $1.entry.entryNumber }) { s in
                    NavigationLink {
                        BBTEntryDetailView(viewModel: viewModel, standing: s)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.entry.entryName).font(.subheadline.weight(.semibold))
                                Text("$\(s.entry.spent)/$\(BBTConfig.budget) spent · \(s.entry.picks.count) players")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(viewModel.isLocked ? "#\(s.rank.formatted())" : "Entered")
                                    .font(.subheadline.weight(.bold)).foregroundStyle(brandPurple)
                                Text(String(format: "%.1f pts", s.totalPoints))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 16)
                }
            }
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
        }
    }

    private var leaderboardCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Leaderboard").font(.headline)
                Spacer()
                if viewModel.isScoring { ProgressView().controlSize(.small) }
                NavigationLink("See all") { BBTLeaderboardView(viewModel: viewModel) }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(brandPurple)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)
            if viewModel.standings.isEmpty {
                Text(viewModel.isLoading ? "Building the field…" : "Field appears once entries load.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.bottom, 14)
            } else {
                ForEach(viewModel.standings.prefix(10)) { s in
                    BBTStandingRow(standing: s, brandPurple: brandPurple)
                    Divider().padding(.leading, 16)
                }
            }
        }
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
    }
}

struct BBTStandingRow: View {
    let standing: BBTStanding
    let brandPurple: Color
    var body: some View {
        HStack(spacing: 12) {
            Text("\(standing.rank)")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(standing.rank <= 3 ? .orange : .secondary)
                .frame(width: 44, alignment: .leading)
            Text(standing.entry.entryName)
                .font(.subheadline.weight(standing.entry.isCurrentUser ? .bold : .regular))
                .foregroundStyle(standing.entry.isCurrentUser ? brandPurple : .primary)
                .lineLimit(1)
            Spacer()
            Text(String(format: "%.1f", standing.totalPoints))
                .font(.subheadline.weight(.semibold).monospacedDigit())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(standing.entry.isCurrentUser ? brandPurple.opacity(0.06) : Color.clear)
    }
}

// MARK: - Full Leaderboard

struct BBTLeaderboardView: View {
    @Bindable var viewModel: BestBallTournamentViewModel
    @State private var shown = 100
    @State private var search = ""
    private var brandPurple: Color { Color(red: 0.48, green: 0.23, blue: 0.93) }

    private var rows: [BBTStanding] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Array(viewModel.standings.prefix(shown)) }
        return viewModel.standings.filter { $0.entry.entryName.lowercased().contains(q) }
    }

    var body: some View {
        List {
            ForEach(rows) { s in
                NavigationLink {
                    BBTEntryDetailView(viewModel: viewModel, standing: s)
                } label: {
                    BBTStandingRow(standing: s, brandPurple: brandPurple)
                        .padding(.horizontal, -16)
                }
            }
            if search.isEmpty, shown < viewModel.standings.count {
                Button("Show more") { shown += 200 }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(brandPurple)
            }
        }
        .listStyle(.plain)
        .searchable(text: $search, prompt: "Search entries")
        .navigationTitle("Leaderboard · \(viewModel.fieldSize.formatted())")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Entry Detail

struct BBTEntryDetailView: View {
    @Bindable var viewModel: BestBallTournamentViewModel
    let standing: BBTStanding
    @State private var showEditor = false
    private var brandPurple: Color { Color(red: 0.48, green: 0.23, blue: 0.93) }

    /// Season points per rostered player (sum over weeks with data).
    private var seasonByPlayer: [String: Double] {
        var out: [String: Double] = [:]
        for (_, pts) in viewModel.weekPoints {
            for p in standing.entry.picks { out[p.playerID, default: 0] += pts[p.playerID] ?? 0 }
        }
        return out
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 6) {
                    Text(standing.entry.entryName).font(.title3.weight(.bold))
                    HStack(spacing: 20) {
                        VStack { Text(viewModel.isLocked ? "#\(standing.rank.formatted())" : "—").font(.title2.weight(.bold)).foregroundStyle(brandPurple); Text("Rank").font(.caption2).foregroundStyle(.secondary) }
                        VStack { Text(String(format: "%.1f", standing.totalPoints)).font(.title2.weight(.bold)); Text("Points").font(.caption2).foregroundStyle(.secondary) }
                        VStack { Text("$\(standing.entry.spent)/$\(BBTConfig.budget)").font(.title2.weight(.bold)); Text("Spent").font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Roster").font(.headline)
                        Spacer()
                        Text("SEASON PTS").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
                    let order = ["QB", "RB", "WR", "TE"]
                    ForEach(standing.entry.picks.sorted { a, b in
                        let ia = order.firstIndex(of: a.position) ?? 9, ib = order.firstIndex(of: b.position) ?? 9
                        if ia != ib { return ia < ib }
                        return a.price > b.price
                    }, id: \.playerID) { pick in
                        HStack(spacing: 10) {
                            Text(pick.position)
                                .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 30, height: 18).background(positionColor(pick.position))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(pick.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                Text(pick.team).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("$\(pick.price)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(String(format: "%.1f", seasonByPlayer[pick.playerID] ?? 0))
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .frame(width: 52, alignment: .trailing)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        Divider().padding(.leading, 56)
                    }
                }
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))

                if !standing.weeklyPoints.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Weekly").font(.headline)
                            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
                        ForEach(standing.weeklyPoints.keys.sorted(), id: \.self) { week in
                            HStack {
                                Text("Week \(week)").font(.subheadline)
                                Spacer()
                                Text(String(format: "%.1f", standing.weeklyPoints[week] ?? 0))
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                            }
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            Divider().padding(.leading, 16)
                        }
                    }
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Entry")
        .toolbar {
            if !viewModel.isLocked, standing.entry.isCurrentUser {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit") { showEditor = true }
                }
            }
        }
        .navigationDestination(isPresented: $showEditor) {
            BBTBuilderView(viewModel: viewModel, editing: standing.entry)
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func positionColor(_ pos: String) -> Color {
        switch pos {
        case "QB": return .red
        case "RB": return Color(red: 0.2, green: 0.6, blue: 0.9)
        case "WR": return .green
        case "TE": return .orange
        default: return .gray
        }
    }
}

// MARK: - Roster Builder

struct BBTBuilderView: View {
    @Bindable var viewModel: BestBallTournamentViewModel
    /// Pre-lock edit of an existing entry (nil = new entry).
    var editing: BBTEntry? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var picks: [BBTPlayer] = []
    @State private var seededFromEntry = false
    @State private var positionFilter: String = "ALL"
    @State private var search = ""
    @State private var showSubmitted = false
    private var brandPurple: Color { Color(red: 0.48, green: 0.23, blue: 0.93) }

    private var spent: Int { picks.reduce(0) { $0 + $1.price } }
    private var remaining: Int { BBTConfig.budget - spent }
    private var violation: String? { BBTRosterRules.violation(for: picks) }

    private var filtered: [BBTPlayer] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return viewModel.pool.filter { p in
            (positionFilter == "ALL" || p.position == positionFilter)
                && (q.isEmpty || p.name.lowercased().contains(q) || p.team.lowercased().contains(q))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            budgetBar
            rosterStrip
            filterChips
            playerList
            submitBar
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(editing == nil ? "Build Roster" : "Edit Roster")
        .onAppear {
            guard let editing, !seededFromEntry else { return }
            seededFromEntry = true
            picks = editing.picks.compactMap { pick in
                viewModel.pool.first { $0.id == pick.playerID }
                    ?? BBTPlayer(id: pick.playerID, name: pick.name, team: pick.team, position: pick.position,
                                 price: pick.price, adp: nil, projectedPoints: 0)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search players or teams")
        .alert("Entry submitted", isPresented: $showSubmitted) {
            Button("Done") { dismiss() }
        } message: {
            Text("Your roster is in. Best ball scoring starts Week 1.")
        }
    }

    private var budgetBar: some View {
        VStack(spacing: 6) {
            HStack {
                Text("BUDGET").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                Spacer()
                Text("$\(spent) / $\(BBTConfig.budget)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(remaining < 0 ? .red : .primary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.systemGray5))
                    Capsule().fill(remaining < 0 ? Color.red : brandPurple)
                        .frame(width: geo.size.width * min(1, Double(spent) / Double(BBTConfig.budget)))
                }
            }
            .frame(height: 8)
            HStack {
                Text("$\(max(0, remaining)) remaining").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(picks.count)/\(BBTConfig.rosterSize) players").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.white)
    }

    private var rosterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(picks) { p in
                    HStack(spacing: 4) {
                        Text(p.position).font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 2).background(brandPurple).clipShape(Capsule())
                        Text(p.name.split(separator: " ").last.map(String.init) ?? p.name).font(.caption.weight(.medium)).lineLimit(1)
                        Text("$\(p.price)").font(.caption2).foregroundStyle(.secondary)
                        Button { picks.removeAll { $0.id == p.id } } label: {
                            Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(Color(.systemGray6))
                    .clipShape(Capsule())
                }
                if picks.isEmpty {
                    Text("Tap players to add them").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .background(.white)
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(["ALL"] + BBTConfig.positions, id: \.self) { pos in
                    let count = picks.filter { $0.position == pos }.count
                    Button {
                        positionFilter = pos
                    } label: {
                        HStack(spacing: 4) {
                            Text(pos)
                            if pos != "ALL", let min = BBTConfig.minByPosition[pos] {
                                Text("\(count)/\(min)+").font(.caption2)
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(positionFilter == pos ? brandPurple : Color(.systemGray6))
                        .foregroundStyle(positionFilter == pos ? .white : .primary)
                        .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    private var playerList: some View {
        List {
            ForEach(filtered) { p in
                let selected = picks.contains { $0.id == p.id }
                let blocker = selected ? nil : BBTRosterRules.canAdd(p, to: picks)
                Button {
                    if selected { picks.removeAll { $0.id == p.id } }
                    else if blocker == nil { picks.append(p) }
                } label: {
                    HStack(spacing: 10) {
                        Text(p.position).font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 30, height: 18).background(selected ? brandPurple : Color(.systemGray3))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name).font(.subheadline.weight(selected ? .semibold : .regular)).lineLimit(1)
                            Text(p.adp.map { "\(p.team) · ADP \(String(format: "%.0f", $0))" } ?? p.team)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("$\(p.price)")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(blocker == nil || selected ? .primary : .tertiary)
                        Image(systemName: selected ? "checkmark.circle.fill" : "plus.circle")
                            .foregroundStyle(selected ? brandPurple : (blocker == nil ? Color.secondary : Color(.systemGray4)))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!selected && blocker != nil)
                .listRowBackground(selected ? brandPurple.opacity(0.06) : Color.white)
            }
        }
        .listStyle(.plain)
    }

    private var submitBar: some View {
        VStack(spacing: 6) {
            if let v = violation {
                Text(v).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(editing == nil ? "Roster is legal · \(BBTConfig.entryFeeRR) RR entry" : "Roster is legal · edits are free until lock")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button {
                Task {
                    if let editing {
                        if await viewModel.updateEntry(entryID: editing.id, picks: picks) { dismiss() }
                    } else if await viewModel.submitEntry(picks: picks) {
                        showSubmitted = true
                    }
                }
            } label: {
                Text(viewModel.isSubmitting ? (editing == nil ? "Submitting…" : "Saving…")
                     : (editing == nil ? "Submit Entry #\(viewModel.myEntries.count + 1)" : "Save Changes"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(violation == nil && !viewModel.isSubmitting ? brandPurple : Color(.systemGray4))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(violation != nil || viewModel.isSubmitting)
            if let error = viewModel.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(16)
        .background(.white)
    }
}
