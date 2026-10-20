#!/usr/bin/env bash
# Usage: scripts/rollback.sh <env> [git-rev]
# GitOps rollback: restore <env>'s previous image.yaml from git history (or the
# version at [git-rev]) as a new commit; Argo CD reconciles it. Only the image
# reference changes - config changes made since are kept. Database schema and
# data are NOT rolled back (migrations are additive / backward compatible).
# GITOPS_ONLY=1 (used by CI): only write + commit; no cluster, push or wait.
source "$(dirname "$0")/lib.sh"

env=${1:-prod}
rev=${2:-${TO:-}}
valid_env "$env"
if [[ "${GITOPS_ONLY:-0}" != "1" ]]; then
  require_cluster
  sync_main
fi
file="$(image_file "$env")"
rel="${file#"$ROOT"/}"
current=$(image_field "$env" digest)

if [[ -z "$rev" ]]; then
  # Walk the file's history, newest first, to the first digest that differs.
  # In GitHub mode, skip images that only ever existed in a local registry.
  while read -r commit; do
    candidate=$(git -C "$ROOT" show "${commit}:${rel}" | sed -n 's/^  digest: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p')
    candidate_repo=$(git -C "$ROOT" show "${commit}:${rel}" | sed -n 's/^  repository: *//p')
    if [[ "$(gitops_mode)" == github && "$candidate_repo" == localhost:* ]]; then continue; fi
    if [[ "$candidate" == sha256:* && "$candidate" != "$current" ]]; then
      rev=$commit
      break
    fi
  done < <(git -C "$ROOT" log --format=%H -- "$rel")
  [[ -n "$rev" ]] || die "No previous image found in the git history of $rel"
fi

git -C "$ROOT" show "${rev}:${rel}" >"$file"
target_version=$(image_field "$env" version)
target_digest=$(image_field "$env" digest)
log "Rolling $env back from $(git -C "$ROOT" show "HEAD:${rel}" | sed -n 's/^  version: *"\(.*\)"$/\1/p') to ${target_version} (${target_digest:7:12}, from $(git -C "$ROOT" rev-parse --short "$rev"))"
msg="rollback($env): release-notes ${target_version} (${target_digest:7:12})"
if [[ "${GITOPS_ONLY:-0}" == "1" ]]; then
  commit_gitops "$msg" "$file"
  exit 0
fi
deliver_change "$msg" "$file"

if [[ "${NO_WAIT:-0}" == "1" ]]; then exit 0; fi
wait_for_app "$env" 300
wait_for_version "$env" "$target_version"
