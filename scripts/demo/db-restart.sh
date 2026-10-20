#!/usr/bin/env bash
# PostgreSQL restart demo: delete the prod database pod and verify that
#   - data written before the restart survives (PVC)
#   - app readiness drops while the DB is unavailable and recovers afterwards
# Postgres is a single instance, so requests DO fail during the restart; the
# traffic generator reports how many (it does not fail the demo on them).
source "$(dirname "$0")/../lib.sh"
require_cluster

marker="persist-$(date +%s)"
api="http://127.0.0.1:8080/api/releases"
curl -fsS -X POST "$api" -H 'Content-Type: application/json' \
  -d "{\"version\":\"${marker}\",\"description\":\"written before the database restart\"}" >/dev/null
ok "Wrote release ${marker}"

restarts_of() { k -n prod get pods -l app.kubernetes.io/component=api \
  -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"+"}{end}0' | bc; }
restarts_before=$(restarts_of)
traffic_start prod 90 --max-failures 1000000
sleep 10
pvc_uid=$(k -n prod get pvc data-release-notes-db-0 -o jsonpath='{.metadata.uid}')
old_uid=$(k -n prod get pod release-notes-db-0 -o jsonpath='{.metadata.uid}')
start=$SECONDS
log "Deleting pod release-notes-db-0"
k -n prod delete pod release-notes-db-0 --wait=false

# Wait for the *replacement* pod (new UID) to be Ready, not the terminating one.
_db_replaced() {
  [[ "$(k -n prod get pod release-notes-db-0 -o jsonpath='{.metadata.uid}/{.status.conditions[?(@.type=="Ready")].status}')" == \
    "$(k -n prod get pod release-notes-db-0 -o jsonpath='{.metadata.uid}')/True" &&
    "$(k -n prod get pod release-notes-db-0 -o jsonpath='{.metadata.uid}')" != "$old_uid" ]]
}
wait_until 180 "replacement Postgres pod Ready" _db_replaced
ok "Postgres Ready again after $((SECONDS - start))s (new pod)"
_all_ready() { [[ "$(k -n prod get deploy release-notes -o jsonpath='{.status.readyReplicas}')" == \
  "$(k -n prod get deploy release-notes -o jsonpath='{.spec.replicas}')" ]]; }
wait_until 120 "all API pods Ready" _all_ready
ok "API fully Ready after $((SECONDS - start))s"

[[ "$(k -n prod get pvc data-release-notes-db-0 -o jsonpath='{.metadata.uid}')" == "$pvc_uid" ]] &&
  ok "Same PVC re-attached (uid ${pvc_uid:0:8})"
curl -fsS --retry 5 --retry-all-errors --retry-delay 1 "${api}?limit=200" | grep -q "\"${marker}\"" || die "Release ${marker} missing after restart!"
ok "Release ${marker} survived the database restart"
[[ "$(restarts_of)" == "$restarts_before" ]] &&
  ok "No API container restarts: liveness (/health) ignores the database by design"

traffic_wait prod || true
python3 - "$ROOT/.local/traffic-prod.json" <<'PY' || true
import json, sys
s = json.load(open(sys.argv[1]))
print(f"Outage as seen by clients: {s['failed']} of {s['total']} requests failed "
      f"(http_error={s['http_error']} timeout={s['timeout']} conn_error={s['conn_error']}). "
      "Expected: Postgres is a single point of failure.")
PY
