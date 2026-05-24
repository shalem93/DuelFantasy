import SwiftUI

struct PlayoffTiersLobbyView: View {
    @Bindable var viewModel: PlayoffTiersViewModel
    @State private var selectedTier: Int = 1
    @State private var showCreateGroup = false
    @State private var showJoinGroup = false
    @State private var newGroupName = ""
    @State private var joinCode = ""

    private var brandPurple: Color {
        Color(red: 0.48, green: 0.23, blue: 0.93)
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isLoading && !viewModel.hasAttemptedLoad {
                loadingView
            } else if viewModel.isLocked {
                // Tournament is locked — always show live view (whether or not user submitted)
                PlayoffTiersLiveView(viewModel: viewModel)
            } else if let error = viewModel.error, viewModel.tiers.isEmpty {
                errorView(error)
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        heroCard
                        picksOverview
                        tierSelector
                        playerList
                        submitButton
                        groupsSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
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
        .navigationTitle("Playoff Tiers")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if !viewModel.hasAttemptedLoad {
                await viewModel.loadTournament()
            } else {
                // Even if already loaded, re-check status transitions in case
                // the app was opened before lock time and is now past it.
                await viewModel.recheckStatusIfNeeded()
            }
            await viewModel.loadMyGroups()
        }
        .sheet(isPresented: $showCreateGroup) {
            createGroupSheet
        }
        .sheet(isPresented: $showJoinGroup) {
            joinGroupSheet
        }
    }

    // MARK: - Hero Card

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("NBA")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(brandPurple)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: "person.2.fill")
                        .font(.caption2)
                    Text("\(viewModel.tournament?.entryCount ?? 1000) entries")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(.white.opacity(0.8))
            }

            Text(viewModel.tournament?.title ?? "NBA Playoff Tiers")
                .font(.title2.bold())
                .foregroundStyle(.white)

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("FORMAT")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("Pick 1 per tier")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("TIERS")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("6 tiers")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }

                Spacer()

                if let remaining = viewModel.lockTimeRemaining {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("LOCKS IN")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.6))
                        Text(remaining)
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                    }
                }
            }
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [Color(red: 0.10, green: 0.15, blue: 0.30), Color(red: 0.15, green: 0.25, blue: 0.50)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }

    // MARK: - Picks Overview

    private var picksOverview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("YOUR PICKS")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(1...6, id: \.self) { tier in
                    pickSlot(tier: tier)
                }
            }
        }
    }

    private func pickSlot(tier: Int) -> some View {
        let player = viewModel.userPicks[tier]
        let isFilled = player != nil

        return VStack(spacing: 4) {
            Text("T\(tier)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isFilled ? .white : .secondary)

            if let player {
                Text(lastName(player.name))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            } else {
                Image(systemName: "plus")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .background(isFilled ? brandPurple : Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture {
            selectedTier = tier
        }
    }

    // MARK: - Tier Selector

    private var tierSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(1...6, id: \.self) { tier in
                    let isSelected = selectedTier == tier
                    let tierPlayers = tier <= viewModel.tiers.count ? viewModel.tiers[tier - 1] : []

                    Button {
                        Haptics.light()
                        selectedTier = tier
                    } label: {
                        VStack(spacing: 2) {
                            Text("Tier \(tier)")
                                .font(.subheadline.weight(isSelected ? .bold : .medium))
                            Text("\(tierPlayers.count) players")
                                .font(.system(size: 9))
                        }
                        .foregroundStyle(isSelected ? .white : .primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(isSelected ? brandPurple : Color(.systemGray6))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Player List

    private var playerList: some View {
        let tierIndex = selectedTier - 1
        let players = tierIndex < viewModel.tiers.count ? viewModel.tiers[tierIndex] : []
        let selectedPlayerID = viewModel.userPicks[selectedTier]?.id

        return LazyVStack(spacing: 0) {
            ForEach(Array(players.enumerated()), id: \.element.id) { index, player in
                playerRow(player: player, isSelected: player.id == selectedPlayerID, rank: index + 1)
            }
        }
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
    }

    private func playerRow(player: PlayoffTiersPlayer, isSelected: Bool, rank: Int) -> some View {
        Button {
            Haptics.light()
            if isSelected {
                viewModel.removePlayer(tier: selectedTier)
            } else {
                viewModel.selectPlayer(tier: selectedTier, player: player)
            }
        } label: {
            HStack(spacing: 12) {
                // Rank
                Text("\(rank)")
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .center)

                // Player headshot placeholder
                if let imageURL = player.imageURL, let url = URL(string: imageURL) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 36, height: 36)
                    .clipShape(Circle())
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                }

                // Player info
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(player.team)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(player.position)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Projected FPTS
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.1f", player.projectedPoints))
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(.primary)
                    Text("FPPG")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                // Selection indicator
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? brandPurple : Color(.systemGray4))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isSelected ? brandPurple.opacity(0.08) : .clear)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Submit Button

    @ViewBuilder
    private var submitButton: some View {
        if !viewModel.isLocked {
            Button {
                Haptics.medium()
                Task {
                    await viewModel.submitPicks()
                }
            } label: {
                HStack(spacing: 8) {
                    if viewModel.isSubmitting {
                        ProgressView()
                            .tint(.white)
                    }
                    Text(viewModel.hasSubmitted ? "Update Picks" : "Lock In Picks")
                        .font(.headline.weight(.bold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(viewModel.allPicksMade ? brandPurple : Color(.systemGray4))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(!viewModel.allPicksMade || viewModel.isSubmitting)

            if !viewModel.allPicksMade {
                Text("Select 1 player from each of the 6 tiers to submit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let error = viewModel.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Loading & Error

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading playoff data...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await viewModel.loadTournament() }
            }
            .buttonStyle(.borderedProminent)
            .tint(brandPurple)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Groups Section

    private var groupsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("MY GROUPS")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showCreateGroup = true
                } label: {
                    Label("Create", systemImage: "plus.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(brandPurple)
                }
                Button {
                    showJoinGroup = true
                } label: {
                    Label("Join", systemImage: "person.badge.plus")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(brandPurple)
                }
            }

            if viewModel.myGroups.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.3")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No groups yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Create a group and invite friends to compete")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(spacing: 0) {
                    ForEach(viewModel.myGroups) { group in
                        NavigationLink {
                            PlayoffTiersGroupDetailView(viewModel: viewModel, group: group)
                        } label: {
                            groupRow(group)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
            }

            if let error = viewModel.groupError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func groupRow(_ group: PlayoffTiersGroup) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.3.fill")
                .font(.title3)
                .foregroundStyle(brandPurple)
                .frame(width: 36, height: 36)
                .background(brandPurple.opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Code: \(group.inviteCode)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Create Group Sheet

    private var createGroupSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Create a private group to compete with friends in Playoff Tiers.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                TextField("Group name", text: $newGroupName)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)

                Button {
                    Task {
                        if let _ = await viewModel.createGroup(name: newGroupName) {
                            newGroupName = ""
                            showCreateGroup = false
                        }
                    }
                } label: {
                    HStack {
                        if viewModel.isCreatingGroup {
                            ProgressView().tint(.white)
                        }
                        Text("Create Group")
                            .font(.headline.weight(.bold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(newGroupName.trimmingCharacters(in: .whitespaces).isEmpty ? Color(.systemGray4) : brandPurple)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(newGroupName.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isCreatingGroup)
                .padding(.horizontal)

                if let error = viewModel.groupError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }

                Spacer()
            }
            .padding(.top, 20)
            .navigationTitle("New Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showCreateGroup = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Join Group Sheet

    private var joinGroupSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Enter the 6-character invite code from your friend to join their group.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                TextField("Invite code", text: $joinCode)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.characters)
                    .padding(.horizontal)

                Button {
                    Task {
                        let success = await viewModel.joinGroupByCode(joinCode)
                        if success {
                            joinCode = ""
                            showJoinGroup = false
                        }
                    }
                } label: {
                    HStack {
                        if viewModel.isJoiningGroup {
                            ProgressView().tint(.white)
                        }
                        Text("Join Group")
                            .font(.headline.weight(.bold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(joinCode.trimmingCharacters(in: .whitespaces).isEmpty ? Color(.systemGray4) : brandPurple)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(joinCode.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isJoiningGroup)
                .padding(.horizontal)

                if let error = viewModel.groupError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }

                Spacer()
            }
            .padding(.top, 20)
            .navigationTitle("Join Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showJoinGroup = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Helpers

    private func lastName(_ fullName: String) -> String {
        let parts = fullName.components(separatedBy: " ")
        guard parts.count >= 2 else { return fullName }
        let suffixes: Set<String> = ["Jr.", "Jr", "Sr.", "Sr", "II", "III", "IV", "V"]
        if let last = parts.last, suffixes.contains(last), parts.count >= 3 {
            return parts[parts.count - 2]
        }
        return parts.last ?? fullName
    }
}


