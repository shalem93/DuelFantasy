import SwiftUI

struct BestBallRosterView: View {
    @Bindable var viewModel: BestBallViewModel
    let memberID: String
    @State private var detailPlayer: BBPlayerRef? = nil

    private var brandPurple: Color {
        Color(red: 0.48, green: 0.23, blue: 0.93)
    }

    private var memberName: String {
        viewModel.memberName(for: memberID)
    }

    private var roster: [BestBallPick] {
        viewModel.draftState?.roster(for: memberID) ?? []
    }

    private var sport: String {
        viewModel.currentLeague?.sport ?? "NBA"
    }

    // Current week's scoring player IDs (the best-8 starters)
    private var scoringPlayerIDs: Set<String> {
        let weekScore = viewModel.weeklyScores
            .first(where: { $0.memberID == memberID && $0.week == viewModel.selectedWeek })
        return Set(weekScore?.scoringPlayerIDs ?? [])
    }

    // Current week's total per-player points
    private var weeklyPlayerPoints: [String: Double] {
        viewModel.weeklyScores
            .first(where: { $0.memberID == memberID && $0.week == viewModel.selectedWeek })?
            .playerPoints ?? [:]
    }

    // Today's points from daily scores
    private var todayPlayerPoints: [String: Double] {
        viewModel.dailyPlayerPoints(for: memberID)
    }

    // Today's stats from daily scores
    private var todayPlayerStats: [String: [String: Double]] {
        viewModel.dailyPlayerStats(for: memberID)
    }

    // Weekly stats
    private var weeklyPlayerStats: [String: [String: Double]] {
        viewModel.weeklyScores
            .first(where: { $0.memberID == memberID && $0.week == viewModel.selectedWeek })?
            .playerStats ?? [:]
    }

    // Matchup result for current week
    private var weekScore: BestBallWeeklyScore? {
        viewModel.weeklyScores
            .first(where: { $0.memberID == memberID && $0.week == viewModel.selectedWeek })
    }

    // Sorted roster: starters first, then bench. Within each group sort
    // by POSITION first (QB → RB → WR → TE for NFL, etc.), then by
    // points within the same position. Position-grouping matches what
    // people expect from a fantasy roster screen — easier to scan than
    // a flat points-descending list.
    private var sortedRoster: [BestBallPick] {
        let sport = viewModel.currentLeague?.sport ?? "NFL"
        return roster.sorted { a, b in
            let aScoring = scoringPlayerIDs.contains(a.playerID)
            let bScoring = scoringPlayerIDs.contains(b.playerID)
            if aScoring != bScoring { return aScoring }
            let aRank = positionSortRank(a.playerPosition, sport: sport)
            let bRank = positionSortRank(b.playerPosition, sport: sport)
            if aRank != bRank { return aRank < bRank }
            if isDingersOnly {
                let aHR = seasonHRTotals[a.playerID] ?? 0
                let bHR = seasonHRTotals[b.playerID] ?? 0
                return aHR > bHR
            }
            let aPts = weeklyPlayerPoints[a.playerID] ?? 0
            let bPts = weeklyPlayerPoints[b.playerID] ?? 0
            return aPts > bPts
        }
    }

    private func positionSortRank(_ position: String, sport: String) -> Int {
        let order: [String]
        switch sport {
        case "NFL", "CFB": order = ["QB", "RB", "FB", "WR", "TE", "K"]
        case "NBA": order = ["PG", "SG", "SF", "PF", "C"]
        case "MLB": order = ["SP", "RP", "P", "C", "1B", "2B", "3B", "SS", "LF", "CF", "RF", "OF", "DH"]
        case "EPL": order = ["GK", "DEF", "MID", "FWD"]
        default:    order = []
        }
        return order.firstIndex(of: position) ?? Int.max
    }

    private var isDingersOnly: Bool {
        viewModel.currentLeague?.isDingersOnly == true
    }

    // Season-total HR per player for dingers-only.
    // Uses liveHRByMember which fetches the full season range from ESPN directly.
    private var seasonHRTotals: [String: Double] {
        guard isDingersOnly else { return [:] }
        return viewModel.liveHRByMember[memberID] ?? [:]
    }

    // Season total HR count
    private var seasonTotalHR: Double {
        seasonHRTotals.values.reduce(0, +)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isDingersOnly {
                // Week navigator
                weekNavigator

                // Date selector — daily granularity only makes sense for
                // sports that play every day (MLB/NBA). Football is one
                // slate a week, so the MON–SUN strip was just noise.
                if sport != "NFL" && sport != "CFB" {
                    dateSelector
                }
            }

            ScrollView {
                VStack(spacing: 12) {
                    // H2H result banner (hidden for dingers-only)
                    if let ws = weekScore, viewModel.currentLeague?.scoringMode == .normal {
                        matchupResultBanner(ws)
                    }

                    // Week total header
                    weekTotalHeader

                    if sport == "MLB" {
                        let isDingersOnly = viewModel.currentLeague?.isDingersOnly == true

                        if !isDingersOnly {
                            // Pitchers section
                            mlbRosterSection(
                                title: "PITCHERS",
                                players: sortedRoster.filter { BestBallLineupConfig.isPitcher($0.playerPosition) },
                                isPitcher: true
                            )
                        }

                        // Batters section
                        mlbRosterSection(
                            title: isDingersOnly ? "BATTERS (HR)" : "BATTERS",
                            players: sortedRoster.filter { !BestBallLineupConfig.isPitcher($0.playerPosition) },
                            isPitcher: false
                        )
                    } else {
                        // Non-MLB: single section with all players
                        statColumnHeader(isPitcher: false)

                        VStack(spacing: 0) {
                            // Slot-aware starter ordering for NFL: assign each
                            // scoring player to QB/RB/WR/TE/FLEX in the league's
                            // lineup config and render in that order. The slot
                            // label shows what role they're filling — so a top
                            // RB scoring into the FLEX spot reads "FLEX" rather
                            // than "RB" again. Other sports keep the existing
                            // position-rank sort.
                            let starterEntries = sportSpecificStarterEntries()
                            // Bench = whatever isn't shown in the starter
                            // slots above (scoringPlayerIDs is empty before
                            // the week scores, which used to bench everyone).
                            let starterIDs = Set(starterEntries.map { $0.pick.playerID })
                            let bench = sortedRoster.filter { !starterIDs.contains($0.playerID) }

                            ForEach(starterEntries, id: \.pick.id) { entry in
                                // Slot fillers (roster players holding an
                                // empty lineup slot mid-week) don't get the
                                // scoring star until they actually score.
                                let scoring = scoringPlayerIDs.isEmpty || scoringPlayerIDs.contains(entry.pick.playerID)
                                playerRow(pick: entry.pick, isScoring: scoring, isPitcher: false, slotLabel: entry.slotLabel)
                                Divider().padding(.leading, 44)
                            }

                            if !bench.isEmpty && !starterEntries.isEmpty {
                                benchDivider
                            }

                            ForEach(bench) { pick in
                                playerRow(pick: pick, isScoring: false, isPitcher: false, slotLabel: nil)
                                if pick.id != bench.last?.id {
                                    Divider().padding(.leading, 44)
                                }
                            }
                        }
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle(memberName)
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
        .sheet(item: $detailPlayer) { ref in
            BestBallPlayerDetailSheet(viewModel: viewModel, player: ref)
        }
        .task {
            if let league = viewModel.currentLeague {
                if league.isDingersOnly {
                    // Fetch today's live HR data directly from ESPN
                    await viewModel.refreshDingersLive(leagueID: league.id)
                } else {
                    await viewModel.loadDailyScores(leagueID: league.id, week: viewModel.selectedWeek)
                    // Football has no date strip (whose onAppear triggers
                    // this for the daily sports), so load fixtures here.
                    await viewModel.loadDayFixtures()
                }
            }
        }
    }

    // MARK: - Week Navigator

    private var weekNavigator: some View {
        let totalWeeks = viewModel.currentLeague?.totalWeeks ?? 1

        return HStack {
            Button {
                if viewModel.selectedWeek > 1 {
                    viewModel.selectedWeek -= 1
                    onWeekChanged()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(viewModel.selectedWeek > 1 ? brandPurple : Color(.systemGray4))
            }
            .disabled(viewModel.selectedWeek <= 1)

            Spacer()

            Text("Week \(viewModel.selectedWeek) of \(totalWeeks)")
                .font(.subheadline.weight(.semibold))

            Spacer()

            Button {
                if viewModel.selectedWeek < totalWeeks {
                    viewModel.selectedWeek += 1
                    onWeekChanged()
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(viewModel.selectedWeek < totalWeeks ? brandPurple : Color(.systemGray4))
            }
            .disabled(viewModel.selectedWeek >= totalWeeks)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.white)
    }

    private func onWeekChanged() {
        guard let league = viewModel.currentLeague else { return }
        viewModel.loadMatchupsForWeek(week: viewModel.selectedWeek, league: league)
        // Set date to start of new week
        let (weekStart, _) = BestBallSeasonHelper.weekDateRange(sport: league.sport, week: viewModel.selectedWeek)
        viewModel.selectedDate = weekStart
        Task {
            await viewModel.loadDailyScores(leagueID: league.id, week: viewModel.selectedWeek)
            await viewModel.loadDayFixtures()
        }
    }

    // MARK: - Date Selector

    private var dateSelector: some View {
        let dates = viewModel.weekDates

        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(dates, id: \.timeIntervalSince1970) { date in
                        let isSelected = Calendar.current.isDate(date, inSameDayAs: viewModel.selectedDate)
                        let isToday = Calendar.current.isDateInToday(date)
                        let hasData = hasDailyData(for: date)

                        Button {
                            viewModel.selectedDate = date
                            Task { await viewModel.loadDayFixtures() }
                        } label: {
                            VStack(spacing: 3) {
                                Text(dayAbbrev(date))
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(isSelected ? .white : .secondary)
                                Text(dayNumber(date))
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(isSelected ? .white : .primary)
                                if hasData {
                                    Circle()
                                        .fill(isSelected ? .white : brandPurple)
                                        .frame(width: 4, height: 4)
                                } else {
                                    Circle()
                                        .fill(.clear)
                                        .frame(width: 4, height: 4)
                                }
                            }
                            .frame(width: 42, height: 54)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(isSelected ? brandPurple : isToday ? brandPurple.opacity(0.1) : .clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(isToday && !isSelected ? brandPurple : .clear, lineWidth: 1.5)
                            )
                        }
                        .id(date.timeIntervalSince1970)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(.white)
            .onAppear {
                if let today = dates.first(where: { Calendar.current.isDateInToday($0) }) {
                    proxy.scrollTo(today.timeIntervalSince1970, anchor: .center)
                }
                Task { await viewModel.loadDayFixtures() }
            }
        }
    }

    // MARK: - Matchup Result Banner

    private func matchupResultBanner(_ ws: BestBallWeeklyScore) -> some View {
        HStack(spacing: 10) {
            if let result = ws.matchupResult {
                Image(systemName: result == "win" ? "trophy.fill" : result == "tie" ? "equal.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(result == "win" ? .yellow : result == "tie" ? .orange : .red)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("Week \(ws.week)")
                        .font(.subheadline.weight(.semibold))

                    if let result = ws.matchupResult {
                        let bgColor: Color = result == "win" ? brandPurple.opacity(0.2) : result == "tie" ? Color.orange.opacity(0.2) : Color.red.opacity(0.2)
                        let fgColor: Color = result == "win" ? brandPurple : result == "tie" ? .orange : .red
                        Text(result.uppercased())
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(bgColor)
                            .foregroundStyle(fgColor)
                            .clipShape(Capsule())
                    }
                }

                if let opponentID = ws.opponentMemberID {
                    Text("vs \(viewModel.memberName(for: opponentID))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(String(format: "%.1f", ws.totalPoints))
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(brandPurple)
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    // MARK: - Week Total Header

    private var weekTotalHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if isDingersOnly {
                    Text("Season HR Leaderboard")
                        .font(.subheadline.weight(.semibold))
                } else if hasDailyDataForSelectedDate {
                    Text(formattedSelectedDate)
                        .font(.subheadline.weight(.semibold))
                    let dayTotal = todayPlayerPoints.values.reduce(0, +)
                    Text("Day: \(String(format: "%.1f", dayTotal)) FPTS")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Week \(viewModel.selectedWeek)")
                        .font(.subheadline.weight(.semibold))
                    // Football has no day strip, so a single date read as
                    // "this week is Tuesday" — show the week's span instead.
                    Text(sport == "NFL" || sport == "CFB" ? formattedWeekRange : formattedSelectedDate)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(isDingersOnly ? "Total HR" : "Week Total")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                if isDingersOnly {
                    if viewModel.isLoadingDingersHR && seasonHRTotals.isEmpty {
                        ProgressView()
                            .scaleEffect(0.7)
                            .tint(brandPurple)
                    } else {
                        Text("\(Int(seasonTotalHR))")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(brandPurple)
                    }
                } else {
                    let weekTotal = weekScore?.totalPoints ?? weeklyPlayerPoints.values.reduce(0, +)
                    Text(String(format: "%.1f", weekTotal))
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(brandPurple)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - MLB Roster Section

    private func mlbRosterSection(title: String, players: [BestBallPick], isPitcher: Bool) -> some View {
        let allStarters: Bool = isDingersOnly  // Dingers-only: everyone is a starter, no bench
        let starters: [BestBallPick]
        let bench: [BestBallPick]
        if allStarters {
            starters = players.sorted { (seasonHRTotals[$0.playerID] ?? 0) > (seasonHRTotals[$1.playerID] ?? 0) }
            bench = []
        } else {
            starters = players.filter { scoringPlayerIDs.contains($0.playerID) }
                .sorted { (weeklyPlayerPoints[$0.playerID] ?? 0) > (weeklyPlayerPoints[$1.playerID] ?? 0) }
            bench = players.filter { !scoringPlayerIDs.contains($0.playerID) }
                .sorted { (weeklyPlayerPoints[$0.playerID] ?? 0) > (weeklyPlayerPoints[$1.playerID] ?? 0) }
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

            statColumnHeader(isPitcher: isPitcher)

            ForEach(starters) { pick in
                playerRow(pick: pick, isScoring: true, isPitcher: isPitcher)
                if pick.id != starters.last?.id {
                    Divider().padding(.leading, 44)
                }
            }

            if !bench.isEmpty && !starters.isEmpty {
                benchDivider
            }

            ForEach(bench) { pick in
                playerRow(pick: pick, isScoring: false, isPitcher: isPitcher)
                if pick.id != bench.last?.id {
                    Divider().padding(.leading, 44)
                }
            }
        }
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
        // Horizontal swipe pages the stat columns (chevrons in the header
        // do the same). Horizontal-dominant check so vertical scrolling
        // and row taps are untouched.
        .simultaneousGesture(
            DragGesture(minimumDistance: 25)
                .onEnded { v in
                    let pages = statPageCount(isPitcher: isPitcher)
                    guard pages > 1,
                          abs(v.translation.width) > abs(v.translation.height) * 1.5 else { return }
                    Haptics.light()
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if v.translation.width < 0 {
                            statPage = min(pages - 1, statPage + 1)
                        } else {
                            statPage = max(0, statPage - 1)
                        }
                    }
                }
        )
    }

    // MARK: - Stat Column Header

    /// Page through stat columns 5 at a time (EPL tracks 13: shots, cards,
    /// tackles, interceptions, crosses, passes, fouls…). All rows read the
    /// same window so the table stays in sync.
    @State private var statPage = 0

    private func visibleStatLabels(isPitcher: Bool) -> [String] {
        let labels = BestBallLineupConfig.statLabels(for: sport, isPitcher: isPitcher)
        guard labels.count > 5 else { return labels }
        let start = min(statPage * 5, max(0, labels.count - 5))
        return Array(labels.dropFirst(start).prefix(5))
    }

    private func statPageCount(isPitcher: Bool) -> Int {
        let labels = BestBallLineupConfig.statLabels(for: sport, isPitcher: isPitcher)
        return max(1, Int(ceil(Double(labels.count) / 5.0)))
    }

    private func statColumnHeader(isPitcher: Bool) -> some View {
        let labels = visibleStatLabels(isPitcher: isPitcher)
        let pages = statPageCount(isPitcher: isPitcher)

        return HStack(spacing: 0) {
            Text("PLAYER")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 44)

            if isDingersOnly {
                Text("HR")
                    .frame(width: 44, alignment: .trailing)
            } else {
                if pages > 1 {
                    Button {
                        Haptics.light()
                        statPage = max(0, statPage - 1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(statPage > 0 ? brandPurple : Color(.systemGray4))
                            .frame(width: 16)
                    }
                    .buttonStyle(.plain)
                    .disabled(statPage == 0)
                }
                ForEach(labels, id: \.self) { label in
                    Text(label)
                        .frame(width: 30, alignment: .trailing)
                }
                if pages > 1 {
                    Button {
                        Haptics.light()
                        statPage = min(pages - 1, statPage + 1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(statPage < pages - 1 ? brandPurple : Color(.systemGray4))
                            .frame(width: 16)
                    }
                    .buttonStyle(.plain)
                    .disabled(statPage >= pages - 1)
                }

                Text("FPTS")
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // Whether we have daily data for the selected date
    private var hasDailyDataForSelectedDate: Bool {
        !todayPlayerPoints.isEmpty
    }

    // Effective stats to display: daily if available, otherwise weekly
    private func effectiveStats(for playerID: String) -> [String: Double] {
        if hasDailyDataForSelectedDate {
            return todayPlayerStats[playerID] ?? [:]
        }
        return weeklyPlayerStats[playerID] ?? [:]
    }

    // Effective points to display: daily if available, otherwise weekly
    private func effectivePoints(for playerID: String) -> Double {
        if hasDailyDataForSelectedDate {
            return todayPlayerPoints[playerID] ?? 0
        }
        return weeklyPlayerPoints[playerID] ?? 0
    }

    // MARK: - Slot Assignment

    /// Returns starters in lineup-slot order, each tagged with the slot label
    /// they're filling. For NFL this is the slot-aware QB/RB/WR/TE/FLEX
    /// assignment; for other sports it falls back to the existing
    /// position-rank sort with no override label.
    private func sportSpecificStarterEntries() -> [(pick: BestBallPick, slotLabel: String?)] {
        let hasScores = !scoringPlayerIDs.isEmpty
        // Before the week has scores, football projects a starting lineup
        // from the WHOLE roster (draft-priority order) so the screen shows
        // slotted starters + bench instead of one flat unslotted list.
        let candidates = hasScores
            ? sortedRoster.filter { scoringPlayerIDs.contains($0.playerID) }
            : sortedRoster
        guard sport == "NFL" || sport == "CFB" || sport == "EPL", let league = viewModel.currentLeague else {
            // Other sports keep the old behavior: no starters until scored.
            return hasScores ? candidates.map { ($0, nil) } : []
        }
        let constraints = BestBallLineupConfig.requirements(for: league).constraints
        let positions = Dictionary(uniqueKeysWithValues: candidates.map { ($0.playerID, $0.playerPosition) })
        let points = Dictionary(uniqueKeysWithValues: candidates.map { ($0.playerID, weeklyPlayerPoints[$0.playerID] ?? 0) })
        let pickByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.playerID, $0) })
        let assigned = BestBallLineupConfig.assignStartersToSlots(
            scoringIDs: candidates.map { $0.playerID },
            positions: positions,
            points: points,
            constraints: constraints
        )
        let assignedEntries: [(pick: BestBallPick, slotLabel: String?)] = assigned.compactMap { slot in
            guard let pick = pickByID[slot.playerID] else { return nil }
            return (pick, slot.label)
        }
        // Mid-week only some starters have scored, which left the lineup
        // rendering fewer slots than the league configures (7 rows with the
        // FLEX slots missing entirely). Walk the canonical slot sequence,
        // keep each scored starter in its slot, and fill every empty slot
        // with the best unused roster player (no star until they score).
        let fullLabels = constraints.flatMap { Array(repeating: $0.label, count: $0.count) }
        // Real eligibility from the lineup config — a label-string heuristic
        // put a GOALKEEPER in an EPL FLEX slot (FLEX is outfield-only, and
        // NFL FLEX excludes QBs).
        let eligibleByLabel = Dictionary(constraints.map { ($0.label, $0.eligible) }, uniquingKeysWith: { a, _ in a })
        var pool = assignedEntries
        var used = Set(assignedEntries.map { $0.pick.playerID })
        var out: [(pick: BestBallPick, slotLabel: String?)] = []
        for label in fullLabels {
            if let i = pool.firstIndex(where: { $0.slotLabel == label }) {
                out.append(pool.remove(at: i))
                continue
            }
            let fits: (BestBallPick) -> Bool = { p in
                guard let eligible = eligibleByLabel[label] else { return true }
                return eligible.contains(p.playerPosition.uppercased())
            }
            let filler = sortedRoster.first(where: { p in
                !used.contains(p.playerID) && fits(p)
            })
            guard let f = filler else { continue }
            used.insert(f.playerID)
            out.append((f, label))
        }
        out.append(contentsOf: pool)
        return out
    }

    // MARK: - Player Row

    private func playerRow(pick: BestBallPick, isScoring: Bool, isPitcher: Bool, slotLabel: String? = nil) -> some View {
        let pts = effectivePoints(for: pick.playerID)
        let weekPts = weeklyPlayerPoints[pick.playerID] ?? 0
        let stats = effectiveStats(for: pick.playerID)
        let labels = visibleStatLabels(isPitcher: isPitcher)
        let statPages = statPageCount(isPitcher: isPitcher)
        let showingDaily = hasDailyDataForSelectedDate
        // Use the slot label as the badge when the player is filling a
        // role that differs from their actual position (the FLEX/SFLEX
        // case for NFL). Position-specific slots stay color-coded by
        // position; flex slots render in neutral gray so they're visually
        // distinct from a position-locked starter.
        let badgeText = slotLabel ?? pick.playerPosition
        let isFlexSlot = slotLabel == "FLEX" || slotLabel == "SFLEX"
        let badgeColor: Color = isFlexSlot ? Color(.systemGray) : positionColor(pick.playerPosition)

        return HStack(spacing: 0) {
            // Position / slot badge
            Text(badgeText)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 18)
                .background(badgeColor)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .padding(.trailing, 6)

            // Scoring indicator
            Image(systemName: isScoring ? "star.fill" : "arrow.down.circle")
                .font(.system(size: 10))
                .foregroundStyle(isScoring ? .yellow : Color(.systemGray4))
                .frame(width: 14)

            // Player name and team
            VStack(alignment: .leading, spacing: 1) {
                Text(pick.playerName)
                    .font(.system(size: 13, weight: isScoring ? .semibold : .regular))
                    .foregroundStyle(isScoring ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                // Team + that day's opponent as ONE string ("EVE vs CRY") so
                // it shrinks as a unit instead of wrapping the opponent onto
                // a second line. Its mere presence means they play that day,
                // so no extra marker is needed.
                // The player's OWN team reads darker/semibold so it stays the
                // scannable part; the matchup half stays light.
                (
                    Text(pick.playerTeam)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    + Text(viewModel.dayFixtures[pick.playerTeam].map { " \($0.home ? "vs" : "@") \($0.opp)" } ?? "")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                )
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)

            if isDingersOnly {
                // Dingers-only: show season HR total for this player
                let hrCount = Int(seasonHRTotals[pick.playerID] ?? 0)
                if viewModel.isLoadingDingersHR && seasonHRTotals.isEmpty {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 44, alignment: .trailing)
                } else {
                    Text(hrCount > 0 ? "\(hrCount)" : "-")
                        .font(.system(size: 14, weight: .bold).monospacedDigit())
                        .foregroundStyle(hrCount > 0 ? brandPurple : .secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            } else {
                // Stat columns (aligned under the pager chevrons when present)
                if statPages > 1 {
                    Spacer().frame(width: 16)
                }
                ForEach(labels, id: \.self) { label in
                    let val = stats[label]
                    Text(val != nil ? formatStat(val!) : "-")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(val != nil ? (isScoring ? .primary : .secondary) : .quaternary)
                        .frame(width: 30, alignment: .trailing)
                }
                if statPages > 1 {
                    Spacer().frame(width: 16)
                }

                // FPTS box
                VStack(spacing: 1) {
                    Text(pts > 0 ? String(format: "%.1f", pts) : "-")
                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                        .foregroundStyle(isScoring ? brandPurple : .secondary)
                    // Show weekly total underneath if showing daily and they differ
                    if showingDaily && weekPts > 0 && weekPts != pts {
                        Text(String(format: "%.0f", weekPts))
                            .font(.system(size: 8, weight: .medium).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 44, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isScoring ? brandPurple.opacity(0.04) : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.light()
            detailPlayer = BBPlayerRef(
                playerID: pick.playerID, name: pick.playerName,
                team: pick.playerTeam, position: pick.playerPosition
            )
        }
    }

    // MARK: - Bench Divider

    private var benchDivider: some View {
        HStack {
            Text("BENCH")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(Color(.systemGray4))
                .frame(height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.systemGray6).opacity(0.5))
    }

    // MARK: - Helpers

    private func hasDailyData(for date: Date) -> Bool {
        let dateKey = viewModel.formattedDate(date)
        return viewModel.dailyScores.contains { ds in
            ds.memberID == memberID && viewModel.formattedDate(ds.gameDate) == dateKey
        }
    }

    private var formattedSelectedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: viewModel.selectedDate)
    }

    /// "Sep 8 – Sep 14" for the selected week (football, which plays one
    /// slate a week and shows no day strip).
    private var formattedWeekRange: String {
        let (start, end) = BestBallSeasonHelper.weekDateRange(sport: sport, week: viewModel.selectedWeek)
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
    }

    private func dayAbbrev(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter.string(from: date).uppercased()
    }

    private func dayNumber(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter.string(from: date)
    }

    private func formatStat(_ value: Double) -> String {
        if value == value.rounded() {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    private func positionColor(_ position: String) -> Color {
        switch position {
        case "PG", "SG": return .blue
        case "SF", "PF": return .orange
        case "C": return .purple
        case "QB": return .red
        case "RB": return .cyan
        case "WR": return .green
        case "TE": return .orange
        case "K": return .gray
        case "SP", "RP", "P": return .red
        case "1B", "2B", "3B", "SS": return .indigo
        case "LF", "CF", "RF", "OF": return .teal
        case "GK": return .yellow
        case "DEF": return .blue
        case "MID": return .green
        case "FWD": return .red
        default: return .gray
        }
    }
}
