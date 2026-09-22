# Fleet

A framework for running a company on a hierarchy of autonomous Claude Code
agents: a General Manager, division managers, workers, team auditors and one
database auditor, driven by a queue in both directions and gated by audit
before anything reaches production.

Nothing in this repository is specific to one company: divisions, seats,
prompts, rules and schedules are rows in each company's own ledger, and the
same installer stands up the next one.

```
installer/   the ledger: one parameterised SQL file per company (schema, queue, prompts, schedules)
routines/    the eight-line stub every Claude Code routine carries, and how to create one
companies/   example seed for a new company (divisions, seats, first prompts, schedules)
console/     SPEC.md: what the owner's console does; build it in your stack (the missing piece)
BUILD.md     how to replicate the whole thing for a new business, step by step
```

Start with [BUILD.md](BUILD.md). This public copy is the structure: the ledger,
the rules, the routine stub, the procedure. The owner's console is specified in
`console/SPEC.md` and left for you to build; every screen is one query.

## Replicating it with your own agent

Paste this to Claude Code (or any agent with a shell) and answer its one
round of questions:

> Clone https://github.com/superdangerbro/agent-fleet and follow its BUILD.md to
> stand up an agent fleet for **<company>**. Divisions: **<list them and what
> each owns>**. Supabase project: **<ref>** (or create one). Repository:
> **<owner/name>**. Do everything BUILD.md says end to end and build the console
> from console/SPEC.md in <your stack>; the only step I will do by hand is
> creating the routines at claude.ai, which you will prepare for me.

The root `CLAUDE.md` / `AGENTS.md` tells the agent how to behave here: do the
whole job, ask for the five inputs once, never commit a secret, and stop only
at the one step that has no API.

## The shape, in one paragraph

Every seat is a Claude Code routine whose only instruction is *load your seat
from the ledger and do what its prompt says*. The ledger is a Postgres schema
(Supabase) holding the seats, their versioned prompts, the shared rule blocks,
the schedules, and every hand-off: mandates down to managers, activations down
to workers, staged changes up to auditors, verdicts up to the database auditor,
reports up to the General Manager. A row landing in a hand-off table wakes the
seat that consumes it by firing its routine over HTTP from inside the database
(`pg_net`). Schedules are a backstop, not the driver. The owner talks to one
seat only, the General Manager, through `owner_task()`; everything else is
between the agents.
