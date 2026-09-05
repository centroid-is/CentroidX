# The relay gateway, containerised

One process reads the plant's PLCs and serves every panel over one WebSocket.
This directory is how it gets onto a rig: a Dockerfile that builds it (the rig
has no Dart toolchain, so the build happens in the image), a compose fragment
that runs it beside an existing stack, and an example config.

Two binaries come out of the image:

| Path | What it is |
| --- | --- |
| `/app/bin/relay_gateway` | the gateway process — the container's `CMD` |
| `/usr/local/bin/relay_certs` | the CA/leaf minting tool the TLS listener needs |

`relay_certs` is in the same image on purpose. The PKI it writes has to land on
the volume the gateway reads, and it needs no `openssl` on the host — the
certificate bytes come out of `tfc_relay_server/lib/src/tls/mint.dart`, the same
function every TLS test in the repository mints through.

---

## 1. Build

```sh
# from the repository root
docker compose -f docker/relay-gateway/docker-compose.yml build
```

or directly:

```sh
docker build -f docker/relay-gateway/Dockerfile -t centroidx-relay-gateway:local .
```

The build context is the repository root; `Dockerfile.dockerignore` prunes it
down to `packages/`. Nearly all of the time goes into one step: `dart build cli`
fires `open62541_dart`'s build hook, which compiles open62541 and mbedTLS from
source as native assets. That is why the builder stage installs `cmake`,
`build-essential`, `python3` and `git` for a program with no C in it.

Measured cold, no cache: **4 min 30 s** for `linux/amd64` on an M-series Mac
under emulation. The rig builds natively and should be at least as fast. The
finished image is **42 MB**.

Layer caching is arranged so an edit to a `.dart` file does not re-resolve pub
or re-download the pinned `open62541` / `postgres` git dependencies — but it
*does* re-run the native-asset build. There is no way around that; the hook runs
as part of the compile.

### Cross-building on an Apple Silicon Mac

The rig is `linux/amd64`. On an arm64 Mac:

```sh
docker buildx build --platform linux/amd64 \
  -f docker/relay-gateway/Dockerfile \
  -t centroidx-relay-gateway:amd64 --load .
```

This runs the whole mbedTLS compile under emulation and still finishes in about
four and a half minutes, so it is a perfectly usable way to produce a rig image
from a laptop:

```sh
docker save centroidx-relay-gateway:amd64 | ssh hq-skjar 'docker load'
```

Building on the rig itself is simpler, and is what the compose fragment does by
default.

---

## 2. Mint the certificates

Two runs, in order. The root is provisioned once (ten years) to every panel; the
leaf is re-issued yearly, which the gateway's days-to-expiry health key turns
into a Tuesday ticket rather than an outage.

```sh
CONFIG=/home/centroid/relay_config          # the host dir bind-mounted as /config
mkdir -p "$CONFIG/pki"

docker run --rm -v "$CONFIG:/config" centroidx-relay-gateway:local \
  relay_certs --ca --out /config/pki

docker run --rm -v "$CONFIG:/config" centroidx-relay-gateway:local \
  relay_certs --leaf \
    --ca-cert /config/pki/ca.pem \
    --ca-key  /config/pki/ca-key.pem \
    --san 10.50.10.11 \
    --san relay.svn.local \
    --days 365 \
    --out /config/pki
```

Note the mount has **no `:ro`** here — this is the one command that writes into
the config directory. The compose service mounts it read-only.

`--san` matters: the panels dial an address, and a leaf without that address in
its SAN list fails the handshake no matter how correct the CA chain is. A value
that parses as an IP is written as an `iPAddress` SAN, anything else as a DNS
name. Repeat the flag for each.

Copy `pki/ca.pem` — and only `ca.pem` — to every panel that will connect. The
two `*-key.pem` files never leave the rig.

---

## 3. Configuration

Copy `gateway.example.json` to `<config dir>/gateway.json` and fill it in. The
example is annotated inline (`_comment` keys, which the parser ignores) and the
authoritative shape is `packages/tfc_relay_local/lib/src/gateway_config.dart`.

### What the operator must fill in

| Field | What it is | Where to get it |
| --- | --- | --- |
| `links[].endpoint` | `opc.tcp://<host>:4840` per PLC | the `opcua[].endpoint` entries in the rig's `stateman.json` |
| `links[].alias` | the link's *name*: health keys (`PIPE.upstream.<alias>.*`) and status notifications use it | pick something short and real (`ST101`, `RIG`) — it can never be null |
| `links[].answers_to` | which keymapping `server_alias` this link serves | the `opcua[].server_alias` in the rig's `stateman.json`. **If it is `null` there — the single-server era's spelling, and what the live plant file has on every entry — you must write `"answers_to": null` here.** Omitting the field makes the link answer to its own `alias`, and every `server_alias: null` key reads `errorConfig` (q=770) on every panel, with the session connected and nothing in the log (RIG-TEST-FINDINGS.md F1) |
| `links[].username` / `.password` | the OPC UA **user token** | `opcua[].username` / `.password` in the rig's `stateman.json` — see below |
| `links[].certificate_path` / `.private_key_path` | the OPC UA **application certificate**, which is what selects an encrypted channel | `opcua[].ssl_cert` / `.ssl_key` in the same file, converted to DER — see below |
| `key_mappings` | container path to the plant's key→node map | export it out of the database — see below |
| `collection.endpoint.password` | the Postgres password | the running backend's environment — see below |

Everything else in the example is a working default.

### OPC UA credentials: the certificate is not an alternative to the password

The two fields do different jobs, and on a hardened server you need **both**.

- `certificate_path` + `private_key_path` select the **secure channel**. The
  gateway asks for `SIGNANDENCRYPT` **only when a certificate is present**, and
  for `NONE` when it is not — `_opcUaClient` in `gateway_config.dart` computes
  `hasUser` and `hasCert` independently and derives the security mode from
  `hasCert` alone.
- `username` + `password` are the **user token**, passed independently of the
  channel.

So a server that offers no `None` endpoint — this plant's, and any hardened one
— rejects a username-only config. What that looks like:

```
error/client   No suitable endpoint found
error/client   SecureChannel must be connected to send request
error/client   SecureChannel must be connected to send request
   … once a second, for ever
```

That message names neither the credentials nor the security mode, which is why
it is worth writing down: **the fix is to add the certificate pair**, not to
re-check the password. Found in the field on the first SVN deployment.

Certificate without username is a legitimate combination — an encrypted channel
with an anonymous user token — but only if the server admits anonymous users.
Neither pair at all is an anonymous, unencrypted session.

### Convert the OPC UA credentials to DER

The rig keeps its OPC UA client certificate and key in `stateman.json` as
**base64-encoded PEM**. The gateway reads **DER** file paths. Nothing in either
format announces itself, so this is a required, easy-to-miss step:

```sh
CONFIG=/home/centroid/relay_config
mkdir -p "$CONFIG/opcua"

# 1. out of stateman.json, un-base64'd — this yields PEM
jq -r '.opcua[0].ssl_cert' /home/centroid/tfc_config/stateman.json \
  | base64 -d > "$CONFIG/opcua/client-cert.pem"
jq -r '.opcua[0].ssl_key'  /home/centroid/tfc_config/stateman.json \
  | base64 -d > "$CONFIG/opcua/client-key.pem"

# 2. PEM -> DER, which is what gateway.json points at
openssl x509 -in "$CONFIG/opcua/client-cert.pem" -outform der \
  -out "$CONFIG/opcua/client-cert.der"
openssl pkey -in "$CONFIG/opcua/client-key.pem" -outform der \
  -out "$CONFIG/opcua/client-key.der"

rm "$CONFIG/opcua/client-cert.pem" "$CONFIG/opcua/client-key.pem"
chmod 600 "$CONFIG/opcua/client-key.der"
```

Adjust the `jq` index if the PLC you want is not `opcua[0]`; match on
`server_alias` rather than position when there is more than one.

### Where the real credentials live — paths, not values

Nothing in this repository holds the plant's credentials, and
`gateway.example.json` must never grow one. On the rig they are:

- **OPC UA username/password** — `/home/centroid/tfc_config/stateman.json`, in
  the `opcua[]` array as `username` and `password`. That file is bind-mounted
  into `centroidx-backend` as `/config/stateman.json`.
- **OPC UA client certificate and key** — the same file, as `opcua[].ssl_cert`
  and `opcua[].ssl_key`, base64-encoded PEM. Converted to DER by the step
  above; the DER lands in `<config dir>/opcua/`.
- **Postgres password** — the `CENTROID_PGPASSWORD` environment variable on the
  running `centroidx-backend` container, which is set from the rig's backend
  compose file. Read it with
  `docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' centroidx-backend | grep PGPASSWORD`.
- **The gateway's own TLS private key** — `<config dir>/pki/leaf-key.pem`,
  written by `relay_certs` in step 2. It is generated on the rig and does not
  come from anywhere else.
- **Panel tokens** — `<config dir>/tokens.json`, which you write. There is no
  existing source; the gateway's auth is new.

`gateway.json` itself ends up holding the OPC UA password and the Postgres
password in plaintext. That is what `TlsConfig` and `AuthConfig` exist to avoid
for *their* secrets — both hold paths and refuse to hold bytes — and the two
upstream credentials are the exception the config format still has. Keep the
file `0600`, and keep it out of git.

### The keymappings file

The backend reads its keymappings from the database, not from a file; the
gateway wants a file. Export it:

```sh
docker exec -i timescaledb psql -U centroid -d hmi -At \
  -c "SELECT value FROM flutter_preferences WHERE key = 'key_mappings'" \
  > /home/centroid/relay_config/keymappings.json
```

`{"nodes": {}}` is a valid empty mapping if you only want to prove the port
answers on a first boot.

### File modes

The container runs as uid **1000** (`gateway`), fixed so a host `chown` can name
it. Two files are checked:

```sh
sudo chown -R 1000:1000 /home/centroid/relay_config
sudo chmod 600 /home/centroid/relay_config/tokens.json \
               /home/centroid/relay_config/pki/*-key.pem
```

`FileTokenValidator` **refuses to load** a token file that any group or other
can read (`file_token_validator.dart:270`) — that is a hard failure at start,
not a warning.

### The `tokens.json` shape

```json
{
  "tokens": {
    "<a long random string>": { "stationId": "st101-panel", "role": "operate" },
    "<another>":              { "stationId": "office-view", "role": "view"    }
  }
}
```

Omit the `server.auth` block entirely and every peer that can reach the port
gets `operate` rights. The gateway logs a loud `ERROR` line at bind when TLS or
the token file is missing; it starts anyway, because "behind a firewall on a
segmented network" is a legitimate deployment it cannot detect.

### `sslmode=require`

The rig's TimescaleDB runs `ssl=on` with a self-signed certificate. Set
`collection.ssl_mode` to `"require"`. The three modes the sink accepts are
`disable`, `require` and `verifyFull` — the list is closed so that a typo cannot
silently become `disable` and put the historian credential on the wire in clear.

`verifyFull` would need the Postgres server certificate in the image's trust
store; the runtime image installs `ca-certificates` but the rig's Postgres cert
is self-signed and not in it, so `require` is the correct answer there.

### `table_prefix` — leave it as `gw_`

While the app's collector is still running, the gateway must write into a
disjoint table namespace. The two writers otherwise pick byte-identical table
names, the tables have no primary key so Postgres accepts both without a
murmur, the row count silently doubles, and the two retention policies
uninstall each other at every start. Emptying the prefix is refused unless
`sole_writer` is also set — a deliberate two-field act, after the app's
collector has been stopped. `collection_config.dart` carries the full argument
and the cutover procedure.

---

## 4. Run it beside the existing stack

The fragment does **not** define `timescaledb` and does not touch
`docker/backend/docker-compose.yml`. It joins an **external** network — the one
the running `timescaledb` is already on — so the two containers reach each other
by service name.

```sh
cd /path/to/CentroidX

# 1. which network is timescaledb on?
docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' timescaledb

# 2. tell compose, along with where the config lives
cat > docker/relay-gateway/.env <<'EOF'
GATEWAY_DATA_NET=centroid_default
GATEWAY_CONFIG_DIR=/home/centroid/relay_config
GATEWAY_PORT=9443
GATEWAY_WSS_PORT=9443
EOF

# 3. up
docker compose -f docker/relay-gateway/docker-compose.yml up -d --build
```

Step 1 is not optional: compose prefixes network names with the project name, so
what a compose file calls `data-net` is really `<project>_data-net`, and the
project name is whatever the directory happened to be called. On the SVN rig the
answer is neither — it is **`centroid_default`**, the default network of a
project called `centroid`, which is the default the compose file now carries.
Run the inspect anyway; the next rig will differ again.

`GATEWAY_PORT` is the port **inside** the container and must equal `server.port`
in `gateway.json`; `GATEWAY_WSS_PORT` is the host port. Both default to **9443**
rather than 8443 because **8443 is already published by `docker-update` on the
SVN rig** — a reader following an earlier draft of this file verbatim got a port
clash.

To merge the service into the rig's existing compose file by hand instead: copy
the `centroidx-relay-gateway:` block into that file's `services:` map, change
`networks: [data-net-external]` to that file's own network name, and drop this
file's `networks:` block.

---

## 5. Check it is serving

```sh
docker logs -f centroidx-relay-gateway
```

The two lines that matter, in order:

```
INFO  upstream ST101: opcua opc.tcp://10.50.10.10:4840
INFO  serving on 0.0.0.0:9443, TLS on
```

`serving on ...` is the line to look for, and it comes **last**: the gateway
connects its links before it binds the socket, so a PLC that is switched off
delays the port answering by its full connection timeout. Two links pointed at
black-hole addresses measured ~14 s. Until then the container is up, the port is
closed, and the log is a wall of `SecureChannel must be connected` from the OPC
UA client — that is the link retrying, not a fault in the gateway.

**But if that wall never stops, it is not patience you need.** A
`SecureChannel must be connected` that repeats once a second indefinitely,
especially preceded by `No suitable endpoint found`, is the missing-certificate
misconfiguration above — see "the certificate is not an alternative to the
password". The distinguishing question is whether `serving on ...` ever
appears: it does eventually even with every link down, so a log with no
`serving` line at all is a bind problem, and a log *with* one and a continuing
wall is a link problem.

That line also reports the port it *actually*
bound, which is the check that matters when `server.port` was left out — a
missing `port` binds an **ephemeral** one, and the panels come up unable to find
the gateway on a boot that reported no error.

Then prove the socket from outside:

```sh
# plaintext
curl -i --http1.1 -N \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  http://10.50.10.11:9443/

# TLS, verified against the CA you minted
curl -i --http1.1 -N --cacert pki/ca.pem \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  https://10.50.10.11:9443/
```

`HTTP/1.1 101 Switching Protocols` is the answer. Any other status, or a TLS
error, and the gateway is up but not reachable as a panel would reach it.

If collection is on, one more line appears once the runner has registered its
tables — deliberately *after* the socket exists, so panels never wait on a slow
database:

```
INFO  collecting 431 keys into "gw_"-prefixed tables (0 rejected, ...)
```

And the writer shows up in Postgres under its own name:

```sh
docker exec -it timescaledb psql -U centroid -d hmi \
  -c "SELECT application_name, count(*) FROM pg_stat_activity GROUP BY 1"
```

The app's collector is `tfc_dart`; the gateway is
`centroidx-gateway-collector-<publisher_id>`.

---

## Two sessions to the same PLC

The gateway opens **its own OPC UA session** to the plant, alongside the one
`centroidx-backend` already holds. That is fine: OPC UA servers multiplex
sessions, and the two will each get their own subscriptions and their own
monitored items. Expect the PLC's session count to go up by one per gateway
link, and check that against the server's configured maximum before deploying to
a plant with a tight limit.

**This is not true of the M2200 weighers.** Each accepts exactly one TCP client,
which is why the plant runs a relay in front of them at all — a gateway that
opened its own weigher connection while the backend held one would take the
weighers away from whichever process lost the race. The same is true of the
UMAS/Modbus links to the extent a given device limits concurrent connections.

That asymmetry is the reason the end state is **one process, not two**: the
gateway is meant to replace the backend's plant side rather than run permanently
beside it. Running both is a transition state that works for OPC UA links, and
only for OPC UA links. Do not add `m2400` links to `gateway.json` while
`centroidx-backend` is still running.

---

## Files

| File | Purpose |
| --- | --- |
| `Dockerfile` | two stages: build both binaries, then a slim runtime |
| `Dockerfile.dockerignore` | prunes the context to `packages/`; scoped to this Dockerfile so the backend and frontend builds are unaffected |
| `docker-compose.yml` | the service, on an external network — merge or run standalone |
| `gateway.example.json` | annotated example, placeholders only |
