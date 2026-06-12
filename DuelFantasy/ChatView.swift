import SwiftUI

// MARK: - Content Moderation

/// Lightweight client-side profanity filter for chat. Not a substitute for
/// server-side enforcement, but blocks the most obvious vulgar terms from
/// being submitted in the first place. Matches on letter-only normalized
/// form so common obfuscations like "f*ck" or "sh!t" are still caught.
enum ChatModeration {
    private static let bannedTerms: [String] = [
        "fuck", "shit", "bitch", "cunt", "dick", "pussy", "cock",
        "nigger", "nigga", "faggot", "kike", "spic", "chink",
        "slut", "whore", "asshole", "motherfucker", "bastard",
        "retard", "tranny"
    ]

    static func containsVulgarity(_ text: String) -> Bool {
        let lowered = text.lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
        let lettersOnly = String(lowered.unicodeScalars.filter {
            CharacterSet.letters.contains($0)
        })
        for term in bannedTerms where lettersOnly.contains(term) {
            return true
        }
        return false
    }
}

// MARK: - View Model

@Observable
@MainActor
final class ChatViewModel {
    var messages: [ChatMessageRecord] = []
    var draft: String = ""
    var isLoading: Bool = false
    var errorMessage: String?
    var leagueId: String?  // nil = All Chat
    /// userID → avatar URL. Populated on load + after each poll so chat
    /// bubbles can render the sender's profile picture without an extra
    /// JOIN on every message row.
    var avatarsByUserID: [String: String] = [:]
    /// messageID → array of reactions on that message. Updated every fetch
    /// + optimistically on add/remove so the chip rail responds instantly.
    var reactionsByMessageID: [String: [ChatReactionRecord]] = [:]

    private var pollingTask: Task<Void, Never>?

    func loadMessages(accessToken: String) async {
        isLoading = messages.isEmpty
        errorMessage = nil
        do {
            messages = try await SupabaseService.shared.fetchRecentMessages(leagueId: leagueId, accessToken: accessToken)
            await refreshAvatars(accessToken: accessToken)
            await refreshReactions(accessToken: accessToken)
        } catch {
            errorMessage = "Unable to load messages."
        }
        isLoading = false
    }

    func send(userId: String, username: String, accessToken: String) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if ChatModeration.containsVulgarity(text) {
            // Keep the draft so the user can edit it instead of losing
            // what they wrote, and surface a transient alert via the
            // existing errorMessage channel.
            blockedMessageAlert = "Your message was blocked for inappropriate language. Please revise it before sending."
            return
        }
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
            await refreshAvatars(accessToken: accessToken)
        } catch {
            errorMessage = "Failed to send message."
        }
    }

    /// Surfaced via `.alert` on the chat view when a send is blocked.
    var blockedMessageAlert: String?

    func startPolling(accessToken: String) {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)  // 4 seconds
                guard !Task.isCancelled else { break }
                if let leagueId = self?.leagueId,
                   let updated = try? await SupabaseService.shared.fetchRecentMessages(leagueId: leagueId, accessToken: accessToken) {
                    self?.messages = updated
                    await self?.refreshAvatars(accessToken: accessToken)
                    await self?.refreshReactions(accessToken: accessToken)
                } else if self?.leagueId == nil,
                          let updated = try? await SupabaseService.shared.fetchRecentMessages(leagueId: nil, accessToken: accessToken) {
                    self?.messages = updated
                    await self?.refreshAvatars(accessToken: accessToken)
                    await self?.refreshReactions(accessToken: accessToken)
                }
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Fetch avatar URLs for any senders we don't yet have a mapping for.
    /// Idempotent — only hits the API when there are new userIDs.
    private func refreshAvatars(accessToken: String) async {
        let missing = Array(Set(messages.map(\.userId)).subtracting(avatarsByUserID.keys))
        guard !missing.isEmpty else { return }
        if let profiles = try? await SupabaseService.shared.fetchProfiles(userIDs: missing, accessToken: accessToken) {
            for p in profiles {
                avatarsByUserID[p.id] = p.avatarUrl ?? ""
            }
        }
    }

    /// Pulls reactions for every currently-loaded message. Replaces the
    /// whole map each call so reactions removed by other users disappear.
    func refreshReactions(accessToken: String) async {
        let ids = messages.map(\.id)
        guard !ids.isEmpty else { return }
        if let reactions = try? await SupabaseService.shared.fetchChatReactions(messageIDs: ids, accessToken: accessToken) {
            reactionsByMessageID = Dictionary(grouping: reactions, by: \.messageId)
        }
    }

    /// Toggles the current user's reaction. If they already reacted with
    /// this emoji, the reaction is removed; otherwise it's added.
    /// Optimistically updates the local map before the server roundtrip.
    func toggleReaction(messageID: String, emoji: String, userID: String, accessToken: String) async {
        let existing = (reactionsByMessageID[messageID] ?? []).first(where: { $0.userId == userID && $0.emoji == emoji })
        if existing != nil {
            reactionsByMessageID[messageID]?.removeAll { $0.userId == userID && $0.emoji == emoji }
            try? await SupabaseService.shared.removeChatReaction(messageID: messageID, userID: userID, emoji: emoji, accessToken: accessToken)
        } else {
            let optimistic = ChatReactionRecord(
                id: UUID().uuidString, messageId: messageID,
                userId: userID, emoji: emoji, createdAt: Date()
            )
            reactionsByMessageID[messageID, default: []].append(optimistic)
            try? await SupabaseService.shared.addChatReaction(messageID: messageID, userID: userID, emoji: emoji, accessToken: accessToken)
        }
        await refreshReactions(accessToken: accessToken)
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

        // Sort by stable key so the chat list doesn't reorder every time
        // the user backs out of a chat room — TaskGroup completion order is
        // non-deterministic, which made FIFA / golf group rows visibly swap
        // positions after sending a message and returning.
        groupChatInfos = infos.sorted { $0.id < $1.id }
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
    /// When non-nil, the iMessage-style horizontal emoji picker is shown
    /// targeting this message. Set by long-press on a bubble; cleared on
    /// emoji tap or outside tap.
    @State private var reactionTargetMessageID: String?
    /// Screen-coordinate frame of each rendered bubble. Lets the reaction
    /// picker overlay anchor itself directly above the bubble the user
    /// long-pressed, instead of always docking at the bottom of the
    /// screen — much less confusing when the bubble is high up.
    @State private var bubbleFrames: [String: CGRect] = [:]
    /// When non-nil, presents a small profile preview sheet for this
    /// (userId, username). Set by tapping a username in a chat bubble.
    @State private var previewedUser: (userId: String, username: String)?

    private var brandPurple: Color {
        Color(red: 0.48, green: 0.23, blue: 0.93)
    }

    var body: some View {
        ZStack {
            chatBody
            if reactionTargetMessageID != nil {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                            reactionTargetMessageID = nil
                        }
                    }
                reactionPickerOverlay
                    .transition(.scale(scale: 0.7, anchor: .center).combined(with: .opacity))
            }
        }
    }

    private var chatBody: some View {
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
        .alert("Message Blocked", isPresented: Binding(
            get: { viewModel.blockedMessageAlert != nil },
            set: { if !$0 { viewModel.blockedMessageAlert = nil } }
        ), actions: {
            Button("OK", role: .cancel) {}
        }, message: {
            Text(viewModel.blockedMessageAlert ?? "")
        })
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
        .sheet(isPresented: Binding(
            get: { previewedUser != nil },
            set: { if !$0 { previewedUser = nil } }
        )) {
            if let preview = previewedUser {
                ChatProfilePreviewSheet(
                    userId: preview.userId,
                    fallbackUsername: preview.username,
                    avatarURL: viewModel.avatarsByUserID[preview.userId] ?? ""
                )
                .environmentObject(auth)
                .presentationDetents([.height(440)])
                .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - Message List

    /// A consecutive run of messages by the same sender within a short
    /// time window. Bunching them lets us draw the avatar + name once
    /// and tighten the spacing between bubbles in the same burst.
    private struct MessageGroup: Identifiable {
        let id: String
        let userId: String
        let username: String
        let isMe: Bool
        let messages: [ChatMessageRecord]
        let endTime: Date
    }

    private var messageGroups: [MessageGroup] {
        var groups: [MessageGroup] = []
        for message in viewModel.messages {
            let isMe = message.userId == auth.userID
            // Bunch into the previous group if same sender AND within 2 min.
            if let last = groups.last,
               last.userId == message.userId,
               message.createdAt.timeIntervalSince(last.endTime) < 120 {
                let combined = last.messages + [message]
                groups[groups.count - 1] = MessageGroup(
                    id: last.id, userId: last.userId, username: last.username,
                    isMe: last.isMe, messages: combined, endTime: message.createdAt
                )
            } else {
                groups.append(MessageGroup(
                    id: message.id, userId: message.userId, username: message.username,
                    isMe: isMe, messages: [message], endTime: message.createdAt
                ))
            }
        }
        return groups
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(messageGroups) { group in
                        messageGroupView(group)
                            .id(group.messages.last?.id ?? group.id)
                    }
                }
                .padding(.vertical, 12)
            }
            // Anchor the content to the bottom of the scroll view so that
            // when the keyboard dismisses (or when there aren't enough
            // messages to fill the view) the messages sit just above the
            // input bar instead of leaving a chunk of whitespace below.
            .defaultScrollAnchor(.bottom)
            .onChange(of: viewModel.messages.count) {
                if let last = viewModel.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func messageGroupView(_ group: MessageGroup) -> some View {
        let avatarURL = viewModel.avatarsByUserID[group.userId] ?? ""
        // GroupMe-style layout: every sender is left-aligned with their
        // avatar and name. The current user's own bubbles get a faint
        // purple tint instead of being moved to the right edge — keeps
        // the visual rhythm consistent across the room.
        return HStack(alignment: .top, spacing: 8) {
            avatarView(for: group.username, urlString: avatarURL)
                .contentShape(Circle())
                .onTapGesture {
                    guard !group.isMe, !group.userId.isEmpty else { return }
                    Haptics.light()
                    previewedUser = (group.userId, group.username)
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(group.isMe ? (group.username.isEmpty ? "You" : group.username) : group.username)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(group.isMe ? brandPurple : usernameColor(for: group.userId))
                        // Tap another user's name to open a profile preview
                        // (RR / W-L / Add Friend). Disabled for the current
                        // user's own name.
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard !group.isMe, !group.userId.isEmpty else { return }
                            Haptics.light()
                            previewedUser = (group.userId, group.username)
                        }
                    Text(timeString(group.messages.first?.createdAt ?? Date()))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.leading, 12)
                ForEach(Array(group.messages.enumerated()), id: \.element.id) { idx, message in
                    bubbleContent(message: message, isMe: group.isMe, position: bubblePosition(idx, count: group.messages.count))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
    }

    /// Deterministic per-user color so each sender's display name stays the
    /// same color across renders without needing a server-side mapping.
    /// GroupMe does the same trick on usernames.
    private func usernameColor(for userID: String) -> Color {
        let palette: [Color] = [
            Color(red: 0.32, green: 0.43, blue: 0.95),  // blue
            Color(red: 0.04, green: 0.55, blue: 0.35),  // green
            Color(red: 0.85, green: 0.40, blue: 0.05),  // orange
            Color(red: 0.65, green: 0.20, blue: 0.65),  // magenta
            Color(red: 0.10, green: 0.45, blue: 0.65),  // teal
            Color(red: 0.70, green: 0.10, blue: 0.25),  // crimson
            Color(red: 0.40, green: 0.30, blue: 0.05),  // brown
            Color(red: 0.20, green: 0.30, blue: 0.55)   // navy
        ]
        // Stable hash from the userID's UTF-8 bytes.
        var hash: UInt64 = 5381
        for byte in userID.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return palette[Int(hash % UInt64(palette.count))]
    }

    private enum BubblePosition { case single, top, middle, bottom }

    private func bubblePosition(_ idx: Int, count: Int) -> BubblePosition {
        if count == 1 { return .single }
        if idx == 0 { return .top }
        if idx == count - 1 { return .bottom }
        return .middle
    }

    private func bubbleContent(message: ChatMessageRecord, isMe: Bool, position: BubblePosition) -> some View {
        // Always-left-aligned layout, so every bubble uses the "incoming"
        // corner shape regardless of sender.
        let shape = bubbleShape(for: position, isMe: false)
        let bg: Color = isMe ? brandPurple.opacity(0.12) : Color(.systemGray6)
        return VStack(alignment: .leading, spacing: 0) {
            messageBody(message.body, isMe: false)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(bg)
                .clipShape(shape)
                .background(
                    // Publishes this bubble's global frame into the
                    // shared `bubbleFrames` dict so the long-press
                    // picker overlay can anchor near it.
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { bubbleFrames[message.id] = proxy.frame(in: .global) }
                            .onChange(of: proxy.frame(in: .global)) { _, newFrame in
                                bubbleFrames[message.id] = newFrame
                            }
                    }
                )
                // Double-tap is the well-known iMessage shortcut for
                // "thumbs up." Fires before the long-press has a chance
                // to engage (count: 2 has higher precedence).
                .onTapGesture(count: 2) {
                    Haptics.light()
                    guard let userId = auth.userID,
                          let token = auth.accessToken else { return }
                    Task {
                        await viewModel.toggleReaction(messageID: message.id, emoji: "👍", userID: userId, accessToken: token)
                    }
                }
                .onLongPressGesture(minimumDuration: 0.35) {
                    Haptics.medium()
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        reactionTargetMessageID = message.id
                    }
                }
            // Negative top offset pulls the chip rail up so the chips
            // overlap the bottom edge of the bubble — matches GroupMe.
            reactionChipRail(for: message)
                .offset(y: -8)
                .padding(.leading, 8)
        }
    }

    /// Standard emoji palette shown in the horizontal long-press picker.
    private static let reactionEmojis: [String] = ["👍", "❤️", "😂", "🔥", "😮", "😢", "🎉", "😍", "👀", "👏"]

    /// Floating iMessage-style horizontal picker anchored to the bubble
    /// the user long-pressed. Falls back to a centered position if the
    /// bubble frame hasn't been measured yet.
    private var reactionPickerOverlay: some View {
        GeometryReader { screen in
            // Picker height is ~64pt (emoji size + vertical padding).
            // We position it just above the targeted bubble. If the
            // bubble is too high to fit a picker above it, render below.
            let pickerHeight: CGFloat = 64
            let gap: CGFloat = 12
            let frame = reactionTargetMessageID.flatMap { bubbleFrames[$0] }
            let bubbleTop = frame?.minY ?? screen.size.height * 0.5
            let bubbleBottom = frame?.maxY ?? screen.size.height * 0.5
            let preferAbove = bubbleTop > pickerHeight + gap + 40 // 40 = nav bar safe area
            let yOrigin: CGFloat = preferAbove
                ? bubbleTop - pickerHeight - gap
                : bubbleBottom + gap
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(Self.reactionEmojis, id: \.self) { emoji in
                            Button {
                                Haptics.light()
                                guard let messageID = reactionTargetMessageID,
                                      let userId = auth.userID,
                                      let token = auth.accessToken else { return }
                                Task {
                                    await viewModel.toggleReaction(messageID: messageID, emoji: emoji, userID: userId, accessToken: token)
                                }
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                    reactionTargetMessageID = nil
                                }
                            } label: {
                                Text(emoji)
                                    .font(.system(size: 28))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                }
            }
            .background(.regularMaterial)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(.black.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
            .padding(.horizontal, 24)
            .position(x: screen.size.width / 2, y: yOrigin + pickerHeight / 2)
        }
    }

    /// Horizontal rail of reaction chips under a bubble. GroupMe-style:
    /// every reaction shows a count (even 1), modest rounding, a thicker
    /// outline, and the outline goes BLUE when the current user has
    /// reacted with that emoji.
    @ViewBuilder
    private func reactionChipRail(for message: ChatMessageRecord) -> some View {
        let reactions = viewModel.reactionsByMessageID[message.id] ?? []
        if !reactions.isEmpty {
            let grouped = Dictionary(grouping: reactions, by: \.emoji)
            let sorted = grouped.sorted(by: { $0.key < $1.key })
            HStack(spacing: 4) {
                ForEach(sorted, id: \.key) { emoji, items in
                    reactionChip(
                        emoji: emoji,
                        count: items.count,
                        isMine: items.contains(where: { $0.userId == auth.userID }),
                        messageID: message.id
                    )
                }
            }
        }
    }

    private func reactionChip(emoji: String, count: Int, isMine: Bool, messageID: String) -> some View {
        let reactedBlue = Color(red: 0.0, green: 0.48, blue: 1.0)
        return Button {
            Haptics.light()
            guard let userId = auth.userID,
                  let token = auth.accessToken else { return }
            Task {
                await viewModel.toggleReaction(messageID: messageID, emoji: emoji, userID: userId, accessToken: token)
            }
        } label: {
            HStack(spacing: 4) {
                Text(emoji)
                    .font(.system(size: 13))
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isMine ? reactedBlue : .secondary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.white)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isMine ? reactedBlue : Color(.systemGray3), lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    /// Per-position bubble shape that tightens internal corners when
    /// multiple bubbles stack from the same sender — gives the GroupMe
    /// "connected" look.
    private func bubbleShape(for position: BubblePosition, isMe: Bool) -> UnevenRoundedRectangle {
        let big: CGFloat = 16
        let small: CGFloat = 4
        switch position {
        case .single:
            return UnevenRoundedRectangle(cornerRadii: .init(topLeading: big, bottomLeading: big, bottomTrailing: big, topTrailing: big))
        case .top:
            return UnevenRoundedRectangle(cornerRadii: .init(
                topLeading: big,
                bottomLeading: isMe ? big : small,
                bottomTrailing: isMe ? small : big,
                topTrailing: big
            ))
        case .middle:
            return UnevenRoundedRectangle(cornerRadii: .init(
                topLeading: isMe ? big : small,
                bottomLeading: isMe ? big : small,
                bottomTrailing: isMe ? small : big,
                topTrailing: isMe ? small : big
            ))
        case .bottom:
            return UnevenRoundedRectangle(cornerRadii: .init(
                topLeading: isMe ? big : small,
                bottomLeading: big,
                bottomTrailing: big,
                topTrailing: isMe ? small : big
            ))
        }
    }

    /// Splits text into URLs vs plain runs and renders URLs as tappable
    /// styled links inline. AttributedString does the heavy lifting via
    /// NSDataDetector so we don't ship our own URL regex.
    @ViewBuilder
    private func messageBody(_ body: String, isMe: Bool) -> some View {
        if let attributed = try? AttributedString(markdown: linkifiedMarkdown(body)) {
            Text(attributed)
                .font(.subheadline)
                .foregroundStyle(isMe ? .white : .primary)
                .tint(isMe ? Color.white : brandPurple)
        } else {
            Text(body)
                .font(.subheadline)
                .foregroundStyle(isMe ? .white : .primary)
        }
    }

    /// Converts bare URLs in a string into Markdown links so AttributedString's
    /// markdown initializer styles them. Pre-escapes existing Markdown chars
    /// so user-typed brackets/parens don't accidentally become links.
    private func linkifiedMarkdown(_ body: String) -> String {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return body }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        let matches = detector.matches(in: body, options: [], range: range)
        guard !matches.isEmpty else { return escapedMarkdown(body) }
        var result = ""
        var cursor = body.startIndex
        for match in matches {
            guard let r = Range(match.range, in: body), let url = match.url else { continue }
            // Append any text between the previous URL and this one, escaped.
            result += escapedMarkdown(String(body[cursor..<r.lowerBound]))
            let visible = String(body[r])
            result += "[\(visible)](\(url.absoluteString))"
            cursor = r.upperBound
        }
        result += escapedMarkdown(String(body[cursor..<body.endIndex]))
        return result
    }

    private func escapedMarkdown(_ s: String) -> String {
        // Minimal escape — just the characters that Markdown actively parses.
        var out = s
        for ch in ["\\", "*", "_", "`", "[", "]"] {
            out = out.replacingOccurrences(of: ch, with: "\\\(ch)")
        }
        return out
    }

    /// Circular avatar — falls back to a colored disc with the username's
    /// first letter when no image URL is set or the image fails to load.
    private func avatarView(for username: String, urlString: String) -> some View {
        Group {
            if !urlString.isEmpty, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        avatarFallback(for: username)
                    }
                }
                .frame(width: 32, height: 32)
                .clipShape(Circle())
            } else {
                avatarFallback(for: username)
            }
        }
    }

    private func avatarFallback(for username: String) -> some View {
        ZStack {
            Circle().fill(brandPurple.opacity(0.85))
            Text(String(username.prefix(1)).uppercased())
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 32, height: 32)
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

// MARK: - Chat Profile Preview Sheet

/// Small bottom sheet shown when a user taps another user's name in a
/// chat bubble. Fetches the tapped user's profile (RR, W-L) and current
/// friendship state, then exposes an Add Friend / Added control.
struct ChatProfilePreviewSheet: View {
    let userId: String
    let fallbackUsername: String
    let avatarURL: String

    @EnvironmentObject private var auth: AuthViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var profile: DFSProfileRecord?
    @State private var friendshipID: String?
    @State private var isLoading: Bool = true
    @State private var isSendingRequest: Bool = false
    @State private var didSendRequest: Bool = false
    /// RR breakdown — fills in once the secondary fetch completes. nil
    /// while loading; the section shows shimmer/placeholder until then.
    @State private var pickemBreakdown: RRBreakdown?
    @State private var dfsBreakdown: RRBreakdown?
    @State private var isLoadingBreakdown: Bool = true

    private struct RRBreakdown {
        let gain: Int
        let loss: Int
        var net: Int { gain - loss }
    }

    private var brandPurple: Color {
        Color(red: 0.48, green: 0.23, blue: 0.93)
    }
    private var greenGain: Color {
        Color(red: 0.04, green: 0.55, blue: 0.35)
    }
    private var redLoss: Color {
        Color(red: 0.78, green: 0.18, blue: 0.18)
    }

    private var displayName: String {
        profile?.username ?? fallbackUsername
    }

    var body: some View {
        VStack(spacing: 14) {
            // Top padding pushed down so the sheet's drag indicator
            // sits in its own breathing room instead of crowding the
            // avatar.
            avatarHeader
                .padding(.top, 28)

            Text(displayName)
                .font(.title3.weight(.semibold))

            if isLoading {
                ProgressView()
                    .padding(.vertical, 4)
            } else {
                HStack(spacing: 14) {
                    statTile(title: "RR", value: "\(profile?.rrScore ?? 0)")
                    statTile(
                        title: "Record",
                        value: "\(profile?.wins ?? 0)-\(profile?.losses ?? 0)"
                    )
                }
            }

            rrBreakdownSection

            actionButton
                .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .task { await loadProfile() }
        .task { await loadBreakdown() }
    }

    private var avatarHeader: some View {
        Group {
            if let url = URL(string: avatarURL), !avatarURL.isEmpty {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    default:
                        avatarFallback
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(Circle())
            } else {
                avatarFallback
            }
        }
    }

    private var avatarFallback: some View {
        ZStack {
            Circle().fill(brandPurple.opacity(0.85))
            Text(String(displayName.prefix(1)).uppercased())
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
        }
        .frame(width: 64, height: 64)
    }

    private func statTile(title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline.monospacedDigit())
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
        }
        .frame(minWidth: 90)
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.systemGray5), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
    }

    @ViewBuilder
    private var rrBreakdownSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                rrSourceCard(
                    icon: "checkmark.circle.fill",
                    iconColor: brandPurple,
                    title: "Pick'em",
                    breakdown: pickemBreakdown
                )
                rrSourceCard(
                    icon: "trophy.fill",
                    iconColor: Color(red: 0.95, green: 0.70, blue: 0.10),
                    title: "DFS",
                    breakdown: dfsBreakdown
                )
            }
        }
        .padding(.top, 4)
    }

    private func rrSourceCard(icon: String, iconColor: Color, title: String, breakdown: RRBreakdown?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(iconColor)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                if let net = breakdown?.net {
                    Text(net >= 0 ? "+\(net)" : "\(net)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(net >= 0 ? greenGain : redLoss)
                } else if isLoadingBreakdown {
                    ProgressView().controlSize(.mini)
                }
            }
            HStack(spacing: 12) {
                deltaPair(
                    label: "Gained",
                    value: breakdown.map { "+\($0.gain)" },
                    color: greenGain
                )
                Divider().frame(height: 22)
                deltaPair(
                    label: "Lost",
                    value: breakdown.map { "-\($0.loss)" },
                    color: redLoss
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.systemGray5), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
    }

    private func deltaPair(label: String, value: String?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value ?? "—")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(value == nil ? Color.secondary : color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if userId == auth.userID {
            // Defensive — chat already gates the tap, but if somehow this
            // sheet opens for the current user, don't offer a friend
            // button for themselves.
            Text("This is you")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        } else if friendshipID != nil || didSendRequest {
            Label("Added", systemImage: "checkmark")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .background(Color(.systemGray5))
                .foregroundStyle(.secondary)
                .clipShape(Capsule())
        } else {
            Button {
                Task { await sendRequest() }
            } label: {
                HStack(spacing: 6) {
                    if isSendingRequest {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "person.badge.plus")
                    }
                    Text(isSendingRequest ? "Sending..." : "Add Friend")
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .background(brandPurple)
                .foregroundStyle(.white)
                .clipShape(Capsule())
            }
            .disabled(isSendingRequest || isLoading)
        }
    }

    private func loadProfile() async {
        guard let token = auth.accessToken else {
            isLoading = false
            return
        }
        async let profilesTask = SupabaseService.shared.fetchProfiles(userIDs: [userId], accessToken: token)
        let friendships: [FriendshipRecord]
        if let uid = auth.userID {
            friendships = (try? await SupabaseService.shared.fetchFriendships(userID: uid, accessToken: token)) ?? []
        } else {
            friendships = []
        }
        let profiles = (try? await profilesTask) ?? []
        profile = profiles.first
        friendshipID = friendships.first(where: {
            $0.requesterID == userId || $0.addresseeID == userId
        })?.id
        isLoading = false
    }

    /// Walk the user's settled Pickem picks and DFS tournament results,
    /// summing positive rr_deltas as "gain" and absolute negative deltas
    /// as "loss". Runs in parallel with the basic profile fetch so the
    /// header doesn't have to wait for this larger pull.
    private func loadBreakdown() async {
        defer { isLoadingBreakdown = false }
        guard let token = auth.accessToken else { return }
        async let picksTask = SupabaseService.shared.fetchSettledPicks(
            userID: userId, limit: 1000, offset: 0, accessToken: token
        )
        async let dfsTask = SupabaseService.shared.fetchUserDFSHistory(
            userID: userId, limit: 1000, offset: 0, accessToken: token
        )
        let picks = (try? await picksTask) ?? []
        let dfs = (try? await dfsTask) ?? []

        var pGain = 0, pLoss = 0
        for p in picks {
            if p.rrDelta >= 0 { pGain += p.rrDelta } else { pLoss += -p.rrDelta }
        }
        var dGain = 0, dLoss = 0
        for r in dfs {
            if r.rrDelta >= 0 { dGain += r.rrDelta } else { dLoss += -r.rrDelta }
        }
        pickemBreakdown = RRBreakdown(gain: pGain, loss: pLoss)
        dfsBreakdown = RRBreakdown(gain: dGain, loss: dLoss)
    }

    private func sendRequest() async {
        guard let uid = auth.userID, let token = auth.accessToken else { return }
        isSendingRequest = true
        defer { isSendingRequest = false }
        do {
            try await SupabaseService.shared.sendFriendRequest(
                fromUserID: uid, toUserID: userId, accessToken: token
            )
            didSendRequest = true
            Haptics.medium()
        } catch {
            // Surface failure silently for now — user can retry by tapping
            // the button again. Keeping this sheet lightweight on purpose.
        }
    }
}
