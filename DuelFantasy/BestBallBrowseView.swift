import SwiftUI

struct BestBallBrowseView: View {
    @Bindable var viewModel: BestBallViewModel
    @State private var showCreateSheet: Bool = false
    @State private var showJoinByCode: Bool = false
    @State private var newLeagueTitle: String = ""
    @State private var newLeagueSport: String = "MLB"
    @State private var newLeaguePrivate: Bool = false
    @State private var newLeagueSize: Int = 12
    @State private var newLeagueRosterSize: Int = 12
    @State private var newPitcherSlots: Int = 2
    @State private var newBatterSlots: Int = 6
    @State private var newScoringMode: BestBallScoringMode = .normal
    @State private var inviteCode: String = ""
    @State private var isJoiningByCode: Bool = false

    private var brandPurple: Color {
        Color(red: 0.48, green: 0.23, blue: 0.93)
    }

    private let sports = ["MLB"]

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Sport filter pills
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        filterPill("All", sport: nil)
                        ForEach(sports, id: \.self) { sport in
                            filterPill(sport, sport: sport)
                        }
                    }
                    .padding(.horizontal, 2)
                }

                // Create league + Join by code
                HStack(spacing: 8) {
                    Button {
                        Haptics.medium()
                        showCreateSheet = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("Create League")
                                .font(.subheadline.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(brandPurple)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    Button {
                        Haptics.medium()
                        showJoinByCode = true
                    } label: {
                        HStack {
                            Image(systemName: "ticket")
                            Text("Join by Code")
                                .font(.subheadline.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color(.systemGray5))
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }

                // Open leagues
                if viewModel.isLoading && viewModel.openLeagues.isEmpty {
                    ProgressView()
                        .padding(.top, 40)
                } else if viewModel.openLeagues.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("No open leagues")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Create one to get started!")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, 40)
                } else {
                    ForEach(viewModel.openLeagues) { league in
                        NavigationLink {
                            BestBallLeagueDetailView(viewModel: viewModel, leagueID: league.id)
                        } label: {
                            openLeagueCard(league)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
        .sheet(isPresented: $showCreateSheet) {
            createLeagueSheet
        }
        .sheet(isPresented: $showJoinByCode) {
            joinByCodeSheet
        }
    }

    // MARK: - Filter Pill

    private func filterPill(_ label: String, sport: String?) -> some View {
        let isSelected = viewModel.sportFilter == sport
        return Button {
            Haptics.light()
            viewModel.sportFilter = sport
            Task { await viewModel.loadOpenLeagues() }
        } label: {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isSelected ? brandPurple : Color(.systemGray6))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Open League Card

    private func openLeagueCard(_ league: BestBallLeague) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(league.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if league.isDingersOnly {
                    Text("HR")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.15))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
                Text(league.sport)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(brandPurple.opacity(0.15))
                    .foregroundStyle(brandPurple)
                    .clipShape(Capsule())
            }
            HStack {
                Label(league.season, systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "person.2")
                        .font(.caption)
                    Text("\(viewModel.leagueMemberCounts[league.id] ?? league.draftOrder.count)/\(league.maxMembers)")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    // MARK: - Create League Sheet

    private var createLeagueSheet: some View {
        NavigationStack {
            Form {
                Section("League Name") {
                    TextField("e.g. Hoops Masters", text: $newLeagueTitle)
                }

                Section("Sport") {
                    Picker("Sport", selection: $newLeagueSport) {
                        ForEach(sports, id: \.self) { sport in
                            Text(sport).tag(sport)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("League Settings") {
                    Stepper("League Size: \(newLeagueSize)", value: $newLeagueSize, in: 4...16, step: 2)
                    if newScoringMode != .dingersOnly {
                        let minRoster = newPitcherSlots + newBatterSlots
                        Stepper("Roster Size: \(newLeagueRosterSize)", value: $newLeagueRosterSize, in: minRoster...20)
                    }
                    Toggle("Private League", isOn: $newLeaguePrivate)
                }

                if newLeagueSport == "MLB" {
                    Section("Scoring Mode") {
                        Picker("Mode", selection: $newScoringMode) {
                            ForEach(BestBallScoringMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: newScoringMode) { _, newValue in
                            if newValue == .dingersOnly {
                                newPitcherSlots = 0
                            } else {
                                newPitcherSlots = 2
                            }
                        }
                    }
                }

                if newLeagueSport == "MLB" {
                    Section("Scoring Starters") {
                        if newScoringMode == .normal {
                            Stepper("Pitchers: \(newPitcherSlots)", value: $newPitcherSlots, in: 1...4)
                                .onChange(of: newPitcherSlots) { _, _ in
                                    let totalStarters = newPitcherSlots + newBatterSlots
                                    if newLeagueRosterSize < totalStarters {
                                        newLeagueRosterSize = totalStarters
                                    }
                                }
                        }
                        Stepper("Batters (UTIL): \(newBatterSlots)", value: $newBatterSlots, in: 4...10)
                            .onChange(of: newBatterSlots) { _, _ in
                                let totalStarters = newPitcherSlots + newBatterSlots
                                if newLeagueRosterSize < totalStarters {
                                    newLeagueRosterSize = totalStarters
                                }
                            }
                        HStack {
                            Text("Total Starters")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(newScoringMode == .dingersOnly ? newBatterSlots : newPitcherSlots + newBatterSlots)")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(brandPurple)
                        }
                    }
                } else if newLeagueSport == "NBA" {
                    Section("Scoring Starters") {
                        Stepper("Starters: \(newPitcherSlots + newBatterSlots)", value: Binding(
                            get: { newPitcherSlots + newBatterSlots },
                            set: { newVal in
                                newPitcherSlots = 0
                                newBatterSlots = newVal
                            }
                        ), in: 6...12)
                    }
                }

                Section("Scoring Model") {
                    Text(BestBallLineupConfig.scoringDescription(for: newLeagueSport, scoringMode: newScoringMode))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("\(newLeagueSize)-person league", systemImage: "person.3")
                        let draftRounds = (newScoringMode == .dingersOnly && newLeagueSport == "MLB") ? newBatterSlots : newLeagueRosterSize
                        Label("\(draftRounds)-round snake draft", systemImage: "arrow.triangle.swap")
                        let starters = newLeagueSport == "MLB" ? (newScoringMode == .dingersOnly ? newBatterSlots : newPitcherSlots + newBatterSlots) : (newLeagueSport == "NBA" ? newPitcherSlots + newBatterSlots : 8)
                        if newScoringMode == .dingersOnly && newLeagueSport == "MLB" {
                            Label("All \(starters) batters score · HR leaderboard", systemImage: "star")
                        } else {
                            Label("Best \(starters) of \(newLeagueRosterSize) score · H2H matchups", systemImage: "star")
                        }
                        Label("Bots fill empty spots", systemImage: "cpu")
                        if newLeaguePrivate {
                            Label("Invite code required to join", systemImage: "lock.fill")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Create League")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showCreateSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let title = newLeagueTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !title.isEmpty else { return }
                        Task {
                            _ = await viewModel.createLeague(
                                title: title, sport: newLeagueSport,
                                isPrivate: newLeaguePrivate,
                                maxMembers: newLeagueSize,
                                rosterSize: newScoringMode == .dingersOnly ? newBatterSlots : newLeagueRosterSize,
                                pitcherSlots: newScoringMode == .dingersOnly ? 0 : newPitcherSlots,
                                batterSlots: newBatterSlots,
                                scoringMode: newScoringMode
                            )
                            showCreateSheet = false
                            newLeagueTitle = ""
                            newLeaguePrivate = false
                            newLeagueSize = 12
                            newLeagueRosterSize = 12
                            newPitcherSlots = 2
                            newBatterSlots = 6
                            newScoringMode = .normal
                        }
                    }
                    .disabled(newLeagueTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: - Join by Code Sheet

    private var joinByCodeSheet: some View {
        NavigationStack {
            Form {
                Section("Invite Code") {
                    TextField("e.g. ABC123", text: $inviteCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Enter the 6-character code", systemImage: "ticket")
                        Label("Shared by the league commissioner", systemImage: "person.badge.shield.checkmark")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                if let error = viewModel.error {
                    Section {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Join by Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showJoinByCode = false
                        inviteCode = ""
                        viewModel.error = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Join") {
                        let code = inviteCode.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !code.isEmpty else { return }
                        isJoiningByCode = true
                        Task {
                            if let league = await viewModel.joinLeagueByCode(code) {
                                showJoinByCode = false
                                inviteCode = ""
                                _ = league
                            }
                            isJoiningByCode = false
                        }
                    }
                    .disabled(inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).count < 6 || isJoiningByCode)
                }
            }
        }
    }
}
