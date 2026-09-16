# The browser client: the eight routes of `docs/web-client-scope.md`, served as
# static files to any browser on the plant network.
#
# It holds no PLC session, no database and no secrets — it is a client of the
# gateway exactly as a panel in gateway mode is, and everything it shows comes
# over one `wss://` socket. So the image is nginx plus a bundle, and the only
# thing that makes one deployment differ from another is the address it
# declares (see `20-declare-gateway.sh`).
#
# The bundle is built in CI and handed to this context, the way
# `docker/frontend` takes the eLinux bundle: `flutter build web` needs the whole
# Flutter SDK and a pub cache, and baking that into an image that ships nginx
# would be a 2 GB build stage to produce 51 MB of static files that the workflow
# already produces for the artifact.
FROM nginx:alpine

# Overridable so a local `docker build` can point at a bundle built by hand;
# CI downloads the artifact to `docker/web/bundle` and takes the default.
ARG APP_BUNDLE=bundle

COPY ${APP_BUNDLE} /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf

# nginx:alpine runs every executable in this directory before starting the
# server, which is the seam the gateway declaration needs: the address is a
# per-station value, so it is applied at container start rather than at build
# time. One image serves every plant.
COPY 20-declare-gateway.sh /docker-entrypoint.d/20-declare-gateway.sh
RUN chmod +x /docker-entrypoint.d/20-declare-gateway.sh

EXPOSE 80
