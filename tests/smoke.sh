#!/usr/bin/env bash
#
# Smoke tests for the image: builds it, boots it with a few env combinations
# and checks through the Grafana API that the provisioning (datasource,
# dashboards, alerting), the entrypoint.sh overrides and the branding all
# made it in. Meant to catch a grafana/grafana bump (Renovate) silently
# breaking something.
#
# Needs docker, curl and jq. Usage: tests/smoke.sh  (IMAGE=... to skip the build)

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMAGE="${IMAGE:-}"
CONTAINER=grafana-smoke-$$
NETWORK=grafana-smoke-$$
# an empty Prometheus so alert rules really evaluate (a broken rule only shows up there)
PROMETHEUS_IMAGE=prom/prometheus:v3.5.0
FAILURES=0

pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

# check <description> <actual> <expected>
check() {
  if [ "$2" = "$3" ]; then
    pass "$1"
  else
    fail "$1"
    printf '      expected: %s\n      actual:   %s\n' "$3" "$2"
  fi
}

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap 'cleanup; docker rm -f "$NETWORK-prometheus" >/dev/null 2>&1; docker network rm "$NETWORK" >/dev/null 2>&1 || true' EXIT

# start <env args...>: boots the image and waits for /api/health
start() {
  cleanup
  docker run -d --name "$CONTAINER" --network "$NETWORK" -p 127.0.0.1::3000 "$@" "$IMAGE" >/dev/null
  BASE="http://$(docker port "$CONTAINER" 3000/tcp | head -n1)/dashboard"
  for _ in $(seq 90); do
    if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" != true ]; then
      docker logs "$CONTAINER" 2>&1 | tail -n 30
      fail "container exited during startup"
      return 1
    fi
    curl -fs "$BASE/api/health" >/dev/null && { pass "container started"; return 0; }
    sleep 2
  done
  docker logs "$CONTAINER" 2>&1 | tail -n 30
  fail "grafana not healthy after 180s"
  return 1
}

# api <user:password> <path>
api() { curl -fsS -u "$1" "$BASE/api/$2"; }

sha() { sha256sum | cut -d' ' -f1; }

check_dashboards() {
  local auth="$1" expected actual
  # invalid files are already reported by the static check
  expected=$(for f in "$ROOT"/dashboards/*.json; do jq -r .title "$f" 2>/dev/null || true; done | sort)
  actual=$(api "$auth" 'search?type=dash-db' | jq -r '.[].title' | sort)
  check "all dashboards provisioned ($(echo "$expected" | wc -l))" "$actual" "$expected"
}

check_branding() {
  local f name base ext want paths p
  for f in "$ROOT"/branding/*; do
    name=$(basename "$f"); base="${name%.*}"; ext="${name##*.}"
    want=$(sha < "$f")
    # same lookup as the Dockerfile
    paths=$(docker exec "$CONTAINER" sh -c "cd /usr/share/grafana && ls public/img/$name public/build/img/$name public/build/static/img/$base.*.$ext 2>/dev/null" || true)
    if [ -z "$paths" ]; then
      fail "branding: $name has no stock file to replace anymore (renamed upstream?)"
      continue
    fi
    for p in $paths; do
      check "branding: $p served" "$(curl -fsS "$BASE/$p" | sha)" "$want"
    done
  done
}

check_no_provisioning_errors() {
  local errors
  errors=$(docker logs "$CONTAINER" 2>&1 | grep -E 'logger=provisioning\S* .*level=error' || true)
  check "no provisioning errors in logs" "$errors" ""
}

echo "== Static: dashboards only use the \${datasource} variable"
for f in "$ROOT"/dashboards/*.json; do
  jq empty "$f" 2>/dev/null || { fail "$(basename "$f"): invalid JSON"; continue; }
  bad=$(jq -r '[.. | objects | .datasource? // empty | if type == "object" then .uid else . end
                | select(. != "${datasource}" and . != "-- Grafana --" and . != "grafana")] | unique | join(", ")' "$f")
  check "$(basename "$f")" "$bad" ""
done

if [ -z "$IMAGE" ]; then
  IMAGE=saashup-grafana:smoke
  echo "== Building $IMAGE"
  docker build -q -t "$IMAGE" "$ROOT" >/dev/null
fi
docker network create "$NETWORK" >/dev/null
docker run -d --name "$NETWORK-prometheus" --network "$NETWORK" --network-alias prometheus "$PROMETHEUS_IMAGE" >/dev/null

echo "== Missing required variables make the container exit"
REQUIRED=(BASE_DOMAIN=paashup.test GF_SECURITY_ADMIN_PASSWORD=smoke-pass GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=smoke-secret)
for missing in "${REQUIRED[@]}"; do
  args=()
  for kv in "${REQUIRED[@]}"; do [ "$kv" = "$missing" ] || args+=(-e "$kv"); done
  if out=$(timeout 60 docker run --rm "${args[@]}" "$IMAGE" 2>&1); then
    fail "${missing%%=*} missing: container did not fail"
  else
    check "${missing%%=*} missing: exits with an error" "$(echo "$out" | grep -c "${missing%%=*} is required")" 1
  fi
done

echo "== Defaults (required variables only)"
if start -e BASE_DOMAIN=paashup.test -e GF_SECURITY_ADMIN_PASSWORD=smoke-pass -e GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=smoke-secret; then
  AUTH=admin:smoke-pass
  settings=$(api $AUTH admin/settings)
  check "root_url" "$(jq -r .server.root_url <<<"$settings")" "https://paashup.test/dashboard/"
  check "serve_from_sub_path" "$(jq -r .server.serve_from_sub_path <<<"$settings")" "true"
  check "oauth enabled" "$(jq -r '.["auth.generic_oauth"].enabled' <<<"$settings")" "true"
  check "oauth client_id" "$(jq -r '.["auth.generic_oauth"].client_id' <<<"$settings")" "grafana"
  check "oauth auth_url (realm paashup)" "$(jq -r '.["auth.generic_oauth"].auth_url' <<<"$settings")" \
    "https://paashup.test/auth/realms/paashup/protocol/openid-connect/auth"
  check "oauth token_url" "$(jq -r '.["auth.generic_oauth"].token_url' <<<"$settings")" \
    "https://paashup.test/auth/realms/paashup/protocol/openid-connect/token"
  check "oauth admin group" "$(jq -r '.["auth.generic_oauth"].role_attribute_path' <<<"$settings")" \
    "contains(groups, 'SaasHup-Admins') && 'GrafanaAdmin' || 'Viewer'"

  ds=$(api $AUTH datasources/uid/paashup-prometheus)
  check "datasource url" "$(jq -r .url <<<"$ds")" "https://paashup.test/monitoring"
  check "datasource is default" "$(jq -r .isDefault <<<"$ds")" "true"
  check "datasource basic auth user" "$(jq -r .basicAuthUser <<<"$ds")" "admin"
  check "datasource basic auth password set" "$(jq -r .secureJsonFields.basicAuthPassword <<<"$ds")" "true"

  check_dashboards $AUTH
  check "no alerting without DISCORD_ALERT_WEBHOOK_URL" "$(api $AUTH v1/provisioning/alert-rules | jq length)" "0"
  check_branding
  sleep 10 # the background plugin installer starts a few seconds after the API is up
  check "no bundled plugin updated at startup" \
    "$(docker logs "$CONTAINER" 2>&1 | grep -o 'msg="Updating plugin" pluginId=\S*' || true)" ""
  check_no_provisioning_errors
fi

echo "== Custom variables + Discord alerting"
if start -e BASE_DOMAIN=custom.test -e GF_SECURITY_ADMIN_PASSWORD=smoke-pass -e GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=smoke-secret \
  -e BASE_SCHEME=http -e GF_SECURITY_ADMIN_USER=root -e KEYCLOAK_REALM=custom-realm -e KEYCLOAK_ADMIN_GROUP=Custom-Admins \
  -e GF_AUTH_GENERIC_OAUTH_CLIENT_ID=grafana-custom -e PROM_URL=http://prometheus:9090 -e PROM_BASIC_AUTH_USER=promuser \
  -e DISCORD_ALERT_WEBHOOK_URL=http://127.0.0.1:9/hook -e ALERTING_INTERVAL=10s; then
  AUTH=root:smoke-pass
  settings=$(api $AUTH admin/settings)
  check "root_url (BASE_SCHEME=http)" "$(jq -r .server.root_url <<<"$settings")" "http://custom.test/dashboard/"
  check "oauth client_id" "$(jq -r '.["auth.generic_oauth"].client_id' <<<"$settings")" "grafana-custom"
  check "oauth auth_url (custom realm)" "$(jq -r '.["auth.generic_oauth"].auth_url' <<<"$settings")" \
    "http://custom.test/auth/realms/custom-realm/protocol/openid-connect/auth"
  check "oauth admin group" "$(jq -r '.["auth.generic_oauth"].role_attribute_path' <<<"$settings")" \
    "contains(groups, 'Custom-Admins') && 'GrafanaAdmin' || 'Viewer'"

  ds=$(api $AUTH datasources/uid/paashup-prometheus)
  check "datasource url (PROM_URL)" "$(jq -r .url <<<"$ds")" "http://prometheus:9090"
  check "datasource basic auth user" "$(jq -r .basicAuthUser <<<"$ds")" "promuser"

  check_dashboards $AUTH
  check "alert rules provisioned" "$(api $AUTH v1/provisioning/alert-rules | jq -r '.[].uid' | sort)" \
    "$(sed -n 's/^ *- uid: *//p' "$ROOT/alerting/rules.yaml" | sort)"
  check "contact points use the webhook" "$(api $AUTH v1/provisioning/contact-points | jq -r '.[].settings.url' | sort -u)" \
    "http://127.0.0.1:9/hook"
  check "rule groups use ALERTING_INTERVAL" \
    "$(api $AUTH prometheus/grafana/api/v1/rules | jq -r '[.data.groups[].interval] | unique | join(",")')" "10"
  check "info alerts routed to their own contact point" \
    "$(api $AUTH v1/provisioning/policies | jq -r '.routes[] | select(.object_matchers == [["severity","=","info"]]) | .receiver')" \
    "Discord - Paashup Info"

  ds_health=""
  for _ in $(seq 30); do
    ds_health=$(api $AUTH datasources/uid/paashup-prometheus/health 2>/dev/null | jq -r .status) && [ "$ds_health" = OK ] && break
    sleep 2
  done
  check "datasource reachable" "$ds_health" "OK"
  # judge the first full round after the datasource answers (every 10s, see ALERTING_INTERVAL)
  since=$(date -u +%Y-%m-%dT%H:%M:%S)
  for _ in $(seq 15); do
    rules=$(api $AUTH prometheus/grafana/api/v1/rules | jq -c '[.data.groups[].rules[]]')
    jq -e --arg since "$since" 'all(.lastEvaluation[0:19] > $since)' <<<"$rules" >/dev/null && break
    sleep 2
  done
  while read -r rule; do
    check "alert rule evaluates: $(jq -r .name <<<"$rule")" \
      "$(jq -r '.health + (if .lastError then ": " + .lastError else "" end)' <<<"$rule")" "ok"
  done < <(jq -c '.[]' <<<"$rules")
  # rules with execErrState: OK report health "ok" even when broken, only the logs tell
  check "no alert evaluation errors in logs" \
    "$(docker logs --since "${since}Z" "$CONTAINER" 2>&1 | grep -E 'logger=ngalert\S* .*level=error' | sed -E "s/.*(now=\S+).*(error=.*)/\1 \2/" | cut -c1-300 | sort -u || true)" ""
  check_no_provisioning_errors
fi

echo
if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES check(s) failed"
  exit 1
fi
echo "All checks passed"
