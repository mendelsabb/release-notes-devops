#!/usr/bin/env bash
# Bring up the whole local stack from nothing (or converge an existing one).
# Safe to re-run: every step checks current state first.
source "$(dirname "$0")/lib.sh"
# shellcheck source=../infrastructure/versions.env
source "$ROOT/infrastructure/versions.env"

LOG_DIR="$ROOT/.local/logs"
HOST_PORTS=(8080 8081 3000 8090 8418)

preflight() {
  log "Checking prerequisites"
  require_cmd docker kind kubectl helm git curl openssl
  docker info >/dev/null 2>&1 || die "Docker is not running. Start Docker Desktop (or your engine) and retry."
  git -C "$ROOT" rev-parse HEAD >/dev/null 2>&1 ||
    die "This directory must be a git repository with at least one commit (Argo CD deploys from git).
    Run: git init && git add -A && git commit -m 'initial import'"
  local mem
  mem=$(docker info --format '{{.MemTotal}}')
  ((mem >= 6 * 1024 * 1024 * 1024)) ||
    warn "Docker has $((mem / 1024 / 1024)) MiB of memory; 6 GiB+ is recommended for the full stack."
  if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    local port busy=()
    for port in "${HOST_PORTS[@]}"; do
      if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then busy+=("$port"); fi
    done
    ((${#busy[@]} == 0)) || die "Host ports already in use: ${busy[*]}. Free them (the kind cluster maps them) and retry."
  fi
  [[ -z "$(git -C "$ROOT" status --porcelain)" ]] ||
    warn "Uncommitted changes are not deployed: Argo CD deploys committed state only."
  ok "Prerequisites satisfied"
}

ensure_registry() {
  if [[ "$(docker inspect -f '{{.State.Running}}' "$REGISTRY_NAME" 2>/dev/null)" == "true" ]]; then
    ok "Local registry already running on 127.0.0.1:${REGISTRY_PORT}"
  elif docker inspect "$REGISTRY_NAME" >/dev/null 2>&1; then
    docker start "$REGISTRY_NAME" >/dev/null && ok "Started local registry"
  else
    log "Starting local image registry on 127.0.0.1:${REGISTRY_PORT}"
    docker run -d --restart=always --name "$REGISTRY_NAME" \
      -p "127.0.0.1:${REGISTRY_PORT}:5000" -v kind-registry-data:/var/lib/registry \
      "$REGISTRY_IMAGE" >/dev/null
  fi
  wait_until 30 "local registry" curl -fsS "http://127.0.0.1:${REGISTRY_PORT}/v2/"
}

ensure_cluster() {
  if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    ok "kind cluster '$CLUSTER_NAME' exists"
  else
    log "Creating kind cluster '$CLUSTER_NAME'"
    kind create cluster --config "$ROOT/infrastructure/kind/cluster.yaml" --wait 120s
  fi
  # Make "localhost:5001/..." image refs resolve to the registry container from
  # inside the node (https://kind.sigs.k8s.io/docs/user/local-registry/).
  local node dir="/etc/containerd/certs.d/localhost:${REGISTRY_PORT}"
  for node in $(kind get nodes --name "$CLUSTER_NAME"); do
    docker exec "$node" mkdir -p "$dir"
    printf '[host."http://%s:5000"]\n' "$REGISTRY_NAME" | docker exec -i "$node" cp /dev/stdin "$dir/hosts.toml"
  done
  if [[ "$(docker inspect -f '{{json .NetworkSettings.Networks.kind}}' "$REGISTRY_NAME")" == "null" ]]; then
    docker network connect kind "$REGISTRY_NAME"
  fi
  k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REGISTRY_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
  k apply -f "$ROOT/infrastructure/namespaces.yaml" >/dev/null
  ok "Cluster, registry wiring and namespaces ready"
}

ensure_secrets() {
  # Generated per cluster, never written to git. Re-runs keep existing values so
  # Postgres data stays readable.
  local env
  for env in "${ENVIRONMENTS[@]}"; do
    if ! k -n "$env" get secret release-notes-db >/dev/null 2>&1; then
      k -n "$env" create secret generic release-notes-db \
        --from-literal=username=release_notes \
        --from-literal=password="$(openssl rand -hex 24)" >/dev/null
      ok "Created database credentials for $env"
    fi
  done
  if ! k -n monitoring get secret grafana-admin >/dev/null 2>&1; then
    k -n monitoring create secret generic grafana-admin \
      --from-literal=admin-user=admin \
      --from-literal=admin-password="$(openssl rand -hex 12)" >/dev/null
  fi
  k -n monitoring create configmap grafana-dashboards \
    --from-file="$ROOT/infrastructure/monitoring/dashboards/" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  ok "Secrets and dashboard ConfigMap in place"
}

# helm_install <release> <namespace> <repo-url> <chart> <version> <values-file>
helm_install() {
  h upgrade --install "$1" "$4" --repo "$3" --version "$5" \
    --namespace "$2" -f "$6" --wait --timeout 10m >"$LOG_DIR/helm-$1.log" 2>&1
}

install_platform() {
  log "Installing platform charts in parallel: Argo CD, Prometheus, Loki, Alloy, Grafana, metrics-server"
  mkdir -p "$LOG_DIR"
  local mon="$ROOT/infrastructure/monitoring" pids=() names=() i failed=0
  helm_install argocd argocd https://argoproj.github.io/argo-helm argo-cd \
    "$ARGOCD_CHART_VERSION" "$ROOT/infrastructure/argocd/values.yaml" &
  pids+=($!) names+=(argocd)
  helm_install prometheus monitoring https://prometheus-community.github.io/helm-charts prometheus \
    "$PROMETHEUS_CHART_VERSION" "$mon/prometheus-values.yaml" &
  pids+=($!) names+=(prometheus)
  helm_install loki monitoring https://grafana.github.io/helm-charts loki \
    "$LOKI_CHART_VERSION" "$mon/loki-values.yaml" &
  pids+=($!) names+=(loki)
  helm_install alloy monitoring https://grafana.github.io/helm-charts alloy \
    "$ALLOY_CHART_VERSION" "$mon/alloy-values.yaml" &
  pids+=($!) names+=(alloy)
  helm_install grafana monitoring https://grafana.github.io/helm-charts grafana \
    "$GRAFANA_CHART_VERSION" "$mon/grafana-values.yaml" &
  pids+=($!) names+=(grafana)
  helm_install metrics-server kube-system https://kubernetes-sigs.github.io/metrics-server/ metrics-server \
    "$METRICS_SERVER_CHART_VERSION" "$mon/metrics-server-values.yaml" &
  pids+=($!) names+=(metrics-server)
  for i in "${!pids[@]}"; do
    if wait "${pids[$i]}"; then
      ok "${names[$i]} installed"
    else
      warn "${names[$i]} failed; see $LOG_DIR/helm-${names[$i]}.log"
      failed=1
    fi
  done
  ((failed == 0)) || die "Platform installation failed (re-running 'make up' is safe)."
}

ensure_git_server() {
  log "Deploying the in-cluster GitOps repository"
  docker build --quiet -t "$GIT_SERVER_IMAGE" "$ROOT/infrastructure/git-server" >/dev/null
  docker push --quiet "$GIT_SERVER_IMAGE" >/dev/null
  sed "s|GIT_SERVER_IMAGE|${GIT_SERVER_IMAGE}|" "$ROOT/infrastructure/git-server/k8s.yaml" | k apply -f - >/dev/null
  k -n git rollout status deployment/git-server --timeout=120s >/dev/null
  wait_until 60 "git server reachable on 127.0.0.1:8418" \
    git ls-remote "$GIT_MIRROR_HOST_URL"
  ok "Git server ready"
}

# True if the image an environment points at can be pulled by the cluster.
image_available() {
  local repo digest
  repo=$(image_field "$1" repository)
  digest=$(image_field "$1" digest)
  # Only an immutable digest counts: a tag could point at a stale build.
  [[ "$digest" == sha256:* ]] || return 1
  if [[ "$repo" == "localhost:${REGISTRY_PORT}/"* ]]; then
    [[ -n "$(registry_digest "${repo#*/}" "$digest")" ]]
  else
    docker manifest inspect "${repo}@${digest}" >/dev/null 2>&1
  fi
}

# A fresh clone may reference images that only exist on another machine (a
# previous local registry, or a private GHCR package). Build the current source
# once and record its digest in git, so Argo CD still deploys from git.
ensure_app_images() {
  local env missing=()
  for env in "${ENVIRONMENTS[@]}"; do
    image_available "$env" || missing+=("$env")
  done
  if ((${#missing[@]} == 0)); then
    ok "Images referenced by gitops/environments/*/image.yaml are available"
    return
  fi
  local version digest files=()
  version="$(sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT/pyproject.toml")"
  log "Building release-notes:${version} from $(git -C "$ROOT" rev-parse --short HEAD) for: ${missing[*]}"
  digest="$(build_and_push "$version")"
  for env in "${missing[@]}"; do
    write_image_file "$env" "$IMAGE_REPO" "$digest" "$version"
    files+=("$(image_file "$env")")
  done
  commit_gitops "deploy(bootstrap): ${missing[*]} -> release-notes ${version} (${digest:7:12})" "${files[@]}"
}

deploy_apps() {
  push_gitops
  k apply -f "$ROOT/gitops/argocd/applications.yaml" >/dev/null
  ok "Argo CD applications registered"
  wait_for_app dev 600
  wait_for_app prod 600
}

smoke_test() {
  local env port
  for env in dev prod; do
    [[ $env == prod ]] && port=8080 || port=8081
    wait_until 60 "$env /ready via localhost:$port" curl -fsS "http://127.0.0.1:$port/ready"
    ok "$env serving version $(curl -fsS "http://127.0.0.1:$port/version" | sed 's/.*"version":"\([^"]*\)".*/\1/') on http://localhost:$port"
  done
}

summary() {
  local grafana_pw argocd_pw
  grafana_pw=$(k -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)
  argocd_pw=$(k -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)
  cat <<EOF

${_B}Release Notes is up.${_N}
  App (prod)   http://localhost:8080
  App (dev)    http://localhost:8081
  Grafana      http://localhost:3000   (anonymous view; admin / ${grafana_pw})
  Argo CD      http://localhost:8090   (admin / ${argocd_pw:-<see argocd-initial-admin-secret>})

Next: make status | make demo-rollout | make rollback ENV=prod | make down
EOF
}

preflight
ensure_registry
ensure_cluster
ensure_secrets
ensure_git_server
install_platform
ensure_app_images
deploy_apps
smoke_test
summary
