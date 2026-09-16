# `centroid-web` — the browser client

Static files and nginx. The bundle is `flutter build web -t lib/main_web.dart`,
built by the `Web Bundle` job in `.github/workflows/centroid-hmi.yml` and copied
into this context by `Web Image`; the runtime holds no PLC session, no database
and no secrets, because a browser is a client of the gateway exactly as a panel
in gateway mode is.

## The one setting

```yaml
centroidx-web:
  image: ghcr.io/centroid-is/centroid-web:latest
  environment:
    CENTROIDX_GATEWAY_URL: wss://10.104.60.84:9443
  ports: ["8090:80"]
```

`20-declare-gateway.sh` stamps that address into `index.html` at container
start, and the page reads it at boot. That is the whole of the configuration,
and it is what makes a generic image belong to one plant.

Three things it has to be:

- **`wss://`.** A browser cannot pin a private CA, so the client refuses `ws://`
  by name. The entrypoint refuses it too, at start, where the message can say so
  rather than leaving every browser reporting a plant fault.
- **An address a browser can reach** — the station's own IP or DNS name, never
  the compose service name, which resolves only inside the compose network.
- **Named in the relay's `allowed_origins`.** The gateway answers a WebSocket
  handshake from an unlisted origin with `403`, which is the
  cross-site-hijacking defence and not a gap. Add `http://<station>:8090` to
  `relay.allowed_origins` in `tfc_config/stateman.json`.

Unset it and the container still serves: browsers come up on their own origin,
report "misconfigured" in the banner, and Server Config stays reachable so an
address can be typed in per browser. Worse, not broken — which is why the
entrypoint warns rather than exits.

## Precedence, so nobody is surprised

1. a transport row saved from Server Config, which lives in that browser;
2. this declaration;
3. the origin the page was served from.

So a redeploy with a new address does **not** move a browser somebody pointed
somewhere else by hand, and a bundle served by a host that knows nothing of the
declaration behaves exactly as it did before there was one — the template ships
`content="$CENTROIDX_GATEWAY"`, and that exact string means "no declaration".

## The certificate

The relay's leaf is signed by the CA minted with
`dart run tfc_relay_server:relay_certs`. A browser trusts nothing by default, so
until that CA is in the machine's or the browser's trust store, the page loads
and the socket fails. The page reports it; the fix is trust, not configuration.
