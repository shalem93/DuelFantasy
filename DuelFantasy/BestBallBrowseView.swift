import SwiftUI

struct BestBallBrowseView: View {
    @Bindable var viewModel: BestBallViewModel
    @State private var showCreateSheet: Bool = false
    @State private var isCreatingLeague: Bool = false
    @State private var showJoinByCode: Bool = false
    @State private var newLeagueTitle: String = ""
    @State private var newLeagueSport: String = "NFL"
    @State private var newLeagueEntryFee: Int = 10
    @State private var newLeaguePrivate: Bool = false
    @State private var newLeagueSize: Int = 12
    @State private var newLeagueRosterSize: Int = 12
    @State private var newPitcherSlots: Int = 2
    @State private var newBatterSlots: Int = 6
    @State private var newScoringMode: BestBallScoringMode = .normal
    // NFL starting-lineup config — only used when sport == "NFL".
    @State private var newNflQB: Int = 1
    @State private var newNflRB: Int = 2
    @State private var newNflWR: Int = 2
    @State private var newNflTE: Int = 1
    @State private var newNflFLEX: Int = 2
    @State private var newNflSFLEX: Int = 0
    // NBA positional lineup config.
    @State private var newNbaPG: Int = 1
    @State private var newNbaSG: Int = 1
    @State private var newNbaSF: Int = 1
    @State private var newNbaPF: Int = 1
    @State private var newNbaC: Int = 1
    @State private var newNbaFLEX: Int = 3
    /// CFB player pool: "all" FBS or "power" (P4 + Notre Dame).
    @State private var newCfbPool: String = "all"
    @State private var newPickTimer: Int = 30
    // EPL positional lineup config (defaults to the classic XI).
    @State private var newEplGK: Int = 1
    @State private var newEplDEF: Int = 3
    @State private var newEplMID: Int = 4
    @State private var newEplFWD: Int = 2
    @State private var newEplFLEX: Int = 1
    @State private var inviteCode: String = ""
    @State private var isJoiningByCode: Bool = false
    /// Set after a successful create to push straight into the new
    /// league. Without this, a private league "disappears" — Browse only
    /// lists public leagues, so the creator saw no trace of it.
    @State private var pushedLeague: CreatedLeagueRef?

    private struct CreatedLeagueRef: Identifiable, Hashable { let id: String }

    private var brandPurple: Color {
        Color(red: 0.48, green: 0.23, blue: 0.93)
    }

    // Sports are offered ONLY until the day before their season starts:
    // a Best Ball drafted mid-season plays against a half-burned schedule.
    // NBA re-enters the list automatically ahead of its October tip-off,
    // MLB drops out after Opening Day, NFL/CFB run up to kickoff week.
    private let allSports = ["NFL", "CFB", "EPL", "MLB", "NBA"]
    private var sports: [String] {
        allSports.filter { BestBallViewModel.isSportOpenForNewLeagues($0) }
    }

    /// Display metadata for the create-sheet sport cards.
    private struct SportOption {
        let name: String
        let icon: String
        let tagline: String
        let seasonNote: String
        let gradient: [Color]
    }

    private func sportOption(for sport: String) -> SportOption {
        switch sport {
        case "NFL":
            return SportOption(
                name: "NFL", icon: "football.fill",
                tagline: "Sundays are back",
                seasonNote: "Kicks off September · 18 wks",
                gradient: [Color(red: 0.00, green: 0.15, blue: 0.40), Color(red: 0.05, green: 0.32, blue: 0.65)]
            )
        case "CFB":
            return SportOption(
                name: "NCAAF", icon: "football.fill",
                tagline: "Saturdays all fall",
                seasonNote: "Week 1 late August · 15 wks",
                gradient: [Color(red: 0.45, green: 0.10, blue: 0.08), Color(red: 0.75, green: 0.28, blue: 0.10)]
            )
        case "NBA":
            return SportOption(
                name: "NBA", icon: "basketball.fill",
                tagline: "Nightly buckets",
                seasonNote: "Tips off October · 24 wks",
                gradient: [Color(red: 0.30, green: 0.08, blue: 0.35), Color(red: 0.55, green: 0.18, blue: 0.55)]
            )
        case "EPL":
            return SportOption(
                name: "EPL", icon: "soccerball",
                tagline: "Premier League XIs",
                seasonNote: "Kicks off late August · 41 wks",
                gradient: [Color(red: 0.22, green: 0.03, blue: 0.28), Color(red: 0.55, green: 0.05, blue: 0.30)]
            )
        default:
            return SportOption(
                name: "MLB", icon: "figure.baseball",
                tagline: "Bats & arms daily",
                seasonNote: "Season live now · 26 wks",
                gradient: [Color(red: 0.05, green: 0.28, blue: 0.14), Color(red: 0.10, green: 0.48, blue: 0.24)]
            )
        }
    }

    /// Tappable sport cards for the create sheet — replaces the old
    /// segmented picker with something that actually sells each sport.
    private var sportCardPicker: some View {
        HStack(spacing: 10) {
            ForEach(sports, id: \.self) { sport in
                SportPickerCard(
                    option: sportOption(for: sport),
                    isSelected: newLeagueSport == sport,
                    brandPurple: brandPurple
                ) {
                    Haptics.light()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        newLeagueSport = sport
                    }
                }
            }
        }
    }

    private struct SportPickerCard: View {
        let option: SportOption
        let isSelected: Bool
        let brandPurple: Color
        let action: () -> Void

        private var cardBackground: AnyShapeStyle {
            if isSelected {
                return AnyShapeStyle(LinearGradient(colors: option.gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            return AnyShapeStyle(Color(.systemGray6))
        }

        private var iconCircleColor: Color {
            isSelected ? Color.white.opacity(0.22) : brandPurple.opacity(0.10)
        }

        private var shadowColor: Color {
            isSelected ? (option.gradient.last ?? brandPurple).opacity(0.35) : .clear
        }

        var body: some View {
            // A tap gesture, NOT a Button: multiple plain-style buttons in
            // one Form row get their taps hijacked by the row (only the
            // first card ever responded — NFL looked "stuck selected").
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(iconCircleColor)
                        .frame(width: 42, height: 42)
                    Image(systemName: option.icon)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.white : brandPurple)
                }
                Text(option.name)
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                Text(option.tagline)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(option.seasonNote)
                    .font(.system(size: 8.5))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.7) : Color(.tertiaryLabel))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 4)
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? Color.white.opacity(0.35) : Color.clear, lineWidth: 1)
            )
            .shadow(color: shadowColor, radius: 6, y: 3)
            .scaleEffect(isSelected ? 1.0 : 0.97)
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .onTapGesture(perform: action)
        }
    }

    /// Bump the roster-size stepper up to the configured starting-lineup
    /// total when the commissioner adds another starter slot. Mirrors
    /// the MLB onChange handlers and the auto-floor we already apply on
    /// Create. Without it, "Roster Size: 8 / Total Starters: 9" was a
    /// reachable state in the form.
    private func floorRosterSizeForNFL() {
        let total = newNflQB + newNflRB + newNflWR + newNflTE + newNflFLEX + newNflSFLEX
        if newLeagueRosterSize < total {
            newLeagueRosterSize = total
        }
    }

    private var newEplStarters: Int {
        newEplGK + newEplDEF + newEplMID + newEplFWD + newEplFLEX
    }

    private func floorRosterSizeForEPL() {
        if newLeagueRosterSize < newEplStarters {
            newLeagueRosterSize = newEplStarters
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                heroBanner

                // Sport filter chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        filterPill("All", sport: nil)
                        ForEach(sports, id: \.self) { sport in
                            filterPill(displaySportLabel(sport), sport: sport)
                        }
                    }
                    .padding(.horizontal, 2)
                }

                // Create league + Join by code
                HStack(spacing: 8) {
                    Button {
                        Haptics.medium()
                        // Pre-select the create-sheet sport to match
                        // whatever filter pill the user already has
                        // active. Saves them the redundant tap.
                        if let filter = viewModel.sportFilter, sports.contains(filter) {
                            newLeagueSport = filter
                        }
                        showCreateSheet = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("Create League")
                                .font(.subheadline.weight(.bold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(
                            LinearGradient(colors: [brandPurple, Color(red: 0.35, green: 0.18, blue: 0.80)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 13))
                        .shadow(color: brandPurple.opacity(0.35), radius: 8, y: 4)
                    }

                    Button {
                        Haptics.medium()
                        showJoinByCode = true
                    } label: {
                        HStack {
                            Image(systemName: "ticket.fill")
                            Text("Join by Code")
                                .font(.subheadline.weight(.bold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(.white)
                        .foregroundStyle(brandPurple)
                        .clipShape(RoundedRectangle(cornerRadius: 13))
                        .overlay(
                            RoundedRectangle(cornerRadius: 13)
                                .strokeBorder(brandPurple.opacity(0.35), lineWidth: 1.5)
                        )
                    }
                }

                // Open leagues
                if viewModel.isLoading && viewModel.openLeagues.isEmpty {
                    ProgressView()
                        .padding(.top, 40)
                } else if viewModel.openLeagues.isEmpty {
                    emptyState
                } else {
                    let joinableLeagues = viewModel.openLeagues.filter {
                        BestBallViewModel.isSportJoinable($0.sport)
                    }
                    HStack {
                        Text("OPEN LEAGUES")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(joinableLeagues.count) joinable")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
                    ForEach(joinableLeagues) { league in
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
        .background(
            LinearGradient(
                colors: [Color(red: 0.95, green: 0.94, blue: 1.00), Color(red: 0.97, green: 0.98, blue: 1.00)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .navigationDestination(item: $pushedLeague) { ref in
            BestBallLeagueDetailView(viewModel: viewModel, leagueID: ref.id)
        }
        .onChange(of: showCreateSheet) { _, isShowing in
            // Runs in the PRESENTING view the instant the sheet opens —
            // the belt to the sheet-side onAppear's suspenders.
            if isShowing, let filter = viewModel.sportFilter, sports.contains(filter) {
                newLeagueSport = filter
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            createLeagueSheet
        }
        .sheet(isPresented: $showJoinByCode) {
            joinByCodeSheet
        }
    }

    // MARK: - Hero Banner

    private var heroBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "trophy.fill")
                    .font(.title3)
                    .foregroundStyle(Color(red: 0.98, green: 0.82, blue: 0.30))
                Text("Season-Long Best Ball")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "football.fill")
                    Image(systemName: "figure.baseball")
                }
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
            }
            Text("Draft once — your best lineup scores itself every week. Winner takes the pot.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                ForEach(BestBallViewModel.entryFeeTiers, id: \.self) { fee in
                    Text("\(fee)")
                        .font(.system(size: 10, weight: .heavy).monospacedDigit())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.white.opacity(0.18))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                Text("RR ENTRIES")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color(red: 0.30, green: 0.12, blue: 0.70),
                         Color(red: 0.48, green: 0.23, blue: 0.93),
                         Color(red: 0.20, green: 0.35, blue: 0.85)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: brandPurple.opacity(0.35), radius: 10, y: 5)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sportscourt")
                .font(.system(size: 34))
                .foregroundStyle(brandPurple.opacity(0.5))
            Text("No open leagues right now")
                .font(.subheadline.weight(.semibold))
            Text("Start one and the lobby fills from here — or grab an invite code from a friend.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 24)
        .background(.white.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Filter Pill

    private func filterPill(_ label: String, sport: String?) -> some View {
        let isSelected = viewModel.sportFilter == sport
        let gradient: [Color] = sport.map { sportOption(for: $0).gradient }
            ?? [brandPurple, Color(red: 0.35, green: 0.18, blue: 0.80)]
        let icon: String? = sport.map { sportOption(for: $0).icon }
        return Button {
            Haptics.light()
            viewModel.sportFilter = sport
            // Keep the create sheet's sport in lockstep with the filter
            // pill so Create League always opens on the filtered sport.
            if let sport, sports.contains(sport) {
                newLeagueSport = sport
            }
            Task { await viewModel.loadOpenLeagues() }
        } label: {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.caption2)
                }
                Text(label)
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                isSelected
                    ? AnyShapeStyle(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                    : AnyShapeStyle(Color.white)
            )
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(Capsule())
            .shadow(color: isSelected ? (gradient.last ?? brandPurple).opacity(0.35) : .black.opacity(0.05), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Open League Card

    private func openLeagueCard(_ league: BestBallLeague) -> some View {
        let option = sportOption(for: league.sport)
        let filled = viewModel.leagueMemberCounts[league.id] ?? league.draftOrder.count
        let capacity = max(league.maxMembers, 1)
        let fillFraction = min(1.0, Double(filled) / Double(capacity))
        let spotsLeft = max(0, capacity - filled)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                // Sport tile
                Image(systemName: option.icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(
                        LinearGradient(colors: option.gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 3) {
                    Text(league.title)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(displaySportLabel(league.sport))
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(option.gradient.last ?? brandPurple)
                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text("\(option.seasonNote) · \(BestBallViewModel.joinDeadlineNote(for: league.sport))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(league.entryFee > 0 ? "\(league.entryFee) RR" : "FREE")
                        .font(.caption.weight(.heavy))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            (league.entryFee > 0 ? brandPurple : Color.green).opacity(0.12)
                        )
                        .foregroundStyle(league.entryFee > 0 ? brandPurple : .green)
                        .clipShape(Capsule())
                    if league.isDingersOnly {
                        Text("HR ONLY")
                            .font(.system(size: 8, weight: .heavy))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    }
                    if league.isPrivate {
                        HStack(spacing: 3) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 7, weight: .heavy))
                            Text("PRIVATE")
                                .font(.system(size: 8, weight: .heavy))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .foregroundStyle(.secondary)
                        .clipShape(Capsule())
                    }
                }
            }

            // Fill bar: how close this league is to drafting
            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color(.systemGray5))
                        Capsule()
                            .fill(
                                LinearGradient(colors: option.gradient, startPoint: .leading, endPoint: .trailing)
                            )
                            .frame(width: max(6, geo.size.width * fillFraction))
                    }
                }
                .frame(height: 6)
                HStack {
                    Text("\(filled)/\(capacity) drafters")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(spotsLeft == 0 ? "FULL — drafting soon" : "\(spotsLeft) \(spotsLeft == 1 ? "spot" : "spots") left")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(spotsLeft <= 2 ? .orange : brandPurple)
                }
            }
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16))
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
                    sportCardPicker
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                        .listRowBackground(Color.clear)
                }

                Section {
                    HStack(spacing: 8) {
                        ForEach(BestBallViewModel.entryFeeTiers, id: \.self) { fee in
                            let isSelected = newLeagueEntryFee == fee
                            Button {
                                Haptics.light()
                                newLeagueEntryFee = fee
                            } label: {
                                Text("\(fee)")
                                    .font(.subheadline.weight(.bold).monospacedDigit())
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(isSelected ? brandPurple : Color(.systemGray6))
                                    .foregroundStyle(isSelected ? .white : .primary)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 4, trailing: 8))
                    .listRowBackground(Color.clear)
                } header: {
                    Text("Entry Fee (RR)")
                } footer: {
                    let cap = BestBallViewModel.joinCap(forFee: newLeagueEntryFee)
                    let current = viewModel.activeLeagueCount(atFee: newLeagueEntryFee, sport: newLeagueSport)
                    Text(cap == 1
                         ? "Charged when the draft starts. Winners earn back multiples of the entry. Limited to 1 \(newLeagueSport) league at this level\(current >= 1 ? " — you already have one" : "")."
                         : "Charged when the draft starts. Winners earn back multiples of the entry. You can be in \(cap) \(newLeagueSport) leagues at this level (currently in \(current)).")
                }

                Section("League Settings") {
                    Stepper("League Size: \(newLeagueSize)", value: $newLeagueSize, in: 4...16, step: 2)
                    HStack {
                        Text("Pick Clock")
                        Spacer()
                        Picker("", selection: $newPickTimer) {
                            Text("30s").tag(30)
                            Text("45s").tag(45)
                            Text("60s").tag(60)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 170)
                    }
                    if newScoringMode != .dingersOnly {
                        // Sport-aware minimum roster size — it can never
                        // be lower than the configured starting lineup
                        // count, otherwise the bot drafter and lineup
                        // optimizer can't fill all the slots.
                        let minRoster: Int = {
                            if newLeagueSport == "NFL" || newLeagueSport == "CFB" {
                                return newNflQB + newNflRB + newNflWR + newNflTE + newNflFLEX + newNflSFLEX
                            }
                            if newLeagueSport == "EPL" { return newEplStarters }
                            return newPitcherSlots + newBatterSlots
                        }()
                        Stepper("Roster Size: \(newLeagueRosterSize)", value: $newLeagueRosterSize, in: minRoster...20)
                    }
                    Toggle("Private League", isOn: $newLeaguePrivate)
                }

                if newLeagueSport == "CFB" {
                    Section("Player Pool") {
                        Picker("", selection: $newCfbPool) {
                            Text("All FBS").tag("all")
                            Text("Power Conferences").tag("power")
                        }
                        .pickerStyle(.segmented)
                        Text(newCfbPool == "power"
                             ? "ACC, Big Ten, Big 12, SEC + Notre Dame — household names only."
                             : "Every FBS program — a deep pool with plenty of sleepers (and randos).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
                    Section("Starting Lineup") {
                        Stepper("PG: \(newNbaPG)", value: $newNbaPG, in: 0...3)
                        Stepper("SG: \(newNbaSG)", value: $newNbaSG, in: 0...3)
                        Stepper("SF: \(newNbaSF)", value: $newNbaSF, in: 0...3)
                        Stepper("PF: \(newNbaPF)", value: $newNbaPF, in: 0...3)
                        Stepper("C: \(newNbaC)", value: $newNbaC, in: 0...2)
                        Stepper("FLEX (any position): \(newNbaFLEX)", value: $newNbaFLEX, in: 0...5)
                        HStack {
                            Text("Total Starters")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(newNbaPG + newNbaSG + newNbaSF + newNbaPF + newNbaC + newNbaFLEX)")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(brandPurple)
                        }
                    }
                } else if newLeagueSport == "EPL" {
                    Section("Starting Lineup") {
                        Stepper("GK: \(newEplGK)", value: $newEplGK, in: 0...2)
                            .onChange(of: newEplGK) { _, _ in floorRosterSizeForEPL() }
                        Stepper("DEF: \(newEplDEF)", value: $newEplDEF, in: 0...5)
                            .onChange(of: newEplDEF) { _, _ in floorRosterSizeForEPL() }
                        Stepper("MID: \(newEplMID)", value: $newEplMID, in: 0...6)
                            .onChange(of: newEplMID) { _, _ in floorRosterSizeForEPL() }
                        Stepper("FWD: \(newEplFWD)", value: $newEplFWD, in: 0...4)
                            .onChange(of: newEplFWD) { _, _ in floorRosterSizeForEPL() }
                        Stepper("FLEX (DEF/MID/FWD): \(newEplFLEX)", value: $newEplFLEX, in: 0...4)
                            .onChange(of: newEplFLEX) { _, _ in floorRosterSizeForEPL() }
                        HStack {
                            Text("Total Starters")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(newEplStarters)")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(brandPurple)
                        }
                        Text("FLEX takes any outfield player — the best lineup morphs between 3-5-2, 3-4-3, and 4-4-2.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if newLeagueSport == "NFL" || newLeagueSport == "CFB" {
                    Section("Starting Lineup") {
                        Stepper("QB: \(newNflQB)", value: $newNflQB, in: 0...2)
                            .onChange(of: newNflQB) { _, _ in floorRosterSizeForNFL() }
                        Stepper("RB: \(newNflRB)", value: $newNflRB, in: 0...4)
                            .onChange(of: newNflRB) { _, _ in floorRosterSizeForNFL() }
                        Stepper("WR: \(newNflWR)", value: $newNflWR, in: 0...4)
                            .onChange(of: newNflWR) { _, _ in floorRosterSizeForNFL() }
                        Stepper("TE: \(newNflTE)", value: $newNflTE, in: 0...3)
                            .onChange(of: newNflTE) { _, _ in floorRosterSizeForNFL() }
                        Stepper("FLEX: \(newNflFLEX)", value: $newNflFLEX, in: 0...3)
                            .onChange(of: newNflFLEX) { _, _ in floorRosterSizeForNFL() }
                        Stepper("SFLEX (Superflex): \(newNflSFLEX)", value: $newNflSFLEX, in: 0...2)
                            .onChange(of: newNflSFLEX) { _, _ in floorRosterSizeForNFL() }
                        HStack {
                            Text("Total Starters")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(newNflQB + newNflRB + newNflWR + newNflTE + newNflFLEX + newNflSFLEX)")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(brandPurple)
                        }
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
                        let starters: Int = {
                            switch newLeagueSport {
                            case "MLB": return newScoringMode == .dingersOnly ? newBatterSlots : newPitcherSlots + newBatterSlots
                            case "NBA": return newNbaPG + newNbaSG + newNbaSF + newNbaPF + newNbaC + newNbaFLEX
                            case "EPL": return newEplStarters
                            default: return newNflQB + newNflRB + newNflWR + newNflTE + newNflFLEX + newNflSFLEX
                            }
                        }()
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

                if let error = viewModel.error {
                    Section {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .onAppear {
                // Mirror the active browse filter pill EVERY time the
                // sheet opens — the Create-button preselect alone left a
                // stale sport from a previous open on some entry paths.
                if let filter = viewModel.sportFilter, sports.contains(filter) {
                    newLeagueSport = filter
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
                    Button {
                        let title = newLeagueTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        // In-flight guard: a slow create used to leave the
                        // button live, and a second tap duplicated the league.
                        guard !title.isEmpty, !isCreatingLeague else { return }
                        isCreatingLeague = true
                        viewModel.error = nil
                        Task {
                            // For NFL leagues, ensure the roster is at
                            // least big enough to hold the configured
                            // starting lineup.
                            let nflStarters = newNflQB + newNflRB + newNflWR + newNflTE + newNflFLEX + newNflSFLEX
                            let effectiveRoster: Int
                            if newLeagueSport == "NFL" || newLeagueSport == "CFB" {
                                effectiveRoster = max(newLeagueRosterSize, nflStarters)
                            } else if newLeagueSport == "EPL" {
                                effectiveRoster = max(newLeagueRosterSize, newEplStarters)
                            } else if newScoringMode == .dingersOnly {
                                effectiveRoster = newBatterSlots
                            } else {
                                effectiveRoster = newLeagueRosterSize
                            }
                            let created = await viewModel.createLeague(
                                title: title, sport: newLeagueSport,
                                isPrivate: newLeaguePrivate,
                                maxMembers: newLeagueSize,
                                rosterSize: effectiveRoster,
                                pitcherSlots: newScoringMode == .dingersOnly ? 0 : newPitcherSlots,
                                batterSlots: newBatterSlots,
                                scoringMode: newScoringMode,
                                nflQB: newNflQB, nflRB: newNflRB,
                                nflWR: newNflWR, nflTE: newNflTE, nflFLEX: newNflFLEX, nflSFLEX: newNflSFLEX,
                                entryFee: newLeagueEntryFee,
                                nbaPG: newLeagueSport == "NBA" ? newNbaPG : nil,
                                nbaSG: newLeagueSport == "NBA" ? newNbaSG : nil,
                                nbaSF: newLeagueSport == "NBA" ? newNbaSF : nil,
                                nbaPF: newLeagueSport == "NBA" ? newNbaPF : nil,
                                nbaC: newLeagueSport == "NBA" ? newNbaC : nil,
                                nbaFLEX: newLeagueSport == "NBA" ? newNbaFLEX : nil,
                                eplGK: newLeagueSport == "EPL" ? newEplGK : nil,
                                eplDEF: newLeagueSport == "EPL" ? newEplDEF : nil,
                                eplMID: newLeagueSport == "EPL" ? newEplMID : nil,
                                eplFWD: newLeagueSport == "EPL" ? newEplFWD : nil,
                                eplFLEX: newLeagueSport == "EPL" ? newEplFLEX : nil,
                                cfbPool: newLeagueSport == "CFB" ? newCfbPool : nil,
                                pickTimerSeconds: newPickTimer
                            )
                            isCreatingLeague = false
                            // Failed create: keep the sheet open so the
                            // error section is visible and nothing is lost.
                            guard let created else { return }
                            showCreateSheet = false
                            newLeagueTitle = ""
                            newLeaguePrivate = false
                            newLeagueSize = 12
                            newLeagueRosterSize = 12
                            newPitcherSlots = 2
                            newBatterSlots = 6
                            newScoringMode = .normal
                            newNflQB = 1
                            newNflRB = 2
                            newNflWR = 2
                            newNflTE = 1
                            newNflFLEX = 2
                            newNflSFLEX = 0
                            newEplGK = 1
                            newEplDEF = 3
                            newEplMID = 4
                            newEplFWD = 2
                            newEplFLEX = 1
                            newCfbPool = "all"
                            newPickTimer = 30
                            // Land the creator inside their new league
                            // (shows the invite code for private ones).
                            // Small beat so the sheet dismissal animation
                            // finishes before the push starts.
                            try? await Task.sleep(nanoseconds: 350_000_000)
                            pushedLeague = CreatedLeagueRef(id: created.id)
                        }
                    } label: {
                        if isCreatingLeague {
                            ProgressView()
                        } else {
                            Text("Create")
                        }
                    }
                    .disabled(newLeagueTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreatingLeague)
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
