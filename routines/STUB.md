# The routine stub

Every seat is a Claude Code routine (claude.ai → Code → Routines). Its
instructions are this stub and nothing else. `<COMPANY>`, `<SCHEMA>`,
`<LEDGER MCP SERVER>` and `<slug>` are the only things that change per seat.

```
You are a seat in the <COMPANY> agent fleet: agent slug <slug>. Everything about your job lives in the fleet ledger, not in this form.

Before anything else, using the <LEDGER MCP SERVER> MCP server, run:
  select * from <SCHEMA>.seat_brief('<slug>');

Follow the prompt column exactly — it is your complete job description for this run and it tells you how to report yourself. If paused is true, record yourself with the note "fleet is paused" and stop. If this run arrived with a payload (text after these instructions), that payload is your task and takes precedence over any standing job in the prompt.

Nothing else is configured here on purpose: prompts, rules and schedules are changed in the ledger, never in this form.
```

## Creating a seat's routine (once per seat, by hand — there is no API for this)

1. Routines → New routine. **Name it `<Company> · <seat name>`** (e.g.
   `Acme · Sales manager`): the routines sidebar at claude.ai is one flat
   list across every company with no folder or filter, so the prefix is the
   only grouping you get. Repository: the company repo. Model: whatever the
   seat's `agents.model` says (Sonnet for most seats; Opus for the General
   Manager and the Database Auditor is a reasonable default).
2. Instructions: the stub above with the slug filled in.
3. Triggers: **remove the default schedule trigger**; add **Call via API** and
   generate the token. Copy the token — it is shown once.
4. Connectors/MCP: the routine runs with the repository's `.mcp.json`, so the
   ledger server (read-write to the ledger schema) and the product server
   (read-only) come from the repo. Nothing to add here.
5. Notifications: "Notify me when this routine finishes" **off** for every seat
   but the General Manager. The owner hears from one seat.
6. Save. Copy the routine id from the URL (`trig_…`).
7. Record it in the ledger — that is what makes the seat reachable by the queue:

   ```sql
   update <SCHEMA>.agents set routine_id = 'trig_…' where slug = '<slug>';
   insert into <SCHEMA>.dispatch (agent_slug, routine_id, fire_token, why)
   values ('<slug>', 'trig_…', 'sk-ant-oat01-…', 'queue wakes')
   on conflict (agent_slug) do update set routine_id = excluded.routine_id, fire_token = excluded.fire_token;
   ```

   The console's agent page has a form for exactly this.

8. Leave the routine's Active switch **off** until the fleet is resumed
   (`fleet_resume()`); flip it on then. A fired routine whose switch is off
   simply does not run, and the wake is recorded as fired anyway — the switch
   is the only state the ledger cannot see.

## Firing a routine by hand

```bash
curl -sS -X POST "https://api.anthropic.com/v1/claude_code/routines/<routine_id>/fire" \
  -H "Authorization: Bearer <fire_token>" \
  -H "anthropic-version: 2023-06-01" \
  -H "anthropic-beta: experimental-cc-routine-2026-04-01" \
  -H "content-type: application/json" \
  --data '{"payload":"<what you want it to do>"}'
```

This is what `wake()` does from inside Postgres. Use it only to carry out a wake
the ledger shows as `unroutable` (no token yet); everything else should go
through a row.

## Editing the stub in bulk

The stub is deliberately never edited, but if it must change, the claude.ai
routine page is scriptable from a browser console: click the button with
`aria-label="Edit instructions"`, set the dialog's `<textarea>` through the
native value setter plus an `input` event (it is a React form), click the
"Remove trigger" whose grandparent row reads "Runs daily …" if one is present,
then click "Save". The first click after a navigation is sometimes swallowed,
so retry the open until a dialog with a textarea exists.
