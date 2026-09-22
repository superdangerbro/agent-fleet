"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { getCompany } from "@/lib/companies";
import { sql, lit, str, num, need, slug, csv } from "@/lib/ledger";

// Every action takes the company slug from a hidden field, runs SQL against
// that company's ledger schema, and revalidates the page it came from.

function ctx(fd: FormData) {
  const company = need(fd, "company");
  const c = getCompany(company);
  return { company, s: c.schema };
}
function done(company: string, path = "") {
  revalidatePath(`/c/${company}${path}`);
  revalidatePath("/");
}

// --- fleet ------------------------------------------------------------------

export async function pauseFleet(fd: FormData) {
  const { company, s } = ctx(fd);
  await sql(company, `select ${s}.fleet_pause(${lit(str(fd, "reason") ?? "paused from the console")})`);
  done(company);
}

export async function resumeFleet(fd: FormData) {
  const { company, s } = ctx(fd);
  await sql(company, `select ${s}.fleet_resume()`);
  done(company);
}

export async function ownerTask(fd: FormData) {
  const { company, s } = ctx(fd);
  await sql(company, `select ${s}.owner_task(${lit(need(fd, "text"))})`);
  done(company);
}

export async function setPhase(fd: FormData) {
  const { company, s } = ctx(fd);
  const phase = need(fd, "phase");
  if (!["scope", "build", "test", "operate"].includes(phase)) throw new Error("bad phase");
  await sql(
    company,
    `update ${s}.programme set phase = ${lit(phase)}, note = ${lit(str(fd, "note"))}, set_by = null, set_at = now() where id;
     insert into ${s}.events (kind, severity, message) values ('note', 'info', ${lit(`owner set the programme phase to ${phase}`)})`,
  );
  done(company);
}

export async function flushDeferred(fd: FormData) {
  const { company, s } = ctx(fd);
  await sql(company, `select ${s}.flush_deferred(null); select ${s}.reroute_unroutable(null)`);
  done(company);
}

export async function resolveFlag(fd: FormData) {
  const { company, s } = ctx(fd);
  const id = num(fd, "id");
  await sql(
    company,
    `update ${s}.events set resolved_at = now(), resolved_by = 'owner', resolution = ${lit(str(fd, "resolution") ?? "closed from the console")}
      where id = ${lit(id)} and kind = 'flag'`,
  );
  done(company);
}

// --- divisions --------------------------------------------------------------

export async function upsertDivision(fd: FormData) {
  const { company, s } = ctx(fd);
  await sql(
    company,
    `insert into ${s}.divisions (slug, name, accent, repo, sort)
     values (${lit(slug(fd, "slug"))}, ${lit(need(fd, "name"))}, ${lit(str(fd, "accent") ?? "#7dd3fc")}, ${lit(str(fd, "repo"))}, ${lit(num(fd, "sort") ?? 100)})
     on conflict (slug) do update set name = excluded.name, accent = excluded.accent, repo = excluded.repo, sort = excluded.sort`,
  );
  done(company);
}

export async function deleteDivision(fd: FormData) {
  const { company, s } = ctx(fd);
  await sql(company, `delete from ${s}.divisions where slug = ${lit(slug(fd, "slug"))}`);
  done(company);
}

// --- agents -----------------------------------------------------------------

const ROLES = ["general_manager", "division_manager", "worker", "auditor", "team_auditor", "database_auditor"];

export async function upsertAgent(fd: FormData) {
  const { company, s } = ctx(fd);
  const agent = slug(fd, "slug");
  const role = need(fd, "role");
  if (!ROLES.includes(role)) throw new Error("bad role");
  await sql(
    company,
    `insert into ${s}.agents (slug, division_slug, name, role, model, model_note, repo, expected_every_hours, sort, routine_id)
     values (${lit(agent)}, ${lit(str(fd, "division_slug"))}, ${lit(need(fd, "name"))}, ${lit(role)}, ${lit(str(fd, "model"))},
             ${lit(str(fd, "model_note"))}, ${lit(str(fd, "repo"))}, ${lit(num(fd, "expected_every_hours"))}, ${lit(num(fd, "sort") ?? 100)}, ${lit(str(fd, "routine_id"))})
     on conflict (slug) do update set division_slug = excluded.division_slug, name = excluded.name, role = excluded.role,
       model = excluded.model, model_note = excluded.model_note, repo = excluded.repo, expected_every_hours = excluded.expected_every_hours,
       sort = excluded.sort, routine_id = excluded.routine_id,
       status = case when ${s}.agents.status = 'vacant' and excluded.routine_id is not null then 'idle' else ${s}.agents.status end`,
  );
  done(company, `/agents/${agent}`);
  if (str(fd, "created")) redirect(`/c/${company}/agents/${agent}`);
}

export async function deleteAgent(fd: FormData) {
  const { company, s } = ctx(fd);
  await sql(company, `delete from ${s}.agents where slug = ${lit(slug(fd, "slug"))}`);
  done(company);
  redirect(`/c/${company}`);
}

export async function setDispatch(fd: FormData) {
  const { company, s } = ctx(fd);
  const agent = slug(fd, "slug");
  const routine = need(fd, "routine_id");
  const token = need(fd, "fire_token");
  if (!/^trig_[A-Za-z0-9]+$/.test(routine)) throw new Error("routine id should look like trig_…");
  await sql(
    company,
    `update ${s}.agents set routine_id = ${lit(routine)}, status = case when status = 'vacant' then 'idle' else status end where slug = ${lit(agent)};
     insert into ${s}.dispatch (agent_slug, routine_id, fire_token, why) values (${lit(agent)}, ${lit(routine)}, ${lit(token)}, 'queue wakes')
     on conflict (agent_slug) do update set routine_id = excluded.routine_id, fire_token = excluded.fire_token, added_at = now();
     select ${s}.reroute_unroutable(${lit(agent)})`,
  );
  done(company, `/agents/${agent}`);
}

export async function clearDispatch(fd: FormData) {
  const { company, s } = ctx(fd);
  const agent = slug(fd, "slug");
  await sql(company, `delete from ${s}.dispatch where agent_slug = ${lit(agent)}`);
  done(company, `/agents/${agent}`);
}

// --- prompts ----------------------------------------------------------------

export async function setPrompt(fd: FormData) {
  const { company, s } = ctx(fd);
  const agent = slug(fd, "slug");
  await sql(company, `select ${s}.set_prompt(${lit(agent)}, ${lit(need(fd, "body"))}, 'console', ${lit(str(fd, "note"))})`);
  done(company, `/agents/${agent}`);
}

export async function restorePrompt(fd: FormData) {
  const { company, s } = ctx(fd);
  const agent = slug(fd, "slug");
  const id = num(fd, "id");
  await sql(
    company,
    `select ${s}.set_prompt(${lit(agent)}, p.body, 'console', 'restored v' || p.version)
       from ${s}.prompts p where p.id = ${lit(id)} and p.agent_slug = ${lit(agent)}`,
  );
  done(company, `/agents/${agent}`);
}

// --- schedules --------------------------------------------------------------

export async function addSchedule(fd: FormData) {
  const { company, s } = ctx(fd);
  const agent = slug(fd, "slug");
  const cron = need(fd, "cron");
  if (!/^(\S+\s+){4}\S+$/.test(cron)) throw new Error("cron must have five fields");
  await sql(
    company,
    `insert into ${s}.schedules (agent_slug, cron, payload, note, enabled)
     values (${lit(agent)}, ${lit(cron)}, ${lit(str(fd, "payload") ?? "SCHEDULED RUN. Do your standing job as your prompt describes; stop when it is done.")}, ${lit(str(fd, "note"))}, ${lit(fd.get("enabled") !== "off")})`,
  );
  done(company, `/agents/${agent}`);
}

export async function updateSchedule(fd: FormData) {
  const { company, s } = ctx(fd);
  const agent = slug(fd, "slug");
  const id = num(fd, "id");
  const cron = need(fd, "cron");
  if (!/^(\S+\s+){4}\S+$/.test(cron)) throw new Error("cron must have five fields");
  await sql(
    company,
    `update ${s}.schedules set cron = ${lit(cron)}, payload = ${lit(need(fd, "payload"))}, note = ${lit(str(fd, "note"))},
        enabled = ${lit(fd.get("enabled") === "on")} where id = ${lit(id)} and agent_slug = ${lit(agent)}`,
  );
  done(company, `/agents/${agent}`);
}

export async function deleteSchedule(fd: FormData) {
  const { company, s } = ctx(fd);
  const agent = slug(fd, "slug");
  await sql(company, `delete from ${s}.schedules where id = ${lit(num(fd, "id"))} and agent_slug = ${lit(agent)}`);
  done(company, `/agents/${agent}`);
}

// --- rule blocks ------------------------------------------------------------

export async function upsertRule(fd: FormData) {
  const { company, s } = ctx(fd);
  const key = need(fd, "key");
  if (!/^[a-z0-9][a-z0-9-]*$/.test(key)) throw new Error("key must be a slug like 40-worker-limits");
  const roles = csv(fd, "applies_to");
  for (const r of roles) if (!ROLES.includes(r)) throw new Error(`unknown role in applies_to: ${r}`);
  await sql(
    company,
    `insert into ${s}.rule_blocks (key, applies_to, sort, body, note, updated_by)
     values (${lit(key)}, ${lit(roles)}, ${lit(num(fd, "sort") ?? 100)}, ${lit(need(fd, "body"))}, ${lit(str(fd, "note"))}, 'console')
     on conflict (key) do update set applies_to = excluded.applies_to, sort = excluded.sort, body = excluded.body, note = excluded.note,
       updated_at = now(), updated_by = 'console'`,
  );
  done(company, "/rules");
}

export async function deleteRule(fd: FormData) {
  const { company, s } = ctx(fd);
  await sql(company, `delete from ${s}.rule_blocks where key = ${lit(need(fd, "key"))}`);
  done(company, "/rules");
}
