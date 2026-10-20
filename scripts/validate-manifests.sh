#!/usr/bin/env bash
# Static validation of every deployment definition (no cluster needed):
#   helm lint + helm template for each environment, then kubeconform schema
#   validation (Kubernetes 1.35 + Argo CD CRDs) of rendered and plain manifests.
# kubeconform runs from its container image unless installed locally.
source "$(dirname "$0")/lib.sh"
require_cmd helm

KUBE_VERSION=1.35.0
KUBECONFORM_IMAGE=ghcr.io/yannh/kubeconform:v0.7.0
out="$ROOT/.local/rendered"
mkdir -p "$out"

for env in "${ENVIRONMENTS[@]}"; do
  values=(-f "$ROOT/gitops/environments/$env/values.yaml" -f "$ROOT/gitops/environments/$env/image.yaml")
  # A fresh checkout may not have a digest yet; render with a placeholder tag then.
  [[ "$(image_field "$env" digest)" == sha256:* ]] || values+=(--set image.tag=validate)
  helm lint --strict "$ROOT/helm/release-notes" "${values[@]}" >/dev/null
  helm template release-notes "$ROOT/helm/release-notes" --namespace "$env" \
    --kube-version "$KUBE_VERSION" "${values[@]}" >"$out/$env.yaml"
  ok "helm lint + template: $env ($(grep -c '^kind:' "$out/$env.yaml") objects)"
done
sed "s|GIT_SERVER_IMAGE|${GIT_SERVER_IMAGE}|" "$ROOT/infrastructure/git-server/k8s.yaml" >"$out/git-server.yaml"
cp "$ROOT/infrastructure/namespaces.yaml" "$ROOT/gitops/argocd/applications.yaml" "$out/"

kubeconform_args=(-strict -summary -kubernetes-version "$KUBE_VERSION"
  -schema-location default
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json')
if command -v kubeconform >/dev/null 2>&1; then
  kubeconform "${kubeconform_args[@]}" "$out"
else
  require_cmd docker
  docker run --rm -v "$out:/manifests:ro" "$KUBECONFORM_IMAGE" "${kubeconform_args[@]}" /manifests
fi
ok "All manifests valid against Kubernetes ${KUBE_VERSION} schemas"
