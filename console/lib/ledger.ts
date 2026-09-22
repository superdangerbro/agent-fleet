import { getCompany } from "./companies";

// One credential for every company: a Supabase personal access token, which the
// Management API accepts for any project the account can reach.
//   POST https://api.supabase.com/v1/projects/<ref>/database/query  { query }
// Rows come back as a JSON array. Everything the console does is SQL against
// the company's ledger schema, so this file is the whole data layer.

export type Row = Record<string, unknown>;

export async function sql<T extends Row = Row>(companySlug: string, query: string): Promise<T[]> {
  const c = getCompany(companySlug);
  const token = process.env.SUPABASE_ACCESS_TOKEN;
  if (!token) throw new Error("SUPABASE_ACCESS_TOKEN is not set (a Supabase personal access token)");
  const res = await fetch(`https://api.supabase.com/v1/projects/${c.projectRef}/database/query`, {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({ query }),
    cache: "no-store",
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`ledger query failed for ${c.name} (${res.status}): ${text.slice(0, 600)}`);
  }
  const body = await res.json();
  return (Array.isArray(body) ? body : []) as T[];
}

/** SQL literal for a JS value. Strings are single-quoted with '' escaping; null/undefined → NULL. */
export function lit(v: unknown): string {
  if (v === null || v === undefined) return "null";
  if (typeof v === "number") return Number.isFinite(v) ? String(v) : "null";
  if (typeof v === "boolean") return v ? "true" : "false";
  if (Array.isArray(v)) return v.length ? `array[${v.map(lit).join(",")}]::text[]` : "'{}'::text[]";
  return `'${String(v).replace(/'/g, "''")}'`;
}

export function ident(s: string): string {
  if (!/^[a-z_][a-z0-9_]*$/.test(s)) throw new Error(`bad identifier: ${s}`);
  return s;
}

/** Form helpers: empty strings become null; numbers parse or null. */
export const str = (fd: FormData, k: string): string | null => {
  const v = fd.get(k);
  if (typeof v !== "string") return null;
  const t = v.trim();
  return t === "" ? null : t;
};
export const num = (fd: FormData, k: string): number | null => {
  const s = str(fd, k);
  if (s === null) return null;
  const n = Number(s);
  return Number.isFinite(n) ? n : null;
};
export const need = (fd: FormData, k: string): string => {
  const s = str(fd, k);
  if (s === null) throw new Error(`${k} is required`);
  return s;
};
export const slug = (fd: FormData, k: string): string => {
  const s = need(fd, k);
  if (!/^[a-z0-9][a-z0-9-]*$/.test(s)) throw new Error(`${k} must be a lowercase slug (a-z, 0-9, -)`);
  return s;
};
export const csv = (fd: FormData, k: string): string[] =>
  (str(fd, k) ?? "").split(",").map((x) => x.trim()).filter(Boolean);
