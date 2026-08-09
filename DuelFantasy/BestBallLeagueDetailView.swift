import SwiftUI

struct BestBallLeagueDetailView: View {
    @Bindable var viewModel: BestBallViewModel
    let leagueID: String
    @EnvironmentObject private var auth: AuthViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: LeagueTab = .standings
    @State private var selectedMatchup: BestBallMatchup? = nil
    @State private var settingsLeague: BestBallLeague? = nil  // non-nil triggers sheet

    enum LeagueTab: String, CaseIterable {
        case standings = "Standings"
        case myTeam = "My Team"
        case myMatchup = "Matchup"

        static func tabs(for league: BestBallLeague?) -> [LeagueTab] {
            if league?.isDingersOnly == true {
                return [.standings, .myTeam]
            }
            return allCases
        }
    }

    private var brandPurple: Color {
        Color(red: 0.48, green: 0.23, blue: 0.93)
    }

    private var league: BestBallLeague? { viewModel.currentLeague }

    @State private var hasTriggeredCatchUp = false

    var body: some View {
        Group {
            if let league {
                switch league.status {
                case "open":
                    openLeagueContent(league)
                case "drafting":
                    BestBallDraftView(viewModel: viewModel)
                case "active", "completed":
                    activeLeagueContent
                default:
                    Text("Unknown status")
                }
            } else if viewModel.isLoading {
                ProgressView()
            } else {
                Text("League not found")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(league?.title ?? "League")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let league {
                ToolbarItem(placement: .topBarTrailing) {
                    Text(league.entryFee > 0 ? "\(league.entryFee) RR" : "FREE")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.12))
                        .foregroundStyle(Color(red: 0.1, green: 0.55, blue: 0.25))
                        .clipShape(Capsule())
                }
            }
            if let league, league.status == "open", viewModel.isCommish {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.light()
                        settingsLeague = league
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
        .sheet(item: $settingsLeague) { leagueSnapshot in
            CommishSettingsSheet(
                league: leagueSnapshot,
                viewModel: viewModel,
                leagueID: leagueID,
                onDismiss: { settingsLeague = nil }
            )
        }
        .task {
            await viewModel.loadLeagueDetail(leagueID: leagueID)
            // Auto-catch-up on initial load for ANY member opening the
            // league. `catchUpScoring` already skips weeks that are
            // fully scored, and `batchUpsertWeeklyScores` is idempotent
            // on conflict — so opening the door beyond just the host
            // means a member who joined mid-week sees correct standings
            // without waiting for the host to log in. Race against
            // another member triggering the same compute is acceptable:
            // both writes converge on the same values via upsert.
            if viewModel.currentLeague?.status == "active",
               !isCatchingUp, !hasTriggeredCatchUp {
                hasTriggeredCatchUp = true
                isCatchingUp = true
                await viewModel.catchUpScoring(leagueID: leagueID)
                isCatchingUp = false
            }
            // Lobby polling: while the league is still open, keep
            // refreshing so every member's screen flips into the draft
            // the moment the host starts it — previously non-hosts sat
            // on "Waiting for host..." until they backed out and
            // re-entered the league.
            await viewModel.autoStartScheduledDraftIfDue()
            while !Task.isCancelled,
                  viewModel.currentLeague?.id == leagueID,
                  viewModel.currentLeague?.status == "open" {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { break }
                await viewModel.loadLeagueDetail(leagueID: leagueID)
                await viewModel.autoStartScheduledDraftIfDue()
            }
        }
    }

    // MARK: - Active League Content (Tabs)

    @State private var isCatchingUp = false

    private var activeLeagueContent: some View {
        VStack(spacing: 0) {
            // Catch-up scoring runs silently in the background — the old
            // purple "Scoring past weeks..." banner on every league open
            // read as a loading screen. The Standings refresh button still
            // shows inline progress for user-triggered scoring.

            // Segmented control
            Picker("Tab", selection: $selectedTab) {
                ForEach(LeagueTab.tabs(for: viewModel.currentLeague), id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .onChange(of: selectedTab) { _, newTab in
                if newTab != .myMatchup {
                    selectedMatchup = nil
                }
            }

            switch selectedTab {
            case .standings:
                BestBallStandingsView(viewModel: viewModel, leagueID: leagueID) { matchup in
                    selectedMatchup = matchup
                    selectedTab = .myMatchup
                }
            case .myTeam:
                if let myID = viewModel.myMemberID {
                    BestBallRosterView(viewModel: viewModel, memberID: myID)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "person.crop.rectangle.stack")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Team not found")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 60)
                }
            case .myMatchup:
                if let matchup = selectedMatchup ?? viewModel.myMatchup {
                    BestBallMatchupView(viewModel: viewModel, initialMatchup: matchup)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "sportscourt")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No matchup found")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Waiting for scores to compute...")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 60)
                }
            }
        }
        .onChange(of: viewModel.currentLeague?.status) {
            // Trigger auto-catchup when status transitions to "active"
            guard viewModel.currentLeague?.status == "active", viewModel.isHost,
                  !isCatchingUp, !hasTriggeredCatchUp else { return }
            hasTriggeredCatchUp = true
            isCatchingUp = true
            Task {
                await viewModel.catchUpScoring(leagueID: leagueID)
                isCatchingUp = false
            }
        }
    }

    // MARK: - Open League Content

    private func openLeagueContent(_ league: BestBallLeague) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                // League info card
                VStack(spacing: 12) {
                    HStack {
                        Label(league.sport, systemImage: sportIcon(league.sport))
                            .font(.headline)
                        if league.isDingersOnly {
                            Text("DINGERS ONLY")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.orange.opacity(0.15))
                                .foregroundStyle(.orange)
                                .clipShape(Capsule())
                        }
                        Spacer()
                        Text(league.season)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    HStack {
                        VStack(spacing: 4) {
                            Text("\(viewModel.currentMembers.count)")
                                .font(.title2.weight(.bold))
                            Text("Joined")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)

                        Divider().frame(height: 40)

                        VStack(spacing: 4) {
                            Text("\(league.maxMembers - viewModel.currentMembers.count)")
                                .font(.title2.weight(.bold))
                            Text("Open Spots")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)

                        Divider().frame(height: 40)

                        VStack(spacing: 4) {
                            Text("\(league.rosterSize)")
                                .font(.title2.weight(.bold))
                            Text("Roster Size")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    // Scoring starters info
                    Divider()
                    HStack {
                        if league.sport == "MLB" && !league.isDingersOnly {
                            VStack(spacing: 4) {
                                Text("\(league.pitcherSlots)")
                                    .font(.title2.weight(.bold))
                                Text("Pitchers")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)

                            Divider().frame(height: 40)

                            VStack(spacing: 4) {
                                Text("\(league.batterSlots)")
                                    .font(.title2.weight(.bold))
                                Text("Batters")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)

                            Divider().frame(height: 40)
                        }

                        VStack(spacing: 4) {
                            // Derive from the league's actual lineup config —
                            // reading pitcher+batter slots showed NFL/CFB
                            // leagues a hardcoded 8 regardless of their
                            // configured QB/RB/WR/TE/FLEX/SFLEX total.
                            Text("\(BestBallLineupConfig.requirements(for: league).starters)")
                                .font(.title2.weight(.bold))
                                .foregroundStyle(brandPurple)
                            Text(league.isDingersOnly ? "Batters" : "Starters")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    // Invite code for private leagues
                    if league.isPrivate, let code = league.inviteCode {
                        Divider()
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Invite Code")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(code)
                                    .font(.title3.weight(.bold).monospaced())
                            }
                            Spacer()
                            Button {
                                Haptics.light()
                                UIPasteboard.general.string = code
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                                    .font(.caption.weight(.medium))
                            }
                            .buttonStyle(.bordered)
                            .tint(brandPurple)
                            ShareLink(item: league.shareMessage(code: code)) {
                                Label("Share", systemImage: "square.and.arrow.up")
                                    .font(.caption.weight(.medium))
                            }
                            .buttonStyle(.bordered)
                            .tint(brandPurple)
                        }
                    }
                }
                .padding(16)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.06), radius: 8, y: 4)

                // Members list
                VStack(alignment: .leading, spacing: 10) {
                    Text("Members")
                        .font(.headline)

                    ForEach(viewModel.currentMembers) { member in
                        HStack {
                            Image(systemName: member.isBot ? "cpu" : "person.fill")
                                .font(.caption)
                                .foregroundStyle(member.isBot ? .orange : brandPurple)
                                .frame(width: 24)
                            Text(member.displayName)
                                .font(.subheadline)
                            if member.userID == auth.userID {
                                Text("(You)")
                                    .font(.caption)
                                    .foregroundStyle(brandPurple)
                            }
                            Spacer()
                            Text("Slot \(member.slotIndex + 1)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }

                    // Empty slots
                    let filledSlots = viewModel.currentMembers.count
                    if filledSlots < league.maxMembers {
                        ForEach(filledSlots..<league.maxMembers, id: \.self) { i in
                            HStack {
                                Image(systemName: "person.badge.plus")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)
                                Text("Open Slot \(i + 1)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .padding(16)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.06), radius: 8, y: 4)

                // Scheduled draft banner — live per-second countdown once
                // the start is under 2 minutes away.
                if let scheduled = league.draftStartTime {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = Int(scheduled.timeIntervalSince(context.date).rounded(.up))
                        HStack(spacing: 10) {
                            Image(systemName: "clock.fill")
                                .font(.subheadline)
                            VStack(alignment: .leading, spacing: 2) {
                                if remaining <= 0 {
                                    Text("Draft is starting…")
                                        .font(.subheadline.weight(.heavy))
                                } else if remaining <= 120 {
                                    Text("DRAFT STARTING IN")
                                        .font(.caption2.weight(.bold))
                                        .tracking(0.5)
                                    Text("\(remaining)s")
                                        .font(.title2.weight(.heavy).monospacedDigit())
                                } else {
                                    Text("Draft scheduled")
                                        .font(.caption.weight(.bold))
                                    Text(scheduled.formatted(date: .abbreviated, time: .shortened))
                                        .font(.subheadline.weight(.semibold))
                                }
                            }
                            Spacer()
                        }
                        .foregroundStyle(remaining <= 120 ? Color.orange : brandPurple)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background((remaining <= 120 ? Color.orange : brandPurple).opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }

                // Action buttons
                let isMember = viewModel.currentMembers.contains(where: { $0.userID == auth.userID })

                if !isMember {
                    Button {
                        Haptics.medium()
                        Task { _ = await viewModel.joinLeague(league) }
                    } label: {
                        Text("Join League")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(brandPurple)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                } else if viewModel.isHost {
                    Button {
                        Haptics.medium()
                        Task { await viewModel.startDraft(leagueID: league.id) }
                    } label: {
                        VStack(spacing: 4) {
                            if viewModel.isStartingDraft {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .tint(.white)
                                    Text("Starting Draft…")
                                        .font(.headline)
                                }
                                Text("Filling empty slots with bots and loading player pool")
                                    .font(.caption)
                                    .opacity(0.8)
                            } else {
                                Text("Start Draft")
                                    .font(.headline)
                                Text("Bots fill empty slots · 30s countdown before pick 1")
                                    .font(.caption)
                                    .opacity(0.8)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(brandPurple)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(viewModel.isStartingDraft)
                } else {
                    Text("Waiting for host to start draft...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)

                    // Allow leaving the league before the draft starts.
                    if league.status == "open" {
                        Button {
                            Haptics.medium()
                            Task {
                                if await viewModel.leaveLeague(league) {
                                    dismiss()
                                }
                            }
                        } label: {
                            Text("Leave League")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .foregroundStyle(.red)
                                .background(Color.red.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }

                if let error = viewModel.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(16)
        }
    }

    private func sportIcon(_ sport: String) -> String {
        switch sport {
        case "NBA": return "basketball"
        case "MLB": return "baseball"
        case "NFL", "CFB": return "football"
        case "EPL": return "soccerball"
        default: return "sportscourt"
        }
    }

}

extension BestBallLeague {
    /// Pre-filled share message for the system share sheet. The invite
    /// code is the actionable bit; we wrap it in friendly copy so a
    /// recipient pasting from Messages/WhatsApp/etc. sees context, not
    /// just a code blob.
    func shareMessage(code: String) -> String {
        "Join my Best Ball league \"\(title)\" on DuelFantasy — invite code: \(code)"
    }
}

// MARK: - Commissioner Settings Sheet (standalone view so @State initializes from league)

private struct CommishSettingsSheet: View {
    let league: BestBallLeague
    @Bindable var viewModel: BestBallViewModel
    let leagueID: String
    let onDismiss: () -> Void

    @State private var editTitle: String
    @State private var editMaxMembers: Int
    @State private var editRosterSize: Int
    @State private var editIsPrivate: Bool
    @State private var editPitcherSlots: Int
    @State private var editBatterSlots: Int
    @State private var editNflQB: Int
    @State private var editNflRB: Int
    @State private var editNflWR: Int
    @State private var editNflTE: Int
    @State private var editNflFLEX: Int
    @State private var editNflSFLEX: Int
    @State private var editEplGK: Int
    @State private var editEplDEF: Int
    @State private var editEplMID: Int
    @State private var editEplFWD: Int
    @State private var editEplFLEX: Int
    @State private var isSavingSettings: Bool = false
    @State private var showDeleteConfirmation: Bool = false
    @State private var isDeletingLeague: Bool = false
    @State private var editScheduleDraft: Bool
    @State private var editDraftDate: Date

    private var brandPurple: Color {
        Color(red: 0.48, green: 0.23, blue: 0.93)
    }

    /// True only when this user created the league AND no other human
    /// has joined — the "solo open league" state. Once someone else
    /// signs up, deletion is hidden because tearing the league down
    /// would silently strand other players.
    private var canDeleteLeague: Bool {
        guard let uid = viewModel.userID, league.createdBy == uid else { return false }
        let humans = viewModel.currentMembers.filter { !$0.isBot }
        return humans.count <= 1 && humans.allSatisfy { $0.userID == uid }
    }

    init(league: BestBallLeague, viewModel: BestBallViewModel, leagueID: String, onDismiss: @escaping () -> Void) {
        self.league = league
        self.viewModel = viewModel
        self.leagueID = leagueID
        self.onDismiss = onDismiss
        _editTitle = State(initialValue: league.title)
        _editMaxMembers = State(initialValue: league.maxMembers)
        _editRosterSize = State(initialValue: league.rosterSize)
        _editIsPrivate = State(initialValue: league.isPrivate)
        _editPitcherSlots = State(initialValue: league.pitcherSlots)
        _editBatterSlots = State(initialValue: league.batterSlots)
        _editNflQB = State(initialValue: league.nflQbStarters)
        _editNflRB = State(initialValue: league.nflRbStarters)
        _editNflWR = State(initialValue: league.nflWrStarters)
        _editNflTE = State(initialValue: league.nflTeStarters)
        _editNflFLEX = State(initialValue: league.nflFlexStarters)
        _editNflSFLEX = State(initialValue: league.nflSflexStarters)
        _editEplGK = State(initialValue: league.eplGkStarters ?? 1)
        _editEplDEF = State(initialValue: league.eplDefStarters ?? 3)
        _editEplMID = State(initialValue: league.eplMidStarters ?? 4)
        _editEplFWD = State(initialValue: league.eplFwdStarters ?? 2)
        _editEplFLEX = State(initialValue: league.eplFlexStarters ?? 1)
        _editScheduleDraft = State(initialValue: league.draftStartTime != nil)
        _editDraftDate = State(initialValue: league.draftStartTime ?? Date().addingTimeInterval(3600))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Header
                    VStack(spacing: 4) {
                        Text(league.sport)
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(brandPurple.opacity(0.15))
                            .foregroundStyle(brandPurple)
                            .clipShape(Capsule())
                        Text(league.season)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)

                    // League Info card
                    settingsCard(title: "League Info") {
                        VStack(spacing: 14) {
                            HStack {
                                Text("League Name")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                TextField("League Name", text: $editTitle)
                                    .font(.subheadline)
                                    .multilineTextAlignment(.trailing)
                                    .frame(maxWidth: 180)
                            }
                            Divider()
                            HStack {
                                Text("League Size")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Stepper("\(editMaxMembers)", value: $editMaxMembers, in: max(viewModel.currentMembers.count, 4)...16, step: 2)
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: 140)
                            }
                            Divider()
                            HStack {
                                Text("Roster Size")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                // Sport-aware floor: the roster can never be
                                // smaller than the configured starting lineup
                                // (the old MLB-only min let an NFL/CFB league
                                // set roster 8 under a 9-man lineup).
                                let minRoster: Int = {
                                    if league.sport == "NFL" || league.sport == "CFB" {
                                        return editNflQB + editNflRB + editNflWR + editNflTE + editNflFLEX + editNflSFLEX
                                    }
                                    if league.sport == "EPL" {
                                        return editEplGK + editEplDEF + editEplMID + editEplFWD + editEplFLEX
                                    }
                                    return editPitcherSlots + editBatterSlots
                                }()
                                Stepper("\(editRosterSize)", value: $editRosterSize, in: minRoster...20)
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: 140)
                                    .onChange(of: minRoster) { _, newMin in
                                        if editRosterSize < newMin { editRosterSize = newMin }
                                    }
                                    .onAppear {
                                        if editRosterSize < minRoster { editRosterSize = minRoster }
                                    }
                            }
                            Divider()
                            HStack {
                                Text("Private League")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Toggle("", isOn: $editIsPrivate)
                                    .labelsHidden()
                                    .tint(brandPurple)
                            }

                            if league.isPrivate, let code = league.inviteCode {
                                Divider()
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Invite Code")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(code)
                                            .font(.subheadline.weight(.bold).monospaced())
                                    }
                                    Spacer()
                                    Button {
                                        Haptics.light()
                                        UIPasteboard.general.string = code
                                    } label: {
                                        Label("Copy", systemImage: "doc.on.doc")
                                            .font(.caption.weight(.medium))
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(brandPurple)
                                    ShareLink(item: league.shareMessage(code: code)) {
                                        Label("Share", systemImage: "square.and.arrow.up")
                                            .font(.caption.weight(.medium))
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(brandPurple)
                                }
                            }
                        }
                    }

                    // Draft schedule (only meaningful before the draft)
                    if league.status == "open" {
                        settingsCard(title: "Draft Schedule") {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack {
                                    Text("Scheduled Start")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Toggle("", isOn: $editScheduleDraft)
                                        .labelsHidden()
                                        .tint(brandPurple)
                                }
                                if editScheduleDraft {
                                    Divider()
                                    DatePicker(
                                        "Start Time",
                                        selection: $editDraftDate,
                                        in: Date()...,
                                        displayedComponents: [.date, .hourAndMinute]
                                    )
                                    .font(.subheadline)
                                    .tint(brandPurple)
                                }
                                Text(editScheduleDraft
                                     ? "The draft starts automatically at this time for everyone in the lobby. You can still hit Start Draft earlier."
                                     : "You start the draft manually from the league page.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    // Scoring Configuration card (sport-specific)
                    if league.sport == "MLB" {
                        settingsCard(title: "Scoring Configuration") {
                            VStack(spacing: 14) {
                                if !league.isDingersOnly {
                                    HStack {
                                        Text("Scoring Pitchers")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Stepper("\(editPitcherSlots)", value: $editPitcherSlots, in: 1...4)
                                            .font(.subheadline.weight(.semibold))
                                            .frame(maxWidth: 140)
                                            .onChange(of: editPitcherSlots) { _, _ in
                                                let totalStarters = editPitcherSlots + editBatterSlots
                                                if editRosterSize < totalStarters {
                                                    editRosterSize = totalStarters
                                                }
                                            }
                                    }
                                    Divider()
                                }
                                HStack {
                                    Text("Scoring Batters")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Stepper("\(editBatterSlots)", value: $editBatterSlots, in: 4...10)
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: 140)
                                        .onChange(of: editBatterSlots) { _, _ in
                                            let totalStarters = editPitcherSlots + editBatterSlots
                                            if editRosterSize < totalStarters {
                                                editRosterSize = totalStarters
                                            }
                                        }
                                }
                                Divider()
                                HStack {
                                    Text("Total Starters")
                                        .font(.subheadline.weight(.medium))
                                    Spacer()
                                    Text("\(league.isDingersOnly ? editBatterSlots : editPitcherSlots + editBatterSlots)")
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(brandPurple)
                                }
                            }
                        }
                    } else if league.sport == "NBA" {
                        settingsCard(title: "Scoring Configuration") {
                            VStack(spacing: 14) {
                                HStack {
                                    Text("Scoring Starters")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Stepper("\(editPitcherSlots + editBatterSlots)", value: Binding(
                                        get: { editPitcherSlots + editBatterSlots },
                                        set: { newVal in
                                            editPitcherSlots = 0
                                            editBatterSlots = newVal
                                            if editRosterSize < newVal {
                                                editRosterSize = newVal
                                            }
                                        }
                                    ), in: 6...12)
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: 140)
                                }
                            }
                        }
                    } else if league.sport == "NFL" || league.sport == "CFB" {
                        settingsCard(title: "Starting Lineup") {
                            // NFL config is only editable before the
                            // draft starts — once it's drafting/active
                            // the player pool was generated against the
                            // current shape, so changing it mid-stream
                            // would invalidate everyone's roster.
                            let isEditable = league.status == "open"
                            nflLineupConfigStepper(label: "QB",   value: $editNflQB,   range: 0...2, editable: isEditable)
                            Divider()
                            nflLineupConfigStepper(label: "RB",   value: $editNflRB,   range: 0...4, editable: isEditable)
                            Divider()
                            nflLineupConfigStepper(label: "WR",   value: $editNflWR,   range: 0...4, editable: isEditable)
                            Divider()
                            nflLineupConfigStepper(label: "TE",   value: $editNflTE,   range: 0...3, editable: isEditable)
                            Divider()
                            nflLineupConfigStepper(label: "FLEX", value: $editNflFLEX, range: 0...3, editable: isEditable)
                            Divider()
                            nflLineupConfigStepper(label: "SFLEX", value: $editNflSFLEX, range: 0...2, editable: isEditable)
                            Divider()
                            HStack {
                                Text("Total Starters")
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Text("\(editNflQB + editNflRB + editNflWR + editNflTE + editNflFLEX + editNflSFLEX)")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(brandPurple)
                            }
                            if !isEditable {
                                Text("Lineup is locked once the draft begins.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else if league.sport == "EPL" {
                        settingsCard(title: "Starting Lineup") {
                            // Same pre-draft-only rule as NFL: the pool and
                            // rosters were drafted against this shape.
                            let isEditable = league.status == "open"
                            nflLineupConfigStepper(label: "GK",   value: $editEplGK,   range: 0...2, editable: isEditable)
                            Divider()
                            nflLineupConfigStepper(label: "DEF",  value: $editEplDEF,  range: 0...5, editable: isEditable)
                            Divider()
                            nflLineupConfigStepper(label: "MID",  value: $editEplMID,  range: 0...6, editable: isEditable)
                            Divider()
                            nflLineupConfigStepper(label: "FWD",  value: $editEplFWD,  range: 0...4, editable: isEditable)
                            Divider()
                            nflLineupConfigStepper(label: "FLEX", value: $editEplFLEX, range: 0...4, editable: isEditable)
                            Divider()
                            HStack {
                                Text("Total Starters")
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Text("\(editEplGK + editEplDEF + editEplMID + editEplFWD + editEplFLEX)")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(brandPurple)
                            }
                            Text("FLEX takes any outfield player (DEF/MID/FWD).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !isEditable {
                                Text("Lineup is locked once the draft begins.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    // Scoring Model card
                    settingsCard(title: "Scoring Model") {
                        Text(BestBallLineupConfig.scoringDescription(for: league.sport, scoringMode: league.scoringMode))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let error = viewModel.error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 16)
                    }

                    // Buttons
                    VStack(spacing: 10) {
                        Button {
                            Haptics.medium()
                            isSavingSettings = true
                            Task {
                                // Make sure the roster can still hold
                                // the configured NFL lineup.
                                var effectiveRoster = editRosterSize
                                if league.sport == "NFL" || league.sport == "CFB" {
                                    let starters = editNflQB + editNflRB + editNflWR + editNflTE + editNflFLEX + editNflSFLEX
                                    effectiveRoster = max(effectiveRoster, starters)
                                } else if league.sport == "EPL" {
                                    effectiveRoster = max(effectiveRoster, editEplGK + editEplDEF + editEplMID + editEplFWD + editEplFLEX)
                                }
                                await viewModel.updateLeagueSettings(
                                    leagueID: leagueID,
                                    title: editTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                                    maxMembers: editMaxMembers,
                                    rosterSize: effectiveRoster,
                                    isPrivate: editIsPrivate,
                                    pitcherSlots: editPitcherSlots,
                                    batterSlots: editBatterSlots,
                                    nflQB: editNflQB,
                                    nflRB: editNflRB,
                                    nflWR: editNflWR,
                                    nflTE: editNflTE,
                                    nflFLEX: editNflFLEX,
                                    nflSFLEX: editNflSFLEX,
                                    eplGK: league.sport == "EPL" ? editEplGK : nil,
                                    eplDEF: league.sport == "EPL" ? editEplDEF : nil,
                                    eplMID: league.sport == "EPL" ? editEplMID : nil,
                                    eplFWD: league.sport == "EPL" ? editEplFWD : nil,
                                    eplFLEX: league.sport == "EPL" ? editEplFLEX : nil
                                )
                                // Persist the draft schedule only when it changed.
                                let newSchedule: Date? = editScheduleDraft ? editDraftDate : nil
                                if league.status == "open", newSchedule != league.draftStartTime {
                                    await viewModel.setDraftStartTime(leagueID: leagueID, date: newSchedule)
                                }
                                isSavingSettings = false
                                onDismiss()
                            }
                        } label: {
                            Text("Save Changes")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(brandPurple)
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .disabled(editTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSavingSettings)

                        if canDeleteLeague {
                            deleteLeagueButton
                        }

                        Button {
                            Haptics.light()
                            onDismiss()
                        } label: {
                            Text("Cancel")
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color(.systemGray6))
                                .foregroundStyle(.primary)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("League Settings")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Delete League?", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    Haptics.medium()
                    isDeletingLeague = true
                    Task {
                        let ok = await viewModel.deleteLeague(league)
                        isDeletingLeague = false
                        if ok { onDismiss() }
                    }
                }
            } message: {
                Text("This will permanently remove \"\(league.title)\". Since no one else has joined yet, you can safely delete it.")
            }
        }
    }

    @ViewBuilder
    private func nflLineupConfigStepper(label: String, value: Binding<Int>, range: ClosedRange<Int>, editable: Bool) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            if editable {
                Stepper("\(value.wrappedValue)", value: value, in: range)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: 140)
            } else {
                Text("\(value.wrappedValue)")
                    .font(.subheadline.weight(.semibold))
            }
        }
    }

    @ViewBuilder
    private var deleteLeagueButton: some View {
        Button(role: .destructive) {
            Haptics.medium()
            showDeleteConfirmation = true
        } label: {
            HStack(spacing: 6) {
                if isDeletingLeague {
                    ProgressView().tint(.red)
                } else {
                    Image(systemName: "trash")
                        .font(.subheadline.weight(.semibold))
                }
                Text(isDeletingLeague ? "Deleting…" : "Delete League")
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.red.opacity(0.10))
            .foregroundStyle(.red)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(isDeletingLeague)
    }

    private func settingsCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
        }
    }
}
