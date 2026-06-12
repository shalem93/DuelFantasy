-- Run in Supabase SQL Editor

create extension if not exists pgcrypto;

create table if not exists public.profiles (
    id uuid primary key references auth.users(id) on delete cascade,
    username text not null default 'Player',
    rr_score integer not null default 1000,
    created_at timestamptz not null default now()
);

create table if not exists public.dfs_tournaments (
    id text primary key,
    title text not null,
    league text not null,
    lock_time timestamptz not null,
    created_at timestamptz not null default now()
);

create table if not exists public.dfs_entries (
    id uuid primary key default gen_random_uuid(),
    tournament_id text not null references public.dfs_tournaments(id) on delete cascade,
    user_id uuid not null references auth.users(id) on delete cascade,
    lineup_player_ids text[] not null,
    submitted_at timestamptz not null default now(),
    unique (tournament_id, user_id)
);

-- Friendships (bidirectional: accepted means both are friends)
create table if not exists public.friendships (
    id uuid primary key default gen_random_uuid(),
    requester_id uuid not null references auth.users(id) on delete cascade,
    addressee_id uuid not null references auth.users(id) on delete cascade,
    status text not null default 'pending' check (status in ('pending', 'accepted')),
    created_at timestamptz not null default now(),
    unique (requester_id, addressee_id)
);

-- Add wins/losses columns to profiles (idempotent)
alter table public.profiles add column if not exists wins integer not null default 0;
alter table public.profiles add column if not exists losses integer not null default 0;

-- Pick'em picks (server-side persistence for cross-device / reinstall survival)
create table if not exists public.pickem_picks (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users(id) on delete cascade,
    match_id text not null,
    picked_team text not null,
    match_name text not null,
    gain_rr integer not null,
    loss_rr integer not null,
    result text check (result in ('win', 'loss', 'expired')),
    rr_delta integer,
    settled_at timestamptz,
    created_at timestamptz not null default now(),
    unique (user_id, match_id)
);

grant usage on schema public to anon, authenticated, service_role;
grant select, insert, update, delete on table public.profiles to authenticated, service_role;
grant select on table public.profiles to anon;
grant select, insert, update, delete on table public.dfs_tournaments to authenticated, service_role;
grant select on table public.dfs_tournaments to anon;
grant select, insert, update, delete on table public.dfs_entries to authenticated, service_role;
grant select on table public.dfs_entries to anon;

grant select, insert, update, delete on table public.friendships to authenticated, service_role;
grant select on table public.friendships to anon;

grant select, insert, update, delete on table public.pickem_picks to authenticated, service_role;

alter table public.profiles enable row level security;
alter table public.dfs_tournaments enable row level security;
alter table public.dfs_entries enable row level security;
alter table public.friendships enable row level security;
alter table public.pickem_picks enable row level security;

drop policy if exists "profiles_select_all" on public.profiles;
create policy "profiles_select_all" on public.profiles
for select using (true);

drop policy if exists "profiles_insert_self" on public.profiles;
create policy "profiles_insert_self" on public.profiles
for insert with check (auth.uid() = id);

drop policy if exists "profiles_update_self" on public.profiles;
create policy "profiles_update_self" on public.profiles
for update using (auth.uid() = id);

drop policy if exists "tournaments_select_all" on public.dfs_tournaments;
create policy "tournaments_select_all" on public.dfs_tournaments
for select using (true);

drop policy if exists "tournaments_insert_auth" on public.dfs_tournaments;
create policy "tournaments_insert_auth" on public.dfs_tournaments
for insert with check (auth.uid() is not null);

drop policy if exists "tournaments_update_auth" on public.dfs_tournaments;
create policy "tournaments_update_auth" on public.dfs_tournaments
for update using (auth.uid() is not null);

drop policy if exists "entries_select_all" on public.dfs_entries;
create policy "entries_select_all" on public.dfs_entries
for select using (true);

drop policy if exists "entries_insert_self" on public.dfs_entries;
create policy "entries_insert_self" on public.dfs_entries
for insert with check (auth.uid() = user_id);

drop policy if exists "entries_update_self" on public.dfs_entries;
create policy "entries_update_self" on public.dfs_entries
for update using (auth.uid() = user_id);

drop policy if exists "entries_delete_self" on public.dfs_entries;
create policy "entries_delete_self" on public.dfs_entries
for delete using (auth.uid() = user_id);

-- Friendships policies
drop policy if exists "friendships_select_own" on public.friendships;
create policy "friendships_select_own" on public.friendships
for select using (auth.uid() = requester_id or auth.uid() = addressee_id);

drop policy if exists "friendships_insert_self" on public.friendships;
create policy "friendships_insert_self" on public.friendships
for insert with check (auth.uid() = requester_id);

drop policy if exists "friendships_update_addressee" on public.friendships;
create policy "friendships_update_addressee" on public.friendships
for update using (auth.uid() = addressee_id);

drop policy if exists "friendships_delete_own" on public.friendships;
create policy "friendships_delete_own" on public.friendships
for delete using (auth.uid() = requester_id or auth.uid() = addressee_id);

-- Pick'em picks policies
-- Allow any authenticated user to read all picks (needed for global settlement + viewing friend profiles)
drop policy if exists "picks_select_own" on public.pickem_picks;
drop policy if exists "picks_select_all_auth" on public.pickem_picks;
create policy "picks_select_all_auth" on public.pickem_picks
for select using (auth.uid() is not null);

drop policy if exists "picks_insert_self" on public.pickem_picks;
create policy "picks_insert_self" on public.pickem_picks
for insert with check (auth.uid() = user_id);

drop policy if exists "picks_update_self" on public.pickem_picks;
create policy "picks_update_self" on public.pickem_picks
for update using (auth.uid() = user_id);

-- Allow any authenticated user to settle unsettled picks (for global grading)
drop policy if exists "picks_settle_any_unsettled" on public.pickem_picks;
create policy "picks_settle_any_unsettled" on public.pickem_picks
for update
using (auth.uid() is not null and result is null)
with check (true);

drop policy if exists "picks_delete_self" on public.pickem_picks;
create policy "picks_delete_self" on public.pickem_picks
for delete using (
    auth.uid() = user_id
    or (auth.uid() is not null and result is null and created_at < now() - interval '7 days')
);

-- ============================================================
-- BEST BALL FANTASY
-- ============================================================

create table if not exists public.bestball_leagues (
    id uuid primary key default gen_random_uuid(),
    title text not null,
    sport text not null check (sport in ('NBA', 'MLB', 'NFL')),
    season text not null,
    status text not null default 'open' check (status in ('open', 'drafting', 'active', 'completed')),
    draft_start_time timestamptz,
    draft_order text[] not null default '{}',
    current_pick_number integer not null default 0,
    pick_timer_seconds integer not null default 30,
    roster_size integer not null default 12,
    scoring_slots integer not null default 8,
    current_week integer not null default 1,
    total_weeks integer not null default 20,
    created_at timestamptz not null default now(),
    schedule jsonb not null default '[]',
    week_structure text not null default 'mon_sun',
    scoring_mode text not null default 'normal' check (scoring_mode in ('normal', 'dingersOnly')),
    pitcher_slots integer not null default 2,
    batter_slots integer not null default 6,
    is_private boolean not null default false,
    created_by uuid references auth.users(id) on delete set null,
    max_members integer not null default 12,
    invite_code text
);

create table if not exists public.bestball_members (
    id uuid primary key default gen_random_uuid(),
    league_id uuid not null references public.bestball_leagues(id) on delete cascade,
    user_id uuid references auth.users(id) on delete set null,
    slot_index integer not null,
    display_name text not null,
    is_bot boolean not null default false,
    joined_at timestamptz not null default now(),
    unique (league_id, slot_index)
);

create table if not exists public.bestball_picks (
    id uuid primary key default gen_random_uuid(),
    league_id uuid not null references public.bestball_leagues(id) on delete cascade,
    member_id uuid not null references public.bestball_members(id) on delete cascade,
    pick_number integer not null,
    round integer not null,
    player_id text not null,
    player_name text not null,
    player_team text not null,
    player_position text not null,
    picked_at timestamptz not null default now(),
    unique (league_id, pick_number)
);

create table if not exists public.bestball_weekly_scores (
    id uuid primary key default gen_random_uuid(),
    league_id uuid not null references public.bestball_leagues(id) on delete cascade,
    member_id uuid not null references public.bestball_members(id) on delete cascade,
    week integer not null,
    total_points double precision not null default 0,
    scoring_player_ids text[] not null default '{}',
    player_points jsonb not null default '{}',
    computed_at timestamptz not null default now(),
    unique (league_id, member_id, week)
);

create table if not exists public.bestball_standings (
    id uuid primary key default gen_random_uuid(),
    league_id uuid not null references public.bestball_leagues(id) on delete cascade,
    member_id uuid not null references public.bestball_members(id) on delete cascade,
    total_points double precision not null default 0,
    weeks_scored integer not null default 0,
    rank integer not null default 0,
    updated_at timestamptz not null default now(),
    unique (league_id, member_id)
);

-- Grants
grant select, insert, update, delete on table public.bestball_leagues to authenticated, service_role;
grant select on table public.bestball_leagues to anon;
grant select, insert, update, delete on table public.bestball_members to authenticated, service_role;
grant select on table public.bestball_members to anon;
grant select, insert, update, delete on table public.bestball_picks to authenticated, service_role;
grant select on table public.bestball_picks to anon;
grant select, insert, update, delete on table public.bestball_weekly_scores to authenticated, service_role;
grant select on table public.bestball_weekly_scores to anon;
grant select, insert, update, delete on table public.bestball_standings to authenticated, service_role;
grant select on table public.bestball_standings to anon;

-- RLS
alter table public.bestball_leagues enable row level security;
alter table public.bestball_members enable row level security;
alter table public.bestball_picks enable row level security;
alter table public.bestball_weekly_scores enable row level security;
alter table public.bestball_standings enable row level security;

-- Leagues: readable by all, writable by authenticated
drop policy if exists "bb_leagues_select_all" on public.bestball_leagues;
create policy "bb_leagues_select_all" on public.bestball_leagues
for select using (true);

drop policy if exists "bb_leagues_insert_auth" on public.bestball_leagues;
create policy "bb_leagues_insert_auth" on public.bestball_leagues
for insert with check (auth.uid() is not null);

drop policy if exists "bb_leagues_update_auth" on public.bestball_leagues;
create policy "bb_leagues_update_auth" on public.bestball_leagues
for update using (auth.uid() is not null);

-- Only the league's creator can delete it. Without this policy Postgres
-- silently rejects every DELETE (PostgREST still returns 204) so the
-- client thinks the delete worked while the row persists.
drop policy if exists "bb_leagues_delete_creator" on public.bestball_leagues;
create policy "bb_leagues_delete_creator" on public.bestball_leagues
for delete using (auth.uid() = created_by);

-- NFL starting-lineup configuration. Commissioner picks how many of
-- each position score each week. Defaults match the prior hardcoded
-- lineup (QB×1, RB×2, WR×2, TE×1, FLEX×2 — total 8 starters).
alter table public.bestball_leagues
    add column if not exists nfl_qb_starters integer default 1,
    add column if not exists nfl_rb_starters integer default 2,
    add column if not exists nfl_wr_starters integer default 2,
    add column if not exists nfl_te_starters integer default 1,
    add column if not exists nfl_flex_starters integer default 2,
    add column if not exists nfl_sflex_starters integer default 0;

-- Members: readable by all, users manage own membership
drop policy if exists "bb_members_select_all" on public.bestball_members;
create policy "bb_members_select_all" on public.bestball_members
for select using (true);

drop policy if exists "bb_members_insert_auth" on public.bestball_members;
create policy "bb_members_insert_auth" on public.bestball_members
for insert with check (auth.uid() is not null);

drop policy if exists "bb_members_update_auth" on public.bestball_members;
create policy "bb_members_update_auth" on public.bestball_members
for update using (auth.uid() is not null);

drop policy if exists "bb_members_delete_own" on public.bestball_members;
create policy "bb_members_delete_own" on public.bestball_members
for delete using (auth.uid() = user_id);

-- League creator can delete ANY member row (including bot rows which
-- have a null user_id and so don't match the "delete_own" policy).
-- Needed both for the standalone delete-league flow's pre-cascade
-- cleanup and for kicking bots out of an open league.
drop policy if exists "bb_members_delete_by_creator" on public.bestball_members;
create policy "bb_members_delete_by_creator" on public.bestball_members
for delete using (
  exists (
    select 1 from public.bestball_leagues l
    where l.id = league_id and l.created_by = auth.uid()
  )
);

-- Picks: readable by all, insertable by authenticated
drop policy if exists "bb_picks_select_all" on public.bestball_picks;
create policy "bb_picks_select_all" on public.bestball_picks
for select using (true);

drop policy if exists "bb_picks_insert_auth" on public.bestball_picks;
create policy "bb_picks_insert_auth" on public.bestball_picks
for insert with check (auth.uid() is not null);

-- Weekly scores: readable by all, writable by authenticated
drop policy if exists "bb_scores_select_all" on public.bestball_weekly_scores;
create policy "bb_scores_select_all" on public.bestball_weekly_scores
for select using (true);

drop policy if exists "bb_scores_insert_auth" on public.bestball_weekly_scores;
create policy "bb_scores_insert_auth" on public.bestball_weekly_scores
for insert with check (auth.uid() is not null);

drop policy if exists "bb_scores_update_auth" on public.bestball_weekly_scores;
create policy "bb_scores_update_auth" on public.bestball_weekly_scores
for update using (auth.uid() is not null);

-- Standings: readable by all, writable by authenticated
drop policy if exists "bb_standings_select_all" on public.bestball_standings;
create policy "bb_standings_select_all" on public.bestball_standings
for select using (true);

drop policy if exists "bb_standings_insert_auth" on public.bestball_standings;
create policy "bb_standings_insert_auth" on public.bestball_standings
for insert with check (auth.uid() is not null);

drop policy if exists "bb_standings_update_auth" on public.bestball_standings;
create policy "bb_standings_update_auth" on public.bestball_standings
for update using (auth.uid() is not null);

-- DFS: store final lineup scores on entries for past tournament standings
alter table public.dfs_entries add column if not exists lineup_total_points double precision;
alter table public.dfs_entries add column if not exists display_name text;

-- Allow any authenticated user to update entries (needed for score settlement)
drop policy if exists "entries_update_auth" on public.dfs_entries;
create policy "entries_update_auth" on public.dfs_entries
for update using (auth.uid() is not null);

-- ============================================================
-- DFS Tournament Results (full leaderboard persistence)
-- ============================================================

create table if not exists public.dfs_tournament_results (
    id uuid primary key default gen_random_uuid(),
    tournament_id text not null references public.dfs_tournaments(id) on delete cascade,
    user_id uuid references auth.users(id) on delete set null,
    entry_name text not null,
    lineup_player_ids text[] not null default '{}',
    lineup_player_names text[] not null default '{}',
    total_points double precision not null default 0,
    player_points jsonb not null default '{}',
    rank integer not null default 0,
    rr_delta integer not null default 0,
    is_current_user boolean not null default false,
    is_bot boolean not null default false,
    created_at timestamptz not null default now(),
    unique (tournament_id, entry_name)
);

grant select, insert, update, delete on table public.dfs_tournament_results to authenticated, service_role;
grant select on table public.dfs_tournament_results to anon;

alter table public.dfs_tournament_results enable row level security;

drop policy if exists "dfs_results_select_all" on public.dfs_tournament_results;
create policy "dfs_results_select_all" on public.dfs_tournament_results
for select using (true);

drop policy if exists "dfs_results_insert_auth" on public.dfs_tournament_results;
create policy "dfs_results_insert_auth" on public.dfs_tournament_results
for insert with check (auth.uid() is not null);

drop policy if exists "dfs_results_update_auth" on public.dfs_tournament_results;
create policy "dfs_results_update_auth" on public.dfs_tournament_results
for update using (auth.uid() is not null);

drop policy if exists "dfs_results_delete_auth" on public.dfs_tournament_results;
create policy "dfs_results_delete_auth" on public.dfs_tournament_results
for delete using (auth.uid() is not null);

-- Store per-player salaries for past standings display
alter table public.dfs_tournament_results add column if not exists player_salaries jsonb not null default '{}';

-- Also add settled flag + total_entries to dfs_tournaments
alter table public.dfs_tournaments add column if not exists is_settled boolean not null default false;
alter table public.dfs_tournaments add column if not exists total_entries integer not null default 0;

-- Allow authenticated users to update tournaments (for marking settled)
drop policy if exists "tournaments_update_auth" on public.dfs_tournaments;
create policy "tournaments_update_auth" on public.dfs_tournaments
for update using (auth.uid() is not null);

-- Store player salaries at draft time so past standings show correct prices
alter table public.dfs_entries add column if not exists lineup_player_salaries jsonb not null default '{}';

-- Store player names at draft time so lineup display can fall back to saved names
alter table public.dfs_entries add column if not exists lineup_player_names text[] not null default '{}';

-- Store full slate player salaries on tournament so re-settlement uses original prices
alter table public.dfs_tournaments add column if not exists player_salaries jsonb not null default '{}';

-- Store bot field lineups on tournament so post-match settlement uses the original pre-game lineups
alter table public.dfs_tournaments add column if not exists bot_field jsonb;

-- Multi-lineup support: add lineup_number and update unique constraint
alter table public.dfs_entries add column if not exists lineup_number int not null default 1;

-- Drop the old constraint that only allowed 1 entry per user per tournament
alter table public.dfs_entries drop constraint if exists dfs_entries_tournament_id_user_id_key;

-- New constraint allows multiple lineups per user per tournament (distinguished by lineup_number)
alter table public.dfs_entries add constraint dfs_entries_tournament_user_lineup_unique
    unique (tournament_id, user_id, lineup_number);

-- ──────────────────────────────────────────────
-- TENNIS BRACKET POOL
-- ──────────────────────────────────────────────

create table if not exists public.tennis_bracket_tournaments (
    id text primary key,
    title text not null,
    grand_slam text not null check (grand_slam in ('french_open','wimbledon','us_open','australian_open')),
    draw_type text not null check (draw_type in ('atp','wta')),
    season text not null,
    status text not null default 'open' check (status in ('open','locked','live','settled')),
    lock_time timestamptz,
    draw_data jsonb,
    results_data jsonb not null default '{}',
    bot_field jsonb,
    entry_count integer not null default 1000,
    is_settled boolean not null default false,
    created_at timestamptz not null default now()
);

create table if not exists public.tennis_bracket_entries (
    id uuid primary key default gen_random_uuid(),
    tournament_id text not null references public.tennis_bracket_tournaments(id) on delete cascade,
    user_id uuid references auth.users(id) on delete set null,
    entry_name text not null,
    picks jsonb not null default '{}',
    total_points double precision not null default 0,
    rank integer not null default 0,
    is_bot boolean not null default false,
    created_at timestamptz not null default now(),
    unique (tournament_id, user_id)
);

create table if not exists public.tennis_bracket_groups (
    id uuid primary key default gen_random_uuid(),
    tournament_id text not null references public.tennis_bracket_tournaments(id) on delete cascade,
    name text not null,
    created_by uuid not null references auth.users(id) on delete cascade,
    invite_code text not null unique,
    max_members integer not null default 20,
    created_at timestamptz not null default now()
);

create table if not exists public.tennis_bracket_group_members (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.tennis_bracket_groups(id) on delete cascade,
    user_id uuid not null references auth.users(id) on delete cascade,
    display_name text not null,
    joined_at timestamptz not null default now(),
    unique (group_id, user_id)
);

-- Indexes
create index if not exists idx_tb_entries_tournament on public.tennis_bracket_entries(tournament_id);
create index if not exists idx_tb_entries_user on public.tennis_bracket_entries(user_id);
create index if not exists idx_tb_groups_tournament on public.tennis_bracket_groups(tournament_id);
create index if not exists idx_tb_groups_invite on public.tennis_bracket_groups(invite_code);
create index if not exists idx_tb_group_members_group on public.tennis_bracket_group_members(group_id);
create index if not exists idx_tb_group_members_user on public.tennis_bracket_group_members(user_id);

-- Grants
grant select, insert, update, delete on table public.tennis_bracket_tournaments to authenticated, service_role;
grant select on table public.tennis_bracket_tournaments to anon;
grant select, insert, update, delete on table public.tennis_bracket_entries to authenticated, service_role;
grant select on table public.tennis_bracket_entries to anon;
grant select, insert, update, delete on table public.tennis_bracket_groups to authenticated, service_role;
grant select on table public.tennis_bracket_groups to anon;
grant select, insert, update, delete on table public.tennis_bracket_group_members to authenticated, service_role;
grant select on table public.tennis_bracket_group_members to anon;

-- RLS
alter table public.tennis_bracket_tournaments enable row level security;
alter table public.tennis_bracket_entries enable row level security;
alter table public.tennis_bracket_groups enable row level security;
alter table public.tennis_bracket_group_members enable row level security;

-- Tournaments: readable by all, writable by authenticated
drop policy if exists "tb_tournaments_select_all" on public.tennis_bracket_tournaments;
create policy "tb_tournaments_select_all" on public.tennis_bracket_tournaments
for select using (true);

drop policy if exists "tb_tournaments_insert_auth" on public.tennis_bracket_tournaments;
create policy "tb_tournaments_insert_auth" on public.tennis_bracket_tournaments
for insert with check (auth.uid() is not null);

drop policy if exists "tb_tournaments_update_auth" on public.tennis_bracket_tournaments;
create policy "tb_tournaments_update_auth" on public.tennis_bracket_tournaments
for update using (auth.uid() is not null);

-- Entries: readable by all, writable by authenticated
drop policy if exists "tb_entries_select_all" on public.tennis_bracket_entries;
create policy "tb_entries_select_all" on public.tennis_bracket_entries
for select using (true);

drop policy if exists "tb_entries_insert_auth" on public.tennis_bracket_entries;
create policy "tb_entries_insert_auth" on public.tennis_bracket_entries
for insert with check (auth.uid() is not null);

drop policy if exists "tb_entries_update_auth" on public.tennis_bracket_entries;
create policy "tb_entries_update_auth" on public.tennis_bracket_entries
for update using (auth.uid() is not null);

-- Groups: readable by all, insert by auth, update/delete by owner
drop policy if exists "tb_groups_select_all" on public.tennis_bracket_groups;
create policy "tb_groups_select_all" on public.tennis_bracket_groups
for select using (true);

drop policy if exists "tb_groups_insert_auth" on public.tennis_bracket_groups;
create policy "tb_groups_insert_auth" on public.tennis_bracket_groups
for insert with check (auth.uid() is not null);

drop policy if exists "tb_groups_update_owner" on public.tennis_bracket_groups;
create policy "tb_groups_update_owner" on public.tennis_bracket_groups
for update using (auth.uid() = created_by);

drop policy if exists "tb_groups_delete_owner" on public.tennis_bracket_groups;
create policy "tb_groups_delete_owner" on public.tennis_bracket_groups
for delete using (auth.uid() = created_by);

-- Group members: readable by all, insert by auth, delete own
drop policy if exists "tb_group_members_select_all" on public.tennis_bracket_group_members;
create policy "tb_group_members_select_all" on public.tennis_bracket_group_members
for select using (true);

drop policy if exists "tb_group_members_insert_auth" on public.tennis_bracket_group_members;
create policy "tb_group_members_insert_auth" on public.tennis_bracket_group_members
for insert with check (auth.uid() is not null);

drop policy if exists "tb_group_members_delete_own" on public.tennis_bracket_group_members;
create policy "tb_group_members_delete_own" on public.tennis_bracket_group_members
for delete using (auth.uid() = user_id);

-- ──────────────────────────────────────────────
-- DFS TOURNAMENT INVITES
-- ──────────────────────────────────────────────

create table if not exists public.dfs_tournament_invites (
    id uuid primary key default gen_random_uuid(),
    tournament_id text not null references public.dfs_tournaments(id) on delete cascade,
    inviter_id uuid not null references auth.users(id) on delete cascade,
    invitee_id uuid not null references auth.users(id) on delete cascade,
    status text not null default 'pending' check (status in ('pending','accepted','declined')),
    created_at timestamptz not null default now(),
    unique (tournament_id, inviter_id, invitee_id)
);

create index if not exists idx_dfs_invites_invitee on public.dfs_tournament_invites(invitee_id);
create index if not exists idx_dfs_invites_tournament on public.dfs_tournament_invites(tournament_id);

grant select, insert, update, delete on table public.dfs_tournament_invites to authenticated, service_role;
grant select on table public.dfs_tournament_invites to anon;

alter table public.dfs_tournament_invites enable row level security;

drop policy if exists "dfs_invites_select_own" on public.dfs_tournament_invites;
create policy "dfs_invites_select_own" on public.dfs_tournament_invites
for select using (auth.uid() = inviter_id or auth.uid() = invitee_id);

drop policy if exists "dfs_invites_insert_self" on public.dfs_tournament_invites;
create policy "dfs_invites_insert_self" on public.dfs_tournament_invites
for insert with check (auth.uid() = inviter_id);

drop policy if exists "dfs_invites_update_invitee" on public.dfs_tournament_invites;
create policy "dfs_invites_update_invitee" on public.dfs_tournament_invites
for update using (auth.uid() = invitee_id);

drop policy if exists "dfs_invites_delete_own" on public.dfs_tournament_invites;
create policy "dfs_invites_delete_own" on public.dfs_tournament_invites
for delete using (auth.uid() = inviter_id or auth.uid() = invitee_id);

select pg_notify('pgrst', 'reload schema');

-- ============================================================
-- GOLF MAJOR TIERS
-- ============================================================

create table if not exists public.golf_tiers_tournaments (
    id text primary key,
    title text not null,
    major_name text not null,
    season text not null,
    status text not null default 'open' check (status in ('open', 'locked', 'live', 'settled')),
    lock_time timestamptz,
    espn_event_id text,
    entry_count integer not null default 1000,
    bot_field jsonb,
    is_settled boolean not null default false,
    created_at timestamptz not null default now()
);

create table if not exists public.golf_tiers_entries (
    id uuid primary key default gen_random_uuid(),
    tournament_id text not null references public.golf_tiers_tournaments(id) on delete cascade,
    user_id uuid references auth.users(id) on delete set null,
    entry_name text not null,
    picks jsonb not null default '[]',
    total_points double precision not null default 0,
    rank integer not null default 0,
    is_bot boolean not null default false,
    created_at timestamptz not null default now(),
    unique (tournament_id, user_id)
);

grant select, insert, update, delete on table public.golf_tiers_tournaments to authenticated, service_role;
grant select on table public.golf_tiers_tournaments to anon;
grant select, insert, update, delete on table public.golf_tiers_entries to authenticated, service_role;
grant select on table public.golf_tiers_entries to anon;

alter table public.golf_tiers_tournaments enable row level security;
alter table public.golf_tiers_entries enable row level security;

drop policy if exists "gt_tournaments_select_all" on public.golf_tiers_tournaments;
create policy "gt_tournaments_select_all" on public.golf_tiers_tournaments
for select using (true);

drop policy if exists "gt_tournaments_insert_auth" on public.golf_tiers_tournaments;
create policy "gt_tournaments_insert_auth" on public.golf_tiers_tournaments
for insert with check (auth.uid() is not null);

drop policy if exists "gt_tournaments_update_auth" on public.golf_tiers_tournaments;
create policy "gt_tournaments_update_auth" on public.golf_tiers_tournaments
for update using (auth.uid() is not null);

drop policy if exists "gt_entries_select_all" on public.golf_tiers_entries;
create policy "gt_entries_select_all" on public.golf_tiers_entries
for select using (true);

drop policy if exists "gt_entries_insert_auth" on public.golf_tiers_entries;
create policy "gt_entries_insert_auth" on public.golf_tiers_entries
for insert with check (auth.uid() is not null);

drop policy if exists "gt_entries_update_auth" on public.golf_tiers_entries;
create policy "gt_entries_update_auth" on public.golf_tiers_entries
for update using (auth.uid() is not null);

drop policy if exists "gt_entries_delete_auth" on public.golf_tiers_entries;
create policy "gt_entries_delete_auth" on public.golf_tiers_entries
for delete using (auth.uid() = user_id or is_bot = true);

-- Golf Tiers Private Groups
create table if not exists public.golf_tiers_groups (
    id uuid primary key default gen_random_uuid(),
    tournament_id text not null references public.golf_tiers_tournaments(id) on delete cascade,
    name text not null,
    created_by uuid not null references auth.users(id) on delete cascade,
    invite_code text not null unique,
    max_members integer not null default 20,
    created_at timestamptz not null default now()
);

create table if not exists public.golf_tiers_group_members (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.golf_tiers_groups(id) on delete cascade,
    user_id uuid not null references auth.users(id) on delete cascade,
    display_name text not null,
    joined_at timestamptz not null default now(),
    unique (group_id, user_id)
);

create index if not exists idx_gt_groups_tournament on public.golf_tiers_groups(tournament_id);
create index if not exists idx_gt_groups_invite on public.golf_tiers_groups(invite_code);
create index if not exists idx_gt_group_members_group on public.golf_tiers_group_members(group_id);
create index if not exists idx_gt_group_members_user on public.golf_tiers_group_members(user_id);

grant select, insert, update, delete on table public.golf_tiers_groups to authenticated, service_role;
grant select on table public.golf_tiers_groups to anon;
grant select, insert, update, delete on table public.golf_tiers_group_members to authenticated, service_role;
grant select on table public.golf_tiers_group_members to anon;

alter table public.golf_tiers_groups enable row level security;
alter table public.golf_tiers_group_members enable row level security;

drop policy if exists "gt_groups_select_all" on public.golf_tiers_groups;
create policy "gt_groups_select_all" on public.golf_tiers_groups
for select using (true);

drop policy if exists "gt_groups_insert_auth" on public.golf_tiers_groups;
create policy "gt_groups_insert_auth" on public.golf_tiers_groups
for insert with check (auth.uid() is not null);

drop policy if exists "gt_groups_update_owner" on public.golf_tiers_groups;
create policy "gt_groups_update_owner" on public.golf_tiers_groups
for update using (auth.uid() = created_by);

drop policy if exists "gt_groups_delete_owner" on public.golf_tiers_groups;
create policy "gt_groups_delete_owner" on public.golf_tiers_groups
for delete using (auth.uid() = created_by);

drop policy if exists "gt_group_members_select_all" on public.golf_tiers_group_members;
create policy "gt_group_members_select_all" on public.golf_tiers_group_members
for select using (true);

drop policy if exists "gt_group_members_insert_auth" on public.golf_tiers_group_members;
create policy "gt_group_members_insert_auth" on public.golf_tiers_group_members
for insert with check (auth.uid() is not null);

drop policy if exists "gt_group_members_delete_own" on public.golf_tiers_group_members;
create policy "gt_group_members_delete_own" on public.golf_tiers_group_members
for delete using (auth.uid() = user_id);

select pg_notify('pgrst', 'reload schema');

-- ============================================================
-- PLAYOFF TIERS
-- ============================================================

create table if not exists public.playoff_tiers_tournaments (
    id text primary key,
    title text not null,
    season text not null,
    status text not null default 'open' check (status in ('open', 'locked', 'live', 'settled')),
    lock_time timestamptz,
    entry_count integer not null default 1000,
    playoff_round text not null default 'full',
    bot_field jsonb,
    is_settled boolean not null default false,
    created_at timestamptz not null default now()
);

create table if not exists public.playoff_tiers_entries (
    id uuid primary key default gen_random_uuid(),
    tournament_id text not null references public.playoff_tiers_tournaments(id) on delete cascade,
    user_id uuid references auth.users(id) on delete set null,
    entry_name text not null,
    picks jsonb not null default '[]',
    total_points double precision not null default 0,
    rank integer not null default 0,
    is_bot boolean not null default false,
    created_at timestamptz not null default now(),
    unique (tournament_id, user_id)
);

grant select, insert, update, delete on table public.playoff_tiers_tournaments to authenticated, service_role;
grant select on table public.playoff_tiers_tournaments to anon;
grant select, insert, update, delete on table public.playoff_tiers_entries to authenticated, service_role;
grant select on table public.playoff_tiers_entries to anon;

alter table public.playoff_tiers_tournaments enable row level security;
alter table public.playoff_tiers_entries enable row level security;

drop policy if exists "pt_tournaments_select_all" on public.playoff_tiers_tournaments;
create policy "pt_tournaments_select_all" on public.playoff_tiers_tournaments
for select using (true);

drop policy if exists "pt_tournaments_insert_auth" on public.playoff_tiers_tournaments;
create policy "pt_tournaments_insert_auth" on public.playoff_tiers_tournaments
for insert with check (auth.uid() is not null);

drop policy if exists "pt_tournaments_update_auth" on public.playoff_tiers_tournaments;
create policy "pt_tournaments_update_auth" on public.playoff_tiers_tournaments
for update using (auth.uid() is not null);

drop policy if exists "pt_entries_select_all" on public.playoff_tiers_entries;
create policy "pt_entries_select_all" on public.playoff_tiers_entries
for select using (true);

drop policy if exists "pt_entries_insert_auth" on public.playoff_tiers_entries;
create policy "pt_entries_insert_auth" on public.playoff_tiers_entries
for insert with check (auth.uid() is not null);

drop policy if exists "pt_entries_update_auth" on public.playoff_tiers_entries;
create policy "pt_entries_update_auth" on public.playoff_tiers_entries
for update using (auth.uid() is not null);

drop policy if exists "pt_entries_delete_auth" on public.playoff_tiers_entries;
create policy "pt_entries_delete_auth" on public.playoff_tiers_entries
for delete using (auth.uid() is not null);

select pg_notify('pgrst', 'reload schema');

-- ============================================================
-- Best Ball V4 Migration: Scoring Mode (Dingers Only)
-- ============================================================
alter table public.bestball_leagues add column if not exists scoring_mode text not null default 'normal';

-- Valid values: 'normal' (standard H2H fantasy), 'dingers_only' (batters-only HR leaderboard)
alter table public.bestball_leagues drop constraint if exists bestball_leagues_scoring_mode_check;
alter table public.bestball_leagues add constraint bestball_leagues_scoring_mode_check
    check (scoring_mode in ('normal', 'dingers_only'));

select pg_notify('pgrst', 'reload schema');
-- ============================================================
-- Best Ball V2 Migration: H2H matchups, live scoring, stat lines
-- ============================================================

-- 1. Alter bestball_leagues: add schedule + week structure, change scoring_slots default
alter table public.bestball_leagues alter column scoring_slots set default 8;
alter table public.bestball_leagues add column if not exists schedule jsonb not null default '[]';
alter table public.bestball_leagues add column if not exists week_structure text not null default 'mon_sun';

-- 2. Alter bestball_weekly_scores: add stat lines, H2H opponent, matchup result
alter table public.bestball_weekly_scores add column if not exists player_stats jsonb not null default '{}';
alter table public.bestball_weekly_scores add column if not exists opponent_member_id uuid;
alter table public.bestball_weekly_scores add column if not exists matchup_result text;

-- 3. Alter bestball_standings: add W-L record
alter table public.bestball_standings add column if not exists wins integer not null default 0;
alter table public.bestball_standings add column if not exists losses integer not null default 0;

-- 4. New table: bestball_daily_scores (per-day player scores within a week)
create table if not exists public.bestball_daily_scores (
    id uuid primary key default gen_random_uuid(),
    league_id uuid not null references public.bestball_leagues(id) on delete cascade,
    member_id uuid not null references public.bestball_members(id) on delete cascade,
    week integer not null,
    game_date date not null,
    player_points jsonb not null default '{}',
    player_stats jsonb not null default '{}',
    updated_at timestamptz not null default now(),
    unique (league_id, member_id, week, game_date)
);

grant select, insert, update, delete on table public.bestball_daily_scores to authenticated, service_role;
grant select on table public.bestball_daily_scores to anon;

alter table public.bestball_daily_scores enable row level security;

drop policy if exists "bb_daily_select_all" on public.bestball_daily_scores;
create policy "bb_daily_select_all" on public.bestball_daily_scores
for select using (true);

drop policy if exists "bb_daily_insert_auth" on public.bestball_daily_scores;
create policy "bb_daily_insert_auth" on public.bestball_daily_scores
for insert with check (auth.uid() is not null);

drop policy if exists "bb_daily_update_auth" on public.bestball_daily_scores;
create policy "bb_daily_update_auth" on public.bestball_daily_scores
for update using (auth.uid() is not null);

-- Atomic profile stats adjustment for global pick settlement
-- SECURITY DEFINER bypasses RLS so any authenticated user can adjust another user's stats
create or replace function public.adjust_profile_stats(
  p_user_id uuid, p_rr_delta int, p_wins_delta int, p_losses_delta int
) returns void as $$
begin
  update public.profiles
  set rr_score = rr_score + p_rr_delta,
      wins = wins + p_wins_delta,
      losses = losses + p_losses_delta
  where id = p_user_id;
end;
$$ language plpgsql security definer;

grant execute on function public.adjust_profile_stats(uuid, int, int, int) to authenticated;

select pg_notify('pgrst', 'reload schema');

-- ============================================================
-- Chat V2 Migration: League-specific chat rooms
-- ============================================================
-- Add league_id to chat_messages (NULL = All Chat, non-null = league chat)
alter table public.chat_messages add column if not exists league_id text;
create index if not exists idx_chat_messages_league on public.chat_messages(league_id);

-- Explicit RLS policies for chat_messages so every authenticated user can
-- read all messages in a chat room and insert their own. Without these,
-- earlier-migration policies (if any) could restrict SELECT to your own
-- messages and other users' messages in a private group chat would
-- silently never appear.
alter table public.chat_messages enable row level security;

drop policy if exists "chat_messages_select_all_auth" on public.chat_messages;
create policy "chat_messages_select_all_auth" on public.chat_messages
    for select to authenticated using (true);

drop policy if exists "chat_messages_insert_self" on public.chat_messages;
create policy "chat_messages_insert_self" on public.chat_messages
    for insert to authenticated with check (auth.uid()::text = user_id);

drop policy if exists "chat_messages_update_self" on public.chat_messages;
create policy "chat_messages_update_self" on public.chat_messages
    for update to authenticated using (auth.uid()::text = user_id);

drop policy if exists "chat_messages_delete_self" on public.chat_messages;
create policy "chat_messages_delete_self" on public.chat_messages
    for delete to authenticated using (auth.uid()::text = user_id);

-- ============================================================
-- Disk IO optimization: hot-path indexes
-- ============================================================
-- These cover the queries the iOS app fires most frequently. Each one
-- below was previously a sequential scan (or worse) once the table grew
-- past a few thousand rows. Adding them is the single biggest IO win
-- before scaling past a handful of users.

-- Pick'em: settlement and stat-restore paths
create index if not exists idx_pickem_picks_result_isnull
    on public.pickem_picks(result) where result is null;
create index if not exists idx_pickem_picks_user_settled
    on public.pickem_picks(user_id, settled_at desc);
create index if not exists idx_pickem_picks_user_result
    on public.pickem_picks(user_id, result);

-- DFS: per-tournament results and user entries
create index if not exists idx_dfs_results_tournament
    on public.dfs_tournament_results(tournament_id);
create index if not exists idx_dfs_results_tournament_user
    on public.dfs_tournament_results(tournament_id, user_id);
create index if not exists idx_dfs_entries_user_submitted
    on public.dfs_entries(user_id, submitted_at desc);
create index if not exists idx_dfs_entries_tournament_user
    on public.dfs_entries(tournament_id, user_id);

-- Tier games + tennis brackets: per-user entry lookup
create index if not exists idx_st_entries_tid_user
    on public.soccer_tiers_entries(tournament_id, user_id);
create index if not exists idx_pt_entries_tid_user
    on public.playoff_tiers_entries(tournament_id, user_id);
create index if not exists idx_tb_entries_tid_user
    on public.tennis_bracket_entries(tournament_id, user_id);
create index if not exists idx_gt_entries_tid_user
    on public.golf_tiers_entries(tournament_id, user_id);

-- Chat: per-room recent messages
create index if not exists idx_chat_messages_league_created
    on public.chat_messages(league_id, created_at desc);

select pg_notify('pgrst', 'reload schema');

-- ============================================================
-- Best Ball V3.5 Migration: Configurable starter slots (pitcher/batter)
-- ============================================================
alter table public.bestball_leagues add column if not exists pitcher_slots integer not null default 2;
alter table public.bestball_leagues add column if not exists batter_slots integer not null default 6;

select pg_notify('pgrst', 'reload schema');

-- ============================================================
-- Best Ball V3 Migration: Private leagues, configurable settings, commissioner
-- ============================================================
-- 1. Add commissioner (created_by), private flag, max members, invite code
alter table public.bestball_leagues add column if not exists is_private boolean not null default false;
alter table public.bestball_leagues add column if not exists created_by uuid references auth.users(id) on delete set null;
alter table public.bestball_leagues add column if not exists max_members integer not null default 12;
alter table public.bestball_leagues add column if not exists invite_code text;

select pg_notify('pgrst', 'reload schema');

-- ============================================================
-- Playoff Tiers V2 Migration: Private Groups
-- ============================================================
create table if not exists public.playoff_tiers_groups (
    id uuid primary key default gen_random_uuid(),
    tournament_id text not null references public.playoff_tiers_tournaments(id) on delete cascade,
    name text not null,
    created_by uuid not null references auth.users(id) on delete cascade,
    invite_code text not null unique,
    max_members integer not null default 20,
    created_at timestamptz not null default now()
);

create table if not exists public.playoff_tiers_group_members (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.playoff_tiers_groups(id) on delete cascade,
    user_id uuid not null references auth.users(id) on delete cascade,
    display_name text not null,
    joined_at timestamptz not null default now(),
    unique (group_id, user_id)
);

create index if not exists idx_pt_groups_tournament on public.playoff_tiers_groups(tournament_id);
create index if not exists idx_pt_groups_invite on public.playoff_tiers_groups(invite_code);
create index if not exists idx_pt_group_members_group on public.playoff_tiers_group_members(group_id);
create index if not exists idx_pt_group_members_user on public.playoff_tiers_group_members(user_id);

grant select, insert, update, delete on table public.playoff_tiers_groups to authenticated, service_role;
grant select on table public.playoff_tiers_groups to anon;
grant select, insert, update, delete on table public.playoff_tiers_group_members to authenticated, service_role;
grant select on table public.playoff_tiers_group_members to anon;

alter table public.playoff_tiers_groups enable row level security;
alter table public.playoff_tiers_group_members enable row level security;

drop policy if exists "pt_groups_select_all" on public.playoff_tiers_groups;
create policy "pt_groups_select_all" on public.playoff_tiers_groups
for select using (true);

drop policy if exists "pt_groups_insert_auth" on public.playoff_tiers_groups;
create policy "pt_groups_insert_auth" on public.playoff_tiers_groups
for insert with check (auth.uid() is not null);

drop policy if exists "pt_groups_update_owner" on public.playoff_tiers_groups;
create policy "pt_groups_update_owner" on public.playoff_tiers_groups
for update using (auth.uid() = created_by);

drop policy if exists "pt_groups_delete_owner" on public.playoff_tiers_groups;
create policy "pt_groups_delete_owner" on public.playoff_tiers_groups
for delete using (auth.uid() = created_by);

drop policy if exists "pt_group_members_select_all" on public.playoff_tiers_group_members;
create policy "pt_group_members_select_all" on public.playoff_tiers_group_members
for select using (true);

drop policy if exists "pt_group_members_insert_auth" on public.playoff_tiers_group_members;
create policy "pt_group_members_insert_auth" on public.playoff_tiers_group_members
for insert with check (auth.uid() is not null);

drop policy if exists "pt_group_members_delete_own" on public.playoff_tiers_group_members;
create policy "pt_group_members_delete_own" on public.playoff_tiers_group_members
for delete using (auth.uid() = user_id);

select pg_notify('pgrst', 'reload schema');

-- ============================================================
-- SOCCER WORLD CUP TIERS
-- ============================================================

create table if not exists public.soccer_tiers_tournaments (
    id text primary key,
    title text not null,
    season text not null,
    status text not null default 'open' check (status in ('open', 'locked', 'live', 'settled')),
    lock_time timestamptz,
    entry_count integer not null default 1000,
    bot_field jsonb,
    is_settled boolean not null default false,
    created_at timestamptz not null default now()
);

create table if not exists public.soccer_tiers_entries (
    id uuid primary key default gen_random_uuid(),
    tournament_id text not null references public.soccer_tiers_tournaments(id) on delete cascade,
    user_id uuid references auth.users(id) on delete set null,
    entry_name text not null,
    picks jsonb not null default '[]',
    total_points double precision not null default 0,
    rank integer not null default 0,
    is_bot boolean not null default false,
    created_at timestamptz not null default now(),
    unique (tournament_id, user_id)
);

create table if not exists public.soccer_tiers_groups (
    id uuid primary key default gen_random_uuid(),
    tournament_id text not null references public.soccer_tiers_tournaments(id) on delete cascade,
    name text not null,
    created_by uuid not null references auth.users(id) on delete cascade,
    invite_code text not null unique,
    max_members integer not null default 20,
    created_at timestamptz not null default now()
);

create table if not exists public.soccer_tiers_group_members (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references public.soccer_tiers_groups(id) on delete cascade,
    user_id uuid not null references auth.users(id) on delete cascade,
    display_name text not null,
    joined_at timestamptz not null default now(),
    unique (group_id, user_id)
);

-- Indexes
create index if not exists idx_st_entries_tournament on public.soccer_tiers_entries(tournament_id);
create index if not exists idx_st_entries_user on public.soccer_tiers_entries(user_id);
create index if not exists idx_st_groups_tournament on public.soccer_tiers_groups(tournament_id);
create index if not exists idx_st_groups_invite on public.soccer_tiers_groups(invite_code);
create index if not exists idx_st_group_members_group on public.soccer_tiers_group_members(group_id);
create index if not exists idx_st_group_members_user on public.soccer_tiers_group_members(user_id);

-- Grants
grant select, insert, update, delete on table public.soccer_tiers_tournaments to authenticated, service_role;
grant select on table public.soccer_tiers_tournaments to anon;
grant select, insert, update, delete on table public.soccer_tiers_entries to authenticated, service_role;
grant select on table public.soccer_tiers_entries to anon;
grant select, insert, update, delete on table public.soccer_tiers_groups to authenticated, service_role;
grant select on table public.soccer_tiers_groups to anon;
grant select, insert, update, delete on table public.soccer_tiers_group_members to authenticated, service_role;
grant select on table public.soccer_tiers_group_members to anon;

-- RLS
alter table public.soccer_tiers_tournaments enable row level security;
alter table public.soccer_tiers_entries enable row level security;
alter table public.soccer_tiers_groups enable row level security;
alter table public.soccer_tiers_group_members enable row level security;

-- Tournaments: readable by all, writable by authenticated
drop policy if exists "st_tournaments_select_all" on public.soccer_tiers_tournaments;
create policy "st_tournaments_select_all" on public.soccer_tiers_tournaments
for select using (true);

drop policy if exists "st_tournaments_insert_auth" on public.soccer_tiers_tournaments;
create policy "st_tournaments_insert_auth" on public.soccer_tiers_tournaments
for insert with check (auth.uid() is not null);

drop policy if exists "st_tournaments_update_auth" on public.soccer_tiers_tournaments;
create policy "st_tournaments_update_auth" on public.soccer_tiers_tournaments
for update using (auth.uid() is not null);

-- Entries: readable by all, writable by authenticated
drop policy if exists "st_entries_select_all" on public.soccer_tiers_entries;
create policy "st_entries_select_all" on public.soccer_tiers_entries
for select using (true);

drop policy if exists "st_entries_insert_auth" on public.soccer_tiers_entries;
create policy "st_entries_insert_auth" on public.soccer_tiers_entries
for insert with check (auth.uid() is not null);

drop policy if exists "st_entries_update_auth" on public.soccer_tiers_entries;
create policy "st_entries_update_auth" on public.soccer_tiers_entries
for update using (auth.uid() is not null);

drop policy if exists "st_entries_delete_auth" on public.soccer_tiers_entries;
create policy "st_entries_delete_auth" on public.soccer_tiers_entries
for delete using (auth.uid() is not null);

-- Groups: readable by all, insert by auth, update/delete by owner
drop policy if exists "st_groups_select_all" on public.soccer_tiers_groups;
create policy "st_groups_select_all" on public.soccer_tiers_groups
for select using (true);

drop policy if exists "st_groups_insert_auth" on public.soccer_tiers_groups;
create policy "st_groups_insert_auth" on public.soccer_tiers_groups
for insert with check (auth.uid() is not null);

drop policy if exists "st_groups_update_owner" on public.soccer_tiers_groups;
create policy "st_groups_update_owner" on public.soccer_tiers_groups
for update using (auth.uid() = created_by);

drop policy if exists "st_groups_delete_owner" on public.soccer_tiers_groups;
create policy "st_groups_delete_owner" on public.soccer_tiers_groups
for delete using (auth.uid() = created_by);

-- Group members: readable by all, insert by auth, delete own
drop policy if exists "st_group_members_select_all" on public.soccer_tiers_group_members;
create policy "st_group_members_select_all" on public.soccer_tiers_group_members
for select using (true);

drop policy if exists "st_group_members_insert_auth" on public.soccer_tiers_group_members;
create policy "st_group_members_insert_auth" on public.soccer_tiers_group_members
for insert with check (auth.uid() is not null);

drop policy if exists "st_group_members_delete_own" on public.soccer_tiers_group_members;
create policy "st_group_members_delete_own" on public.soccer_tiers_group_members
for delete using (auth.uid() = user_id);

-- One-shot cleanup: delete duplicate soccer_tiers_groups rows where the same
-- creator made two groups with the same name (caused by transient retries on
-- create). Keep the earliest row; FK cascade drops orphaned memberships.
delete from public.soccer_tiers_groups g1
where exists (
    select 1 from public.soccer_tiers_groups g2
    where g2.created_by = g1.created_by
      and g2.name = g1.name
      and g2.created_at < g1.created_at
);

-- Prevent a single user from creating two groups with the same name.
alter table public.soccer_tiers_groups drop constraint if exists soccer_tiers_groups_creator_name_unique;
alter table public.soccer_tiers_groups add constraint soccer_tiers_groups_creator_name_unique unique (created_by, name);

-- ──────────────────────────────────────────────
-- DFS PRIVATE CONTESTS (invite-code based, no bots)
-- ──────────────────────────────────────────────

create table if not exists public.dfs_private_contests (
    id uuid primary key default gen_random_uuid(),
    parent_tournament_id text not null references public.dfs_tournaments(id) on delete cascade,
    name text not null,
    created_by uuid not null references auth.users(id) on delete cascade,
    invite_code text not null unique,
    max_members integer not null default 20,
    created_at timestamptz not null default now()
);

create table if not exists public.dfs_private_contest_members (
    id uuid primary key default gen_random_uuid(),
    contest_id uuid not null references public.dfs_private_contests(id) on delete cascade,
    user_id uuid not null references auth.users(id) on delete cascade,
    display_name text not null,
    joined_at timestamptz not null default now(),
    unique (contest_id, user_id)
);

create table if not exists public.dfs_private_contest_entries (
    id uuid primary key default gen_random_uuid(),
    contest_id uuid not null references public.dfs_private_contests(id) on delete cascade,
    user_id uuid not null references auth.users(id) on delete cascade,
    display_name text not null default 'Player',
    lineup_player_ids text[] not null,
    lineup_total_points double precision not null default 0,
    submitted_at timestamptz not null default now(),
    unique (contest_id, user_id)
);

-- Indexes
create index if not exists idx_dfs_pc_parent on public.dfs_private_contests(parent_tournament_id);
create index if not exists idx_dfs_pc_invite on public.dfs_private_contests(invite_code);
create index if not exists idx_dfs_pc_members_contest on public.dfs_private_contest_members(contest_id);
create index if not exists idx_dfs_pc_members_user on public.dfs_private_contest_members(user_id);
create index if not exists idx_dfs_pc_entries_contest on public.dfs_private_contest_entries(contest_id);
create index if not exists idx_dfs_pc_entries_user on public.dfs_private_contest_entries(user_id);

-- Grants
grant select, insert, update, delete on table public.dfs_private_contests to authenticated, service_role;
grant select on table public.dfs_private_contests to anon;
grant select, insert, update, delete on table public.dfs_private_contest_members to authenticated, service_role;
grant select on table public.dfs_private_contest_members to anon;
grant select, insert, update, delete on table public.dfs_private_contest_entries to authenticated, service_role;
grant select on table public.dfs_private_contest_entries to anon;

-- RLS
alter table public.dfs_private_contests enable row level security;
alter table public.dfs_private_contest_members enable row level security;
alter table public.dfs_private_contest_entries enable row level security;

drop policy if exists "dfs_pc_select_all" on public.dfs_private_contests;
create policy "dfs_pc_select_all" on public.dfs_private_contests
for select using (true);

drop policy if exists "dfs_pc_insert_auth" on public.dfs_private_contests;
create policy "dfs_pc_insert_auth" on public.dfs_private_contests
for insert with check (auth.uid() = created_by);

drop policy if exists "dfs_pc_update_owner" on public.dfs_private_contests;
create policy "dfs_pc_update_owner" on public.dfs_private_contests
for update using (auth.uid() = created_by);

drop policy if exists "dfs_pc_delete_owner" on public.dfs_private_contests;
create policy "dfs_pc_delete_owner" on public.dfs_private_contests
for delete using (auth.uid() = created_by);

drop policy if exists "dfs_pc_members_select_all" on public.dfs_private_contest_members;
create policy "dfs_pc_members_select_all" on public.dfs_private_contest_members
for select using (true);

drop policy if exists "dfs_pc_members_insert_self" on public.dfs_private_contest_members;
create policy "dfs_pc_members_insert_self" on public.dfs_private_contest_members
for insert with check (auth.uid() = user_id);

drop policy if exists "dfs_pc_members_delete_self" on public.dfs_private_contest_members;
create policy "dfs_pc_members_delete_self" on public.dfs_private_contest_members
for delete using (auth.uid() = user_id);

drop policy if exists "dfs_pc_entries_select_all" on public.dfs_private_contest_entries;
create policy "dfs_pc_entries_select_all" on public.dfs_private_contest_entries
for select using (true);

drop policy if exists "dfs_pc_entries_insert_self" on public.dfs_private_contest_entries;
create policy "dfs_pc_entries_insert_self" on public.dfs_private_contest_entries
for insert with check (auth.uid() = user_id);

drop policy if exists "dfs_pc_entries_update_self" on public.dfs_private_contest_entries;
create policy "dfs_pc_entries_update_self" on public.dfs_private_contest_entries
for update using (auth.uid() = user_id);

drop policy if exists "dfs_pc_entries_delete_self" on public.dfs_private_contest_entries;
create policy "dfs_pc_entries_delete_self" on public.dfs_private_contest_entries
for delete using (auth.uid() = user_id);

-- ============================================================================
-- Tennis Odds Cache
-- ============================================================================
-- Cached tennis moneylines fetched from Pinnacle (or fallback provider) by a
-- Supabase Edge Function on a cron schedule. The iOS app reads from this
-- table instead of hitting the Odds API directly — one external call every
-- few minutes regardless of user count.
-- ============================================================================

create table if not exists public.tennis_odds (
    id text primary key,                          -- pinnacle matchup id
    league text not null,                         -- 'atp' | 'wta' | 'tennis'
    home_team text not null,
    away_team text not null,
    home_moneyline integer,                       -- american odds, e.g. -150 / +120
    away_moneyline integer,
    starts_at timestamptz not null,
    fetched_at timestamptz not null default now(),
    source text not null default 'pinnacle'
);

create index if not exists tennis_odds_starts_at_idx on public.tennis_odds(starts_at);
create index if not exists tennis_odds_league_idx on public.tennis_odds(league);

alter table public.tennis_odds enable row level security;

drop policy if exists "tennis_odds_select_all" on public.tennis_odds;
create policy "tennis_odds_select_all" on public.tennis_odds
for select using (true);

-- Writes only via the edge function (service-role key), not from clients.
-- No insert/update/delete policies → those are blocked for normal users.

-- ============================================================
-- Profile avatars (chat + profile screens)
-- Adds avatar_url to profiles and creates a public storage bucket with
-- per-user RLS so users can only overwrite their own avatar path.
-- ============================================================
alter table public.profiles add column if not exists avatar_url text;

insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do nothing;

create policy "Avatars are publicly readable"
  on storage.objects for select using (bucket_id = 'avatars');

create policy "Users can upload their own avatar"
  on storage.objects for insert with check (
    bucket_id = 'avatars' and auth.uid()::text = (storage.foldername(name))[1]
  );

create policy "Users can update their own avatar"
  on storage.objects for update using (
    bucket_id = 'avatars' and auth.uid()::text = (storage.foldername(name))[1]
  );

-- ============================================================
-- Chat reactions
-- (message_id, user_id, emoji) is unique so a user can react with the
-- same emoji at most once per message. Cascade-deletes ensure stale
-- reactions clear when the original message is deleted.
-- ============================================================
create table if not exists public.chat_reactions (
    id uuid primary key default gen_random_uuid(),
    message_id uuid not null references public.chat_messages(id) on delete cascade,
    user_id uuid not null,
    emoji text not null,
    created_at timestamptz not null default now(),
    unique (message_id, user_id, emoji)
);

create index if not exists idx_chat_reactions_message on public.chat_reactions(message_id);

alter table public.chat_reactions enable row level security;

create policy "reactions_select_all" on public.chat_reactions
for select using (true);

create policy "reactions_insert_own" on public.chat_reactions
for insert with check (auth.uid() = user_id);

create policy "reactions_delete_own" on public.chat_reactions
for delete using (auth.uid() = user_id);

-- Account deletion RPC (Apple App Review 5.1.1(v) compliance).
-- The client cannot delete from `auth.users` directly; this function runs
-- with SECURITY DEFINER so it can. It deletes only the CALLER's row, and
-- the ON DELETE CASCADE on `profiles.id` (plus every other FK referencing
-- `auth.users(id)`) cascades through every piece of user-owned data.
create or replace function public.delete_current_user()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
    caller uuid;
begin
    caller := auth.uid();
    if caller is null then
        raise exception 'Not authenticated';
    end if;
    delete from auth.users where id = caller;
end;
$$;

revoke all on function public.delete_current_user() from public;
grant execute on function public.delete_current_user() to authenticated;

select pg_notify('pgrst', 'reload schema');

