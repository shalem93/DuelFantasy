import SwiftUI

struct DFSPastStandingsView: View {
    @Bindable var viewModel: DFSViewModel
    let result: DFSResult

    /// Live result: re-reads from dfsHistory after sync repairs lineupNumber.
    /// Falls back to the original result if no match is found.
    private var liveResult: DFSResult {
        guard let tid = result.tournamentId else { return result }
        // Find the matching entry in the live history by ID first, then by tournamentId + lineupNumber
        if let match = viewModel.dfsHistory.first(where: { $0.id == result.id }) {
            return match
        }
        return result
    }

    private var brandPurple: Color {
        Color(red: 0.48, green: 0.23, blue: 0.93)
    }

    /// Detect sport from tournament ID prefix
    private var isGolf: Bool {
        result.tournamentId?.hasPrefix("pga-") == true
    }
    private var isMLB: Bool {
        result.tournamentId?.hasPrefix("mlb-") == true
    }
    private var isNHL: Bool {
        result.tournamentId?.hasPrefix("nhl-") == true
    }
    private var isSingleGameTournament: Bool {
        // UFC main slates are captain mode (MVP + 5 FLEX) even without a "-sg-"
        // in the tid, so treat any UFC contest as single-game for MVP scoring
        // and slot labels.
        result.tournamentId?.contains("-sg-") == true
            || result.tournamentId?.hasPrefix("ufc-") == true
    }
    private var isSoccer: Bool {
        result.tournamentId?.hasPrefix("epl-") == true
            || result.tournamentId?.hasPrefix("ucl-") == true
            || result.tournamentId?.hasPrefix("wc-") == true
    }

    /// Resolve a player's roster position for the slot badge. Live pool first
    /// (works for today's contest); a two-way "-sp" id is always the pitcher;
    /// MLB falls back to batter/pitcher from the box-score stat shape. Empty
    /// when unknown (caller falls back to a numeric label).
    private func slotPosition(for playerID: String) -> String {
        if playerID.hasSuffix("-sp") { return "SP" }
        if let p = viewModel.activePlayers.first(where: { $0.id == playerID }), !p.position.isEmpty {
            return p.position
        }
        if isMLB {
            return isMLBPitcher(viewModel.pastTournamentPlayerStats[playerID]) ? "SP" : ""
        }
        return ""
    }
    private var isUFC: Bool {
        result.tournamentId?.hasPrefix("ufc-") == true
    }
    private var sportLabel: String {
        if isGolf { return "PGA" }
        if isMLB { return "MLB" }
        if isNHL { return "NHL" }
        if isUFC { return "UFC" }
        if result.tournamentId?.hasPrefix("ncaam-") == true { return "NCAAM" }
        if result.tournamentId?.hasPrefix("wnba-") == true { return "WNBA" }
        if result.tournamentId?.hasPrefix("epl-") == true { return "EPL" }
        if result.tournamentId?.hasPrefix("ucl-") == true { return "UCL" }
        if result.tournamentId?.hasPrefix("wc-") == true { return "WC" }
        if result.tournamentId?.hasPrefix("nfl-") == true { return "NFL" }
        if result.tournamentId?.hasPrefix("cfb-") == true { return "CFB" }
        return "NBA"
    }

    /// Use server leaderboard data for the header when available (avoids stale local rank)
    /// For multi-lineup tournaments, match the specific lineup by entry name containing the lineup number
    /// Match a specific lineup entry by checking the name ends with " #N"
    private func matchesLineup(_ name: String, lineupNum: Int) -> Bool {
        name.hasSuffix(" #\(lineupNum)")
    }

    /// Find the specific leaderboard entry for the current result's lineup.
    /// Uses lineup number from liveResult (which may have been repaired by sync).
    private var matchedUserEntry: DFSLeaderboardEntry? {
        let userEntries = viewModel.pastTournamentLeaderboard.filter { $0.isCurrentUser }
        guard userEntries.count > 1 else { return userEntries.first }
        let r = liveResult

        print("[DFS-Match] userEntries=\(userEntries.count) lineupNum=\(r.lineupNumber as Any) pts=\(r.lineupPoints) rank=\(r.rank)")
        for ue in userEntries {
            print("[DFS-Match]   entry: name=\(ue.name) rank=\(ue.rank) pts=\(ue.points)")
        }

        // Strategy 1: Match by lineup number in entry name
        if let lineupNum = r.lineupNumber {
            if let match = userEntries.first(where: { matchesLineup($0.name, lineupNum: lineupNum) }) {
                print("[DFS-Match] Matched by lineup# \(lineupNum): \(match.name) rank=\(match.rank)")
                return match
            }
            // Fallback: use the nth entry sorted by rank
            if lineupNum <= userEntries.count {
                let sorted = userEntries.sorted(by: { $0.rank < $1.rank })
                let match = sorted[lineupNum - 1]
                print("[DFS-Match] Matched by nth entry (\(lineupNum)): \(match.name) rank=\(match.rank)")
                return match
            }
        }

        // Strategy 2: Match by points (for entries where lineupNumber was lost)
        if r.lineupPoints > 0 {
            let closest = userEntries.min(by: {
                abs($0.points - r.lineupPoints) < abs($1.points - r.lineupPoints)
            })
            if let closest, abs(closest.points - r.lineupPoints) < 0.5 {
                print("[DFS-Match] Matched by points: \(closest.name) rank=\(closest.rank)")
                return closest
            }
        }

        // Strategy 3: Match by stored rank
        if let match = userEntries.first(where: { $0.rank == r.rank }) {
            print("[DFS-Match] Matched by rank: \(match.name) rank=\(match.rank)")
            return match
        }

        print("[DFS-Match] No match found, returning first entry")
        return userEntries.first
    }

    private var displayRank: Int {
        matchedUserEntry?.rank ?? liveResult.rank
    }
    private var displayPoints: Double {
        matchedUserEntry?.points ?? liveResult.lineupPoints
    }
    private var displayTotalEntries: Int {
        let count = viewModel.pastTournamentLeaderboard.count
        // Use the expected entry count from the tournament ID (e.g., 2000 for "-2000")
        // to avoid showing stale counts from partially re-settled data
        let expectedFromID = result.tournamentId.map { DFSViewModel.entryCountFromTournamentID($0) } ?? 0
        let best = max(count, max(liveResult.totalEntries, expectedFromID))
        return best > 0 ? best : liveResult.totalEntries
    }
    /// Fix titles from a prior bug where multi-game slates were incorrectly labeled "Single Game"
    private var correctedTitle: String {
        let title = result.tournamentTitle
        guard title.hasPrefix("Single Game:") else { return title }
        // If the user's lineup has != 6 players, it wasn't actually a single-game slate
        if let userRecord = viewModel.pastTournamentResultRecords.first(where: { $0.isCurrentUser }),
           userRecord.lineupPlayerIDs.count != 6 {
            return "Free Tournament of the Day"
        }
        return title
    }
    private var displayRRDelta: Int {
        let userRecords = viewModel.pastTournamentResultRecords.filter { $0.isCurrentUser }
        let r = liveResult
        guard userRecords.count > 1 else { return userRecords.first?.rrDelta ?? r.rrDelta }

        // Match by lineup number in entry name
        if let lineupNum = r.lineupNumber {
            if let match = userRecords.first(where: { matchesLineup($0.entryName, lineupNum: lineupNum) }) {
                return match.rrDelta
            }
        }

        // Fallback: match by points
        if r.lineupPoints > 0 {
            let closest = userRecords.min(by: {
                abs($0.totalPoints - r.lineupPoints) < abs($1.totalPoints - r.lineupPoints)
            })
            if let closest, abs(closest.totalPoints - r.lineupPoints) < 0.5 {
                return closest.rrDelta
            }
        }

        // Fallback: match by rank
        if let match = userRecords.first(where: { $0.rank == r.rank }) {
            return match.rrDelta
        }

        return userRecords.first?.rrDelta ?? r.rrDelta
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                resultHeader
                leaderboardSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.94, green: 0.98, blue: 0.95),
                    Color(red: 0.95, green: 0.97, blue: 1.00),
                    Color(red: 0.98, green: 0.99, blue: 1.00)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        .navigationTitle("Standings")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: result.tournamentId) {
            if let tournamentId = result.tournamentId {
                await viewModel.loadPastTournamentStandings(tournamentId: tournamentId)
                rebuildCachesIfNeeded()
                await viewModel.loadPastTournamentBoxScores(tournamentId: tournamentId)
            }
        }
        .onChange(of: viewModel.pastTournamentLeaderboard.count) {
            rebuildCachesIfNeeded()
        }
    }

    // MARK: - Result Header

    private var resultHeader: some View {
        VStack(spacing: 14) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.white)
                    Text("FINAL")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                    Text(sportLabel)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.2))
                        .clipShape(Capsule())
                        .foregroundStyle(.white)
                }
                Spacer()
                Text(result.loggedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))
            }

            Text(correctedTitle)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)

            HStack(spacing: 24) {
                VStack(spacing: 2) {
                    Text("RANK")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("#\(displayRank)")
                        .font(.title.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()
                    Text("of \(displayTotalEntries)")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                }

                VStack(spacing: 2) {
                    Text("SCORE")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    Text(String(format: "%.1f", displayPoints))
                        .font(.title.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                    Text("FPTS")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                }

                VStack(spacing: 2) {
                    Text("RR")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("\(displayRRDelta >= 0 ? "+" : "")\(displayRRDelta)")
                        .font(.title.weight(.bold).monospacedDigit())
                        .foregroundStyle(displayRRDelta >= 0 ? Color(red: 0.4, green: 1.0, blue: 0.5) : Color(red: 1.0, green: 0.5, blue: 0.5))
                    Text("delta")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.12, blue: 0.22),
                    Color(red: 0.15, green: 0.20, blue: 0.35)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
    }

    // MARK: - Leaderboard

    @State private var expandedEntryID: UUID? = nil
    @State private var leaderboardPageSize: Int = 25

    // Cached maps — rebuilt only when the underlying data changes
    @State private var cachedResultByEntryID: [UUID: DFSTournamentResultRecord] = [:]
    @State private var cachedOwnershipByPlayerID: [String: Int] = [:]
    @State private var cachedDataVersion: Int = -1

    /// Rebuild cached maps only when leaderboard/result data actually changes
    private func rebuildCachesIfNeeded() {
        // Include the first record's id hash in the version — without it,
        // a regen that replaces the bot field but keeps the same entry
        // count (2000 in, 2000 out) leaves the version unchanged and the
        // entry-id→record map keeps stale UUIDs, breaking row expansion.
        let firstIDHash = viewModel.pastTournamentResultRecords.first?.id.hashValue ?? 0
        let lastIDHash = viewModel.pastTournamentResultRecords.last?.id.hashValue ?? 0
        let version = viewModel.pastTournamentLeaderboard.count
            + viewModel.pastTournamentResultRecords.count * 1000
            &+ firstIDHash &+ lastIDHash
        guard version != cachedDataVersion else { return }
        cachedDataVersion = version
        // New data means the previously-expanded row's UUID no longer
        // matches; clear so the next tap re-expands cleanly.
        expandedEntryID = nil

        var map: [UUID: DFSTournamentResultRecord] = [:]
        for (index, entry) in viewModel.pastTournamentLeaderboard.enumerated() {
            if index < viewModel.pastTournamentResultRecords.count {
                map[entry.id] = viewModel.pastTournamentResultRecords[index]
            }
        }
        cachedResultByEntryID = map

        let records = viewModel.pastTournamentResultRecords
        let totalEntries = max(records.count, 1)
        var counts: [String: Int] = [:]
        for record in records {
            for pid in record.lineupPlayerIDs {
                counts[pid, default: 0] += 1
            }
        }
        cachedOwnershipByPlayerID = counts.mapValues { count in
            Int((Double(count) / Double(totalEntries) * 100).rounded())
        }
    }

    /// Map from leaderboard entry ID → result record (for lineup details)
    private var resultByEntryID: [UUID: DFSTournamentResultRecord] {
        cachedResultByEntryID
    }

    /// Ownership percentage for each player ID across the entire field
    private var ownershipByPlayerID: [String: Int] {
        cachedOwnershipByPlayerID
    }

    /// Entries to display: top N entries plus the specific user lineup that was clicked.
    /// For multi-lineup, only show the matched entry (the one the user navigated from).
    private var visibleEntries: [DFSLeaderboardEntry] {
        let all = viewModel.pastTournamentLeaderboard
        let topSlice = Array(all.prefix(leaderboardPageSize))

        // Determine which user entry to pin at the bottom
        let pinnedEntry: DFSLeaderboardEntry? = {
            if let matched = matchedUserEntry {
                // Check if it's already in the top slice
                if topSlice.contains(where: { $0.id == matched.id }) {
                    return nil // already visible
                }
                return matched
            }
            // If no match in leaderboard, create synthetic entry from result data
            let r = liveResult
            if r.lineupPoints > 0 || r.rank > 0 {
                return DFSLeaderboardEntry(
                    id: r.id,
                    name: "You",
                    rank: r.rank,
                    points: r.lineupPoints,
                    isCurrentUser: true
                )
            }
            return nil
        }()

        // Also include other user entries that are in the top slice
        // (they're already there, no need to add)
        if let pinned = pinnedEntry {
            return topSlice + [pinned]
        }
        return topSlice
    }

    private var leaderboardSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Leaderboard")
                    .font(.headline)
                Spacer()
                Text("\(displayTotalEntries) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if viewModel.isLoadingPastTournament {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Loading standings...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else if viewModel.pastTournamentLeaderboard.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.3")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No standings available")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                // Header row
                HStack {
                    Text("#")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 28, alignment: .leading)
                    Text("PLAYER")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(isGolf ? "SCORE" : "SAL")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                    Text("FPTS")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .trailing)
                }
                .padding(.horizontal, 12)

                ForEach(visibleEntries) { entry in
                    // Show a separator before the user entry if they're outside the top slice
                    if entry.isCurrentUser && entry.rank > leaderboardPageSize {
                        HStack {
                            Spacer()
                            Text("···")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.tertiary)
                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }
                    leaderboardRow(entry)
                }

                if viewModel.pastTournamentLeaderboard.count > leaderboardPageSize {
                    let remaining = max(0, viewModel.pastTournamentLeaderboard.count - leaderboardPageSize)
                    Button("Show More (\(remaining) remaining)") {
                        leaderboardPageSize += 50
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(brandPurple)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                }
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    private func leaderboardRow(_ entry: DFSLeaderboardEntry) -> some View {
        let isExpanded = expandedEntryID == entry.id
        let resultRecord = resultByEntryID[entry.id]
        let hasLineup = resultRecord != nil && !(resultRecord?.lineupPlayerIDs.isEmpty ?? true)

        return VStack(spacing: 0) {
            Button {
                guard hasLineup else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedEntryID = isExpanded ? nil : entry.id
                }
            } label: {
                HStack {
                    Text("\(entry.rank)")
                        .font(.subheadline.weight(.medium).monospacedDigit())
                        .foregroundStyle(entry.rank <= 3 ? Color(red: 0.95, green: 0.78, blue: 0.20) : .secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: 28, alignment: .leading)

                    HStack(spacing: 4) {
                        if entry.isCurrentUser {
                            Image(systemName: "star.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(brandPurple)
                        }
                        Text(entry.name)
                            .font(.subheadline.weight(entry.isCurrentUser ? .bold : .regular))
                            .foregroundStyle(entry.isCurrentUser ? brandPurple : .primary)
                    }

                    Spacer()

                    // Golf: show aggregate score-to-par; other sports: total salary
                    if isGolf {
                        let scoreToPar = golfEntryScoreToPar(entry)
                        if let score = scoreToPar {
                            let display = score == 0 ? "E" : (score > 0 ? "+\(score)" : "\(score)")
                            Text(display)
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(score < 0 ? .red : (score > 0 ? Color(.systemGreen) : .secondary))
                                .frame(width: 52, alignment: .trailing)
                        } else {
                            Text("-")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .frame(width: 52, alignment: .trailing)
                        }
                    } else if let record = resultRecord {
                        let rawTotalSal = record.lineupPlayerIDs.reduce(0) { $0 + (salaryForPlayer($1, in: record) ?? 0) }
                        // Cap displayed salary at the sport's salary cap so estimation drift never shows over-budget
                        let capLimit = 50000
                        let totalSal = min(rawTotalSal, capLimit)
                        if totalSal > 0 {
                            Text("$\(viewModel.formatSalary(totalSal))")
                                .font(.caption2.weight(.medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .trailing)
                        } else {
                            Text("-")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .frame(width: 52, alignment: .trailing)
                        }
                    } else {
                        Text("-")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(width: 52, alignment: .trailing)
                    }

                    Text(String(format: "%.1f", entry.points))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(entry.isCurrentUser ? brandPurple : .secondary)
                        .frame(width: 50, alignment: .trailing)

                    if hasLineup {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(width: 16)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            // Expanded lineup view with box scores
            if isExpanded, let record = resultRecord {
                VStack(spacing: 0) {
                    if isGolf {
                        golfExpandedLineup(record: record)
                    } else if isMLB {
                        mlbExpandedLineup(record: record)
                    } else if isNHL {
                        nhlExpandedLineup(record: record)
                    } else if isSoccer {
                        soccerExpandedLineup(record: record)
                    } else if isUFC {
                        ufcExpandedLineup(record: record)
                    } else {
                        basketballExpandedLineup(record: record)
                    }
                }
                .background(Color(.systemGray6).opacity(0.5))
            }
        }
        .background(entry.isCurrentUser ? brandPurple.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Basketball Expanded Lineup

    @ViewBuilder
    private func basketballExpandedLineup(record: DFSTournamentResultRecord) -> some View {
        // Box score header
        HStack(spacing: 0) {
            Text("PLAYER")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("PTS")
                .frame(width: 30, alignment: .trailing)
            Text("REB")
                .frame(width: 30, alignment: .trailing)
            Text("AST")
                .frame(width: 30, alignment: .trailing)
            Text("STL")
                .frame(width: 28, alignment: .trailing)
            Text("BLK")
                .frame(width: 28, alignment: .trailing)
            Text("FPTS")
                .frame(width: 38, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)

        let playerIDs = record.lineupPlayerIDs
        let playerNames = record.lineupPlayerNames
        let perPlayerPts = resolvePlayerPoints(for: record)
        let isSingleGame = isSingleGameTournament

        ForEach(Array(playerIDs.enumerated()), id: \.offset) { index, playerID in
            let storedName = index < playerNames.count ? playerNames[index] : playerID
            let name = resolvePlayerName(storedName: storedName, playerID: playerID)
            let isMVP = isSingleGame && index == 0
            let fpts = perPlayerPts[playerID] ?? 0  // already includes 1.5x MVP multiplier from settlement
            let stats = viewModel.pastTournamentPlayerStats[playerID]
            let bbPos = slotPosition(for: playerID)
            let slotLabel = isMVP ? "MVP" : (isSingleGame ? "FLEX" : (bbPos.isEmpty ? "\(index + 1)" : bbPos))
            let isWideSlot = isMVP || slotLabel == "FLEX" || slotLabel.count > 2

            HStack(spacing: 0) {
                HStack(spacing: 4) {
                    Text(slotLabel)
                        .font(.system(size: isMVP ? 7 : 8, weight: .bold))
                        .foregroundStyle(isMVP ? .black : .white)
                        .lineLimit(1)
                        .frame(width: isWideSlot ? 28 : 18, height: 18)
                        .background(isMVP ? Color.yellow : brandPurple.opacity(0.7))
                        .clipShape(isWideSlot ? AnyShape(Capsule()) : AnyShape(Circle()))

                    Text(lastName(name))
                        .font(.caption.weight(.medium))
                        .lineLimit(1)

                    if let sal = salaryForPlayer(playerID, in: record) {
                        Text("$\(viewModel.formatSalary(sal))")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    if let pct = ownershipByPlayerID[playerID] {
                        Text("\(pct)%")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let stats {
                    Text("\(stats.points)")
                        .frame(width: 30, alignment: .trailing)
                    Text("\(stats.rebounds)")
                        .frame(width: 30, alignment: .trailing)
                    Text("\(stats.assists)")
                        .frame(width: 30, alignment: .trailing)
                    Text("\(stats.steals)")
                        .frame(width: 28, alignment: .trailing)
                    Text("\(stats.blocks)")
                        .frame(width: 28, alignment: .trailing)
                } else {
                    Text("-").frame(width: 30, alignment: .trailing)
                    Text("-").frame(width: 30, alignment: .trailing)
                    Text("-").frame(width: 30, alignment: .trailing)
                    Text("-").frame(width: 28, alignment: .trailing)
                    Text("-").frame(width: 28, alignment: .trailing)
                }

                Text(String(format: "%.1f", fpts))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(brandPurple)
                    .frame(width: 38, alignment: .trailing)
            }
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }

        lineupTotalsRow(record: record)
    }

    // MARK: - UFC Expanded Lineup

    /// MMA box-score columns: SIG / TD / KD / SUB / CTRL. Same DFSPlayerLiveStats
    /// field mapping the live view uses (points=sig strikes, rebounds=takedowns,
    /// assists=knockdowns, steals=sub attempts, blocks=time-in-control seconds).
    @ViewBuilder
    private func ufcExpandedLineup(record: DFSTournamentResultRecord) -> some View {
        HStack(spacing: 0) {
            Text("FIGHTER")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("SIG")
                .frame(width: 28, alignment: .trailing)
            Text("TD")
                .frame(width: 24, alignment: .trailing)
            Text("KD")
                .frame(width: 24, alignment: .trailing)
            Text("SUB")
                .frame(width: 28, alignment: .trailing)
            Text("CTRL")
                .frame(width: 36, alignment: .trailing)
            Text("FPTS")
                .frame(width: 38, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)

        let playerIDs = record.lineupPlayerIDs
        let playerNames = record.lineupPlayerNames
        let perPlayerPts = resolvePlayerPoints(for: record)

        ForEach(Array(playerIDs.enumerated()), id: \.offset) { index, playerID in
            let storedName = index < playerNames.count ? playerNames[index] : playerID
            let name = resolvePlayerName(storedName: storedName, playerID: playerID)
            let fpts = perPlayerPts[playerID] ?? 0
            let stats = viewModel.pastTournamentPlayerStats[playerID]

            HStack(spacing: 0) {
                HStack(spacing: 4) {
                    Text("F")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Color(red: 0.6, green: 0.1, blue: 0.1))
                        .clipShape(Circle())
                    Text(lastName(name))
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    if let sal = salaryForPlayer(playerID, in: record) {
                        Text("$\(viewModel.formatSalary(sal))")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    if let pct = ownershipByPlayerID[playerID] {
                        Text("\(pct)%")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let stats {
                    Text("\(stats.points)")
                        .frame(width: 28, alignment: .trailing)
                    Text("\(stats.rebounds)")
                        .frame(width: 24, alignment: .trailing)
                    Text("\(stats.assists)")
                        .frame(width: 24, alignment: .trailing)
                    Text("\(stats.steals)")
                        .frame(width: 28, alignment: .trailing)
                    let ctrlMin = stats.blocks / 60
                    let ctrlSec = stats.blocks % 60
                    Text("\(ctrlMin):\(String(format: "%02d", ctrlSec))")
                        .frame(width: 36, alignment: .trailing)
                } else {
                    Text("-").frame(width: 28, alignment: .trailing)
                    Text("-").frame(width: 24, alignment: .trailing)
                    Text("-").frame(width: 24, alignment: .trailing)
                    Text("-").frame(width: 28, alignment: .trailing)
                    Text("-").frame(width: 36, alignment: .trailing)
                }

                Text(String(format: "%.1f", fpts))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(brandPurple)
                    .frame(width: 38, alignment: .trailing)
            }
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }

        lineupTotalsRow(record: record)
    }

    // MARK: - Soccer Expanded Lineup

    @ViewBuilder
    private func soccerExpandedLineup(record: DFSTournamentResultRecord) -> some View {
        // Box score header — soccer stats
        HStack(spacing: 0) {
            Text("PLAYER")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("G")
                .frame(width: 22, alignment: .trailing)
            Text("A")
                .frame(width: 22, alignment: .trailing)
            Text("SOT")
                .frame(width: 28, alignment: .trailing)
            Text("SV")
                .frame(width: 22, alignment: .trailing)
            Text("FD")
                .frame(width: 22, alignment: .trailing)
            Text("FPTS")
                .frame(width: 38, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)

        let playerIDs = record.lineupPlayerIDs
        let playerNames = record.lineupPlayerNames
        let perPlayerPts = resolvePlayerPoints(for: record)
        let isSingleGame = isSingleGameTournament

        ForEach(Array(playerIDs.enumerated()), id: \.offset) { index, playerID in
            let storedName = index < playerNames.count ? playerNames[index] : playerID
            let name = resolvePlayerName(storedName: storedName, playerID: playerID)
            let isMVP = isSingleGame && index == 0
            let fpts = perPlayerPts[playerID] ?? 0
            let stats = viewModel.pastTournamentPlayerStats[playerID]
            let slotLabel = isMVP ? "MVP" : (isSingleGame ? "FLEX" : (stats?.minutes.contains("GK") == true ? "GK" : ""))
            let isWideSlot = isMVP || slotLabel == "FLEX" || slotLabel == "GK"

            HStack(spacing: 0) {
                HStack(spacing: 4) {
                    if !slotLabel.isEmpty {
                        Text(slotLabel)
                            .font(.system(size: isMVP ? 7 : 8, weight: .bold))
                            .foregroundStyle(isMVP ? .black : .white)
                            .lineLimit(1)
                            .frame(width: isWideSlot ? 28 : 18, height: 18)
                            .background(isMVP ? Color.yellow : brandPurple.opacity(0.7))
                            .clipShape(isWideSlot ? AnyShape(Capsule()) : AnyShape(Circle()))
                    }

                    Text(lastName(name))
                        .font(.caption.weight(.medium))
                        .lineLimit(1)

                    if let sal = salaryForPlayer(playerID, in: record) {
                        Text("$\(viewModel.formatSalary(sal))")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    if let pct = ownershipByPlayerID[playerID] {
                        Text("\(pct)%")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let stats {
                    // G, A, SOT, SV, FD (mapped from DFSPlayerLiveStats)
                    Text("\(stats.points)")
                        .frame(width: 22, alignment: .trailing)
                    Text("\(stats.assists)")
                        .frame(width: 22, alignment: .trailing)
                    Text("\(stats.rebounds)")
                        .frame(width: 28, alignment: .trailing)
                    Text("\(stats.blocks)")
                        .frame(width: 22, alignment: .trailing)
                    Text("\(stats.fgm)")
                        .frame(width: 22, alignment: .trailing)
                } else {
                    Text("-").frame(width: 22, alignment: .trailing)
                    Text("-").frame(width: 22, alignment: .trailing)
                    Text("-").frame(width: 28, alignment: .trailing)
                    Text("-").frame(width: 22, alignment: .trailing)
                    Text("-").frame(width: 22, alignment: .trailing)
                }

                Text(String(format: "%.1f", fpts))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(brandPurple)
                    .frame(width: 38, alignment: .trailing)
            }
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }

        lineupTotalsRow(record: record)
    }

    // MARK: - NHL Expanded Lineup

    /// NHL roster slots in FanDuel order
    private let nhlSlots = ["C", "C", "W", "W", "D", "D", "UTIL", "UTIL", "G"]

    /// Detect NHL goalie from the minutes field marker set by the scoring provider.
    /// Goalies have minutes="G", skaters have minutes="" (empty).
    private func isNHLGoalie(_ stats: DFSPlayerLiveStats?) -> Bool {
        guard let stats else { return false }
        return stats.minutes == "G"
    }

    /// Determine which lineup indices are goalies for an NHL lineup.
    /// Uses minutes == "G" marker from the scoring provider or ESPN position data.
    private func nhlGoalieIndices(playerIDs: [String]) -> Set<Int> {
        var goalies = Set<Int>()
        for i in playerIDs.indices {
            if isNHLGoalie(viewModel.pastTournamentPlayerStats[playerIDs[i]]) {
                goalies.insert(i)
            }
        }
        return goalies
    }

    @ViewBuilder
    private func nhlExpandedLineup(record: DFSTournamentResultRecord) -> some View {
        let playerIDs = record.lineupPlayerIDs
        let playerNames = record.lineupPlayerNames
        let perPlayerPts = resolvePlayerPoints(for: record)
        let isSingleGame = isSingleGameTournament

        // Separate skaters and goalies
        let goalieSet = nhlGoalieIndices(playerIDs: playerIDs)
        let skaterIndices = playerIDs.indices.filter { !goalieSet.contains($0) }
        let goalieIndices = playerIDs.indices.filter { goalieSet.contains($0) }

        // Skater header: G  A  SOG  BLK  FPTS
        HStack(spacing: 0) {
            Text("PLAYER")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("G")
                .frame(width: 26, alignment: .trailing)
            Text("A")
                .frame(width: 26, alignment: .trailing)
            Text("SOG")
                .frame(width: 32, alignment: .trailing)
            Text("BLK")
                .frame(width: 30, alignment: .trailing)
            Text("FPTS")
                .frame(width: 38, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)

        // Skater slot labels (excludes the G slot)
        let skaterSlots: [String] = isSingleGame
            ? Array(repeating: "FLEX", count: max(skaterIndices.count, 5))
            : nhlSlots.filter { $0 != "G" }

        // Skater rows
        ForEach(Array(skaterIndices.enumerated()), id: \.offset) { skaterIdx, index in
            let playerID = playerIDs[index]
            let storedName = index < playerNames.count ? playerNames[index] : playerID
            let name = resolvePlayerName(storedName: storedName, playerID: playerID)
            let fpts = perPlayerPts[playerID] ?? 0  // already includes 1.5x MVP multiplier from settlement
            let isMVP = isSingleGame && index == 0
            let stats = viewModel.pastTournamentPlayerStats[playerID]
            let slot = isMVP ? "MVP" : (skaterIdx < skaterSlots.count ? skaterSlots[skaterIdx] : "FLEX")
            let isWideSlotExp = isMVP || slot.count > 2

            HStack(spacing: 0) {
                HStack(spacing: 4) {
                    Text(slot)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(isMVP ? .black : .white)
                        .lineLimit(1)
                        .frame(width: isWideSlotExp ? 28 : 18, height: 18)
                        .background(isMVP ? Color.yellow : brandPurple.opacity(0.7))
                        .clipShape(isWideSlotExp ? AnyShape(Capsule()) : AnyShape(Circle()))

                    Text(lastName(name))
                        .font(.caption.weight(.medium))
                        .lineLimit(1)

                    if let sal = salaryForPlayer(playerID, in: record) {
                        Text("$\(viewModel.formatSalary(sal))")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    if let pct = ownershipByPlayerID[playerID] {
                        Text("\(pct)%")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let stats {
                    Text("\(stats.points)")          // Goals
                        .frame(width: 26, alignment: .trailing)
                    Text("\(stats.rebounds)")         // Assists
                        .frame(width: 26, alignment: .trailing)
                    Text("\(stats.assists)")          // SOG
                        .frame(width: 32, alignment: .trailing)
                    Text("\(stats.steals)")           // BLK
                        .frame(width: 30, alignment: .trailing)
                } else {
                    Text("-").frame(width: 26, alignment: .trailing)
                    Text("-").frame(width: 26, alignment: .trailing)
                    Text("-").frame(width: 32, alignment: .trailing)
                    Text("-").frame(width: 30, alignment: .trailing)
                }

                Text(String(format: "%.1f", fpts))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(brandPurple)
                    .frame(width: 38, alignment: .trailing)
            }
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }

        // Goalie section
        if !goalieIndices.isEmpty {
            HStack(spacing: 0) {
                Text("GOALIE")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("SV")
                    .frame(width: 30, alignment: .trailing)
                Text("GA")
                    .frame(width: 26, alignment: .trailing)
                Text("W")
                    .frame(width: 26, alignment: .trailing)
                Text("FPTS")
                    .frame(width: 38, alignment: .trailing)
            }
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            ForEach(goalieIndices, id: \.self) { index in
                let playerID = playerIDs[index]
                let storedName = index < playerNames.count ? playerNames[index] : playerID
                let name = resolvePlayerName(storedName: storedName, playerID: playerID)
                let fpts = perPlayerPts[playerID] ?? 0
                let stats = viewModel.pastTournamentPlayerStats[playerID]
                let isGoalieMVP = isSingleGame && index == 0

                HStack(spacing: 0) {
                    HStack(spacing: 4) {
                        Text(isGoalieMVP ? "MVP" : "G")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(isGoalieMVP ? .black : .white)
                            .frame(width: isGoalieMVP ? 28 : 18, height: 18)
                            .background(isGoalieMVP ? Color.yellow : brandPurple.opacity(0.7))
                            .clipShape(isGoalieMVP ? AnyShape(Capsule()) : AnyShape(Circle()))

                        Text(lastName(name))
                            .font(.caption.weight(.medium))
                            .lineLimit(1)

                        if let sal = salaryForPlayer(playerID, in: record) {
                            Text("$\(viewModel.formatSalary(sal))")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(.secondary)
                        }

                        if let pct = ownershipByPlayerID[playerID] {
                            Text("\(pct)%")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if let stats {
                        Text("\(stats.points)")      // Saves
                            .frame(width: 30, alignment: .trailing)
                        Text("\(stats.rebounds)")     // Goals Against
                            .frame(width: 26, alignment: .trailing)
                        Text("\(stats.assists)")      // Wins
                            .frame(width: 26, alignment: .trailing)
                    } else {
                        Text("-").frame(width: 30, alignment: .trailing)
                        Text("-").frame(width: 26, alignment: .trailing)
                        Text("-").frame(width: 26, alignment: .trailing)
                    }

                    Text(String(format: "%.1f", fpts))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(brandPurple)
                        .frame(width: 38, alignment: .trailing)
                }
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
        }

        lineupTotalsRow(record: record)
    }

    // MARK: - MLB Expanded Lineup

    /// Whether the player is a pitcher based on the stat `minutes` field format.
    /// Batters have "X AB", pitchers have IP like "5.0 IP" or numeric-only like "5.2".
    /// Players with empty/missing stats default to batter (only 1 pitcher slot in a 9-man lineup).
    private func isMLBPitcher(_ stats: DFSPlayerLiveStats?) -> Bool {
        guard let stats else { return false }
        let m = stats.minutes.trimmingCharacters(in: .whitespaces)
        // Explicitly a batter if minutes contains "AB"
        if m.contains("AB") { return false }
        // Empty or blank minutes = resolved-only player with no box score → default to batter
        if m.isEmpty { return false }
        // Contains IP marker → pitcher
        if m.contains("IP") { return true }
        // Numeric-only value (e.g. "5.2") → likely innings pitched
        let cleaned = m.replacingOccurrences(of: ".", with: "")
        return cleaned.allSatisfy(\.isNumber)
    }

    @ViewBuilder
    private func mlbExpandedLineup(record: DFSTournamentResultRecord) -> some View {
        let playerIDs = record.lineupPlayerIDs
        let playerNames = record.lineupPlayerNames
        let perPlayerPts = resolvePlayerPoints(for: record)

        // Split into batters and pitchers for display
        let batterIndices = playerIDs.indices.filter { idx in
            let pid = playerIDs[idx]
            return !isMLBPitcher(viewModel.pastTournamentPlayerStats[pid])
        }
        let pitcherIndices = playerIDs.indices.filter { idx in
            let pid = playerIDs[idx]
            return isMLBPitcher(viewModel.pastTournamentPlayerStats[pid])
        }

        // Batter section
        if !batterIndices.isEmpty {
            HStack(spacing: 0) {
                Text("BATTER")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("H/AB")
                    .frame(width: 34, alignment: .trailing)
                Text("HR")
                    .frame(width: 26, alignment: .trailing)
                Text("RBI")
                    .frame(width: 28, alignment: .trailing)
                Text("R")
                    .frame(width: 22, alignment: .trailing)
                Text("SB")
                    .frame(width: 24, alignment: .trailing)
                Text("FPTS")
                    .frame(width: 38, alignment: .trailing)
            }
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            ForEach(batterIndices, id: \.self) { index in
                let playerID = playerIDs[index]
                let storedName = index < playerNames.count ? playerNames[index] : playerID
                let name = resolvePlayerName(storedName: storedName, playerID: playerID)
                let fpts = perPlayerPts[playerID] ?? 0
                let stats = viewModel.pastTournamentPlayerStats[playerID]

                mlbBatterRow(index: index, name: name, playerID: playerID, stats: stats, fpts: fpts, record: record)
            }
        }

        // Pitcher section
        if !pitcherIndices.isEmpty {
            HStack(spacing: 0) {
                Text("PITCHER")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("IP")
                    .frame(width: 28, alignment: .trailing)
                Text("K")
                    .frame(width: 24, alignment: .trailing)
                Text("ER")
                    .frame(width: 24, alignment: .trailing)
                Text("W")
                    .frame(width: 22, alignment: .trailing)
                Text("FPTS")
                    .frame(width: 38, alignment: .trailing)
            }
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .padding(.top, 4)

            ForEach(pitcherIndices, id: \.self) { index in
                let playerID = playerIDs[index]
                let storedName = index < playerNames.count ? playerNames[index] : playerID
                let name = resolvePlayerName(storedName: storedName, playerID: playerID)
                let fpts = perPlayerPts[playerID] ?? 0
                let stats = viewModel.pastTournamentPlayerStats[playerID]

                mlbPitcherRow(index: index, name: name, playerID: playerID, stats: stats, fpts: fpts, record: record)
            }
        }

        lineupTotalsRow(record: record)
    }

    @ViewBuilder
    private func mlbBatterRow(index: Int, name: String, playerID: String, stats: DFSPlayerLiveStats?, fpts: Double, record: DFSTournamentResultRecord) -> some View {
        let isMVP = isSingleGameTournament && index == 0
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                // A batter-row player must never badge "SP" — that leaks in from
                // a two-way player's "-sp" pitcher sibling (or today's pool typing
                // Ohtani as a pitcher). Treat SP here as a batter slot.
                let rawPos = slotPosition(for: playerID)
                let pos = rawPos == "SP" ? "1B" : rawPos
                let slotText = isMVP ? "MVP" : (pos.isEmpty ? "\(index + 1)" : pos)
                let isWide = isMVP || slotText.count > 2
                Text(slotText)
                    .font(.system(size: isMVP ? 7 : 8, weight: .bold))
                    .foregroundStyle(isMVP ? .black : .white)
                    .frame(width: isWide ? 28 : 18, height: 18)
                    .background(isMVP ? Color.yellow : brandPurple.opacity(0.7))
                    .clipShape(isWide ? AnyShape(Capsule()) : AnyShape(Circle()))

                Text(lastName(name))
                    .font(.caption.weight(.medium))
                    .lineLimit(1)

                if let sal = salaryForPlayer(playerID, in: record) {
                    Text("$\(viewModel.formatSalary(sal))")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                if let pct = ownershipByPlayerID[playerID] {
                    Text("\(pct)%")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let stats {
                // H/AB, HR, RBI, R, SB
                let ab = mlbAtBats(from: stats.minutes)
                if let ab {
                    Text("\(stats.points)/\(ab)")
                        .frame(width: 34, alignment: .trailing)
                } else {
                    Text("\(stats.points)")
                        .frame(width: 34, alignment: .trailing)
                }
                Text("\(stats.rebounds)")
                    .frame(width: 26, alignment: .trailing)
                Text("\(stats.assists)")
                    .frame(width: 28, alignment: .trailing)
                Text("\(stats.steals)")
                    .frame(width: 22, alignment: .trailing)
                Text("\(stats.turnovers)")
                    .frame(width: 24, alignment: .trailing)
            } else {
                Text("-").frame(width: 34, alignment: .trailing)
                Text("-").frame(width: 26, alignment: .trailing)
                Text("-").frame(width: 28, alignment: .trailing)
                Text("-").frame(width: 22, alignment: .trailing)
                Text("-").frame(width: 24, alignment: .trailing)
            }

            Text(String(format: "%.1f", fpts))
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(isMVP ? .orange : brandPurple)
                .frame(width: 38, alignment: .trailing)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func mlbPitcherRow(index: Int, name: String, playerID: String, stats: DFSPlayerLiveStats?, fpts: Double, record: DFSTournamentResultRecord) -> some View {
        let isMVP = isSingleGameTournament && index == 0
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                // Pitchers always badge "SP" (the SP roster slot / two-way "-sp").
                let slotText = isMVP ? "MVP" : "SP"
                let isWide = isMVP
                Text(slotText)
                    .font(.system(size: isMVP ? 7 : 8, weight: .bold))
                    .foregroundStyle(isMVP ? .black : .white)
                    .frame(width: isWide ? 28 : 18, height: 18)
                    .background(isMVP ? Color.yellow : Color.blue.opacity(0.6))
                    .clipShape(isWide ? AnyShape(Capsule()) : AnyShape(Circle()))

                Text(lastName(name))
                    .font(.caption.weight(.medium))
                    .lineLimit(1)

                if let sal = salaryForPlayer(playerID, in: record) {
                    Text("$\(viewModel.formatSalary(sal))")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                if let pct = ownershipByPlayerID[playerID] {
                    Text("\(pct)%")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let stats {
                // IP, K, ER, W (mapped from minutes, points, rebounds, assists)
                Text(stats.minutes)
                    .frame(width: 28, alignment: .trailing)
                Text("\(stats.points)")
                    .frame(width: 24, alignment: .trailing)
                Text("\(stats.rebounds)")
                    .frame(width: 24, alignment: .trailing)
                Text("\(stats.assists)")
                    .frame(width: 22, alignment: .trailing)
            } else {
                Text("-").frame(width: 28, alignment: .trailing)
                Text("-").frame(width: 24, alignment: .trailing)
                Text("-").frame(width: 24, alignment: .trailing)
                Text("-").frame(width: 22, alignment: .trailing)
            }

            Text(String(format: "%.1f", fpts))
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(isMVP ? .orange : brandPurple)
                .frame(width: 38, alignment: .trailing)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - Golf Expanded Lineup

    @ViewBuilder
    private func golfExpandedLineup(record: DFSTournamentResultRecord) -> some View {
        // Golf header: GOLFER | SAL | R1 | R2 | R3 | R4 | FPTS
        HStack(spacing: 0) {
            Text("GOLFER")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("PAR")
                .frame(width: 42, alignment: .trailing)
            Text("R1")
                .frame(width: 26, alignment: .trailing)
            Text("R2")
                .frame(width: 26, alignment: .trailing)
            Text("R3")
                .frame(width: 26, alignment: .trailing)
            Text("R4")
                .frame(width: 26, alignment: .trailing)
            Text("FPTS")
                .frame(width: 40, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)

        let playerIDs = record.lineupPlayerIDs
        let playerNames = record.lineupPlayerNames
        let perPlayerPts = resolvePlayerPoints(for: record)

        ForEach(Array(playerIDs.enumerated()), id: \.offset) { index, playerID in
            let storedName = index < playerNames.count ? playerNames[index] : playerID
            let name = resolvePlayerName(storedName: storedName, playerID: playerID)
            let fpts = perPlayerPts[playerID] ?? 0
            let stats = viewModel.pastTournamentPlayerStats[playerID]

            HStack(spacing: 0) {
                HStack(spacing: 4) {
                    Text("\(index + 1)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(brandPurple.opacity(0.7))
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(lastName(name))
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            // Show finishing position (e.g. "T4", "1", "CUT")
                            if let s = stats, !s.minutes.isEmpty, s.minutes != "-" {
                                Text(s.minutes)
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(s.minutes == "CUT" || s.minutes == "WD" ? Color.gray : Color.blue.opacity(0.7))
                                    .clipShape(Capsule())
                            }
                            if let pct = ownershipByPlayerID[playerID] {
                                Text("\(pct)%")
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(.orange)
                            }
                        }
                        HStack(spacing: 4) {
                            if let sal = salaryForPlayer(playerID, in: record) {
                                Text("$\(viewModel.formatSalary(sal))")
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            // Show position bonus points if applicable
                            if let s = stats, s.ftm > 0, s.ftm < 51 {
                                let bonus = DFSEngine.dkPositionPoints(s.ftm)
                                if bonus > 0 {
                                    Text("+\(Int(bonus))pos")
                                        .font(.system(size: 7, weight: .medium))
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Score to par
                if let s = stats {
                    let scoreToPar = s.points
                    let display = scoreToPar == 0 ? "E" : (scoreToPar > 0 ? "+\(scoreToPar)" : "\(scoreToPar)")
                    Text(display)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(scoreToPar < 0 ? .red : (scoreToPar > 0 ? Color(.systemGreen) : .secondary))
                        .frame(width: 42, alignment: .trailing)
                } else {
                    Text("-")
                        .frame(width: 42, alignment: .trailing)
                }

                // Round scores (fgm=R1, fga=R2, threePM=R3, threePA=R4)
                if let stats {
                    golfRoundScoreText(stats.fgm)
                        .frame(width: 26, alignment: .trailing)
                    golfRoundScoreText(stats.fga)
                        .frame(width: 26, alignment: .trailing)
                    golfRoundScoreText(stats.threePM)
                        .frame(width: 26, alignment: .trailing)
                    golfRoundScoreText(stats.threePA)
                        .frame(width: 26, alignment: .trailing)
                } else {
                    Text("-").frame(width: 26, alignment: .trailing)
                    Text("-").frame(width: 26, alignment: .trailing)
                    Text("-").frame(width: 26, alignment: .trailing)
                    Text("-").frame(width: 26, alignment: .trailing)
                }

                Text(String(format: "%.1f", fpts))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(brandPurple)
                    .frame(width: 40, alignment: .trailing)
            }
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }

        lineupTotalsRow(record: record)
    }

    /// Format a golf round score — show the score if > 0, otherwise "-"
    private func golfRoundScoreText(_ score: Int) -> some View {
        Group {
            if score > 0 {
                Text("\(score)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.primary)
            } else {
                Text("-")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Shared Totals Row

    @ViewBuilder
    private func lineupTotalsRow(record: DFSTournamentResultRecord) -> some View {
        let playerIDs = record.lineupPlayerIDs
        let totalSalary = playerIDs.reduce(0) { sum, pid in
            sum + (salaryForPlayer(pid, in: record) ?? 0)
        }
        // Show the REAL salary sum, not a `min(sum, cap)`. The cap was being
        // used to hide over-cap bot lineups in the UI, which masked a real
        // bug in the bot field (stale prices, cross-session showdown
        // conversion drift). When a lineup actually exceeds the cap, color
        // the total red so the bug is visible.
        let capLimit = 50000
        let isOverCap = totalSalary > capLimit
        Divider().padding(.horizontal, 12)
        HStack(spacing: 0) {
            Text("TOTAL")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            if totalSalary > 0 {
                Text("$\(viewModel.formatSalary(totalSalary))")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isOverCap ? .red : .secondary)
                    .padding(.leading, 4)
            }
            Spacer()
            Text(String(format: "%.1f", record.totalPoints))
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(brandPurple)
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// Compute aggregate score-to-par for a golf leaderboard entry
    private func golfEntryScoreToPar(_ entry: DFSLeaderboardEntry) -> Int? {
        guard let record = resultByEntryID[entry.id] else { return nil }
        var total = 0
        var hasAny = false
        for pid in record.lineupPlayerIDs {
            if let stats = viewModel.pastTournamentPlayerStats[pid] {
                total += stats.points
                hasAny = true
            }
        }
        return hasAny ? total : nil
    }

    // MARK: - Helpers

    /// Resolve per-player fantasy points for a result record.
    /// When `playerPoints` is nil (synthetic entries), try to find a matching result
    /// record (e.g., a bot with the same lineup) and copy its per-player points.
    /// Falls back to computing from pastTournamentPlayerStats (box scores).
    private func resolvePlayerPoints(for record: DFSTournamentResultRecord) -> [String: Double] {
        if let pts = record.playerPoints, !pts.isEmpty { return pts }
        // Try to find another result record with the same lineup player IDs
        let targetSet = Set(record.lineupPlayerIDs)
        for other in viewModel.pastTournamentResultRecords {
            guard other.id != record.id else { continue }
            guard let otherPts = other.playerPoints, !otherPts.isEmpty else { continue }
            if Set(other.lineupPlayerIDs) == targetSet {
                return otherPts
            }
        }
        // Fall back to box score fantasy points
        var computed: [String: Double] = [:]
        for (index, pid) in record.lineupPlayerIDs.enumerated() {
            if let stats = viewModel.pastTournamentPlayerStats[pid] {
                var pts = stats.fantasyPoints
                // Apply MVP multiplier for single game first slot
                if isSingleGameTournament && index == 0 { pts *= 1.5 }
                computed[pid] = pts
            }
        }
        return computed
    }

    /// Resolve player name from stored name, falling back to box score stats
    /// and then to other result records that may have this player's name resolved.
    private func resolvePlayerName(storedName: String, playerID: String) -> String {
        let rawPrefixes = ["nba-", "pga-", "ncaam-", "mlb-", "nhl-", "epl-", "ucl-", "wc-"]
        let needsResolution = rawPrefixes.contains(where: { storedName.hasPrefix($0) })
            || storedName == "Unknown" || storedName.isEmpty

        if needsResolution {
            // Try box score / live stats lookup
            if let name = viewModel.pastTournamentPlayerStats[playerID]?.name,
               !name.isEmpty,
               !rawPrefixes.contains(where: { name.hasPrefix($0) }) {
                return name
            }
            // Try other result records — another entry may have this player's name resolved
            for record in viewModel.pastTournamentResultRecords {
                if let idx = record.lineupPlayerIDs.firstIndex(of: playerID),
                   idx < record.lineupPlayerNames.count {
                    let otherName = record.lineupPlayerNames[idx]
                    if !otherName.isEmpty,
                       !rawPrefixes.contains(where: { otherName.hasPrefix($0) }),
                       otherName != "Unknown" {
                        return otherName
                    }
                }
            }
            // Last chance: cached preloaded player info — survives pool refresh /
            // DNP filtering, so a player who never played still has their name.
            if let cached = viewModel.cachedPlayerName(for: playerID) {
                return cached
            }
            return "Unknown"
        }
        return storedName
    }

    private func lastName(_ fullName: String) -> String {
        let parts = fullName.components(separatedBy: " ").filter { !$0.isEmpty }
        guard parts.count >= 2 else { return fullName.trimmingCharacters(in: .whitespaces) }
        let suffixes: Set<String> = ["Jr.", "Jr", "Sr.", "Sr", "II", "III", "IV", "V"]
        if let last = parts.last, suffixes.contains(last), parts.count >= 3 {
            return parts[parts.count - 2] + " " + last
        }
        return parts.last ?? fullName.trimmingCharacters(in: .whitespaces)
    }

    /// Extract at-bats from the minutes field (e.g. "4 AB" → 4)
    private func mlbAtBats(from minutes: String) -> Int? {
        let m = minutes.trimmingCharacters(in: .whitespaces)
        guard m.contains("AB") else { return nil }
        let parts = m.components(separatedBy: " ")
        return Int(parts.first ?? "")
    }

    /// Look up salary for a player: per-entry record first, then tournament-level slate salaries.
    /// Treats $0 as missing so it falls through to the next source.
    /// Falls back to a minimum salary floor so every player always shows a price.
    private func salaryForPlayer(_ playerID: String, in record: DFSTournamentResultRecord) -> Int? {
        let direct = rawSalary(playerID, in: record)
        // MLB two-way player (Ohtani): the lineup carries TWO entries for the
        // same person — one scored as a batter, one as a pitcher — and the
        // per-id salaries stored at submit time were sometimes swapped, so the
        // batter row showed the pitcher's price and vice versa. Matching by id
        // suffix isn't reliable (the stored ids/keys vary), so detect the pair
        // the same way the section split does: same last name + OPPOSITE role
        // (role read from the box-score stat shape). DK always prices the
        // pitcher higher than the hitter, so assign max→pitcher, min→batter.
        if isMLB, let mySal = direct {
            let ids = record.lineupPlayerIDs
            let names = record.lineupPlayerNames
            func lastNameForLineupID(_ id: String) -> String {
                let idx = ids.firstIndex(of: id)
                let stored = (idx != nil && idx! < names.count) ? names[idx!] : id
                return lastName(resolvePlayerName(storedName: stored, playerID: id)).lowercased()
            }
            let myName = lastNameForLineupID(playerID)
            let myIsPitcher = isMLBPitcher(viewModel.pastTournamentPlayerStats[playerID])
            if !myName.isEmpty {
                for otherID in ids where otherID != playerID {
                    guard lastNameForLineupID(otherID) == myName else { continue }
                    let otherIsPitcher = isMLBPitcher(viewModel.pastTournamentPlayerStats[otherID])
                    guard otherIsPitcher != myIsPitcher, let otherSal = rawSalary(otherID, in: record) else { continue }
                    return myIsPitcher ? max(mySal, otherSal) : min(mySal, otherSal)
                }
            }
        }
        if let direct { return direct }
        // Last resort: show minimum salary floor for the sport so no player is priceless
        if isNHL { return 4500 }
        if isMLB { return 2000 }
        return 3500
    }

    /// Direct salary lookup (per-entry record, then tournament slate). Treats
    /// $0 as missing. No floor fallback — callers add that.
    private func rawSalary(_ playerID: String, in record: DFSTournamentResultRecord) -> Int? {
        if let sal = record.playerSalaries?[playerID], sal > 0 { return sal }
        if let sal = viewModel.pastTournamentSlateSalaries[playerID], sal > 0 { return sal }
        return nil
    }

}
