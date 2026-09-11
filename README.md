# saashup/grafana

Saashup's custom Grafana image, used on **paashups**. It boots directly with a Prometheus datasource and dashboards ready to use, and Keycloak login already wired up — no manual setup afterwards.

## Ready out of the box

- **Prometheus datasource** (`paashup.yaml`) pointed at `$PROM_URL`.
- **4 dashboards** (`dashboards/*.json`): Traefik, Docker, Netbox Docker Agents, Grafana itself. All of them point at a `datasource` template variable (not a fixed uid), so adding/switching the Prometheus datasource applies to every dashboard immediately.
- **OIDC login via Keycloak** — same settings as the rest of the Paashup stack.

## Required variables

| Variable | |
|---|---|
| `BASE_DOMAIN` | the paashup's domain |
| `GF_SECURITY_ADMIN_PASSWORD` | admin password |
| `GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET` | secret of the `grafana` client in Keycloak |
| `PROM_BASIC_AUTH_PASSWORD` | basic-auth password towards Prometheus |

Everything else (`GF_SERVER_ROOT_URL`, the Keycloak URLs, `PROM_URL`, ...) is recomputed automatically from `BASE_DOMAIN` by [entrypoint.sh](entrypoint.sh) on every start. `BASE_SCHEME` (default `https`) lets you test locally without TLS if you change on `http`.

## Traefik label to add manually

The image does **not** bake a router rule label — container labels are frozen at creation, nothing inside the container can update them at runtime the way `entrypoint.sh` does for `ENV` vars, so there's no safe default to bake. This one must be added by hand (or in the VM's init script) at `docker run`, with the paashup's real domain:

```bash
--label "traefik.http.routers.grafana.rule=Host(\`${BASE_DOMAIN}\`) && PathPrefix(\`/dashboard\`)"
```

## Build & publish

Push a `vX.Y.Z` tag — `.github/workflows/docker-publish.yml` handles the build + push.
