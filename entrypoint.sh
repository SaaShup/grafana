#!/usr/bin/env sh
#
# Thin wrapper around the grafana/grafana entrypoint (/run.sh): runs
# at container start so every BASE_DOMAIN-derived variable (root url,
# Keycloak endpoint URLs, ...) gets recomputed on each run, not just
# once at image build time. 

set -eu

require() {
  var_name="$1"
  eval "value=\${${var_name}:-}"
  if [ -z "$value" ]; then
    echo "entrypoint: \$${var_name} is required" >&2
    exit 1
  fi
}

require BASE_DOMAIN
require GF_SECURITY_ADMIN_PASSWORD
require GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET

: "${KEYCLOAK_REALM:=paashup}"
: "${KEYCLOAK_ADMIN_GROUP:=SaasHup-Admins}"
: "${GF_SECURITY_ADMIN_USER:=admin}"
: "${GF_AUTH_GENERIC_OAUTH_CLIENT_ID:=grafana}"
: "${BASE_SCHEME:=https}"

KEYCLOAK_ISSUER="${BASE_SCHEME}://${BASE_DOMAIN}/auth/realms/${KEYCLOAK_REALM}"

: "${GF_SERVER_DOMAIN:=${BASE_DOMAIN}}"
: "${GF_SERVER_ROOT_URL:=${BASE_SCHEME}://${BASE_DOMAIN}/dashboard/}"
: "${GF_AUTH_GENERIC_OAUTH_AUTH_URL:=${KEYCLOAK_ISSUER}/protocol/openid-connect/auth}"
: "${GF_AUTH_GENERIC_OAUTH_TOKEN_URL:=${KEYCLOAK_ISSUER}/protocol/openid-connect/token}"
: "${GF_AUTH_GENERIC_OAUTH_API_URL:=${KEYCLOAK_ISSUER}/protocol/openid-connect/userinfo}"
: "${GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH:=contains(groups, '${KEYCLOAK_ADMIN_GROUP}') && 'GrafanaAdmin' || 'Viewer'}"

: "${PROM_URL:=${BASE_SCHEME}://${BASE_DOMAIN}/monitoring}"
: "${PROM_BASIC_AUTH_USER:=${GF_SECURITY_ADMIN_USER}}"
: "${PROM_BASIC_AUTH_PASSWORD:=${GF_SECURITY_ADMIN_PASSWORD}}"

export GF_SERVER_DOMAIN GF_SERVER_ROOT_URL \
  GF_AUTH_GENERIC_OAUTH_AUTH_URL GF_AUTH_GENERIC_OAUTH_TOKEN_URL GF_AUTH_GENERIC_OAUTH_API_URL \
  GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH GF_SECURITY_ADMIN_USER GF_AUTH_GENERIC_OAUTH_CLIENT_ID \
  PROM_URL PROM_BASIC_AUTH_USER PROM_BASIC_AUTH_PASSWORD

exec /run.sh "$@"
