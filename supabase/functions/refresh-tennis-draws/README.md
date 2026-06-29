# refresh-tennis-draws

Auto-populates each Grand Slam's 128-player main draw (ATP + WTA, in bracket
order) into `tennis_bracket_tournaments.draw_data`. The iOS app reads Supabase
`draw_data` **before** its hardcoded fallback, so new slam draws appear for all
users **over the air — no app update / redownload**.

It discovers whichever slam the bracket source currently has live (by scraping
the pool's home-page links), validates the draw hard, and writes it. It is a
safe **no-op** when no clean 128-draw is available yet, so it can run daily and
simply back-fills each slam the day its draw drops.

## Why this exists
Hardcoding a draw per slam ships in the binary and needs an App Store update.
ESPN/official sites are JS-rendered and expose no draw *position*, so they can't
be auto-fetched in order. The Nothing Major pool embeds the official draw as
clean ordered JSON — the only machine-readable source we found. Validation fails
closed (writes nothing) if that source ever changes shape, so a bad draw can
never overwrite a good one.

## Deploy
```bash
supabase functions deploy refresh-tennis-draws --no-verify-jwt
```

## Schedule (daily)
Easiest: Supabase Dashboard → Edge Functions → `refresh-tennis-draws` → add a
schedule (e.g. `0 12 * * *`).

Or via SQL (requires `pg_cron` + `pg_net` extensions, enabled under
Database → Extensions):
```sql
select cron.schedule(
  'refresh-tennis-draws-daily',
  '0 12 * * *',   -- 12:00 UTC every day
  $$
  select net.http_post(
    url := 'https://myhyzjfsyfvwmzknjdof.supabase.co/functions/v1/refresh-tennis-draws',
    headers := '{"Content-Type":"application/json"}'::jsonb
  );
  $$
);
```
To remove: `select cron.unschedule('refresh-tennis-draws-daily');`

## Test manually
```bash
curl -i -X POST https://myhyzjfsyfvwmzknjdof.supabase.co/functions/v1/refresh-tennis-draws
```
Returns a JSON `report` array, one entry per discovered draw, e.g.
`{"tid":"us_open-atp-2026","status":"inserted"}`. Statuses:
`inserted` / `updated` (wrote the draw), `already_populated` (skipped — row
already has 128), `validation_failed` / `fetch_failed` (safe no-op).

## Notes
- Writes only `draw_data` on existing rows — never touches `status`,
  `lock_time`, `results_data`, or `bot_field`, so it won't disturb a live or
  settled tournament.
- `country` is left blank and `rank` is derived from seed (the source has
  neither); the app shows the seed instead of a rank for these draws and uses
  the approximated rank only to seed the bot win-probability model.
- Depends on the Nothing Major pool running a bracket for the slam. If they
  don't (or change their page), the slam stays unavailable until handled
  manually — the function never corrupts anything, it just writes nothing.
