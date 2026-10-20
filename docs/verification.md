# Verification record

Everything below was executed on **2026-10-20** on a MacBook (Apple silicon, 10 CPUs). Docker
Desktop 29.4 had 8 GB of RAM. The stack ran on kind 0.33 with Kubernetes 1.35.1, Helm 4.1.1 and
Argo CD 3.5 (chart 10.10.5). Unless noted, the numbers come from the final run in a **fresh clone**
after `make clean` (no cluster, no registry), which is what a reviewer would do. Earlier runs during
development gave the same results within the ranges shown.

## Static checks and tests

| Check | Command | Result |
|---|---|---|
| Lint | `make lint` (ruff check + format, shellcheck) | clean |
| Dockerfile lint | `hadolint` 2.12 | clean |
| Workflow lint | `actionlint` 1.7.7 on `.github/workflows/*` | clean |
| Unit tests | `pytest tests/unit` | 33 passed |
| Integration tests (Postgres 17, Alembic) | `pytest tests/integration` | 9 passed |
| Chart policy tests | `pytest tests/chart` | 21 passed |
| **Total** | `make test` | **63 passed, 0 failed, 0 skipped** |
| Manifests | `make validate` (helm lint --strict, template dev+prod, kubeconform -strict incl. Argo CD CRDs) | 29 resources valid, 0 skipped |
| Misconfiguration scan | Trivy 0.67 `config` on rendered manifests + Dockerfile | 0 HIGH/CRITICAL |
| Image vulnerabilities | Trivy 0.67 `image`, fixable HIGH/CRITICAL | 0 (after replacing `psycopg[binary]`, see below) |
| CI shell logic | CI's smoke-test step, digest commit, promote/rollback PR preparation (`GITOPS_ONLY=1`) executed locally under bash | all passed |

## Bootstrap

| Run | Result |
|---|---|
| `make up` from nothing (fresh clone, registry and cluster deleted) | Synced/Healthy dev and prod in **3 min 30 s**; built the image once and committed `deploy(bootstrap): dev prod -> release-notes 1.0.0` |
| `make up` re-run on an existing cluster | converges without changes (idempotent) |
| `make e2e` | **38/38 checks passed**: UI, create/list/409/422 in both envs, `/version` = git, running digest = git, Argo CD Synced/Healthy at the GitOps repo HEAD, PVCs bound, headless DB Service, pod hardening, Prometheus `up`/counters/histograms/build info/kube-state-metrics/p95, Loki logs by env/pod/level (and no DEBUG in prod), Grafana dashboard + both data sources healthy |
| UI in a real browser | headless Chrome rendered the page; JS loaded the version badge (`v1.0.0 · <sha>`, `DEV`) and the release history |
| NetworkPolicy | pod without the API labels → `TimeoutError` to Postgres; pod with them → connected |
| Pod Security | `dev`/`prod` enforce `restricted`; app, Postgres, migration Job and traffic Job all admitted |

## Rollouts, rollback and failures (in-cluster traffic, ~40 req/s, new connection per request)

| Scenario | Requests | Failed | Notes |
|---|---|---|---|
| `make demo-rollout` 1.0.0 → 1.1.0 (prod, 4 pods via HPA) | 6,002 | **0** | 1.0.0 last seen at 46.4 s, 1.1.0 first seen at 23.6 s; p95 23 ms, max 79 ms |
| `make rollback ENV=prod` under traffic | 4,000 | **0** | one-file commit; Healthy and serving the old version about 35 s after the commit |
| `make demo-broken-rollout` | 9,599 | **0** | new pod never Ready; 4/4 old pods available; `ProgressDeadlineExceeded`; Argo CD `Synced/Degraded`; rollback restored Healthy |
| `make demo-pod-kill` (graceful delete) | 2,400 | **0** | replica replaced |
| `CRASH=1 make demo-pod-kill` (SIGKILL) | 1,801–1,803 | 4–8 | `ConnectionRefused` within a few ms of the kill, until kube-proxy/kubelet react. Expected: no drain on a crash |
| `make demo-db-restart` | 3,600 | 48–80 | HTTP 503 for about 2–3 s while Postgres restarts; same PVC, marker row intact, 0 API restarts. Expected: single DB instance |
| Rollout with `--keepalive` clients (no client retry) | 6,003 | 11 | `RemoteDisconnected`: uvicorn closes idle keep-alive connections on shutdown. Browsers and most HTTP clients retry idempotent requests in this case; Python's `http.client` does not. See DECISIONS.md |

The traffic generator is the source of truth for these numbers. It runs as a Job in the target
namespace and calls the Service DNS name, so refused connections and timeouts that never reach a
pod are counted too.

## Defects found by running the system (and fixed)

1. `alembic` CLI could not import `app` in the container → `prepend_sys_path` in `alembic.ini`.
2. Sync-wave deadlock: the HPA (wave 0) was Degraded until its Deployment (wave 2) existed, so the
   sync never progressed → HPA/PDB moved to wave 3.
3. A retrying Argo CD sync keeps its original revision, so a fix or rollback commit waited behind it.
   Fixed with faster failure (2 retries, Job `backoffLimit: 2`); the scripts also terminate a
   running sync that is pinned to an older revision.
4. `psycopg[binary]` vendors libpq/OpenSSL/pcre2 from AlmaLinux 8 (Trivy: 3 CRITICAL, 5 HIGH),
   which OS updates never patch → the image uses Debian's `libpq5`; the binary wheel is dev-only.
5. bash 3.2 (stock macOS) fails on empty arrays under `set -u` → portable expansion.
6. `*.env` in `.gitignore` silently excluded `infrastructure/versions.env`; caught only by the
   fresh-clone test.
7. Version checks right after a rollout could hit a pod still in its preStop window → scripts poll
   until the Service converges.
8. Postgres `preStop: pg_ctl stop` was redundant: containerd honours the image's `STOPSIGNAL SIGINT`
   (verified: "received fast shutdown request").

## Not verified

- **GitHub Actions on GitHub.** The workflows pass actionlint and their shell logic was executed
  locally, but they have not run on GitHub: no repository was created or pushed for this
  submission. In particular, GHCR publishing, multi-arch builds, `gh pr create` permissions and the
  `GITHUB_TOKEN` push to `main` are unverified.
- Argo CD tracking a hosted GitHub repo (`repoURL` change) was not exercised; the in-cluster mirror
  was.
