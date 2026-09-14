FROM grafana/grafana:12.4

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

# Traefik / Prometheus discovery

LABEL traefik.enable="true" \
      traefik.docker.network="traefik" \
      traefik.http.routers.grafana.entrypoints="http" \
      traefik.http.services.grafana.loadbalancer.server.port="3000" \
      traefik.http.middlewares.force-https-header.headers.customrequestheaders.X-Forwarded-Proto="https" \
      traefik.http.middlewares.force-https-header.headers.customrequestheaders.X-Forwarded-Port="443" \
      traefik.http.routers.grafana.middlewares="force-https-header" \
      prometheus_address="grafana:3000" \
      prometheus_path="/dashboard/metrics" \
      prometheus_scrape="true"

COPY provisioning/ /etc/grafana/provisioning/
COPY dashboards/ /etc/grafana/dashboards/
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh \
    && chown -R 472:472 /etc/grafana/provisioning /etc/grafana/dashboards

USER 472

ENTRYPOINT ["/entrypoint.sh"]
