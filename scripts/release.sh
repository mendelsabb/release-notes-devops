#!/usr/bin/env bash
# Usage: scripts/release.sh <version> [env]       (env defaults to dev)
#
# github mode (default): a release is a version bump. It goes to main through a
#   pull request; CI on main builds the image once, pushes it to GHCR and commits
#   its digest to gitops/environments/dev/image.yaml; Argo CD deploys dev. Nothing
#   is built on this machine. Prod only receives images via promote.sh.
# local mode: build the current commit, push it to the local registry and commit
#   its digest for <env> (BROKEN=1 bakes in a readiness fault for the demo).
source "$(dirname "$0")/lib.sh"

version=${1:-}
env=${2:-dev}
[[ "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,49}$ ]] ||
  die "Usage: make release VERSION=<version>   e.g. make release VERSION=1.1.0"
valid_env "$env"
require_cluster

_dev_image_on_main_is() {
  git -C "$ROOT" fetch --quiet origin "$GITOPS_BRANCH" &&
    git -C "$ROOT" show "origin/${GITOPS_BRANCH}:gitops/environments/dev/image.yaml" |
    grep -qx "  version: \"$1\""
}

if [[ "$(gitops_mode)" == github ]]; then
  [[ "$env" == dev ]] || die "In GitHub mode only CI deploys new builds, and only to dev; use 'make promote' for prod"
  [[ "${BROKEN:-0}" != "1" ]] || die "BROKEN=1 builds locally; in GitHub mode use 'make demo-broken-rollout'"
  require_cmd uv gh
  sync_main
  current=$(sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT/pyproject.toml")
  [[ "$version" != "$current" ]] || die "Version $version is already the current version"
  (cd "$ROOT" && uv version "$version" --no-sync >/dev/null)
  deliver_change "release: $version" "$ROOT/pyproject.toml" "$ROOT/uv.lock"
  log "Waiting for CI on main to build $version, push it to GHCR and deploy it to dev"
  wait_until 1200 "CI to commit the $version digest to gitops/environments/dev/image.yaml" \
    _dev_image_on_main_is "$version"
  sync_main
  ok "CI deployed $(image_field dev repository)@$(image_field dev digest | cut -c1-19) to dev"
  push_gitops
else
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
  deliver_change "deploy($env): release-notes ${version} (${digest:7:12})" "$(image_file "$env")"
fi

if [[ "${NO_WAIT:-0}" == "1" ]]; then exit 0; fi
wait_for_app "$env" 300
wait_for_version "$env" "$version"
