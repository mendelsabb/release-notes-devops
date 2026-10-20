#!/usr/bin/env bash
# Usage (CI, publish job): scripts/ci-deploy-dev.sh <image> <digest> <version>
# Commit the freshly published digest to gitops/environments/dev/image.yaml on main.
#
# Several publish jobs can race (pushes merged close together). Each attempt
# therefore re-applies the change on top of the latest main instead of rebasing
# an old commit (two edits of the same file always conflict), and a build whose
# commit is no longer the newest code on main is skipped: the newer commit's own
# run deploys dev, so an older image can never overwrite a newer one.
source "$(dirname "$0")/lib.sh"

image=$1 digest=$2 version=$3
sha=${GITHUB_SHA:-$(git -C "$ROOT" rev-parse HEAD)}
file="$(image_file dev)"

for attempt in 1 2 3 4 5; do
  git -C "$ROOT" fetch --quiet origin "$GITOPS_BRANCH"
  newer=$(git -C "$ROOT" log --format=%h "${sha}..origin/${GITOPS_BRANCH}" -- . \
    ':(exclude)gitops/environments/*/image.yaml' ':(exclude)*.md' | head -1)
  if [[ -n "$newer" ]]; then
    ok "main already has newer code (${newer}); its own run deploys dev. Skipping ${version}."
    exit 0
  fi
  git -C "$ROOT" checkout --quiet --detach "origin/${GITOPS_BRANCH}"
  write_image_file dev "$image" "$digest" "$version"
  commit_gitops "deploy(dev): release-notes ${version} (${digest:7:12}) [ci]" "$file"
  if git -C "$ROOT" push --quiet origin "HEAD:refs/heads/${GITOPS_BRANCH}"; then
    ok "Deployed ${version} to dev: ${image}@${digest}"
    exit 0
  fi
  warn "main moved while pushing (attempt ${attempt}); retrying on the new main"
done
die "Could not update gitops/environments/dev/image.yaml after 5 attempts"
