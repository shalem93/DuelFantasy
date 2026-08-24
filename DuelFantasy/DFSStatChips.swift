import SwiftUI

/// One box-score stat rendered as a "value LABEL" capsule chip.
struct DFSStatChip: Hashable {
    let value: String
    let label: String
}

/// Horizontally scrollable row of stat chips — the pretty replacement for
/// the old cramped "2-11 Rec"-style single-line stat strings. Used by the
/// live leaderboard box scores, the Your Lineup card, and Past Results
/// standings for football and soccer.
struct DFSStatChipsRow: View {
    let chips: [DFSStatChip]
    var emptyText: String = "No stats yet"

    var body: some View {
        if chips.isEmpty {
            Text(emptyText)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(chips, id: \.self) { chip in
                        HStack(spacing: 3) {
                            Text(chip.value)
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.primary)
                            Text(chip.label)
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Capsule())
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
    }
}

enum DFSStatChipBuilder {
    /// Football chips from the repurposed live-stat fields (see
    /// ESPNNFLDFSLiveScoringProvider): points=passYds, rebounds=rushYds,
    /// assists=REC, steals=passTD, blocks=rushTD, turnovers=INT+FumL,
    /// fgm/fga=comp/att, threePM=recTD, fta=recYds. DST rows (named
    /// "XXX Defense"): steals=sacks, blocks=INTs, turnovers=fumbles
    /// recovered, fgm=defTDs, fta=points allowed.
    static func football(_ stats: DFSPlayerLiveStats) -> [DFSStatChip] {
        if stats.name.hasSuffix("Defense") {
            var chips = [
                DFSStatChip(value: "\(stats.steals)", label: "SACKS"),
                DFSStatChip(value: "\(stats.blocks)", label: "INT"),
                DFSStatChip(value: "\(stats.turnovers)", label: "FUM REC"),
            ]
            if stats.fgm > 0 { chips.append(DFSStatChip(value: "\(stats.fgm)", label: "TD")) }
            chips.append(DFSStatChip(value: "\(stats.fta)", label: "PTS ALLOWED"))
            return chips
        }
        var chips: [DFSStatChip] = []
        if stats.fga > 0 || stats.points != 0 {
            chips.append(DFSStatChip(value: "\(stats.fgm)/\(stats.fga)", label: "CMP"))
            chips.append(DFSStatChip(value: "\(stats.points)", label: "PASS YDS"))
            if stats.steals > 0 { chips.append(DFSStatChip(value: "\(stats.steals)", label: "PASS TD")) }
        }
        if stats.rebounds != 0 || stats.blocks > 0 {
            chips.append(DFSStatChip(value: "\(stats.rebounds)", label: "RUSH YDS"))
            if stats.blocks > 0 { chips.append(DFSStatChip(value: "\(stats.blocks)", label: "RUSH TD")) }
        }
        if stats.assists > 0 || stats.fta != 0 || stats.threePM > 0 {
            chips.append(DFSStatChip(value: "\(stats.assists)", label: "REC"))
            chips.append(DFSStatChip(value: "\(stats.fta)", label: "REC YDS"))
            if stats.threePM > 0 { chips.append(DFSStatChip(value: "\(stats.threePM)", label: "REC TD")) }
        }
        if stats.turnovers > 0 {
            // extraStats carries the INT/FUML split; older persisted stats
            // only have the combined turnovers count — fall back to "TO".
            let extras = stats.extraStats ?? [:]
            let ints = extras["INT"] ?? 0
            let fums = extras["FUML"] ?? 0
            if ints > 0 { chips.append(DFSStatChip(value: "\(ints)", label: "INT")) }
            if fums > 0 { chips.append(DFSStatChip(value: "\(fums)", label: "FUM LOST")) }
            if ints + fums == 0 { chips.append(DFSStatChip(value: "\(stats.turnovers)", label: "TO")) }
        }
        return chips
    }

    /// Soccer chips — every nonzero DK-scored stat. Field mapping:
    /// points=G, assists=A, rebounds=SOT, turnovers=SH, blocks=SV,
    /// steals=TKL, fgm=FD, ftm=YC, fta=RC; INT/CRS/SA/PAS/FC ride in
    /// extraStats.
    static func soccer(_ stats: DFSPlayerLiveStats) -> [DFSStatChip] {
        var chips: [DFSStatChip] = []
        if stats.points > 0 { chips.append(DFSStatChip(value: "\(stats.points)", label: "GOALS")) }
        if stats.assists > 0 { chips.append(DFSStatChip(value: "\(stats.assists)", label: "AST")) }
        if stats.rebounds > 0 { chips.append(DFSStatChip(value: "\(stats.rebounds)", label: "SOT")) }
        if stats.turnovers > 0 { chips.append(DFSStatChip(value: "\(stats.turnovers)", label: "SHOTS")) }
        if stats.blocks > 0 { chips.append(DFSStatChip(value: "\(stats.blocks)", label: "SAVES")) }
        if stats.steals > 0 { chips.append(DFSStatChip(value: "\(stats.steals)", label: "TKL")) }
        let extras = stats.extraStats ?? [:]
        let extraLabels: [(key: String, label: String)] = [
            ("INT", "INT"), ("CRS", "CROSSES"), ("SA", "SHOT AST"),
            ("PAS", "PASSES"), ("FC", "FOULS"),
        ]
        for pair in extraLabels {
            if let v = extras[pair.key], v > 0 {
                chips.append(DFSStatChip(value: "\(v)", label: pair.label))
            }
        }
        if stats.fgm > 0 { chips.append(DFSStatChip(value: "\(stats.fgm)", label: "FLS DRAWN")) }
        if stats.ftm > 0 { chips.append(DFSStatChip(value: "\(stats.ftm)", label: "YC")) }
        if stats.fta > 0 { chips.append(DFSStatChip(value: "\(stats.fta)", label: "RC")) }
        return chips
    }
}
