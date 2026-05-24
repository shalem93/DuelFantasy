import SwiftUI

struct BestBallRosterView: View {
    @Bindable var viewModel: BestBallViewModel
    let memberID: String

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

    // Sorted roster: starters first (by points desc), then bench (by points desc)
    private var sortedRoster: [BestBallPick] {
        roster.sorted { a, b in
            let aScoring = scoringPlayerIDs.contains(a.playerID)
            let bScoring = scoringPlayerIDs.contains(b.playerID)
            if aScoring != bScoring { return aScoring }
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

                // Date selector
                dateSelector
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
                            let starters = sortedRoster.filter { scoringPlayerIDs.contains($0.playerID) }
                            let bench = sortedRoster.filter { !scoringPlayerIDs.contains($0.playerID) }

                            ForEach(starters) { pick in
                                playerRow(pick: pick, isScoring: true, isPitcher: false)
                                Divider().padding(.leading, 44)
                            }

                            if !bench.isEmpty && !starters.isEmpty {
                                benchDivider
                            }

                            ForEach(bench) { pick in
                                playerRow(pick: pick, isScoring: false, isPitcher: false)
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
        .task {
            if let league = viewModel.currentLeague {
                if league.isDingersOnly {
                    // Fetch today's live HR data directly from ESPN
                    await viewModel.refreshDingersLive(leagueID: league.id)
                } else {
                    await viewModel.loadDailyScores(leagueID: league.id, week: viewModel.selectedWeek)
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
                    Text(formattedSelectedDate)
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
    }

    // MARK: - Stat Column Header

    private func statColumnHeader(isPitcher: Bool) -> some View {
        let labels = BestBallLineupConfig.statLabels(for: sport, isPitcher: isPitcher)

        return HStack(spacing: 0) {
            Text("PLAYER")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 44)

            if isDingersOnly {
                Text("HR")
                    .frame(width: 48, alignment: .trailing)
            } else {
                ForEach(labels.prefix(5), id: \.self) { label in
                    Text(label)
                        .frame(width: 32, alignment: .trailing)
                }

                Text("FPTS")
                    .frame(width: 48, alignment: .trailing)
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

    // MARK: - Player Row

    private func playerRow(pick: BestBallPick, isScoring: Bool, isPitcher: Bool) -> some View {
        let pts = effectivePoints(for: pick.playerID)
        let weekPts = weeklyPlayerPoints[pick.playerID] ?? 0
        let stats = effectiveStats(for: pick.playerID)
        let labels = BestBallLineupConfig.statLabels(for: sport, isPitcher: isPitcher)
        let showingDaily = hasDailyDataForSelectedDate

        return HStack(spacing: 0) {
            // Position badge
            Text(pick.playerPosition)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 18)
                .background(positionColor(pick.playerPosition))
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
                Text(pick.playerTeam)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)

            if isDingersOnly {
                // Dingers-only: show season HR total for this player
                let hrCount = Int(seasonHRTotals[pick.playerID] ?? 0)
                if viewModel.isLoadingDingersHR && seasonHRTotals.isEmpty {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 48, alignment: .trailing)
                } else {
                    Text(hrCount > 0 ? "\(hrCount)" : "-")
                        .font(.system(size: 14, weight: .bold).monospacedDigit())
                        .foregroundStyle(hrCount > 0 ? brandPurple : .secondary)
                        .frame(width: 48, alignment: .trailing)
                }
            } else {
                // Stat columns
                ForEach(labels.prefix(5), id: \.self) { label in
                    let val = stats[label]
                    Text(val != nil ? formatStat(val!) : "-")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(val != nil ? (isScoring ? .primary : .secondary) : .quaternary)
                        .frame(width: 32, alignment: .trailing)
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
                .frame(width: 48, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isScoring ? brandPurple.opacity(0.04) : .clear)
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
        default: return .gray
        }
    }
}
