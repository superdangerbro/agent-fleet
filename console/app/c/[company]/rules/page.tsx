import Link from "next/link";
import { getCompany } from "@/lib/companies";
import { sql } from "@/lib/ledger";
import * as act from "../actions";

export const dynamic = "force-dynamic";

export default async function RulesPage({ params }: { params: Promise<{ company: string }> }) {
  const { company } = await params;
  const c = getCompany(company);
  const rules = await sql(company, `select * from ${c.schema}.rule_blocks order by sort, key`);
  const hidden = <input type="hidden" name="company" value={company} />;
  return (
    <>
      <h1><Link href={`/c/${company}`}>{c.name}</Link> / Rule blocks</h1>
      <p className="muted small">
        Composed in <code>sort</code> order at the top of every seat&apos;s prompt. <code>applies_to</code> empty = every seat;
        otherwise a comma-separated list of roles (worker, auditor, division_manager, team_auditor, general_manager, database_auditor).
        Placeholders <code>{"{slug} {name} {division} {schema}"}</code> are substituted per seat. Edits apply on each seat&apos;s next run.
      </p>
      {rules.map((r) => (
        <form action={act.upsertRule} key={String(r.key)} className="card" style={{ marginBottom: 10 }}>{hidden}
          <input type="hidden" name="key" value={String(r.key)} />
          <div className="row spread">
            <b>{String(r.key)}</b>
            <span className="muted small">updated {String(r.updated_at).slice(0, 16).replace("T", " ")}{r.updated_by ? ` by ${String(r.updated_by)}` : ""}</span>
          </div>
          <div className="row" style={{ alignItems: "flex-end" }}>
            <div className="field" style={{ flex: 1, minWidth: 260 }}><label>applies to (roles, comma-separated; blank = everyone)</label><input type="text" name="applies_to" defaultValue={((r.applies_to as string[]) ?? []).join(", ")} /></div>
            <div className="field" style={{ width: 90 }}><label>sort</label><input type="number" name="sort" defaultValue={String(r.sort)} /></div>
            <div className="field" style={{ flex: 1, minWidth: 200 }}><label>note</label><input type="text" name="note" defaultValue={String(r.note ?? "")} /></div>
          </div>
          <div className="field"><textarea name="body" className="mono" defaultValue={String(r.body)} required /></div>
          <div className="row"><button className="primary small">Save</button><button className="small danger" formAction={act.deleteRule}>Delete</button></div>
        </form>
      ))}
      <form action={act.upsertRule} className="card">{hidden}
        <h3>New rule block</h3>
        <div className="row" style={{ alignItems: "flex-end" }}>
          <div className="field" style={{ width: 220 }}><label>key (e.g. 50-house-style)</label><input type="text" name="key" required /></div>
          <div className="field" style={{ flex: 1, minWidth: 260 }}><label>applies to</label><input type="text" name="applies_to" placeholder="blank = everyone" /></div>
          <div className="field" style={{ width: 90 }}><label>sort</label><input type="number" name="sort" defaultValue={100} /></div>
          <div className="field" style={{ flex: 1, minWidth: 200 }}><label>note</label><input type="text" name="note" /></div>
        </div>
        <div className="field"><textarea name="body" className="mono" required /></div>
        <button className="primary small">Add block</button>
      </form>
    </>
  );
}
