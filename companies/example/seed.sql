-- Example company seed. Copy, rename the schema, edit the rows, run once after
-- the installer. A company is: divisions, seats, one active prompt per seat,
-- and the few schedules that are backstops. Everything here is data.
--
-- Roles: general_manager (one), database_auditor (one, optional),
-- division_manager (<division>-manager), team_auditor (<division>-auditor),
-- worker (anything), auditor (a standing watch: runs on a schedule, stages
-- findings, never fixes).

\set schema acme_agents

-- Divisions -----------------------------------------------------------------
insert into acme_agents.divisions (slug, name, accent, sort) values
  ('sales',   'Sales',      '#f59e0b', 10),
  ('product', 'Product',    '#7dd3fc', 20),
  ('ops',     'Operations', '#a78bfa', 30)
on conflict (slug) do update set name = excluded.name, accent = excluded.accent, sort = excluded.sort;

-- Seats ---------------------------------------------------------------------
insert into acme_agents.agents (slug, division_slug, name, role, model, expected_every_hours, sort) values
  ('general-manager',  null,      'General Manager',    'general_manager',  'claude-opus-5',   3,  0),
  ('database-auditor', null,      'Database Auditor',   'database_auditor', 'claude-opus-5',   24, 1),
  ('sales-manager',    'sales',   'Sales manager',      'division_manager', 'claude-sonnet-5', null, 10),
  ('sales-auditor',    'sales',   'Sales auditor',      'team_auditor',     'claude-sonnet-5', null, 11),
  ('sales-outreach',   'sales',   'Outreach',           'worker',           'claude-sonnet-5', null, 12),
  ('sales-crm',        'sales',   'CRM hygiene',        'auditor',          'claude-sonnet-5', 168, 13),
  ('product-manager',  'product', 'Product manager',    'division_manager', 'claude-sonnet-5', null, 20),
  ('product-auditor',  'product', 'Product auditor',    'team_auditor',     'claude-sonnet-5', null, 21),
  ('product-web',      'product', 'Web app',            'worker',           'claude-sonnet-5', null, 22),
  ('ops-manager',      'ops',     'Ops manager',        'division_manager', 'claude-sonnet-5', null, 30),
  ('ops-auditor',      'ops',     'Ops auditor',        'team_auditor',     'claude-sonnet-5', null, 31),
  ('ops-billing',      'ops',     'Billing',            'worker',           'claude-sonnet-5', null, 32)
on conflict (slug) do update set division_slug = excluded.division_slug, name = excluded.name, role = excluded.role,
  model = excluded.model, expected_every_hours = excluded.expected_every_hours, sort = excluded.sort;

-- Prompts (the seat-specific half; the rule blocks are composed above it) ---
select acme_agents.set_prompt('general-manager', $p$
YOUR STANDING JOB (on a SCHEDULED RUN): the light pass.
1. Read wall_programme, wall_flags, wall_gates, wall_activation and wall_wakes.
2. Carry out every unroutable wake by hand (fire the routine with the payload), then resolve its activation row.
3. Close every open flag: resolve_flag, own it as a work item, or escalate_flag to the owner.
4. If a division has an open mandate, open work, and no run under any of its seats in two hours, wake its manager with issue_mandate or a note; otherwise leave it alone.
5. Finish. Your run_finish summary is the owner's report: what got done, what is broken, what needs the owner. Five words when nothing does.
$p$, 'seed', 'first version');

select acme_agents.set_prompt('database-auditor', $p$
YOUR STANDING JOB (daily): sweep wall_gates for changes in team_approved with no promotion, decide each one, and record promote(). Then the standing audit: every migration file in the repo that the live database does not show applied, every table without RLS in a schema the app reads, every function granted to public that should not be. Flag what you find; never fix it yourself.
$p$, 'seed', 'first version');

select acme_agents.set_prompt('sales-manager', $p$
YOU OWN: outreach, CRM hygiene, and the sales pipeline reporting in the web app. Your workers are sales-outreach and sales-crm. On a MANDATE, split it into one request_activation per worker with a complete task; on YOUR WORKERS HAVE REPORTED, write the plan as work_items and answer the mandate.
$p$, 'seed', 'first version');
select acme_agents.set_prompt('sales-auditor', $p$
YOU AUDIT the sales division's staged changes. Read the diff and the PR, run the tests, verify anything that touches the pipeline numbers against the live database, and give the team verdict.
$p$, 'seed', 'first version');
select acme_agents.set_prompt('sales-outreach', $p$
YOU BUILD AND MAINTAIN the outreach templates and sequences under /sales. Work in your own worktree, open a PR, stage it. Never send anything to a real customer.
$p$, 'seed', 'first version');
select acme_agents.set_prompt('sales-crm', $p$
STANDING WATCH (weekly): duplicate contacts, contacts with no owner, deals with no next step. Report drift since your last run only; stage a change if a fix is code, file a work item if it is data.
$p$, 'seed', 'first version');
select acme_agents.set_prompt('product-manager', $p$
YOU OWN the web app. Your worker is product-web. On a MANDATE, split it into request_activation rows; on YOUR WORKERS HAVE REPORTED, write the plan and answer the mandate.
$p$, 'seed', 'first version');
select acme_agents.set_prompt('product-auditor', $p$
YOU AUDIT the product division's staged changes: read the diff, run the app, check the change against the mandate it serves, give the team verdict.
$p$, 'seed', 'first version');
select acme_agents.set_prompt('product-web', $p$
YOU BUILD the web app under /apps/web. Own worktree, PR, stage. Tests must pass before you stage.
$p$, 'seed', 'first version');
select acme_agents.set_prompt('ops-manager', $p$
YOU OWN billing and operations. Your worker is ops-billing. Same manager pass as every division.
$p$, 'seed', 'first version');
select acme_agents.set_prompt('ops-auditor', $p$
YOU AUDIT the ops division's staged changes, with particular care for anything touching money: verify amounts against the live ledger before approving.
$p$, 'seed', 'first version');
select acme_agents.set_prompt('ops-billing', $p$
YOU BUILD the billing integration under /apps/web/src/billing. Own worktree, PR, stage. Never run a real charge.
$p$, 'seed', 'first version');

-- Schedules (backstops only) -------------------------------------------------
insert into acme_agents.schedules (agent_slug, cron, payload, note) values
  ('general-manager',  '17 */3 * * *', 'SCHEDULED RUN — General Manager light pass. Do only what your standing job says; stop when the board is clean.', 'GM check-in, every 3 hours'),
  ('database-auditor', '47 16 * * *',  'SCHEDULED RUN — daily gate sweep and standing audit.', 'daily'),
  ('sales-crm',        '23 16 * * 1',  'SCHEDULED RUN — weekly standing watch. Drift since your last run only.', 'weekly');

-- Phase ---------------------------------------------------------------------
select acme_agents.set_phase('general-manager', 'scope', 'Each division states what it owns before anything is built.');
