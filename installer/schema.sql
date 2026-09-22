-- Fleet ledger — installable schema template.
--
-- Render with installer/render.py --schema <name>, which replaces the schema
-- placeholder with the company's ledger schema (e.g. acme_agents) and
-- prints SQL you run once against that company's Postgres/Supabase project.
-- Idempotent: every statement is create-if-not-exists or create-or-replace.
--
-- Conventions the functions rely on (slugs are data, but these shapes are fixed):
--   general-manager        the one seat that reports to the owner
--   database-auditor       the one seat that promotes to production (optional; leave vacant)
--   <division>-manager     a division's manager
--   <division>-auditor     a division's team auditor
-- Everything else — divisions, workers, standing watches — is whatever rows you insert.

create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;
create schema if not exists {{SCHEMA}};

-- ---------------------------------------------------------------------------
-- Tables

create table if not exists {{SCHEMA}}.divisions (
  slug        text primary key,
  name        text not null,
  accent      text not null default '#7dd3fc',
  repo        text,
  sort        int  not null default 100,
  created_at  timestamptz not null default now()
);

create table if not exists {{SCHEMA}}.agents (
  slug                 text primary key,
  division_slug        text references {{SCHEMA}}.divisions(slug) on delete cascade,
  name                 text not null,
  role                 text not null check (role in ('general_manager','division_manager','worker','auditor','team_auditor','database_auditor')),
  routine_id           text unique,
  repo                 text,
  model                text,
  model_note           text,
  triggers             text[] not null default '{}',
  status               text not null default 'vacant' check (status in ('idle','running','failed','flagged','vacant')),
  last_run_at          timestamptz,
  expected_every_hours int,
  overdue_since        timestamptz,
  overdue_alerted_at   timestamptz,
  sort                 int not null default 100,
  created_at           timestamptz not null default now()
);

create table if not exists {{SCHEMA}}.runs (
  id            bigint generated always as identity primary key,
  agent_slug    text not null references {{SCHEMA}}.agents(slug) on delete cascade,
  session_id    text,
  session_url   text,
  trigger       text not null check (trigger in ('schedule','api','manual','manager')),
  started_at    timestamptz not null default now(),
  ended_at      timestamptz,
  status        text not null default 'running' check (status in ('running','succeeded','failed','cancelled')),
  summary       text,
  commands      int,
  files_read    int,
  files_changed int,
  pr_url        text,
  flagged       boolean not null default false,
  flag_reason   text,
  constraint runs_agent_session_key unique (agent_slug, session_id)
);
create index if not exists runs_agent_recent_idx on {{SCHEMA}}.runs (agent_slug, started_at desc);
create index if not exists runs_recent_idx on {{SCHEMA}}.runs (started_at desc);

create table if not exists {{SCHEMA}}.events (
  id           bigint generated always as identity primary key,
  run_id       bigint references {{SCHEMA}}.runs(id) on delete cascade,
  agent_slug   text references {{SCHEMA}}.agents(slug) on delete cascade,
  at           timestamptz not null default now(),
  kind         text not null check (kind in ('start','tool','note','flag','finish')),
  severity     text not null default 'info' check (severity in ('info','warn','critical')),
  message      text not null,
  resolved_at  timestamptz,
  resolved_by  text,
  resolution   text,
  owner        text
);
create index if not exists events_recent_idx on {{SCHEMA}}.events (at desc);
create index if not exists events_open_flags_idx on {{SCHEMA}}.events (at desc) where kind = 'flag' and resolved_at is null;

create table if not exists {{SCHEMA}}.changes (
  id             bigint generated always as identity primary key,
  run_id         bigint references {{SCHEMA}}.runs(id) on delete set null,
  agent_slug     text not null references {{SCHEMA}}.agents(slug),
  division_slug  text references {{SCHEMA}}.divisions(slug),
  title          text not null,
  detail         text,
  staging_ref    text,
  pr_url         text,
  risk           text not null default 'normal' check (risk in ('low','normal','high')),
  kind           text not null default 'code' check (kind in ('code','data','roster')),
  payload        jsonb,
  state          text not null default 'staged' check (state in ('staged','team_approved','escalated','rejected','promoted')),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index if not exists changes_open_idx on {{SCHEMA}}.changes (state, created_at desc);

create table if not exists {{SCHEMA}}.audits (
  id            bigint generated always as identity primary key,
  change_id     bigint not null references {{SCHEMA}}.changes(id) on delete cascade,
  auditor_slug  text not null references {{SCHEMA}}.agents(slug),
  tier          text not null check (tier in ('team','database')),
  verdict       text not null check (verdict in ('approved','rejected','needs_work','escalated')),
  rationale     text not null,
  at            timestamptz not null default now()
);
create index if not exists audits_change_idx on {{SCHEMA}}.audits (change_id, at);

create table if not exists {{SCHEMA}}.promotions (
  id            bigint generated always as identity primary key,
  change_id     bigint not null references {{SCHEMA}}.changes(id),
  auditor_slug  text not null references {{SCHEMA}}.agents(slug),
  staging_ref   text,
  method        text not null default 'merge',
  outcome       text not null check (outcome in ('promoted','withheld','failed')),
  rationale     text not null,
  at            timestamptz not null default now()
);

create table if not exists {{SCHEMA}}.programme (
  id      boolean primary key default true check (id),
  phase   text not null default 'scope' check (phase in ('scope','build','test','operate')),
  note    text,
  set_by  text references {{SCHEMA}}.agents(slug),
  set_at  timestamptz not null default now()
);

create table if not exists {{SCHEMA}}.mandates (
  id             bigint generated always as identity primary key,
  division_slug  text not null references {{SCHEMA}}.divisions(slug) on delete cascade,
  phase          text not null check (phase in ('scope','build','test','operate')),
  title          text not null,
  detail         text,
  issued_by      text not null references {{SCHEMA}}.agents(slug),
  issued_at      timestamptz not null default now(),
  due_by         timestamptz,
  state          text not null default 'issued' check (state in ('issued','accepted','reported','closed','withdrawn')),
  reported_at    timestamptz,
  report         text
);
create index if not exists mandates_open_idx on {{SCHEMA}}.mandates (state, division_slug);

create table if not exists {{SCHEMA}}.work_items (
  id             bigint generated always as identity primary key,
  division_slug  text references {{SCHEMA}}.divisions(slug) on delete cascade,
  title          text not null,
  detail         text,
  kind           text not null default 'feature' check (kind in ('feature','fix','test','chore','recurring','spike')),
  blocks_launch  boolean not null default false,
  priority       int not null default 100,
  effort         text check (effort in ('small','medium','large','unknown')),
  state          text not null default 'proposed' check (state in ('proposed','accepted','assigned','in_progress','in_review','done','dropped')),
  assigned_to    text references {{SCHEMA}}.agents(slug),
  created_by     text not null references {{SCHEMA}}.agents(slug),
  change_id      bigint references {{SCHEMA}}.changes(id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index if not exists work_open_idx on {{SCHEMA}}.work_items (state, blocks_launch desc, priority);
create index if not exists work_division_idx on {{SCHEMA}}.work_items (division_slug, state);

create table if not exists {{SCHEMA}}.activation (
  id            bigint generated always as identity primary key,
  agent_slug    text not null references {{SCHEMA}}.agents(slug) on delete cascade,
  requested_by  text not null references {{SCHEMA}}.agents(slug) on delete cascade,
  task          text not null,
  work_item_id  bigint references {{SCHEMA}}.work_items(id) on delete set null,
  state         text not null default 'requested' check (state in ('requested','activated','declined')),
  requested_at  timestamptz not null default now(),
  resolved_at   timestamptz,
  resolution    text
);
create index if not exists activation_open_idx on {{SCHEMA}}.activation (state, requested_at);

create table if not exists {{SCHEMA}}.dispatch (
  agent_slug  text primary key references {{SCHEMA}}.agents(slug) on delete cascade,
  routine_id  text not null,
  fire_token  text not null,
  why         text not null,
  added_at    timestamptz not null default now()
);

create table if not exists {{SCHEMA}}.fleet_state (
  id         boolean primary key default true check (id),
  paused     boolean not null default false,
  paused_at  timestamptz,
  paused_by  text,
  reason     text
);

create table if not exists {{SCHEMA}}.wakes (
  id           bigint generated always as identity primary key,
  agent_slug   text not null references {{SCHEMA}}.agents(slug),
  ref          text not null,
  payload      text not null,
  state        text not null check (state in ('fired','deferred','unroutable','failed')),
  reason       text,
  request_id   bigint,
  http_status  int,
  created_at   timestamptz not null default now(),
  fired_at     timestamptz
);
create index if not exists wakes_pending_idx on {{SCHEMA}}.wakes (agent_slug) where state = 'deferred';

create table if not exists {{SCHEMA}}.rule_blocks (
  key         text primary key,
  applies_to  text[] not null default '{}',
  sort        int not null default 100,
  body        text not null,
  note        text,
  updated_at  timestamptz not null default now(),
  updated_by  text
);

create table if not exists {{SCHEMA}}.prompts (
  id          bigint generated always as identity primary key,
  agent_slug  text not null references {{SCHEMA}}.agents(slug) on delete cascade,
  version     int not null,
  body        text not null,
  note        text,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  created_by  text,
  unique (agent_slug, version)
);
create unique index if not exists prompts_one_active on {{SCHEMA}}.prompts (agent_slug) where active;

create table if not exists {{SCHEMA}}.schedules (
  id          bigint generated always as identity primary key,
  agent_slug  text not null references {{SCHEMA}}.agents(slug) on delete cascade,
  cron        text not null,
  payload     text not null default 'SCHEDULED RUN. Do your standing job as your prompt describes; stop when it is done.',
  enabled     boolean not null default true,
  note        text,
  jobname     text generated always as ('{{SCHEMA}}:' || agent_slug || ':' || id) stored,
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Reporting: what every seat calls

create or replace function {{SCHEMA}}.run_start(p_agent text, p_session text, p_url text, p_trigger text default 'schedule')
returns bigint language plpgsql as $$
declare v_run bigint;
begin
  insert into {{SCHEMA}}.runs (agent_slug, session_id, session_url, trigger)
  values (p_agent, p_session, p_url, p_trigger)
  on conflict (agent_slug, session_id) do update set started_at = {{SCHEMA}}.runs.started_at
  returning id into v_run;
  update {{SCHEMA}}.agents set status = 'running', last_run_at = now() where slug = p_agent;
  insert into {{SCHEMA}}.events (run_id, agent_slug, kind, message) values (v_run, p_agent, 'start', 'run started');
  return v_run;
end $$;

create or replace function {{SCHEMA}}.run_finish(p_run bigint, p_status text, p_summary text default null, p_commands int default null, p_files_read int default null, p_files_changed int default null, p_pr_url text default null)
returns void language plpgsql as $$
declare v_agent text;
begin
  update {{SCHEMA}}.runs
     set ended_at = now(), status = p_status, summary = p_summary,
         commands = p_commands, files_read = p_files_read, files_changed = p_files_changed, pr_url = p_pr_url
   where id = p_run returning agent_slug into v_agent;
  update {{SCHEMA}}.agents a
     set status = case when p_status <> 'succeeded' then 'failed'
                       when exists (select 1 from {{SCHEMA}}.runs r where r.id = p_run and r.flagged) then 'flagged'
                       else 'idle' end
   where a.slug = v_agent;
  insert into {{SCHEMA}}.events (run_id, agent_slug, kind, severity, message)
  values (p_run, v_agent, 'finish', case when p_status = 'succeeded' then 'info' else 'warn' end, coalesce(p_summary, 'run ' || p_status));
end $$;

create or replace function {{SCHEMA}}.note(p_run bigint, p_message text, p_kind text default 'note')
returns void language sql as $$
  insert into {{SCHEMA}}.events (run_id, agent_slug, kind, message)
  select p_run, r.agent_slug, p_kind, p_message from {{SCHEMA}}.runs r where r.id = p_run;
$$;

create or replace function {{SCHEMA}}.flag(p_run bigint, p_severity text, p_message text)
returns void language plpgsql as $$
declare v_agent text;
begin
  update {{SCHEMA}}.runs set flagged = true, flag_reason = p_message where id = p_run returning agent_slug into v_agent;
  insert into {{SCHEMA}}.events (run_id, agent_slug, kind, severity, message) values (p_run, v_agent, 'flag', p_severity, p_message);
end $$;

create or replace function {{SCHEMA}}.resolve_flag(p_id bigint, p_by text, p_resolution text, p_owner text default null)
returns void language plpgsql as $$
begin
  update {{SCHEMA}}.events set resolved_at = now(), resolved_by = p_by, resolution = p_resolution, owner = coalesce(p_owner, owner)
   where id = p_id and kind = 'flag';
  insert into {{SCHEMA}}.events (agent_slug, kind, severity, message)
  values (p_by, 'note', 'info', 'flag #' || p_id || ' resolved: ' || left(p_resolution, 160));
end $$;

-- ---------------------------------------------------------------------------
-- The programme: phase, mandates, work

create or replace function {{SCHEMA}}.set_phase(p_by text, p_phase text, p_note text default null)
returns void language plpgsql as $$
begin
  update {{SCHEMA}}.programme set phase = p_phase, note = p_note, set_by = p_by, set_at = now() where id;
  insert into {{SCHEMA}}.events (agent_slug, kind, message) values (p_by, 'note', 'programme phase set to ' || p_phase || coalesce(': ' || p_note, ''));
end $$;

create or replace function {{SCHEMA}}.issue_mandate(p_by text, p_division text, p_phase text, p_title text, p_detail text default null, p_due_by timestamptz default null)
returns bigint language plpgsql as $$
declare v_id bigint;
begin
  insert into {{SCHEMA}}.mandates (division_slug, phase, title, detail, issued_by, due_by)
  values (p_division, p_phase, p_title, p_detail, p_by, p_due_by) returning id into v_id;
  insert into {{SCHEMA}}.events (agent_slug, kind, message) values (p_by, 'note', 'mandate #' || v_id || ' to ' || p_division || ': ' || p_title);
  return v_id;
end $$;

create or replace function {{SCHEMA}}.report_mandate(p_id bigint, p_by text, p_report text, p_state text default 'reported')
returns void language plpgsql as $$
begin
  update {{SCHEMA}}.mandates set state = p_state, report = p_report, reported_at = now() where id = p_id;
  insert into {{SCHEMA}}.events (agent_slug, kind, message) values (p_by, 'note', 'mandate #' || p_id || ' ' || p_state || ': ' || left(p_report, 160));
end $$;

create or replace function {{SCHEMA}}.add_work_item(p_by text, p_division text, p_title text, p_kind text default 'feature', p_detail text default null, p_blocks_launch boolean default false, p_priority int default 100, p_effort text default 'unknown')
returns bigint language plpgsql as $$
declare v_id bigint;
begin
  insert into {{SCHEMA}}.work_items (division_slug, title, detail, kind, blocks_launch, priority, effort, created_by)
  values (p_division, p_title, p_detail, p_kind, p_blocks_launch, p_priority, p_effort, p_by) returning id into v_id;
  insert into {{SCHEMA}}.events (agent_slug, kind, message)
  values (p_by, 'note', case when p_blocks_launch then 'BLOCKER ' else '' end || 'work #' || v_id || ' (' || p_kind || '): ' || p_title);
  return v_id;
end $$;

create or replace function {{SCHEMA}}.assign_work(p_id bigint, p_by text, p_to text)
returns void language plpgsql as $$
begin
  update {{SCHEMA}}.work_items set assigned_to = p_to, state = 'assigned', updated_at = now() where id = p_id;
  insert into {{SCHEMA}}.events (agent_slug, kind, message) values (p_by, 'note', 'work #' || p_id || ' assigned to ' || p_to);
end $$;

create or replace function {{SCHEMA}}.set_work_state(p_id bigint, p_by text, p_state text, p_note text default null)
returns void language plpgsql as $$
begin
  update {{SCHEMA}}.work_items set state = p_state, updated_at = now() where id = p_id;
  insert into {{SCHEMA}}.events (agent_slug, kind, message) values (p_by, 'note', 'work #' || p_id || ' -> ' || p_state || coalesce(': ' || p_note, ''));
end $$;

create or replace function {{SCHEMA}}.escalate_flag(p_id bigint, p_by text, p_title text, p_detail text)
returns bigint language plpgsql as $$
declare v_wi bigint;
begin
  v_wi := {{SCHEMA}}.add_work_item(p_by, null, 'OWNER: ' || p_title, 'chore', p_detail, true, 1, 'unknown');
  update {{SCHEMA}}.work_items set state = 'accepted' where id = v_wi;
  perform {{SCHEMA}}.resolve_flag(p_id, p_by, 'Escalated to the owner as work item #' || v_wi || ': ' || p_title, 'OWNER');
  return v_wi;
end $$;

-- ---------------------------------------------------------------------------
-- Delegation and the gate

create or replace function {{SCHEMA}}.request_activation(p_by text, p_agent text, p_task text, p_work_item bigint default null)
returns bigint language plpgsql as $$
declare v_id bigint;
begin
  insert into {{SCHEMA}}.activation (agent_slug, requested_by, task, work_item_id)
  values (p_agent, p_by, p_task, p_work_item) returning id into v_id;
  insert into {{SCHEMA}}.events (agent_slug, kind, message)
  values (p_by, 'note', 'requested activation #' || v_id || ' for ' || p_agent || ': ' || left(p_task, 140));
  return v_id;
end $$;

create or replace function {{SCHEMA}}.resolve_activation(p_id bigint, p_by text, p_state text, p_resolution text default null)
returns void language plpgsql as $$
begin
  update {{SCHEMA}}.activation set state = p_state, resolved_at = now(), resolution = p_resolution where id = p_id;
  insert into {{SCHEMA}}.events (agent_slug, kind, message)
  values (p_by, 'note', 'activation #' || p_id || ' ' || p_state || coalesce(': ' || p_resolution, ''));
end $$;

create or replace function {{SCHEMA}}.request_seats(p_manager text, p_run bigint, p_title text, p_seats jsonb, p_why text default null)
returns bigint language plpgsql as $$
declare v_id bigint;
begin
  insert into {{SCHEMA}}.changes (run_id, agent_slug, division_slug, title, detail, kind, payload, risk)
  select p_run, p_manager, a.division_slug, p_title, p_why, 'roster', p_seats, 'normal'
    from {{SCHEMA}}.agents a where a.slug = p_manager returning id into v_id;
  insert into {{SCHEMA}}.events (run_id, agent_slug, kind, message)
  values (p_run, p_manager, 'note', 'requested ' || coalesce(jsonb_array_length(p_seats), 0) || ' seat(s): ' || p_title);
  return v_id;
end $$;

create or replace function {{SCHEMA}}.stage(p_agent text, p_run bigint, p_title text, p_detail text default null, p_staging_ref text default null, p_pr_url text default null, p_risk text default 'normal')
returns bigint language plpgsql as $$
declare v_id bigint;
begin
  insert into {{SCHEMA}}.changes (run_id, agent_slug, division_slug, title, detail, staging_ref, pr_url, risk)
  select p_run, p_agent, a.division_slug, p_title, p_detail, p_staging_ref, p_pr_url, p_risk
    from {{SCHEMA}}.agents a where a.slug = p_agent returning id into v_id;
  insert into {{SCHEMA}}.events (run_id, agent_slug, kind, message) values (p_run, p_agent, 'note', 'staged change #' || v_id || ': ' || p_title);
  return v_id;
end $$;

create or replace function {{SCHEMA}}.audit(p_change bigint, p_auditor text, p_tier text, p_verdict text, p_rationale text)
returns void language plpgsql as $$
begin
  insert into {{SCHEMA}}.audits (change_id, auditor_slug, tier, verdict, rationale) values (p_change, p_auditor, p_tier, p_verdict, p_rationale);
  update {{SCHEMA}}.changes set state = case
      when p_verdict = 'rejected' then 'rejected'
      when p_verdict = 'approved' and p_tier = 'team' then 'team_approved'
      when p_verdict = 'escalated' then 'escalated'
      else state end, updated_at = now()
   where id = p_change;
  insert into {{SCHEMA}}.events (agent_slug, kind, severity, message)
  values (p_auditor, 'note', case when p_verdict in ('rejected','needs_work') then 'warn' else 'info' end, p_tier || ' audit of change #' || p_change || ': ' || p_verdict);
end $$;

create or replace function {{SCHEMA}}.promote(p_change bigint, p_auditor text, p_outcome text, p_rationale text, p_staging_ref text default null)
returns void language plpgsql as $$
begin
  insert into {{SCHEMA}}.promotions (change_id, auditor_slug, staging_ref, outcome, rationale) values (p_change, p_auditor, p_staging_ref, p_outcome, p_rationale);
  update {{SCHEMA}}.changes
     set state = case when p_outcome = 'promoted' then 'promoted'
                      when state = 'promoted' and p_outcome in ('withheld','failed') then 'team_approved'
                      else state end,
         updated_at = now()
   where id = p_change;
  insert into {{SCHEMA}}.events (agent_slug, kind, severity, message)
  values (p_auditor, case when p_outcome = 'promoted' then 'note' else 'flag' end,
          case when p_outcome = 'promoted' then 'info' else 'warn' end, 'promotion of change #' || p_change || ': ' || p_outcome);
end $$;

-- ---------------------------------------------------------------------------
-- The queue: a hand-off row wakes the seat that consumes it

create or replace function {{SCHEMA}}.seat_is_live(p_agent text) returns boolean
language sql stable as $$
  select exists (select 1 from {{SCHEMA}}.runs r where r.agent_slug = p_agent and r.status = 'running' and r.started_at > now() - interval '2 hours')
      or exists (select 1 from {{SCHEMA}}.wakes w where w.agent_slug = p_agent and w.state = 'fired'
                   and w.fired_at > now() - (case when p_agent = 'general-manager' then interval '30 minutes' else interval '15 minutes' end));
$$;

create or replace function {{SCHEMA}}.wake(p_agent text, p_ref text, p_payload text)
returns bigint language plpgsql security definer set search_path = {{SCHEMA}}, extensions, net, public as $$
declare v_disp {{SCHEMA}}.dispatch%rowtype; v_id bigint; v_req bigint; v_body text;
begin
  if exists (select 1 from {{SCHEMA}}.fleet_state where paused) then
    insert into {{SCHEMA}}.wakes (agent_slug, ref, payload, state, reason)
    values (p_agent, p_ref, p_payload, 'deferred', 'fleet paused by the owner; will go out when the fleet is resumed') returning id into v_id;
    return v_id;
  end if;
  select * into v_disp from {{SCHEMA}}.dispatch where agent_slug = p_agent;
  if not found then
    insert into {{SCHEMA}}.wakes (agent_slug, ref, payload, state, reason)
    values (p_agent, p_ref, p_payload, 'unroutable', 'no fire token in dispatch for ' || p_agent) returning id into v_id;
    return v_id;
  end if;
  if {{SCHEMA}}.seat_is_live(p_agent) then
    insert into {{SCHEMA}}.wakes (agent_slug, ref, payload, state, reason)
    values (p_agent, p_ref, p_payload, 'deferred', 'seat is live or was fired minutes ago; coalesced into the next wake') returning id into v_id;
    return v_id;
  end if;
  v_body := 'QUEUE WAKE (' || p_ref || '), rung by the fleet database, not by a person. '
         || 'Record your run with trigger ''api''. Do ONLY what this payload asks, report, and stop — no board review, no code, no dispatch beyond it. ' || p_payload;
  v_req := net.http_post(
    url := 'https://api.anthropic.com/v1/claude_code/routines/' || v_disp.routine_id || '/fire',
    body := jsonb_build_object('payload', v_body),
    headers := jsonb_build_object('Authorization', 'Bearer ' || v_disp.fire_token, 'anthropic-version', '2023-06-01',
                                  'anthropic-beta', 'experimental-cc-routine-2026-04-01', 'content-type', 'application/json'),
    timeout_milliseconds := 15000);
  insert into {{SCHEMA}}.wakes (agent_slug, ref, payload, state, request_id, fired_at)
  values (p_agent, p_ref, p_payload, 'fired', v_req, now()) returning id into v_id;
  return v_id;
end $$;
revoke execute on function {{SCHEMA}}.wake(text, text, text) from public;

create or replace function {{SCHEMA}}.flush_deferred(p_agent text default null)
returns int language plpgsql security definer set search_path = {{SCHEMA}}, extensions, net, public as $$
declare v_slug text; v_ids bigint[]; v_payload text; v_ref text; v_new bigint; v_n int := 0;
begin
  for v_slug in
    select distinct w.agent_slug from {{SCHEMA}}.wakes w
     where w.state = 'deferred' and (p_agent is null or w.agent_slug = p_agent) and not {{SCHEMA}}.seat_is_live(w.agent_slug)
  loop
    select array_agg(id order by id), string_agg(payload, E'\n---\n' order by id), string_agg(ref, ',' order by id)
      into v_ids, v_payload, v_ref from {{SCHEMA}}.wakes where agent_slug = v_slug and state = 'deferred';
    v_new := {{SCHEMA}}.wake(v_slug, v_ref, v_payload);
    update {{SCHEMA}}.wakes set state = 'fired', fired_at = now(), reason = coalesce(reason,'') || ' -> re-fired as wake #' || v_new
     where id = any(v_ids) and state = 'deferred';
    v_n := v_n + 1;
  end loop;
  update {{SCHEMA}}.wakes w
     set http_status = r.status_code,
         state = case when r.status_code between 200 and 299 then 'fired' else 'failed' end,
         reason = case when r.status_code between 200 and 299 then w.reason else coalesce(w.reason,'') || ' HTTP ' || r.status_code || ': ' || left(coalesce(r.content::text,''), 200) end
    from net._http_response r
   where r.id = w.request_id and w.http_status is null and w.state = 'fired';
  return v_n;
end $$;
revoke execute on function {{SCHEMA}}.flush_deferred(text) from public;

create or replace function {{SCHEMA}}.reroute_unroutable(p_agent text default null)
returns int language plpgsql security definer set search_path = {{SCHEMA}}, public as $$
declare r record; v_wake bigint; v_n int := 0;
begin
  for r in select a.* from {{SCHEMA}}.activation a
            where a.state = 'requested' and (p_agent is null or a.agent_slug = p_agent)
              and exists (select 1 from {{SCHEMA}}.dispatch d where d.agent_slug = a.agent_slug) order by a.id
  loop
    v_wake := {{SCHEMA}}.wake(r.agent_slug, 'activation:' || r.id,
      'ACTIVATION #' || r.id || ' from ' || r.requested_by || coalesce(' (work item #' || r.work_item_id || ')','') || E':\n' || r.task);
    if exists (select 1 from {{SCHEMA}}.wakes w where w.id = v_wake and w.state in ('fired','deferred')) then
      update {{SCHEMA}}.activation set state = 'activated', resolved_at = now(), resolution = 'queue: wake #' || v_wake || ' (rerouted once the seat had a token)' where id = r.id;
      v_n := v_n + 1;
    end if;
  end loop;
  for r in select w.* from {{SCHEMA}}.wakes w
            where w.state = 'unroutable' and w.ref not like 'activation:%' and (p_agent is null or w.agent_slug = p_agent)
              and exists (select 1 from {{SCHEMA}}.dispatch d where d.agent_slug = w.agent_slug) and w.created_at > now() - interval '2 days' order by w.id
  loop
    v_wake := {{SCHEMA}}.wake(r.agent_slug, r.ref, r.payload);
    update {{SCHEMA}}.wakes set state = 'failed', reason = coalesce(reason,'') || ' -> rerouted as wake #' || v_wake where id = r.id;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;
revoke execute on function {{SCHEMA}}.reroute_unroutable(text) from public;

-- Triggers: down (mandate → manager, activation → worker) and up (change → auditor,
-- verdict → DBA or bounce, report/critical flag → GM, last worker done → manager).

create or replace function {{SCHEMA}}.trg_mandate_wake() returns trigger
language plpgsql security definer set search_path = {{SCHEMA}}, public as $$
begin
  perform {{SCHEMA}}.wake(new.division_slug || '-manager', 'mandate:' || new.id,
    'MANDATE #' || new.id || ' for your division, issued by ' || new.issued_by
    || coalesce(' (due ' || to_char(new.due_by at time zone 'utc','YYYY-MM-DD HH24:MI') || ' UTC)', '')
    || ': ' || new.title || E'\n' || coalesce(new.detail,'')
    || E'\nDo the division-manager pass: request_activation for every worker you own with its share of this mandate, then wait for their reports and answer the mandate from them.');
  return new;
end $$;
drop trigger if exists mandate_wake on {{SCHEMA}}.mandates;
create trigger mandate_wake after insert on {{SCHEMA}}.mandates for each row execute function {{SCHEMA}}.trg_mandate_wake();

create or replace function {{SCHEMA}}.trg_activation_wake() returns trigger
language plpgsql security definer set search_path = {{SCHEMA}}, public as $$
declare v_target {{SCHEMA}}.agents%rowtype; v_by {{SCHEMA}}.agents%rowtype; v_wake bigint; v_dup bigint;
begin
  if new.state <> 'requested' then return new; end if;
  select * into v_target from {{SCHEMA}}.agents where slug = new.agent_slug;
  select * into v_by from {{SCHEMA}}.agents where slug = new.requested_by;
  if v_target.role = 'team_auditor' and v_by.division_slug is not distinct from v_target.division_slug then
    update {{SCHEMA}}.activation set state = 'declined', resolved_at = now(),
           resolution = 'queue: a manager may not start its own team auditor; that gate is woken by staged changes' where id = new.id;
    return new;
  end if;
  select id into v_dup from {{SCHEMA}}.activation
   where agent_slug = new.agent_slug and id <> new.id and state = 'activated' and resolved_at > now() - interval '2 hours'
     and exists (select 1 from {{SCHEMA}}.runs r where r.agent_slug = new.agent_slug and r.status = 'running');
  v_wake := {{SCHEMA}}.wake(new.agent_slug, 'activation:' || new.id,
    'ACTIVATION #' || new.id || ' from ' || new.requested_by || coalesce(' (work item #' || new.work_item_id || ')','') || E':\n' || new.task);
  if exists (select 1 from {{SCHEMA}}.wakes where id = v_wake and state in ('fired','deferred')) then
    update {{SCHEMA}}.activation set state = 'activated', resolved_at = now(),
           resolution = 'queue: wake #' || v_wake || case when v_dup is not null then ' (deferred behind activation #' || v_dup || ')' else '' end
     where id = new.id;
  end if;
  return new;
end $$;
drop trigger if exists activation_wake on {{SCHEMA}}.activation;
create trigger activation_wake after insert on {{SCHEMA}}.activation for each row execute function {{SCHEMA}}.trg_activation_wake();

create or replace function {{SCHEMA}}.trg_change_wake() returns trigger
language plpgsql security definer set search_path = {{SCHEMA}}, public as $$
begin
  if new.state = 'staged' and new.division_slug is not null then
    perform {{SCHEMA}}.wake(new.division_slug || '-auditor', 'change:' || new.id,
      'CHANGE #' || new.id || ' staged by ' || new.agent_slug || ' (risk ' || coalesce(new.risk,'normal') || '): ' || new.title
      || coalesce(E'\nPR: ' || new.pr_url, '') || coalesce(E'\n' || new.detail, '')
      || E'\nGive the team verdict with {{SCHEMA}}.audit(' || new.id || ', ''' || new.division_slug || '-auditor'', ''team'', <verdict>, <rationale>). Verify live; needs_work beats a thin approve.');
  end if;
  return new;
end $$;
drop trigger if exists change_wake on {{SCHEMA}}.changes;
create trigger change_wake after insert on {{SCHEMA}}.changes for each row execute function {{SCHEMA}}.trg_change_wake();

create or replace function {{SCHEMA}}.trg_audit_wake() returns trigger
language plpgsql security definer set search_path = {{SCHEMA}}, public as $$
declare v_change {{SCHEMA}}.changes%rowtype;
begin
  select * into v_change from {{SCHEMA}}.changes where id = new.change_id;
  if new.tier = 'team' and new.verdict = 'approved' then
    perform {{SCHEMA}}.wake('database-auditor', 'change:' || new.change_id,
      'CHANGE #' || new.change_id || ' is team-approved by ' || new.auditor_slug || ' and waiting on you: ' || v_change.title
      || coalesce(E'\nPR: ' || v_change.pr_url, '') || E'\nTeam rationale: ' || coalesce(new.rationale,'')
      || E'\nThe decision is yours; this message only says the gate ahead of you has cleared.');
  elsif new.verdict in ('needs_work','rejected') and v_change.agent_slug is not null then
    perform {{SCHEMA}}.wake(v_change.agent_slug, 'change:' || new.change_id,
      'YOUR CHANGE #' || new.change_id || ' (' || v_change.title || coalesce(', ' || v_change.pr_url, '') || ') came back ' || new.verdict
      || ' from ' || new.auditor_slug || E':\n' || coalesce(new.rationale,'')
      || E'\nAddress every point in your own worktree, push, and leave a note on your run containing "ready for re-audit" and "change #' || new.change_id || '".');
  end if;
  return new;
end $$;
drop trigger if exists audit_wake on {{SCHEMA}}.audits;
create trigger audit_wake after insert on {{SCHEMA}}.audits for each row execute function {{SCHEMA}}.trg_audit_wake();

create or replace function {{SCHEMA}}.trg_mandate_reported_wake() returns trigger
language plpgsql security definer set search_path = {{SCHEMA}}, public as $$
begin
  if new.state is distinct from old.state and new.state in ('reported','declined','withdrawn') then
    perform {{SCHEMA}}.wake('general-manager', 'mandate:' || new.id,
      'MANDATE #' || new.id || ' (' || new.division_slug || ') is ' || new.state || ': ' || new.title
      || E'\nReport: ' || left(coalesce(new.report,''), 4000) || E'\nDo the check-in pass, starting with this division.');
  end if;
  return new;
end $$;
drop trigger if exists mandate_reported_wake on {{SCHEMA}}.mandates;
create trigger mandate_reported_wake after update on {{SCHEMA}}.mandates for each row execute function {{SCHEMA}}.trg_mandate_reported_wake();

create or replace function {{SCHEMA}}.trg_flag_wake() returns trigger
language plpgsql security definer set search_path = {{SCHEMA}}, public as $$
begin
  if new.kind = 'flag' and new.severity = 'critical' and new.agent_slug is distinct from 'general-manager' then
    perform {{SCHEMA}}.wake('general-manager', 'flag:' || new.id,
      'CRITICAL FLAG #' || new.id || ' raised by ' || coalesce(new.agent_slug,'?') || ': ' || new.message
      || E'\nClose this one flag: resolve_flag, own it as a work item, or escalate_flag to the owner. Nothing else.');
  end if;
  return new;
end $$;
drop trigger if exists flag_wake on {{SCHEMA}}.events;
create trigger flag_wake after insert on {{SCHEMA}}.events for each row execute function {{SCHEMA}}.trg_flag_wake();

create or replace function {{SCHEMA}}.trg_note_reaudit_wake() returns trigger
language plpgsql security definer set search_path = {{SCHEMA}}, public as $$
declare v_change {{SCHEMA}}.changes%rowtype; v_id bigint;
begin
  if new.kind = 'note' and new.message ~* 're-?audit' then
    v_id := (regexp_match(new.message, 'change #?(\d+)', 'i'))[1]::bigint;
    if v_id is not null then
      select * into v_change from {{SCHEMA}}.changes where id = v_id;
      if found and v_change.division_slug is not null and v_change.state = 'staged' then
        perform {{SCHEMA}}.wake(v_change.division_slug || '-auditor', 'change:' || v_id,
          'CHANGE #' || v_id || ' (' || v_change.title || coalesce(', ' || v_change.pr_url,'') || ') is ready for RE-AUDIT after your needs_work; '
          || coalesce(new.agent_slug,'the worker') || ' says: ' || new.message || E'\nGive a fresh team verdict with {{SCHEMA}}.audit(...).');
      end if;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists note_reaudit_wake on {{SCHEMA}}.events;
create trigger note_reaudit_wake after insert on {{SCHEMA}}.events for each row execute function {{SCHEMA}}.trg_note_reaudit_wake();

create or replace function {{SCHEMA}}.trg_run_finished_wake() returns trigger
language plpgsql security definer set search_path = {{SCHEMA}}, public as $$
declare v_agent {{SCHEMA}}.agents%rowtype; v_mgr text; v_since timestamptz; v_reports text;
begin
  if new.ended_at is null or old.ended_at is not null then return new; end if;
  perform {{SCHEMA}}.flush_deferred(new.agent_slug);
  select * into v_agent from {{SCHEMA}}.agents where slug = new.agent_slug;
  if v_agent.role in ('worker','auditor') and v_agent.division_slug is not null and new.trigger in ('manager','api') then
    v_mgr := v_agent.division_slug || '-manager';
    if not exists (select 1 from {{SCHEMA}}.runs r join {{SCHEMA}}.agents a on a.slug = r.agent_slug
                    where a.division_slug = v_agent.division_slug and a.role in ('worker','auditor')
                      and r.status = 'running' and r.id <> new.id and r.started_at > now() - interval '2 hours') then
      select max(started_at) into v_since from {{SCHEMA}}.runs where agent_slug = v_mgr;
      select string_agg(r.agent_slug || ' (run #' || r.id || ', ' || r.status || '): ' || coalesce(r.summary,'no summary'), E'\n' order by r.ended_at)
        into v_reports from {{SCHEMA}}.runs r join {{SCHEMA}}.agents a on a.slug = r.agent_slug
       where a.division_slug = v_agent.division_slug and a.role in ('worker','auditor')
         and r.ended_at is not null and r.ended_at > coalesce(v_since, now() - interval '1 day');
      perform {{SCHEMA}}.wake(v_mgr, 'reports:' || v_agent.division_slug,
        'YOUR WORKERS HAVE REPORTED. Every activated seat in ' || v_agent.division_slug || ' has finished; the reports since your last run:'
        || E'\n' || coalesce(v_reports,'(none)')
        || E'\nBuild the plan from them, write work_items honestly, answer your open mandate with report_mandate, and file the next request_activation round.');
    end if;
  end if;
  return new;
end $$;
drop trigger if exists run_finished_wake on {{SCHEMA}}.runs;
create trigger run_finished_wake after update on {{SCHEMA}}.runs for each row execute function {{SCHEMA}}.trg_run_finished_wake();

create or replace function {{SCHEMA}}.trg_promotion_closes_work() returns trigger
language plpgsql security definer set search_path = {{SCHEMA}}, public as $$
begin
  if new.outcome = 'promoted' then
    update {{SCHEMA}}.work_items set state = 'done', updated_at = now() where change_id = new.change_id and state not in ('done','dropped');
  end if;
  return new;
end $$;
drop trigger if exists promotion_closes_work on {{SCHEMA}}.promotions;
create trigger promotion_closes_work after insert on {{SCHEMA}}.promotions for each row execute function {{SCHEMA}}.trg_promotion_closes_work();

-- ---------------------------------------------------------------------------
-- Prompts, rules, schedules, owner controls

create or replace function {{SCHEMA}}.set_prompt(p_agent text, p_body text, p_by text default null, p_note text default null)
returns bigint language plpgsql security definer set search_path = {{SCHEMA}}, public as $$
declare v_ver int; v_id bigint;
begin
  select coalesce(max(version),0)+1 into v_ver from {{SCHEMA}}.prompts where agent_slug = p_agent;
  update {{SCHEMA}}.prompts set active = false where agent_slug = p_agent and active;
  insert into {{SCHEMA}}.prompts (agent_slug, version, body, note, created_by) values (p_agent, v_ver, p_body, p_note, p_by) returning id into v_id;
  return v_id;
end $$;
revoke execute on function {{SCHEMA}}.set_prompt(text, text, text, text) from public;

create or replace function {{SCHEMA}}.composed_prompt(p_agent text) returns text language sql stable as $$
  select coalesce((select string_agg(b.body, E'\n\n' order by b.sort, b.key)
                     from {{SCHEMA}}.rule_blocks b, {{SCHEMA}}.agents a
                    where a.slug = p_agent and (b.applies_to = '{}' or a.role = any(b.applies_to))), '')
      || E'\n\n'
      || coalesce((select p.body from {{SCHEMA}}.prompts p where p.agent_slug = p_agent and p.active),
                  '(no active prompt for this seat — record yourself, flag it, and stop)');
$$;

create or replace function {{SCHEMA}}.seat_brief(p_agent text)
returns table (agent_slug text, name text, role text, division_slug text, model text, paused boolean, pause_reason text, phase text, prompt text)
language sql stable as $$
  select a.slug, a.name, a.role, a.division_slug, a.model, coalesce(f.paused, false), f.reason,
         (select phase from {{SCHEMA}}.programme limit 1),
         replace(replace(replace(replace({{SCHEMA}}.composed_prompt(a.slug), '{slug}', a.slug), '{name}', a.name), '{division}', coalesce(a.division_slug, 'none')), '{schema}', '{{SCHEMA}}')
    from {{SCHEMA}}.agents a left join {{SCHEMA}}.fleet_state f on f.id
   where a.slug = p_agent;
$$;

create or replace function {{SCHEMA}}.trg_schedule_sync() returns trigger
language plpgsql security definer set search_path = {{SCHEMA}}, cron, public as $$
declare v_name text; v_cmd text;
begin
  -- Job names are prefixed with the ledger schema: two ledgers on one database must never share a name
  -- (cron.schedule silently overwrites an existing job of the same name).
  if tg_op in ('DELETE','UPDATE') then
    v_name := '{{SCHEMA}}:' || old.agent_slug || ':' || old.id;
    if exists (select 1 from cron.job where jobname = v_name) then perform cron.unschedule(v_name); end if;
  end if;
  if tg_op in ('INSERT','UPDATE') and new.enabled then
    v_name := '{{SCHEMA}}:' || new.agent_slug || ':' || new.id;
    v_cmd := format('select {{SCHEMA}}.wake(%L, %L, %L)', new.agent_slug, 'schedule:' || new.id, new.payload);
    perform cron.schedule(v_name, new.cron, v_cmd);
  end if;
  return coalesce(new, old);
end $$;
drop trigger if exists schedule_sync on {{SCHEMA}}.schedules;
create trigger schedule_sync after insert or update or delete on {{SCHEMA}}.schedules for each row execute function {{SCHEMA}}.trg_schedule_sync();

create or replace function {{SCHEMA}}.owner_task(p_text text)
returns bigint language plpgsql security definer set search_path = {{SCHEMA}}, public as $$
begin
  return {{SCHEMA}}.wake('general-manager', 'owner:' || to_char(now(), 'YYYYMMDDHH24MISS'),
    'ONE-OFF FROM THE OWNER. Decide whose it is, delegate it, and report the outcome in your summary: ' || p_text);
end $$;
revoke execute on function {{SCHEMA}}.owner_task(text) from public;

create or replace function {{SCHEMA}}.fleet_pause(p_reason text default null)
returns void language plpgsql security definer set search_path = {{SCHEMA}}, cron, public as $$
begin
  insert into {{SCHEMA}}.fleet_state (id, paused, paused_at, paused_by, reason) values (true, true, now(), 'owner', p_reason)
  on conflict (id) do update set paused = true, paused_at = now(), paused_by = 'owner', reason = p_reason;
  update {{SCHEMA}}.runs set status = 'failed', ended_at = now(), summary = coalesce(summary,'') || ' [closed at fleet pause]' where status = 'running';
  update {{SCHEMA}}.agents set status = 'idle' where status = 'running';
end $$;
revoke execute on function {{SCHEMA}}.fleet_pause(text) from public;

create or replace function {{SCHEMA}}.fleet_resume()
returns int language plpgsql security definer set search_path = {{SCHEMA}}, cron, public as $$
begin
  update {{SCHEMA}}.fleet_state set paused = false, paused_at = null, paused_by = null, reason = 'resumed ' || now()::text;
  return {{SCHEMA}}.flush_deferred(null);
end $$;
revoke execute on function {{SCHEMA}}.fleet_resume() from public;

create or replace function {{SCHEMA}}.check_liveness() returns int
language plpgsql security definer set search_path = {{SCHEMA}}, public as $$
declare v_row record; v_count int := 0;
begin
  for v_row in
    select a.slug, a.name, a.expected_every_hours, a.last_run_at, a.overdue_alerted_at from {{SCHEMA}}.agents a
     where a.routine_id is not null and a.expected_every_hours is not null
       and (a.last_run_at is null or a.last_run_at < now() - make_interval(hours => (a.expected_every_hours * 1.5)::int))
  loop
    update {{SCHEMA}}.agents set overdue_since = coalesce(overdue_since, now()) where slug = v_row.slug;
    if v_row.overdue_alerted_at is null or v_row.overdue_alerted_at < now() - interval '24 hours' then
      insert into {{SCHEMA}}.events (agent_slug, kind, severity, message)
      values (v_row.slug, 'flag', 'warn', v_row.name || ' has not reported in ' ||
              case when v_row.last_run_at is null then 'ever since it was staffed' else round(extract(epoch from (now() - v_row.last_run_at)) / 3600) || 'h' end ||
              ' (expected every ' || v_row.expected_every_hours || 'h).');
      update {{SCHEMA}}.agents set overdue_alerted_at = now() where slug = v_row.slug;
      v_count := v_count + 1;
    end if;
  end loop;
  update {{SCHEMA}}.agents a set overdue_since = null, overdue_alerted_at = null
   where a.overdue_since is not null and a.expected_every_hours is not null and a.last_run_at is not null
     and a.last_run_at >= now() - make_interval(hours => (a.expected_every_hours * 1.5)::int);
  return v_count;
end $$;
revoke execute on function {{SCHEMA}}.check_liveness() from public;

-- ---------------------------------------------------------------------------
-- The wall (read views the console and the agents use)

create or replace view {{SCHEMA}}.wall_programme as
 select phase, note, set_by, set_at,
        (select count(*) from {{SCHEMA}}.mandates m where m.state in ('issued','accepted')) as mandates_open,
        (select count(*) from {{SCHEMA}}.work_items w where w.state not in ('done','dropped')) as work_open,
        (select count(*) from {{SCHEMA}}.work_items w where w.blocks_launch and w.state not in ('done','dropped')) as blockers_open,
        (select count(*) from {{SCHEMA}}.work_items w where w.state = 'done') as work_done,
        (select count(*) from {{SCHEMA}}.work_items w where w.kind = 'recurring' and w.state not in ('done','dropped')) as recurring_pending
   from {{SCHEMA}}.programme p;

create or replace view {{SCHEMA}}.wall_agents as
 select a.slug, a.name, a.role, a.status, a.repo, a.triggers, a.model, a.model_note,
        case when a.model is null then null when a.model like 'claude-opus%' then 'Opus' when a.model like 'claude-sonnet%' then 'Sonnet'
             when a.model like 'claude-fable%' then 'Fable' when a.model like 'claude-haiku%' then 'Haiku' else a.model end as tier,
        a.routine_id is not null as staffed, a.last_run_at, a.sort,
        d.slug as division_slug, d.name as division_name, d.accent, d.sort as division_sort,
        r.id as current_run_id, r.session_url as current_session_url, r.started_at as current_started_at,
        (select count(*) from {{SCHEMA}}.runs x where x.agent_slug = a.slug and x.started_at > now() - interval '7 days') as runs_7d,
        (select count(*) from {{SCHEMA}}.runs x where x.agent_slug = a.slug and x.flagged and x.started_at > now() - interval '7 days') as flags_7d
   from {{SCHEMA}}.agents a
   left join {{SCHEMA}}.divisions d on d.slug = a.division_slug
   left join lateral (select id, session_url, started_at from {{SCHEMA}}.runs where agent_slug = a.slug order by started_at desc limit 1) r on true;

create or replace view {{SCHEMA}}.wall_metrics as
 select (select count(*) from {{SCHEMA}}.agents where routine_id is not null) as agents_staffed,
        (select count(*) from {{SCHEMA}}.agents) as agents_total,
        (select count(*) from {{SCHEMA}}.agents where status = 'running') as agents_running,
        (select count(*) from {{SCHEMA}}.runs where status = 'running') as runs_active,
        (select count(*) from {{SCHEMA}}.runs where started_at > now() - interval '24 hours') as runs_24h,
        (select count(*) from {{SCHEMA}}.runs where started_at > now() - interval '7 days') as runs_7d,
        (select count(*) from {{SCHEMA}}.runs where status = 'succeeded' and started_at > now() - interval '7 days') as ok_7d,
        (select count(*) from {{SCHEMA}}.runs where status = 'failed' and started_at > now() - interval '7 days') as failed_7d,
        (select count(*) from {{SCHEMA}}.runs where flagged and started_at > now() - interval '7 days') as flags_7d,
        (select round(avg(extract(epoch from ended_at - started_at))) from {{SCHEMA}}.runs where ended_at is not null and started_at > now() - interval '7 days') as avg_seconds_7d,
        (select coalesce(sum(files_changed),0) from {{SCHEMA}}.runs where started_at > now() - interval '7 days') as files_changed_7d,
        (select count(*) from {{SCHEMA}}.runs where pr_url is not null and started_at > now() - interval '7 days') as prs_7d;

create or replace view {{SCHEMA}}.wall_runs_by_day as
 select d.day::date as day, count(r.id) as runs,
        count(r.id) filter (where r.status = 'succeeded') as ok,
        count(r.id) filter (where r.status = 'failed') as failed,
        count(r.id) filter (where r.flagged) as flagged
   from generate_series(now()::date - interval '13 days', now()::date::timestamp, interval '1 day') d(day)
   left join {{SCHEMA}}.runs r on r.started_at::date = d.day::date
  group by d.day order by d.day;

create or replace view {{SCHEMA}}.wall_flow as
 select e.id, e.at, e.kind, e.severity, e.message, e.agent_slug, a.name as agent_name, a.role,
        d.slug as division_slug, d.name as division_name, d.accent, e.run_id, r.session_url, r.trigger
   from {{SCHEMA}}.events e
   left join {{SCHEMA}}.agents a on a.slug = e.agent_slug
   left join {{SCHEMA}}.divisions d on d.slug = a.division_slug
   left join {{SCHEMA}}.runs r on r.id = e.run_id
  order by e.at desc limit 200;

create or replace view {{SCHEMA}}.wall_gates as
 select c.id, c.title, c.detail, c.state, c.risk, c.kind, c.payload, c.staging_ref, c.pr_url, c.created_at, c.updated_at,
        c.agent_slug, a.name as agent_name, d.slug as division_slug, d.name as division_name, d.accent,
        (select count(*) from {{SCHEMA}}.audits x where x.change_id = c.id) as looks,
        (select x.verdict from {{SCHEMA}}.audits x where x.change_id = c.id order by x.at desc limit 1) as last_verdict,
        (select x.rationale from {{SCHEMA}}.audits x where x.change_id = c.id order by x.at desc limit 1) as last_rationale,
        extract(epoch from now() - c.updated_at) as waiting_seconds
   from {{SCHEMA}}.changes c
   left join {{SCHEMA}}.agents a on a.slug = c.agent_slug
   left join {{SCHEMA}}.divisions d on d.slug = c.division_slug
  where c.state in ('staged','team_approved','escalated')
  order by case c.risk when 'high' then 0 when 'normal' then 1 else 2 end, c.created_at;

create or replace view {{SCHEMA}}.wall_mandates as
 select m.id, m.phase, m.title, m.detail, m.state, m.issued_by, m.issued_at, m.due_by, m.reported_at, m.report,
        d.slug as division_slug, d.name as division_name, d.accent, extract(epoch from now() - m.issued_at) as age_seconds
   from {{SCHEMA}}.mandates m join {{SCHEMA}}.divisions d on d.slug = m.division_slug
  order by case m.state when 'issued' then 0 when 'accepted' then 1 else 2 end, m.issued_at;

create or replace view {{SCHEMA}}.wall_work as
 select w.id, w.title, w.detail, w.kind, w.blocks_launch, w.priority, w.effort, w.state, w.assigned_to, a.name as assigned_name,
        w.created_by, w.change_id, w.created_at, w.updated_at, d.slug as division_slug, d.name as division_name, d.accent
   from {{SCHEMA}}.work_items w
   left join {{SCHEMA}}.divisions d on d.slug = w.division_slug
   left join {{SCHEMA}}.agents a on a.slug = w.assigned_to
  where w.state not in ('done','dropped')
  order by w.blocks_launch desc, w.priority, w.created_at;

create or replace view {{SCHEMA}}.wall_flags as
 select e.id, e.agent_slug, e.severity, e.message, e.at, e.owner, a.division_slug, d.name as division_name, d.accent,
        extract(epoch from now() - e.at) as age_seconds
   from {{SCHEMA}}.events e
   left join {{SCHEMA}}.agents a on a.slug = e.agent_slug
   left join {{SCHEMA}}.divisions d on d.slug = a.division_slug
  where e.kind = 'flag' and e.resolved_at is null
  order by case e.severity when 'critical' then 0 when 'warn' then 1 else 2 end, e.at;

create or replace view {{SCHEMA}}.wall_activation as
 select a.id, a.agent_slug, a.requested_by, a.task, a.work_item_id, a.state, a.requested_at, a.resolved_at, a.resolution,
        ag.name as agent_name, ag.model as agent_model, d.slug as division_slug, d.name as division_name, d.accent
   from {{SCHEMA}}.activation a
   join {{SCHEMA}}.agents ag on ag.slug = a.agent_slug
   left join {{SCHEMA}}.divisions d on d.slug = ag.division_slug
  order by case a.state when 'requested' then 0 else 1 end, a.requested_at;

create or replace view {{SCHEMA}}.wall_wakes as
 select w.id, w.agent_slug, a.division_slug, w.ref, w.state, w.http_status, w.reason, w.created_at, w.fired_at, left(w.payload, 200) as payload
   from {{SCHEMA}}.wakes w join {{SCHEMA}}.agents a on a.slug = w.agent_slug
  order by w.id desc;

-- ---------------------------------------------------------------------------
-- System jobs and singleton rows

select cron.unschedule(jobid) from cron.job where jobname = '{{SCHEMA}}:flush';
select cron.schedule('{{SCHEMA}}:flush', '*/5 * * * *', 'select {{SCHEMA}}.flush_deferred(null)');
insert into {{SCHEMA}}.programme (id, phase, note) values (true, 'scope', 'Fresh install. Each division states what it owns before anything is built.') on conflict (id) do nothing;
insert into {{SCHEMA}}.fleet_state (id, paused, reason) values (true, true, 'Fresh install. Paused until seats have routines and tokens; resume with fleet_resume().') on conflict (id) do nothing;
