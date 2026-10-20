#!/usr/bin/env bash
# Zero-downtime rollout demo:
#   1. release vNEXT to dev (github mode: version bump PR, CI builds and deploys;
#      local mode: build once into the local registry)
#   2. promote the same digest to prod; in-cluster traffic starts right before
#      the change lands (after the promotion PR passed CI)
#   3. watch the RollingUpdate, wait for the old pods to drain
#   4. report client-visible failures; exit non-zero if any request failed
# Usage: VERSION=1.2.0 scripts/demo/rollout.sh   (default: next minor version)
source "$(dirname "$0")/../lib.sh"
require_cluster
sync_main

old=$(image_field prod version)
if [[ -z "${VERSION:-}" ]]; then
  # github mode: next minor after the project version; local mode: after prod's.
  base=$old
  [[ "$(gitops_mode)" == github ]] && base=$(sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT/pyproject.toml")
  IFS=. read -r major minor _ <<<"$base"
  VERSION="${major}.$((minor + 1)).0"
fi
duration=${DURATION:-150}

log "Step 1/4: release ${VERSION} to dev (prod stays on ${old})"
"$ROOT/scripts/release.sh" "$VERSION" dev

log "Step 2/4: promote ${VERSION} to prod (same digest as dev); ${duration}s of traffic starts just before it lands"
GITOPS_BEFORE_MERGE="START_ONLY=1 '$ROOT/scripts/traffic.sh' prod ${duration} && sleep 10" \
  NO_WAIT=1 "$ROOT/scripts/promote.sh"

log "Step 3/4: rolling update"
wait_for_app prod 300
k -n prod rollout status deployment/release-notes --timeout=300s
# `rollout status` returns while old pods are still in preStop/draining.
_old_pods_gone() { [[ -z "$(k -n prod get pods -l "app.kubernetes.io/component=api,app.kubernetes.io/version=$1" -o name)" ]]; }
wait_until 90 "${old} pods to finish draining and terminate" _old_pods_gone "$old"
ok "All ${old} pods drained and terminated"
k -n prod get pods -l app.kubernetes.io/component=api \
  -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[0].ready,VERSION:.metadata.labels.app\.kubernetes\.io/version'
wait_for_version prod "$VERSION"
ok "UI/API now reports: $(curl -fsS http://127.0.0.1:8080/version)"

log "Step 4/4: waiting for the traffic generator to finish"
if traffic_wait prod; then
  ok "Zero-downtime rollout ${old} -> ${VERSION}: no failed requests (details: .local/traffic-prod.json)"
else
  die "Requests failed during the rollout (see .local/traffic-prod.json)"
fi
