#!/usr/bin/env bash
# Zero-downtime rollout demo:
#   1. build vNEXT once and deploy it to dev (git commit -> Argo CD)
#   2. start in-cluster traffic against prod
#   3. promote the same digest to prod while traffic runs; watch the RollingUpdate
#   4. report client-visible failures; exit non-zero if any request failed
# Usage: VERSION=1.2.0 scripts/demo/rollout.sh   (default: bump prod's minor version)
source "$(dirname "$0")/../lib.sh"
require_cluster

old=$(image_field prod version)
if [[ -z "${VERSION:-}" ]]; then
  IFS=. read -r major minor _ <<<"$old"
  VERSION="${major}.$((minor + 1)).0"
fi
duration=${DURATION:-150}

log "Step 1/4: release ${VERSION} to dev (prod stays on ${old})"
"$ROOT/scripts/release.sh" "$VERSION" dev

log "Step 2/4: start ${duration}s of in-cluster traffic against prod"
traffic_start prod "$duration"
sleep 10 # baseline on the old version before the rollout starts

log "Step 3/4: promote ${VERSION} to prod (same digest as dev)"
NO_WAIT=1 "$ROOT/scripts/promote.sh"
k -n prod rollout status deployment/release-notes --timeout=300s
wait_for_app prod 300
# `rollout status` returns while old pods are still in preStop/draining.
_old_pods_gone() { [[ -z "$(k -n prod get pods -l "app.kubernetes.io/component=api,app.kubernetes.io/version=$1" -o name)" ]]; }
wait_until 90 "${old} pods to finish draining and terminate" _old_pods_gone "$old"
ok "All ${old} pods drained and terminated"
k -n prod get pods -l app.kubernetes.io/component=api \
  -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[0].ready,VERSION:.metadata.labels.app\.kubernetes\.io/version'
ok "UI/API now reports: $(curl -fsS http://127.0.0.1:8080/version)"

log "Step 4/4: waiting for the traffic generator to finish"
if traffic_wait prod; then
  ok "Zero-downtime rollout ${old} -> ${VERSION}: no failed requests (details: .local/traffic-prod.json)"
else
  die "Requests failed during the rollout (see .local/traffic-prod.json)"
fi
