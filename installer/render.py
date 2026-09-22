#!/usr/bin/env python3
"""Render the ledger installer for one company.

    python installer/render.py --schema acme_agents > acme-ledger.sql

Then run the output once against that company's Postgres (Supabase SQL editor,
psql, or the management API). Idempotent: re-running upgrades in place.
Pass --with-rules to include the shared rule blocks (yes for a fresh company;
omit when you have edited a company's rule_blocks and do not want them reset).
"""
import argparse, io, pathlib, re, sys

HERE = pathlib.Path(__file__).parent

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--schema", required=True, help="ledger schema name, e.g. acme_agents")
    ap.add_argument("--with-rules", action="store_true", help="also emit installer/rules.sql")
    a = ap.parse_args()
    if not re.fullmatch(r"[a-z][a-z0-9_]{1,40}", a.schema):
        sys.exit("schema must be a plain lowercase identifier")
    parts = [(HERE / "schema.sql").read_text(encoding="utf-8")]
    if a.with_rules:
        parts.append((HERE / "rules.sql").read_text(encoding="utf-8"))
    out = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", newline="\n")
    out.write("\n".join(p.replace("{{SCHEMA}}", a.schema) for p in parts))
    out.flush()

if __name__ == "__main__":
    main()
