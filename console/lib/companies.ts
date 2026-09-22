import fs from "node:fs";
import path from "node:path";

// The company registry is configuration, not code. It is read at request time
// from, in order:
//   1. FLEET_COMPANIES   — a JSON object in the environment (what a hosted
//                          deployment uses; nothing about a company is committed)
//   2. companies.json     — next to package.json, gitignored, for a local console
//   3. companies.example.json — the shipped example, so a fresh clone renders
// Shape: { "<slug>": { name, projectRef, schema, repo?, routinesUrl? } }

export type Company = {
  slug: string;
  name: string;
  projectRef: string;
  schema: string;
  repo?: string;
  routinesUrl?: string;
};

type Registry = Record<string, Omit<Company, "slug">>;

function readRegistry(): Registry {
  const env = process.env.FLEET_COMPANIES;
  if (env && env.trim()) {
    try {
      return JSON.parse(env) as Registry;
    } catch (e) {
      throw new Error(`FLEET_COMPANIES is not valid JSON: ${(e as Error).message}`);
    }
  }
  for (const file of ["companies.json", "companies.example.json"]) {
    const p = path.join(process.cwd(), file);
    if (fs.existsSync(p)) return JSON.parse(fs.readFileSync(p, "utf8")) as Registry;
  }
  return {};
}

export function listCompanies(): Company[] {
  return Object.entries(readRegistry()).map(([slug, c]) => ({ slug, ...c }));
}

export function getCompany(slug: string): Company {
  const c = readRegistry()[slug];
  if (!c) throw new Error(`unknown company: ${slug}`);
  if (!/^[a-z_][a-z0-9_]*$/.test(c.schema)) throw new Error(`bad schema name for ${slug}`);
  if (!/^[a-z]{20}$/.test(c.projectRef)) throw new Error(`bad project ref for ${slug}`);
  return { slug, ...c };
}
