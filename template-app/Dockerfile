# Placeholder — replace with your app's Dockerfile. Contract: linux/amd64,
# listen on the manifest port, answer the manifest healthcheck with 200
# within 30s, log to stdout, run unprivileged.
#
# nginx-unprivileged already runs as a non-root user and listens on 8080,
# matching this template's app-manifest.yaml (port: 8080, healthcheck: /healthz).
FROM nginxinc/nginx-unprivileged:alpine

# Build-time writes need root; the base image's default user can't write here.
USER root
RUN echo "ok" > /usr/share/nginx/html/healthz \
    && echo "hello from flightdeck" > /usr/share/nginx/html/index.html

# Explicit non-root user: the Trivy gate (DS002, HIGH) checks the Dockerfile
# itself and can't see that the base image already switches users.
USER nginx

EXPOSE 8080
