import { NextResponse } from "next/server";
import { getCompany } from "@/lib/companies";
import { sql } from "@/lib/ledger";

export const dynamic = "force-dynamic";

// One round trip returns the whole fleet for the wall: every screen is drawn
// from a single consistent instant. Same query the original wall artifact ran
// through the Supabase connector, now served by the console.
export async function GET(_req: Request, { params }: { params: Promise<{ company: string }> }) {
  const { company } = await params;
  let c;
  try {
    c = getCompany(company);
  } catch (e) {
    return NextResponse.json({ error: (e as Error).message }, { status: 404 });
  }
  const s = c.schema;
  try {
    const rows = await sql<{ snapshot: unknown }>(
      company,
      `select json_build_object(
         'company',  ${JSON.stringify(c.name).replace(/'/g, "''").replace(/^"|"$/g, "'")},
         'paused',   (select coalesce(f.paused, false) from ${s}.fleet_state f),
         'phase',    (select phase from ${s}.programme),
         'agents',   (select coalesce(json_agg(a order by a.division_sort nulls first, a.sort, a.name),'[]'::json) from ${s}.wall_agents a),
         'metrics',  (select row_to_json(m) from ${s}.wall_metrics m),
         'byday',    (select coalesce(json_agg(d order by d.day),'[]'::json) from ${s}.wall_runs_by_day d),
         'flow',     (select coalesce(json_agg(f order by f.at desc),'[]'::json) from ${s}.wall_flow f),
         'gates',    (select coalesce(json_agg(g),'[]'::json) from ${s}.wall_gates g),
         'flags',    (select coalesce(json_agg(x),'[]'::json) from ${s}.wall_flags x),
         'wakes',    (select coalesce(json_agg(w),'[]'::json) from (select * from ${s}.wall_wakes limit 30) w),
         'divisions',(select coalesce(json_agg(x order by x.sort),'[]'::json) from ${s}.divisions x),
         'at', now()
       ) as snapshot`,
    );
    return NextResponse.json(rows[0]?.snapshot ?? null, { headers: { "cache-control": "no-store" } });
  } catch (e) {
    return NextResponse.json({ error: (e as Error).message }, { status: 502 });
  }
}
