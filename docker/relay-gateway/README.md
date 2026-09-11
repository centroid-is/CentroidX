# `relay_gateway` is a test harness. It is not a deployable.

This directory used to hold a Dockerfile, a compose fragment and an example
config that built and ran `relay_gateway` at a plant. Phase 13 deleted all
four. Nothing in this repository builds `relay_gateway` into an image, and
nothing runs it at the plant.

The deletion is deliberate rather than a comment: a commented-out compose block
is a thing somebody uncomments at 2 a.m.

## The plant runs one process

`centroidx-backend` — `packages/tfc_dart/bin/main.dart` — is the plant's single
deployable. From Phase 13 onward it serves the relay WebSocket itself, from an
adapter over its own acquisition pipe. Its relay configuration lives in the
backend's own `stateman.json` world (`CENTROID_STATEMAN_FILE_PATH`), not in a
`gateway.json`, and it is **off by default**: a backend with no relay section
boots with the WebSocket off and says so in one log line.

## Why one and not two

The eight M2200 weighers accept exactly one TCP client each, so two processes
owning the plant is not a deployment choice — whichever process loses the race
loses the weighers.

## Where the harness is still used

- `packages/tfc_relay_local/test/` — the gateway composition is the reference
  the relay tests exercise end to end.
- `dart run tfc_relay_local:relay_gateway --help` — the usage text.

Started without `--harness` (or `CENTROIDX_RELAY_HARNESS=1`), the binary writes
a notice to stderr saying it is not the plant's deployable. It still runs; a
harness that has to be special-cased is a harness people stop using.

## Turning the relay on

The relay is **off until a `relay` section exists**. Add one to the file
`CENTROID_STATEMAN_FILE_PATH` already points at — the same file the backend
reads its OPC UA, Modbus and M2400 servers out of. There is no second config
file.

```json
{
  "opcua": [ … ],
  "modbus": [ … ],
  "jbtm": [ … ],

  "relay": {
    "port": 8443,
    "address": "0.0.0.0",
    "publisher_id": "centroidx-backend-svn",
    "allowed_origins": ["https://hmi.svn.local"],
    "tls": {
      "chain_path": "/etc/relay/chain.pem",
      "key_path": "/etc/relay/key.pem",
      "key_password": "…"
    },
    "credentials": {
      "source": "token_file",
      "token_file": "/run/secrets/relay-tokens.json"
    }
  }
}
```

### Every field

| Key | Type | Required | Absent means |
|---|---|---|---|
| the whole `relay` object | object | **no** | **the WebSocket is OFF.** This is the deployment-safety property: a plant backend upgraded to this binary behaves exactly as it did before |
| `port` | integer, 0–65535 | **yes** | refused. The underlying default is `0`, an ephemeral port, and a plant whose panels carry a fixed address would come up unreachable on a boot that reported no error. Write `"port": 0` if a drawn free port really is what is meant |
| `credentials` | object | **yes** | refused. The default would be an unauthenticated WebSocket on the plant LAN, arriving through a line somebody left out rather than a line somebody wrote |
| `credentials.source` | `"none"` \| `"token_file"` \| `"validator"` | **yes** | refused |
| `credentials.token_file` | string path | only when `source` is `token_file` | — |
| `address` | IP literal string | no | loopback. A hostname is refused: it would be resolved at bind time, possibly to an interface nobody meant to expose |
| `tls` | object | no | plaintext, deliberately and visibly — the boot line then says `TLS no` |
| `tls.chain_path` | string path | all-or-nothing with `key_path` | — |
| `tls.key_path` | string path | all-or-nothing with `chain_path` | — |
| `tls.key_password` | string | no | an unencrypted key. Never printed in any log line |
| `allowed_origins` | list of strings | no | the empty list, which is the cross-site-WebSocket-hijacking defence and not a gap |
| `publisher_id` | string | no | the key is omitted from the wire entirely |

**Any other key inside `relay`, `relay.tls` or `relay.credentials` is refused
by name.** `"prot": 8443` must not silently keep the default — a typo that
quietly reads as "off" is a plant running unserved for a week behind a green
log. A broken section refuses to boot and names the field, even when the relay
is switched off by the environment: otherwise the typo is discovered on the day
somebody flips the variable, which is the day it matters.

### The seven environment overrides

| Variable | Effect |
|---|---|
| `CENTROID_RELAY_ENABLED` | `0`/`false`/`no`/`off` forces the relay OFF even with a section present. `1`/`true`/`yes`/`on` is a no-op. Anything else is refused, naming the variable and the value. **It cannot invent a section**: with no `relay` key, `=1` is still off |
| `CENTROID_RELAY_PORT` | replaces `relay.port`; anything outside 0–65535 is refused |
| `CENTROID_RELAY_ADDRESS` | replaces `relay.address`; a hostname is refused |
| `CENTROID_RELAY_TLS_CHAIN` | replaces `relay.tls.chain_path` |
| `CENTROID_RELAY_TLS_KEY` | replaces `relay.tls.key_path` |
| `CENTROID_RELAY_TLS_KEY_PASSWORD` | replaces `relay.tls.key_password` |
| `CENTROID_RELAY_TOKEN_FILE` | supplies or replaces the token file. Over a `validator` deployment it is **refused** — that is the second spelling of two credential sources |

TLS is all-or-nothing *after* the overrides are applied: a chain from the
environment with no key anywhere is refused while the config is being read,
rather than at bind time where the symptom is a certificate error naming a file.

### The boot log lines

Exactly one line, every boot, whether the relay is on or off.

**OFF, no section** — the upgrade-safe default:

```
relay WebSocket is OFF: no `relay` section in /etc/centroid/stateman.json. This backend serves no WebSocket; add a `relay` section to turn it on.
```

**OFF, disabled by the environment:**

```
relay WebSocket is OFF: disabled by CENTROID_RELAY_ENABLED=0 (a `relay` section IS present in /etc/centroid/stateman.json).
```

**ON:**

```
relay WebSocket is ON: 0.0.0.0:8443, TLS yes, credentials token file /run/secrets/relay-tokens.json, 1 allowed origin (config: /etc/centroid/stateman.json)
```

followed, once the socket is actually bound, by:

```
relay WebSocket bound on port 8443
```

If the socket cannot be bound — an expired certificate, a port something else
already holds — the backend logs that at warning level and **keeps running the
plant**. The plant is the job; the WebSocket is a service on top of it, and a
backend that refuses to acquire because a certificate expired is a worse
outcome than a backend nobody can connect to.

### A change takes effect on restart

There is no relay config watcher. The `relay` section lives in the stateman
file, not in a database preference row, so a change to it is applied by
restarting `centroidx-backend` — exactly like a change to the OPC UA server
list. The container runs with `restart: unless-stopped`, so stopping it is
enough.

## What goes red if a build path comes back

`packages/tfc_relay_local/test/harness_only_test.dart` scans this directory
tree and fails if any file here names `relay_gateway` in a build or run
directive. This README is the one exemption, by name.
