import SwiftUI

/// Wrapper to disambiguate NavigationLink values from matchup IDs (both are String)
struct BestBallMemberNavID: Hashable {
    let memberID: String
}

struct BestBallStandingsView: View {
    @Bindable var viewModel: BestBallViewModel
    let leagueID: String
    var onSelectMatchup: ((BestBallMatchup) -> Void)? = nil
    @EnvironmentObject private var auth: AuthViewModel

    private var brandPurple: Color {
        Color(red: 0.48, green: 0.23, blue: 0.93)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Week navigation (hidden for dingers-only since there are no weekly matchups)
                if let league = viewModel.currentLeague, !league.isDingersOnly {
                    weekNavigator(league)
                }

                // Standings table
                standingsTable

                // This week's matchups (hidden for dingers-only)
                if !viewModel.currentWeekMatchups.isEmpty,
                   viewModel.currentLeague?.scoringMode == .normal {
                    matchupsSection
                }

                // Manual refresh button — kept as a fallback for the
                // automatic catch-up flow (which runs on LeagueDetail
                // view appearance). Available to any member: gives them
                // a way to force-pull live scores mid-week without
                // waiting for the next view re-mount, and lets the host
                // force a redo if a previous compute hit transient ESPN
                // errors. Idempotent — `batchUpsertWeeklyScores`
                // converges multiple concurrent computes on the same
                // canonical values.
                if let league = viewModel.currentLeague, league.status == "active" {
                    let realWeek = BestBallSeasonHelper.currentWeekNumber(for: league.sport)
                    let weeksBehind = max(0, realWeek - league.currentWeek)

                    Button {
                        Task {
                            if league.isDingersOnly {
                                await viewModel.refreshDingersLive(leagueID: leagueID, forceRefresh: true)
                            } else if weeksBehind > 0 {
                                await viewModel.catchUpScoring(leagueID: leagueID)
                            } else {
                                await viewModel.computeWeeklyScores(leagueID: leagueID)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if !viewModel.catchUpProgress.isEmpty {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text(viewModel.catchUpProgress)
                                    .font(.caption.weight(.medium))
                            } else if league.isDingersOnly && viewModel.isLoadingDingersHR {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Loading HR…")
                                    .font(.caption.weight(.medium))
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption.weight(.semibold))
                                Text(league.isDingersOnly ? "Refresh HR Counts" : "Refresh Scores")
                                    .font(.caption.weight(.medium))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundStyle(brandPurple)
                        .background(brandPurple.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .padding(16)
        }
        .task {
            // For dingers-only, fetch live HR data on load
            if viewModel.currentLeague?.isDingersOnly == true {
                await viewModel.refreshDingersLive(leagueID: leagueID)
            }
        }
    }

    // MARK: - Week Navigator

    private func weekNavigator(_ league: BestBallLeague) -> some View {
        HStack {
            Button {
                if viewModel.selectedWeek > 1 {
                    viewModel.selectedWeek -= 1
                    viewModel.loadMatchupsForWeek(week: viewModel.selectedWeek, league: league)
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .foregroundStyle(viewModel.selectedWeek > 1 ? brandPurple : .secondary)
            }
            .disabled(viewModel.selectedWeek <= 1)

            Spacer()

            VStack(spacing: 2) {
                Text("Week \(viewModel.selectedWeek) of \(league.totalWeeks)")
                    .font(.headline)
                Label(league.sport, systemImage: sportIcon(league.sport))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                let realWeek = BestBallSeasonHelper.currentWeekNumber(for: league.sport)
                let maxWeek = min(max(league.currentWeek, realWeek), league.totalWeeks)
                if viewModel.selectedWeek < maxWeek {
                    viewModel.selectedWeek += 1
                    viewModel.loadMatchupsForWeek(week: viewModel.selectedWeek, league: league)
                }
            } label: {
                let realWeek = BestBallSeasonHelper.currentWeekNumber(for: league.sport)
                let maxWeek = min(max(league.currentWeek, realWeek), league.totalWeeks)
                Image(systemName: "chevron.right")
                    .font(.headline)
                    .foregroundStyle(viewModel.selectedWeek < maxWeek ? brandPurple : .secondary)
            }
            .disabled(viewModel.selectedWeek >= min(max(league.currentWeek, BestBallSeasonHelper.currentWeekNumber(for: league.sport)), league.totalWeeks))
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    // MARK: - Standings Table

    private var standingsTable: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(viewModel.standings.isEmpty ? "Teams" : "Standings")
                .font(.headline)

            if viewModel.currentLeague?.isDingersOnly == true && !viewModel.liveHRByMember.isEmpty {
                // Dingers-only: always prefer live HR counts when available
                let liveStandings = viewModel.currentMembers.map { member -> (member: BestBallMember, hr: Int) in
                    let hr = viewModel.liveHRByMember[member.id]?.values.reduce(0, +) ?? 0
                    return (member, Int(hr))
                }.sorted { $0.hr > $1.hr }

                // Header
                HStack {
                    Text("#")
                        .frame(width: 24, alignment: .leading)
                    Text("TEAM")
                    Spacer()
                    Text("HR")
                        .frame(width: 56, alignment: .trailing)
                }
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)

                ForEach(Array(liveStandings.enumerated()), id: \.element.member.id) { idx, entry in
                    let isMe = entry.member.userID == viewModel.userID
                    NavigationLink {
                        BestBallRosterView(viewModel: viewModel, memberID: entry.member.id)
                    } label: {
                        HStack {
                            Text("\(idx + 1)")
                                .font(.subheadline.weight(.medium).monospacedDigit())
                                .foregroundStyle(idx < 3 ? Color(red: 0.95, green: 0.78, blue: 0.20) : .secondary)
                                .frame(width: 24, alignment: .leading)
                            Text(entry.member.displayName)
                                .font(.subheadline.weight(isMe ? .bold : .medium))
                                .foregroundStyle(isMe ? brandPurple : .primary)
                            Spacer()
                            Text("\(entry.hr)")
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(isMe ? brandPurple : .primary)
                                .frame(width: 56, alignment: .trailing)
                        }
                        .padding(.vertical, 3)
                        .background(isMe ? brandPurple.opacity(0.08) : .clear)
                    }
                    .buttonStyle(.plain)
                }
            } else if !viewModel.standings.isEmpty && viewModel.currentLeague?.isDingersOnly != true {
                // Normal (non-dingers) standings from DB
                // Filter to only members that exist in this league
                let validMemberIDs = Set(viewModel.currentMembers.map(\.id))
                let filteredStandings = viewModel.standings.filter { validMemberIDs.contains($0.memberID) }

                // Header
                HStack {
                    Text("#")
                        .frame(width: 24, alignment: .leading)
                    Text("TEAM")
                    Spacer()
                    Text("W-L")
                        .frame(width: 50, alignment: .trailing)
                    Text("PTS")
                        .frame(width: 66, alignment: .trailing)
                }
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)

                ForEach(filteredStandings) { standing in
                    let isMe = standing.memberID == viewModel.myMemberID
                    NavigationLink {
                        BestBallRosterView(viewModel: viewModel, memberID: standing.memberID)
                    } label: {
                        HStack {
                            Text("\(standing.rank)")
                                .font(.subheadline.weight(.medium).monospacedDigit())
                                .foregroundStyle(standing.rank <= 3 ? Color(red: 0.95, green: 0.78, blue: 0.20) : .secondary)
                                .frame(width: 24, alignment: .leading)
                            Text(viewModel.memberName(for: standing.memberID))
                                .font(.subheadline.weight(isMe ? .bold : .medium))
                                .foregroundStyle(isMe ? brandPurple : .primary)
                                .lineLimit(1)
                            Spacer()
                            Text("\(standing.wins)-\(standing.losses)")
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(width: 50, alignment: .trailing)
                            Text(String(format: "%.1f", standing.totalPoints))
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(isMe ? brandPurple : .primary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(width: 66, alignment: .trailing)
                        }
                        .padding(.vertical, 3)
                        .background(isMe ? brandPurple.opacity(0.08) : .clear)
                    }
                    .buttonStyle(.plain)
                }
            } else if viewModel.currentLeague?.isDingersOnly == true && viewModel.liveHRByMember.isEmpty {
                // Loading state for dingers-only before any data arrives
                VStack(spacing: 12) {
                    if viewModel.isLoadingDingersHR {
                        ProgressView()
                            .tint(brandPurple)
                        Text("Loading HR counts…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Tap \"Refresh HR Counts\" to load standings")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                // No standings yet — show members with tap to view roster
                Text("No weekly scores yet — tap a team to view their roster")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)

                ForEach(viewModel.currentMembers) { member in
                    let isMe = member.userID == viewModel.userID
                    NavigationLink {
                        BestBallRosterView(viewModel: viewModel, memberID: member.id)
                    } label: {
                        HStack {
                            Image(systemName: member.isBot ? "cpu" : "person.fill")
                                .font(.caption)
                                .foregroundStyle(member.isBot ? .orange : brandPurple)
                                .frame(width: 24)
                            Text(member.displayName)
                                .font(.subheadline.weight(isMe ? .bold : .medium))
                                .foregroundStyle(isMe ? brandPurple : .primary)
                            if isMe {
                                Text("(You)")
                                    .font(.caption)
                                    .foregroundStyle(brandPurple)
                            }
                            Spacer()
                            let rosterCount = viewModel.draftState?.roster(for: member.id).count ?? 0
                            Text("\(rosterCount) players")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    // MARK: - Matchups Section

    private var matchupsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Week \(viewModel.selectedWeek) Matchups")
                .font(.headline)

            ForEach(viewModel.currentWeekMatchups) { matchup in
                Button {
                    onSelectMatchup?(matchup)
                } label: {
                    matchupCard(matchup)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    private func matchupCard(_ matchup: BestBallMatchup) -> some View {
        let m1Name = viewModel.memberName(for: matchup.member1ID)
        let m2Name = viewModel.memberName(for: matchup.member2ID)
        let hasScores = matchup.member1Score > 0 || matchup.member2Score > 0
        let isMyMatchup = matchup.member1ID == viewModel.myMemberID || matchup.member2ID == viewModel.myMemberID

        return HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if matchup.winnerID == matchup.member1ID {
                        Image(systemName: "crown.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                    Text(m1Name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(matchup.member1ID == viewModel.myMemberID ? brandPurple : .primary)
                }
                HStack(spacing: 6) {
                    if matchup.winnerID == matchup.member2ID {
                        Image(systemName: "crown.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                    Text(m2Name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(matchup.member2ID == viewModel.myMemberID ? brandPurple : .primary)
                }
            }

            Spacer()

            if hasScores {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(String(format: "%.1f", matchup.member1Score))
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(matchup.winnerID == matchup.member1ID ? brandPurple : .primary)
                    Text(String(format: "%.1f", matchup.member2Score))
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(matchup.winnerID == matchup.member2ID ? brandPurple : .primary)
                }
            } else {
                Text("vs")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(isMyMatchup ? brandPurple.opacity(0.06) : Color(.systemGray6).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func sportIcon(_ sport: String) -> String {
        switch sport {
        case "NBA": return "basketball"
        case "MLB": return "baseball"
        case "NFL": return "football"
        default: return "sportscourt"
        }
    }
}
