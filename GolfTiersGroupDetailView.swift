import SwiftUI

struct GolfTiersGroupDetailView: View {
    @Bindable var viewModel: GolfTiersViewModel
    let group: GolfTiersGroup

    @State private var copiedCode = false
    @Environment(\.dismiss) private var dismiss

    private var darkGreen: Color {
        Color(red: 0.05, green: 0.45, blue: 0.25)
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
                if viewModel.isLocked || viewModel.isLive || viewModel.isSettled {
                    groupLeaderboardSection
                }
                actionButtons
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.93, green: 0.97, blue: 0.93),
                    Color(red: 0.95, green: 0.98, blue: 0.95),
                    Color(red: 0.98, green: 0.99, blue: 0.98)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadGroupDetail(group)
        }
    }

    // MARK: - Group Header

    private var groupHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "person.3.fill")
                    .font(.title3)
                    .foregroundStyle(.white)

                Text(group.name)
                    .font(.title3.bold())
                    .foregroundStyle(.white)

                Spacer()

                Text("\(viewModel.currentGroupMembers.count)/\(group.maxMembers)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("TOURNAMENT")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    Text(viewModel.tournament?.title ?? "Golf Major Tiers")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("STATUS")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    Text(viewModel.tournament?.status.capitalized ?? "Open")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [Color(red: 0.04, green: 0.30, blue: 0.15), Color(red: 0.08, green: 0.50, blue: 0.28)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }

    // MARK: - Invite Code

    private var inviteCodeCard: some View {
        VStack(spacing: 8) {
            Text("INVITE CODE")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)

            Text(group.inviteCode)
                .font(.title2.bold().monospaced())
                .foregroundStyle(darkGreen)

            Button {
                UIPasteboard.general.string = group.inviteCode
                copiedCode = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    copiedCode = false
                }
            } label: {
                Label(copiedCode ? "Copied!" : "Copy Code", systemImage: copiedCode ? "checkmark" : "doc.on.doc")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(copiedCode ? .green : darkGreen)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
    }

    // MARK: - Members

    private var membersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MEMBERS")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            if viewModel.currentGroupMembers.isEmpty {
                Text("Loading members...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(viewModel.currentGroupMembers) { member in
                        HStack(spacing: 12) {
                            Image(systemName: "person.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.secondary)

                            Text(member.displayName)
                                .font(.subheadline.weight(.medium))

                            if member.userID == group.createdBy {
                                Text("Owner")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(darkGreen)
                                    .clipShape(Capsule())
                            }

                            if member.userID == viewModel.userID {
                                Text("You")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.blue)
                                    .clipShape(Capsule())
                            }

                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }
                }
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
            }
        }
    }

    // MARK: - Group Leaderboard

    private var groupLeaderboardSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GROUP STANDINGS")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            let entries = viewModel.groupLeaderboard
            if entries.isEmpty {
                Text("Standings will appear once the tournament is live.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(entries) { entry in
                        DisclosureGroup {
                            VStack(spacing: 4) {
                                ForEach(entry.picks.sorted(by: { $0.tier < $1.tier }), id: \.playerID) { pick in
                                    HStack(spacing: 10) {
                                        Text("T\(pick.tier)")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(.white)
                                            .frame(width: 26, height: 18)
                                            .background(darkGreen.opacity(0.8))
                                            .clipShape(RoundedRectangle(cornerRadius: 4))
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(pick.playerName)
                                                .font(.caption.weight(.medium))
                                                .lineLimit(1)
                                            Text(pick.playerCountry)
                                                .font(.system(size: 9))
                                                .foregroundStyle(.secondary)
                                        }
                                        if entry.countingPicks.contains(pick.playerID) {
                                            Text("✓")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundStyle(darkGreen)
                                        }
                                        Spacer()
                                        let score = entry.pickScores[pick.playerID] ?? 0
                                        Text(GolfTiersEngine.scoreToParDisplay(score))
                                            .font(.caption.weight(.semibold).monospacedDigit())
                                            .foregroundStyle(score < 0 ? .red : .secondary)
                                    }
                                    .padding(.vertical, 2)
                                }
                                Text("✓ = counting toward best 4 of 6")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.leading, 24)
                            .padding(.bottom, 6)
                        } label: {
                            HStack(spacing: 12) {
                                Text("\(entry.rank)")
                                    .font(.subheadline.weight(.bold).monospacedDigit())
                                    .foregroundStyle(entry.rank <= 3 ? darkGreen : .secondary)
                                    .frame(width: 24, alignment: .center)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.entryName)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(entry.isCurrentUser ? darkGreen : .primary)
                                    Text("\(entry.picks.count) picks")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Text(GolfTiersEngine.scoreToParDisplay(entry.totalScore))
                                    .font(.subheadline.weight(.bold).monospacedDigit())
                                    .foregroundStyle(.primary)
                            }
                            .contentShape(Rectangle())
                        }
                        .tint(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(entry.isCurrentUser ? darkGreen.opacity(0.08) : .clear)
                    }
                }
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
            }
        }
    }

    // MARK: - Actions

    private var actionButtons: some View {
        VStack(spacing: 8) {
            NavigationLink {
                ChatRoomView(leagueId: "group-golf_tiers-\(group.id.uuidString)", title: "\(group.name) Chat")
            } label: {
                Label("Group Chat", systemImage: "bubble.left.and.bubble.right.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(darkGreen)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(darkGreen.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            if isOwner {
                Button(role: .destructive) {
                    Task {
                        await viewModel.deleteGroup(group)
                        dismiss()
                    }
                } label: {
                    Text("Delete Group")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            } else {
                Button {
                    Task {
                        await viewModel.leaveGroup(group)
                        dismiss()
                    }
                } label: {
                    Text("Leave Group")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
}
