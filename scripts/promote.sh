#!/usr/bin/env bash
# Promote the image currently deployed to dev to prod: same digest, no rebuild
# (build once, deploy many). Only gitops/environments/prod/image.yaml changes.
source "$(dirname "$0")/lib.sh"
require_cluster

repo=$(image_field dev repository)
digest=$(image_field dev digest)
version=$(image_field dev version)
[[ "$digest" == sha256:* ]] || die "dev has no image digest to promote"

# Gate: dev must actually be running and healthy on this digest.
[[ "$(app_status dev)" == "Synced/Healthy" ]] || die "dev is $(app_status dev); promote only from a healthy dev"
dev_image=$(k -n dev get deploy release-notes -o jsonpath='{.spec.template.spec.containers[0].image}')
[[ "$dev_image" == *"@${digest}" ]] || die "dev is running $dev_image, not the digest in git ($digest)"
dev_version="$(served_version dev)"
[[ "$dev_version" == "$version" ]] || die "dev serves $dev_version, expected $version"
ok "dev gate passed: Synced/Healthy and serving $version"

if [[ "$(image_field prod digest)" == "$digest" ]]; then
  ok "prod already runs $version ($digest)"
  exit 0
fi
write_image_file prod "$repo" "$digest" "$version"
commit_gitops "promote(prod): release-notes ${version} (${digest:7:12}) from dev" "$(image_file prod)"
push_gitops

if [[ "${NO_WAIT:-0}" == "1" ]]; then exit 0; fi
wait_for_app prod 300
actual="$(served_version prod)"
[[ "$actual" == "$version" ]] || die "prod Service reports version $actual, expected $version"
ok "prod is serving release-notes $version"
