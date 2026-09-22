# For the agent reading this

You are in the **fleet** repository: a framework for running a company on a
hierarchy of autonomous Claude Code agents, driven by a queue in a Postgres
ledger and gated by audit before anything reaches production. You are most
likely here to stand it up for a company.

**Do the whole job, end to end.** Read `BUILD.md` and execute it in order. Do
not summarise it back to the operator, do not stop at a plan, and do not hand
back a list of steps for a person to run. Everything in it except one step can
be done by you with a shell, a Supabase access token and the operator's repo.

**Ask the operator for exactly these, up front, in one message, then proceed:**

1. The company name and the ledger schema name (`<company>_agents`).
2. The Supabase project ref (20 lowercase letters) — or permission to create
   a project.
3. The company's GitHub repository (`owner/name`).
4. The divisions, and for each one what it owns — from that you derive the
   seats (one manager and one team auditor per division, workers as needed,
   standing watches where something needs checking on a cadence). Propose the
   roster; do not wait for them to design it.
5. A Supabase personal access token (or confirmation that `supabase login`
   has been run on this machine, in which case reuse it).

**The one step you cannot do:** creating each seat's Claude Code routine and
generating its fire token happens at claude.ai/code/routines by hand, because
there is no API for it. `routines/STUB.md` is the exact procedure. Do
everything else first — ledger, seed, repo wiring, console — so that when the
operator sits down to create routines, each one is a paste of the stub and a
paste of the token into the console's seat page, and the fleet is live the
moment the last switch is flipped.

**Never** put a token, key or password into a file that is committed, into a
knowledge base, or into a prompt. `.env.local` and the ledger's `dispatch`
table are the only two homes for secrets.

**Adapting.** Divisions, seats, prompts, rules and schedules are rows, not
code. A company with two divisions and no database auditor is a different
seed file, not a fork. Change a function in `installer/schema.sql` only when
the promotion chain itself must differ, and say why in the commit.

Layout:

```
BUILD.md                  the procedure — start here
installer/                the ledger (schema.sql, rules.sql, render.py)
routines/STUB.md          the routine stub and the by-hand routine steps
companies/example/        a template company seed
console/                  the owner's console (Next.js; deploy per BUILD.md §5)
```
