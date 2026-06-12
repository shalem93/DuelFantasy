import SwiftUI

struct GolfPlayerDetailView: View {
    let player: DFSPlayer
    let isSelected: Bool
    let onToggle: () -> Void

    @State private var tournaments: [GolfTournamentResult] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    private var brandPurple: Color {
        Color(red: 0.48, green: 0.23, blue: 0.93)
    }

    private var averages: (made: Int, avgFinish: Double, avgScore: Double)? {
        guard !tournaments.isEmpty else { return nil }
        let finished = tournaments.filter { !$0.isCut && !$0.isWithdrawn }
        let cutsMade = finished.count

        // Average finish position (parse numeric part from "T7" → 7, "1" → 1)
        let finishNums = finished.compactMap { parseFinishPosition($0.finishPosition) }
        let avgFinish = finishNums.isEmpty ? 0 : Double(finishNums.reduce(0, +)) / Double(finishNums.count)

        // Average score to par across all tournaments
        let parScores = tournaments.compactMap { parseScoreToPar($0.scoreToPar) }
        let avgScore = parScores.isEmpty ? 0 : parScores.reduce(0.0, +) / Double(parScores.count)

        return (made: cutsMade, avgFinish: avgFinish, avgScore: avgScore)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    playerHeader
                    if let avgs = averages {
                        averagesCard(avgs)
                    }
                    tournamentHistorySection
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
            await loadTournamentHistory()
        }
    }

    // MARK: - Player Header

    private var playerHeader: some View {
        VStack(spacing: 14) {
            HStack(spacing: 16) {
                Image(systemName: "figure.golf")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(brandPurple)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(player.name)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                    Text(player.team.isEmpty ? "PGA Tour" : player.team)
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
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(isSelected ? brandPurple : Color(.systemGray5))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .clipShape(Capsule())
                }
                .fixedSize(horizontal: true, vertical: false)
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

    // MARK: - Averages

    private func averagesCard(_ avgs: (made: Int, avgFinish: Double, avgScore: Double)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Last \(tournaments.count) Tournaments")
                .font(.headline)

            HStack(spacing: 0) {
                VStack(spacing: 4) {
                    Text("CUTS MADE")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("\(avgs.made)/\(tournaments.count)")
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(.primary)
                }
                .frame(minWidth: 80)

                Spacer()

                VStack(spacing: 4) {
                    Text("AVG FINISH")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(avgs.avgFinish > 0 ? String(format: "%.0f", avgs.avgFinish) : "-")
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(.primary)
                }
                .frame(minWidth: 80)

                Spacer()

                VStack(spacing: 4) {
                    Text("AVG SCORE")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(formatAvgScore(avgs.avgScore))
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(avgs.avgScore < 0 ? brandPurple : (avgs.avgScore > 0 ? .red : .primary))
                }
                .frame(minWidth: 80)
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    // MARK: - Tournament History

    private var tournamentHistorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tournament History")
                .font(.headline)

            if isLoading {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Loading tournament history...")
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
            } else if tournaments.isEmpty {
                Text("No recent tournament data available.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                // Header row
                HStack(spacing: 0) {
                    Text("TOURNAMENT")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("POS")
                        .frame(width: 38, alignment: .trailing)
                    Text("SCR")
                        .frame(width: 38, alignment: .trailing)
                    Text("R1")
                        .frame(width: 28, alignment: .trailing)
                    Text("R2")
                        .frame(width: 28, alignment: .trailing)
                    Text("R3")
                        .frame(width: 28, alignment: .trailing)
                    Text("R4")
                        .frame(width: 28, alignment: .trailing)
                }
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)

                ForEach(tournaments) { tournament in
                    tournamentRow(tournament)
                }
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    private func tournamentRow(_ tournament: GolfTournamentResult) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Tournament name + date
                VStack(alignment: .leading, spacing: 1) {
                    Text(tournament.name)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Text(tournament.date)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Finish position
                Text(tournament.finishPosition)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(positionColor(tournament.finishPosition))
                    .frame(width: 38, alignment: .trailing)

                // Score to par
                Text(tournament.scoreToPar)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(scoreColor(tournament.scoreToPar))
                    .frame(width: 38, alignment: .trailing)

                // Round scores
                ForEach(0..<4, id: \.self) { i in
                    if i < tournament.roundScores.count && tournament.roundScores[i] > 0 {
                        Text("\(tournament.roundScores[i])")
                            .font(.caption.monospacedDigit())
                            .frame(width: 28, alignment: .trailing)
                    } else {
                        Text("-")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.quaternary)
                            .frame(width: 28, alignment: .trailing)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(rowBackground(tournament))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Data Loading

    private func loadTournamentHistory() async {
        isLoading = true
        errorMessage = nil
        let provider = GolfTournamentHistoryProvider()
        do {
            tournaments = try await provider.fetchTournamentHistory(athleteID: player.id)
            if tournaments.isEmpty {
                errorMessage = "No tournament history found for this player."
            }
        } catch {
            errorMessage = "Unable to load tournament history."
        }
        isLoading = false
    }

    // MARK: - Helpers

    private func formatted(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func positionColor(_ position: String) -> Color {
        if position == "CUT" || position == "WD" { return .red }
        guard let num = parseFinishPosition(position) else { return .primary }
        if num == 1 { return .yellow }
        if num <= 5 { return brandPurple }
        if num <= 10 { return .blue }
        return .primary
    }

    private func scoreColor(_ score: String) -> Color {
        if score.hasPrefix("-") { return brandPurple }
        if score.hasPrefix("+") { return .red }
        return .primary
    }

    private func rowBackground(_ tournament: GolfTournamentResult) -> Color {
        if tournament.isCut || tournament.isWithdrawn { return Color.red.opacity(0.04) }
        if let num = parseFinishPosition(tournament.finishPosition), num <= 10 {
            return brandPurple.opacity(0.06)
        }
        return Color.clear
    }

    private func parseFinishPosition(_ pos: String) -> Int? {
        // Handle "T7" → 7, "1" → 1, "CUT" → nil, "WD" → nil
        let cleaned = pos.replacingOccurrences(of: "T", with: "")
        return Int(cleaned)
    }

    private func parseScoreToPar(_ score: String) -> Double? {
        if score == "E" { return 0 }
        return Double(score)
    }

    private func formatAvgScore(_ avg: Double) -> String {
        if abs(avg) < 0.05 { return "E" }
        if avg > 0 { return String(format: "+%.1f", avg) }
        return String(format: "%.1f", avg)
    }
}
