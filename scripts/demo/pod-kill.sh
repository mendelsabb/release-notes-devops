#!/usr/bin/env bash
# App pod termination demo under traffic.
#   default : graceful `kubectl delete pod` (preStop + drain); expect 0 failures and
#             the Deployment to restore the replica count.
#   CRASH=1 : SIGKILL the app process from the kind node (an OOM kill/segfault: no
#             preStop, no drain). A few in-flight/new connections to that pod fail
#             until the kubelet restarts it; reported, not judged.
source "$(dirname "$0")/../lib.sh"
require_cluster

desired=$(k -n prod get deploy release-notes -o jsonpath='{.spec.replicas}')
victim=$(k -n prod get pods -l app.kubernetes.io/component=api -o jsonpath='{.items[0].metadata.name}')

if [[ "${CRASH:-0}" == "1" ]]; then
  traffic_start prod 45 --max-failures 1000000 # report, do not judge
  sleep 10
  cid=$(k -n prod get pod "$victim" -o jsonpath='{.status.containerStatuses[0].containerID}')
  node=$(k -n prod get pod "$victim" -o jsonpath='{.spec.nodeName}')
  pid=$(docker exec "$node" crictl inspect --output go-template --template '{{.info.pid}}' "${cid#containerd://}")
  before=$(k -n prod get pod "$victim" -o jsonpath='{.status.containerStatuses[0].restartCount}')
  log "SIGKILL app process (pid ${pid}) of ${victim}"
  docker exec "$node" kill -9 "$pid"
  # The pod still looks Ready until the kubelet notices: wait for the restart itself.
  _restarted() {
    [[ "$(k -n prod get pod "$victim" -o jsonpath='{.status.containerStatuses[0].restartCount}')" -gt "$1" &&
      "$(k -n prod get pod "$victim" -o jsonpath='{.status.containerStatuses[0].ready}')" == "true" ]]
  }
  wait_until 120 "${victim} to be restarted and Ready" _restarted "$before"
  ok "Container restarted by the kubelet (restartCount ${before} -> $(k -n prod get pod "$victim" -o jsonpath='{.status.containerStatuses[0].restartCount}')) and Ready again"
  traffic_wait prod
  exit 0
fi

traffic_start prod 60
sleep 10
log "Deleting pod ${victim} (${desired} desired replicas)"
k -n prod delete pod "$victim" --wait=false

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
