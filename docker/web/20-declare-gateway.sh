#!/bin/sh
# Stamp the gateway address this deployment's browsers should dial.
#
# The bundle is generic and the station is not: one image serves every plant,
# and `CENTROIDX_GATEWAY_URL` is what makes a given container belong to a given
# backend. The page reads the declaration out of its own HTML at boot, so a
# browser that opens the address connects with nobody typing anything into
# Server Config.
#
# It is a *default*, not a pin: a transport row saved from Server Config lives
# in that browser and still wins, so somebody pointing their own tab at a bench
# gateway keeps that across a redeploy of this container.
set -eu

INDEX=/usr/share/nginx/html/index.html
URL="${CENTROIDX_GATEWAY_URL:-}"

if [ -z "$URL" ]; then
  # Loud, and not fatal. Serving the page is still better than refusing to
  # start: the page comes up on its own origin, reports "misconfigured" in the
  # banner, and Server Config is reachable — which is a screen somebody can act
  # on. A container that exits leaves a browser with a connection refused and
  # nothing to read.
  echo "centroidx-web: CENTROID_GATEWAY_URL is unset, so this container declares" >&2
  echo "centroidx-web: no gateway. Browsers will come up misconfigured and each" >&2
  echo "centroidx-web: one will need its address typed into Server Config." >&2
  exit 0
fi

# `wss://` only, and refused by name rather than served broken. A browser cannot
# pin a private CA, so a `ws://` declaration is a socket the client refuses at
# the field — and it would do so with the *station's* address in the message,
# which reads like a plant fault rather than the configuration mistake it is.
case "$URL" in
  wss://*) ;;
  *)
    echo "centroidx-web: CENTROIDX_GATEWAY_URL is \"$URL\"." >&2
    echo "centroidx-web: It must start with wss://. A browser cannot pin a" >&2
    echo "centroidx-web: private CA, so ws:// is refused by the client, and" >&2
    echo "centroidx-web: http:// or a bare host is not a socket address." >&2
    exit 1
    ;;
esac

# `"` and `<` would close the attribute and the tag; a value carrying either is
# a mistake that would otherwise become markup in every browser on the plant.
case "$URL" in
  *'"'*|*'<'*|*'>'*)
    echo "centroidx-web: CENTROIDX_GATEWAY_URL contains a quote or angle" >&2
    echo "centroidx-web: bracket, which cannot go in an HTML attribute." >&2
    exit 1
    ;;
esac

# Replaced, not appended: the template ships an inert placeholder, and a
# container restarted after an edit must not accumulate a second declaration
# that the page would then have to choose between.
sed -i "s|<meta name=\"centroidx-gateway\"[^>]*>|<meta name=\"centroidx-gateway\" content=\"$URL\">|" "$INDEX"

if ! grep -q "content=\"$URL\"" "$INDEX"; then
  echo "centroidx-web: could not write the declaration into $INDEX — the" >&2
  echo "centroidx-web: bundle has no centroidx-gateway placeholder, so it was" >&2
  echo "centroidx-web: built before the web client could read one." >&2
  exit 1
fi

echo "centroidx-web: declaring gateway $URL"
