# The console — what to build

The framework ships the ledger, the rules, the routine stub and the
procedure. The owner's console is deliberately left for you (or your agent)
to build: it is the part that should look like *your* company, and every
screen below is one SQL query against views the installer already creates.
Any stack works. The reference implementation is a small Next.js app that
runs SQL through the Supabase Management API with one personal access token
(`POST https://api.supabase.com/v1/projects/<ref>/database/query`, body
`{ "query": "..." }`), so one deployment serves every company.

## Registry

A map of companies the console can reach, from an environment variable or a
local file, never committed:

```json
{ "acme": { "name": "Acme", "projectRef": "<20 chars>", "schema": "acme_agents", "repo": "owner/acme" } }
```

Gate the whole thing behind a single shared key or your own auth; there is
one user.

## Pages

**Home**: every company with `wall_metrics`, `programme.phase`,
`fleet_state.paused`, open `wall_flags`, open `wall_gates`, and unroutable
`wakes` in the last two days.

**Board** (`/c/<company>`)
- Paused banner with **Resume** (`select <s>.fleet_resume()`) or **Pause**
  (`select <s>.fleet_pause('<reason>')`).
- **Ask the General Manager**: a textarea, then `select <s>.owner_task('<text>')`.
- Programme: `wall_programme`; set the phase with an `update <s>.programme`.
- Seats grouped by division from `wall_agents` (status dot, last run linked
  to its session url, runs and flags over 7 days, staffed or not).
- Open flags (`wall_flags`) with a close button (`update <s>.events set
  resolved_at = now(), resolved_by = 'owner', resolution = ... where id = ...`).
- The gate (`wall_gates`), open mandates (`wall_mandates`), activations still
  `requested` (`wall_activation`), the latest wakes (`wall_wakes`, with
  `http_status`), the event flow (`wall_flow`).
- A **flush** button: `select <s>.flush_deferred(null); select <s>.reroute_unroutable(null)`.
- Forms to add a division (`divisions`) and a seat (`agents`).

**Seat** (`/c/<company>/agents/<slug>`)
- Settings: name, role, division, model, expected_every_hours, sort,
  routine_id; an upsert on `agents`.
- Dispatch: whether a token is on file (`select routine_id, added_at from
  dispatch where agent_slug = ...`; never select the token), a form to save
  one (`insert into dispatch ... on conflict do update`), then
  `select <s>.reroute_unroutable('<slug>')`.
- Recent runs (`runs`, newest first).
- Prompt: the active body in a textarea; saving calls
  `select <s>.set_prompt('<slug>', '<body>', 'console', '<note>')`; a
  versions table from `prompts` with a restore button (`set_prompt` with the
  old body). A preview of what the seat really receives:
  `select prompt from <s>.seat_brief('<slug>')`.
- Schedules: rows of `schedules` (cron, payload, note, enabled); insert,
  update, delete. The trigger keeps pg_cron in sync.
- Delete the seat (`delete from agents where slug = ...`; everything cascades).

**Rule blocks** (`/c/<company>/rules`): edit `rule_blocks` (key, applies_to
roles, sort, body); upsert and delete.

**Wall**: a full-screen display for a spare monitor. One query every 30 s:

```sql
select json_build_object(
  'agents',   (select coalesce(json_agg(a order by a.division_sort nulls first, a.sort, a.name),'[]'::json) from <s>.wall_agents a),
  'metrics',  (select row_to_json(m) from <s>.wall_metrics m),
  'byday',    (select coalesce(json_agg(d order by d.day),'[]'::json) from <s>.wall_runs_by_day d),
  'flow',     (select coalesce(json_agg(f order by f.at desc),'[]'::json) from <s>.wall_flow f),
  'gates',    (select coalesce(json_agg(g),'[]'::json) from <s>.wall_gates g),
  'flags',    (select coalesce(json_agg(x),'[]'::json) from <s>.wall_flags x),
  'divisions',(select coalesce(json_agg(x order by x.sort),'[]'::json) from <s>.divisions x),
  'at', now());
```

Three screens work well: the fleet as an organism (nucleus = GM, one cell per
division, seats on each membrane, pulsing while running, hollow when
unstaffed), metrics tiles with runs by day, and a three-column flow (the
gate, the live stream, flagged).

## Rules the console must respect

- Every write is a plain SQL statement against the company's schema. The
  functions (`set_prompt`, `owner_task`, `fleet_pause`, `fleet_resume`,
  `flush_deferred`, `reroute_unroutable`) are `security definer` with
  execute revoked from `public`, so run them as the project owner (the
  Management API does).
- Never display a fire token after it is saved. Never put a token in a URL.
- Quote every literal (`'` becomes `''`); validate the schema name against
  `^[a-z_][a-z0-9_]*$` before it is interpolated.
- Prompts are never overwritten: a save is a new version; restore is a new
  version with an old body.
