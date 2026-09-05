/// Operating instructions handed to every client at `initialize`.
///
/// This is the highest-leverage place to put the knowledge a fresh client
/// needs, because it is the one place a client cannot fail to read: the MCP
/// `instructions` field comes back in the initialize result, before any tool
/// is listed, with no extra round trip and nothing to opt into. A new PC with
/// a new AI on it should not have to rediscover how this server behaves --
/// so the knowledge ships in the Dart source, versioned with the code it
/// describes, rather than living in someone's notes.
///
/// Keep this operational and roughly a page. It answers "how do I drive this
/// thing without breaking anything"; the longer-form conventions, data models
/// and plant specifics live in the `scada://source/knowledge` resource, and
/// per-argument detail lives in each tool's own description.
library;

/// The `instructions` string advertised by `TfcMcpServer`.
const kTfcServerInstructions = '''
TFC HMI — industrial SCADA control system for a fish processing plant.
This server is hosted INSIDE the running Flutter HMI application, so it reads
live process values and the live configuration.

## The one thing to understand: every write tool is a PROPOSAL

create_alarm, update_alarm, delete_alarm, create_key_mapping,
update_key_mapping, delete_key_mapping, propose_page, propose_asset and
update_asset DO NOT WRITE ANYTHING. Each one builds a proposal, hands it to
the operator's screen as a black banner, and returns the proposal JSON to you.

    tool -> ProposalService -> the operator's banner -> Accept -> saved

The operator's Accept is what persists it, through the same code path used
when a person edits by hand. Until then nothing exists: nothing is in the
database, nothing survives an app restart, and there is no table to poll. A
successful tool result means "the operator has been asked", not "done".

## Learning what the operator decided

- `await_proposal_feedback` — parks until the operator accepts, rejects,
  dismisses or views a proposal, then returns. Park it in a background
  process and re-arm it when it returns; it wakes you the moment a button is
  clicked. It returns `timed_out: true` with no decisions if nothing happened
  within `timeout_seconds` (default 55) — that is not an error, just call it
  again with the same `since`.
- `get_proposal_feedback` — the same payload without blocking, for reconnects.

Both take `since` and return `last_seq`. Track `last_seq` and pass it back as
`since`: decisions are handed out strictly-greater-than, so you never see one
twice. Decisions are kept in a bounded in-memory ring; a `truncated: true`
flag means you fell behind it and should re-read the config instead of
trusting your picture of it. Each decision carries a `summary` sentence
naming exactly what the operator acted on, plus per-proposal title/type/op.

## Verify before you propose

Never propose against a remembered picture of the config.
- Read the live mirror at %APPDATA%/centroidx/shared_preferences.json — keys
  `page_editor_data`, `key_mappings`, `alarm_man_config` — for asset indices
  and existing bindings.
- Confirm an OPC UA node actually exists with browse_nodes, and that it reads,
  with get_tag_value, BEFORE proposing a mapping to it.
- list_pages / list_assets / get_asset_detail / list_key_mappings /
  list_alarm_definitions are the read side of the same data.

## server_alias is mandatory on every OPC UA key mapping

Aliases in this plant: st101, st201, st301 (the three station PLCs), baader,
speedbatcher1, speedbatcher2, speedbatcher3.

A mapping without one resolves to no client and SILENTLY READS NULL — no
error, no alarm, just a sensor that never reports. 28 sensor .Fault mappings
were dead for exactly this reason.

Note the shape: `server_alias` lives INSIDE the `opcua_node` object, not at
the top level of the mapping. An audit that looks at the top level reports
every healthy mapping as broken.

## Asset editing

update_asset: `page_key` + `asset_type` + `patch` are required. Narrow with
`title` or `key`; use `index` when several still match (the index is
re-validated against type/title/key when applied, so a stale index fails
safely instead of patching the wrong asset). `child_id` targets a child
inside a ThirdPartyEquipment or Elevator. Omit `title` for assets that hide
their tag — their `text` is null, so a title selector matches nothing.
`patch` is a SHALLOW MERGE onto the asset's own JSON field names.

propose_asset: one `title` plus a `children` array — send a batch as ONE
proposal, not one call per asset. `x`/`y` are page fractions (0..1);
everything else goes under `config`. Trap: list_asset_types under-reports
required fields (SensorConfig also needs kind, invertActivePolarity,
risingEdgeDelayKey, fallingEdgeDelayKey, activeColor, inactiveColor,
showTag). Validate against the asset's own fromJson, not the catalog — one
invalid child strands the whole batch.

create_alarm returns the alarm `uid`, and alarm beacon assets bind BY uid:
create the alarm first, then the asset. Replacing an alarm means replacing
its asset as a pair.

## Static reports

list_reports, get_report_definition, generate_report, resolve_shift and
get_shift_calendar read. generate_report takes an offset: 0 is the current
period, -1 the one before, so "last night's shift" is offset -1 on a
shift-ranged report.

create_report, update_report, delete_report and set_shift_calendar are
**proposals like every other write here** — they change nothing. A person
applies them in the report editor, and that save is checked against their
session for `configure` and recorded. Say so when you propose one: the
operator has to approve it.

A report's `sql` section runs one read-only SELECT. It may not name the
access tables (app_user, app_role, audit_entry, access_template,
access_key_binding) — a report is rendered on a page any operator can open,
so publishing credentials or the audit record through one is refused.

## Looking at the screen

screenshot_window returns a PNG of the HMI window as the operator sees it --
live theme, fonts, painters and values. render_page does the same for any
page from list_pages, rendered offscreen without disturbing the operator.
Look before you judge a layout; reconstructing a page from its config is
guesswork. Both only exist when the server is hosted inside the app, and both
cap the image at ~2 MB of base64, re-rendering smaller if it would not fit.

## Transport and limits

Streamable HTTP at http://127.0.0.1:8765/mcp. initialize ->
notifications/initialized -> tools/call, carrying the `mcp-session-id` header
from the first response on every subsequent request. Replies arrive as SSE
`data:` lines. Restarting the app kills the session — re-initialize.

Tool concurrency is 3. Fanning out more than three calls just makes them
queue, so batch instead of parallelising. (await_proposal_feedback and
get_proposal_feedback are exempt — parking one does not block other tools.)

Read `scada://source/knowledge` for the longer-form architecture and
conventions.
''';
