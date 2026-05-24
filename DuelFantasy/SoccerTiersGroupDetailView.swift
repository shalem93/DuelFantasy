import SwiftUI

struct SoccerTiersGroupDetailView: View {
    @Bindable var viewModel: SoccerTiersViewModel
    let group: SoccerTiersGroup

    @State private var showInviteCode = false
    @State private var copiedCode = false
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
                    Color(red: 0.93, green: 0.98, blue: 0.93),
                    Color(red: 0.95, green: 0.97, blue: 1.00),
                    Color(red: 0.98, green: 0.99, blue: 1.00)
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
                    Text(viewModel.tournament?.title ?? "FIFA World Cup 2026 Tiers")
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
                colors: [Color(red: 0.05, green: 0.35, blue: 0.15), Color(red: 0.10, green: 0.50, blue: 0.25)],
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
                .foregroundStyle(brandPurple)

            Button {
                UIPasteboard.general.string = group.inviteCode
                copiedCode = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    copiedCode = false
                }
            } label: {
                Label(copiedCode ? "Copied!" : "Copy Code", systemImage: copiedCode ? "checkmark" : "doc.on.doc")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(copiedCode ? .green : brandPurple)
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
                                    .background(brandPurple)
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
                        HStack(spacing: 12) {
                            Text("\(entry.rank)")
                                .font(.subheadline.weight(.bold).monospacedDigit())
                                .foregroundStyle(entry.rank <= 3 ? brandPurple : .secondary)
                                .frame(width: 24, alignment: .center)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.entryName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(entry.isCurrentUser ? brandPurple : .primary)
                                Text("\(entry.picks.count) picks")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text(String(format: "%.1f", entry.totalPoints))
                                .font(.subheadline.weight(.bold).monospacedDigit())
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(entry.isCurrentUser ? brandPurple.opacity(0.08) : .clear)
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
                ChatRoomView(leagueId: "group-soccer_tiers-\(group.id.uuidString)", title: "\(group.name) Chat")
            } label: {
                Label("Group Chat", systemImage: "bubble.left.and.bubble.right.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Color.green.opacity(0.1))
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
