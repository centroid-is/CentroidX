# Web-HMI/SCADA edge cases from practitioner forums

(Research agent report — forum-edge-cases, 2026-08-13. Reddit/plctalk blocked to crawler; depth from Inductive Automation Discourse, HA community, OPC Foundation, and two locally-verified Dart experiments — repros in scratchpad: nan.dart, enc.dart.)

## Theme 1: Gateway freeze looks like network death — to all clients at once

Ignition "ClockDriftDetector" threads: VMware/Veeam snapshot froze gateway **42 s** → "tag subscriptions time out all over the place… bad data in history… missed events" (forum 64109); nightly snapshots 1.5–4.4 s pauses put tags in "erred state that they won't update again until manually toggled" (32236, vendor acknowledges staleness cascade; failure-to-recover is the bug). Also GC (94938, 52754), one expensive report (40216), a recursive script (44137), even a diagnostics page (55097); a 4 s stall caused a comms dropout (30776).

**For us:** Dart gateway = single isolate, single event loop — more exposed than the JVM. Long work (big batch encode, Timescale result decode, alarm-history query) stalls every client's heartbeat simultaneously → synchronized false disconnect + self-inflicted reconnect storm, recurring nightly at backup time. A stalled gateway and a dead network are indistinguishable to the client but need different responses (gateway's history has a hole after a stall).

**Do:** event-loop lag monitor (Timer.periodic ~200 ms, alarm >1000 ms drift); unbounded work off-isolate (Isolate.run); after a stall > freshness deadline, gateway proactively announces "I was frozen for N ms" on resync; historian marks interval gapped. **Test:** SIGSTOP gateway 45 s, 5 clients, 3 PLCs — every value must return to good quality without manual intervention. Ask about host backup strategy before go-live.

## Theme 2: Two Dart-verified data hazards

### 2a. jsonEncode THROWS on NaN/Infinity (worse than JS's null)
Verified: encode NaN/±Infinity → throw; decode {"v":NaN} → throw; **decode 1e999 → silently Infinity** (poison value: enters silently, detonates on re-encode). One open-circuit 4–20 mA input or divide-by-zero on a weigher rate calc (kg/min when belt stops) kills the entire 10 Hz batch for every client. OPC UA Part 6 §5.4.2.4 says encode as JSON *strings* "NaN"/"Infinity"/"-Infinity".
**Do:** sanitize at the OPC UA boundary — non-finite double → null value + "non-finite" quality code. Property-test round trip with NaN, ±Inf, ±0.0, maxFinite, subnormals; fuzz decoder with 1e999, deep nesting, duplicate keys.

### 2b. utf8.decode throws on Latin-1 bytes — Icelandic product names
Verified: strict utf8 → FormatException mid-batch; lenient → U+FFFD; latin1 → correct "Þýæ". ABB AC500 thread (forum 56614): "Moteur prêt" → "Moteur pr?t", fix required converting ~800 vars STRING→WSTRING. S7 STRING is byte array, no declared encoding (in practice CP1252/Latin-1); ST101/ST201/ST301 and Baader may disagree with each other. Þ/æ/ð/ö in product names/batch codes/alarm text is the NORMAL case in Iceland.
**Do:** explicit per-server byte→String decode config (utf8|latin1), default `utf8.decode(bytes, allowMalformed: true)`; strip trailing NULs (S7 fixed-width padding); test fixtures "Þorskflök í raspi", "Ýsuhnakkar" from day one. Note: Dart emits unpaired surrogates (\ud800) that strict non-Dart parsers reject.

## Theme 3: Dead subscription on a live connection

HA thread 686946: wall dashboard visually normal, data hours old, **some widgets updating while others froze** (graphs live, cards stale). Connection-level liveness cannot detect per-subscription death by construction — heartbeat flows, freshness deadline never fires.
**Do:** per-subscription monotonic seq + "last evaluated" stamp in each batch; three UI states: fresh / stale-link-down (whole screen) / stale-this-value-stopped (single widget). **Test:** drop one subscription's updates while connection + other subs stay healthy; client must notice.

## Theme 4: Ghost sessions server-side — the mirror of half-open

Ignition 101257: closed tab sends nothing; IA dev: "no way to distinguish, on the backend, between closed-tab and dropped-network." Server-side session keeps running until timeout; repeated open/close compounds. Related OOM (101903): **carousel rotating views every 30 s leaks** — auto-rotating wall display = widget tree discarded 2880×/day. eLinux panels get power-cycled at wash-down; each hard-kill leaves subscriptions + conflation buffer + OPC UA monitored items. PLCs have hard monitored-item caps (UA-.NETStandard#564) → weeks later NEW clients fail to subscribe, symptom unrelated to cause.
**Do:** heartbeat-driven session expiry with FULL teardown (monitored items, buffers, alarm subs); refcount/dedup monitored items across clients (N clients watching one tag = one item); per-client resource counts on status page. **Test:** connect, kill -9, ×200 — gateway memory and PLC monitored-item count return to baseline. Soak-test any rotating wall display.

## Theme 5: Touch panels / on-screen keyboards — silent write loss with confirming UI

IGN-2441 (forum 95818): "binding never fires after pressing Enter on the on-screen keyboard" — operator types setpoint, presses Enter, sees their value, NOTHING WAS WRITTEN. ~50 OSK threads: full-screen OSK hiding the field (107064), OSK won't launch on Linux (50474, 47904), freezes (79551), broken backspace (50663), wrong orientation (79287), password shown in clear text (15570), key events only from hardware keyboards (61087).
**For us:** Flutter eLinux has no system OSK — we build our own numeric keypad (good: we control commit semantics).
**Do:** never let local edit state be the confirmation — after write, clear edit state and display PLC read-back; mismatch within timeout → "unconfirmed". Keypad must never cover the field (modal restating tag/current/new on 7–10" panels). Test on the actual panel in its mounting orientation.

## Theme 6: Momentary controls — the release that never arrives

Forum 21388: START bit latched, "not able to shut the motor down." Expert: "HMI sets the command, PLC resets it; don't rely on the HMI to reset it." And: "The correct answer is to not use momentary buttons in Perspective." Hold-to-run: **fast repeating incrementing 'still pressed' messages; PLC watchdogs presence of the operator**, timeout-reset in PLC is a "band-aid". FactoryTalk/Wonderware/RSView32 all exhibit stuck buttons on window focus loss (not just comms). Flutter extra trigger: onTapDown with no onTapUp on lifecycle change (screensaver, focus steal).
**Do:** hold-to-run = rolling counter/deadman at fixed rate, PLC runs only while counter advances; discrete commands = HMI sets, PLC clears; treat onTapCancel/AppLifecycleState change/connection loss as release. **Test:** hold jog, then (a) pull cable (b) kill app (c) background lifecycle — machine stops in all three.

### 6a. Write outcome unknown (mid-flight disconnect)
Writes prevented without error messages documented (20756). Need explicit "outcome unknown — verify" UI state: idempotency id per write, gateway short-lived outcome log, client re-queries in-flight ids on reconnect, operator dismissal required. Never silently resolve to "probably fine". (Converges with rpc-layer report's writeStatus design.)

## Theme 7: Alarms — floods on restore, ack propagation

Ack doesn't propagate across clients (65652: "still remain as unacknowledged on the local project"); per-client ack scoping actively contested (75427); alarms stuck in renotify pipeline after ack+clear, needing restart (87511). Animation trap (45637): plant overview with per-symbol blink animation → CPU spike exactly at peak alarm count; eLinux panels have far less headroom. Flood suppression best practice (reig-us.com solar SCADA): comms-alarm on-delay 30–120 s tuned to reconnect time constants; off-delay ~5 min to stop re-trigger chatter; **master inhibit — PLC health tag inhibits every dependent alarm** so link loss = ONE alarm.
**Do:** master-inhibit by PLC link status (wire the PIPE.upstream channel into alarm evaluation, not just UI); alarm state incl. ack gateway-authoritative, reconnecting client adopts gateway state, never replays; re-arm after blip = NEW occurrence with new id (decide explicitly); above N active alarms switch overview from blinking to static count+list. **Test:** drop one PLC with 50 active alarms, restore after 60 s, 5 clients (one disconnected throughout) — all converge on identical alarm state.

## Theme 8: Time — and the Iceland trap

Clock skew silently breaks `clientNow - serverTimestamp` staleness (everything permanently stale or never stale). eLinux panels often have **no RTC battery** → boot at epoch 0 until NTP; segmented plant LAN may never reach NTP → panel computes everything 56 years stale, greys out whole plant.
**Iceland: no DST, UTC+0 year-round** → dodges DST-hell trend/alarm bugs BUT local==UTC on every dev/test machine makes every timezone bug (naive datetimes, missing toUtc(), `timestamp` vs `timestamptz`) invisible until a CET laptop or remote-support client connects — surfacing as silently wrong data.
**Do:** single-clock staleness — gateway sends age-in-ms it computed, or client establishes clock offset at handshake; implausible-clock banner (clock before build date or >few s off gateway) instead of grey-out; timestamptz everywhere, UTC on wire, local only at render; **CI under TZ=Pacific/Chatham** (UTC+12:45 + DST, maximally hostile); decide timestamp provenance (PLC source ts vs gateway receive ts vs client render ts — which drives history, staleness, display).

## Theme 9: PLC program download invalidates NodeIds — wrong-tag reads that SUCCEED

Server restart invalidates every SubscriptionId (BadSubscriptionIdInvalid). After full program download the NodeId space can be rebuilt — numeric NodeIds reassigned → **cached-handle reads succeed and return the wrong tag's value** (weigher showing conveyor speed; no error, no bad quality). Detection: **read ServerStatus.StartTime on session activation; if changed, invalidate NodeId cache and re-browse.** Four independently-downloadable PLCs (ST101/ST201/ST301/Baader). Client↔gateway epoch doesn't cover gateway↔PLC boundary — this is a second, per-PLC epoch.
**Do:** per-PLC epoch on ServerStatus.StartTime; resolve by browse path/string NodeId, never cached numeric across session boundary; "ST201 was reprogrammed at 14:32, re-syncing" on link-status channel; tag-deleted = distinct "configuration error" state, not just bad quality. **Test:** restart one OPC UA server mid-session; separately change NodeId assignments — no stale-handle read may succeed.

## Theme 10: Operational/network hazards

- **Cert expiry:** OPC UA client certs 12–24 mo typical. Staged rotation (new cert 30 d out, trust stores 14 d, present at 7 d — OPC UA permits multiple valid certs). **Monitor days-to-expiry as a plant alarm** (gateway cert + every PLC's).
- **Duplicate IP:** intermittent connection instability that looks like a flaky app (113538, 81729). Weighers on hand-configured static 10.104.29.71–78 = exactly where the next contractor introduces a duplicate.
- **Endpoint security agents:** AV exclusions for gateway data dirs standing practice; agent auto-updates reboot machines (49362).
- **Windows Update:** no safe default; deliberate per-machine decision (8805). HMI desktops reboot on Patch Tuesday unless decided.
- **Wi-Fi roaming (future tablets):** client-driven; sticky clients "show bars but can't pull data"; forklift cages are Faraday cages; roaming = routine 2–10 s blackouts → reconnect must be cheap enough to run many times per shift without visible resync flash.

## Theme 11: Two UX findings worth arguing about

- **Grey-out may be worse than digit replacement for NUMBERS** (10059): a greyed "12.4 kg" still reads as 12.4 kg from 3 m in a wet bright room. For state indicators grey works; for numerics consider `--.-` + "last good 4 min ago". Consistency matters more than which option. Per-widget-type decision, not global.
- **Auto-logout must degrade to view-only, not a login screen** (FactoryTalk/PanelView pattern: revert to ViewOnly user, graphics stay). Operator mid-incident never faces a login prompt; wall display never stops displaying. Consider re-auth per privileged write (badge/PIN on the confirm dialog) — real audit trail with shared accounts, no lockout.

## Top 10 most likely to bite (ranked)

1. **jsonEncode throws on NaN/Inf → one bad analog blanks the whole plant HMI** (verified). Sanitize at OPC UA boundary + property tests.
2. **Gateway event-loop stall = synchronized false disconnect on all clients** (nightly VM snapshot). Lag monitor, off-isolate work, "I stalled" announcement, SIGSTOP test.
3. **Icelandic chars in PLC strings throw in utf8.decode** (verified). allowMalformed + per-server encoding + Icelandic fixtures.
4. **Silent write loss with confirming UI on touch panels** (IGN-2441). Read-back is the only confirmation.
5. **Dead subscription on live connection** (HA). Per-subscription seq/last-evaluated.
6. **Write outcome unknown after mid-flight disconnect.** Idempotency ids + outcome log + explicit UI state.
7. **Clock skew / no-RTC panels break freshness; Iceland hides TZ bugs.** Single-clock age, clock-sanity banner, TZ=Pacific/Chatham CI.
8. **Ghost sessions leak PLC monitored items → new clients can't subscribe weeks later.** Full teardown on heartbeat expiry, refcounted dedup, kill -9 ×200 test.
9. **NodeId invalidation after PLC download → plausible wrong numbers, no error.** Per-PLC epoch on ServerStatus.StartTime, browse-path resolution.
10. **Alarm storm on link restore + animation CPU collapse at peak alarm count.** Master-inhibit, on/off-delays, new-occurrence semantics, animation cap.

Honourable mentions: cert-expiry alarm; view-only auto-logout; digit-replacement for stale numerics; duplicate-IP detection on weigher range; soak-test rotating displays.

## Coverage gaps (follow-up candidates)
r/PLC, r/SCADA, plctalk.net direct (crawler-blocked); Grafana community on long-lived streaming; gateway disk-full post-mortems (only inference — check Timescale retention + log rotation regardless); Chrome background-tab throttling specifics (browser phase); screen burn-in; IGMP/multicast storms; MTU/jumbo frames.
