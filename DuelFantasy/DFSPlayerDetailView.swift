import SwiftUI

struct DFSPlayerDetailView: View {
    let player: DFSPlayer
    let isSelected: Bool
    let onToggle: () -> Void

    @State private var gameLogs: [DFSPlayerGameLog] = []
    @State private var newsItems: [ESPNPlayerNews] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    private var brandPurple: Color {
        Color(red: 0.48, green: 0.23, blue: 0.93)
    }

    private var isMLB: Bool { player.id.hasPrefix("mlb-") }
    private var isMLBPitcher: Bool {
        isMLB && ["SP", "RP", "P"].contains(player.position.uppercased())
    }

    private var isNHL: Bool { player.id.hasPrefix("nhl-") }
    private var isNHLGoalie: Bool {
        isNHL && player.position.uppercased() == "G"
    }

    private var isUFC: Bool { player.id.hasPrefix("ufc-") }

    private var isSoccer: Bool { player.id.hasPrefix("epl-") || player.id.hasPrefix("ucl-") || player.id.hasPrefix("wc-") }
    private var isSoccerGK: Bool {
        isSoccer && player.position.uppercased() == "GK"
    }

    private var averages: (pts: Double, reb: Double, ast: Double, fpts: Double)? {
        guard !gameLogs.isEmpty else { return nil }
        let count = Double(gameLogs.count)
        return (
            pts: gameLogs.reduce(0.0) { $0 + Double($1.points) } / count,
            reb: gameLogs.reduce(0.0) { $0 + Double($1.rebounds) } / count,
            ast: gameLogs.reduce(0.0) { $0 + Double($1.assists) } / count,
            fpts: gameLogs.reduce(0.0) { $0 + $1.fantasyPoints } / count
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    playerHeader
                    if !newsItems.isEmpty {
                        newsSection
                    }
                    if isSoccer {
                        if let avgs = averages {
                            soccerAveragesCard(avgs)
                        }
                        soccerGameLogSection
                    } else if isNHL {
                        if let avgs = averages {
                            nhlAveragesCard(avgs)
                        }
                        nhlGameLogSection
                    } else if isMLB {
                        if let avgs = averages {
                            mlbAveragesCard(avgs)
                        }
                        mlbGameLogSection
                    } else if isUFC {
                        if let avgs = averages {
                            ufcAveragesCard(avgs)
                        }
                        ufcGameLogSection
                    } else {
                        if let avgs = averages {
                            averagesCard(avgs)
                        }
                        gameLogSection
                    }
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
            .navigationTitle(player.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            await loadGameLogs()
        }
    }

    // MARK: - Player Header

    private var playerHeader: some View {
        VStack(spacing: 14) {
            HStack(spacing: 16) {
                // Position badge
                Text(player.position)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(brandPurple)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(player.name)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                        if let status = player.injuryStatus {
                            Text(status)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(injuryColor(for: status))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    Text("\(player.team) • \(player.position)")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
            }

            HStack(spacing: 20) {
                VStack(spacing: 2) {
                    Text("SALARY")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("$\(formatted(player.salary))")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.white)
                }
                VStack(spacing: 2) {
                    Text("PROJ")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    Text(String(format: "%.1f", player.projectedPoints))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(brandPurple)
                }
                Spacer()

                Button {
                    Haptics.medium()
                    onToggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "plus.circle")
                        Text(isSelected ? "Selected" : "Add")
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(isSelected ? brandPurple : Color(.systemGray5))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .clipShape(Capsule())
                }
            }
        }
        .padding(20)
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

    // MARK: - News

    private var newsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "newspaper")
                    .foregroundStyle(brandPurple)
                Text("Recent News")
                    .font(.headline)
            }

            ForEach(newsItems) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.headline)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    if let desc = item.description {
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if !item.published.isEmpty {
                        Text(item.published)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
                if item.id != newsItems.last?.id {
                    Divider()
                }
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    // MARK: - Averages

    private func averagesCard(_ avgs: (pts: Double, reb: Double, ast: Double, fpts: Double)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Last \(gameLogs.count) Games Avg")
                .font(.headline)

            HStack(spacing: 0) {
                avgStat(label: "PTS", value: String(format: "%.1f", avgs.pts))
                Spacer()
                avgStat(label: "REB", value: String(format: "%.1f", avgs.reb))
                Spacer()
                avgStat(label: "AST", value: String(format: "%.1f", avgs.ast))
                Spacer()
                avgStat(label: "FPTS", value: String(format: "%.1f", avgs.fpts), highlight: true)
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    private func avgStat(label: String, value: String, highlight: Bool = false) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(highlight ? brandPurple : .primary)
        }
        .frame(minWidth: 60)
    }

    // MARK: - Game Log

    private var gameLogSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Game Log")
                .font(.headline)

            if isLoading {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Loading stats...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 20)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else if gameLogs.isEmpty {
                Text("No recent game data available.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                // Header
                HStack(spacing: 0) {
                    Text("DATE")
                        .frame(width: 44, alignment: .leading)
                    Text("OPP")
                        .frame(width: 56, alignment: .leading)
                    Text("MIN")
                        .frame(width: 36, alignment: .trailing)
                    Text("PTS")
                        .frame(width: 32, alignment: .trailing)
                    Text("REB")
                        .frame(width: 32, alignment: .trailing)
                    Text("AST")
                        .frame(width: 32, alignment: .trailing)
                    Text("STL")
                        .frame(width: 28, alignment: .trailing)
                    Text("BLK")
                        .frame(width: 28, alignment: .trailing)
                    Spacer()
                    Text("FPTS")
                        .frame(width: 44, alignment: .trailing)
                }
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)

                ForEach(gameLogs) { log in
                    gameLogRow(log)
                }
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    private func gameLogRow(_ log: DFSPlayerGameLog) -> some View {
        HStack(spacing: 0) {
            Text(log.date)
                .frame(width: 44, alignment: .leading)
            Text(log.opponent)
                .frame(width: 56, alignment: .leading)
                .lineLimit(1)
            Text(log.minutes)
                .frame(width: 36, alignment: .trailing)
            Text("\(log.points)")
                .frame(width: 32, alignment: .trailing)
                .fontWeight(log.points >= 25 ? .bold : .regular)
            Text("\(log.rebounds)")
                .frame(width: 32, alignment: .trailing)
            Text("\(log.assists)")
                .frame(width: 32, alignment: .trailing)
            Text("\(log.steals)")
                .frame(width: 28, alignment: .trailing)
            Text("\(log.blocks)")
                .frame(width: 28, alignment: .trailing)
            Spacer()
            Text(String(format: "%.1f", log.fantasyPoints))
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(log.fantasyPoints >= 35 ? brandPurple : .primary)
                .fontWeight(log.fantasyPoints >= 35 ? .semibold : .regular)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(log.fantasyPoints >= 40 ? brandPurple.opacity(0.06) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - MLB Averages

    private func mlbAveragesCard(_ avgs: (pts: Double, reb: Double, ast: Double, fpts: Double)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Last \(gameLogs.count) Games Avg")
                .font(.headline)

            if isMLBPitcher {
                // Pitcher: IP avg, K avg, ER avg, FPTS avg
                let avgIP = gameLogs.reduce(0.0) { total, log in
                    let parts = log.minutes.split(separator: ".")
                    let full = Double(parts.first ?? "0") ?? 0
                    let partial = parts.count > 1 ? (Double(parts[1]) ?? 0) / 3.0 : 0
                    return total + full + partial
                } / Double(gameLogs.count)
                HStack(spacing: 0) {
                    avgStat(label: "IP", value: String(format: "%.1f", avgIP))
                    Spacer()
                    avgStat(label: "K", value: String(format: "%.1f", avgs.pts))
                    Spacer()
                    avgStat(label: "ER", value: String(format: "%.1f", avgs.reb))
                    Spacer()
                    avgStat(label: "FPTS", value: String(format: "%.1f", avgs.fpts), highlight: true)
                }
            } else {
                // Batter: AVG, HR avg, RBI avg, FPTS avg
                let totalH = gameLogs.reduce(0) { $0 + $1.points }
                let totalAB = gameLogs.reduce(0) { $0 + (Int($1.minutes) ?? 0) }
                let avg = totalAB > 0 ? Double(totalH) / Double(totalAB) : 0
                HStack(spacing: 0) {
                    avgStat(label: "AVG", value: String(format: ".%03d", Int(avg * 1000)))
                    Spacer()
                    avgStat(label: "HR", value: String(format: "%.1f", avgs.reb))
                    Spacer()
                    avgStat(label: "RBI", value: String(format: "%.1f", avgs.ast))
                    Spacer()
                    avgStat(label: "FPTS", value: String(format: "%.1f", avgs.fpts), highlight: true)
                }
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    // MARK: - NHL Averages

    private func nhlAveragesCard(_ avgs: (pts: Double, reb: Double, ast: Double, fpts: Double)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Last \(gameLogs.count) Games Avg")
                .font(.headline)

            if isNHLGoalie {
                // Goalie averages: SV* (estimated ~30-GA), GA, W count, SO count, FPTS
                HStack(spacing: 0) {
                    avgStat(label: "SV*", value: String(format: "%.0f", avgs.pts))
                    Spacer()
                    avgStat(label: "GA", value: String(format: "%.1f", avgs.reb))
                    Spacer()
                    avgStat(label: "W", value: "\(gameLogs.filter { $0.assists > 0 }.count)")
                    Spacer()
                    avgStat(label: "SO", value: "\(gameLogs.filter { $0.steals > 0 }.count)")
                    Spacer()
                    avgStat(label: "FPTS", value: String(format: "%.1f", avgs.fpts), highlight: true)
                }
            } else {
                // Skater: G avg, A avg, PTS avg, S avg, FPTS avg
                HStack(spacing: 0) {
                    avgStat(label: "G", value: String(format: "%.1f", avgs.pts))
                    Spacer()
                    avgStat(label: "A", value: String(format: "%.1f", avgs.reb))
                    Spacer()
                    avgStat(label: "PTS", value: String(format: "%.1f", avgs.pts + avgs.reb))
                    Spacer()
                    avgStat(label: "S", value: String(format: "%.1f", avgs.ast))
                    Spacer()
                    avgStat(label: "FPTS", value: String(format: "%.1f", avgs.fpts), highlight: true)
                }
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    // MARK: - MLB Game Log

    private var mlbGameLogSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Game Log")
                .font(.headline)

            if isLoading {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Loading stats...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 20)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else if gameLogs.isEmpty {
                Text("No recent game data available.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                if isMLBPitcher {
                    mlbPitcherGameLogContent
                } else {
                    mlbBatterGameLogContent
                }
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    private var mlbBatterGameLogContent: some View {
        VStack(spacing: 0) {
            // Header: DATE, OPP, AB, H, HR, RBI, R, BB, FPTS
            HStack(spacing: 0) {
                Text("DATE")
                    .frame(width: 38, alignment: .leading)
                Text("OPP")
                    .frame(width: 52, alignment: .leading)
                Text("AB")
                    .frame(width: 26, alignment: .trailing)
                Text("H")
                    .frame(width: 24, alignment: .trailing)
                Text("HR")
                    .frame(width: 26, alignment: .trailing)
                Text("RBI")
                    .frame(width: 28, alignment: .trailing)
                Text("R")
                    .frame(width: 22, alignment: .trailing)
                Text("BB")
                    .frame(width: 26, alignment: .trailing)
                Text("SB")
                    .frame(width: 24, alignment: .trailing)
                Spacer()
                Text("FPTS")
                    .frame(width: 42, alignment: .trailing)
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)

            ForEach(gameLogs) { log in
                mlbBatterRow(log)
            }
        }
    }

    private func mlbBatterRow(_ log: DFSPlayerGameLog) -> some View {
        // minutes=AB, points=H, rebounds=HR, assists=RBI, steals=R, blocks=BB, fgm=SB
        HStack(spacing: 0) {
            Text(log.date)
                .frame(width: 38, alignment: .leading)
            Text(log.opponent)
                .frame(width: 52, alignment: .leading)
                .lineLimit(1)
            Text(log.minutes)
                .frame(width: 26, alignment: .trailing)
            Text("\(log.points)")
                .frame(width: 24, alignment: .trailing)
            Text("\(log.rebounds)")
                .frame(width: 26, alignment: .trailing)
                .fontWeight(log.rebounds > 0 ? .bold : .regular)
                .foregroundStyle(log.rebounds > 0 ? brandPurple : .primary)
            Text("\(log.assists)")
                .frame(width: 28, alignment: .trailing)
            Text("\(log.steals)")
                .frame(width: 22, alignment: .trailing)
            Text("\(log.blocks)")
                .frame(width: 26, alignment: .trailing)
            Text("\(log.fgm)")
                .frame(width: 24, alignment: .trailing)
            Spacer()
            Text(String(format: "%.1f", log.fantasyPoints))
                .frame(width: 42, alignment: .trailing)
                .foregroundStyle(log.fantasyPoints >= 20 ? brandPurple : .primary)
                .fontWeight(log.fantasyPoints >= 20 ? .semibold : .regular)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(log.fantasyPoints >= 25 ? brandPurple.opacity(0.06) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var mlbPitcherGameLogContent: some View {
        VStack(spacing: 0) {
            // Header: DATE, OPP, IP, K, ER, H, BB, DEC, FPTS
            HStack(spacing: 0) {
                Text("DATE")
                    .frame(width: 38, alignment: .leading)
                Text("OPP")
                    .frame(width: 52, alignment: .leading)
                Text("IP")
                    .frame(width: 28, alignment: .trailing)
                Text("K")
                    .frame(width: 24, alignment: .trailing)
                Text("ER")
                    .frame(width: 26, alignment: .trailing)
                Text("H")
                    .frame(width: 24, alignment: .trailing)
                Text("BB")
                    .frame(width: 26, alignment: .trailing)
                Text("DEC")
                    .frame(width: 28, alignment: .trailing)
                Spacer()
                Text("FPTS")
                    .frame(width: 42, alignment: .trailing)
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)

            ForEach(gameLogs) { log in
                mlbPitcherRow(log)
            }
        }
    }

    private func mlbPitcherRow(_ log: DFSPlayerGameLog) -> some View {
        // minutes=IP, points=K, rebounds=ER, assists=W/L decision (1=W,-1=L,0=-),
        // steals=H, blocks=BB, turnovers=HR allowed
        let dec = log.assists == 1 ? "W" : (log.assists == -1 ? "L" : "-")
        return HStack(spacing: 0) {
            Text(log.date)
                .frame(width: 38, alignment: .leading)
            Text(log.opponent)
                .frame(width: 52, alignment: .leading)
                .lineLimit(1)
            Text(log.minutes)
                .frame(width: 28, alignment: .trailing)
            Text("\(log.points)")
                .frame(width: 24, alignment: .trailing)
                .fontWeight(log.points >= 8 ? .bold : .regular)
            Text("\(log.rebounds)")
                .frame(width: 26, alignment: .trailing)
                .foregroundStyle(log.rebounds >= 4 ? .red : .primary)
            Text("\(log.steals)")
                .frame(width: 24, alignment: .trailing)
            Text("\(log.blocks)")
                .frame(width: 26, alignment: .trailing)
            Text(dec)
                .frame(width: 28, alignment: .trailing)
                .foregroundStyle(dec == "W" ? brandPurple : (dec == "L" ? .red : .secondary))
                .fontWeight(dec != "-" ? .semibold : .regular)
            Spacer()
            Text(String(format: "%.1f", log.fantasyPoints))
                .frame(width: 42, alignment: .trailing)
                .foregroundStyle(log.fantasyPoints >= 25 ? brandPurple : .primary)
                .fontWeight(log.fantasyPoints >= 25 ? .semibold : .regular)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(log.fantasyPoints >= 30 ? brandPurple.opacity(0.06) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - NHL Game Log

    private var nhlGameLogSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Game Log")
                .font(.headline)

            if isLoading {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Loading stats...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 20)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else if gameLogs.isEmpty {
                Text("No recent game data available.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                if isNHLGoalie {
                    nhlGoalieGameLogContent
                } else {
                    nhlSkaterGameLogContent
                }
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    private var nhlSkaterGameLogContent: some View {
        VStack(spacing: 0) {
            // Header: DATE, OPP, G, A, PTS, S, FPTS
            HStack(spacing: 0) {
                Text("DATE")
                    .frame(width: 38, alignment: .leading)
                Text("OPP")
                    .frame(width: 52, alignment: .leading)
                Text("G")
                    .frame(width: 26, alignment: .trailing)
                Text("A")
                    .frame(width: 26, alignment: .trailing)
                Text("PTS")
                    .frame(width: 30, alignment: .trailing)
                Text("S")
                    .frame(width: 28, alignment: .trailing)
                Spacer()
                Text("FPTS")
                    .frame(width: 42, alignment: .trailing)
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)

            ForEach(gameLogs) { log in
                nhlSkaterRow(log)
            }
        }
    }

    private func nhlSkaterRow(_ log: DFSPlayerGameLog) -> some View {
        // points=Goals, rebounds=Assists, assists=Shots
        let pts = log.points + log.rebounds // G + A = PTS
        return HStack(spacing: 0) {
            Text(log.date)
                .frame(width: 38, alignment: .leading)
            Text(log.opponent)
                .frame(width: 52, alignment: .leading)
                .lineLimit(1)
            Text("\(log.points)")
                .frame(width: 26, alignment: .trailing)
                .fontWeight(log.points > 0 ? .bold : .regular)
                .foregroundStyle(log.points > 0 ? brandPurple : .primary)
            Text("\(log.rebounds)")
                .frame(width: 26, alignment: .trailing)
                .fontWeight(log.rebounds > 0 ? .bold : .regular)
            Text("\(pts)")
                .frame(width: 30, alignment: .trailing)
                .fontWeight(pts > 0 ? .semibold : .regular)
            Text("\(log.assists)")
                .frame(width: 28, alignment: .trailing)
            Spacer()
            Text(String(format: "%.1f", log.fantasyPoints))
                .frame(width: 42, alignment: .trailing)
                .foregroundStyle(log.fantasyPoints >= 20 ? brandPurple : .primary)
                .fontWeight(log.fantasyPoints >= 20 ? .semibold : .regular)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(log.fantasyPoints >= 25 ? brandPurple.opacity(0.06) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var nhlGoalieGameLogContent: some View {
        VStack(spacing: 0) {
            // Header: DATE, OPP, SCORE, SV, GA, W/L, FPTS
            HStack(spacing: 0) {
                Text("DATE")
                    .frame(width: 34, alignment: .leading)
                Text("OPP")
                    .frame(width: 44, alignment: .leading)
                Text("SCORE")
                    .frame(width: 50, alignment: .trailing)
                    .lineLimit(1)
                Text("SV")
                    .frame(width: 24, alignment: .trailing)
                Text("GA")
                    .frame(width: 22, alignment: .trailing)
                Text("W/L")
                    .frame(width: 26, alignment: .trailing)
                Spacer()
                Text("FPTS")
                    .frame(width: 42, alignment: .trailing)
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)

            ForEach(gameLogs) { log in
                nhlGoalieRow(log)
            }
        }
    }

    private func nhlGoalieRow(_ log: DFSPlayerGameLog) -> some View {
        // points=Saves, minutes=score, rebounds=Goals Against, assists=Win(1/0), steals=Shutout(1/0), turnovers=Loss(1/0)
        let result = log.assists > 0 ? "W" : (log.turnovers > 0 ? "L" : "-")
        let score = log.minutes.isEmpty ? "-" : log.minutes
        return HStack(spacing: 0) {
            Text(log.date)
                .frame(width: 34, alignment: .leading)
            Text(log.opponent)
                .frame(width: 44, alignment: .leading)
                .lineLimit(1)
            Text(score)
                .frame(width: 50, alignment: .trailing)
                .lineLimit(1)
                .fontWeight(.medium)
            Text("\(log.points)")
                .frame(width: 24, alignment: .trailing)
            Text("\(log.rebounds)")
                .frame(width: 22, alignment: .trailing)
                .foregroundStyle(log.rebounds >= 4 ? .red : .primary)
            Text(result)
                .frame(width: 26, alignment: .trailing)
                .foregroundStyle(result == "W" ? brandPurple : (result == "L" ? .red : .secondary))
                .fontWeight(result != "-" ? .semibold : .regular)
            Spacer()
            Text(String(format: "%.1f", log.fantasyPoints))
                .frame(width: 42, alignment: .trailing)
                .foregroundStyle(log.fantasyPoints >= 25 ? brandPurple : .primary)
                .fontWeight(log.fantasyPoints >= 25 ? .semibold : .regular)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(log.fantasyPoints >= 30 ? brandPurple.opacity(0.06) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Soccer Averages

    private func soccerAveragesCard(_ avgs: (pts: Double, reb: Double, ast: Double, fpts: Double)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Last \(gameLogs.count) Games Avg")
                .font(.headline)

            if isSoccerGK {
                // GK: SV avg, GA avg (from turnovers-goals), CS count, FPTS
                let avgSaves = gameLogs.reduce(0.0) { $0 + Double($1.blocks) } / Double(gameLogs.count)
                let csCount = gameLogs.filter { $0.ftm > 0 }.count
                HStack(spacing: 0) {
                    avgStat(label: "SV", value: String(format: "%.1f", avgSaves))
                    Spacer()
                    avgStat(label: "G", value: String(format: "%.1f", avgs.pts))
                    Spacer()
                    avgStat(label: "CS", value: "\(csCount)")
                    Spacer()
                    avgStat(label: "FPTS", value: String(format: "%.1f", avgs.fpts), highlight: true)
                }
            } else {
                // Outfield: G avg, A avg, SOT avg, FD avg, FPTS avg
                HStack(spacing: 0) {
                    avgStat(label: "G", value: String(format: "%.1f", avgs.pts))
                    Spacer()
                    avgStat(label: "A", value: String(format: "%.1f", avgs.ast))
                    Spacer()
                    avgStat(label: "SOT", value: String(format: "%.1f", avgs.reb))
                    Spacer()
                    avgStat(label: "FD", value: String(format: "%.1f", gameLogs.reduce(0.0) { $0 + Double($1.steals) } / Double(gameLogs.count)))
                    Spacer()
                    avgStat(label: "FPTS", value: String(format: "%.1f", avgs.fpts), highlight: true)
                }
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    // MARK: - Soccer Game Log

    private var soccerGameLogSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Game Log")
                .font(.headline)

            if isLoading {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Loading stats...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 20)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else if gameLogs.isEmpty {
                Text("No recent game data available.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                if isSoccerGK {
                    soccerGKGameLogContent
                } else {
                    soccerOutfieldGameLogContent
                }
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    private var soccerOutfieldGameLogContent: some View {
        VStack(spacing: 0) {
            // Header: DATE, OPP, MIN, G, A, SOT, TK, DEF, YC, FPTS
            // TK = tackles, DEF = total defensive actions (tackles + interceptions
            // + blocked shots + clearances). Replaces the SH column — total shots
            // duplicate the SOT signal and didn't help judge defenders.
            HStack(spacing: 0) {
                Text("DATE")
                    .frame(width: 38, alignment: .leading)
                Text("OPP")
                    .frame(width: 52, alignment: .leading)
                Text("MIN")
                    .frame(width: 30, alignment: .trailing)
                Text("G")
                    .frame(width: 22, alignment: .trailing)
                Text("A")
                    .frame(width: 22, alignment: .trailing)
                Text("SOT")
                    .frame(width: 30, alignment: .trailing)
                Text("TK")
                    .frame(width: 24, alignment: .trailing)
                Text("DEF")
                    .frame(width: 28, alignment: .trailing)
                Text("YC")
                    .frame(width: 22, alignment: .trailing)
                Spacer()
                Text("FPTS")
                    .frame(width: 42, alignment: .trailing)
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)

            ForEach(gameLogs) { log in
                soccerOutfieldRow(log)
            }
        }
    }

    private func soccerOutfieldRow(_ log: DFSPlayerGameLog) -> some View {
        // points=Goals, rebounds=SOT, assists=Assists, threePM=tackles,
        // threePA=defensive actions sum, fgm=YC, fga=RC
        HStack(spacing: 0) {
            Text(log.date)
                .frame(width: 38, alignment: .leading)
            Text(log.opponent)
                .frame(width: 52, alignment: .leading)
                .lineLimit(1)
            Text(log.minutes)
                .frame(width: 30, alignment: .trailing)
            Text("\(log.points)")
                .frame(width: 22, alignment: .trailing)
                .fontWeight(log.points > 0 ? .bold : .regular)
                .foregroundStyle(log.points > 0 ? brandPurple : .primary)
            Text("\(log.assists)")
                .frame(width: 22, alignment: .trailing)
                .fontWeight(log.assists > 0 ? .bold : .regular)
                .foregroundStyle(log.assists > 0 ? brandPurple : .primary)
            Text("\(log.rebounds)")
                .frame(width: 30, alignment: .trailing)
            Text("\(log.threePM)")
                .frame(width: 24, alignment: .trailing)
                .fontWeight(log.threePM >= 3 ? .bold : .regular)
                .foregroundStyle(log.threePM >= 3 ? brandPurple : .primary)
            Text("\(log.threePA)")
                .frame(width: 28, alignment: .trailing)
                .fontWeight(log.threePA >= 6 ? .bold : .regular)
                .foregroundStyle(log.threePA >= 6 ? brandPurple : .primary)
            Text("\(log.fgm)")
                .frame(width: 22, alignment: .trailing)
                .foregroundStyle(log.fgm > 0 ? .yellow : .primary)
            Spacer()
            Text(String(format: "%.1f", log.fantasyPoints))
                .frame(width: 42, alignment: .trailing)
                .foregroundStyle(log.fantasyPoints >= 15 ? brandPurple : .primary)
                .fontWeight(log.fantasyPoints >= 15 ? .semibold : .regular)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(log.fantasyPoints >= 20 ? brandPurple.opacity(0.06) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var soccerGKGameLogContent: some View {
        VStack(spacing: 0) {
            // Header: DATE, OPP, MIN, SV, GA, CS, YC, FPTS
            HStack(spacing: 0) {
                Text("DATE")
                    .frame(width: 38, alignment: .leading)
                Text("OPP")
                    .frame(width: 52, alignment: .leading)
                Text("MIN")
                    .frame(width: 30, alignment: .trailing)
                Text("SV")
                    .frame(width: 26, alignment: .trailing)
                Text("G")
                    .frame(width: 22, alignment: .trailing)
                Text("A")
                    .frame(width: 22, alignment: .trailing)
                Text("CS")
                    .frame(width: 24, alignment: .trailing)
                Spacer()
                Text("FPTS")
                    .frame(width: 42, alignment: .trailing)
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)

            ForEach(gameLogs) { log in
                soccerGKRow(log)
            }
        }
    }

    private func soccerGKRow(_ log: DFSPlayerGameLog) -> some View {
        // blocks=Saves, points=Goals, assists=Assists, ftm=CleanSheet
        let cs = log.ftm > 0
        return HStack(spacing: 0) {
            Text(log.date)
                .frame(width: 38, alignment: .leading)
            Text(log.opponent)
                .frame(width: 52, alignment: .leading)
                .lineLimit(1)
            Text(log.minutes)
                .frame(width: 30, alignment: .trailing)
            Text("\(log.blocks)")
                .frame(width: 26, alignment: .trailing)
            Text("\(log.points)")
                .frame(width: 22, alignment: .trailing)
                .fontWeight(log.points > 0 ? .bold : .regular)
                .foregroundStyle(log.points > 0 ? brandPurple : .primary)
            Text("\(log.assists)")
                .frame(width: 22, alignment: .trailing)
                .fontWeight(log.assists > 0 ? .bold : .regular)
            Text(cs ? "✓" : "-")
                .frame(width: 24, alignment: .trailing)
                .foregroundStyle(cs ? brandPurple : .secondary)
                .fontWeight(cs ? .bold : .regular)
            Spacer()
            Text(String(format: "%.1f", log.fantasyPoints))
                .frame(width: 42, alignment: .trailing)
                .foregroundStyle(log.fantasyPoints >= 15 ? brandPurple : .primary)
                .fontWeight(log.fantasyPoints >= 15 ? .semibold : .regular)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(log.fantasyPoints >= 20 ? brandPurple.opacity(0.06) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - UFC Averages

    private func ufcAveragesCard(_ avgs: (pts: Double, reb: Double, ast: Double, fpts: Double)) -> some View {
        // pts=SigStrikes, reb=Takedowns, ast=Knockdowns
        VStack(alignment: .leading, spacing: 10) {
            Text("Last \(gameLogs.count) Fights Avg")
                .font(.headline)

            HStack(spacing: 0) {
                avgStat(label: "SIG STR", value: String(format: "%.1f", avgs.pts))
                Spacer()
                avgStat(label: "TD", value: String(format: "%.1f", avgs.reb))
                Spacer()
                avgStat(label: "KD", value: String(format: "%.1f", avgs.ast))
                Spacer()
                avgStat(label: "FPTS", value: String(format: "%.1f", avgs.fpts), highlight: true)
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    // MARK: - UFC Game Log

    private var ufcGameLogSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Fight Log")
                .font(.headline)

            if isLoading {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Loading stats...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 20)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else if gameLogs.isEmpty {
                Text("No recent fight data available.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                // Header: DATE, OPP, RD, SIG, TD, KD, SUB, FPTS
                HStack(spacing: 0) {
                    Text("DATE")
                        .frame(width: 44, alignment: .leading)
                    Text("OPP")
                        .frame(width: 56, alignment: .leading)
                    Text("RD")
                        .frame(width: 24, alignment: .trailing)
                    Text("SIG")
                        .frame(width: 32, alignment: .trailing)
                    Text("TD")
                        .frame(width: 28, alignment: .trailing)
                    Text("KD")
                        .frame(width: 28, alignment: .trailing)
                    Text("SUB")
                        .frame(width: 28, alignment: .trailing)
                    Spacer()
                    Text("FPTS")
                        .frame(width: 44, alignment: .trailing)
                }
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)

                ForEach(gameLogs) { log in
                    ufcGameLogRow(log)
                }
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    private func ufcGameLogRow(_ log: DFSPlayerGameLog) -> some View {
        // points=SigStrikes, rebounds=Takedowns, assists=Knockdowns,
        // steals=SubAttempts, minutes=Round, ftm=win flag
        let isWin = log.ftm > 0
        return HStack(spacing: 0) {
            Text(log.date)
                .frame(width: 38, alignment: .leading)
            HStack(spacing: 2) {
                Text(isWin ? "W" : "L")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(isWin ? .green : .red)
                Text(log.opponent)
                    .lineLimit(1)
            }
            .frame(width: 62, alignment: .leading)
            Text("R\(log.minutes)")
                .frame(width: 24, alignment: .trailing)
            Text("\(log.points)")
                .frame(width: 32, alignment: .trailing)
                .fontWeight(log.points >= 50 ? .bold : .regular)
            Text("\(log.rebounds)")
                .frame(width: 28, alignment: .trailing)
            Text("\(log.assists)")
                .frame(width: 28, alignment: .trailing)
                .fontWeight(log.assists > 0 ? .bold : .regular)
                .foregroundStyle(log.assists > 0 ? brandPurple : .primary)
            Text("\(log.steals)")
                .frame(width: 28, alignment: .trailing)
            Spacer()
            Text(String(format: "%.1f", log.fantasyPoints))
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(log.fantasyPoints >= 60 ? brandPurple : .primary)
                .fontWeight(log.fantasyPoints >= 60 ? .semibold : .regular)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(log.fantasyPoints >= 80 ? brandPurple.opacity(0.06) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Data Loading

    private func loadGameLogs() async {
        isLoading = true
        errorMessage = nil
        let provider = ESPNPlayerGameLogProvider()
        do {
            gameLogs = try await provider.fetchGameLog(playerID: player.id, position: player.position)
            if gameLogs.isEmpty {
                errorMessage = "No game log data found for this player."
            }
        } catch {
            errorMessage = "Unable to load game stats."
        }
        // Fetch news filtered to articles mentioning this player
        if let news = try? await provider.fetchNews(playerID: player.id, playerName: player.name) {
            newsItems = news
        }
        isLoading = false
    }

    private func formatted(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
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
