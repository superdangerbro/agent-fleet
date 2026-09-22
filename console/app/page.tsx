import Link from "next/link";
import { listCompanies } from "@/lib/companies";
import { sql } from "@/lib/ledger";

export const dynamic = "force-dynamic";

type Summary = {
  paused: boolean;
  reason: string | null;
  phase: string;
  agents_total: number;
  agents_staffed: number;
  runs_active: number;
  runs_24h: number;
  failed_7d: number;
  flags_open: number;
  gates_open: number;
  unroutable: number;
};

async function summary(slug: string, schema: string): Promise<Summary | { error: string }> {
  try {
    const rows = await sql<Summary>(
      slug,
      `select coalesce(f.paused,false) as paused, f.reason,
              (select phase from ${schema}.programme) as phase,
              m.agents_total, m.agents_staffed, m.runs_active, m.runs_24h, m.failed_7d,
              (select count(*) from ${schema}.wall_flags) as flags_open,
              (select count(*) from ${schema}.wall_gates) as gates_open,
              (select count(*) from ${schema}.wakes where state = 'unroutable' and created_at > now() - interval '2 days') as unroutable
         from ${schema}.wall_metrics m left join ${schema}.fleet_state f on f.id`,
    );
    return rows[0];
  } catch (e) {
    return { error: (e as Error).message };
  }
}

export default async function Home() {
  const companies = listCompanies();
  const summaries = await Promise.all(companies.map((c) => summary(c.slug, c.schema)));
  return (
    <>
      <h1>Companies</h1>
      <div className="grid">
        {companies.map((c, i) => {
          const s = summaries[i];
          return (
            <div className="card" key={c.slug}>
              <div className="row spread">
                <Link href={`/c/${c.slug}`}><b>{c.name}</b></Link>
                {"error" in s ? (
                  <span className="pill bad">unreachable</span>
                ) : s.paused ? (
                  <span className="pill warn">paused</span>
                ) : (
                  <span className="pill ok">live</span>
                )}
              </div>
              <div className="muted small">{c.schema} · {c.projectRef}{c.repo ? ` · ${c.repo}` : ""} · <a href={`/wall.html?c=${c.slug}`}>wall</a></div>
              {"error" in s ? (
                <pre style={{ marginTop: 8 }}>{s.error}</pre>
              ) : (
                <div className="metrics" style={{ marginTop: 10 }}>
                  <div className="metric"><b>{s.phase}</b><span>phase</span></div>
                  <div className="metric"><b>{s.agents_staffed}/{s.agents_total}</b><span>seats staffed</span></div>
                  <div className="metric"><b>{s.runs_active}</b><span>running now</span></div>
                  <div className="metric"><b>{s.runs_24h}</b><span>runs 24h</span></div>
                  <div className="metric"><b>{s.flags_open}</b><span>open flags</span></div>
                  <div className="metric"><b>{s.gates_open}</b><span>at the gate</span></div>
                  <div className="metric"><b>{s.unroutable}</b><span>unroutable wakes</span></div>
                  <div className="metric"><b>{s.failed_7d}</b><span>failed 7d</span></div>
                </div>
              )}
            </div>
          );
        })}
      </div>
      <p className="muted small" style={{ marginTop: 16 }}>
        Companies come from the <code>FLEET_COMPANIES</code> environment variable or a local <code>companies.json</code>
        (see <code>companies.example.json</code>): name, Supabase project ref, ledger schema. One Supabase personal
        access token reaches all of them.
      </p>
    </>
  );
}
