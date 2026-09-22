import Link from "next/link";
import { notFound } from "next/navigation";
import { getCompany } from "@/lib/companies";
import { sql, lit } from "@/lib/ledger";
import * as act from "../../actions";

export const dynamic = "force-dynamic";

const ROLES = ["worker", "auditor", "division_manager", "team_auditor", "general_manager", "database_auditor"];

export default async function AgentPage({ params }: { params: Promise<{ company: string; slug: string }> }) {
  const { company, slug } = await params;
  const c = getCompany(company);
  const s = c.schema;
  const [agents, divisions, prompts, active, schedules, dispatch, brief, runs] = await Promise.all([
    sql(company, `select * from ${s}.agents where slug = ${lit(slug)}`),
    sql(company, `select slug, name from ${s}.divisions order by sort, slug`),
    sql(company, `select id, version, active, note, created_by, created_at, length(body) as len from ${s}.prompts where agent_slug = ${lit(slug)} order by version desc`),
    sql(company, `select body, version from ${s}.prompts where agent_slug = ${lit(slug)} and active`),
    sql(company, `select * from ${s}.schedules where agent_slug = ${lit(slug)} order by id`),
    sql(company, `select routine_id, added_at, left(fire_token, 12) || '…' as token_hint from ${s}.dispatch where agent_slug = ${lit(slug)}`),
    sql(company, `select prompt, paused, phase from ${s}.seat_brief(${lit(slug)})`),
    sql(company, `select id, status, trigger, started_at, ended_at, summary, session_url, flagged from ${s}.runs where agent_slug = ${lit(slug)} order by started_at desc limit 12`),
  ]);
  const a = agents[0];
  if (!a) notFound();
  const hidden = (
    <>
      <input type="hidden" name="company" value={company} />
      <input type="hidden" name="slug" value={slug} />
    </>
  );
  const d = dispatch[0];

  return (
    <>
      <div className="row spread">
        <h1><Link href={`/c/${company}`}>{c.name}</Link> / {String(a.name)} <span className="muted small">{slug}</span></h1>
        <span><span className={`dot ${String(a.status)}`} />{String(a.status)}</span>
      </div>

      <div className="grid">
        <form action={act.upsertAgent} className="card">{hidden}
          <h3>Settings</h3>
          <div className="field"><label>name</label><input type="text" name="name" defaultValue={String(a.name)} required /></div>
          <div className="field"><label>role</label>
            <select name="role" defaultValue={String(a.role)}>{ROLES.map((r) => <option key={r} value={r}>{r}</option>)}</select>
          </div>
          <div className="field"><label>division</label>
            <select name="division_slug" defaultValue={String(a.division_slug ?? "")}>
              <option value="">— company level —</option>
              {divisions.map((x) => <option key={String(x.slug)} value={String(x.slug)}>{String(x.name)}</option>)}
            </select>
          </div>
          <div className="field"><label>model (the routine&apos;s model is set at claude.ai; this is what the ledger records and shows)</label><input type="text" name="model" defaultValue={String(a.model ?? "")} /></div>
          <div className="field"><label>model note</label><input type="text" name="model_note" defaultValue={String(a.model_note ?? "")} /></div>
          <div className="field"><label>repo (blank = the company repo)</label><input type="text" name="repo" defaultValue={String(a.repo ?? "")} /></div>
          <div className="field"><label>expected every N hours (liveness flag when overdue; blank = none)</label><input type="number" name="expected_every_hours" defaultValue={a.expected_every_hours == null ? "" : String(a.expected_every_hours)} /></div>
          <div className="field"><label>routine id (trig_…)</label><input type="text" name="routine_id" defaultValue={String(a.routine_id ?? "")} /></div>
          <div className="field"><label>sort</label><input type="number" name="sort" defaultValue={String(a.sort ?? 100)} /></div>
          <div className="row"><button className="primary">Save settings</button></div>
        </form>

        <div className="card">
          <h3>Dispatch — how the queue reaches this seat</h3>
          {d ? (
            <div>
              <div><span className="pill ok">token on file</span> <span className="muted small">{String(d.routine_id)} · {String(d.token_hint)} · added {String(d.added_at).slice(0, 10)}</span></div>
              <form action={act.clearDispatch} style={{ marginTop: 8 }}>{hidden}<button className="small danger">Remove token</button></form>
            </div>
          ) : (
            <div><span className="pill warn">no token</span> <span className="muted small">wakes for this seat are recorded as unroutable until a token is on file</span></div>
          )}
          <form action={act.setDispatch} style={{ marginTop: 10 }}>{hidden}
            <div className="field"><label>routine id</label><input type="text" name="routine_id" defaultValue={String(a.routine_id ?? d?.routine_id ?? "")} required /></div>
            <div className="field"><label>fire token (from the routine&apos;s Call-via-API trigger; stored in the ledger only)</label><input type="password" name="fire_token" required autoComplete="off" /></div>
            <button>Save token &amp; reroute waiting wakes</button>
          </form>
          <p className="muted small">Create the routine at {c.routinesUrl ? <a href={c.routinesUrl} target="_blank" rel="noreferrer">claude.ai/code/routines</a> : "claude.ai"} with the stub in <code>routines/STUB.md</code>, Call-via-API trigger only, notifications off.</p>

          <h3 style={{ marginTop: 16 }}>Recent runs</h3>
          <table><tbody>
            {runs.map((r) => (
              <tr key={String(r.id)}>
                <td className="small"><span className={`pill ${r.status === "succeeded" ? "ok" : r.status === "running" ? "info" : "bad"}`}>{String(r.status)}</span></td>
                <td className="small">{String(r.trigger)}</td>
                <td className="small muted">{String(r.started_at).slice(0, 16).replace("T", " ")}</td>
                <td className="small">{r.session_url ? <a href={String(r.session_url)} target="_blank" rel="noreferrer">{String(r.summary ?? "(no summary)").slice(0, 140)}</a> : String(r.summary ?? "").slice(0, 140)}</td>
              </tr>
            ))}
            {runs.length === 0 && <tr><td className="muted small">never run</td></tr>}
          </tbody></table>

          <details style={{ marginTop: 14 }}>
            <summary>Danger zone</summary>
            <form action={act.deleteAgent} style={{ marginTop: 8 }}>{hidden}
              <button className="danger">Delete this seat (runs, prompts, schedules and token go with it)</button>
            </form>
          </details>
        </div>
      </div>

      <h2>Prompt</h2>
      <div className="grid">
        <form action={act.setPrompt} className="card">{hidden}
          <h3>Active prompt — v{String(active[0]?.version ?? "none")}</h3>
          <div className="field"><textarea name="body" className="mono tall" defaultValue={String(active[0]?.body ?? "")} required /></div>
          <div className="field"><label>note for this version</label><input type="text" name="note" placeholder="what changed and why" /></div>
          <button className="primary">Save as new version</button>
          <span className="muted small"> · the old version stays in history; nothing is overwritten</span>
        </form>
        <div className="card">
          <h3>Versions</h3>
          <table>
            <thead><tr><th>v</th><th>note</th><th>by</th><th>when</th><th>size</th><th></th></tr></thead>
            <tbody>
              {prompts.map((p) => (
                <tr key={String(p.id)}>
                  <td>{p.active ? <b>v{String(p.version)}</b> : `v${String(p.version)}`}</td>
                  <td className="small">{String(p.note ?? "")}</td>
                  <td className="small muted">{String(p.created_by ?? "")}</td>
                  <td className="small muted">{String(p.created_at).slice(0, 16).replace("T", " ")}</td>
                  <td className="small muted">{String(p.len)}</td>
                  <td>{p.active ? <span className="pill ok">active</span> : (
                    <form action={act.restorePrompt}>{hidden}<input type="hidden" name="id" value={String(p.id)} /><button className="small">restore</button></form>
                  )}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <details style={{ marginTop: 12 }}>
            <summary>What the seat actually receives — <code>seat_brief(&apos;{slug}&apos;)</code> (rule blocks + active prompt, substituted)</summary>
            <div className="small muted" style={{ margin: "6px 0" }}>paused: {String(brief[0]?.paused)} · phase: {String(brief[0]?.phase)}</div>
            <pre>{String(brief[0]?.prompt ?? "")}</pre>
          </details>
        </div>
      </div>

      <h2>Schedules</h2>
      <div className="grid">
        <div className="card wide">
          {schedules.length === 0 && <div className="muted small" style={{ marginBottom: 8 }}>No schedules: this seat runs only when the queue wakes it. That is the default for workers, managers and team auditors.</div>}
          {schedules.map((sc) => (
            <form action={act.updateSchedule} key={String(sc.id)} className="row" style={{ alignItems: "flex-start", borderBottom: "1px solid var(--line)", padding: "8px 0" }}>{hidden}
              <input type="hidden" name="id" value={String(sc.id)} />
              <div className="field" style={{ width: 150 }}><label>cron (UTC)</label><input type="text" name="cron" defaultValue={String(sc.cron)} required /></div>
              <div className="field" style={{ flex: 1, minWidth: 260 }}><label>payload (the wake text)</label><textarea name="payload" defaultValue={String(sc.payload)} style={{ minHeight: "3.5rem" }} /></div>
              <div className="field" style={{ width: 180 }}><label>note</label><input type="text" name="note" defaultValue={String(sc.note ?? "")} /></div>
              <div className="field" style={{ width: 90 }}><label>enabled</label><input type="checkbox" name="enabled" defaultChecked={Boolean(sc.enabled)} /></div>
              <div className="field" style={{ width: 200 }}><label>pg_cron job</label><code className="small">{String(sc.jobname)}</code></div>
              <div className="field"><label>&nbsp;</label><div className="row"><button className="small">Save</button><button className="small danger" formAction={act.deleteSchedule}>Delete</button></div></div>
            </form>
          ))}
          <form action={act.addSchedule} className="row" style={{ alignItems: "flex-start", paddingTop: 8 }}>{hidden}
            <div className="field" style={{ width: 150 }}><label>new: cron (UTC)</label><input type="text" name="cron" placeholder="17 */3 * * *" required /></div>
            <div className="field" style={{ flex: 1, minWidth: 260 }}><label>payload</label><textarea name="payload" placeholder="SCHEDULED RUN. Do your standing job as your prompt describes; stop when it is done." style={{ minHeight: "3.5rem" }} /></div>
            <div className="field" style={{ width: 180 }}><label>note</label><input type="text" name="note" /></div>
            <div className="field"><label>&nbsp;</label><button className="primary small">Add schedule</button></div>
          </form>
          <p className="muted small">Each row is mirrored into pg_cron as <code>{s}:{slug}:&lt;id&gt;</code>. The job calls <code>wake()</code>, so a scheduled run honours the pause gate and the fire-time lock like any queue wake.</p>
        </div>
      </div>
    </>
  );
}
