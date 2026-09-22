import Link from "next/link";
import { getCompany } from "@/lib/companies";
import { sql, type Row } from "@/lib/ledger";
import * as act from "./actions";

export const dynamic = "force-dynamic";

const ago = (v: unknown) => {
  if (!v) return "—";
  const ms = Date.now() - new Date(String(v)).getTime();
  const m = Math.round(ms / 60000);
  if (m < 1) return "just now";
  if (m < 60) return `${m}m ago`;
  const h = Math.round(m / 60);
  if (h < 48) return `${h}h ago`;
  return `${Math.round(h / 24)}d ago`;
};

export default async function Board({ params }: { params: Promise<{ company: string }> }) {
  const { company } = await params;
  const c = getCompany(company);
  const s = c.schema;
  const [state, prog, agents, divisions, flags, gates, wakes, flow, activation, mandates] = await Promise.all([
    sql(company, `select * from ${s}.fleet_state`),
    sql(company, `select * from ${s}.wall_programme`),
    sql(company, `select * from ${s}.wall_agents order by division_sort nulls first, sort, slug`),
    sql(company, `select * from ${s}.divisions order by sort, slug`),
    sql(company, `select * from ${s}.wall_flags limit 40`),
    sql(company, `select * from ${s}.wall_gates limit 40`),
    sql(company, `select * from ${s}.wall_wakes limit 30`),
    sql(company, `select * from ${s}.wall_flow limit 40`),
    sql(company, `select * from ${s}.wall_activation where state = 'requested' limit 40`),
    sql(company, `select * from ${s}.wall_mandates where state in ('issued','accepted') limit 40`),
  ]);
  const fs = state[0] ?? { paused: false };
  const p = prog[0] ?? {};
  const byDivision = new Map<string, Row[]>();
  for (const a of agents) {
    const k = String(a.division_slug ?? "");
    byDivision.set(k, [...(byDivision.get(k) ?? []), a]);
  }
  const hidden = <input type="hidden" name="company" value={company} />;

  return (
    <>
      <div className="row spread">
        <h1>{c.name}</h1>
        <nav className="row">
          <a href={`/wall.html?c=${company}`}><b>Wall</b> (organism · metrics · flow)</a>
          <Link href={`/c/${company}/rules`}>Rule blocks</Link>
          {c.routinesUrl && <a href={c.routinesUrl} target="_blank" rel="noreferrer">Routines ↗</a>}
          {c.repo && <a href={`https://github.com/${c.repo}`} target="_blank" rel="noreferrer">{c.repo} ↗</a>}
        </nav>
      </div>

      {fs.paused ? (
        <div className="banner paused row spread">
          <div>
            <b>Fleet is paused.</b> <span className="muted">{String(fs.reason ?? "")}</span>
            <div className="small muted">Every wake since the pause is deferred and goes out, coalesced per seat, on resume. Flip the routines&apos; Active switches on at claude.ai after resuming.</div>
          </div>
          <form action={act.resumeFleet}>{hidden}<button className="primary">Resume fleet</button></form>
        </div>
      ) : (
        <div className="banner live row spread">
          <div><b>Fleet is live.</b> <span className="muted small">Pausing closes running rows and defers every new wake.</span></div>
          <form action={act.pauseFleet} className="row">{hidden}
            <input type="text" name="reason" placeholder="why (optional)" style={{ width: 260 }} />
            <button className="danger">Pause fleet</button>
          </form>
        </div>
      )}

      <div className="grid">
        <div className="card">
          <h3>Ask the General Manager</h3>
          <form action={act.ownerTask}>{hidden}
            <div className="field"><textarea name="text" required placeholder="One-off task. The GM decides whose it is, delegates it, and reports back in its run summary." /></div>
            <button className="primary">Send to the GM</button>
            <span className="muted small"> · goes out as a queue wake (deferred while paused)</span>
          </form>
        </div>
        <div className="card">
          <h3>Programme</h3>
          <div className="metrics">
            <div className="metric"><b>{String(p.phase ?? "—")}</b><span>phase</span></div>
            <div className="metric"><b>{String(p.mandates_open ?? 0)}</b><span>mandates open</span></div>
            <div className="metric"><b>{String(p.work_open ?? 0)}</b><span>work open</span></div>
            <div className="metric"><b>{String(p.blockers_open ?? 0)}</b><span>blockers</span></div>
          </div>
          <form action={act.setPhase} className="row" style={{ marginTop: 10 }}>{hidden}
            <select name="phase" defaultValue={String(p.phase ?? "scope")} style={{ width: 130 }}>
              {["scope", "build", "test", "operate"].map((x) => <option key={x} value={x}>{x}</option>)}
            </select>
            <input type="text" name="note" placeholder="note" style={{ flex: 1, minWidth: 160 }} defaultValue={String(p.note ?? "")} />
            <button>Set phase</button>
          </form>
          <div className="small muted" style={{ marginTop: 6 }}>{String(p.note ?? "")}</div>
        </div>
      </div>

      <h2>Seats</h2>
      {[...byDivision.entries()].map(([dslug, list]) => {
        const d = divisions.find((x) => x.slug === dslug);
        return (
          <div className="card" key={dslug || "_company"} style={{ marginBottom: 10 }}>
            <div className="row spread">
              <b>{d ? <><span className="swatch" style={{ background: String(d.accent) }} />{String(d.name)}</> : "Company"}</b>
              {d && <span className="muted small">{dslug}{d.repo ? ` · ${String(d.repo)}` : ""}</span>}
            </div>
            <table>
              <thead><tr><th>Seat</th><th>Role</th><th>Model</th><th>Status</th><th>Last run</th><th>7d runs / flags</th><th>Routine</th></tr></thead>
              <tbody>
                {list.map((a) => (
                  <tr key={String(a.slug)}>
                    <td><Link href={`/c/${company}/agents/${a.slug}`}><b>{String(a.name)}</b></Link><div className="muted small">{String(a.slug)}</div></td>
                    <td className="small">{String(a.role).replace("_", " ")}</td>
                    <td className="small">{String(a.tier ?? a.model ?? "—")}</td>
                    <td><span className={`dot ${String(a.status)}`} />{String(a.status)}</td>
                    <td className="small">{a.current_session_url ? <a href={String(a.current_session_url)} target="_blank" rel="noreferrer">{ago(a.last_run_at)}</a> : ago(a.last_run_at)}</td>
                    <td className="small">{String(a.runs_7d)} / {String(a.flags_7d)}</td>
                    <td className="small">{a.staffed ? <span className="pill ok">staffed</span> : <span className="pill warn">no routine</span>}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        );
      })}

      <details className="card" style={{ marginBottom: 10 }}>
        <summary>Add a seat or a division</summary>
        <div className="grid" style={{ marginTop: 10 }}>
          <form action={act.upsertAgent} className="card">{hidden}<input type="hidden" name="created" value="1" />
            <h3>New seat</h3>
            <div className="field"><label>slug (e.g. sales-outreach; managers must be &lt;division&gt;-manager, team auditors &lt;division&gt;-auditor)</label><input type="text" name="slug" required /></div>
            <div className="field"><label>name</label><input type="text" name="name" required /></div>
            <div className="field"><label>role</label>
              <select name="role" defaultValue="worker">
                {["worker", "auditor", "division_manager", "team_auditor", "general_manager", "database_auditor"].map((r) => <option key={r} value={r}>{r}</option>)}
              </select>
            </div>
            <div className="field"><label>division</label>
              <select name="division_slug" defaultValue="">
                <option value="">— company level —</option>
                {divisions.map((d) => <option key={String(d.slug)} value={String(d.slug)}>{String(d.name)}</option>)}
              </select>
            </div>
            <div className="field"><label>model</label><input type="text" name="model" placeholder="claude-sonnet-5" /></div>
            <div className="field"><label>expected every N hours (liveness watch; blank = none)</label><input type="number" name="expected_every_hours" /></div>
            <div className="field"><label>sort</label><input type="number" name="sort" defaultValue={100} /></div>
            <button className="primary">Create seat</button>
          </form>
          <form action={act.upsertDivision} className="card">{hidden}
            <h3>New or edited division</h3>
            <div className="field"><label>slug</label><input type="text" name="slug" required /></div>
            <div className="field"><label>name</label><input type="text" name="name" required /></div>
            <div className="field"><label>accent colour</label><input type="text" name="accent" defaultValue="#7dd3fc" /></div>
            <div className="field"><label>repo (optional, owner/name)</label><input type="text" name="repo" /></div>
            <div className="field"><label>sort</label><input type="number" name="sort" defaultValue={100} /></div>
            <button className="primary">Save division</button>
          </form>
        </div>
      </details>

      <div className="grid">
        <div className="card">
          <h3>Open flags <span className="muted">({flags.length})</span></h3>
          {flags.length === 0 && <div className="muted small">none</div>}
          <table><tbody>
            {flags.map((f) => (
              <tr key={String(f.id)}>
                <td><span className={`pill ${f.severity === "critical" ? "bad" : "warn"}`}>{String(f.severity)}</span></td>
                <td className="small">{String(f.message)}<div className="muted">{String(f.agent_slug)} · {ago(f.at)}</div></td>
                <td><form action={act.resolveFlag}>{hidden}<input type="hidden" name="id" value={String(f.id)} /><button className="small">close</button></form></td>
              </tr>
            ))}
          </tbody></table>
        </div>
        <div className="card">
          <h3>At the gate <span className="muted">({gates.length})</span></h3>
          {gates.length === 0 && <div className="muted small">nothing staged</div>}
          <table><tbody>
            {gates.map((g) => (
              <tr key={String(g.id)}>
                <td><span className={`pill ${g.state === "team_approved" ? "info" : g.state === "escalated" ? "bad" : ""}`}>{String(g.state)}</span></td>
                <td className="small">#{String(g.id)} {g.pr_url ? <a href={String(g.pr_url)} target="_blank" rel="noreferrer">{String(g.title)}</a> : String(g.title)}
                  <div className="muted">{String(g.agent_slug)} · {String(g.division_name ?? "")} · {g.last_verdict ? `last verdict ${String(g.last_verdict)}` : "no verdict yet"} · {ago(g.updated_at)}</div></td>
              </tr>
            ))}
          </tbody></table>
        </div>
        <div className="card">
          <h3>Open mandates <span className="muted">({mandates.length})</span></h3>
          {mandates.length === 0 && <div className="muted small">none</div>}
          <table><tbody>
            {mandates.map((m) => (
              <tr key={String(m.id)}><td className="small">#{String(m.id)} <b>{String(m.title)}</b><div className="muted">{String(m.division_name)} · {String(m.state)} · issued {ago(m.issued_at)}</div></td></tr>
            ))}
          </tbody></table>
        </div>
        <div className="card">
          <h3>Activations waiting <span className="muted">({activation.length})</span></h3>
          {activation.length === 0 && <div className="muted small">none — every request has been routed</div>}
          <table><tbody>
            {activation.map((a) => (
              <tr key={String(a.id)}><td className="small">#{String(a.id)} → <b>{String(a.agent_slug)}</b> from {String(a.requested_by)}<div className="muted">{String(a.task).slice(0, 160)}</div></td></tr>
            ))}
          </tbody></table>
        </div>
      </div>

      <div className="card" style={{ marginTop: 14 }}>
        <div className="row spread">
          <h3>Queue — latest wakes</h3>
          <form action={act.flushDeferred}>{hidden}<button className="small">Flush deferred + reroute unroutable now</button></form>
        </div>
        <table>
          <thead><tr><th>#</th><th>seat</th><th>ref</th><th>state</th><th>http</th><th>when</th><th>payload / reason</th></tr></thead>
          <tbody>
            {wakes.map((w) => (
              <tr key={String(w.id)}>
                <td className="small">{String(w.id)}</td>
                <td className="small">{String(w.agent_slug)}</td>
                <td className="small">{String(w.ref)}</td>
                <td><span className={`pill ${w.state === "fired" ? "ok" : w.state === "deferred" ? "info" : "warn"}`}>{String(w.state)}</span></td>
                <td className="small">{String(w.http_status ?? "")}</td>
                <td className="small">{ago(w.fired_at ?? w.created_at)}</td>
                <td className="small muted">{String(w.reason ?? "")} {w.reason ? "· " : ""}{String(w.payload ?? "").slice(0, 120)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="card" style={{ marginTop: 14 }}>
        <h3>Flow — latest events</h3>
        <table><tbody>
          {flow.map((e) => (
            <tr key={String(e.id)}>
              <td className="small muted" style={{ whiteSpace: "nowrap" }}>{ago(e.at)}</td>
              <td className="small"><span className={`pill ${e.severity === "critical" ? "bad" : e.severity === "warn" ? "warn" : ""}`}>{String(e.kind)}</span></td>
              <td className="small">{e.session_url ? <a href={String(e.session_url)} target="_blank" rel="noreferrer">{String(e.agent_slug ?? "")}</a> : String(e.agent_slug ?? "")}</td>
              <td className="small">{String(e.message)}</td>
            </tr>
          ))}
        </tbody></table>
      </div>
    </>
  );
}
