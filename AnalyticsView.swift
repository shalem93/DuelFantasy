import SwiftUI

struct AnalyticsView: View {
    let userID: String
    let accessToken: String
    var initialTab: Int = 0

    @State private var selectedTab: Int = 0
    @State private var selectedPickemSport: String = "All"
    @State private var selectedDFSSport: String = "All"
    @State private var settledPicks: [SettledPickRecord] = []
    @State private var dfsResults: [DFSTournamentResultRecord] = []
    @State private var dfsTournaments: [String: DFSTournamentRecord] = [:]
    @State private var isLoading: Bool = true

    private var brandPurple: Color {
        Color(red: 0.48, green: 0.23, blue: 0.93)
    }

    private var appBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.94, green: 0.98, blue: 0.95),
                Color(red: 0.95, green: 0.97, blue: 1.00),
                Color(red: 0.98, green: 0.99, blue: 1.00)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Sport Inference

    private func pickemSport(matchId: String, matchName: String) -> String {
        // 1. ESPN-sourced picks have the sport key in the match ID
        if matchId.contains("basketball_nba") { return "NBA" }
        if matchId.contains("basketball_ncaab") { return "NCAAB" }
        if matchId.contains("baseball_mlb") { return "MLB" }
        if matchId.contains("icehockey_nhl") { return "NHL" }
        if matchId.contains("americanfootball_nfl") { return "NFL" }
        if matchId.contains("americanfootball_ncaaf") { return "NCAAF" }
        if matchId.contains("soccer_epl") { return "EPL" }
        if matchId.contains("soccer_uefa") { return "UCL" }
        if matchId.contains("tennis_") { return "Tennis" }

        // 2. Odds-only picks: infer from team names in matchName
        let name = matchName.lowercased()

        // NFL teams
        let nflTeams = ["chiefs", "eagles", "bills", "49ers", "cowboys", "ravens", "lions", "dolphins",
                        "packers", "bengals", "jets", "chargers", "seahawks", "steelers", "rams", "vikings",
                        "jaguars", "broncos", "texans", "bears", "saints", "buccaneers", "colts", "browns",
                        "falcons", "cardinals", "raiders", "titans", "commanders", "panthers", "patriots", "giants"]
        if nflTeams.contains(where: { name.contains($0) }) {
            // Distinguish NFL vs NCAAF: NFL team names are unique enough
            // But some overlap (e.g., "Tigers" could be college). Check for NFL-specific names first.
            return "NFL"
        }

        // NBA teams
        let nbaTeams = ["lakers", "celtics", "warriors", "bucks", "76ers", "sixers", "nets", "knicks",
                        "heat", "suns", "mavericks", "nuggets", "clippers", "cavaliers", "timberwolves",
                        "thunder", "grizzlies", "pelicans", "raptors", "hawks", "wizards", "pistons",
                        "rockets", "jazz", "spurs", "trail blazers", "blazers", "magic", "hornets", "pacers", "kings"]
        if nbaTeams.contains(where: { name.contains($0) }) { return "NBA" }

        // NHL teams
        let nhlTeams = ["bruins", "maple leafs", "canadiens", "red wings", "blackhawks", "penguins",
                        "flyers", "oilers", "avalanche", "lightning", "blue jackets", "wild", "predators",
                        "canucks", "flames", "senators", "islanders", "sabres", "coyotes", "kraken",
                        "hurricanes", "sharks", "ducks", "blue shirts", "golden knights", "panthers"]
        // Panthers overlap with NFL/NCAAF — check for hockey context
        if nhlTeams.contains(where: { name.contains($0) && $0 != "panthers" }) { return "NHL" }

        // MLB teams
        let mlbTeams = ["yankees", "red sox", "dodgers", "astros", "braves", "mets", "phillies",
                        "padres", "guardians", "orioles", "twins", "mariners", "blue jays", "rays",
                        "brewers", "diamondbacks", "d-backs", "white sox", "rockies", "royals", "reds",
                        "pirates", "nationals", "marlins", "athletics", "cubs", "tigers", "angels", "rangers"]
        // Tigers/Rangers overlap — but MLB "Tigers" = Detroit Tigers, NCAAF "Tigers" = Auburn/Clemson/etc.
        // Check for city + team combo patterns
        if mlbTeams.contains(where: { name.contains($0) && $0 != "tigers" && $0 != "rangers" }) { return "MLB" }

        // Soccer
        let eplTeams = ["arsenal", "chelsea", "liverpool", "manchester united", "manchester city", "man utd",
                        "man city", "tottenham", "spurs", "newcastle", "aston villa", "west ham", "brighton",
                        "crystal palace", "everton", "wolves", "wolverhampton", "fulham", "brentford",
                        "nottingham forest", "bournemouth", "luton", "burnley", "sheffield"]
        if eplTeams.contains(where: { name.contains($0) }) { return "EPL" }

        let uclTeams = ["real madrid", "barcelona", "bayern", "psg", "paris saint", "juventus", "inter milan",
                        "ac milan", "atletico madrid", "borussia dortmund", "porto", "benfica"]
        if uclTeams.contains(where: { name.contains($0) }) { return "UCL" }

        // NCAAF / NCAAB — college teams (catch-all for "@ University" or common college identifiers)
        let ncaafKeywords = ["bulldogs", "crimson tide", "volunteers", "gators", "seminoles", "wolverines",
                             "buckeyes", "longhorns", "sooners", "trojans", "ducks", "huskies", "wildcats",
                             "tigers", "rebels", "cowboys", "bears", "aggies", "knights", "cougars",
                             "mountaineers", "cyclones", "jayhawks", "hokies", "wolfpack", "tar heels",
                             "hurricanes", "cardinals", "boilermakers", "fighting irish", "spartans",
                             "cornhuskers", "razorbacks", "gamecocks", "golden gophers", "badgers",
                             "hawkeyes", "illini", "hoosiers", "nittany lions", "terrapins", "sun devils",
                             "beavers", "buffaloes", "red raiders", "horned frogs"]
        if ncaafKeywords.contains(where: { name.contains($0) }) {
            // Could be NCAAF or NCAAB — hard to tell. Default to NCAAF for football season picks.
            return "NCAAF"
        }

        return "Other"
    }

    private func dfsResultSport(_ tournamentID: String) -> String {
        if tournamentID.hasPrefix("nba-") { return "NBA" }
        if tournamentID.hasPrefix("ncaam-") { return "NCAAM" }
        if tournamentID.hasPrefix("mlb-") { return "MLB" }
        if tournamentID.hasPrefix("pga-") { return "PGA" }
        return "Other"
    }

    // MARK: - Computed Pick'em Data

    private var pickemBySport: [String: [SettledPickRecord]] {
        Dictionary(grouping: settledPicks) { pickemSport(matchId: $0.matchId, matchName: $0.matchName) }
    }

    private var pickemSports: [String] {
        let sports = pickemBySport.keys.sorted()
        return sports.isEmpty ? [] : ["All"] + sports
    }

    private var filteredPicks: [SettledPickRecord] {
        if selectedPickemSport == "All" { return settledPicks }
        return pickemBySport[selectedPickemSport] ?? []
    }

    // MARK: - Computed DFS Data

    private var dfsBySport: [String: [DFSTournamentResultRecord]] {
        Dictionary(grouping: dfsResults) { dfsResultSport($0.tournamentID) }
    }

    private var dfsSports: [String] {
        let sports = dfsBySport.keys.sorted()
        return sports.isEmpty ? [] : ["All"] + sports
    }

    private var filteredDFS: [DFSTournamentResultRecord] {
        if selectedDFSSport == "All" { return dfsResults }
        return dfsBySport[selectedDFSSport] ?? []
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            Picker("Category", selection: $selectedTab) {
                Text("Pick'em").tag(0)
                Text("DFS").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else if selectedTab == 0 {
                pickemContent
            } else {
                dfsContent
            }
        }
        .background(appBackground.ignoresSafeArea())
        .navigationTitle("Analytics")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            selectedTab = initialTab
            await loadAllData()
        }
    }

    // MARK: - Pick'em Content

    private var pickemContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                if pickemSports.isEmpty {
                    emptyState(icon: "sportscourt", message: "No pick'em data yet")
                } else {
                    sportPillSelector(sports: pickemSports, selected: $selectedPickemSport)
                    pickemSummaryCard
                    pickemResultsList
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    private var pickemSummaryCard: some View {
        let picks = filteredPicks
        let wins = picks.filter { $0.result == "win" }.count
        let losses = picks.filter { $0.result == "loss" }.count
        let total = wins + losses
        let winRate = total > 0 ? Int((Double(wins) / Double(total)) * 100) : 0
        let rrDelta = picks.reduce(0) { $0 + $1.rrDelta }

        return VStack(spacing: 16) {
            HStack(spacing: 0) {
                summaryStatView(title: "Record", value: "\(wins)-\(losses)")
                dividerLine
                summaryStatView(title: "Win Rate", value: "\(winRate)%")
                dividerLine
                summaryStatView(title: "RR", value: "\(rrDelta >= 0 ? "+" : "")\(rrDelta)", valueColor: rrDelta >= 0 ? .green : .red)
            }
        }
        .padding(.vertical, 20)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    private var pickemResultsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent Picks")
                .font(.headline)

            ForEach(filteredPicks) { pick in
                HStack {
                    Image(systemName: pick.result == "win" ? "checkmark.circle.fill" : (pick.result == "expired" ? "clock.fill" : "xmark.circle.fill"))
                        .font(.caption)
                        .foregroundStyle(pick.result == "win" ? .green : (pick.result == "expired" ? .secondary : .red))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(pick.matchName)
                            .font(.subheadline)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Text("Picked \(pick.pickedTeam)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if let date = pick.createdAt ?? pick.settledAt {
                                Text("•")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                Text(date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            if selectedPickemSport == "All" {
                                let sport = pickemSport(matchId: pick.matchId, matchName: pick.matchName)
                                Text(sport)
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(sportColor(sport).opacity(0.15))
                                    .foregroundStyle(sportColor(sport))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    Spacer()
                    Text("\(pick.rrDelta >= 0 ? "+" : "")\(pick.rrDelta)")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(pick.rrDelta >= 0 ? .green : .red)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    // MARK: - DFS Content

    private var dfsContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                if dfsSports.isEmpty {
                    emptyState(icon: "person.3", message: "No DFS data yet")
                } else {
                    sportPillSelector(sports: dfsSports, selected: $selectedDFSSport)
                    dfsSummaryCard
                    dfsResultsList
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    /// Return the stored rrDelta which accounts for tie-pooling.
    private func recalculatedDFSRR(_ result: DFSTournamentResultRecord) -> Int {
        result.rrDelta
    }

    private var dfsSummaryCard: some View {
        let results = filteredDFS
        let contests = results.count
        let rrDelta = results.reduce(0) { $0 + recalculatedDFSRR($1) }
        let avgFinish: String = {
            guard !results.isEmpty else { return "-" }
            let avgRank = Double(results.reduce(0) { $0 + $1.rank }) / Double(results.count)
            return String(format: "%.0f", avgRank)
        }()

        return VStack(spacing: 16) {
            HStack(spacing: 0) {
                summaryStatView(title: "Contests", value: "\(contests)")
                dividerLine
                summaryStatView(title: "Avg Finish", value: "#\(avgFinish)")
                dividerLine
                summaryStatView(title: "RR", value: "\(rrDelta >= 0 ? "+" : "")\(rrDelta)", valueColor: rrDelta >= 0 ? .green : .red)
            }
        }
        .padding(.vertical, 20)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    private var dfsResultsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent Contests")
                .font(.headline)

            ForEach(filteredDFS) { result in
                let sport = dfsResultSport(result.tournamentID)
                let tournament = dfsTournaments[result.tournamentID]
                let totalEntries = tournament?.totalEntries ?? 500
                let title = tournament?.title
                let date = result.createdAt ?? tournament?.lockTime

                HStack {
                    Image(systemName: dfsResultIcon(sport))
                        .font(.caption)
                        .foregroundStyle(sportColor(sport))
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            if selectedDFSSport == "All" {
                                Text(sport)
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(sportColor(sport).opacity(0.15))
                                    .foregroundStyle(sportColor(sport))
                                    .clipShape(Capsule())
                            }
                            if let title {
                                Text(title)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                            }
                        }
                        HStack(spacing: 4) {
                            Text("#\(result.rank)/\(totalEntries)")
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                            Text("\u{2022}")
                                .foregroundStyle(.tertiary)
                            Text(String(format: "%.1f pts", result.totalPoints))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let date {
                            Text(date.formatted(date: .abbreviated, time: .omitted))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    let rr = recalculatedDFSRR(result)
                    Text("\(rr >= 0 ? "+" : "")\(rr)")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(rr >= 0 ? brandPurple : .red)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    // MARK: - Shared Components

    private func sportPillSelector(sports: [String], selected: Binding<String>) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sports, id: \.self) { sport in
                    Button {
                        selected.wrappedValue = sport
                    } label: {
                        Text(sport)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(selected.wrappedValue == sport ? brandPurple : Color(.systemGray6))
                            .foregroundStyle(selected.wrappedValue == sport ? .white : .primary)
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func summaryStatView(title: String, value: String, valueColor: Color = .primary) -> some View {
        VStack(spacing: 6) {
            Text(value)
                .font(.title2.weight(.bold).monospacedDigit())
                .foregroundStyle(valueColor)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var dividerLine: some View {
        Rectangle()
            .fill(Color(.systemGray5))
            .frame(width: 1, height: 36)
    }

    private func emptyState(icon: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    private func sportColor(_ sport: String) -> Color {
        switch sport {
        case "NBA": return .orange
        case "NCAAB", "NCAAM": return .blue
        case "MLB": return .red
        case "NHL": return .cyan
        case "NFL": return .brown
        case "NCAAF": return .indigo
        case "PGA": return .green
        case "EPL", "UCL": return .purple
        case "Tennis": return .mint
        default: return brandPurple
        }
    }

    private func dfsResultIcon(_ sport: String) -> String {
        switch sport {
        case "NBA", "NCAAM": return "basketball.fill"
        case "MLB": return "baseball.fill"
        case "PGA": return "figure.golf"
        default: return "trophy.fill"
        }
    }

    // MARK: - Data Loading

    private func loadAllData() async {
        isLoading = true

        let pageSize = 200

        async let picksTask: [SettledPickRecord] = {
            var all: [SettledPickRecord] = []
            var offset = 0
            while true {
                guard let fetched = try? await SupabaseService.shared.fetchSettledPicks(
                    userID: userID, limit: pageSize, offset: offset, accessToken: accessToken
                ) else { break }
                all.append(contentsOf: fetched)
                if fetched.count < pageSize { break }
                offset += fetched.count
            }
            return all
        }()

        async let dfsTask: [DFSTournamentResultRecord] = {
            var all: [DFSTournamentResultRecord] = []
            var offset = 0
            while true {
                guard let fetched = try? await SupabaseService.shared.fetchUserDFSHistory(
                    userID: userID, limit: pageSize, offset: offset, accessToken: accessToken
                ) else { break }
                all.append(contentsOf: fetched)
                if fetched.count < pageSize { break }
                offset += fetched.count
            }
            return all
        }()

        async let tournamentsTask = try? SupabaseService.shared.fetchRecentTournaments(accessToken: accessToken)

        let (picks, dfs, tournaments) = await (picksTask, dfsTask, tournamentsTask)
        settledPicks = picks
        dfsResults = dfs
        if let tournaments {
            dfsTournaments = Dictionary(uniqueKeysWithValues: tournaments.map { ($0.id, $0) })
        }

        isLoading = false
    }
}
