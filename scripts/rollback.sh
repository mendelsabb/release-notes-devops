#!/usr/bin/env bash
# Usage: scripts/rollback.sh <env> [git-rev]
# GitOps rollback: restore <env>'s previous image.yaml from git history (or the
# version at [git-rev]) as a new commit; Argo CD reconciles it. Only the image
# reference changes - config changes made since are kept. Database schema and
# data are NOT rolled back (migrations are additive / backward compatible).
source "$(dirname "$0")/lib.sh"

env=${1:-prod}
rev=${2:-${TO:-}}
valid_env "$env"
require_cluster
file="$(image_file "$env")"
rel="${file#"$ROOT"/}"
current=$(image_field "$env" digest)

if [[ -z "$rev" ]]; then
  # Walk the file's history, newest first, to the first digest that differs.
  while read -r commit; do
    candidate=$(git -C "$ROOT" show "${commit}:${rel}" | sed -n 's/^  digest: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p')
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
commit_gitops "rollback($env): release-notes ${target_version} (${target_digest:7:12})" "$file"
push_gitops

if [[ "${NO_WAIT:-0}" == "1" ]]; then exit 0; fi
wait_for_app "$env" 300
actual="$(served_version "$env")"
[[ "$actual" == "$target_version" ]] || die "$env Service reports $actual, expected $target_version"
ok "$env is serving release-notes $target_version"
