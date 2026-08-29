import SwiftUI

/// Identifies a tapped Best Ball player for the game-log sheet. The
/// playerID is the prefixed DFS-style id ("nfl-4262921") that both
/// `BestBallPlayer.id` and `BestBallPick.playerID` already carry.
struct BBPlayerRef: Identifiable, Hashable {
    let playerID: String
    let name: String
    let team: String
    let position: String
    var id: String { playerID }
}

/// Player card with this season's and last season's game logs plus
/// fantasy-point totals, scored with the Best Ball scoring model for
/// NFL/CFB. Presented from the draft board, the draft roster/inspect
/// sheets, and the post-draft roster view.
struct BestBallPlayerDetailSheet: View {
    @Bindable var viewModel: BestBallViewModel
    let player: BBPlayerRef
    /// Non-nil when opened from the draft board while drafting is
    /// possible — renders a Draft button pinned to the bottom.
    var onDraft: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var logsBySeason: [Int: [DFSPlayerGameLog]] = [:]
    @State private var selectedSeason: Int = 0
    @State private var isLoading = true

    private var brandPurple: Color {
        Color(red: 0.48, green: 0.23, blue: 0.93)
    }

    private var sport: String { viewModel.currentLeague?.sport ?? "NFL" }

    /// [thisSeason, lastSeason] in ESPN season-year terms.
    private var seasons: [Int] {
        let current = Self.currentSeason(for: sport)
        return [current, current - 1]
    }

    /// ESPN's season year for "this season": NFL/CFB roll in March
    /// (Jan/Feb still belong to the prior season), NBA uses the year the
    /// season ends, MLB is the calendar year.
    static func currentSeason(for sport: String) -> Int {
        let now = Date()
        let year = Calendar.current.component(.year, from: now)
        let month = Calendar.current.component(.month, from: now)
        switch sport {
        case "NFL", "CFB": return month <= 2 ? year - 1 : year
        case "NBA": return month >= 10 ? year + 1 : year
        case "EPL": return month >= 7 ? year : year - 1   // labeled by August start year
        default: return year
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header

                Picker("Season", selection: $selectedSeason) {
                    ForEach(seasons, id: \.self) { season in
                        Text(seasonLabel(season)).tag(season)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                if isLoading {
                    Spacer()
                    ProgressView("Loading game log...")
                    Spacer()
                } else {
                    let logs = logsBySeason[selectedSeason] ?? []
                    if logs.isEmpty {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "calendar.badge.clock")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("No games in \(seasonLabel(selectedSeason))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    } else {
                        totalsBar(logs)
                        gameList(logs)
                    }
                }

                if let onDraft {
                    Button {
                        Haptics.medium()
                        onDraft()
                        dismiss()
                    } label: {
                        Text("Draft \(player.name)")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(brandPurple)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle(player.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task {
                selectedSeason = seasons[0]
                let provider = ESPNPlayerGameLogProvider()
                var loaded: [Int: [DFSPlayerGameLog]] = [:]
                for season in seasons {
                    let logs = (try? await provider.fetchGameLog(
                        playerID: player.playerID, position: player.position,
                        limit: 40, season: season
                    )) ?? []
                    loaded[season] = logs
                }
                logsBySeason = loaded
                // Land on the season that actually has games (preseason
                // opens on last year's log instead of an empty screen).
                if loaded[seasons[0]]?.isEmpty != false,
                   loaded[seasons[1]]?.isEmpty == false {
                    selectedSeason = seasons[1]
                }
                isLoading = false
            }
        }
        .presentationDetents([.large])
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                let bye = viewModel.byeLabel(forTeam: player.team)
                Text("\(player.position) • \(player.team)\(bye.map { " • Bye \($0)" } ?? "")")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: - Totals

    private func totalsBar(_ logs: [DFSPlayerGameLog]) -> some View {
        let total = logs.reduce(0.0) { $0 + fantasyPoints($1) }
        let avg = logs.isEmpty ? 0 : total / Double(logs.count)
        return HStack {
            statPill(value: "\(logs.count)", label: "Games")
            statPill(value: String(format: "%.1f", total), label: "Total Pts")
            statPill(value: String(format: "%.1f", avg), label: "Avg Pts")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func statPill(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(brandPurple)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Game List

    private func gameList(_ logs: [DFSPlayerGameLog]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                HStack {
                    Text("DATE")
                        .frame(width: 44, alignment: .leading)
                    Text("OPP")
                        .frame(width: 56, alignment: .leading)
                    Text("STATS")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("PTS")
                        .frame(width: 48, alignment: .trailing)
                }
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)

                Divider()

                ForEach(logs) { game in
                    HStack {
                        Text(game.date)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .leading)
                        Text(game.opponent)
                            .font(.caption)
                            .frame(width: 56, alignment: .leading)
                            .lineLimit(1)
                        Text(statLine(game))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(2)
                        Text(String(format: "%.1f", fantasyPoints(game)))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .frame(width: 48, alignment: .trailing)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                    Divider().padding(.leading, 16)
                }
            }
        }
    }

    // MARK: - Scoring & Stat Lines

    /// Best Ball fantasy points for a game. Football recomputes with the
    /// app's scoring model (the provider's stored value is DK-scored with
    /// yardage bonuses); other sports use the provider's value.
    private func fantasyPoints(_ g: DFSPlayerGameLog) -> Double {
        switch sport {
        case "NFL", "CFB":
            // Football field mapping in DFSPlayerGameLog:
            // points=passYds rebounds=passTD assists=INT steals=rushYds
            // blocks=rushTD turnovers=REC fgm=recYds fga=recTD threePM=fumL
            return BestBallScoringEngine.nflFantasyPoints(
                passYds: g.points, passTD: g.rebounds, interceptions: g.assists,
                rushYds: g.steals, rushTD: g.blocks,
                recYds: g.fgm, receptions: g.turnovers, recTD: g.fga,
                fumblesLost: g.threePM
            )
        default:
            return g.fantasyPoints
        }
    }

    private func statLine(_ g: DFSPlayerGameLog) -> String {
        switch sport {
        case "NFL", "CFB":
            var parts: [String] = []
            if g.points != 0 || g.rebounds != 0 || g.assists != 0 {
                var s = "\(g.points) PaYd"
                if g.rebounds > 0 { s += ", \(g.rebounds) PaTD" }
                if g.assists > 0 { s += ", \(g.assists) INT" }
                parts.append(s)
            }
            if g.steals != 0 || g.blocks != 0 {
                var s = "\(g.steals) RuYd"
                if g.blocks > 0 { s += ", \(g.blocks) RuTD" }
                parts.append(s)
            }
            if g.turnovers != 0 || g.fgm != 0 || g.fga != 0 {
                var s = "\(g.turnovers) Rec, \(g.fgm) ReYd"
                if g.fga > 0 { s += ", \(g.fga) ReTD" }
                parts.append(s)
            }
            if g.threePM > 0 { parts.append("\(g.threePM) FumL") }
            return parts.isEmpty ? "Did not record a stat" : parts.joined(separator: " · ")
        case "NBA":
            return "\(g.points) PTS · \(g.rebounds) REB · \(g.assists) AST"
        case "EPL":
            // Soccer field mapping in DFSPlayerGameLog: points=goals,
            // rebounds=SOT, assists=assists, blocks=saves,
            // turnovers=totalShots, fgm=YC, fga=RC, ftm=cleanSheet;
            // everything else lives in extraStats (TKL/INT/CRS/SA/PAS/FD/FC).
            var parts: [String] = []
            if g.points > 0 { parts.append("\(g.points) G") }
            if g.assists > 0 { parts.append("\(g.assists) A") }
            if g.rebounds > 0 { parts.append("\(g.rebounds) SOT") }
            if g.turnovers > 0 { parts.append("\(g.turnovers) SH") }
            if g.blocks > 0 { parts.append("\(g.blocks) SV") }
            let extras = g.extraStats ?? [:]
            let isKeeper = player.position == "GK" || g.blocks > 0
            // Goalkeepers: goals against right after saves, so the line reads
            // like a keeper's box score ("4 SV · 1 GA · CS · W"). The win
            // bonus only pays keepers on DK, so only their rows show W.
            if isKeeper {
                parts.append("\(extras["GA"] ?? 0) GA")
            }
            for key in ["TKL", "INT", "CRS", "SA", "PAS", "FD", "FC"] {
                if let v = extras[key], v > 0 { parts.append("\(v) \(key)") }
            }
            // Clean sheet only pays GK (+5) and DEF (+3) — don't decorate
            // mids/forwards with a stat that isn't part of their score.
            if g.ftm > 0, isKeeper || player.position == "DEF" { parts.append("CS") }
            if isKeeper, extras["W"] == 1 { parts.append("W") }
            if g.fgm > 0 { parts.append("\(g.fgm) YC") }
            if g.fga > 0 { parts.append("\(g.fga) RC") }
            return parts.isEmpty ? "No stats" : parts.joined(separator: " · ")
        default:
            return ""
        }
    }

    private func seasonLabel(_ season: Int) -> String {
        // NBA seasons span two calendar years; label as "2025-26".
        if sport == "NBA" {
            return "\(season - 1)-\(String(season).suffix(2))"
        }
        // EPL also spans two years but is keyed by its August start year.
        if sport == "EPL" {
            return "\(season)-\(String(season + 1).suffix(2))"
        }
        return "\(season)"
    }
}
