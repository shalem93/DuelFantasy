import SwiftUI

struct BestBallMatchupView: View {
    @Bindable var viewModel: BestBallViewModel
    let initialMatchup: BestBallMatchup

    private var brandPurple: Color {
        Color(red: 0.48, green: 0.23, blue: 0.93)
    }

    /// The matchup for the currently selected week between the same two members,
    /// falling back to the initial matchup if not found.
    private var matchup: BestBallMatchup {
        viewModel.currentWeekMatchups.first(where: {
            ($0.member1ID == initialMatchup.member1ID && $0.member2ID == initialMatchup.member2ID) ||
            ($0.member1ID == initialMatchup.member2ID && $0.member2ID == initialMatchup.member1ID)
        }) ?? viewModel.currentWeekMatchups.first(where: {
            $0.member1ID == initialMatchup.member1ID || $0.member2ID == initialMatchup.member1ID ||
            $0.member1ID == initialMatchup.member2ID || $0.member2ID == initialMatchup.member2ID
        }) ?? initialMatchup
    }

    private var roster1: [BestBallPick] {
        viewModel.draftState?.roster(for: matchup.member1ID) ?? []
    }

    private var roster2: [BestBallPick] {
        viewModel.draftState?.roster(for: matchup.member2ID) ?? []
    }

    private var weekScore1: BestBallWeeklyScore? {
        viewModel.weeklyScores.first(where: { $0.memberID == matchup.member1ID && $0.week == matchup.week })
    }

    private var weekScore2: BestBallWeeklyScore? {
        viewModel.weeklyScores.first(where: { $0.memberID == matchup.member2ID && $0.week == matchup.week })
    }

    private var scoringSet1: Set<String> {
        Set(weekScore1?.scoringPlayerIDs ?? [])
    }

    private var scoringSet2: Set<String> {
        Set(weekScore2?.scoringPlayerIDs ?? [])
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Week navigator
                weekNavigator

                // Score banner at top
                scoreBanner

                // Week info
                weekInfoBar

                // Position-by-position comparison
                positionComparison

                // Bench sections
                benchComparison
            }
        }
        .navigationTitle("Week \(viewModel.selectedWeek) Matchup")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Week Navigator

    private var weekNavigator: some View {
        let totalWeeks = viewModel.currentLeague?.totalWeeks ?? 1

        return HStack {
            Button {
                if viewModel.selectedWeek > 1 {
                    viewModel.selectedWeek -= 1
                    if let league = viewModel.currentLeague {
                        viewModel.loadMatchupsForWeek(week: viewModel.selectedWeek, league: league)
                    }
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .foregroundStyle(viewModel.selectedWeek > 1 ? brandPurple : .secondary)
            }
            .disabled(viewModel.selectedWeek <= 1)

            Spacer()

            Text("Week \(viewModel.selectedWeek)")
                .font(.headline)

            Spacer()

            Button {
                if viewModel.selectedWeek < totalWeeks {
                    viewModel.selectedWeek += 1
                    if let league = viewModel.currentLeague {
                        viewModel.loadMatchupsForWeek(week: viewModel.selectedWeek, league: league)
                    }
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.headline)
                    .foregroundStyle(viewModel.selectedWeek < totalWeeks ? brandPurple : .secondary)
            }
            .disabled(viewModel.selectedWeek >= totalWeeks)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.white)
    }

    // MARK: - Score Banner

    private var scoreBanner: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center) {
                // Team 1
                VStack(spacing: 4) {
                    Text(viewModel.memberName(for: matchup.member1ID))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(String(format: "%.1f", matchup.member1Score))
                        .font(.system(size: 32, weight: .bold).monospacedDigit())
                        .foregroundStyle(matchup.winnerID == matchup.member1ID ? brandPurple : .primary)
                    if let ws = weekScore1 {
                        let gamesPlayed = ws.playerPoints.count
                        Text("\(gamesPlayed) games")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)

                // VS divider
                VStack(spacing: 4) {
                    if matchup.winnerID == matchup.member1ID {
                        Image(systemName: "arrowtriangle.left.fill")
                            .font(.caption2)
                            .foregroundStyle(brandPurple)
                    } else if matchup.winnerID == matchup.member2ID {
                        Image(systemName: "arrowtriangle.right.fill")
                            .font(.caption2)
                            .foregroundStyle(brandPurple)
                    }
                    Text("VS")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.tertiary)
                }

                // Team 2
                VStack(spacing: 4) {
                    Text(viewModel.memberName(for: matchup.member2ID))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(String(format: "%.1f", matchup.member2Score))
                        .font(.system(size: 32, weight: .bold).monospacedDigit())
                        .foregroundStyle(matchup.winnerID == matchup.member2ID ? brandPurple : .primary)
                    if let ws = weekScore2 {
                        let gamesPlayed = ws.playerPoints.count
                        Text("\(gamesPlayed) games")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(20)
        .background(.white)
    }

    // MARK: - Week Info Bar

    private var weekInfoBar: some View {
        HStack {
            Text("Matchup Totals")
                .font(.caption.weight(.semibold))
            Spacer()
            Text("Week \(matchup.week)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
    }

    // MARK: - Starter Comparison

    private var sport: String {
        viewModel.currentLeague?.sport ?? "NBA"
    }

    private var positionComparison: some View {
        let slots1 = buildScoringSlots(roster: roster1, scoringSet: scoringSet1, weekScore: weekScore1)
        let slots2 = buildScoringSlots(roster: roster2, scoringSet: scoringSet2, weekScore: weekScore2)

        return VStack(spacing: 0) {
            if sport == "MLB" {
                // Split into pitchers and batters
                let pitchers1 = slots1.filter { BestBallLineupConfig.isPitcher($0.pick.playerPosition) }
                let pitchers2 = slots2.filter { BestBallLineupConfig.isPitcher($0.pick.playerPosition) }
                let batters1 = slots1.filter { !BestBallLineupConfig.isPitcher($0.pick.playerPosition) }
                let batters2 = slots2.filter { !BestBallLineupConfig.isPitcher($0.pick.playerPosition) }

                mlbMatchupSection(title: "PITCHERS", badge: "P", slots1: pitchers1, slots2: pitchers2)
                mlbMatchupSection(title: "BATTERS", badge: "UTIL", slots1: batters1, slots2: batters2)
                    .padding(.top, 12)
            } else if sport == "NFL" || sport == "CFB" || sport == "EPL", let league = viewModel.currentLeague {
                // For NFL/EPL we render starters by their lineup slot
                // (QB → RB → … / GK → DEF → MID → FWD → FLEX) so the matchup
                // reads like a standard fantasy box score rather than a
                // flat FLEX list.
                let constraints = BestBallLineupConfig.requirements(for: league).constraints
                let rawOrdered1 = orderedSlots(team: slots1, constraints: constraints)
                let rawOrdered2 = orderedSlots(team: slots2, constraints: constraints)
                let ordered1 = padSlots(rawOrdered1, toMatch: rawOrdered2, roster: roster1, weekScore: weekScore1)
                let ordered2 = padSlots(rawOrdered2, toMatch: rawOrdered1, roster: roster2, weekScore: weekScore2)
                let count = max(ordered1.count, ordered2.count)
                VStack(spacing: 0) {
                    ForEach(0..<count, id: \.self) { index in
                        let row1 = index < ordered1.count ? ordered1[index] : nil
                        let row2 = index < ordered2.count ? ordered2[index] : nil
                        // Same constraint ordering on both sides means both
                        // teams hit each slot label in sync; fall back to
                        // either side's label if one team has no scoring
                        // player for that row.
                        let badge = row1?.label ?? row2?.label ?? "FLEX"
                        matchupRow(badge: badge, player1: row1?.entry, player2: row2?.entry)
                        if index < count - 1 { Divider() }
                    }
                }
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
                .padding(.horizontal, 16)
                .padding(.top, 12)
            } else {
                let count = max(slots1.count, slots2.count)
                let filled1 = padEntries(slots1, to: count, roster: roster1, weekScore: weekScore1)
                let filled2 = padEntries(slots2, to: count, roster: roster2, weekScore: weekScore2)
                VStack(spacing: 0) {
                    ForEach(0..<count, id: \.self) { index in
                        let player1 = index < filled1.count ? filled1[index] : nil
                        let player2 = index < filled2.count ? filled2[index] : nil

                        matchupRow(badge: "FLEX", player1: player1, player2: player2)

                        if index < count - 1 {
                            Divider()
                        }
                    }
                }
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
        }
    }

    /// Mid-week, one side often has fewer scoring starters than the other
    /// (its players haven't played yet), leaving half-empty rows where the
    /// lone player floats ambiguously. Fill the short side's missing rows
    /// with that team's unused roster players (shown with "-" points) so
    /// every row pairs a player from each team.
    private func padSlots(
        _ slots: [(label: String, entry: (pick: BestBallPick, pts: Double))],
        toMatch other: [(label: String, entry: (pick: BestBallPick, pts: Double))],
        roster: [BestBallPick],
        weekScore: BestBallWeeklyScore?
    ) -> [(label: String, entry: (pick: BestBallPick, pts: Double))] {
        guard slots.count < other.count else { return slots }
        var out = slots
        var used = Set(slots.map { $0.entry.pick.playerID })
        for idx in slots.count..<other.count {
            let label = other[idx].label
            let candidate = roster.first(where: { p in
                !used.contains(p.playerID) && Self.positionFits(p.playerPosition, slotLabel: label)
            }) ?? roster.first(where: { !used.contains($0.playerID) })
            guard let filler = candidate else { break }
            used.insert(filler.playerID)
            let pts = weekScore?.playerPoints[filler.playerID] ?? 0
            out.append((label: label, entry: (pick: filler, pts: pts)))
        }
        return out
    }

    /// Label-free variant for the flat-list sports (and MLB sections).
    private func padEntries(
        _ entries: [(pick: BestBallPick, pts: Double)],
        to count: Int,
        roster: [BestBallPick],
        weekScore: BestBallWeeklyScore?,
        eligible: (BestBallPick) -> Bool = { _ in true }
    ) -> [(pick: BestBallPick, pts: Double)] {
        guard entries.count < count else { return entries }
        var out = entries
        var used = Set(entries.map { $0.pick.playerID })
        for pick in roster where out.count < count {
            guard !used.contains(pick.playerID), eligible(pick) else { continue }
            used.insert(pick.playerID)
            out.append((pick: pick, pts: weekScore?.playerPoints[pick.playerID] ?? 0))
        }
        return out
    }

    private static func positionFits(_ position: String, slotLabel: String) -> Bool {
        let label = slotLabel.uppercased()
        if label.contains("FLEX") || label == "UTIL" { return true }
        let pos = position.uppercased()
        return pos == label || pos.hasPrefix(label) || label.hasPrefix(pos)
    }

    /// Assigns a team's scoring starters to canonical NFL lineup slots
    /// (QB, RB, RB, WR, WR, TE, FLEX, FLEX) so the matchup rows pair like
    /// slots across both sides.
    private func orderedSlots(
        team: [(pick: BestBallPick, pts: Double)],
        constraints: [BestBallPositionRequirement]
    ) -> [(label: String, entry: (pick: BestBallPick, pts: Double))] {
        let positions = Dictionary(uniqueKeysWithValues: team.map { ($0.pick.playerID, $0.pick.playerPosition) })
        let points = Dictionary(uniqueKeysWithValues: team.map { ($0.pick.playerID, $0.pts) })
        let byID = Dictionary(uniqueKeysWithValues: team.map { ($0.pick.playerID, $0) })
        let assigned = BestBallLineupConfig.assignStartersToSlots(
            scoringIDs: team.map { $0.pick.playerID },
            positions: positions,
            points: points,
            constraints: constraints
        )
        return assigned.compactMap { slot in
            guard let entry = byID[slot.playerID] else { return nil }
            return (label: slot.label, entry: entry)
        }
    }

    private func mlbMatchupSection(
        title: String,
        badge: String,
        slots1: [(pick: BestBallPick, pts: Double)],
        slots2: [(pick: BestBallPick, pts: Double)]
    ) -> some View {
        let count = max(slots1.count, slots2.count)
        let isPitcherSection = title == "PITCHERS"
        let filled1 = padEntries(slots1, to: count, roster: roster1, weekScore: weekScore1) {
            BestBallLineupConfig.isPitcher($0.playerPosition) == isPitcherSection
        }
        let filled2 = padEntries(slots2, to: count, roster: roster2, weekScore: weekScore2) {
            BestBallLineupConfig.isPitcher($0.playerPosition) == isPitcherSection
        }

        return VStack(spacing: 0) {
            // Section header
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Rectangle()
                    .fill(Color(.systemGray4))
                    .frame(height: 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ForEach(0..<count, id: \.self) { index in
                let player1 = index < filled1.count ? filled1[index] : nil
                let player2 = index < filled2.count ? filled2[index] : nil

                matchupRow(badge: badge, player1: player1, player2: player2)

                if index < count - 1 {
                    Divider()
                }
            }
        }
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
        .padding(.horizontal, 16)
    }

    // MARK: - Bench Comparison

    /// IDs actually rendered in the starters section above. Before a week
    /// has scores, `scoringSet` is EMPTY — the old bench filter
    /// (roster minus scoring set) therefore excluded nobody and the bench
    /// listed the entire roster under the projected lineup.
    private func displayedStarterIDs(
        roster: [BestBallPick], scoringSet: Set<String>, weekScore: BestBallWeeklyScore?
    ) -> Set<String> {
        if !scoringSet.isEmpty { return scoringSet }
        let slots = buildScoringSlots(roster: roster, scoringSet: scoringSet, weekScore: weekScore)
        if sport == "NFL" || sport == "CFB" || sport == "EPL", let league = viewModel.currentLeague {
            let constraints = BestBallLineupConfig.requirements(for: league).constraints
            return Set(orderedSlots(team: slots, constraints: constraints).map { $0.entry.pick.playerID })
        }
        // Other sports display the full pre-score pool as "starters" —
        // mirror that so the bench is empty rather than a duplicate list.
        return Set(slots.map { $0.pick.playerID })
    }

    /// Player IDs the padding pulled up into the starter rows (per team) —
    /// the bench must exclude them or fillers render twice. Mirrors each
    /// positionComparison branch; deterministic because the padders walk the
    /// roster in stable order.
    private func fillerStarterIDs() -> (Set<String>, Set<String>) {
        let slots1 = buildScoringSlots(roster: roster1, scoringSet: scoringSet1, weekScore: weekScore1)
        let slots2 = buildScoringSlots(roster: roster2, scoringSet: scoringSet2, weekScore: weekScore2)
        if sport == "MLB" {
            var f1 = Set<String>(), f2 = Set<String>()
            for isPitcher in [true, false] {
                let a1 = slots1.filter { BestBallLineupConfig.isPitcher($0.pick.playerPosition) == isPitcher }
                let a2 = slots2.filter { BestBallLineupConfig.isPitcher($0.pick.playerPosition) == isPitcher }
                let n = max(a1.count, a2.count)
                let p1 = padEntries(a1, to: n, roster: roster1, weekScore: weekScore1) { BestBallLineupConfig.isPitcher($0.playerPosition) == isPitcher }
                let p2 = padEntries(a2, to: n, roster: roster2, weekScore: weekScore2) { BestBallLineupConfig.isPitcher($0.playerPosition) == isPitcher }
                f1.formUnion(p1.dropFirst(a1.count).map { $0.pick.playerID })
                f2.formUnion(p2.dropFirst(a2.count).map { $0.pick.playerID })
            }
            return (f1, f2)
        }
        if sport == "NFL" || sport == "CFB" || sport == "EPL", let league = viewModel.currentLeague {
            let constraints = BestBallLineupConfig.requirements(for: league).constraints
            let o1 = orderedSlots(team: slots1, constraints: constraints)
            let o2 = orderedSlots(team: slots2, constraints: constraints)
            let p1 = padSlots(o1, toMatch: o2, roster: roster1, weekScore: weekScore1)
            let p2 = padSlots(o2, toMatch: o1, roster: roster2, weekScore: weekScore2)
            return (Set(p1.dropFirst(o1.count).map { $0.entry.pick.playerID }),
                    Set(p2.dropFirst(o2.count).map { $0.entry.pick.playerID }))
        }
        let n = max(slots1.count, slots2.count)
        let p1 = padEntries(slots1, to: n, roster: roster1, weekScore: weekScore1)
        let p2 = padEntries(slots2, to: n, roster: roster2, weekScore: weekScore2)
        return (Set(p1.dropFirst(slots1.count).map { $0.pick.playerID }),
                Set(p2.dropFirst(slots2.count).map { $0.pick.playerID }))
    }

    private var benchComparison: some View {
        let fillers = fillerStarterIDs()
        let starterIDs1 = displayedStarterIDs(roster: roster1, scoringSet: scoringSet1, weekScore: weekScore1).union(fillers.0)
        let starterIDs2 = displayedStarterIDs(roster: roster2, scoringSet: scoringSet2, weekScore: weekScore2).union(fillers.1)
        let bench1 = roster1.filter { !starterIDs1.contains($0.playerID) }
        let bench2 = roster2.filter { !starterIDs2.contains($0.playerID) }
        let maxBench = max(bench1.count, bench2.count)

        return VStack(spacing: 0) {
            // Bench header
            HStack {
                Text("BENCH")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Rectangle()
                    .fill(Color(.systemGray4))
                    .frame(height: 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ForEach(0..<maxBench, id: \.self) { index in
                let p1 = index < bench1.count ? bench1[index] : nil
                let p2 = index < bench2.count ? bench2[index] : nil
                benchRow(player1: p1, player2: p2)

                if index < maxBench - 1 {
                    Divider()
                }
            }
        }
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Matchup Row (Side-by-Side)

    private func matchupRow(
        badge: String,
        player1: (pick: BestBallPick, pts: Double)?,
        player2: (pick: BestBallPick, pts: Double)?
    ) -> some View {
        HStack(spacing: 0) {
            // Team 1 player — name anchored to the LEFT edge. Trailing
            // alignment made short names hug the center chip, so an
            // unpaired team-1 player ("Cody Gakpo  9.1  [FWD]  -")
            // floated mid-row and read as the opponent's player.
            if let p1 = player1 {
                VStack(alignment: .leading, spacing: 2) {
                    Text(p1.pick.playerName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text("\(p1.pick.playerPosition) · \(p1.pick.playerTeam)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Points box
                Text(p1.pts > 0 ? String(format: "%.1f", p1.pts) : "-")
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .foregroundStyle(p1.pts > (player2?.pts ?? 0) ? brandPurple : .primary)
                    .frame(width: 48, alignment: .trailing)
                    .padding(.trailing, 4)
            } else {
                Spacer()
                Text("-")
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .foregroundStyle(.quaternary)
                    .frame(width: 48, alignment: .trailing)
                    .padding(.trailing, 4)
            }

            // Slot badge (center)
            Text(badge)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 20)
                .background(Color(.systemGray))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            // Team 2 player — name anchored to the RIGHT edge (mirror of team 1).
            if let p2 = player2 {
                Text(p2.pts > 0 ? String(format: "%.1f", p2.pts) : "-")
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .foregroundStyle(p2.pts > (player1?.pts ?? 0) ? brandPurple : .primary)
                    .frame(width: 48, alignment: .leading)
                    .padding(.leading, 4)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(p2.pick.playerName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text("\(p2.pick.playerPosition) · \(p2.pick.playerTeam)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Text("-")
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .foregroundStyle(.quaternary)
                    .frame(width: 48, alignment: .leading)
                    .padding(.leading, 4)
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    // MARK: - Bench Row

    private func benchRow(player1: BestBallPick?, player2: BestBallPick?) -> some View {
        let pts1 = player1.flatMap { weekScore1?.playerPoints[$0.playerID] } ?? 0
        let pts2 = player2.flatMap { weekScore2?.playerPoints[$0.playerID] } ?? 0

        return HStack(spacing: 0) {
            // Team 1 — name anchored left (matches matchupRow)
            if let p1 = player1 {
                VStack(alignment: .leading, spacing: 1) {
                    Text(p1.playerName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("\(p1.playerPosition) · \(p1.playerTeam)")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(pts1 > 0 ? String(format: "%.1f", pts1) : "-")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            } else {
                Spacer()
                Text("")
                    .frame(width: 40)
            }

            // Center spacer
            Rectangle()
                .fill(.clear)
                .frame(width: 32)

            // Team 2 — name anchored right (matches matchupRow)
            if let p2 = player2 {
                Text(pts2 > 0 ? String(format: "%.1f", pts2) : "-")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)

                VStack(alignment: .trailing, spacing: 1) {
                    Text(p2.playerName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("\(p2.playerPosition) · \(p2.playerTeam)")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Text("")
                    .frame(width: 40)
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Build Scoring Slots

    /// Returns roster players with their points, sorted by pts desc.
    /// If scoringSet is empty (no scoring data yet), includes ALL roster players.
    /// Otherwise includes only scoring starters.
    private func buildScoringSlots(
        roster: [BestBallPick],
        scoringSet: Set<String>,
        weekScore: BestBallWeeklyScore?
    ) -> [(pick: BestBallPick, pts: Double)] {
        let eligible = scoringSet.isEmpty ? roster : roster.filter { scoringSet.contains($0.playerID) }
        return eligible
            .map { pick in (pick: pick, pts: weekScore?.playerPoints[pick.playerID] ?? 0) }
            .sorted { $0.pts > $1.pts }
    }

}
