import SwiftUI

private let brandPurple = Color(red: 0.48, green: 0.23, blue: 0.93)

// MARK: - Lobby Section

/// "Private Contests" section that lives inside DFSLobbyView. Shows the user's
/// joined private contests with quick Create / Join With Code affordances.
struct DFSPrivateContestsSection: View {
    @Bindable var viewModel: DFSViewModel
    @State private var showCreate = false
    @State private var showJoin = false

    /// Only show private contests whose parent slate belongs to the current
    /// sport lobby AND the currently-displayed date. Without the date filter,
    /// yesterday's settled contests still appear in today's lobby because
    /// `myPrivateContests` is the user's full history. Parent tournament IDs
    /// follow the pattern "<sport>-<YYYYMMDD>-...".
    private var sportFilteredContests: [DFSPrivateContest] {
        let prefix = viewModel.sport.lowercased() + "-"
        return viewModel.myPrivateContests
            .filter { $0.parentTournamentID.hasPrefix(prefix) }
            .filter { viewModel.privateContestBelongsToCurrentSlate($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Private Contests")
                    .font(.headline)
                Spacer()
                Button {
                    showJoin = true
                } label: {
                    Label("Join", systemImage: "person.badge.plus")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(brandPurple)
                }
                Button {
                    showCreate = true
                } label: {
                    Label("Create", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(brandPurple)
                        .clipShape(Capsule())
                }
            }

            if sportFilteredContests.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.secondary)
                    Text("Create or join a private contest to play with friends — no bots.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(spacing: 0) {
                    ForEach(sportFilteredContests) { contest in
                        NavigationLink {
                            DFSPrivateContestDetailView(viewModel: viewModel, contest: contest)
                        } label: {
                            row(for: contest)
                        }
                        .buttonStyle(.plain)
                        if contest.id != sportFilteredContests.last?.id {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
            }
        }
        .sheet(isPresented: $showCreate) {
            DFSPrivateContestCreateSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showJoin) {
            DFSPrivateContestJoinSheet(viewModel: viewModel)
        }
        .task {
            await viewModel.loadMyPrivateContests()
        }
    }

    private func row(for contest: DFSPrivateContest) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(brandPurple.opacity(0.12))
                Image(systemName: "lock.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(brandPurple)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(contest.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Code \(contest.inviteCode) • \(parentLabel(for: contest))")
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

    private func parentLabel(for contest: DFSPrivateContest) -> String {
        if let t = viewModel.tournaments.first(where: { $0.id == contest.parentTournamentID }) {
            return t.title
        }
        return contest.parentTournamentID
    }
}

// MARK: - Create Sheet

struct DFSPrivateContestCreateSheet: View {
    @Bindable var viewModel: DFSViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var selectedTournamentID: String?
    @State private var createdContest: DFSPrivateContest?

    /// One tournament per slate identity. Public tournaments are generated per
    /// contest size (2/3/5/10/100/etc.) — we collapse them so the user picks
    /// the SLATE, not the size. For each slate we keep the largest-entry
    /// tournament as the canonical parent.
    private var eligibleTournaments: [DFSTournament] {
        let now = Date()
        let open = viewModel.tournaments.filter { t in
            viewModel.lockTimeForTournament(t) > now
        }
        var byIdentity: [String: DFSTournament] = [:]
        for t in open {
            let key = slateIdentity(t.id)
            if let existing = byIdentity[key] {
                if t.entryCount > existing.entryCount {
                    byIdentity[key] = t
                }
            } else {
                byIdentity[key] = t
            }
        }
        // Stable order: by lock time, then by title
        return byIdentity.values.sorted { lhs, rhs in
            let lt = viewModel.lockTimeForTournament(lhs)
            let rt = viewModel.lockTimeForTournament(rhs)
            if lt != rt { return lt < rt }
            return lhs.title < rhs.title
        }
    }

    private func slateIdentity(_ tournamentID: String) -> String {
        var id = tournamentID
        if let r = id.range(of: #"-i\d+$"#, options: .regularExpression) {
            id.removeSubrange(r)
        }
        let parts = id.components(separatedBy: "-")
        if let last = parts.last, let n = Int(last),
           [2, 3, 5, 10, 100, 500, 1000, 2000].contains(n) {
            return parts.dropLast().joined(separator: "-")
        }
        return id
    }

    var body: some View {
        NavigationStack {
            if let contest = createdContest {
                createdSuccessView(contest: contest)
            } else {
                createForm
            }
        }
    }

    private var createForm: some View {
        Form {
            Section("Contest Name") {
                TextField("e.g. Tuesday Night NBA", text: $name)
                    .textInputAutocapitalization(.words)
            }
            Section("Slate") {
                if eligibleTournaments.isEmpty {
                    Text("No open slates available right now.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Parent slate", selection: $selectedTournamentID) {
                        Text("Select a slate").tag(String?.none)
                        ForEach(eligibleTournaments, id: \.id) { t in
                            Text(t.title).tag(Optional(t.id))
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
            }
            Section {
                Text("Members will submit their normal DFS lineup to this slate. The private leaderboard shows only members — no bots.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let err = viewModel.privateContestError {
                Section { Text(err).font(.caption).foregroundStyle(.red) }
            }
        }
        .navigationTitle("New Private Contest")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await create() }
                } label: {
                    if viewModel.isCreatingPrivateContest {
                        ProgressView()
                    } else {
                        Text("Create")
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                          || selectedTournamentID == nil
                          || viewModel.isCreatingPrivateContest)
            }
        }
    }

    private func create() async {
        guard let parentID = selectedTournamentID else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let contest = await viewModel.createPrivateContest(parentTournamentID: parentID, name: trimmed) {
            createdContest = contest
        }
    }

    private func createdSuccessView(contest: DFSPrivateContest) -> some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(brandPurple)
            Text("Contest created")
                .font(.title2.weight(.bold))
            Text(contest.name)
                .font(.headline)
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                Text("INVITE CODE")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(contest.inviteCode)
                    .font(.system(size: 32, weight: .heavy, design: .monospaced))
                    .kerning(4)
                    .foregroundStyle(brandPurple)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 20)
            .background(brandPurple.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 16))

            Button {
                UIPasteboard.general.string = contest.inviteCode
            } label: {
                Label("Copy Code", systemImage: "doc.on.doc")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .tint(brandPurple)

            Text("Share this code with friends. They can join from the DFS lobby.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()
            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(brandPurple)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .navigationBarBackButtonHidden()
    }
}

// MARK: - Join Sheet

struct DFSPrivateContestJoinSheet: View {
    @Bindable var viewModel: DFSViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var code: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Invite Code") {
                    TextField("e.g. K3X9PQ", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(.title2, design: .monospaced))
                        .kerning(4)
                        .onChange(of: code) { _, newValue in
                            // Normalize: uppercase + strip non-alphanum, cap at 6
                            let cleaned = newValue.uppercased().filter { $0.isLetter || $0.isNumber }
                            code = String(cleaned.prefix(6))
                        }
                }
                Section {
                    Text("Ask the contest creator for the 6-character invite code.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let err = viewModel.privateContestError {
                    Section { Text(err).font(.caption).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Join Private Contest")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            if await viewModel.joinPrivateContestByCode(code) != nil {
                                dismiss()
                            }
                        }
                    } label: {
                        if viewModel.isJoiningPrivateContest {
                            ProgressView()
                        } else {
                            Text("Join")
                        }
                    }
                    .disabled(code.count < 4 || viewModel.isJoiningPrivateContest)
                }
            }
        }
    }
}

// MARK: - Detail View

struct DFSPrivateContestDetailView: View {
    @Bindable var viewModel: DFSViewModel
    let contest: DFSPrivateContest
    @State private var copyConfirmation = false
    @State private var showLeaveConfirm = false

    private var parentTournament: DFSTournament? {
        viewModel.tournaments.first(where: { $0.id == contest.parentTournamentID })
    }

    private var members: [DFSPrivateContestMember] {
        viewModel.privateContestMembers[contest.id] ?? []
    }

    private var leaderboard: [DFSPrivateContestLeaderboardRow] {
        viewModel.privateContestLeaderboards[contest.id] ?? []
    }

    private var entries: [DFSPrivateContestEntry] {
        viewModel.privateContestEntries[contest.id] ?? []
    }

    private var isOwner: Bool {
        viewModel.userID.flatMap { UUID(uuidString: $0) } == contest.createdBy
    }

    private var currentUserHasSubmitted: Bool {
        guard let uidStr = viewModel.userID, let uid = UUID(uuidString: uidStr) else { return false }
        return entries.contains(where: { $0.userID == uid })
    }

    /// True when the contest's parent slate has locked OR is a past slate
    /// entirely. A past contest must read as locked so we don't surface the
    /// Edit Lineup affordance — the games already played; the result is final.
    private var isLocked: Bool {
        // Past contest (parent date != today's slate date) → always locked.
        if !viewModel.privateContestBelongsToCurrentSlate(contest) { return true }
        // Otherwise fall back to the parent tournament's lock time. If the
        // parent isn't loaded for some reason, assume not locked so the user
        // can still try to enter for the current slate.
        guard let t = parentTournament else { return false }
        return viewModel.lockTimeForTournament(t) <= Date()
    }

    /// Whether this contest's parent slate's day has already passed. Used to
    /// distinguish "locked but in-progress" from "completed and historical".
    private var isPastContest: Bool {
        !viewModel.privateContestBelongsToCurrentSlate(contest)
    }

    /// Human-friendly label derived from the parent tournament ID — used as a
    /// fallback when the actual `parentTournament` object isn't loaded (e.g.
    /// past contests whose slate has rotated out of memory). Returns something
    /// like "Single Game · May 28, 2026" instead of "nba-20260528-sg-...".
    private var parentSlateDateLabel: String? {
        let id = contest.parentTournamentID
        let parts = id.split(separator: "-")
        guard let dateStr = parts.first(where: { $0.count == 8 && Int($0) != nil }) else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        guard let date = fmt.date(from: String(dateStr)) else { return nil }
        let isSG = id.contains("-sg-")
        let kind = isSG ? "Single Game" : "Main Slate"
        return "\(kind) · \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Past contests collapse to just the standings — invite code,
                // members, and lineup-submission UI all become noise once the
                // games are done. Today's contests still show the full layout.
                if isPastContest {
                    pastContestHeader
                } else {
                    headerCard
                    enterLineupCard
                    membersCard
                }
                leaderboardCard
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.94, green: 0.98, blue: 0.95),
                    Color(red: 0.98, green: 0.99, blue: 1.00)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        .navigationTitle(contest.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Hide the Delete / Leave menu once the parent slate has locked —
            // once games start, the contest can't be modified (results are
            // forming in real time) and there's nothing to leave after the
            // games already played.
            if !isLocked {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if isOwner {
                            Button(role: .destructive) {
                                showLeaveConfirm = true
                            } label: {
                                Label("Delete Contest", systemImage: "trash")
                            }
                        } else {
                            Button(role: .destructive) {
                                showLeaveConfirm = true
                            } label: {
                                Label("Leave Contest", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .task {
            // For a past contest, fetch the parent slate's box scores AND
            // canonical salary snapshot BEFORE building the leaderboard so
            // the standings show real FPTS and the roster sheet shows the
            // same prices the public contest used (no drift).
            if isPastContest {
                async let box: Void = viewModel.loadPastTournamentBoxScores(tournamentId: contest.parentTournamentID)
                async let sals: Void = viewModel.loadParentTournamentSalariesIfNeeded(parentTournamentID: contest.parentTournamentID)
                _ = await (box, sals)
            }
            await viewModel.loadPrivateContestMembers(contestID: contest.id)
            await viewModel.loadPrivateContestLeaderboard(contest)
        }
        .refreshable {
            if isPastContest {
                async let box: Void = viewModel.loadPastTournamentBoxScores(tournamentId: contest.parentTournamentID)
                async let sals: Void = viewModel.loadParentTournamentSalariesIfNeeded(parentTournamentID: contest.parentTournamentID)
                _ = await (box, sals)
            }
            await viewModel.loadPrivateContestMembers(contestID: contest.id)
            await viewModel.loadPrivateContestLeaderboard(contest)
        }
        .confirmationDialog(
            isOwner ? "Delete this contest?" : "Leave this contest?",
            isPresented: $showLeaveConfirm,
            titleVisibility: .visible
        ) {
            Button(isOwner ? "Delete" : "Leave", role: .destructive) {
                Task {
                    if isOwner {
                        await viewModel.deletePrivateContest(contest)
                    } else {
                        await viewModel.leavePrivateContest(contest)
                    }
                }
            }
            Button("Cancel", role: .cancel) { }
        }
    }

    /// Minimal header for past contests — just the slate name/date so the
    /// user has context for which day's results they're looking at, without
    /// the full purple invite-code card.
    private var pastContestHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(brandPurple)
                .font(.caption)
            Text(parentTournament?.title ?? parentSlateDateLabel ?? "Final Standings")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.white)
                Text("PRIVATE CONTEST")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
            }

            // Human-friendly slate description. When the parent tournament is
            // loaded, use its title (e.g. "OKC @ SA"). For past contests where
            // the parent isn't in memory anymore, fall back to a date-only
            // label instead of the raw "nba-20260528-sg-..." ID — that's noise
            // for users.
            if let t = parentTournament {
                Text(t.title)
                    .font(.headline)
                    .foregroundStyle(.white)
            } else if let dateLabel = parentSlateDateLabel {
                Text(dateLabel)
                    .font(.headline)
                    .foregroundStyle(.white)
            }

            // Invite code only matters before lock — once the slate locks, no
            // new members can join, so showing the code in history just adds
            // visual noise and can confuse users about whether the contest is
            // still joinable.
            if !isLocked {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("INVITE CODE")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.7))
                        Text(contest.inviteCode)
                            .font(.system(.title2, design: .monospaced).weight(.bold))
                            .kerning(3)
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    Button {
                        UIPasteboard.general.string = contest.inviteCode
                        copyConfirmation = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            copyConfirmation = false
                        }
                    } label: {
                        Label(copyConfirmation ? "Copied" : "Copy", systemImage: copyConfirmation ? "checkmark" : "doc.on.doc")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.white.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [brandPurple, Color(red: 0.30, green: 0.10, blue: 0.65)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: brandPurple.opacity(0.25), radius: 12, y: 6)
    }

    private var enterLineupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: currentUserHasSubmitted ? "checkmark.seal.fill" : "person.crop.rectangle.stack")
                    .foregroundStyle(currentUserHasSubmitted ? Color.green : brandPurple)
                Text(currentUserHasSubmitted ? "Lineup Submitted" : "Your Lineup")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if isLocked {
                    Text("LOCKED")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary)
                        .clipShape(Capsule())
                }
            }
            if currentUserHasSubmitted {
                Text("You're in. Standings will update as the slate plays out.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !isLocked {
                    Button {
                        viewModel.startPrivateContestLineup(contest)
                    } label: {
                        Text("Edit Lineup")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(brandPurple.opacity(0.12))
                            .foregroundStyle(brandPurple)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            } else if isLocked {
                Text("This slate has already locked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if parentTournament == nil {
                Text("Parent slate not loaded yet. Pull to refresh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Submit your lineup to compete in this contest.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    viewModel.startPrivateContestLineup(contest)
                } label: {
                    Label("Enter Lineup", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(brandPurple)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
    }

    private var membersCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Members")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(members.count) / \(contest.maxMembers)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if members.isEmpty {
                Text("No members yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(members) { member in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(brandPurple.opacity(0.15))
                                .frame(width: 24, height: 24)
                                .overlay(
                                    Text(member.displayName.prefix(1).uppercased())
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(brandPurple)
                                )
                            Text(member.displayName)
                                .font(.caption)
                            if member.userID == contest.createdBy {
                                Text("Host")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(brandPurple)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(brandPurple.opacity(0.12))
                                    .clipShape(Capsule())
                            }
                            Spacer()
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
    }

    private var leaderboardCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Standings")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let t = parentTournament, viewModel.tournament?.id == t.id, !viewModel.livePlayerPoints.isEmpty {
                    Text("LIVE")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red)
                        .clipShape(Capsule())
                }
            }
            if leaderboard.isEmpty {
                Text("Standings will populate once members submit lineups to the parent slate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(leaderboard.enumerated()), id: \.element.id) { idx, row in
                        // Only allow expanding to see picks if either:
                        //  - the slate has locked (everyone's locked in, fair to reveal), OR
                        //  - it's the current user's own row (you can always see your own).
                        // Otherwise show a static row — peeking at other people's
                        // lineups before lock would let users copy them.
                        let canRevealLineup = isLocked || row.isCurrentUser
                        if row.hasSubmitted && canRevealLineup {
                            DisclosureGroup {
                                inlineLineupRows(for: row)
                                    .padding(.top, 6)
                            } label: {
                                leaderboardRow(row)
                                    .contentShape(Rectangle())
                            }
                            .tint(.primary)
                        } else {
                            leaderboardRow(row)
                        }
                        if idx < leaderboard.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
    }

    /// Inline per-player lineup rows used by the expandable Standings rows.
    /// Replaces the old modal sheet — keeps everything on a single screen.
    @ViewBuilder
    private func inlineLineupRows(for row: DFSPrivateContestLeaderboardRow) -> some View {
        // Detect single-game from the parent ID so MVP shows even on past
        // contests where the in-memory parentTournament is no longer loaded.
        let isSG = (parentTournament?.isSingleGame) ?? contest.parentTournamentID.contains("-sg-")
        let rawPool: [DFSPlayer] = {
            if isSG, let gid = parentTournament?.gameID,
               let sgPool = viewModel.singleGamePlayers[gid] {
                return sgPool
            }
            return viewModel.players
        }()
        let canonical = viewModel.tournamentPlayerSalaries[contest.parentTournamentID] ?? [:]
        let pool: [DFSPlayer] = canonical.isEmpty ? rawPool : rawPool.map { p in
            guard let drafted = canonical[p.id], drafted > 0, drafted != p.salary else { return p }
            var fixed = DFSPlayer(
                id: p.id, name: p.name, team: p.team, position: p.position,
                salary: drafted, projectedPoints: p.projectedPoints,
                gameID: p.gameID, injuryStatus: p.injuryStatus,
                battingOrder: p.battingOrder
            )
            fixed.gamesPlayed = p.gamesPlayed
            fixed.playedRecently = p.playedRecently
            fixed.isConfirmedActive = p.isConfirmedActive
            fixed.isStartingGoalie = p.isStartingGoalie
            return fixed
        }
        let byID = Dictionary(uniqueKeysWithValues: pool.map { ($0.id, $0) })

        VStack(spacing: 4) {
            ForEach(Array(row.lineupPlayerIDs.enumerated()), id: \.element) { idx, pid in
                let player = byID[pid]
                let isMVP = isSG && idx == 0
                let rawPts: Double = {
                    if let p = viewModel.livePlayerPoints[pid], p > 0 { return p }
                    return viewModel.pastTournamentPlayerStats[pid]?.fantasyPoints ?? 0
                }()
                let displayPts = isMVP ? rawPts * 1.5 : rawPts
                let displaySalary: Int = {
                    let baseSal = player?.salary ?? 0
                    return isMVP ? Int(Double(baseSal) * 1.5) : baseSal
                }()
                HStack(spacing: 10) {
                    Text(isMVP ? "MVP" : (player?.position ?? "—"))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(isMVP ? .black : .white)
                        .frame(width: 32, height: 22)
                        .background(isMVP ? Color.yellow : brandPurple)
                        .clipShape(Capsule())
                    VStack(alignment: .leading, spacing: 1) {
                        let resolvedName: String = {
                            if let p = player, !p.name.isEmpty,
                               !["nba-", "pga-", "ncaam-", "mlb-", "nhl-", "epl-", "ucl-", "wc-", "ufc-", "cfb-", "nfl-"]
                                .contains(where: { p.name.hasPrefix($0) }) {
                                return p.name
                            }
                            return viewModel.cachedPlayerName(for: pid) ?? "Loading…"
                        }()
                        Text(resolvedName)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        if displaySalary > 0 {
                            Text("$\(viewModel.formatSalary(displaySalary))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(String(format: "%.1f", displayPts))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(displayPts > 0 ? brandPurple : .secondary)
                }
                .padding(.vertical, 3)
                if idx < row.lineupPlayerIDs.count - 1 {
                    Divider()
                }
            }
        }
    }

    private func rankColor(for row: DFSPrivateContestLeaderboardRow) -> Color {
        guard row.hasSubmitted else { return Color.secondary.opacity(0.5) }
        return row.rank <= 3 ? Color(red: 0.95, green: 0.78, blue: 0.20) : .secondary
    }

    private func leaderboardRow(_ row: DFSPrivateContestLeaderboardRow) -> some View {
        HStack(spacing: 10) {
            Text(row.hasSubmitted ? "\(row.rank)" : "—")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(rankColor(for: row))
                .frame(width: 24, alignment: .leading)
            Text(row.displayName)
                .font(.subheadline.weight(row.isCurrentUser ? .semibold : .regular))
                .foregroundStyle(row.isCurrentUser ? brandPurple : .primary)
                .lineLimit(1)
            Spacer()
            if row.hasSubmitted {
                Text(String(format: "%.1f", row.points))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
            } else {
                Text("No lineup")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 8)
    }
}
