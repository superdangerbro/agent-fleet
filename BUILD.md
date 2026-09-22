# Building a fleet for a new business

This is the complete procedure for standing up the agent fleet for a company
of any size. It is written to be followed top to bottom by a person or
by a Claude Code session with this repository checked out. Every step names
the file it uses and the thing you should see when it worked.

Time to a running fleet, once the prerequisites exist: about two hours, most
of it creating routines by hand at claude.ai (there is no API for that).

---

## 0. What you are building

```
                         owner
                           │  owner_task()            GM's run summary
                           ▼                               ▲
                    ┌──────────────┐                       │
                    │ General      │──issue_mandate()──►  division managers
                    │ Manager      │◄──report_mandate()──  (one per division)
                    └──────────────┘                          │
                                                  request_activation()  ▼
                                                              workers
                                                                │ stage()
                                                                ▼
                                                     team auditor (per division)
                                                                │ audit('team','approved')
                                                                ▼
                                                        database auditor ──promote()──► production
```

Everything above is a row in one Postgres schema, the **ledger**. A row landing
in a hand-off table fires the routine of the seat that consumes it, from inside
the database (`pg_net` → Claude Code routine fire API). That is the queue, and
it runs in both directions: mandates and activations go down, staged changes,
verdicts and reports come up. Schedules are backstops (a General Manager
check-in every few hours, a daily gate sweep, weekly standing watches), never
the driver.

Each seat is a **Claude Code routine** whose instructions are an eight-line
stub: *load your seat from the ledger, do what its prompt says*. Prompts, rules
and schedules are rows, so they are edited in the **console**, versioned, and
never touched in the routine form again.

Three pieces, three places:

| Piece | Lives in | Per company |
|---|---|---|
| Ledger (schema, queue, prompts, schedules) | the company's Supabase project | `installer/render.py --schema <name>` |
| Seats (routines) | claude.ai → Code → Routines, on the company repo | one routine per seat, the stub from `routines/STUB.md` |
| Console (agents, prompts, rules, schedules, board, pause, ask the GM) | `console/`, one deployment for all companies | one entry in the registry (`FLEET_COMPANIES` or a local `companies.json`) |

Plus the company repository itself, which needs four things (§3).

---

## 1. Prerequisites

- **A Supabase project** for the company (Postgres 15+). The ledger is a schema
  inside the product database — same project the app uses — because the
  Database Auditor has to verify the product live and the workers read it.
  Extensions `pg_cron` and `pg_net` must be available (they are on every
  Supabase plan; the installer enables them).
- **A GitHub repository** for the company's code, private is fine.
- **Claude Code with routines** on the account that owns the fleet. Routines
  bill the Claude subscription, not an API key; that is deliberate.
- **A Supabase personal access token** (`sbp_…`). One token serves the
  console for every company and is what each routine's MCP servers use.
  `supabase login` stores one; the console can reuse it (§5).
- Optional: the `supabase` CLI, `psql`, or the Supabase MCP connector in
  Claude — any one way to run SQL against the project.

Decide the **ledger schema name** now: `<company>_agents` (lowercase, letters,
digits, underscores). It is the one parameter everything else is rendered from.

---

## 2. Install the ledger

```bash
python installer/render.py --schema acme_agents --with-rules > acme-ledger.sql
```

Run `acme-ledger.sql` once against the project (Supabase SQL editor, `psql`,
or the Supabase MCP `apply_migration`). It is idempotent; re-running it later
upgrades the functions in place and leaves data alone. `--with-rules` seeds the
shared rule blocks; leave it off on a re-run if you have edited them.

What it creates, all inside the schema:

- **Roster**: `divisions`, `agents` (seats: slug, division, role, model,
  routine id), `dispatch` (per-seat routine id + fire token; the only table
  that holds a secret).
- **Reporting**: `runs`, `events`; functions `run_start`, `note`, `flag`,
  `run_finish`, `resolve_flag`, `escalate_flag`. Every seat calls these first
  and last.
- **The programme**: `programme` (one row: phase), `mandates`, `work_items`;
  `set_phase`, `issue_mandate`, `report_mandate`, `add_work_item`,
  `assign_work`, `set_work_state`.
- **Delegation and the gate**: `activation` (`request_activation`,
  `resolve_activation`), `changes` (`stage`), `audits` (`audit`),
  `promotions` (`promote`), `request_seats`.
- **The queue**: `wakes`, `fleet_state`; `wake()`, `seat_is_live()`,
  `flush_deferred()`, `reroute_unroutable()`; nine triggers that call `wake()`
  when a hand-off row lands (§7 lists them); a pg_cron job
  `<schema>:flush` every five minutes.
- **Configuration**: `rule_blocks`, `prompts`, `schedules`; `set_prompt()`,
  `composed_prompt()`, `seat_brief()`, `owner_task()`, `fleet_pause()`,
  `fleet_resume()`, `check_liveness()`. Schedules are mirrored into pg_cron as
  `<schema>:<slug>:<id>` by a trigger.
- **The wall**: read views `wall_programme`, `wall_agents`, `wall_metrics`,
  `wall_runs_by_day`, `wall_flow`, `wall_gates`, `wall_mandates`,
  `wall_work`, `wall_flags`, `wall_activation`, `wall_wakes`. The console and
  the agents read these.

A fresh install is **paused** (`fleet_state.paused = true`) with phase `scope`.
Nothing can fire until you resume in §6.

Check:

```sql
select * from acme_agents.wall_programme;      -- one row, phase scope
select jobname from cron.job where jobname like 'acme_agents:%';   -- acme_agents:flush
```

---

## 3. Define the company

Copy `companies/example/seed.sql`, rename the schema, and edit the rows. It is
plain SQL: divisions, seats, one prompt per seat, a few schedules. Run it once.

**Naming rules the functions depend on** (everything else is free):

| Seat | slug | role |
|---|---|---|
| the one seat that reports to the owner | `general-manager` | `general_manager` |
| the one seat that promotes to production | `database-auditor` | `database_auditor` |
| a division's manager | `<division>-manager` | `division_manager` |
| a division's team auditor | `<division>-auditor` | `team_auditor` |
| a worker | anything, conventionally `<division>-<thing>` | `worker` |
| a standing watch (runs on a schedule, stages findings, never fixes) | anything | `auditor` |

The triggers derive `<division>-manager` and `<division>-auditor` from the
division slug; a division without those two seats has a queue that leads
nowhere (wakes land as `unroutable` and the GM carries them out by hand).

**Prompts.** The rule blocks (installed in §2) are the company-neutral half:
identity, report yourself, obey the queue payload, verify before you trust, and
one LIMITS block per role. The seat prompt is the specific half: what this seat
owns, which workers a manager has, what a watch looks for. Keep seat prompts
short; the rules already say how to report, stage and audit. `seat_brief()`
composes them and substitutes `{slug}`, `{name}`, `{division}`, `{schema}`.

**Schedules.** Give the General Manager one (`17 */3 * * *` works well), the
Database Auditor one daily, each standing watch one weekly. Give workers,
managers and team auditors **none** — they run when the queue wakes them. This
is the single biggest cost control: an idle worker costs nothing.

**Models.** Sonnet for most seats, Opus for the General Manager and the
Database Auditor, Haiku for a watch whose job is a diff. `agents.model` is what
the ledger records; the routine's actual model is set at claude.ai (§4).

**Phase.** `scope` until every division has stated what it owns; then `build`;
`test` when the product is being verified end to end; `operate` after launch.
The GM issues mandates per phase; the phase is read from the ledger, never
assumed from a document.

---

## 4. Wire the company repository

Four files.

### 4a. `.mcp.json` — how a seat reaches the database

Three Supabase MCP servers on the same project, distinguished by role:

```json
{
  "mcpServers": {
    "acme-db":        { "command": "npx", "args": ["-y", "@supabase/mcp-server-supabase@latest", "--read-only", "--project-ref=<ref>"], "env": { "SUPABASE_ACCESS_TOKEN": "${SUPABASE_ACCESS_TOKEN}" } },
    "acme-telemetry": { "command": "npx", "args": ["-y", "@supabase/mcp-server-supabase@latest", "--project-ref=<ref>"],               "env": { "SUPABASE_ACCESS_TOKEN": "${SUPABASE_ACCESS_TOKEN}" } },
    "acme-migrate":   { "command": "npx", "args": ["-y", "@supabase/mcp-server-supabase@latest", "--project-ref=<ref>"],               "env": { "SUPABASE_ACCESS_TOKEN": "${SUPABASE_ACCESS_TOKEN}" } }
  }
}
```

`-db` is read-only by construction (product reads). `-telemetry` is the ledger
(every seat writes its runs, notes, stages, audits through it). `-migrate` is
the same server again under a name that the rules reserve for the Database
Auditor — the gate is the rule, not the credential; the audit trail is what
makes a violation visible. The token comes from the routine's environment
(set `SUPABASE_ACCESS_TOKEN` in the routine's settings at claude.ai, or as a
repository-level secret the routine environment exposes).

### 4b. `.claude/settings.json` — no permission prompts

```json
{
  "enableAllProjectMcpServers": true,
  "permissions": {
    "allow": ["mcp__acme-db", "mcp__acme-telemetry", "mcp__acme-migrate", "mcp__Supabase", "mcp__supabase",
              "Bash", "Read", "Edit", "Write", "MultiEdit", "NotebookEdit", "Glob", "Grep",
              "WebFetch", "WebSearch", "Agent", "Task", "TodoWrite"],
    "deny": []
  }
}
```

Without this, every SQL call from every seat asks the owner's phone for
approval. The fleet is unattended by design; the gates live in the rules and
the promotion chain.

### 4c. `CLAUDE.md` — the rules

The sections a company's `CLAUDE.md` must carry (write them for the company;
the rule blocks in `installer/rules.sql` are the condensed form of the same
rules and the two must agree):

1. **What you are doing right now** — point at the newest
   `docs/dev/HANDOFF-*.md` and say the ledger's phase is the truth.
2. **Delegation** — nobody does their own department's work; the manager pass
   (split the mandate into `request_activation` rows, wait for "YOUR WORKERS
   HAVE REPORTED", write work items honestly, `report_mandate`).
3. **The queue is the driver** — the table of which row wakes which seat, and
   the `QUEUE WAKE` rule: do only the payload, report, stop.
4. **Prompts, rules and schedules live in the ledger** — the routine is a stub.
5. **Check-in: the backstop** — the schedules and what a GM check-in does.
6. **Waking a seat you may not spawn** — the Database Auditor is never a
   subagent; `dispatch` and the manual `curl` for unroutable wakes.
7. **Flags** — anyone raises one, the GM closes every one; only `critical`
   wakes the GM.
8. **Roles** — the LIMITS for each role (mirrors `rule_blocks`).
9. **Things that will trip you up** — the shared clone is shared (worktrees
   only), migrations applied through the MCP are recorded under generated
   names, permissions are pre-approved on purpose.

### 4d. Hygiene

- `.githooks/pre-commit` refusing commits in the primary worktree on any
  branch but `main`, and `git config core.hooksPath .githooks` on every clone.
  A seat that checks its branch out in the shared clone silently captures
  every other seat's commits.
- `docs/dev/HANDOFF-<date>.md` whenever the fleet is paused: what shipped, why
  it is off, where each division starts, how to resume.
- Optionally `.github/workflows/fleet-wake-gm.yml` on `workflow_dispatch`
  only, firing the GM with a repository secret — a hand doorbell. Never on
  pull-request events: every PR open and merge starts an Opus session the
  queue already covers.

---

## 5. Run the console

```bash
cd console
cp .env.example .env.local        # SUPABASE_ACCESS_TOKEN=sbp_…, CONSOLE_KEY=<anything>
npm install
npm run build && npm run start -- -p 3111
```

Register the company. The registry is configuration, never committed: for a
local console copy `companies.example.json` to `companies.json` (gitignored);
for a hosted one put the same JSON in the `FLEET_COMPANIES` environment
variable.

```json
{ "acme": { "name": "Acme", "projectRef": "<20-char ref>", "schema": "acme_agents", "repo": "owner/acme", "routinesUrl": "https://claude.ai/code/routines" } }
```

Open `http://localhost:3111/?key=<CONSOLE_KEY>` once; a cookie keeps you in.
Deploy it anywhere Next.js runs. The owner's deployment is on Vercel, made
from the `console/` directory with the CLI (the project root is `console/`,
not the repository root):

```bash
cd console
vercel link --yes --project fleet-console --scope <team-slug>
vercel env add SUPABASE_ACCESS_TOKEN production --sensitive   # paste the sbp_ token
vercel env add CONSOLE_KEY production
vercel env add FLEET_COMPANIES production        # the registry JSON, one line
vercel --prod --yes
```

It is one deployment for every company: the home page lists them all with
phase, staffing, running, flags, gate and unroutable counts. Adding a company
is one entry in the registry and a redeploy.

Per company:

- **Wall** (`/wall.html?c=acme`): the full-screen display — Organism (the
  fleet as a body: nucleus, division cells, seats on each membrane, pulsing
  when running), Metrics (tiles, runs by day, staffing by department) and
  Flow (the gates, the live stream, flagged). Keys 1/2/3 or arrows switch
  screens, R cycles rotation for a spare monitor. Reads
  `/api/c/acme/snapshot` every 30 s.
- **Board** (`/c/acme`): pause / resume, Ask the General Manager, set phase,
  every seat grouped by division with status and last run, open flags (close
  from here), the gate, open mandates, activations still waiting for a token,
  the latest wakes with their HTTP outcome, the event flow.
- **Seat** (`/c/acme/agents/<slug>`): settings, dispatch (paste the routine id
  and fire token; waiting wakes are rerouted immediately), recent runs,
  prompt editor with full version history and one-click restore, the composed
  `seat_brief()` the seat actually receives, schedules (each row is a pg_cron
  job).
- **Rule blocks** (`/c/acme/rules`): the shared rules, per role.

Everything the console does is SQL through the Supabase Management API with
the one access token; there is no console database.

---

## 6. Create the seats' routines and go live

For each seat, follow `routines/STUB.md`: new routine on the company repo, the
stub with the slug filled in, **Call via API** trigger only (remove the default
schedule), notifications off except for the General Manager, save, generate
the token, paste routine id + token into the seat's console page. Leave the
routine's Active switch off.

Then, in order:

1. **Resume** on the board (`fleet_resume()`): clears the pause and fires every
   deferred wake, coalesced per seat.
2. **Flip every routine's Active switch on** at claude.ai. This is the one
   state the ledger cannot see or set.
3. **Test the loop with one task**: type into Ask the General Manager —
   *"Confirm every division manager can hear you: issue each one a mandate to
   state what its division owns."* Within a few minutes the board shows a GM
   run, a mandate per division, a manager run per division, activations, then
   worker runs, then "YOUR WORKERS HAVE REPORTED" manager runs, then reported
   mandates and a GM run with a summary. `wall_wakes` shows each step as a
   `fired` row with `http_status` 200.
4. **Watch for `unroutable`** on the board: a seat with no token. Paste its
   token and the wake reroutes. **Watch for `failed`**: HTTP 401 is a wrong or
   revoked token, 404 a wrong routine id.

---

## 7. Operating it

**Talking to the fleet.** Only through the General Manager: Ask the GM on the
board (`owner_task()`), or the GM's run summaries, which are written as the
owner's report — what got done, what is broken, what needs the owner. No other
seat notifies the owner. That is the notification policy, and it is a rule
block.

**Pausing.** Pause on the board before sleeping if you do not trust what is
queued. Every wake while paused is deferred; resume flushes them coalesced.
Pause closes `running` rows so nothing looks alive that is not.

**Prompts.** Edit on the seat page; each save is a new version, the previous
one stays; restore is one click. The change applies on the seat's next run. A
prompt a seat remembers from a previous run is never authoritative.

**Rules.** Edit on the rules page. `applies_to` scopes a block to roles;
blank means everyone. A new house rule for all workers is one row.

**Schedules.** Add or disable on the seat page. Each row is mirrored into
pg_cron as `<schema>:<slug>:<id>` whose command is `wake()`, so scheduled runs
honour the pause gate, the fire-time lock and the dispatch table.

**Adding a seat.** Board → Add a seat; write its prompt; create its routine;
paste the token. If it is a new division, add the division first and give it a
manager and a team auditor, or the queue has nowhere to send its rows.

**Removing a seat.** Delete on the seat page (runs, prompts, schedules and the
token go with it). Deactivate the routine at claude.ai too, or a stale schedule
there would still run it.

**Cost controls, all on by default.** A seat is *live* from the moment a wake
fires (30 minutes for the GM, 15 for others) and while a run is `running`; a
wake for a live seat is deferred and coalesced. Only `critical` flags wake the
GM. A manager is woken once when its last worker finishes, not per worker. A
promotion closes its work item by trigger, waking nobody. Workers have no
schedules. The queue payload says "do ONLY this" and the rules repeat it —
that line is what stopped fourteen GM runs in half an hour.

**Liveness.** Set `expected_every_hours` on seats that must run on a cadence;
`check_liveness()` (run it from a schedule or by hand) flags a seat overdue by
50% once a day.

---

## 8. Adapting the shape

- **Fewer divisions**: fine down to one. One manager, one team auditor, one or
  more workers.
- **No Database Auditor**: leave the seat unstaffed. Team-approved changes
  wake `database-auditor` and land as `unroutable`; the GM carries them out
  by hand — or, in a company where team approval is the last gate, edit
  `trg_audit_wake` to promote on team approval. The gate is a function; change
  it deliberately, in a migration, with the reason in the commit.
- **Different gate**: the promotion chain is `stage → audit(team) →
  audit(database) → promote`. A second team tier is another `audits.tier`
  value and one more branch in `trg_audit_wake`.
- **Non-code work**: `changes.kind` is `code | data | roster`; a change does
  not need a PR. A worker that writes documents stages the document path as
  `staging_ref`.
- **A second repo in one company**: `divisions.repo` and `agents.repo` are
  free text the prompts can use; each routine runs on one repo, so a division
  on another repo just has its routines created there.
- **A second company on the same database**: supported — job names and
  functions are schema-namespaced. But prefer one project per company; the
  Database Auditor's remit is the project.

---

## 9. Things that will trip you up

- **`cron.schedule()` replaces a same-named job silently.** Job names carry
  the schema for exactly this reason. Never hand-create a job called
  `fleet:…`.
- **The routine's default trigger is a daily 9 AM run.** Remove it. A seat
  with a schedule in the routine form bypasses the pause gate and the lock.
- **Migrations applied through the Supabase MCP are recorded under generated
  names**, not the file's number. Write every ledger migration to be safely
  re-runnable (`if not exists`, `create or replace`) and say in the file what
  name it was applied under.
- **`execute_sql` on the Supabase MCP is read-only** and cannot call
  `wake()`, `set_prompt()` or the other `security definer` functions whose
  execute was revoked from `public`. Writes go through `apply_migration`, the
  SQL editor, or the console.
- **GitHub Actions minutes run out** on a private repo with a chatty fleet;
  the symptom is a job with zero steps and a billing annotation. Add overage or
  stop running CI on every agent branch.
- **The first click after navigating a claude.ai routine page is often
  swallowed.** When scripting the routine form, retry the open until the
  dialog exists.
- **Two seats can share a session id** (the same cloud session serving two
  routines in sequence); `runs` is unique on `(agent_slug, session_id)`, not
  `session_id`. Do not "fix" that.
- **A seat that decides on its own to review the board** on a queue wake is
  the token fire. The payload prefix and the `20-queue` rule block exist to
  stop it; if a seat does it anyway, its prompt is the place to fix it, not a
  schedule.

---

## 10. Reference

**Wake payload prefixes** (what a seat sees, and what it means):

| Prefix | Woken seat | Cause |
|---|---|---|
| `QUEUE WAKE (<ref>)` | any | wrapper on every queue wake |
| `MANDATE #n` | `<division>-manager` | `issue_mandate()` |
| `ACTIVATION #n` | the worker | `request_activation()` |
| `CHANGE #n staged` | `<division>-auditor` | `stage()` |
| `CHANGE #n is team-approved` | `database-auditor` | `audit(..,'team','approved',..)` |
| `YOUR CHANGE #n … came back needs_work` | the worker | `audit(..,'needs_work'|'rejected',..)` |
| `CHANGE #n … ready for RE-AUDIT` | `<division>-auditor` | a note containing "re-audit" and "change #n" |
| `MANDATE #n … is reported` | `general-manager` | `report_mandate()` |
| `CRITICAL FLAG #n` | `general-manager` | `flag(.., 'critical', ..)` |
| `YOUR WORKERS HAVE REPORTED` | `<division>-manager` | last live worker's `run_finish()` |
| `ONE-OFF FROM THE OWNER` | `general-manager` | `owner_task()` |
| `SCHEDULED RUN` | the scheduled seat | a `schedules` row |

**Wake states**: `fired` (HTTP request sent; `http_status` filled by the next
flush), `deferred` (paused, or seat live — coalesced later), `unroutable` (no
token — `reroute_unroutable()` sends it once a token exists), `failed`
(non-2xx, reason holds the response).

**Files in this repository**:

```
installer/schema.sql      the ledger, {{SCHEMA}} placeholder
installer/rules.sql       the shared rule blocks
installer/render.py       renders both for one schema name
routines/STUB.md          the routine stub and the by-hand steps
companies/example/seed.sql a template company
console/                  the owner's console (Next.js)
```
