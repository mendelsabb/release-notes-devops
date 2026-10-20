#!/usr/bin/env bash
# Failed-rollout drill: ship an image whose readiness probe never passes straight
# to prod (deliberately skipping the dev gate) while traffic runs, and show:
#   - the new pod never becomes Ready, old pods keep serving (maxUnavailable: 0)
#   - the rollout is reported as failed: Deployment ProgressDeadlineExceeded,
#     Argo CD health Degraded (while sync status is still "Synced")
#   - `make rollback ENV=prod` restores the last good version
# github mode: CI builds the fault image (workflow_dispatch simulate_unready) and
#   the bad digest reaches prod through a pull request like any other change.
# local mode: the fault image is built into the local registry.
source "$(dirname "$0")/../lib.sh"
require_cluster
sync_main

good=$(image_field prod version)
bad="${good}-unready"
deadline=$(k -n prod get deploy release-notes -o jsonpath='{.spec.progressDeadlineSeconds}')
# Traffic must cover the failed rollout, the deadline and the rollback (whose PR
# waits for CI in github mode).
duration=$((deadline + 120))
[[ "$(gitops_mode)" == github ]] && duration=$((deadline + 480))
export GITOPS_BEFORE_MERGE="START_ONLY=1 '$ROOT/scripts/traffic.sh' prod ${duration}"

_fault_run_id() {
  gh run list --repo "$(github_slug)" --workflow ci.yml --event workflow_dispatch --commit "$1" \
    --limit 1 --json databaseId --jq '.[0].databaseId // empty'
}

_fault_run_started() { [[ -n "$(_fault_run_id "$1")" ]]; }

if [[ "$(gitops_mode)" == github ]]; then
  require_cmd gh docker
  sha=$(git -C "$ROOT" rev-parse HEAD)
  version=$(sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT/pyproject.toml")
  repo=$(image_field dev repository)
  log "Asking CI to build the fault image from ${sha:0:7} (published, not deployed)"
  gh workflow run ci.yml --repo "$(github_slug)" --ref "$GITOPS_BRANCH" -f simulate_unready=true
  wait_until 120 "the CI drill run to start" _fault_run_started "$sha"
  run_id=$(_fault_run_id "$sha")
  gh run watch "$run_id" --repo "$(github_slug)" --interval 20 --exit-status >/dev/null ||
    die "CI drill run $run_id failed"
  digest=$(docker buildx imagetools inspect "${repo}:${version}-unready-${sha:0:7}" | awk '/^Digest:/ {print $2; exit}')
  [[ "$digest" == sha256:* ]] || die "Could not resolve the fault image digest"
  ok "Fault image: ${repo}@${digest}"
  write_image_file prod "$repo" "$digest" "$bad"
  log "Deploying ${bad} (readiness always fails) directly to prod"
  deliver_change "deploy(prod): fault-injection drill ${bad} (${digest:7:12})" "$(image_file prod)"
else
  log "Deploying ${bad} (readiness always fails) directly to prod"
  BROKEN=1 NO_WAIT=1 "$ROOT/scripts/release.sh" "$bad" prod
fi

_new_pod_created() {
  [[ -n "$(k -n prod get pods -l "app.kubernetes.io/version=${bad}" -o name)" ]]
}
wait_until 180 "a ${bad} pod to be created" _new_pod_created
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
GITOPS_BEFORE_MERGE="" "$ROOT/scripts/rollback.sh" prod

log "Waiting for the traffic generator to finish"
if traffic_wait prod; then
  ok "Failed rollout was contained and rolled back with no failed requests"
else
  die "Requests failed during the failed-rollout scenario (see .local/traffic-prod.json)"
fi
