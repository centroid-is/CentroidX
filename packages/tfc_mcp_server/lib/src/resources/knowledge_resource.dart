import 'package:mcp_dart/mcp_dart.dart';

/// Long-form description of how the TFC HMI application works and how to
/// drive it correctly.
///
/// This is the companion to the `instructions` string returned at
/// `initialize` (see `src/server_instructions.dart`). Instructions are the
/// tight operational page every client gets for free; this resource is where
/// the architecture, the data models and the plant conventions live, for a
/// client that wants to go deeper before it proposes anything.
///
/// The capability claims below are checked against the tools actually
/// registered in `src/server.dart`. They were wrong for a while -- this text
/// still said the AI "CANNOT modify layouts directly" long after
/// propose_asset, update_asset, create_alarm and create_key_mapping existed,
/// which taught every client that read it to refuse work it could do. If a
/// tool group changes, change this with it.
const _knowledgeText = '''
# TFC HMI System Architecture

## System Components

### StateMan (State Manager)
Real-time state engine routing OPC UA subscriptions to the UI. Maintains a
key-value store of all live process values. Keys are logical names (e.g.,
"pump3.speed", "conveyor.belt_running") that map to OPC UA nodes via
KeyMappings. The AI can READ current values (get_tag_value, list_tags) and
can PROPOSE changes to the mappings themselves, but can never write a value
to the PLC -- there is no tool that does it.

### AlarmMan (Alarm Manager)
Rule-based alarm system. Each alarm has a UID, title, description, severity
level, and one or more rules defined as boolean expressions over tag values.
When a rule evaluates to true, the alarm activates. Operators can acknowledge
and snooze alarms. The AI can READ alarm state, history and definitions, and
can PROPOSE new, changed or deleted alarm definitions (create_alarm,
update_alarm, delete_alarm) for the operator to accept. It cannot acknowledge
or silence a live alarm.

### Collector
Configurable data collection service that samples tag values at defined
intervals and stores them as timeseries in PostgreSQL. Retention policies
control data lifetime. Collection is configured per key mapping, under
`collect` -- so proposing collection means proposing a key mapping change.

### PageManager
Dynamic HMI page builder. Pages contain positioned widgets (LEDs, buttons,
graphs, conveyors, Beckhoff terminals, etc.) bound to keys. The AI can READ
page and asset configuration (list_pages, list_assets, get_asset_detail) and
can PROPOSE pages and assets (propose_page, propose_asset, update_asset).
The operator's Accept is what applies them.

### Reports
Static shift/production reporting over the Collector's timeseries tables and
the alarm history. A report is a declarative JSON definition (KPI rows,
aggregate tables, charts, alarm summaries, downtime paretos, custom
read-only SQL sections, text sections) bound to a period kind — shift, day
or week — and generated on demand for any period (offset 0 = current,
negative = backwards in time). Shifts come from a configurable shift
calendar. A KPI metric can fold several keys into one figure via
`additional_keys` + `combine` (sum/mean/min/max, default sum) — "plant
throughput = the three SpeedBatchers summed" is one metric, with rollover-
safe counter deltas kept intact. An `sql` section takes one SELECT (or
WITH … SELECT); the tokens `:from`/`:to` are bound to the range as ISO-8601
UTC text (write `:from::timestamptz` against timestamptz columns), rows are
capped by `max_rows`. The AI can READ (list_reports,
get_report_definition, generate_report, resolve_shift, get_shift_calendar)
and can WRITE definitions DIRECTLY (create_report, update_report,
delete_report, set_shift_calendar) — the one tool group whose writes are not
proposals, because a report definition only reads data. Writes are audited.

## Proposals: the only way anything changes

Every write tool builds a proposal and returns it. It does not touch the
database.

    tool handler (propose_asset / create_alarm / ...)
      -> ProposalService.wrapProposal
      -> McpBridgeNotifier.proposalStream
      -> the black proposal banner on the operator's screen
      -> Accept -> the editor saves it, the same way a person would

Consequences worth internalising:

* A successful tool result means the operator HAS BEEN ASKED. It does not
  mean the change happened.
* Nothing about a proposal is persisted. It exists from the moment the tool
  wraps it until the operator decides, and an app restart loses every
  undecided one.
* There is no proposal table to poll. (There used to be; the poll never read
  a single row in production and 1018 rows accumulated, all still `pending`.
  See PROPOSAL_DELIVERY.md in the repository for why it was removed.)
* To learn the outcome, call `await_proposal_feedback` -- see below.

## Learning what the operator decided

`await_proposal_feedback(since?, timeout_seconds?)` parks until the operator
accepts, rejects, dismisses or views a proposal and then returns. Re-arm it
when it returns and you are effectively always listening.
`get_proposal_feedback(since?)` is the same payload without blocking.

Each decision looks like:

    {
      "seq": 7,
      "at": "2026-08-22T09:41:12.004Z",
      "action": "accepted",
      "count": 2,
      "summary": "Accepted 2 asset update proposals: \\"CVS02.CN01.PX01.Fault: server_alias -> st201\\", \\"Line 1: keys -> SPB01.Recipe, SPB02.Recipe\\".",
      "proposals": [
        {"title": "CVS02.CN01.PX01.Fault: server_alias -> st201",
         "type": "asset_update", "op": "update"},
        {"title": "Line 1: keys -> SPB01.Recipe, SPB02.Recipe",
         "type": "asset_update", "op": "update"}
      ]
    }

`summary` is the same sentence the in-app assistant is told, built from the
titles the banner actually showed the operator -- it names what was accepted,
not just how many things were.

Track `last_seq` and pass it back as `since`; delivery is strictly-greater,
so reconnecting never replays a decision you already saw. Decisions are held
in a bounded ring buffer, so a client that was not connected when the
operator clicked still finds them. `truncated: true` means decisions were
evicted before you came back for them: re-read the config rather than trust
your picture of it.

`action` is one of `accepted`, `rejected`, `dismissed`, `viewed`. Note that
`viewed` is not a decision -- the operator opened the proposal in its editor
and the proposal is still pending.

## Data Models

### Key Mappings
Key mappings bind logical key names to OPC UA node addresses.
Shape: `{key, opcua_node: {namespace, identifier, server_alias}, collect?}`

**`server_alias` is mandatory.** This plant runs several OPC UA servers:
st101, st201, st301 (the three station PLCs), baader, and speedbatcher1
through speedbatcher3. A mapping without an alias resolves to no client and
reads null forever -- silently, with no error and no alarm. 28 sensor .Fault
mappings were dead for exactly this reason.

`server_alias` lives INSIDE the `opcua_node` object. An audit that looks for
it at the top level of the mapping reports every healthy mapping as broken;
that false alarm has been raised more than once.

The AI always works with logical key names, never raw OPC UA node IDs.

### Alarm Definitions
Each alarm definition contains: uid (unique identifier), key (the tag it
monitors), title, description, severity level, and rules (boolean
expressions). Operators use: AND, OR, NOT, >, <, >=, <=, ==, !=
Example: "pump3.overcurrent > 15 AND pump3.running == true"

create_alarm returns the generated `uid`. Alarm beacon assets bind BY uid, so
create the alarm first and then the asset that points at it. Replacing an
alarm means replacing its beacon asset as a pair -- an asset left pointing at
a deleted uid renders nothing and reports nothing.

### Pages and Assets
Pages are HMI display screens containing widgets. Each page has a key and a
title. Assets are the widgets on them, positioned by page fraction.

**propose_asset** takes one `title` plus a `children` array: send a batch as
ONE proposal rather than one call per asset. `x`/`y` are fractions of the
page (0..1); everything else belongs under `config`.

The asset-type catalog (list_asset_types) UNDER-REPORTS required fields.
SensorConfig, for instance, also needs kind, invertActivePolarity,
risingEdgeDelayKey, fallingEdgeDelayKey, activeColor, inactiveColor and
showTag beyond the detectionKey the catalog names. Validate against the
asset's own `fromJson` in the repository, not the catalog: one invalid child
strands the entire batch.

**update_asset** requires `page_key` + `asset_type` + `patch`. Narrow the
match with `title` or `key`, and use `index` when several assets still match.
The index is re-validated against type/title/key when the proposal is
applied, so a stale index fails safely instead of patching the wrong asset.
`child_id` targets a child inside a ThirdPartyEquipment or Elevator. Omit
`title` for assets that hide their tag -- their `text` is null, so a title
selector matches nothing at all. `patch` is a SHALLOW MERGE onto the asset's
own JSON field names.

## Verify before proposing

The live configuration mirror is at
`%APPDATA%/centroidx/shared_preferences.json`, under the keys
`page_editor_data`, `key_mappings` and `alarm_man_config`. Read it for asset
indices and existing bindings rather than proposing against a remembered
picture.

Confirm an OPC UA node exists with `browse_nodes`, and that it actually
reads, with `get_tag_value`, before proposing a mapping to it. A proposal
against a node that does not exist costs the operator a decision and buys
nothing.

## AI Capabilities and Boundaries

### What the AI CAN do:
- Read live tag values from StateMan, and browse the live OPC UA address
  space when a PLC session is up
- Read alarm configuration, active alarms, and alarm history
- Read system configuration (pages, assets, key mappings, alarm definitions)
- Search electrical drawings, PLC source code, and technical documentation
- Query historical trend data
- Propose alarms, key mappings, pages and assets for the operator to accept
- Learn the operator's decision on those proposals
- Explain why alarms fired using correlated data
- Produce shift handover summaries

### What the AI CANNOT do:
- Write to OPC UA (no control of physical equipment, no setpoint changes)
- Write to the database (every change goes through a proposal and an editor)
- Modify StateMan values
- Acknowledge or silence a live alarm
- Control or override safety systems
- Access encrypted server configurations (OPC UA endpoints, DB credentials)

## Transport

Streamable HTTP at `http://127.0.0.1:8765/mcp`. Sequence: `initialize`, then
the `notifications/initialized` notification, then `tools/call`, carrying the
`mcp-session-id` header returned by the first response on every subsequent
request. Replies arrive as SSE `data:` lines. Restarting the HMI kills the
session, so re-initialize after a restart.

Tool concurrency is capped at 3: a fourth simultaneous call queues rather
than failing. `await_proposal_feedback` and `get_proposal_feedback` are
exempt, so parking a long poll does not consume one of the three slots.
''';

/// Registers the `scada://source/knowledge` resource on [mcpServer].
///
/// Returns the long-form conventions above. The short operational version is
/// delivered automatically as the server's `instructions` at initialize, so
/// a client that reads nothing still knows the load-bearing rules; this
/// resource is for one that wants the detail.
void registerKnowledgeResource(McpServer mcpServer) {
  mcpServer.registerResource(
    'Application Knowledge',
    'scada://source/knowledge',
    (
      description:
          'How the TFC HMI application works internally -- system components, '
          'data models, proposal conventions, and AI capabilities',
      mimeType: 'text/plain',
    ),
    (Uri uri, RequestHandlerExtra extra) async {
      return ReadResourceResult(
        contents: [
          TextResourceContents(
            uri: uri.toString(),
            mimeType: 'text/plain',
            text: _knowledgeText,
          ),
        ],
      );
    },
  );
}
