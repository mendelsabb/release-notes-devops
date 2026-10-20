#!/usr/bin/env bash
# Failed-rollout demo: ship an image whose readiness probe never passes straight
# to prod (deliberately skipping the dev gate) while traffic runs, and show:
#   - the new pod never becomes Ready, old pods keep serving (maxUnavailable: 0)
#   - the rollout is reported as failed: Deployment ProgressDeadlineExceeded,
#     Argo CD health Degraded (while sync status is still "Synced")
#   - `make rollback ENV=prod` restores the last good version
source "$(dirname "$0")/../lib.sh"
require_cluster

good=$(image_field prod version)
bad="${good}-unready"
deadline=$(k -n prod get deploy release-notes -o jsonpath='{.spec.progressDeadlineSeconds}')

log "Starting traffic against prod (currently ${good})"
traffic_start prod $((deadline + 120))

log "Deploying ${bad} (readiness always fails) directly to prod"
BROKEN=1 NO_WAIT=1 "$ROOT/scripts/release.sh" "$bad" prod

_new_pod_unready() {
  [[ -n "$(k -n prod get pods -l "app.kubernetes.io/version=${bad}" -o name)" ]]
}
wait_until 120 "a ${bad} pod to be created" _new_pod_unready
log "New pod is running but not Ready; old pods still serve:"
k -n prod get pods -l app.kubernetes.io/component=api \
  -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[0].ready,VERSION:.metadata.labels.app\.kubernetes\.io/version'

log "Waiting for Kubernetes to declare the rollout failed (progressDeadlineSeconds=${deadline})"
if k -n prod rollout status deployment/release-notes --timeout=$((deadline + 60))s; then
  die "Rollout unexpectedly reported success"
fi
ok "kubectl rollout status failed: $(k -n prod get deploy release-notes \
  -o jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}')"
_degraded() { [[ "$(app_status prod)" == "Synced/Degraded" ]]; }
wait_until 120 "Argo CD to report prod Degraded" _degraded
ok "Argo CD: $(app_status prod)  (Synced = manifests applied; Degraded = rollout failed)"
log "Available replicas during the failed rollout: $(k -n prod get deploy release-notes -o jsonpath='{.status.availableReplicas}')"

log "Rolling back with: make rollback ENV=prod"
"$ROOT/scripts/rollback.sh" prod

log "Waiting for the traffic generator to finish"
if traffic_wait prod; then
  ok "Failed rollout was contained and rolled back with no failed requests"
else
  die "Requests failed during the failed-rollout scenario (see .local/traffic-prod.json)"
fi
