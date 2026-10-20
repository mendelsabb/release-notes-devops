#!/usr/bin/env bash
# App pod termination demo: delete one prod API pod under traffic and verify the
# Deployment restores the replica count while the others keep serving.
# FORCE=1 kills the pod without a grace period (no preStop, no drain) to show
# what an ungraceful crash looks like; some failures are expected then.
source "$(dirname "$0")/../lib.sh"
require_cluster

desired=$(k -n prod get deploy release-notes -o jsonpath='{.spec.replicas}')
victim=$(k -n prod get pods -l app.kubernetes.io/component=api -o jsonpath='{.items[0].metadata.name}')
max_failures=0
delete_args=(--wait=false)
if [[ "${FORCE:-0}" == "1" ]]; then
  delete_args=(--grace-period=0 --force)
  max_failures=1000000 # report, do not judge
fi

traffic_start prod 60 --max-failures "$max_failures"
sleep 10
log "Deleting pod ${victim} (${desired} desired replicas) ${FORCE:+[FORCE]}"
k -n prod delete pod "$victim" "${delete_args[@]}"

_restored() {
  [[ "$(k -n prod get deploy release-notes -o jsonpath='{.status.availableReplicas}')" == "$desired" &&
    -z "$(k -n prod get pod "$victim" -o name 2>/dev/null)" ]]
}
wait_until 120 "deployment to return to ${desired} available replicas" _restored
ok "Replacement running; ${desired}/${desired} replicas available"
k -n prod get pods -l app.kubernetes.io/component=api

if traffic_wait prod; then
  ok "Pod termination handled (see .local/traffic-prod.json)"
else
  die "Requests failed while a pod was terminated (see .local/traffic-prod.json)"
fi
