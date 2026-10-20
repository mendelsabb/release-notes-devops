# shellcheck shell=bash
# Shared constants and helpers. Sourced by every script in scripts/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT

CLUSTER_NAME="release-notes"
KUBE_CONTEXT="kind-${CLUSTER_NAME}"
REGISTRY_NAME="kind-registry"
REGISTRY_PORT="5001"
IMAGE_REPO="localhost:${REGISTRY_PORT}/release-notes"
GIT_SERVER_IMAGE="localhost:${REGISTRY_PORT}/git-server:1.0.0"
# The in-cluster git server is the GitOps source Argo CD watches.
GIT_MIRROR_REMOTE="cluster-gitops"
GIT_MIRROR_HOST_URL="http://127.0.0.1:8418/release-notes.git"
GIT_MIRROR_CLUSTER_URL="http://git-server.git.svc.cluster.local/release-notes.git"
GITOPS_BRANCH="main"
ENVIRONMENTS=(dev prod)

# --- output -------------------------------------------------------------------
if [[ -t 1 ]]; then
  _B=$'\033[1m' _G=$'\033[32m' _Y=$'\033[33m' _R=$'\033[31m' _N=$'\033[0m'
else
  _B="" _G="" _Y="" _R="" _N=""
fi
log() { printf '%s==>%s %s\n' "$_B" "$_N" "$*"; }
ok() { printf '%s ✓%s %s\n' "$_G" "$_N" "$*"; }
warn() { printf '%s !%s %s\n' "$_Y" "$_N" "$*" >&2; }
die() {
  printf '%s ✗ %s%s\n' "$_R" "$*" "$_N" >&2
  exit 1
}

# --- cluster access: always pin the context so we never touch another cluster --
k() { kubectl --context "$KUBE_CONTEXT" "$@"; }
h() { helm --kube-context "$KUBE_CONTEXT" "$@"; }

require_cmd() {
  local missing=()
  for cmd in "$@"; do command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd"); done
  ((${#missing[@]} == 0)) || die "Missing required tools: ${missing[*]} (see README 'Prerequisites')"
}

require_cluster() {
  kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME" ||
    die "kind cluster '$CLUSTER_NAME' not found. Run 'make up' first."
}

valid_env() {
  [[ " ${ENVIRONMENTS[*]} " == *" $1 "* ]] || die "ENV must be one of: ${ENVIRONMENTS[*]} (got '$1')"
}

# wait_until <timeout-seconds> <description> <command...>
# Polls a condition with a deadline instead of sleeping for a fixed time.
wait_until() {
  local timeout=$1 what=$2
  shift 2
  local deadline=$((SECONDS + timeout))
  until "$@" >/dev/null 2>&1; do
    ((SECONDS < deadline)) || die "Timed out after ${timeout}s waiting for: $what"
    sleep 2
  done
}

# --- images -------------------------------------------------------------------
# build_and_push <version> [extra docker build args...]  -> prints the digest
build_and_push() {
  local version=$1
  shift
  local sha
  sha="$(git -C "$ROOT" rev-parse --short=12 HEAD)"
  docker build --quiet \
    --build-arg "APP_VERSION=${version}" --build-arg "GIT_SHA=${sha}" "$@" \
    -t "${IMAGE_REPO}:${version}" "$ROOT" >/dev/null
  docker push --quiet "${IMAGE_REPO}:${version}" >/dev/null
  registry_digest "release-notes" "$version"
}

# registry_digest <name> <tag> -> manifest digest as stored in the local registry
registry_digest() {
  curl -fs -o /dev/null -D - \
    -H "Accept: application/vnd.oci.image.index.v1+json" \
    -H "Accept: application/vnd.oci.image.manifest.v1+json" \
    -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
    -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
    "http://127.0.0.1:${REGISTRY_PORT}/v2/$1/manifests/$2" |
    awk 'tolower($1)=="docker-content-digest:" {print $2}' | tr -d '\r'
}

# --- GitOps image files -------------------------------------------------------
image_file() { echo "$ROOT/gitops/environments/$1/image.yaml"; }
image_field() { sed -n "s/^  $2: *\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p" "$(image_file "$1")"; }

# write_image_file <env> <repository> <digest> <version>
write_image_file() {
  cat >"$(image_file "$1")" <<EOF
# Desired image for the "$1" environment. Written by automation (CI, make
# release/promote/rollback) — the only thing those workflows change, so image
# rollbacks never revert unrelated configuration.
image:
  repository: $2
  digest: "$3"
  version: "$4"
EOF
}

# commit_gitops <message> <paths...>  (commits only the given paths)
commit_gitops() {
  local msg=$1
  shift
  git -C "$ROOT" add -- "$@"
  if git -C "$ROOT" diff --cached --quiet -- "$@"; then
    warn "No change to commit for: $*"
    return 0
  fi
  git -C "$ROOT" commit --quiet -m "$msg" -- "$@"
  ok "Committed: $msg"
}

# Push the local branch to the in-cluster git server Argo CD watches, then ask
# Argo CD to re-read the repo now instead of waiting for its polling interval.
push_gitops() {
  local branch
  branch="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
  git -C "$ROOT" remote get-url "$GIT_MIRROR_REMOTE" >/dev/null 2>&1 ||
    git -C "$ROOT" remote add "$GIT_MIRROR_REMOTE" "$GIT_MIRROR_HOST_URL"
  # The mirror is a disposable copy of this checkout, so force is safe here.
  git -C "$ROOT" push --quiet --force "$GIT_MIRROR_REMOTE" "HEAD:refs/heads/${GITOPS_BRANCH}"
  ok "Pushed ${branch}@$(git -C "$ROOT" rev-parse --short HEAD) to the in-cluster GitOps repo"
  local env
  for env in "${ENVIRONMENTS[@]}"; do
    terminate_stale_sync "$env"
    k -n argocd annotate application "release-notes-$env" \
      argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
  done
}

# A sync operation that is still retrying keeps using the revision it started
# with, so a newer commit (e.g. a rollback of a release whose migration fails)
# would wait for those retries. Terminate such an operation; automated sync then
# starts a fresh one at the new HEAD. Same effect as `argocd app terminate-op`.
terminate_stale_sync() {
  local app="release-notes-$1" phase revision
  phase=$(k -n argocd get application "$app" -o jsonpath='{.status.operationState.phase}' 2>/dev/null) || return 0
  revision=$(k -n argocd get application "$app" -o jsonpath='{.status.operationState.operation.sync.revision}')
  if [[ "$phase" == "Running" && "$revision" != "$(git -C "$ROOT" rev-parse HEAD)" ]]; then
    warn "Terminating in-progress sync of $app at stale revision ${revision:0:7}"
    k -n argocd patch application "$app" --type merge \
      -p '{"status":{"operationState":{"phase":"Terminating"}}}' >/dev/null
  fi
}

# --- Argo CD / rollout status --------------------------------------------------
app_status() {
  k -n argocd get application "release-notes-$1" \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null
}

app_synced_revision() {
  k -n argocd get application "release-notes-$1" -o jsonpath='{.status.sync.revision}' 2>/dev/null
}

_app_ready() { [[ "$(app_synced_revision "$1")" == "$2" && "$(app_status "$1")" == "Synced/Healthy" ]]; }

# wait_for_app <env> <timeout>: Argo CD has synced the current HEAD *and* the
# app is Healthy. "Synced" alone only means manifests were applied.
wait_for_app() {
  local env=$1 timeout=${2:-300} head
  head="$(git -C "$ROOT" rev-parse HEAD)"
  log "Waiting for Argo CD to sync $env to $(git -C "$ROOT" rev-parse --short HEAD) and report Healthy"
  wait_until "$timeout" "Argo CD application release-notes-$env Synced/Healthy at $head" \
    _app_ready "$env" "$head"
  k -n "$env" rollout status deployment/release-notes --timeout=60s >/dev/null
  ok "release-notes-$env is $(app_status "$env")"
}

# Version reported by the Service, queried from inside the cluster.
served_version() {
  k -n "$1" exec deploy/release-notes -- python -c \
    "import json,urllib.request;print(json.load(urllib.request.urlopen('http://release-notes/version',timeout=5))['version'])"
}

# --- in-cluster traffic generator ----------------------------------------------
TRAFFIC_IMAGE="python:3.12.15-slim"

# traffic_start <env> <duration> [extra traffic.py args...]: starts the Job, returns immediately.
traffic_start() {
  local env=$1 duration=$2
  shift 2
  local args=("--url" "http://release-notes.${env}.svc.cluster.local/api/releases?limit=5"
    "--duration" "$duration" "$@")
  k -n "$env" delete job traffic --ignore-not-found --wait=true >/dev/null
  k -n "$env" create configmap traffic-script --from-file="$ROOT/scripts/traffic/traffic.py" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  local arg_json="" a
  for a in "${args[@]}"; do arg_json+="\"${a}\", "; done
  k -n "$env" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: traffic
  labels: { app.kubernetes.io/name: traffic-generator }
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels: { app.kubernetes.io/name: traffic-generator }
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: traffic
          image: ${TRAFFIC_IMAGE}
          command: ["python", "-u", "/scripts/traffic.py", ${arg_json%, }]
          env: [{ name: PYTHONDONTWRITEBYTECODE, value: "1" }]
          resources:
            requests: { cpu: 100m, memory: 64Mi }
            limits: { cpu: "1", memory: 128Mi }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
          volumeMounts: [{ name: script, mountPath: /scripts }]
      volumes:
        - name: script
          configMap: { name: traffic-script }
EOF
  wait_until 120 "traffic generator pod to start in $env" _traffic_running "$env"
  ok "Traffic generator running in $env for ${duration}s"
}

_traffic_running() {
  [[ -n "$(k -n "$1" get pods -l job-name=traffic \
    -o jsonpath='{.items[0].status.containerStatuses[0].state.running}' 2>/dev/null)" ]]
}

_traffic_done() {
  [[ -n "$(k -n "$1" get job traffic -o jsonpath='{.status.succeeded}{.status.failed}' 2>/dev/null)" ]]
}

# traffic_wait <env>: block until the Job finishes, show its output, return its verdict.
traffic_wait() {
  local env=$1
  wait_until 900 "traffic generator in $env to finish" _traffic_done "$env"
  mkdir -p "$ROOT/.local"
  k -n "$env" logs job/traffic >"$ROOT/.local/traffic-${env}.log"
  grep -v '^SUMMARY ' "$ROOT/.local/traffic-${env}.log"
  sed -n 's/^SUMMARY //p' "$ROOT/.local/traffic-${env}.log" >"$ROOT/.local/traffic-${env}.json"
  [[ "$(k -n "$env" get job traffic -o jsonpath='{.status.succeeded}')" == "1" ]]
}
