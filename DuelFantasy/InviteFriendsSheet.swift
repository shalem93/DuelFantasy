import SwiftUI

struct InviteFriendsSheet: View {
    var viewModel: DFSViewModel
    let tournamentID: String

    @Environment(\.dismiss) private var dismiss
    @State private var friends: [DFSProfileRecord] = []
    @State private var selectedIDs: Set<String> = []
    @State private var alreadyInvitedIDs: Set<String> = []
    @State private var alreadyEnteredIDs: Set<String> = []
    @State private var isLoading = true
    @State private var isSending = false

    private let brandPurple = Color(red: 0.38, green: 0.15, blue: 0.80)

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading friends...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if friends.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "person.2.slash")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No friends to invite")
                            .font(.headline)
                        Text("Add friends from the Social tab first.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(friends) { friend in
                        friendRow(friend)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Invite Friends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        isSending = true
                        Task {
                            await viewModel.sendInvites(tournamentID: tournamentID, friendIDs: Array(selectedIDs))
                            isSending = false
                            dismiss()
                        }
                    } label: {
                        if isSending {
                            ProgressView()
                        } else {
                            Text("Send (\(selectedIDs.count))")
                        }
                    }
                    .disabled(selectedIDs.isEmpty || isSending)
                }
            }
            .task { await loadData() }
        }
    }

    @ViewBuilder
    private func friendRow(_ friend: DFSProfileRecord) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(friend.username)
                    .font(.subheadline.weight(.medium))
                Text("\(friend.rrScore ?? 1000) RR")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if alreadyEnteredIDs.contains(friend.id) {
                Text("Entered")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            } else if alreadyInvitedIDs.contains(friend.id) {
                Text("Invited")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    if selectedIDs.contains(friend.id) {
                        selectedIDs.remove(friend.id)
                    } else {
                        selectedIDs.insert(friend.id)
                    }
                } label: {
                    Image(systemName: selectedIDs.contains(friend.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selectedIDs.contains(friend.id) ? brandPurple : .secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !alreadyEnteredIDs.contains(friend.id),
                  !alreadyInvitedIDs.contains(friend.id) else { return }
            if selectedIDs.contains(friend.id) {
                selectedIDs.remove(friend.id)
            } else {
                selectedIDs.insert(friend.id)
            }
        }
    }

    private func loadData() async {
        guard let userID = viewModel.userID, let token = viewModel.accessToken else {
            isLoading = false
            return
        }
        do {
            // Fetch accepted friends
            let friendships = try await SupabaseService.shared.fetchFriendships(userID: userID, accessToken: token)
            let acceptedFriendIDs = friendships
                .filter { $0.status == "accepted" }
                .map { $0.requesterID == userID ? $0.addresseeID : $0.requesterID }

            if !acceptedFriendIDs.isEmpty {
                let profiles = try await SupabaseService.shared.fetchProfiles(userIDs: acceptedFriendIDs, accessToken: token)
                friends = profiles.sorted { $0.username.lowercased() < $1.username.lowercased() }
            }

            // Fetch already-sent invites for this tournament
            let sentInvites = try await SupabaseService.shared.fetchSentInvites(
                tournamentID: tournamentID, inviterID: userID, accessToken: token
            )
            alreadyInvitedIDs = Set(sentInvites.map(\.inviteeID))

            // Fetch entries for this tournament to see who already joined
            let entries = try await SupabaseService.shared.fetchEntries(
                tournamentID: tournamentID, accessToken: token
            )
            alreadyEnteredIDs = Set(entries.map(\.userID))
        } catch {
            print("[DFS] InviteFriendsSheet loadData failed: \(error.localizedDescription)")
        }
        isLoading = false
    }
}
