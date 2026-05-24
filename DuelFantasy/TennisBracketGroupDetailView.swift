import SwiftUI

struct TennisBracketGroupDetailView: View {
    @Bindable var viewModel: TennisBracketViewModel
    let group: TennisBracketGroup
    @State private var showDeleteConfirmation = false
    @State private var showLeaveConfirmation = false
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
                    }
                    .padding(.vertical, 4)
                    .background(entry.isCurrentUser ? brandPurple.opacity(0.06) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
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
}
