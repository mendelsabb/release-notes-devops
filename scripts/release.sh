#!/usr/bin/env bash
# Usage: scripts/release.sh <version> [env]       (env defaults to dev)
# Build the current commit once, push it to the local registry and deploy it by
# digest to <env> via a git commit. Prod normally receives images via promote.sh.
# BROKEN=1 bakes a readiness fault into the image (failed-rollout demo only).
source "$(dirname "$0")/lib.sh"

version=${1:-}
env=${2:-dev}
[[ "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,49}$ ]] ||
  die "Usage: make release VERSION=<version>   e.g. make release VERSION=1.1.0"
valid_env "$env"
require_cluster

build_args=()
if [[ "${BROKEN:-0}" == "1" ]]; then
  warn "BROKEN=1: building an image whose /ready always fails"
  build_args+=(--build-arg SIMULATE_UNREADY=true)
fi

log "Building release-notes:${version} from $(git -C "$ROOT" rev-parse --short HEAD)"
# bash 3.2 (macOS) treats an empty "${arr[@]}" as unbound under set -u.
digest="$(build_and_push "$version" ${build_args[@]+"${build_args[@]}"})"
[[ "$digest" == sha256:* ]] || die "Could not read the pushed image digest from the local registry"
ok "Pushed ${IMAGE_REPO}@${digest}"

write_image_file "$env" "$IMAGE_REPO" "$digest" "$version"
commit_gitops "deploy($env): release-notes ${version} (${digest:7:12})" "$(image_file "$env")"
push_gitops

if [[ "${NO_WAIT:-0}" == "1" ]]; then exit 0; fi
wait_for_app "$env" 300
actual="$(served_version "$env")"
[[ "$actual" == "$version" ]] || die "$env Service reports version $actual, expected $version"
ok "$env is serving release-notes $version"
