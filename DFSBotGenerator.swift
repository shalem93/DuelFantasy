import Foundation

/// Lock-guarded LRU of per-slate bot pools, shared by every DFSBotGenerator
/// snapshot a view model hands out. Small, not single-slot: main-slate
/// generation and single-game pre-caches interleave, and a single slot made
/// them evict each other every batch (re-paying the ~100ms pool rebuild).
nonisolated final class DFSBotGenPoolsCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(key: String, value: DFSBotGenerator.BotGenPools)] = []

    func get(_ key: String) -> DFSBotGenerator.BotGenPools? {
        lock.lock(); defer { lock.unlock() }
        return entries.first(where: { $0.key == key })?.value
    }

    func put(_ key: String, _ value: DFSBotGenerator.BotGenPools) {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0.key == key }
        entries.append((key, value))
        if entries.count > 4 { entries.removeFirst() }
    }
}

/// DFS bot lineup generation, lifted out of DFSViewModel so it can run OFF the
/// main actor. The project defaults every type to @MainActor, and the 900-line
/// generator × 2000 bots × a 1,000+ player Saturday CFB pool ground the main
/// thread for 20s+ per contest — long enough for the iOS watchdog to kill the
/// app (0x8BADF00D, no crash row). This is a value snapshot of everything the
/// generator used to read from the view model (`DFSViewModel.makeBotGenerator`);
/// build one on the main actor, then call it from a detached task.
///
/// Behavior is unchanged from the view-model version — the code below is the
/// moved body, with the pools cache swapped for the lock-guarded class above.
nonisolated struct DFSBotGenerator: Sendable {
    let sport: String
    let activeTournamentID: String?
    let poolRevision: Int
    let slateGames: [DFSSlateGame]
    /// Game ids whose game has started (live info non-pre, or kickoff passed)
    /// at snapshot time — replaces the view model's `gameHasStarted`.
    let startedGameIDs: Set<String>
    let poolsCache: DFSBotGenPoolsCache

    private func gameHasStarted(_ gameID: String?) -> Bool {
        guard let gid = gameID else { return false }
        return startedGameIDs.contains(gid)
    }

    /// Whether a player matches a roster slot requirement.
    /// Handles DK roster slots: NBA (PG/SG/SF/PF/C/G/F/UTIL), MLB (P/C/1B/2B/3B/SS/OF),
    /// NHL (C/W/D/UTIL/G), Soccer (GK/DEF/MID/FWD/FLEX).
    func playerMatchesSlot(_ player: DFSPlayer, slot: String, isSingleGame: Bool = false) -> Bool {
        Self.playerMatchesSlot(player, slot: slot, isSingleGame: isSingleGame, sport: sport)
    }

    static func playerMatchesSlot(_ player: DFSPlayer, slot: String, isSingleGame: Bool = false, sport: String) -> Bool {
        let effectiveSport = sport
        switch slot {
        case "MVP":
            return true
        case "FLEX":
            // Soccer FLEX excludes goalkeepers — CLASSIC only. Showdown
            // (MVP + 5 FLEX) takes any position incl. GK, like DK.
            if effectiveSport == "EPL" || effectiveSport == "UCL" || effectiveSport == "WC" {
                return isSingleGame || player.position != "GK"
            }
            // Football CLASSIC FLEX = RB/WR/TE; Showdown FLEX takes any
            // position (DK allows multiple QBs in single-game). SKILL is the
            // settlement-inferred "some ball-toucher" position (box-score
            // shape can't split RB/WR/TE).
            if !isSingleGame, effectiveSport == "NFL" || effectiveSport == "CFB" {
                return ["RB", "WR", "TE", "SKILL"].contains(player.position)
            }
            return true
        case "SFLEX":
            // Football superflex: QB-eligible flex (DK college classic).
            return ["QB", "RB", "WR", "TE", "SKILL"].contains(player.position)
        case "RB", "WR", "TE":
            return player.position == slot || player.position == "SKILL"
        case "P":
            return player.position == "SP" || player.position == "RP" || player.position == "P"
        case "C/1B":
            return player.position == "C" || player.position == "1B"
        case "C":
            if effectiveSport == "NHL" {
                // NHL center slot accepts any skater (position data is imprecise)
                return player.position != "G"
            }
            if effectiveSport == "MLB" {
                return player.position == "C"
            }
            // NBA center
            return player.position == "C" || player.position == "PF/C" || player.position == "C/PF"
        case "W", "D":
            if effectiveSport == "NHL" {
                // NHL skater slots accept any skater — during settlement
                // we often can't distinguish exact positions from box score data.
                return player.position != "G"
            }
            return player.position == slot
        case "G":
            if effectiveSport == "NHL" {
                return player.position == "G"
            }
            // NBA guard slot (G = PG or SG)
            let pos = player.position
            return pos == "PG" || pos == "SG" || pos == "PG/SG" || pos == "SG/PG"
        case "F":
            // NBA forward slot (F = SF or PF)
            let pos = player.position
            return pos == "SF" || pos == "PF" || pos == "SF/PF" || pos == "PF/SF"
        case "UTIL":
            if effectiveSport == "MLB" {
                let pitcherPositions: Set<String> = ["SP", "RP", "P"]
                return !pitcherPositions.contains(player.position)
            }
            if effectiveSport == "NHL" {
                // UTIL = any skater (not goalie)
                return player.position != "G"
            }
            // NBA/other: UTIL = any player
            return true
        case "1B", "2B", "3B", "SS", "OF":
            // MLB individual position slots
            return player.position == slot
        case "PG", "SG", "SF", "PF":
            // NBA individual position slots — also accept dual positions
            let pos = player.position
            return pos == slot || pos.contains(slot)
        default:
            return player.position == slot
        }
    }

    /// Staggered soccer slate reservation. The field is generated when game 1's
    /// XI posts (~75 min pre-kickoff), so every bot drafts almost exclusively
    /// game-1 confirmed players — and late-swap (it only edits
    /// not-started+UNCONFIRMED slots) can never pull the bots into the later
    /// games. The whole field then stays clustered on the first match (the
    /// "all bots took from the first game" complaint).
    ///
    /// This parks a few cheap, POSITION-CORRECT placeholders from games that
    /// haven't started yet into each bot, so (a) the field spreads across the
    /// slate and (b) late-swap can later upgrade those reserved slots to each
    /// later game's confirmed starters as its XI drops. Placeholders are cheaper
    /// than what they replace, so the lineup only frees budget (which late-swap
    /// spends) — it never breaks the cap. Generation runs once and the field is
    /// frozen, so the per-bot randomness here causes no leaderboard churn.
    func reserveNotStartedGameSlots(_ lineup: [DFSPlayer], slots: [String?], poolForReservation: [DFSPlayer]) -> [DFSPlayer] {
        guard sport == "EPL" || sport == "UCL" || sport == "WC" else { return lineup }
        guard lineup.count == slots.count, slots.count >= 6 else { return lineup }
        // Split the slate by KICKOFF TIME, not started-state. Bot generation
        // fires as soon as the FIRST game's XI posts — ~75 minutes BEFORE it
        // kicks off — so at generation time NOTHING has started, and the old
        // started/not-started split no-op'd this whole function. That's how
        // the July 11 WC 2-game slate produced bots that were 100% game-1:
        // no later-game placeholders were parked, every slot held a confirmed
        // game-1 player, and the late-swap pass (which only edits
        // not-started+unconfirmed slots) had nothing to migrate into game 2.
        // "Early" = the earliest-kickoff game(s) anchoring generation, plus
        // anything already underway; "later" = strictly-later kickoffs that
        // haven't started.
        guard let earliestStart = slateGames.map(\.startTime).min() else { return lineup }
        let laterGames = slateGames
            .filter { $0.startTime > earliestStart && !gameHasStarted($0.id) }
            .sorted { $0.startTime < $1.startTime }
            .map(\.id)
        let laterSet = Set(laterGames)
        let earlySet = Set(slateGames.map(\.id)).subtracting(laterSet)
        guard !laterGames.isEmpty, !earlySet.isEmpty else { return lineup }

        var result = lineup
        var used = Set(result.map(\.id))
        // Reserve later-game slots roughly PROPORTIONAL to the later games'
        // share of the slate (2-game slate → ~3-4 of 8 slots, not 1-2), with
        // a floor of one per later game and per-bot variance — but always
        // keep a confirmed-starter core from the locking game (>= slots-4).
        let laterShare = Double(laterGames.count) / Double(max(1, slateGames.count))
        let proportional = Int((Double(slots.count) * laterShare).rounded(.down)) + Int.random(in: -1...1)
        let target = min(max(laterGames.count, proportional), max(1, slots.count - 4))
        var rr = Int.random(in: 0..<laterGames.count)   // round-robin start for spread
        func reservedCount() -> Int { result.filter { laterSet.contains($0.gameID ?? "") }.count }

        for slotIdx in result.indices.shuffled() {
            if reservedCount() >= target { break }
            // Only convert a slot currently held by an early-game player.
            guard earlySet.contains(result[slotIdx].gameID ?? "") else { continue }
            let pos = slots[slotIdx]
            var placeholder: DFSPlayer? = nil
            for offset in 0..<laterGames.count {
                let gid = laterGames[(rr + offset) % laterGames.count]
                placeholder = poolForReservation.filter {
                    $0.gameID == gid && !used.contains($0.id)
                        && (pos == nil || playerMatchesSlot($0, slot: pos!))
                }.min(by: { $0.salary < $1.salary })
                if placeholder != nil { rr = (rr + offset + 1) % laterGames.count; break }
            }
            guard let pick = placeholder else { continue }
            used.remove(result[slotIdx].id)
            used.insert(pick.id)
            result[slotIdx] = pick
        }
        return result
    }

    /// Build a competitive bot lineup with varied strategies, injury-adjusted projections,
    /// position diversity, salary cap enforcement, and budget optimization.
    /// Deterministic per-slate bot pools (see generateBotLineup). Cached per
    /// poolRevision so a 2000-bot field pays this cost once, not per bot.
    nonisolated struct BotGenPools {
        let eligible: [DFSPlayer]
        let botPool: [DFSPlayer]
        let upgradePool: [DFSPlayer]
        let mlbHasBattingOrders: Bool
    }

    private func botGenerationPools(
        from players: [DFSPlayer], lineupSize: Int,
        rosterSlots effectiveRosterSlots: [String]?, isSingleGame: Bool,
        effectiveSport: String, cacheable: Bool, cacheToken: String? = nil
    ) -> BotGenPools {
        let cacheKey = "\(cacheToken ?? "live")|\(poolRevision)|\(activeTournamentID ?? "-")|\(players.count)|\(lineupSize)|\(isSingleGame)|\(effectiveSport)|\(effectiveRosterSlots?.joined(separator: ",") ?? "-")"
        if cacheable, let cached = poolsCache.get(cacheKey) {
            return cached
        }
        // Filter out injured/out/IL players and zero-projection bench warmers.
        // NHL uses a higher projection floor (6.0) to exclude healthy scratches and
        // AHL call-ups who technically have roster spots but won't dress.
        // For single-game NHL, use a lower floor (3.0) so goalies aren't excluded.
        let projFloor: Double
        if effectiveSport == "NHL" {
            // NHL DNP-tightening pass — mirrors the NBA pattern. Old floors
            // (SG 5.0, classic 6.0) still admitted 4th-liners projected
            // 5-7 FPPG who DNP routinely in playoff slates. NBA went to
            // 12.0 SG / 8.0 classic and the field got noticeably more
            // competitive. NHL skater projections sit lower than NBA so
            // we don't go that high, but bumping both tiers cuts the
            // deep-bench DNP risk that still leaked through.
            //   SG 7.0 → excludes most bottom-six guys (typically 4-7 FPPG),
            //   keeps the value-tier $3.5K-$5K rotation regulars (8+ FPPG).
            //   Classic 8.0 → same effect on the wider 9-player roster.
            projFloor = isSingleGame ? 7.0 : 8.0
        } else if effectiveSport == "NFL" || effectiveSport == "CFB" {
            // Salary IS the signal for football (showdown weighting is
            // salary-based, preseason fades handle rest-risk). The generic
            // 1.0 projection floor zeroed out rookies/bubble players —
            // last-season stat projections are ~0 for them — and shrank a
            // preseason SG pool to ~lineupSize veterans, making all 2000
            // bots draft the IDENTICAL lineup (1 unique of 1999 saved).
            projFloor = -1.0
        } else if effectiveSport == "NBA" || effectiveSport == "NCAAM" {
            // NBA rotation players score 15+ FPPG (and stars 30+). Deep-bench
            // players like Lindy Waters (~$4,700 UTIL) sit around 6-10 FPPG and
            // routinely DNP — they get injected into the pool via Phase 2.5
            // because DK lists them on the SG slate, but bots shouldn't draft
            // them. SG floors run higher because rotations tighten in playoff
            // single-game slates.
            //
            // SG dropped 12.0 → 10.0 — the 12.0 floor was excluding legit
            // mid-tier rotation guys (Landry Shamet tier, 10-12 FPPG) entirely,
            // which left them at 0% ownership when they should have been
            // marginal-tier picks. 10.0 still cuts the 6-9 FPPG deep-bench
            // DNP risk but admits the rotation regulars who occasionally crack
            // a starting role.
            projFloor = isSingleGame ? 10.0 : 8.0
        } else {
            projFloor = 1.0
        }
        // For NHL we have a `playedRecently` flag derived from recent boxscores. If any
        // skaters on a team are flagged active, we use that signal to exclude DNPs that
        // are technically still rostered (retired, healthy scratches, AHL assignments).
        let nhlHasRecencyData = effectiveSport == "NHL" && players.contains { $0.playedRecently }

        let eligible = players.filter { p in
            let status = p.injuryStatus ?? ""
            var isOut = status == "O" || status == "D" || status.hasPrefix("IL")
            // NHL: GTD players frequently don't dress — exclude from bot pool
            if effectiveSport == "NHL" && status == "GTD" { isOut = true }
            // NHL: require minimum games played to filter AHL call-ups, healthy
            // scratches, and part-time players. Both tiers bumped to match
            // the projection-floor tightening pass:
            //   SG 40 GP → playoff rotation regulars only (~half a season)
            //   Classic 30 GP → established roster guys, not call-ups
            let minGP = effectiveSport == "NHL" ? (isSingleGame ? 40 : 30) : 20
            if effectiveSport == "NHL", let gp = p.gamesPlayed, gp < minGP { isOut = true }
            // NHL: when recency data is available, require skaters to have played recently.
            // This catches DNPs that pass the GP threshold (retired mid-season, prolonged
            // healthy scratch, etc.) — goalies are exempt since they cycle starts.
            if nhlHasRecencyData, p.position != "G", !p.playedRecently { isOut = true }
            // NHL SG: hard-require recent play for skaters regardless of the
            // global `nhlHasRecencyData` flag. Previously this gate only fired
            // when SOME other player had recency data — but a team whose last
            // game fell outside the 7-day lookback (rest days between playoff
            // rounds, etc.) had no recency for ANY of its skaters, leaving
            // `playedRecently=false` defaults to slip through. Strict required
            // recency at the per-player level eliminates that escape hatch.
            // Combined with isConfirmedActive (DK salary list) this gives the
            // two-signal confirmation: dressed last game AND on tonight's DK
            // slate.
            if effectiveSport == "NHL" && isSingleGame && p.position != "G" {
                if !p.isConfirmedActive || !p.playedRecently { isOut = true }
            }
            // NHL SG goalies: ONLY confirmed starters allowed. The previous
            // logic un-excluded starters but didn't exclude backups — so a
            // team's backup goalie (high salary, sitting on the bench) could
            // still end up in 20%+ of bot lineups. Exclude any goalie that
            // isn't the confirmed starter for tonight's game.
            if effectiveSport == "NHL" && isSingleGame && p.position == "G" && !p.isStartingGoalie {
                isOut = true
            }
            // NHL single-game: confirmed starting goalies are NEVER excluded regardless of GP
            if effectiveSport == "NHL" && p.position == "G" && p.isStartingGoalie { isOut = false }
            // Confirmed starting goalies bypass the projection floor entirely —
            // a call-up making his first starts (Bussi) projects ~0.0 from
            // career stats but is still THE goalie bots must draft.
            if effectiveSport == "NHL" && p.position == "G" && p.isStartingGoalie {
                return !isOut
            }
            // NHL goalies use a lower projection floor — they naturally score fewer
            // fantasy points than skaters but are required roster positions
            let floor = (effectiveSport == "NHL" && p.position == "G") ? 1.0 : projFloor
            return !isOut && p.projectedPoints > floor
        }

        // Strongly prefer confirmed active players (matched by real salary data).
        // NHL uses a lower threshold because RotoGrinders NHL pools are smaller.
        let confirmed = eligible.filter { $0.isConfirmedActive }
        let confirmedThreshold = (effectiveSport == "NHL") ? lineupSize + 5 : lineupSize * 2
        let useConfirmedPool = confirmed.count >= confirmedThreshold

        // For MLB: strongly prefer confirmed starters to avoid drafting bench players.
        // Strategy: use battingOrder when available; fall back to projection threshold.
        let hasRosterSlots = effectiveRosterSlots != nil
        let strictBotPool: [DFSPlayer]
        // Track whether we have MLB batting order data to boost confirmed starters in weighting
        var mlbHasBattingOrders = false
        if hasRosterSlots, let slots = effectiveRosterSlots {
            // Check that a candidate pool can fill every required position slot
            func coversAllSlots(_ pool: [DFSPlayer]) -> Bool {
                for slot in Set(slots) {
                    let hasMatch = pool.contains { self.playerMatchesSlot($0, slot: slot, isSingleGame: isSingleGame) }
                    if !hasMatch { return false }
                }
                return true
            }

            // Start with confirmed active players if available (matched by real salary data)
            let basePool = useConfirmedPool ? confirmed : eligible

            // Soccer: `isConfirmedActive` is set when ESPN publishes the
            // starting XI (~1h before kickoff). Use confirmed players
            // exclusively when they cover all positions — bench/squad
            // players have meaningful projections (squad rotation, late
            // subs) and would otherwise slip into bot lineups through the
            // "likelyStarters" projection path below. Mirrors the MLB
            // `battingOrder` lock.
            let isSoccerLeague = effectiveSport == "EPL" || effectiveSport == "UCL" || effectiveSport == "WC"
            // Projected-starter tier, per-team aware: for any team whose XI is
            // already announced use ONLY its confirmed starters (unconfirmed
            // players on that team are benched, not "projected"); for teams
            // without an XI yet, fall back to recent-match participants
            // (warm-up friendlies for the World Cup).
            let soccerHybridPool: [DFSPlayer] = {
                guard isSoccerLeague else { return [] }
                let xiTeams = Set(eligible.filter { $0.isConfirmedActive && !$0.team.isEmpty }.map(\.team))
                // Teams without an announced XI that DID get a likely-starter
                // signal (ESPN predicted XI or a recent-match starter — see
                // SoccerDFSData's `playedRecently` marking). For these we trust
                // that signal and DON'T pull in extra players by salary: a
                // high price alone doesn't mean a player starts (stars get
                // rested/rotated), and rostering DNPs is exactly what we want
                // to avoid.
                let likelyStarterTeams = Set(eligible.filter { $0.playedRecently && !$0.team.isEmpty }.map(\.team))
                // Last resort: a team with NEITHER an announced XI NOR any
                // likely-starter signal (no predicted XI published, no recent
                // matches in the lookback) would contribute zero players and
                // land at 0% bot ownership — the original late-game bug. Only
                // for those signal-less teams do we fall back to top salaries
                // as a rough XI proxy, so every game still gets representation.
                var salaryProxyIDs = Set<String>()
                let signalLessTeams = Set(eligible.map(\.team))
                    .subtracting(xiTeams)
                    .subtracting(likelyStarterTeams)
                    .subtracting([""])
                for team in signalLessTeams {
                    let topBySalary = eligible.filter { $0.team == team }
                        .sorted { $0.salary > $1.salary }
                        .prefix(11)
                    salaryProxyIDs.formUnion(topBySalary.map(\.id))
                }
                if !signalLessTeams.isEmpty {
                    print("[DFS-\(effectiveSport)] Bot pool: no XI/recency signal for \(signalLessTeams.sorted()) — using top salaries as XI proxy")
                }
                return eligible.filter { p in
                    if xiTeams.contains(p.team) { return p.isConfirmedActive }
                    if likelyStarterTeams.contains(p.team) { return p.playedRecently }
                    return salaryProxyIDs.contains(p.id)
                }
            }()
            // Prefer the hybrid pool: it already restricts announced teams to
            // their confirmed XI, so it equals the confirmed-only pool when
            // every game's XI is out — but on a MIXED slate (early game
            // announced, late game still projected) confirmed-only would
            // exclude the unannounced game entirely. Hybrid keeps that game's
            // likely starters in the field. The 1.3x confirmed boost in the
            // weighting below still leans bots toward the announced certainties.
            if isSoccerLeague && soccerHybridPool.count >= lineupSize * 2 && coversAllSlots(soccerHybridPool) {
                print("[DFS-\(effectiveSport)] Bot pool: using \(soccerHybridPool.count) starters (confirmed XI where announced, recent/likely starters elsewhere)")
                strictBotPool = soccerHybridPool
            } else if isSoccerLeague && useConfirmedPool && coversAllSlots(confirmed) {
                strictBotPool = confirmed
            } else {

            let confirmedStarters = basePool.filter { $0.battingOrder != nil || $0.position == "SP" }
            // "Batting orders are available" must mean actual BATTERS carry an
            // order — not just that the slate has pitchers. `|| position ==
            // "SP"` made this true with zero lineups posted, and the weighting
            // below then gave the two SPs a 10x boost while every batter took
            // 0.02x: a 500x swing that pinned both pitchers near 100% owned on
            // showdowns. Require a real batting order on several batters.
            let batsWithOrder = basePool.filter { $0.battingOrder != nil }.count
            if effectiveSport == "MLB" && batsWithOrder >= 4 {
                mlbHasBattingOrders = true
            }
            if effectiveSport == "MLB" && isSingleGame && mlbHasBattingOrders
                && confirmedStarters.count >= lineupSize && coversAllSlots(confirmedStarters) {
                // MLB SHOWDOWN with lineups posted: draft ONLY the announced
                // batting order plus the starters, exactly like soccer's
                // confirmed-XI rule. Weighting alone still let bench catchers
                // through (Banfield, Knizner — both 0-for-0 DNPs), and on a
                // 6-slot showdown one DNP is a sixth of the lineup.
                strictBotPool = confirmedStarters
            } else if confirmedStarters.count >= lineupSize + 5 && coversAllSlots(confirmedStarters) {
                // Batting orders available and cover all positions — use confirmed starters only
                strictBotPool = confirmedStarters
            } else if effectiveSport == "MLB" && mlbHasBattingOrders && coversAllSlots(confirmedStarters) {
                // Some batting orders available but not enough to fill pool exclusively —
                // use full pool but weighting will heavily prefer confirmed starters
                strictBotPool = basePool
            } else {
                // Batting orders not yet posted or don't cover all positions —
                // use projection/salary as a proxy.
                let likelyStarters = basePool.filter { $0.projectedPoints >= 6.0 || $0.position == "SP" || $0.position == "G" }
                // Football also needs DEPTH per slot, not mere coverage: the
                // 6.0-projection trim can leave 1-2 candidates per position
                // (preseason projections cluster low), and with one candidate
                // per slot every bot drafts the IDENTICAL lineup — the
                // 98-100%-ownership field with three-way score ties. Require
                // ~3 candidates per slot instance before trusting the trim.
                let isFootballSport = effectiveSport == "NFL" || effectiveSport == "CFB"
                func hasSlotDepth(_ pool: [DFSPlayer]) -> Bool {
                    var needed: [String: Int] = [:]
                    for slot in slots { needed[slot, default: 0] += 3 }
                    for (slot, count) in needed {
                        let have = pool.filter { self.playerMatchesSlot($0, slot: slot, isSingleGame: isSingleGame) }.count
                        if have < count { return false }
                    }
                    return true
                }
                if likelyStarters.count >= lineupSize * 2 && coversAllSlots(likelyStarters)
                    && (!isFootballSport || hasSlotDepth(likelyStarters)) {
                    strictBotPool = likelyStarters
                } else {
                    // Fall back to full eligible pool (confirmed first, then all)
                    strictBotPool = useConfirmedPool && coversAllSlots(confirmed) ? confirmed : eligible
                }
            }

            }  // close soccer-confirmed-XI else wrapper
        } else {
            // NHL, NBA, NCAAM — use confirmed active pool when available
            if useConfirmedPool {
                strictBotPool = confirmed
            } else {
                strictBotPool = eligible
            }
        }

        // For NHL, restrict the upgrade pass to confirmed-active players only
        // to prevent swapping in healthy scratches during salary optimization.
        // For MLB, restrict to confirmed starters when batting orders are available
        // to prevent upgrading into bench players who will score 0.
        let upgradePool: [DFSPlayer]
        if effectiveSport == "NHL" && !confirmed.isEmpty {
            // NHL classic: confirmed pool is fine. NHL single-game pool is
            // tight enough (~10 confirmed players for 6 slots) that the
            // upgrade pass runs out of candidates after 1-2 swaps and
            // leaves bots underspending the cap. Use the broader `eligible`
            // pool for SG upgrades — it still enforces GP/projection/recency
            // filters, just doesn't require the (sometimes-sparse) RG
            // salary match.
            upgradePool = isSingleGame ? eligible : confirmed
        } else if effectiveSport == "MLB" && mlbHasBattingOrders {
            let starterUpgrades = strictBotPool.filter { $0.battingOrder != nil || $0.position == "SP" }
            upgradePool = starterUpgrades.isEmpty ? strictBotPool : starterUpgrades
        } else {
            upgradePool = strictBotPool
        }

        // Pool collapse handling. The old fallback was
        // `players.shuffled().prefix(lineupSize)` — PURE RANDOM lineups,
        // scratches and backup goalies included, no cap discipline. That's
        // where the $35K / 4-DNP bot fields came from whenever the strict
        // gates rejected everyone (e.g. SG pools missing recency flags).
        // Instead, relax the ACTIVITY gates step by step while never
        // relaxing the safety rules: no injured players, no non-starting
        // NHL SG goalies.
        let botPool: [DFSPlayer] = {
            if strictBotPool.count >= lineupSize { return strictBotPool }
            if eligible.count >= lineupSize {
                print("[DFS-\(effectiveSport)] Bot pool collapsed to \(strictBotPool.count) — using \(eligible.count) eligible players")
                return eligible
            }
            let relaxed = players.filter { p in
                let status = p.injuryStatus ?? ""
                let injured = status == "O" || status == "D" || status == "GTD" || status.hasPrefix("IL")
                if injured { return false }
                if effectiveSport == "NHL" && isSingleGame && p.position == "G" && !p.isStartingGoalie { return false }
                return true
            }
            print("[DFS-\(effectiveSport)] Bot pool collapsed to \(strictBotPool.count)/\(eligible.count) — relaxed activity gates to \(relaxed.count) healthy players")
            return relaxed.count >= lineupSize ? relaxed : players
        }()
        let value = BotGenPools(
            eligible: eligible, botPool: botPool,
            upgradePool: upgradePool, mlbHasBattingOrders: mlbHasBattingOrders
        )
        if cacheable {
            poolsCache.put(cacheKey, value)
        }
        return value
    }

    func generateBotLineup(from players: [DFSPlayer], salaryCap: Int, lineupSize: Int, rosterSlots: [String]? = nil, isSingleGame: Bool = false, sportOverride: String? = nil, settlementCacheToken: String? = nil) -> [String] {
        // Use sportOverride when provided (e.g., during settlement of a different sport's tournament)
        let effectiveSport = sportOverride ?? sport
        // PGA bots have no position constraints — use salary-weighted random generation
        if effectiveSport == "PGA" {
            return generateGolfBotLineup(from: players, salaryCap: salaryCap, lineupSize: lineupSize)
        }
        // DraftKings Showdown uses MVP + 5 FLEX with no position requirements,
        // so no goalie override needed for NHL single-game.
        let effectiveRosterSlots: [String]? = rosterSlots
        // The pool-building prefix (eligibility, confirmed starters, soccer
        // hybrid XI, slot coverage, upgrade pool) is IDENTICAL for every bot
        // in a field — only the per-bot noise/exclusions differ. Recomputing
        // it per bot made each EPL bot cost ~100ms (full-pool filters +
        // team-set builds x 2000 bots = minutes of main-actor work — the
        // "Bot pool: using N starters" log spam and the builder freeze).
        // Memoized per slate; settlement (sportOverride) skips the cache
        // since it feeds custom pools.
        // Settlement (sportOverride) can't use the live cache key, but its
        // pool is stable WITHIN one settle call — the caller passes a
        // per-call token so 2000 bots pay the pool cost once, not per bot
        // (uncached, the NFL Aft settle ground for 2.5 HOURS).
        let pools = botGenerationPools(
            from: players, lineupSize: lineupSize,
            rosterSlots: effectiveRosterSlots, isSingleGame: isSingleGame,
            effectiveSport: effectiveSport,
            cacheable: sportOverride == nil || settlementCacheToken != nil,
            cacheToken: settlementCacheToken
        )
        let eligible = pools.eligible
        let upgradePool = pools.upgradePool
        let botPool = pools.botPool
        let mlbHasBattingOrders = pools.mlbHasBattingOrders
        guard botPool.count >= lineupSize else {
            // Truly nothing to draft from (pool smaller than a lineup) —
            // return best-effort by projection rather than random.
            return players.sorted { $0.projectedPoints > $1.projectedPoints }.prefix(lineupSize).map(\.id)
        }

        // Scramble projections so each bot sees a different player landscape.
        // This is the primary source of lineup diversity.
        // Single-game contests have small pools (~12 players for 6 slots), so
        // use much heavier noise + random exclusions to prevent identical lineups.
        // Soccer/EPL/UCL needs very heavy noise because the confirmed starter pool
        // is tiny (~22 players for 8 slots) and projections cluster tightly.
        let avgProj = botPool.reduce(0.0) { $0 + $1.projectedPoints } / Double(botPool.count)
        let isSoccer = effectiveSport == "EPL" || effectiveSport == "UCL" || effectiveSport == "WC"
        let noiseMagnitude: Double
        if isSingleGame {
            // 35% noise (was 70%). The old setting made every bot's
            // projection landscape nearly random, so 2000-entry NHL/MLB SG
            // contests had ~0 sharp lineups — top bot routinely sat at
            // ~87 FPTS when an optimized lineup should hit 110+. Tighter
            // noise lets sharp bot styles actually lean on projection.
            noiseMagnitude = max(avgProj * 0.35, 2.0)
        } else if isSoccer {
            noiseMagnitude = max(avgProj * 1.0, 6.0) // 100% noise for soccer — pool is tiny
        } else {
            noiseMagnitude = max(avgProj * 0.35, 2.0)
        }
        // Bot personality — defined here so SG exclusion logic can gate
        // on style (sharp styles skip exclusions to keep top players in
        // their view).
        let botStyle = Int.random(in: 0..<5)

        // Football preseason recency: teams where the slate provider read
        // last week's box score (playedRecently is meaningful). Empty in
        // the regular season and in preseason week 1.
        let footballRecencyTeams: Set<String> = (effectiveSport == "NFL" || effectiveSport == "CFB")
            ? Set(players.filter { $0.playedRecently }.map(\.team))
            : []
        // August NFL = preseason (CFB has no preseason; its regular season
        // starts late Aug and shouldn't be veteran-faded).
        let isFootballPreseason = effectiveSport == "NFL"
            && Calendar.current.component(.month, from: Date()) == 8

        // Single-game & soccer: randomly exclude players to force different combinations.
        // Soccer pools are tiny (~22 starters for 8 slots) so excluding 3-6 players
        // is the strongest lever for lineup diversity.
        var sgExcludedIDs = Set<String>()
        // Football SG: salary is the weighting signal, but the priciest
        // player can be a healthy scratch (preseason: Jeremiyah Love,
        // $14.1K, 99% MVP-owned, never played). Cap concentration by
        // excluding the top salaries from a probabilistic share of bots —
        // top1 from ~55%, top2 ~35%, top3 ~20% — for ALL styles, so no
        // single player can approach full-field ownership.
        if isSingleGame && (effectiveSport == "NFL" || effectiveSport == "CFB") && botPool.count > lineupSize + 3 {
            // Rank among players NOT already faded (recency-resters, and in
            // August the 10+ GP veterans) — burning the ladder on players
            // the weights already buried left the real chalk uncapped.
            let recencyTeams: Set<String> = Set(botPool.filter { $0.playedRecently }.map(\.team))
            let isAugustNFL = effectiveSport == "NFL" && Calendar.current.component(.month, from: Date()) == 8
            let ladderPool = botPool.filter { p in
                if recencyTeams.contains(p.team) { return p.playedRecently }
                if isAugustNFL { return (p.gamesPlayed ?? 0) < 10 }
                return true
            }
            let topBySalary = (ladderPool.isEmpty ? botPool : ladderPool).sorted { $0.salary > $1.salary }
            // Top-5 ladder: with only the top-3 covered, the 2nd/3rd
            // priciest no-shows still hit 80-96% ownership on small
            // preseason pools.
            let dropProbabilities: [Double] = [0.50, 0.38, 0.28, 0.20, 0.14]
            for (index, probability) in dropProbabilities.enumerated() where index < topBySalary.count {
                if Double.random(in: 0...1) < probability {
                    sgExcludedIDs.insert(topBySalary[index].id)
                }
            }
        }
        // MLB showdown: both starting pitchers were landing at 100% ownership —
        // the generic exclusion pass below exempts SP/RP entirely and pitcher
        // projections dwarf batters', so every bot rostered both. Real DK
        // showdown fields fade starters too: drop each pitcher from ~30% of
        // bots so pitcher ownership tops out around 70%, not 100%.
        if isSingleGame && effectiveSport == "MLB" && botPool.count > lineupSize + 2 {
            // 45%, up from 30%: at 30% a pitcher could still reach ~90-100%
            // ownership because his projection dwarfs every batter's, so the
            // bots that COULD draft him nearly all did. Fading each starter
            // from ~45% of fields caps him near 55% and forces real lineup
            // diversity, which is what a DK showdown field actually looks like.
            for p in botPool where p.position == "SP" || p.position == "RP" {
                if Double.random(in: 0...1) < 0.45 { sgExcludedIDs.insert(p.id) }
            }
        }
        if isSingleGame && botPool.count > lineupSize + 2 {
            // MLB single-game: exclude 2-4 starters for maximum diversity with ~18 batters.
            // NHL: stricter — only 60% of bots get an exclusion at all, and
            // those exclude only 1 player. Most NHL SG pools are 10-12
            // confirmed players for 6 slots; aggressive exclusions removed
            // top stars from sharp bots' view, capping leaderboard scores.
            // Casual bots (style 4 default) still get random exclusions to
            // preserve some lineup diversity.
            let maxExclude: Int
            if effectiveSport == "MLB" {
                maxExclude = min(4, botPool.count - lineupSize - 1)
            } else if effectiveSport == "NHL" {
                // Skip exclusion for sharp styles (0-2); only casual styles
                // 3-4 see exclusions, and only 40% of them.
                if botStyle >= 3 && Double.random(in: 0...1) < 0.4 {
                    maxExclude = min(1, botPool.count - lineupSize - 1)
                } else {
                    maxExclude = 0
                }
            } else {
                maxExclude = min(2, botPool.count - lineupSize - 1)
            }
            if maxExclude > 0 {
                let excludeCount = maxExclude > 1 ? Int.random(in: 1...maxExclude) : 1
                // Never exclude confirmed starting goalies from NHL pools
                // Never exclude starting pitchers from MLB pools
                let excludable = botPool.filter { p in
                    if effectiveSport == "NHL" && p.position == "G" && (p.isStartingGoalie || (p.isConfirmedActive && (p.gamesPlayed ?? 0) >= 30)) { return false }
                    if effectiveSport == "MLB" && (p.position == "SP" || p.position == "RP") { return false }
                    return true
                }
                let shuffledPool = excludable.shuffled()
                for p in shuffledPool.prefix(excludeCount) {
                    sgExcludedIDs.insert(p.id)
                }
            }
        } else if isSoccer && botPool.count > lineupSize + 3 {
            // Exclude 3-6 players per bot to force very different combinations.
            // With ~22 starters and 8 slots, excluding 3-6 is aggressive but necessary.
            let maxExclude = min(6, botPool.count - lineupSize - 1)
            let excludeCount = maxExclude > 3 ? Int.random(in: 3...maxExclude) : max(1, maxExclude)
            // Bias exclusions toward PROJECTED (late-game, unconfirmed)
            // players: consume them first, only reaching confirmed starters
            // if a bot needs more exclusions than there are projected players.
            // This keeps confirmed starters in most lineups (heavy confirmed
            // lean) while late-game stars cycle in and out across the field —
            // the variance the user wants on the later games without letting
            // those riskier picks dominate ownership.
            let projectedFirst = botPool.filter { !$0.isConfirmedActive }.shuffled()
                + botPool.filter { $0.isConfirmedActive }.shuffled()
            for p in projectedFirst.prefix(excludeCount) {
                sgExcludedIDs.insert(p.id)
            }
        }
        let scrambled: [DFSPlayer] = botPool.compactMap { p in
            if sgExcludedIDs.contains(p.id) { return nil }
            let noise = Double.random(in: -noiseMagnitude...noiseMagnitude)
            // Mixed soccer slates (early game XI announced, late game still
            // projected): lean HEAVILY on CONFIRMED starters — they're a
            // certainty; projected late-game players carry rotation risk.
            // The 1.5x boost (with the projected-biased exclusion below)
            // keeps confirmed starters as the backbone of most bot lineups
            // while still letting high-projection late-game stars surface.
            var baseProj = p.projectedPoints
            if isSoccer && p.isConfirmedActive { baseProj *= 1.5 }
            // Soccer staggered slates: an UNCONFIRMED player is a later-game
            // slot whose XI isn't out yet — a placeholder the late-swap pass
            // will upgrade to a confirmed starter once that game's lineup
            // posts. Bias bots toward CHEAP unconfirmed fills, scaled by price:
            //   (a) stops bots over-rostering expensive non-starters (the $8K
            //       Ollie Watkins problem — he isn't confirmed but his price
            //       pulled him into 16% of lineups), and
            //   (b) reserves salary so the late swap can actually afford the
            //       confirmed late-game studs (Luis Díaz $9.5K, Suárez $8K)
            //       that were landing at 0% because the budget was already
            //       spent on early-game certainties.
            if isSoccer && !p.isConfirmedActive {
                // priceFactor ~1.0 when the player costs an average slot's
                // worth of cap, higher when pricier. Pricier => bigger cut.
                let priceFactor = Double(p.salary) / (Double(salaryCap) / Double(max(1, lineupSize)))
                baseProj *= max(0.35, 1.0 - 0.45 * priceFactor)
            }
            let newProj = max(baseProj + noise, 0.5)
            var scrambledPlayer = DFSPlayer(
                id: p.id, name: p.name, team: p.team, position: p.position,
                salary: p.salary, projectedPoints: newProj, gameID: p.gameID,
                injuryStatus: p.injuryStatus, battingOrder: p.battingOrder
            )
            scrambledPlayer.gamesPlayed = p.gamesPlayed
            scrambledPlayer.playedRecently = p.playedRecently
            scrambledPlayer.isConfirmedActive = p.isConfirmedActive
            scrambledPlayer.isStartingGoalie = p.isStartingGoalie
            return scrambledPlayer
        }

        let originalSlots: [String?] = effectiveRosterSlots?.map { Optional($0) } ?? [String?](repeating: nil, count: lineupSize)

        // For NHL classic, draft the goalie early (pick 3) so budget isn't exhausted
        // on skaters first. This ensures all starting goalies are affordable and the
        // flatter goalie weighting produces real ownership diversity.
        // We build a pick-order that moves "G" earlier, then reorder results back.
        let pickOrder: [Int]
        if effectiveSport == "NHL" && !isSingleGame,
           let gIdx = originalSlots.firstIndex(where: { $0 == "G" }), gIdx > 2 {
            // Move goalie slot to pick index 2 (3rd overall)
            var order = Array(0..<lineupSize)
            order.remove(at: gIdx)
            order.insert(gIdx, at: 2)
            pickOrder = order
        } else {
            pickOrder = Array(0..<lineupSize)
        }
        let slots = originalSlots

        // NHL and NBA bots must spend closer to the cap — with 8 players and $50K cap,
        // underspending makes contests trivially easy.
        // Soccer uses a lower floor because the tiny pool (~22 players) means forcing
        // 92%+ spend causes all bots to converge on the same high-salary players.
        // Single-game modes use variable floors for lineup diversity — small pools
        // with tight spending requirements cause all bots to converge on the same players.
        let minSpendPct: Double
        if isSingleGame {
            // Single-game: bump spend floor toward cap so bots actually use ~$50K,
            // not the ~$38K we were seeing. Small pools still get variance from
            // bot styles and weighted picking; the floor just ensures the lineup
            // ISN'T under-spent.
            switch effectiveSport {
            case "MLB":
                minSpendPct = Double.random(in: 0.92...0.99) // $46K-$49.5K of $50K
            case "NHL", "NBA", "NCAAM":
                minSpendPct = Double.random(in: 0.94...0.99) // $47K-$49.5K of $50K
            default:
                minSpendPct = Double.random(in: 0.90...0.98)
            }
        } else if effectiveSport == "NHL" || effectiveSport == "NBA" || effectiveSport == "NCAAM" {
            minSpendPct = 0.95
        } else if isSoccer {
            minSpendPct = 0.82  // Allow more salary variance for diversity
        } else {
            minSpendPct = 0.92
        }
        let minSpend = Int(Double(salaryCap) * minSpendPct)
        let cheapestSalary = scrambled.map(\.salary).min() ?? 3000

        // (botStyle hoisted up to where SG exclusions need it)

        // NHL single-game (Showdown): 20% of bots skip goalies entirely so ownership
        // settles around ~80% instead of 100% (real DK ownership is rarely that lopsided).
        let nhlSkipGoalie = effectiveSport == "NHL" && isSingleGame && Double.random(in: 0...1) < 0.20

        // Try up to 50 times to build a valid lineup (more retries needed for tight 95% floors)
        for _ in 0..<50 {
            var selectedBySlot: [Int: DFSPlayer] = [:]
            var budgetLeft = salaryCap
            var usedIDs = Set<String>()
            var pool = nhlSkipGoalie ? scrambled.filter { $0.position != "G" } : scrambled

            for (draftStep, slotIndex) in pickOrder.enumerated() {
                let slotsLeft = lineupSize - draftStep
                let slotsAfter = slotsLeft - 1

                // Reserve budget for remaining slots at minimum salary
                let reserveForRest = slotsAfter * cheapestSalary
                let maxForThisPick = budgetLeft - reserveForRest

                // Filter to affordable players within the max for this pick
                // Single-game MVP costs 1.5x, so limit to players whose 1.5x salary fits
                let mvpPick = isSingleGame && slotIndex == 0
                var affordable = pool.filter { mvpPick ? Int(Double($0.salary) * 1.5) <= maxForThisPick : $0.salary <= maxForThisPick }

                // If this slot requires a specific position, filter by position
                if let requiredPos = slots[slotIndex] {
                    affordable = affordable.filter { playerMatchesSlot($0, slot: requiredPos, isSingleGame: isSingleGame) }
                }

                // NHL goalie handling: Remove backup goalies from the pool.
                // For main slate (G slot): filter affordable to only starting goalies.
                // For single-game (FLEX slots): remove backup goalies from the pool
                // entirely so bots only roster confirmed starters.
                if effectiveSport == "NHL" && slots[slotIndex] == "G" {
                    // Main slate G slot — filter to starting goalies only
                    let confirmedStarters = affordable.filter { $0.isStartingGoalie }
                    if !confirmedStarters.isEmpty {
                        affordable = confirmedStarters
                    } else {
                        // Group goalies by team, pick the one with the most games played per team
                        var bestGoaliePerTeam: [String: DFSPlayer] = [:]
                        for goalie in affordable {
                            let team = goalie.team
                            if let existing = bestGoaliePerTeam[team] {
                                if (goalie.gamesPlayed ?? 0) > (existing.gamesPlayed ?? 0) {
                                    bestGoaliePerTeam[team] = goalie
                                }
                            } else {
                                bestGoaliePerTeam[team] = goalie
                            }
                        }
                        let starters = Array(bestGoaliePerTeam.values)
                        if !starters.isEmpty {
                            affordable = starters
                        }
                    }
                }
                // Single-game NHL FLEX slots: also remove backup goalies so bots
                // never draft non-starting goalies in showdown format.
                if effectiveSport == "NHL" && isSingleGame && slots[slotIndex] != "G" {
                    let goaliesInPool = affordable.filter { $0.position == "G" }
                    let confirmedGoalies = goaliesInPool.filter { $0.isStartingGoalie }
                    if !confirmedGoalies.isEmpty {
                        // Remove all non-starting goalies; keep all non-goalies + confirmed starters
                        let confirmedGoalieIDs = Set(confirmedGoalies.map { $0.id })
                        affordable = affordable.filter { p in
                            if p.position == "G" { return confirmedGoalieIDs.contains(p.id) }
                            return true
                        }
                    } else if goaliesInPool.count > 1 {
                        // No confirmed starters — keep only the best goalie per team by GP
                        var bestGoaliePerTeam: [String: DFSPlayer] = [:]
                        for goalie in goaliesInPool {
                            if let existing = bestGoaliePerTeam[goalie.team] {
                                if (goalie.gamesPlayed ?? 0) > (existing.gamesPlayed ?? 0) {
                                    bestGoaliePerTeam[goalie.team] = goalie
                                }
                            } else {
                                bestGoaliePerTeam[goalie.team] = goalie
                            }
                        }
                        let keepGoalieIDs = Set(bestGoaliePerTeam.values.map { $0.id })
                        affordable = affordable.filter { p in
                            if p.position == "G" { return keepGoalieIDs.contains(p.id) }
                            return true
                        }
                    }
                }

                // Soccer GK slot: pick one keeper per team so ownership spreads
                // across all starting GKs (~6 per slate with 6 matches).
                if isSoccer && slots[slotIndex] == "GK" {
                    var bestGKPerTeam: [String: DFSPlayer] = [:]
                    for gk in affordable {
                        if let existing = bestGKPerTeam[gk.team] {
                            if gk.projectedPoints > existing.projectedPoints {
                                bestGKPerTeam[gk.team] = gk
                            }
                        } else {
                            bestGKPerTeam[gk.team] = gk
                        }
                    }
                    let startingGKs = Array(bestGKPerTeam.values)
                    if !startingGKs.isEmpty {
                        affordable = startingGKs
                    }
                }

                guard !affordable.isEmpty else { break }

                // Target salary for this pick to evenly distribute remaining budget
                let targetSalary = slotsLeft > 0 ? budgetLeft / slotsLeft : budgetLeft

                // NHL goalie slot: use flatter weighting so ownership spreads
                // across all starting goalies (typically 2-4 per slate).
                // Real DFS goalie ownership is much more even than skaters.
                let isGoalieSlot = slots[slotIndex] == "G"

                // Score each player — lower exponents = more randomness
                let isGKSlot = isSoccer && slots[slotIndex] == "GK"
                let weights: [Double] = affordable.map { p in
                    let proj = max(p.projectedPoints, 0.5)
                    let value = proj / max(Double(p.salary) / 1000.0, 0.1)
                    var w: Double

                    if isGoalieSlot || isGKSlot {
                        // Goalie/GK picks: very flat weighting so ownership spreads
                        // across all starting keepers (~6 per slate).
                        w = pow(proj, 0.4)
                    } else if isSingleGame && (sport == "NFL" || sport == "CFB") {
                        // Football showdowns weight by SALARY, not stat-based
                        // projections: DK's showdown price encodes expected
                        // snaps for THIS game. Stat projections rated resting
                        // veterans over the actual starters — preseason
                        // CAR@ARI had starting QB Carson Beck ($9,300, the
                        // most expensive player on the slate) at 2% owned
                        // because his rookie stat line projected ~0.
                        // Per-evaluation jitter is the diversity source here:
                        // raw salary is IDENTICAL for every bot (unlike noised
                        // projections), and without jitter the sharp styles
                        // converged — a regen produced 60 identical lineups
                        // out of 2000.
                        var salaryProj = max(Double(p.salary) / 1000.0, 0.5) * Double.random(in: 0.65...1.35)
                        // PRESEASON weighting, mirroring how a sharp human
                        // reads August football:
                        // 1. Team has a readable previous game → whoever sat
                        //    it is near-certainly resting again. Min-flier.
                        // 2. No previous game (the league's week 1) → fade by
                        //    NFL EXPERIENCE: established veterans either sit
                        //    or play one series — even a Bryce Young who
                        //    dresses in week 2/3 gets a quarter at most, so
                        //    he's never preseason DFS value. Rookies and
                        //    bubble players (0-5 GP last season) get the
                        //    volume; DK's pricing is decent WITHIN that group
                        //    (Beck \$9.3K was right).
                        // Recency, when available, overrides the veteran fade
                        // in BOTH directions — a vet who genuinely played a
                        // lot last week (QB competition) stays in the pool.
                        if isFootballPreseason {
                            if footballRecencyTeams.contains(p.team) {
                                if !p.playedRecently { salaryProj = 0.5 }
                            } else {
                                let lastSeasonGP = p.gamesPlayed ?? 0
                                if lastSeasonGP >= 10 {
                                    salaryProj = 0.5          // established starter — sits or cameo
                                } else if lastSeasonGP >= 6 {
                                    salaryProj *= 0.45        // part-timer — dampened
                                }
                            }
                        }
                        switch botStyle {
                        case 0: w = pow(salaryProj, 2.2)                             // Sharp
                        case 1: w = pow(salaryProj, 2.0)                             // Sharp
                        case 2: w = pow(salaryProj, 1.5)                             // Solid
                        case 3: w = pow(salaryProj, 1.2)                             // Mild lean
                        default: w = pow(salaryProj, 0.7)                            // Casual
                        }
                    } else if isSingleGame {
                        // Sharper SG mix. The previous exponents (0.5, 0.8,
                        // 1.2, 0.6, 1.0) were so flat that every bot drafted
                        // near-randomly — for a 2000-entry SG that's wrong:
                        // real DFS has a "sharp" upper tier that drafts close
                        // to optimal. New distribution gives ~40% of bots a
                        // genuinely projection/value-driven build while still
                        // keeping ~20% casual for diversity.
                        switch botStyle {
                        case 0: w = pow(max(value, 0.1), 2.2)                        // Sharp value
                        case 1: w = pow(proj, 2.0)                                   // Sharp projection
                        case 2: w = pow(proj, 1.5) * pow(max(value, 0.1), 0.8)       // Balanced sharp
                        case 3: w = pow(proj, 1.2)                                   // Mild stars lean
                        default: w = pow(proj, 0.7)                                  // Casual
                        }
                    } else if isSoccer {
                        // Soccer: very flat exponents — tiny pool (~22 for 8 slots)
                        // needs maximum randomness to avoid convergence.
                        switch botStyle {
                        case 0: w = pow(proj, 0.4)                                   // Near-random
                        case 1: w = pow(max(value, 0.1), 0.5)                        // Mild value
                        case 2: w = pow(proj, 0.9)                                   // Slight stars lean
                        case 3: w = 1.0                                              // Uniform random
                        default: w = pow(max(value, 0.1), 0.3)                       // Contrarian flat
                        }
                    } else {
                        switch botStyle {
                        case 0: w = pow(proj, 1.2)                                   // Near-random, slight projection lean
                        case 1: w = pow(value, 1.5)                                  // Value hunter
                        case 2: w = pow(proj, 1.8)                                   // Stars-and-scrubs
                        case 3: w = pow(proj, 1.0) * pow(max(value, 0.1), 1.0)       // Balanced
                        default: w = pow(max(Double(p.salary) / 1000.0, 0.1), 1.3)   // Contrarian — prefers expensive
                        }
                    }
                    // Salary steering — stronger for NHL/NBA to ensure bots approach cap
                    // (skip for goalie slot and soccer — small pools need
                    // more randomness, and salary steering causes convergence)
                    if !isGoalieSlot && !isGKSlot && !isSoccer {
                        let salaryRatio = Double(p.salary) / max(Double(targetSalary), 1.0)
                        if isSingleGame {
                            // Single-game: moderate steering to push bots toward 50K cap
                            // Lighter than main slate to preserve diversity in small pools
                            if salaryRatio >= 0.8 && salaryRatio <= 1.3 {
                                w *= 2.0
                            } else if salaryRatio < 0.5 {
                                // MLB showdown needs cheap bats. `targetSalary`
                                // is budgetLeft/slotsLeft, so after an MVP at
                                // 1.5x ($11.8K base = $17.7K charged) and a
                                // second pitcher, the five remaining slots
                                // target ~$6.4K — which puts a $3.1K starter at
                                // ratio ~0.48, just over the cliff. The generic
                                // 0.3 then buried mandatory min-priced starters
                                // at 0% ownership.
                                w *= (effectiveSport == "MLB" ? 0.8 : 0.3)
                            }
                        } else if effectiveSport == "NHL" || effectiveSport == "NBA" || effectiveSport == "NCAAM" {
                            // NHL/NBA: aggressively steer toward target salary
                            if salaryRatio >= 0.8 && salaryRatio <= 1.2 {
                                w *= 3.0
                            } else if salaryRatio >= 0.6 && salaryRatio < 0.8 {
                                w *= 1.0
                            } else if salaryRatio < 0.6 {
                                w *= 0.1
                            }
                        } else {
                            if salaryRatio >= 0.7 && salaryRatio <= 1.3 {
                                w *= 1.5
                            } else if salaryRatio < 0.4 {
                                w *= 0.3
                            }
                        }
                    }
                    // MLB: heavily prefer confirmed starters (in batting order) over bench players.
                    // Players not in the lineup will likely score 0 FPTS.
                    if effectiveSport == "MLB" && mlbHasBattingOrders {
                        let isStartingPitcher = p.position == "SP"
                        let inLineup = p.battingOrder != nil || isStartingPitcher
                        // Showdown pools are ~20 players for 6 slots, so the
                        // 10x/0.02x split (500x) collapsed the field onto the
                        // same handful. A firm-but-survivable 4x/0.15x still
                        // buries true bench bats without pinning anyone at 97%.
                        if isSingleGame {
                            // Pitchers already dominate on projection alone
                            // (30+ FPTS vs a batter's ~8). Giving them the
                            // announced-lineup boost on top double-counted the
                            // same fact and pinned both starters at 100%.
                            // Neutral for them; batters still get the boost.
                            w *= isStartingPitcher ? 1.0 : (inLineup ? 4.0 : 0.15)
                        } else {
                            w *= inLineup ? 10.0 : 0.02
                        }
                    }
                    // NHL: boost confirmed starting goalies so bots roster them
                    // at high ownership. Non-starter goalies get heavily penalized
                    // to prevent DNP goalies from being rostered.
                    if effectiveSport == "NHL" && p.position == "G" {
                        if p.isStartingGoalie {
                            // Single-game: massive boost — there are only 2 goalies and
                            // the confirmed starter should appear in 30-50%+ of lineups.
                            // 150x overcomes the random variance (0.3-1.0) and MVP sqrt
                            // flattening to consistently land goalies in bot rosters.
                            w *= isSingleGame ? 150.0 : 10.0
                        } else if p.isConfirmedActive && (p.gamesPlayed ?? 0) >= 10 && p.playedRecently {
                            // Fallback: confirmed active + reasonable GP + recently played.
                            // Lowered GP threshold from 30→10 so young starters (e.g. Dobes)
                            // aren't excluded when ESPN probables data is missing.
                            w *= isSingleGame ? 15.0 : 3.0
                        } else {
                            w *= 0.05  // Heavy penalty for backup/unconfirmed/inactive goalies
                        }
                    }
                    // NHL skaters: prefer players who actually played recently.
                    // Uses boxscore data from the team's last completed game to
                    // identify who is currently in the lineup vs. scratches/IR/inactive.
                    // Also uses season GP as a secondary signal for role importance.
                    if effectiveSport == "NHL" && p.position != "G" {
                        if !p.playedRecently {
                            w *= 0.05  // Didn't play in team's last game - likely scratch/injured/inactive
                        } else if !p.isConfirmedActive && isSingleGame {
                            // Single-game: if player is NOT on the DK/RotoGrinders salary
                            // list, they're likely a scratch or healthy DNP tonight.
                            // Penalize heavily to avoid 40%+ ownership on DNP players.
                            w *= 0.03
                        } else {
                            let gp = p.gamesPlayed ?? 0
                            if gp >= 65 {
                                w *= 2.0  // Top-line regular who played recently
                            } else if gp >= 45 {
                                w *= 1.3  // Rotation player who played recently
                            } else {
                                w *= 0.7  // Low-GP but recently active (call-up getting a chance)
                            }
                        }
                    }
                    // Soccer: prefer players who appeared in recent matches.
                    // Soccer squads are large (~25-30 per team) but only ~18 dress
                    // per match. Players who haven't featured in recent weeks are
                    // likely reserves, injured, or out of favor.
                    if isSoccer && !p.playedRecently {
                        w *= 0.08  // Didn't appear in any recent match — likely reserve/unavailable
                    }
                    // Captain (MVP) diversity for single-game: mild flatten
                    // so the chalk MVP doesn't reach 100%, but sharp bots
                    // still concentrate on the top projection. Was sqrt
                    // (0.5) — that was so aggressive it spread MVP ownership
                    // evenly across all 6 players, which is why top bots
                    // missed obvious MVP picks. 0.75 = mild flatten.
                    if mvpPick {
                        w = pow(w, 0.75)
                    }
                    // Ownership variance: random dampening so no single
                    // player hits 100% ownership. SG uses a tighter range
                    // (0.6-1.0) so sharp bots still draft the top players;
                    // the wider 0.3-1.0 range was strong enough to
                    // randomly downweight a 25-FPTS stud into a 4-FPTS
                    // slot, which is exactly how 87-FPTS top lineups
                    // were happening.
                    let varianceRange: ClosedRange<Double> = isSingleGame ? 0.6...1.0 : 0.3...1.0
                    let varianceFactor = Double.random(in: varianceRange)
                    w *= varianceFactor
                    return max(w, 0.001)
                }

                let totalW = weights.reduce(0, +)
                guard totalW > 0 else { break }
                var roll = Double.random(in: 0..<totalW)
                var pick = affordable[0]
                for (i, w) in weights.enumerated() {
                    roll -= w
                    if roll <= 0 { pick = affordable[i]; break }
                }

                selectedBySlot[slotIndex] = pick
                // Single-game MVP (slot 0) costs 1.5x salary
                let pickCost = (isSingleGame && slotIndex == 0) ? Int(Double(pick.salary) * 1.5) : pick.salary
                budgetLeft -= pickCost
                usedIDs.insert(pick.id)
                // Remove every ID for this PERSON, not just the drafted one.
                // A pool can carry the same player twice (a two-way "-sp"
                // sibling, a dk-slug alias resolved late), and id-only dedupe
                // let one bot roster him in two slots — a wasted slot and
                // ownership that summed past 100%.
                let pickKey = dfsOwnershipNameKey(pick.name)
                pool.removeAll { $0.id == pick.id || dfsOwnershipNameKey($0.name) == pickKey }
            }

            // Reconstruct selected array in original slot order
            guard selectedBySlot.count == lineupSize else { continue }
            var selected: [DFSPlayer] = (0..<lineupSize).compactMap { selectedBySlot[$0] }
            guard selected.count == lineupSize else { continue }
            let totalSpent = salaryCap - budgetLeft

            // If over cap, reject this lineup
            guard totalSpent <= salaryCap else { continue }

            // Helper: compute effective salary total (MVP costs 1.5x in single-game)
            func effectiveSalary(_ lineup: [DFSPlayer]) -> Int {
                if isSingleGame && !lineup.isEmpty {
                    return Int(Double(lineup[0].salary) * 1.5) + lineup.dropFirst().reduce(0) { $0 + $1.salary }
                }
                return lineup.reduce(0) { $0 + $1.salary }
            }

            // Upgrade pass: push spending toward cap — repeat until stable.
            // Soccer uses fewer passes (1) so bots don't all converge to same players.
            // NBA/NHL use 5 passes to ensure convergence with aggressive 95% floor.
            // Single-game uses 1-2 passes to preserve salary diversity in small pools.
            let upgradePassCount: Int
            if isSingleGame {
                // Bumped 1-2 → 3-5: the prior lighter setting left bots
                // routinely under the minSpend floor on NHL/NBA SG slates,
                // so they kept falling through to the (less constrained)
                // greedy fallback and underspending the cap.
                upgradePassCount = Int.random(in: 3...5)
            } else if isSoccer {
                upgradePassCount = 1
            } else if effectiveSport == "NHL" || effectiveSport == "NBA" || effectiveSport == "NCAAM" {
                upgradePassCount = 5
            } else {
                upgradePassCount = 3
            }
            for _ in 0..<upgradePassCount {
                let cs = effectiveSalary(selected)
                let upgradeThreshold = isSoccer ? (salaryCap - 2000) : (salaryCap - 500)
                if cs >= upgradeThreshold { break }
                // Sort by effective cost (MVP costs 1.5x in single-game) so we upgrade
                // the truly cheapest slots first, not the raw-salary cheapest.
                let sortedByPrice = selected.enumerated().sorted {
                    let cost0 = (isSingleGame && $0.offset == 0) ? Int(Double($0.element.salary) * 1.5) : $0.element.salary
                    let cost1 = (isSingleGame && $1.offset == 0) ? Int(Double($1.element.salary) * 1.5) : $1.element.salary
                    return cost0 < cost1
                }
                for (idx, cheapPlayer) in sortedByPrice {
                    let currentSpent = effectiveSalary(selected)
                    if currentSpent >= salaryCap - 500 { break }
                    let slack = salaryCap - currentSpent
                    // For single-game MVP (slot 0), the cost change is 1.5x the salary difference,
                    // so the max raw-salary increase is slack / 1.5. For FLEX slots it's 1:1.
                    let isMVPSlot = isSingleGame && idx == 0
                    let maxRawSalaryIncrease = isMVPSlot ? Int(Double(slack) / 1.5) : slack

                    let requiredPos = slots[idx]
                    let upgradeCandidates = upgradePool.filter { candidate in
                        !usedIDs.contains(candidate.id)
                        && candidate.salary > cheapPlayer.salary
                        && candidate.salary <= cheapPlayer.salary + maxRawSalaryIncrease
                        && (requiredPos == nil || self.playerMatchesSlot(candidate, slot: requiredPos!, isSingleGame: isSingleGame))
                    }
                    if !upgradeCandidates.isEmpty {
                        // Sort by best cap fit — use effective cost (1.5x for MVP) so MVP upgrades
                        // pick candidates that actually bring the team closest to the cap.
                        let oldCost = isMVPSlot ? Int(Double(cheapPlayer.salary) * 1.5) : cheapPlayer.salary
                        let sorted = upgradeCandidates.sorted {
                            let newCost0 = isMVPSlot ? Int(Double($0.salary) * 1.5) : $0.salary
                            let newCost1 = isMVPSlot ? Int(Double($1.salary) * 1.5) : $1.salary
                            let fit1 = abs(salaryCap - (currentSpent - oldCost + newCost0))
                            let fit2 = abs(salaryCap - (currentSpent - oldCost + newCost1))
                            return fit1 < fit2
                        }
                        let topN = Array(sorted.prefix(5))
                        let upgrade = topN.randomElement()!
                        usedIDs.remove(cheapPlayer.id)
                        usedIDs.insert(upgrade.id)
                        selected[idx] = upgrade
                    }
                }
            }

            let finalSpent = effectiveSalary(selected)

            // Accept if within min spend (92-95% depending on sport) to 100% of cap
            if finalSpent >= minSpend && finalSpent <= salaryCap {
                return reserveNotStartedGameSlots(selected, slots: slots, poolForReservation: players).map(\.id)
            }
        }

        // Fallback: greedy approach that targets salary spending.
        // For NHL, sort by salary descending to pick expensive players first.
        var fallback: [DFSPlayer] = []
        var fb_budget = salaryCap
        var fb_usedIDs = Set<String>()
        var fb_pool = (nhlSkipGoalie ? scrambled.filter { $0.position != "G" } : scrambled).shuffled()
        for pickIndex in 0..<lineupSize {
            let slotsLeft = lineupSize - fallback.count
            let slotsAfter = slotsLeft - 1
            let reserveRest = slotsAfter * cheapestSalary
            var affordable = fb_pool.filter { $0.salary <= fb_budget - reserveRest }
            if let requiredPos = slots[pickIndex] {
                affordable = affordable.filter { playerMatchesSlot($0, slot: requiredPos, isSingleGame: isSingleGame) }
            }
            // If the reserve math leaves no affordable option, relax it: any unused player
            // that fits the remaining budget for this single pick is acceptable. Better to
            // produce a complete lineup that underspends than a short lineup.
            if affordable.isEmpty {
                let mvpFactor = (isSingleGame && pickIndex == 0) ? 1.5 : 1.0
                var relaxed = fb_pool.filter { Int(Double($0.salary) * mvpFactor) <= fb_budget }
                if let requiredPos = slots[pickIndex] {
                    let positional = relaxed.filter { playerMatchesSlot($0, slot: requiredPos, isSingleGame: isSingleGame) }
                    if !positional.isEmpty {
                        relaxed = positional
                    } else if isSoccer || requiredPos == "GK" || requiredPos == "G"
                                || effectiveSport == "NFL" || effectiveSport == "CFB" {
                        // NEVER mis-slot a position-strict spot (a defender in the
                        // GK slot, a cornerback at QB, etc.). Leave it empty — the
                        // position-aware pad below fills it from the full pool,
                        // pulling a cheap fit from another game if this game's
                        // players at that position are used up.
                        relaxed = []
                    }
                }
                affordable = relaxed
            }
            guard !affordable.isEmpty else { break }
            // MLB: prefer confirmed starters in fallback to avoid bench players scoring 0
            if effectiveSport == "MLB" && mlbHasBattingOrders {
                let starters = affordable.filter { $0.battingOrder != nil || $0.position == "SP" }
                if !starters.isEmpty { affordable = starters }
            }
            // Target the salary we should spend on this pick
            let fbTargetSalary = slotsLeft > 0 ? fb_budget / slotsLeft : fb_budget
            // Sort by closeness to target salary, pick from top candidates
            let sorted = affordable.sorted { abs($0.salary - fbTargetSalary) < abs($1.salary - fbTargetSalary) }
            let topCandidates = Array(sorted.prefix(5))
            let best = topCandidates.randomElement()!
            fallback.append(best)
            let fbPickCost = (isSingleGame && pickIndex == 0) ? Int(Double(best.salary) * 1.5) : best.salary
            fb_budget -= fbPickCost
            fb_usedIDs.insert(best.id)
            fb_pool.removeAll { $0.id == best.id }
        }

        // Helper: compute effective salary total for fallback (MVP costs 1.5x in single-game)
        func fbEffectiveSalary(_ lineup: [DFSPlayer]) -> Int {
            if isSingleGame && !lineup.isEmpty {
                return Int(Double(lineup[0].salary) * 1.5) + lineup.dropFirst().reduce(0) { $0 + $1.salary }
            }
            return lineup.reduce(0) { $0 + $1.salary }
        }

        // Run upgrade pass on fallback to push spending toward cap. Use up to 10
        // iterations and prefer the MOST expensive affordable upgrade so a starting
        // total of ~75% of cap can climb to 95% even when individual swaps are small.
        if fallback.count == lineupSize {
            for _ in 0..<10 {
                let currentTotal = fbEffectiveSalary(fallback)
                if currentTotal >= salaryCap - 500 { break }
                let sortedByPrice = fallback.enumerated().sorted { $0.element.salary < $1.element.salary }
                var didUpgrade = false
                for (idx, cheapPlayer) in sortedByPrice {
                    let currentSpent = fbEffectiveSalary(fallback)
                    if currentSpent >= salaryCap - 500 { break }
                    let slack = salaryCap - currentSpent
                    let requiredPos = slots[idx]
                    // For MVP slot (idx 0 in single-game), the effective cost increase is
                    // 1.5x the salary delta, so the max usable salary uplift is slack/1.5.
                    let isMVPSlot = isSingleGame && idx == 0
                    let maxRawSalaryIncrease = isMVPSlot ? Int(Double(slack) / 1.5) : slack
                    let upgradeCandidates = upgradePool.filter { candidate in
                        !fb_usedIDs.contains(candidate.id)
                        && candidate.salary > cheapPlayer.salary
                        && candidate.salary <= cheapPlayer.salary + maxRawSalaryIncrease
                        && (requiredPos == nil || self.playerMatchesSlot(candidate, slot: requiredPos!, isSingleGame: isSingleGame))
                    }
                    if let upgrade = upgradeCandidates.max(by: { $0.salary < $1.salary }) {
                        fb_usedIDs.remove(cheapPlayer.id)
                        fb_usedIDs.insert(upgrade.id)
                        fallback[idx] = upgrade
                        didUpgrade = true
                    }
                }
                if !didUpgrade { break }
            }
        }

        // Pad each still-empty slot with the cheapest unused player that ACTUALLY
        // fits that slot's position — from `eligible`, then the full `players`
        // pool. Slot-aware so a defender never lands in the GK slot (the bug the
        // old position-blind pad caused), and so a scarce position (a 2nd/3rd
        // keeper) gets pulled from another game when the early games' starters at
        // that position are used up. A complete lineup that underspends beats the
        // saved-bot validation rejecting the entry and looping on regeneration.
        if fallback.count < lineupSize {
            var usedIDs = Set(fallback.map(\.id))
            func cheapestFit(_ source: [DFSPlayer], pos: String?) -> DFSPlayer? {
                source.filter {
                    !usedIDs.contains($0.id) && (pos == nil || playerMatchesSlot($0, slot: pos!, isSingleGame: isSingleGame))
                }.min(by: { $0.salary < $1.salary })
            }
            while fallback.count < lineupSize {
                let requiredPos = slots[fallback.count]
                var pick = cheapestFit(eligible, pos: requiredPos) ?? cheapestFit(players, pos: requiredPos)
                // Non-soccer/football last resort: any unused player (their slot
                // rules are already permissive via playerMatchesSlot). Soccer and
                // football keep the position exact — if no QB/keeper/etc. exists
                // anywhere, the lineup stays short rather than mis-slotted
                // (Salvon Ahmed showing in a QB slot).
                if pick == nil && !isSoccer && effectiveSport != "NFL" && effectiveSport != "CFB" {
                    pick = (eligible + players).first { !usedIDs.contains($0.id) }
                }
                guard let chosen = pick else { break }
                fallback.append(chosen)
                usedIDs.insert(chosen.id)
            }
        }

        // Force-spend safety net. The greedy fallback + upgrade loop above
        // can still leave a bot well under-spent — observed live: an NHL SG
        // bot spent $23,100 of $50K. That happens when the fallback's
        // upgrade pool runs out of meaningful candidates after a few swaps
        // and the `didUpgrade = false` break exits prematurely. Run an
        // aggressive last-resort pass: until we're at ~92% of cap (or we've
        // tried every cheap-slot/expensive-swap combo), swap the lineup's
        // cheapest player for the most expensive unused player whose
        // salary fits in remaining slack. Pulls from the full `eligible`
        // pool so the upgrade pool isn't constrained to the tiny SG
        // confirmed list.
        if fallback.count == lineupSize {
            func fbSafetyEffective(_ lineup: [DFSPlayer]) -> Int {
                if isSingleGame && !lineup.isEmpty {
                    return Int(Double(lineup[0].salary) * 1.5) + lineup.dropFirst().reduce(0) { $0 + $1.salary }
                }
                return lineup.reduce(0) { $0 + $1.salary }
            }
            let safetyTarget = Int(Double(salaryCap) * 0.92)
            var safetyUsedIDs = Set(fallback.map(\.id))
            for _ in 0..<30 {
                let totalSpent = fbSafetyEffective(fallback)
                if totalSpent >= safetyTarget { break }
                let slack = salaryCap - totalSpent
                let sortedByCost = fallback.enumerated().sorted {
                    let cost0 = (isSingleGame && $0.offset == 0) ? Int(Double($0.element.salary) * 1.5) : $0.element.salary
                    let cost1 = (isSingleGame && $1.offset == 0) ? Int(Double($1.element.salary) * 1.5) : $1.element.salary
                    return cost0 < cost1
                }
                var didSwap = false
                for (idx, cheapPlayer) in sortedByCost {
                    let isMVPSlot = isSingleGame && idx == 0
                    let maxSalaryIncrease = isMVPSlot ? Int(Double(slack) / 1.5) : slack
                    let maxNewSalary = cheapPlayer.salary + maxSalaryIncrease
                    let requiredPos = slots[idx]
                    let candidates = eligible.filter { c in
                        !safetyUsedIDs.contains(c.id)
                        && c.salary > cheapPlayer.salary
                        && c.salary <= maxNewSalary
                        && (requiredPos == nil || self.playerMatchesSlot(c, slot: requiredPos!, isSingleGame: isSingleGame))
                    }
                    if let upgrade = candidates.max(by: { $0.salary < $1.salary }) {
                        safetyUsedIDs.remove(cheapPlayer.id)
                        safetyUsedIDs.insert(upgrade.id)
                        fallback[idx] = upgrade
                        didSwap = true
                        break // restart the inner sort so the new "cheapest" is targeted next iteration
                    }
                }
                if !didSwap { break }
            }
        }

        let result = (fallback.count == lineupSize
            ? reserveNotStartedGameSlots(fallback, slots: slots, poolForReservation: players)
            : fallback).map(\.id)
        if result.isEmpty || result.count < lineupSize {
            print("[DFS-\(effectiveSport)] generateBotLineup returned \(result.count)/\(lineupSize) players. eligible=\(eligible.count), botPool=\(botPool.count), rosterSlots=\(rosterSlots?.description ?? "nil")")
        }
        return result
    }

    // MARK: - PGA Bot Lineup Generation

    /// Generate a salary-aware golf bot lineup with no position constraints.
    private func generateGolfBotLineup(from players: [DFSPlayer], salaryCap: Int, lineupSize: Int) -> [String] {
        let eligible = players.filter { ($0.injuryStatus ?? "") != "WD" }
        guard eligible.count >= lineupSize else {
            return players.shuffled().prefix(lineupSize).map(\.id)
        }

        let minSpend = Int(Double(salaryCap) * 0.97)
        let upgradeTarget = Int(Double(salaryCap) * 0.99)
        let cheapestSalary = eligible.map(\.salary).min() ?? 3000
        let botStyle = Int.random(in: 0..<3)

        for _ in 0..<30 {
            var selected: [DFSPlayer] = []
            var budgetLeft = salaryCap
            var usedIDs = Set<String>()
            var pool = eligible

            for pickIndex in 0..<lineupSize {
                let slotsLeft = lineupSize - pickIndex
                let slotsAfter = slotsLeft - 1
                let reserveForRest = slotsAfter * cheapestSalary
                let maxForThisPick = budgetLeft - reserveForRest
                let affordable = pool.filter { $0.salary <= maxForThisPick }
                guard !affordable.isEmpty else { break }
                let targetSalary = slotsLeft > 0 ? budgetLeft / slotsLeft : budgetLeft
                let isEarlyPick = pickIndex < 2

                let weights: [Double] = affordable.map { p in
                    let proj = max(p.projectedPoints, 1.0)
                    let value = proj / max(Double(p.salary) / 1000.0, 0.1)
                    var w: Double
                    switch botStyle {
                    case 1: w = pow(value, 2.5)
                    case 2: w = pow(proj, 3.0)
                    default: w = pow(proj, 2.0) * pow(max(value, 0.1), 0.5)
                    }
                    if isEarlyPick {
                        let salaryFrac = Double(p.salary - cheapestSalary) / max(Double(salaryCap / lineupSize - cheapestSalary), 1.0)
                        if salaryFrac < 0.3 { w *= 0.3 }
                    } else {
                        let salaryRatio = Double(p.salary) / max(Double(targetSalary), 1.0)
                        if salaryRatio >= 0.85 && salaryRatio <= 1.15 { w *= 5.0 }
                        else if salaryRatio >= 0.7 && salaryRatio < 0.85 { w *= 1.5 }
                        else if salaryRatio < 0.5 { w *= 0.05 }
                        else if salaryRatio > 1.3 { w *= 0.3 }
                    }
                    return max(w, 0.001)
                }

                let totalW = weights.reduce(0, +)
                guard totalW > 0 else { break }
                var roll = Double.random(in: 0..<totalW)
                var pick = affordable[0]
                for (i, w) in weights.enumerated() {
                    roll -= w
                    if roll <= 0 { pick = affordable[i]; break }
                }
                selected.append(pick)
                budgetLeft -= pick.salary
                usedIDs.insert(pick.id)
                pool.removeAll { $0.id == pick.id }
            }

            guard selected.count == lineupSize else { continue }
            let totalSpent = salaryCap - budgetLeft
            guard totalSpent <= salaryCap else { continue }

            if totalSpent < upgradeTarget {
                let sortedByPrice = selected.enumerated().sorted { $0.element.salary < $1.element.salary }
                for (idx, cheapPlayer) in sortedByPrice {
                    let currentSpent = selected.reduce(0) { $0 + $1.salary }
                    if currentSpent >= upgradeTarget { break }
                    let slack = salaryCap - currentSpent
                    let upgradeCandidates = eligible.filter { candidate in
                        !usedIDs.contains(candidate.id)
                        && candidate.salary > cheapPlayer.salary
                        && candidate.salary <= cheapPlayer.salary + slack
                    }
                    if let upgrade = upgradeCandidates.min(by: {
                        let newSpent1 = currentSpent - cheapPlayer.salary + $0.salary
                        let newSpent2 = currentSpent - cheapPlayer.salary + $1.salary
                        return abs(salaryCap - newSpent1) < abs(salaryCap - newSpent2)
                    }) {
                        usedIDs.remove(cheapPlayer.id)
                        usedIDs.insert(upgrade.id)
                        selected[idx] = upgrade
                    }
                }
            }

            let finalSpent = selected.reduce(0) { $0 + $1.salary }
            if finalSpent >= minSpend && finalSpent <= salaryCap {
                return selected.map(\.id)
            }
        }

        // Fallback: deterministic greedy approach
        var fallback: [DFSPlayer] = []
        var fb_budget = salaryCap
        var fb_pool = eligible.sorted { $0.projectedPoints > $1.projectedPoints }
        for _ in 0..<lineupSize {
            let slotsLeft = lineupSize - fallback.count
            let slotsAfter = slotsLeft - 1
            let reserveRest = slotsAfter * cheapestSalary
            let targetPerSlot = slotsLeft > 0 ? fb_budget / slotsLeft : fb_budget
            let affordable = fb_pool.filter { $0.salary <= fb_budget - reserveRest }
            guard !affordable.isEmpty else { break }
            let best = affordable.min(by: { abs($0.salary - targetPerSlot) < abs($1.salary - targetPerSlot) })!
            fallback.append(best)
            fb_budget -= best.salary
            fb_pool.removeAll { $0.id == best.id }
        }
        return fallback.map(\.id)
    }
}
