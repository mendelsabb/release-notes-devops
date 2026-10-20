#!/usr/bin/env bash
# One-screen overview: desired state in git vs what Argo CD and Kubernetes report.
source "$(dirname "$0")/lib.sh"
require_cluster

log "Argo CD applications (sync = manifests applied, health = workloads actually OK)"
k -n argocd get applications -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision,OPERATION:.status.operationState.phase' |
  awk 'NR==1 {print; next} {$4=substr($4,1,7); print}' | column -t
echo
for env in "${ENVIRONMENTS[@]}"; do
  log "$env: git wants $(image_field "$env" version) ($(image_field "$env" digest | cut -c1-19))"
  k -n "$env" get deploy,statefulset,hpa,pdb -l app.kubernetes.io/instance=release-notes 2>/dev/null || true
  k -n "$env" get pods -l app.kubernetes.io/name=release-notes \
    -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[0].ready,STATUS:.status.phase,VERSION:.metadata.labels.app\.kubernetes\.io/version,IMAGE:.spec.containers[0].image' |
    sed 's|localhost:5001/release-notes@sha256:\(.\{12\}\)[^ ]*|@sha256:\1…|'
  echo
done
log "Endpoints"
for port in 8080 8081; do
  printf '  http://localhost:%s  ' "$port"
  curl -fsS -m 3 "http://127.0.0.1:${port}/version" || printf 'unreachable'
  echo
done
echo "  Grafana http://localhost:3000   Argo CD http://localhost:8090"
