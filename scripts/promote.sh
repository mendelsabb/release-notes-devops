#!/usr/bin/env bash
# Promote the image currently deployed to dev to prod: same digest, no rebuild
# (build once, deploy many). Only gitops/environments/prod/image.yaml changes.
# GITOPS_ONLY=1 (used by CI): only write + commit; no cluster gate, push or wait.
source "$(dirname "$0")/lib.sh"
gitops_only=${GITOPS_ONLY:-0}
if [[ "$gitops_only" != "1" ]]; then
  require_cluster
  sync_main
fi

repo=$(image_field dev repository)
digest=$(image_field dev digest)
version=$(image_field dev version)
[[ "$digest" == sha256:* ]] || die "dev has no image digest to promote"

# Gate: dev must actually be running and healthy on this digest. In CI the gate
# is the reviewed promotion PR plus Argo CD's dev health.
dev_gate() {
  [[ "$(app_status dev)" == "Synced/Healthy" ]] || die "dev is $(app_status dev); promote only from a healthy dev"
  local dev_image
  dev_image=$(k -n dev get deploy release-notes -o jsonpath='{.spec.template.spec.containers[0].image}')
  [[ "$dev_image" == *"@${digest}" ]] || die "dev is running $dev_image, not the digest in git ($digest)"
  [[ "$(served_version dev)" == "$version" ]] || die "dev serves $(served_version dev), expected $version"
  ok "dev gate passed: Synced/Healthy and serving $version"
}
[[ "$gitops_only" == "1" ]] || dev_gate

if [[ "$(image_field prod digest)" == "$digest" ]]; then
  ok "prod already runs $version ($digest)"
  exit 0
fi
write_image_file prod "$repo" "$digest" "$version"
msg="promote(prod): release-notes ${version} (${digest:7:12}) from dev"
if [[ "$gitops_only" == "1" ]]; then
  commit_gitops "$msg" "$(image_file prod)"
  exit 0
fi
deliver_change "$msg" "$(image_file prod)"

[[ "${NO_WAIT:-0}" == "1" ]] && exit 0
wait_for_app prod 300
wait_for_version prod "$version"
