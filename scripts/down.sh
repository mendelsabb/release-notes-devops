#!/usr/bin/env bash
# Delete the kind cluster. This destroys ALL cluster state, including the
# Postgres PVCs (dev and prod data), Prometheus/Loki data and the git mirror.
# --registry also removes the local image registry and the git remote.
source "$(dirname "$0")/lib.sh"

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  log "Deleting kind cluster '$CLUSTER_NAME' (all cluster data, including databases, is lost)"
  kind delete cluster --name "$CLUSTER_NAME"
else
  ok "No kind cluster '$CLUSTER_NAME'"
fi
if [[ "${1:-}" == "--registry" ]]; then
  docker rm -f "$REGISTRY_NAME" >/dev/null 2>&1 && ok "Removed local registry" || true
  docker volume rm kind-registry-data >/dev/null 2>&1 || true
  git -C "$ROOT" remote remove "$GIT_MIRROR_REMOTE" 2>/dev/null || true
fi
