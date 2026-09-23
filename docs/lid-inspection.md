# Lid inspection — integration design

Camera-based anomaly detection for ~40 × 30 cm box lids, shown in CentroidX as
the **Lid inspection** asset (`lib/page_creator/assets/lid_inspection.dart`).

This document is the contract between the inspection service (Python: camera,
model, threshold) and the HMI. It replaces an earlier draft that had the
service drop JSON files on a shared volume for a Dart `AlarmWatcher` to
inotify, a `shelf` route to serve the JPEGs and a hand-rolled Flutter column
to show them. None of that exists, and none of it was needed — see §6 for why
each piece was dropped.

---

## 1. Architecture

```
 Presence sensor ──(opto-in, Line1)──▶ Basler GigE camera
                                           │ dedicated NIC, jumbo frames
                                           ▼
 ┌────────────────────────────────────────────────────────────┐
 │ lid-inspection service (Python, own container)             │
 │  pypylon grab → tile → Anomalib/OpenVINO → score/threshold │
 │                                                            │
 │  publishes:  OPC UA server  (asyncua)   ── live state ──┐  │
 │              Postgres rows  (psycopg)   ── the record ──┼─┐│
 │              /data/frames/<id>.jpg      ── full-res    │ ││
 └────────────────────────────────────────────────────────┼─┼┘
                                                          │ │
      ┌───────────────────────────────────────────────────┘ │
      ▼                                                     ▼
 StateMan (OPC UA client)                         station Postgres
   │ key mappings  LID01.*                           lid_inspection table
   │                                                        │
   ├─▶ AlarmMan     formula  LID01.Anomaly AND LID01.Armed  │
   ├─▶ Collector    historises LID01.Score (trend)          │
   ├─▶ centroidx-backend — same subscriptions, headless     │
   └─▶ Lid inspection asset ◀────────────────────────────────┘
          tile (colour + alarm pulse) → side pane (frame, heat-map,
          score, recent anomalies, trend, arm/shadow, train, threshold)
```

The service speaks two things CentroidX already understands: **OPC UA** for
live values and **Postgres** for records. It is, to the HMI, one more server
in *Server config* and one more table in the station database. No backend
change, no new transport, no new alarm path.

---

## 2. OPC UA node contract

One folder per camera, nodes named exactly as below; the station maps them in
*Key mappings* as `<prefix>.<Name>` (the asset subscribes by suffix). The
authoritative list is `enum LidNode` in the asset file; the configure form
prints it with the operator's own prefix.

| Node | Type | R/W | Meaning |
|---|---|---|---|
| `Score` | Double | R | Anomaly score of the last inspected lid. **Historise this** (collect, no sample interval → one row per lid). |
| `Threshold` | Double | R/W | Score at or above which a lid is an anomaly. Written from the pane's Setpoints. |
| `Anomaly` | Boolean | R | True from the moment a lid scores ≥ threshold until the next lid scores below it. The alarm reads this. |
| `Armed` | Boolean | R/W | False = shadow mode: scored and recorded, no alarm. |
| `LastId` | String | R | Id of the last row written — the pane reloads pictures when it changes. |
| `SecondsSinceLast` | Int32 | R | Refreshed every second. Alarm on `LID01.SecondsSinceLast > 120 AND CVS01.CN05.Running` to catch a silent camera. |
| `CameraOk` | Boolean | R | False while frames cannot be grabbed. |
| `LidType` | String | R | Lid type (= model folder) in use. |
| `ModelVersion` | String | R | Version stamp of the loaded model. |
| `TrainingState` | String | R | `idle` · `collecting` · `training` · `failed`. |
| `GoodSamples` | Int32 | R | Good-lid images in the training set for this lid type. |
| `Command` | String | W | `collect:<n>` · `train` · `reload`. The service acts and clears it to `''`. |

Semantics the service must honour:

* `Anomaly` is level, not pulse. Set it with the verdict of each lid. The
  alarm is acknowledge-required, so a single bad lid stays on screen until an
  operator has looked even after the next good lid clears the node.
* `Armed` false must not suppress `Anomaly` — the alarm formula ANDs the two,
  and the pane wants to show shadow-mode anomalies as such.
* `Command` is consumed once. Ignore a value you do not know; write `''` back
  when done, `TrainingState = failed` when training fails, and keep inferring
  with the previous model until `reload`.
* Writes come through the HMI's access rules: `Threshold`, `Armed` and
  `Command` are gated like any conveyor setpoint. The service does not need
  its own auth.
* Server health is visible to the HMI through the connection meta keys
  (`@conn/<alias>/…`) — no heartbeat node needed.

A minimal server with `asyncua`:

```python
from asyncua import Server, ua

server = Server()
await server.init()
server.set_endpoint("opc.tcp://0.0.0.0:4841/lid/")
idx = await server.register_namespace("centroid.is/lid")
cam = await server.nodes.objects.add_folder(idx, "LID01")
score = await cam.add_variable(idx, "Score", 0.0, ua.VariantType.Double)
threshold = await cam.add_variable(idx, "Threshold", 0.62, ua.VariantType.Double)
await threshold.set_writable()
# … Anomaly, Armed (writable), LastId, SecondsSinceLast, CameraOk, LidType,
#   ModelVersion, TrainingState, GoodSamples, Command (writable)
```

Subscribe to `Threshold`, `Armed` and `Command` in the service to react to
HMI writes; persist `Threshold` and `Armed` next to the model so a restart
keeps them.

---

## 3. Database contract

The service owns the table and runs this at start-up (the same DDL is
`kLidInspectionDdl` in `packages/tfc_dart/lib/core/lid_inspection.dart`):

```sql
CREATE TABLE IF NOT EXISTS lid_inspection (
  id            TEXT PRIMARY KEY,
  camera        TEXT NOT NULL,
  time          TIMESTAMPTZ NOT NULL,
  score         DOUBLE PRECISION NOT NULL,
  threshold     DOUBLE PRECISION NOT NULL,
  anomaly       BOOLEAN NOT NULL,
  armed         BOOLEAN NOT NULL,
  lid_type      TEXT,
  model_version TEXT,
  inference_ms  INTEGER,
  image         BYTEA,
  heatmap       BYTEA
);
CREATE INDEX IF NOT EXISTS lid_inspection_camera_time
  ON lid_inspection (camera, time DESC);
```

Rules:

* **One row per inspected lid**, OK or not. Score history is what makes the
  threshold tunable later; the rows are small without images.
* `image`/`heatmap` are a **preview**: ≤ 1024 px on the long side, JPEG ~85 %,
  roughly 100–200 kB each. Stored for anomalies and for near-misses
  (`score ≥ 0.8 × threshold`), null otherwise. The full-resolution frame goes
  to `/data/frames/<id>.jpg` on the service's disk for engineers.
* `camera` = the key prefix unless the asset is configured otherwise.
* `id` = `<UTC time, ms>_<counter>` e.g. `20260915T143012123Z_000482` — the
  same string goes to `LastId`.
* **Retention is the service's job**: delete rows older than N days and null
  out images beyond a byte budget, nightly. The HMI never deletes.
* Write with the station database credentials from the station `.env`; the
  service runs on the same host.

The HMI reads through `DatabaseLidInspectionStore` (`latest`, `recent`,
`image`) and nothing else. Reports can read the table with an SQL section.

---

## 4. The asset

`LidInspectionConfig extends AlarmVisibilityConfig` — it *is* an alarm
beacon, so the navigation-bar pulse and auto-navigation discover it by type
and need no change.

* **Tile**: camera icon, label, verdict caption (`OK 0.31`, `ANOMALY 0.87`,
  `Shadow · anomaly 0.87`, `Camera offline`, `Unavailable`). Fill colour from
  the muted state palette — only an armed anomaly is saturated red; shadow is
  the manual-mode yellow; anything that is not a verdict is grey. While a
  bound alarm is active the tile carries the beacon's pulse at its corner and
  its border takes the alarm's colour.
* **Pane** (Status → Trend → Manual → Setpoints → Recent anomalies): active
  alarm cards with acknowledge; score and threshold tiles; the latest frame
  (tap → zoomable viewer with Frame / Heat-map toggle); last-lid rows; score
  trend from the collector; Armed switch, training state, good-lid count,
  model version, Collect / Train / Reload buttons; threshold setpoint; the
  recent anomalies with thumbnails.
* **Configure form**: setup help (generated from `LidNode`), key prefix,
  camera name, *Create anomaly alarm* (mints
  `lid-anomaly:<prefix>` with formula `<prefix>.Anomaly AND <prefix>.Armed`,
  error level, acknowledge required, not a stop; a second press updates it),
  alarm picker, announce-in-navigation, recent count, collect batch size,
  label, size, position.

Everything the pane shows is a value, never a key name, per the pane rules.

---

## 5. Training workflow, from the operator's side

1. **Seed the training set** — either press *Collect N good lids* in the pane
   while known-good lids pass (the service saves the next N frames into
   `/data/models/<lid_type>/dataset/good/`), repeated until *Good lids in set*
   is 100–300 and covers every acceptable variation; or copy PNG/JPEG frames
   into that folder by hand (and optional known defects into
   `dataset/defect/`).
2. **Train** — *Train model*. The service fits PatchCore (ResNet18) on the
   set and exports OpenVINO FP16, in a subprocess so inference keeps running
   on the previous model. `TrainingState` goes `training` → `idle` (or
   `failed`), `ModelVersion` shows the new stamp after **Reload model**.
3. **Threshold** — score a held-out set of good lids (the rows are in the
   table), set the setpoint just above the highest good score with a margin,
   verify with a scratched or marked lid.
4. **Shadow** for a few days (Armed off): anomalies are recorded and listed,
   nothing alarms. Then arm.

Any change to camera, lens, lighting, exposure or position → recapture and
retrain. Store `threshold.json` and `VERSION` beside the model.

---

## 6. What changed from the first draft, and why

| Draft | Now | Why |
|---|---|---|
| Service writes `<id>.json` + JPEGs to a shared volume; a Dart `AlarmWatcher` inotifies and calls `alarmSystem.raise(...)` | Service is an OPC UA server; the alarm is an ordinary expression | There is no `raise()` — every alarm is a boolean formula over `StateMan` keys evaluated by `AlarmMan`. A watcher would be a second alarm system with none of ack, history, downtime, editor, nav pulse. |
| `shelf` route `/anomaly/images/<name>` in the backend, `Image.network` in Flutter | Preview JPEGs in a `BYTEA` column; the asset reads through drift | The backend has no HTTP server at all, and no asset fetches over the network. The technical-document library already stores PDF bytes in Postgres; same read path. |
| Alarm carries `imageUrl`; history via `alarm_history` | The `lid_inspection` row is the record; alarm and row share time and id | `alarm_history` has no payload column, is written only on clear, and stations run with `historyToDb: false`. |
| Only anomalies are recorded | Every lid is a row; images for anomalies and near-misses | Threshold tuning needs the good-lid score distribution; the draft's own "hard-won rules" asked for borderline samples. |
| Threshold in `threshold.json`, set by an engineer on the box | `Threshold` node, written from the pane's Setpoints under the access rules | Nobody runs `anomalib` on a panel PC floor-side; the HMI is where the operator is. |
| "Run in shadow mode" as a checklist step | `Armed` node, the alarm formula ANDs it, the tile shows shadow verdicts in yellow | A mode is a state the pane can show and switch, not a deployment note. |
| Training by CLI on a GPU machine | `Command` node: collect / train / reload, `TrainingState`, `GoodSamples` | PatchCore fitting is minutes on CPU; doing it in the service, in a subprocess, makes retraining after a lighting change an operator action. |
| Camera silence is invisible | `CameraOk`, `SecondsSinceLast` | A dead trigger looked identical to a perfect run. |
| `AlarmWatcher._restart()` re-entered `start()`, which re-listed the folder and re-subscribed | (gone) | Would double-handle files; moot. |

Kept from the draft, unchanged: the Basler network/trigger/optics notes, the
tiling approach, the model choice (PatchCore R18 → OpenVINO FP16 on Iris Xe,
benchmark SuperADD on a GPU machine), the shadow-first rollout, NTP on the
host, and `network_mode: host` + `/dev/dri` for the service container. The
`render` group GID comes from the station `.env` (`RENDER_GID`), which is
already how the HMI container gets it.

Open, deliberately: the service has **no reject output**. Wiring one (camera
Line2 → PLC, or the PLC reading `LID01.Anomaly` over its own OPC UA client)
is a PLC decision, not an HMI one.
