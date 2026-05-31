import SwiftUI

struct TennisBracketGroupDetailView: View {
    @Bindable var viewModel: TennisBracketViewModel
    let group: TennisBracketGroup
    @State private var showDeleteConfirmation = false
    @State private var showLeaveConfirmation = false
    @State private var selectedEntry: TennisBracketLeaderboardEntry?
    @Environment(\.dismiss) private var dismiss

    private var brandPurple: Color {
        Color(red: 0.48, green: 0.23, blue: 0.93)
    }

    private var isOwner: Bool {
        viewModel.userID == group.createdBy
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                groupHeader
                inviteCodeCard
                membersSection
                groupStandings
                actionButtons
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.94, green: 0.97, blue: 0.94),
                    Color(red: 0.96, green: 0.97, blue: 1.00)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadGroupDetail(group: group)
        }
        .confirmationDialog("Delete Group?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                Task {
                    await viewModel.deleteGroup(group)
                    dismiss()
                }
            }
        } message: {
            Text("This will permanently delete the group for all members.")
        }
        .confirmationDialog("Leave Group?", isPresented: $showLeaveConfirmation) {
            Button("Leave", role: .destructive) {
                Task {
                    await viewModel.leaveGroup(group)
                    dismiss()
                }
            }
        } message: {
            Text("You can rejoin later with the invite code.")
        }
        .sheet(item: $selectedEntry) { entry in
            entryDetailSheet(entry)
        }
    }

    // MARK: - Group Header

    private var groupHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "person.3.fill")
                    .font(.title2)
                    .foregroundStyle(brandPurple)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(.title3.weight(.bold))
                    Text("\(viewModel.currentGroupMembers.count) member\(viewModel.currentGroupMembers.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let tournament = viewModel.tournament {
                Text(tournament.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Invite Code Card

    private var inviteCodeCard: some View {
        VStack(spacing: 8) {
            Text("Invite Code")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            HStack {
                Text(group.inviteCode)
                    .font(.title2.weight(.bold).monospaced())
                    .tracking(4)
                Spacer()
                Button {
                    UIPasteboard.general.string = group.inviteCode
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.body)
                        .foregroundStyle(brandPurple)
                }
            }

            Text("Share this code with friends to join your group")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Members Section

    private var membersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Members")
                .font(.headline.weight(.bold))

            ForEach(viewModel.currentGroupMembers) { member in
                HStack {
                    Image(systemName: "person.circle.fill")
                        .foregroundStyle(.secondary)
                    Text(member.displayName)
                        .font(.subheadline)
                    Spacer()
                    if member.userID == group.createdBy {
                        Text("Owner")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(brandPurple.opacity(0.1))
                            .foregroundStyle(brandPurple)
                            .clipShape(Capsule())
                    }
                    if member.userID == viewModel.userID {
                        Text("You")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.blue.opacity(0.1))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Group Standings

    private var groupStandings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Group Standings")
                .font(.headline.weight(.bold))

            if viewModel.groupLeaderboard.isEmpty {
                Text("Standings will appear after the tournament locks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // Header
                HStack {
                    Text("#")
                        .frame(width: 30, alignment: .leading)
                    Text("Entry")
                    Spacer()
                    Text("Pts")
                        .frame(width: 50, alignment: .trailing)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

                ForEach(viewModel.groupLeaderboard) { entry in
                    Button {
                        selectedEntry = entry
                    } label: {
                        HStack {
                            Text("\(entry.rank)")
                                .font(.caption.weight(.bold))
                                .frame(width: 30, alignment: .leading)
                            Text(entry.entryName)
                                .font(.subheadline.weight(entry.isCurrentUser ? .bold : .regular))
                                .foregroundStyle(entry.isCurrentUser ? brandPurple : .primary)
                                .lineLimit(1)
                            Spacer()
                            Text(String(format: "%.0f", entry.totalPoints))
                                .font(.subheadline.weight(.semibold))
                                .frame(width: 50, alignment: .trailing)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                        .background(entry.isCurrentUser ? brandPurple.opacity(0.06) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Actions

    private var actionButtons: some View {
        VStack(spacing: 10) {
            NavigationLink {
                ChatRoomView(leagueId: "group-tennis_bracket-\(group.id.uuidString)", title: "\(group.name) Chat")
            } label: {
                Label("Group Chat", systemImage: "bubble.left.and.bubble.right.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.mint)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.mint.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            if isOwner {
                Button {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete Group", systemImage: "trash")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.red.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            } else {
                Button {
                    showLeaveConfirmation = true
                } label: {
                    Label("Leave Group", systemImage: "arrow.right.circle")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.red.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    // MARK: - Entry Detail Sheet

    private func entryDetailSheet(_ entry: TennisBracketLeaderboardEntry) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(entry.entryName)
                            .font(.title3.weight(.bold))
                        Spacer()
                        Text("Rank #\(entry.rank)")
                            .font(.headline)
                            .foregroundStyle(brandPurple)
                    }

                    Text(String(format: "%.0f pts", entry.totalPoints))
                        .font(.title2.weight(.bold))

                    Divider()

                    ForEach(0..<TennisBracketEngine.rounds.count, id: \.self) { roundIndex in
                        let round = TennisBracketEngine.rounds[roundIndex]
                        let matchCount = TennisBracketEngine.matchesPerRound[roundIndex]
                        let roundPts = entry.roundBreakdown[round] ?? 0

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(roundDisplayName(round))
                                    .font(.caption.weight(.bold))
                                Spacer()
                                Text("\(roundPts) pts")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(roundPts > 0 ? brandPurple : .secondary)
                            }

                            let picks = (1...matchCount).compactMap { matchNum -> (slot: String, name: String)? in
                                let slot = TennisBracketEngine.matchSlot(round: round, matchNumber: matchNum)
                                guard let name = entry.picks[slot] else { return nil }
                                return (slot, name)
                            }

                            ForEach(picks, id: \.slot) { pick in
                                pickStatusBadge(slot: pick.slot, name: pick.name)
                            }
                        }
                        if roundIndex < TennisBracketEngine.rounds.count - 1 {
                            Divider()
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("Bracket Detail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { selectedEntry = nil }
                }
            }
        }
    }

    private func pickStatusBadge(slot: String, name: String) -> some View {
        // Use the group's tournament results (loaded by loadGroupStandings)
        // so coloring is correct even when the user is browsing a different draw.
        let result = viewModel.currentGroupResults[slot]
        let status: PickStatus = {
            guard let result else { return .pending }
            if TennisBracketEngine.normalizedName(result) == TennisBracketEngine.normalizedName(name) {
                return .correct
            }
            return .wrong
        }()

        return HStack(spacing: 4) {
            Image(systemName: status.icon)
                .font(.system(size: 10))
                .foregroundStyle(status.color)
            Text(name)
                .font(.system(size: 11))
                .foregroundStyle(status == .wrong ? .secondary : .primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(status.bgColor)
        .clipShape(Capsule())
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private enum PickStatus {
        case correct, wrong, pending

        var icon: String {
            switch self {
            case .correct: return "checkmark.circle.fill"
            case .wrong: return "xmark.circle.fill"
            case .pending: return "clock"
            }
        }

        var color: Color {
            switch self {
            case .correct: return .green
            case .wrong: return .red
            case .pending: return .gray
            }
        }

        var bgColor: Color {
            switch self {
            case .correct: return .green.opacity(0.1)
            case .wrong: return .red.opacity(0.08)
            case .pending: return .gray.opacity(0.08)
            }
        }
    }

    private func roundDisplayName(_ round: String) -> String {
        switch round {
        case "R1": return "Round 1"
        case "R2": return "Round 2"
        case "R3": return "Round 3"
        case "R4": return "Round of 16"
        case "QF": return "Quarterfinals"
        case "SF": return "Semifinals"
        case "F": return "Final"
        default: return round
        }
    }
}
