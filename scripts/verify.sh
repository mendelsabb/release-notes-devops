#!/usr/bin/env bash
# End-to-end checks against the running stack. Prints PASS/FAIL per check and
# exits non-zero if any check fails. Prometheus and Loki are queried through the
# Kubernetes API server's service proxy (no port-forwards needed).
source "$(dirname "$0")/lib.sh"
require_cluster
require_cmd python3

passed=0
failed=0
check() {
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then
    printf '  %sPASS%s %s\n' "$_G" "$_N" "$name"
    passed=$((passed + 1))
  else
    printf '  %sFAIL%s %s\n' "$_R" "$_N" "$name"
    failed=$((failed + 1))
  fi
}

port_of() { [[ $1 == prod ]] && echo 8080 || echo 8081; }
json() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

urlencode() { python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1"; }
prom() {
  k get --raw "/api/v1/namespaces/monitoring/services/prometheus-server:80/proxy/api/v1/query?query=$(urlencode "$1")"
}
prom_has_data() { [[ "$(prom "$1" | json 'len(d["data"]["result"])')" -gt 0 ]]; }

loki_count() {
  k get --raw "/api/v1/namespaces/monitoring/services/loki:3100/proxy/loki/api/v1/query_range?query=$(urlencode "$1")&limit=20&since=1h" |
    json 'sum(len(s["values"]) for s in d["data"]["result"])'
}
loki_has_logs() { [[ "$(loki_count "$1")" -gt 0 ]]; }
loki_has_no_logs() { [[ "$(loki_count "$1")" == 0 ]]; }

api_roundtrip() {
  local port=$1 v
  v="e2e-$(date +%s)-$RANDOM"
  [[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:${port}/api/releases" \
    -H 'Content-Type: application/json' -d "{\"version\":\"$v\",\"description\":\"e2e check\"}")" == 201 ]] &&
    curl -fsS "http://127.0.0.1:${port}/api/releases?limit=200" | grep -q "\"$v\"" &&
    [[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:${port}/api/releases" \
      -H 'Content-Type: application/json' -d "{\"version\":\"$v\",\"description\":\"dup\"}")" == 409 ]]
}
invalid_rejected() {
  [[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$1/api/releases" \
    -H 'Content-Type: application/json' -d '{"version":"not valid","description":""}')" == 422 ]]
}
ui_served() { curl -fsS "http://127.0.0.1:$1/" | grep -q '<title>Release Notes</title>'; }
version_matches_git() {
  [[ "$(curl -fsS "http://127.0.0.1:$(port_of "$1")/version" | json 'd["version"]')" == "$(repo_image_field "$1" version)" ]]
}
running_digest_matches_git() {
  [[ "$(k -n "$1" get deploy release-notes -o jsonpath='{.spec.template.spec.containers[0].image}')" == *"@$(repo_image_field "$1" digest)" ]]
}
# Compare with the repository Argo CD watches (local commits may not be pushed yet).
if [[ "$(gitops_mode)" == local ]]; then
  repo_head=$(git ls-remote "$GIT_MIRROR_HOST_URL" "refs/heads/${GITOPS_BRANCH}" | cut -f1)
else
  repo_head=$(git ls-remote origin "refs/heads/${GITOPS_BRANCH}" | cut -f1)
  git -C "$ROOT" fetch --quiet origin "$GITOPS_BRANCH"
fi
# What Git says an environment should run, read from the commit Argo CD watches
# (not the local checkout, which may be behind, e.g. before CI's digest commit).
repo_image_field() {
  git -C "$ROOT" show "${repo_head}:gitops/environments/$1/image.yaml" |
    sed -n "s/^  $2: *\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p"
}
# Argo CD polls the repo; after a recent push give it up to 2 minutes to catch up.
argo_healthy() {
  local deadline=$((SECONDS + 120))
  until [[ "$(app_status "$1")" == "Synced/Healthy" && "$(app_synced_revision "$1")" == "$repo_head" ]]; do
    ((SECONDS < deadline)) || return 1
    sleep 3
  done
}
push_gitops >/dev/null # ask Argo CD to re-read the repo now
pvc_bound() { [[ "$(k -n "$1" get pvc data-release-notes-db-0 -o jsonpath='{.status.phase}')" == Bound ]]; }
replicas_ok() {
  local want=$2
  [[ "$(k -n "$1" get deploy release-notes -o jsonpath='{.status.availableReplicas}')" -ge "$want" ]]
}
pods_hardened() {
  k -n "$1" get pods -l app.kubernetes.io/component=api -o json | python3 -c '
import json, sys
for p in json.load(sys.stdin)["items"]:
    c = p["spec"]["containers"][0]["securityContext"]
    assert c["readOnlyRootFilesystem"] and c["runAsNonRoot"] and not c["allowPrivilegeEscalation"]
    assert c["capabilities"]["drop"] == ["ALL"]
    assert p["spec"]["automountServiceAccountToken"] is False
'
}
no_db_exposure() { [[ "$(k -n "$1" get svc release-notes-db -o jsonpath='{.spec.clusterIP}')" == None ]]; }
grafana_dashboard() {
  curl -fsS "http://127.0.0.1:3000/api/dashboards/uid/release-notes" | grep -q '"title":"Release Notes"'
}
grafana_datasource_ok() {
  local pw
  pw=$(k -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)
  curl -fsS -u "admin:${pw}" "http://127.0.0.1:3000/api/datasources/uid/$1/health" | grep -q '"status":"OK"'
}

log "Generating a little traffic so metrics and logs exist"
for _ in $(seq 1 20); do
  curl -fsS -o /dev/null http://127.0.0.1:8080/api/releases || true
  curl -fsS -o /dev/null http://127.0.0.1:8081/api/releases || true
done

for env in dev prod; do
  port=$(port_of "$env")
  log "Application ($env, http://localhost:${port})"
  check "UI served" ui_served "$port"
  check "create -> list -> duplicate (201/200/409)" api_roundtrip "$port"
  check "invalid input rejected (422)" invalid_rejected "$port"
  check "/version matches gitops/environments/$env/image.yaml" version_matches_git "$env"
  check "Deployment runs the digest from git" running_digest_matches_git "$env"
  check "Argo CD Synced/Healthy at the GitOps repo HEAD" argo_healthy "$env"
  check "Postgres PVC bound" pvc_bound "$env"
  check "Postgres not exposed outside the cluster (headless)" no_db_exposure "$env"
  check "API pods: read-only rootfs, non-root, no caps, no SA token" pods_hardened "$env"
done
check "prod has >= 2 available replicas" replicas_ok prod 2

log "Metrics (Prometheus)"
sleep 20 # allow one scrape interval after the traffic above
for env in dev prod; do
  check "$env pods scraped (up == 1)" prom_has_data "up{namespace=\"$env\",app_kubernetes_io_name=\"release-notes\"} == 1"
  check "$env request counter has data" prom_has_data "http_requests_total{namespace=\"$env\",route=\"/api/releases\"}"
  check "$env latency histogram has data" prom_has_data "http_request_duration_seconds_bucket{namespace=\"$env\"}"
  check "$env build info exposes version" prom_has_data "release_notes_build_info{namespace=\"$env\"}"
done
check "kube-state-metrics deployment availability" prom_has_data 'kube_deployment_status_replicas_available{deployment="release-notes"}'
check "p95 latency query returns a value" prom_has_data \
  'histogram_quantile(0.95, sum by (namespace, le) (rate(http_request_duration_seconds_bucket[5m])))'

log "Logs (Loki via Alloy)"
check "prod API logs in Loki" loki_has_logs '{namespace="prod", app="release-notes", component="api"}'
check "dev API logs in Loki" loki_has_logs '{namespace="dev", app="release-notes", component="api"}'
check "filter by level label (prod INFO)" loki_has_logs '{namespace="prod", app="release-notes", level="INFO"}'
check "dev DEBUG logs present (probe access logs)" loki_has_logs '{namespace="dev", app="release-notes", level="DEBUG"}'
check "prod has no DEBUG logs (LOG_LEVEL=INFO)" loki_has_no_logs '{namespace="prod", app="release-notes", level="DEBUG"}'
pod=$(k -n prod get pods -l app.kubernetes.io/component=api -o jsonpath='{.items[0].metadata.name}')
check "filter by pod + parse JSON fields" loki_has_logs "{namespace=\"prod\", pod=\"${pod}\"} | json | route=\"/api/releases\" | status=\"200\""

log "Dashboards (Grafana)"
check "Release Notes dashboard provisioned" grafana_dashboard
check "Prometheus datasource healthy" grafana_datasource_ok prometheus
check "Loki datasource healthy" grafana_datasource_ok loki

echo
if ((failed == 0)); then
  ok "All ${passed} checks passed"
else
  die "${failed} of $((passed + failed)) checks failed"
fi
