import SwiftUI

// MARK: - View Model

@Observable
final class ChatViewModel {
    var messages: [ChatMessageRecord] = []
    var draft: String = ""
    var isLoading: Bool = false
    var errorMessage: String?
    var leagueId: String?  // nil = All Chat

    private var pollingTask: Task<Void, Never>?

    func loadMessages(accessToken: String) async {
        isLoading = messages.isEmpty
        errorMessage = nil
        do {
            messages = try await SupabaseService.shared.fetchRecentMessages(leagueId: leagueId, accessToken: accessToken)
        } catch {
            errorMessage = "Unable to load messages."
        }
        isLoading = false
    }

    func send(userId: String, username: String, accessToken: String) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        do {
            try await SupabaseService.shared.sendMessage(
                userId: userId,
                username: username,
                body: text,
                leagueId: leagueId,
                accessToken: accessToken
            )
            // Reload to pick up our message + any new ones
            messages = try await SupabaseService.shared.fetchRecentMessages(leagueId: leagueId, accessToken: accessToken)
        } catch {
            errorMessage = "Failed to send message."
        }
    }

    func startPolling(accessToken: String) {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)  // 4 seconds
                guard !Task.isCancelled else { break }
                if let leagueId = self?.leagueId,
                   let updated = try? await SupabaseService.shared.fetchRecentMessages(leagueId: leagueId, accessToken: accessToken) {
                    self?.messages = updated
                } else if self?.leagueId == nil,
                          let updated = try? await SupabaseService.shared.fetchRecentMessages(leagueId: nil, accessToken: accessToken) {
                    self?.messages = updated
                }
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }
}

// MARK: - Chat List View (Messages-style room list)

struct ChatListView: View {
    var bestBallViewModel: BestBallViewModel
    var golfTiersViewModel: GolfTiersViewModel
    var playoffTiersViewModel: PlayoffTiersViewModel
    var soccerTiersViewModel: SoccerTiersViewModel
    var tennisBracketViewModel: TennisBracketViewModel
    @EnvironmentObject private var auth: AuthViewModel
    @State private var dmConversations: [ChatMessageRecord] = []
    @State private var dmDisplayNames: [String: String] = [:]  // leagueId → other user's display name
    @State private var latestMessageDates: [String?: Date] = [:]  // leagueId → latest message date
    @State private var groupChatInfos: [GroupChatInfo] = []

    private var brandPurple: Color {
        Color(red: 0.48, green: 0.23, blue: 0.93)
    }

    /// Key for storing last-read timestamp per chat room in UserDefaults
    private func lastReadKey(for leagueId: String?) -> String {
        "chat_last_read_\(leagueId ?? "all")"
    }

    private func hasUnread(leagueId: String?) -> Bool {
        guard let latest = latestMessageDates[leagueId] else { return false }
        let lastRead = UserDefaults.standard.object(forKey: lastReadKey(for: leagueId)) as? Date ?? .distantPast
        return latest > lastRead
    }

    /// Mark a chat as read (call when user enters the room)
    static func markAsRead(leagueId: String?) {
        let key = "chat_last_read_\(leagueId ?? "all")"
        UserDefaults.standard.set(Date(), forKey: key)
    }

    var body: some View {
        NavigationStack {
            List {
                // All Chat — always at the top
                NavigationLink(value: ChatRoom(id: "all", title: "All Chat", leagueId: nil, sport: nil)) {
                    chatRow(
                        icon: "bubble.left.and.bubble.right.fill",
                        iconColor: brandPurple,
                        title: "All Chat",
                        subtitle: "Everyone in DuelFantasy",
                        showUnreadDot: hasUnread(leagueId: nil)
                    )
                }

                // Direct Messages
                if !dmConversations.isEmpty {
                    Section {
                        ForEach(dmConversations) { convo in
                            let displayName = dmDisplayNames[convo.leagueId ?? ""] ?? (convo.userId == auth.userID ? "Direct Message" : convo.username)
                            NavigationLink(value: ChatRoom(
                                id: convo.leagueId ?? "",
                                title: displayName,
                                leagueId: convo.leagueId,
                                sport: nil
                            )) {
                                chatRow(
                                    icon: "person.fill",
                                    iconColor: .blue,
                                    title: displayName,
                                    subtitle: String(convo.body.prefix(40)) + (convo.body.count > 40 ? "..." : ""),
                                    showUnreadDot: hasUnread(leagueId: convo.leagueId)
                                )
                            }
                        }
                    } header: {
                        Text("Direct Messages")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                    }
                }

                // Group Chats (from Tiers / Bracket games)
                if !groupChatInfos.isEmpty {
                    Section {
                        ForEach(groupChatInfos) { info in
                            NavigationLink(value: ChatRoom(
                                id: info.leagueId,
                                title: info.name,
                                leagueId: info.leagueId,
                                sport: nil
                            )) {
                                chatRow(
                                    icon: info.icon,
                                    iconColor: info.iconColor,
                                    title: info.name,
                                    subtitle: "\(info.gameTypeLabel) • \(info.tournamentName)",
                                    showUnreadDot: hasUnread(leagueId: info.leagueId)
                                )
                            }
                        }
                    } header: {
                        Text("Group Chats")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                    }
                }

                // League chats
                if !bestBallViewModel.myLeagues.isEmpty {
                    Section {
                        ForEach(bestBallViewModel.myLeagues) { league in
                            NavigationLink(value: ChatRoom(id: league.id, title: league.title, leagueId: league.id, sport: league.sport)) {
                                chatRow(
                                    icon: sportIcon(league.sport),
                                    iconColor: sportColor(league.sport),
                                    title: league.title,
                                    subtitle: "\(league.sport) Best Ball",
                                    showUnreadDot: hasUnread(leagueId: league.id)
                                )
                            }
                        }
                    } header: {
                        Text("League Chats")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Messages")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: ChatRoom.self) { room in
                ChatRoomView(leagueId: room.leagueId, title: room.title)
            }
            .task {
                if bestBallViewModel.myLeagues.isEmpty {
                    await bestBallViewModel.loadMyLeagues()
                }
                await loadDMConversations()
                await loadGroupChats()
                await loadUnreadIndicators()
            }
        }
    }

    private func loadDMConversations() async {
        guard let token = auth.accessToken, let userID = auth.userID else { return }
        let convos = (try? await SupabaseService.shared.fetchDMConversations(userID: userID, accessToken: token)) ?? []
        dmConversations = convos

        // Resolve other user's display name for each DM conversation
        var otherUserIDs: [String: String] = [:]  // leagueId → otherUserID
        for convo in convos {
            guard let lid = convo.leagueId, lid.hasPrefix("dm-") else { continue }
            let parts = lid.dropFirst(3).split(separator: "-")  // remove "dm-" prefix
            // DM ID format: dm-{uuid1}-{uuid2} — UUIDs contain hyphens, so rejoin properly
            // The ID is: dm-{min(id1,id2)}-{max(id1,id2)}
            // Since UUIDs are 36 chars each (with hyphens), extract them by position
            let remainder = String(lid.dropFirst(3)) // everything after "dm-"
            if remainder.count >= 73 { // 36 + 1 + 36
                let firstID = String(remainder.prefix(36))
                let secondID = String(remainder.suffix(36))
                let otherID = firstID == userID ? secondID : firstID
                otherUserIDs[lid] = otherID
            }
        }

        // Fetch profiles for all other users we don't already have names for
        let idsToFetch = Array(Set(otherUserIDs.values))
        guard !idsToFetch.isEmpty else { return }

        if let profiles = try? await SupabaseService.shared.fetchProfiles(userIDs: idsToFetch, accessToken: token) {
            var names: [String: String] = [:]
            let profilesByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
            for (leagueId, otherID) in otherUserIDs {
                if let profile = profilesByID[otherID] {
                    names[leagueId] = profile.username
                }
            }
            dmDisplayNames = names
        }
    }

    private func loadGroupChats() async {
        guard let token = auth.accessToken, let userID = auth.userID else { return }

        // Fetch all groups from all 4 game types in parallel
        var infos: [GroupChatInfo] = []

        await withTaskGroup(of: [GroupChatInfo].self) { group in
            // Golf Tiers
            group.addTask {
                guard let records = try? await SupabaseService.shared.fetchAllMyGolfTiersGroups(userID: userID, accessToken: token) else { return [] }
                return records.map { r in
                    let tournamentName = GolfTiersTournament.majorTitle(for: r.tournamentID)
                        .replacingOccurrences(of: " Tiers", with: "")
                    return GroupChatInfo(
                        id: "golf-\(r.id)",
                        name: r.name,
                        gameType: "golf_tiers",
                        tournamentName: tournamentName,
                        leagueId: "group-golf_tiers-\(r.id)"
                    )
                }
            }

            // Playoff Tiers
            group.addTask {
                guard let records = try? await SupabaseService.shared.fetchAllMyPlayoffTiersGroups(userID: userID, accessToken: token) else { return [] }
                return records.map { r in
                    // Tournament ID format: "nba-playoffs-2026"
                    let parts = r.tournamentID.split(separator: "-")
                    let year = parts.last.map(String.init) ?? ""
                    let tournamentName = "\(year) NBA Playoffs"
                    return GroupChatInfo(
                        id: "playoff-\(r.id)",
                        name: r.name,
                        gameType: "playoff_tiers",
                        tournamentName: tournamentName,
                        leagueId: "group-playoff_tiers-\(r.id)"
                    )
                }
            }

            // Soccer Tiers
            group.addTask {
                guard let records = try? await SupabaseService.shared.fetchAllMySoccerTiersGroups(userID: userID, accessToken: token) else { return [] }
                return records.map { r in
                    let tournamentName = SoccerTiersTournament.currentTitle()
                        .replacingOccurrences(of: " Tiers", with: "")
                    return GroupChatInfo(
                        id: "soccer-\(r.id)",
                        name: r.name,
                        gameType: "soccer_tiers",
                        tournamentName: tournamentName,
                        leagueId: "group-soccer_tiers-\(r.id)"
                    )
                }
            }

            // Tennis Bracket
            group.addTask {
                guard let records = try? await SupabaseService.shared.fetchAllMyTennisBracketGroups(userID: userID, accessToken: token) else { return [] }
                return records.map { r in
                    // Tournament ID format: "french_open-atp-2026"
                    let parts = r.tournamentID.split(separator: "-")
                    var tournamentName = r.tournamentID
                    if parts.count >= 3 {
                        let slamRaw = parts.dropLast(2).joined(separator: "-") // e.g. "french_open"
                        let drawRaw = String(parts[parts.count - 2]) // e.g. "atp"
                        if let slam = GrandSlam(rawValue: slamRaw) {
                            tournamentName = "\(slam.displayName) \(drawRaw.uppercased())"
                        }
                    }
                    return GroupChatInfo(
                        id: "tennis-\(r.id)",
                        name: r.name,
                        gameType: "tennis_bracket",
                        tournamentName: tournamentName,
                        leagueId: "group-tennis_bracket-\(r.id)"
                    )
                }
            }

            for await batch in group {
                infos.append(contentsOf: batch)
            }
        }

        groupChatInfos = infos
    }

    private func loadUnreadIndicators() async {
        guard let token = auth.accessToken else { return }
        // Collect all room IDs we need timestamps for
        var roomIds: [String?] = [nil]  // All Chat
        for league in bestBallViewModel.myLeagues {
            roomIds.append(league.id)
        }
        // Include group chat room IDs
        for group in groupChatInfos {
            roomIds.append(group.leagueId)
        }
        // Fetch latest message dates from server
        if let dates = try? await SupabaseService.shared.fetchLatestMessageDates(leagueIds: roomIds, accessToken: token) {
            latestMessageDates = dates
        }
        // For DMs, use the createdAt from fetchDMConversations (already fetched, most recent message per DM)
        for convo in dmConversations {
            latestMessageDates[convo.leagueId] = convo.createdAt
        }
    }

    private func chatRow(icon: String, iconColor: Color, title: String, subtitle: String, showUnreadDot: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(iconColor)
                .frame(width: 40, height: 40)
                .background(iconColor.opacity(0.15))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if showUnreadDot {
                Circle()
                    .fill(brandPurple)
                    .frame(width: 10, height: 10)
            }
        }
        .padding(.vertical, 4)
    }

    private func sportIcon(_ sport: String) -> String {
        switch sport {
        case "MLB": return "figure.baseball"
        case "NBA": return "figure.basketball"
        case "NFL": return "figure.american.football"
        default: return "sportscourt"
        }
    }

    private func sportColor(_ sport: String) -> Color {
        switch sport {
        case "MLB": return .red
        case "NBA": return .orange
        case "NFL": return .blue
        default: return brandPurple
        }
    }
}

/// Navigation value for chat rooms
struct ChatRoom: Identifiable, Hashable {
    let id: String
    let title: String
    let leagueId: String?  // nil = All Chat
    let sport: String?
}

/// Info for a group chat room in the Messages tab
struct GroupChatInfo: Identifiable, Hashable {
    let id: String           // unique identifier
    let name: String         // group name, e.g. "Office Pool"
    let gameType: String     // "golf_tiers", "playoff_tiers", "soccer_tiers", "tennis_bracket"
    let tournamentName: String // "PGA Championship", "NBA Playoffs 2026", etc.
    let leagueId: String     // "group-golf_tiers-{uuid}"

    var icon: String {
        switch gameType {
        case "golf_tiers": return "figure.golf"
        case "playoff_tiers": return "figure.basketball"
        case "soccer_tiers": return "soccerball"
        case "tennis_bracket": return "figure.tennis"
        default: return "person.3.fill"
        }
    }

    var iconColor: Color {
        switch gameType {
        case "golf_tiers": return Color(red: 0.05, green: 0.45, blue: 0.25)
        case "playoff_tiers": return .orange
        case "soccer_tiers": return .green
        case "tennis_bracket": return .mint
        default: return .purple
        }
    }

    var gameTypeLabel: String {
        switch gameType {
        case "golf_tiers": return "Golf Tiers"
        case "playoff_tiers": return "Playoff Tiers"
        case "soccer_tiers": return "Soccer Tiers"
        case "tennis_bracket": return "Tennis Bracket"
        default: return "Group"
        }
    }
}

// MARK: - Chat Room View (individual message thread)

struct ChatRoomView: View {
    let leagueId: String?
    let title: String

    @EnvironmentObject private var auth: AuthViewModel
    @AppStorage("profile_name") private var profileName: String = ""
    @State private var viewModel = ChatViewModel()

    private var brandPurple: Color {
        Color(red: 0.48, green: 0.23, blue: 0.93)
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isLoading {
                Spacer()
                ProgressView("Loading chat...")
                    .foregroundStyle(.secondary)
                Spacer()
            } else if let error = viewModel.errorMessage, viewModel.messages.isEmpty {
                Spacer()
                Text(error)
                    .foregroundStyle(.secondary)
                    .padding()
                Spacer()
            } else if viewModel.messages.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No messages yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Be the first to say something!")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            } else {
                messageList
            }

            Divider()
            inputBar
        }
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            viewModel.leagueId = leagueId
            ChatListView.markAsRead(leagueId: leagueId)
            guard let token = auth.accessToken else { return }
            await viewModel.loadMessages(accessToken: token)
            viewModel.startPolling(accessToken: token)
        }
        .onDisappear {
            ChatListView.markAsRead(leagueId: leagueId)
            viewModel.stopPolling()
        }
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.messages) { message in
                        messageBubble(message)
                            .id(message.id)
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: viewModel.messages.count) {
                if let last = viewModel.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func messageBubble(_ message: ChatMessageRecord) -> some View {
        let isMe = message.userId == auth.userID
        return HStack(alignment: .top, spacing: 8) {
            if isMe { Spacer(minLength: 60) }

            VStack(alignment: isMe ? .trailing : .leading, spacing: 3) {
                if !isMe {
                    Text(message.username)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(brandPurple)
                }
                Text(message.body)
                    .font(.subheadline)
                    .foregroundStyle(isMe ? .white : .primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isMe ? brandPurple : Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                Text(timeString(message.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !isMe { Spacer(minLength: 60) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Message...", text: $viewModel.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 20))

            Button {
                Haptics.light()
                guard let token = auth.accessToken,
                      let userId = auth.userID else { return }
                let username = profileName.isEmpty ? "Anonymous" : profileName
                Task {
                    await viewModel.send(userId: userId, username: username, accessToken: token)
                }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color(.systemGray3) : brandPurple)
            }
            .disabled(viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    // MARK: - Helpers

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "h:mm a"
        } else {
            formatter.dateFormat = "MMM d, h:mm a"
        }
        return formatter.string(from: date)
    }
}
