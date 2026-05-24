import SwiftUI

struct BestBallLeagueDetailView: View {
    @Bindable var viewModel: BestBallViewModel
    let leagueID: String
    @EnvironmentObject private var auth: AuthViewModel
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
            // Auto-catch-up on initial load if league is active and host
            if viewModel.currentLeague?.status == "active",
               viewModel.isHost, !isCatchingUp, !hasTriggeredCatchUp {
                hasTriggeredCatchUp = true
                isCatchingUp = true
                await viewModel.catchUpScoring(leagueID: leagueID)
                isCatchingUp = false
            }
        }
    }

    // MARK: - Active League Content (Tabs)

    @State private var isCatchingUp = false

    private var activeLeagueContent: some View {
        VStack(spacing: 0) {
            // Auto-scoring banner
            if isCatchingUp || !viewModel.catchUpProgress.isEmpty {
                HStack(spacing: 8) {
                    if isCatchingUp {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(.white)
                    }
                    Text(viewModel.catchUpProgress.isEmpty ? "Scoring past weeks..." : viewModel.catchUpProgress)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(brandPurple)
            }

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
                            Text("\(league.isDingersOnly ? league.batterSlots : league.pitcherSlots + league.batterSlots)")
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
                            Text("Start Draft")
                                .font(.headline)
                            Text("Empty slots will be filled by bots")
                                .font(.caption)
                                .opacity(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(brandPurple)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                } else {
                    Text("Waiting for host to start draft...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
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
        case "NFL": return "football"
        default: return "sportscourt"
        }
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
    @State private var isSavingSettings: Bool = false

    private var brandPurple: Color {
        Color(red: 0.48, green: 0.23, blue: 0.93)
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
                                let minRoster = editPitcherSlots + editBatterSlots
                                Stepper("\(editRosterSize)", value: $editRosterSize, in: minRoster...20)
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: 140)
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
                                }
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
                                await viewModel.updateLeagueSettings(
                                    leagueID: leagueID,
                                    title: editTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                                    maxMembers: editMaxMembers,
                                    rosterSize: editRosterSize,
                                    isPrivate: editIsPrivate,
                                    pitcherSlots: editPitcherSlots,
                                    batterSlots: editBatterSlots
                                )
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
        }
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
