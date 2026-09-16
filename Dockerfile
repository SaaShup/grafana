FROM grafana/grafana:12.4.11

USER root

# Static: identical for every deployment.
ENV GF_SERVER_SERVE_FROM_SUB_PATH=true \
    GF_METRICS_ENABLED=true \
    GF_AUTH_GENERIC_OAUTH_ENABLED=true \
    GF_AUTH_GENERIC_OAUTH_NAME=Keycloak \
    GF_AUTH_GENERIC_OAUTH_ALLOW_SIGN_UP=true \
    GF_AUTH_GENERIC_OAUTH_ALLOW_ASSIGN_GRAFANA_ADMIN=true \
    GF_AUTH_GENERIC_OAUTH_SKIP_ORG_ROLE_SYNC=false \
    GF_AUTH_GENERIC_OAUTH_SCOPES="openid email profile" \
    GF_AUTH_GENERIC_OAUTH_GROUPS_ATTRIBUTE_PATH=groups \
    GF_AUTH_GENERIC_OAUTH_LOGIN_ATTRIBUTE_PATH=preferred_username \
    GF_AUTH_GENERIC_OAUTH_EMAIL_ATTRIBUTE_PATH=email

# Defaulted, but overridable per deployment
ENV GF_SECURITY_ADMIN_USER=admin \
    KEYCLOAK_REALM=paashup \
    KEYCLOAK_ADMIN_GROUP=SaasHup-Admins \
    GF_AUTH_GENERIC_OAUTH_CLIENT_ID=grafana

# Required, no safe default
ENV BASE_DOMAIN="" \
    GF_SECURITY_ADMIN_PASSWORD="" \
    GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=""

# Optional: set to a Discord webhook URL to enable the "container down" alerts
ENV DISCORD_ALERT_WEBHOOK_URL=""

# Traefik / Prometheus discovery
LABEL traefik.enable="true" \
      traefik.docker.network="traefik" \
      traefik.http.routers.grafana.entrypoints="http" \
      traefik.http.services.grafana.loadbalancer.server.port="3000" \
      traefik.http.middlewares.force-https-header.headers.customrequestheaders.X-Forwarded-Proto="https" \
      traefik.http.routers.grafana.middlewares="force-https-header" \
      prometheus_address="grafana:3000" \
      prometheus_path="/dashboard/metrics" \
      prometheus_scrape="true"

COPY provisioning/ /etc/grafana/provisioning/
COPY dashboards/ /etc/grafana/dashboards/
COPY alerting/ /etc/grafana/alerting-templates/
COPY branding/ /tmp/branding/
COPY entrypoint.sh /entrypoint.sh

# SaaShup branding: overwrite Grafana's stock icons/logos with whatever files
# were dropped in branding/,by name.
RUN for f in /tmp/branding/*; do \
      [ -f "$f" ] || continue; \
      name=$(basename "$f"); \
      base="${name%.*}"; ext="${name##*.}"; \
      for dest in \
        "/usr/share/grafana/public/img/$name" \
        "/usr/share/grafana/public/build/img/$name" \
        /usr/share/grafana/public/build/static/img/"$base".*."$ext"; \
      do \
        [ -f "$dest" ] && cp "$f" "$dest"; \
      done; \
    done; \
    rm -rf /tmp/branding; \
    chmod +x /entrypoint.sh \
    && chown -R 472:472 /etc/grafana/provisioning /etc/grafana/dashboards /etc/grafana/alerting-templates

USER 472

ENTRYPOINT ["/entrypoint.sh"]
