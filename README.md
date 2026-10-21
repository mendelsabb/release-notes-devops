# Release Notes

A tiny internal service for recording what shipped in each release. It runs the way a production
service would: containerised, deployed to Kubernetes by GitOps, observable, and rolled out without
downtime.

- **Service:** FastAPI API + plain HTML/JS UI, PostgreSQL (SQLAlchemy, Alembic migrations), JSON
  logs, Prometheus metrics, liveness/readiness endpoints, unit, integration and chart tests.
- **Platform:** a local [kind](https://kind.sigs.k8s.io/) cluster, one Helm chart for `dev` and
  `prod`, Argo CD, Prometheus, Grafana, Loki and Alloy, all brought up by **`make up`**.
- **Delivery:** GitHub Actions (lint → test → validate → build → scan → publish to GHCR → commit
  digest). Build once, promote the same digest to prod by pull request, and roll back by restoring
  the previous digest.

Trade-offs and limitations are in [DECISIONS.md](DECISIONS.md). What was actually executed, with
numbers, is in [docs/verification.md](docs/verification.md). Day-to-day tasks (adding an
environment, schema changes, troubleshooting) are in [docs/operations.md](docs/operations.md).

## Architecture

```mermaid
flowchart LR
  subgraph kind["kind cluster"]
    subgraph prod["namespace prod (and the same in dev)"]
      svc[Service] --> api["release-notes Deployment<br/>2-4 pods, HPA, PDB"]
      api --> db[("PostgreSQL StatefulSet<br/>+ PVC")]
      job["migration Job<br/>(Argo CD sync hook)"] --> db
    end
    argo[Argo CD<br/>root app → ApplicationSet] -- "one app per gitops/environments/*<br/>same chart, same branch" --> prod
    prom[Prometheus] -- scrape /metrics --> api
    alloy[Alloy] -- container logs --> loki[Loki]
    graf[Grafana] --> prom & loki
  end
  user((Browser / curl)) -- "localhost:8080" --> svc
  gh[("GitHub repo<br/>main")] -- "polled by" --> argo
  ci((GitHub Actions)) -- "commit dev digest" --> gh
  you((you)) -- "pull requests<br/>release / promote / rollback" --> gh
  ci -- "push image" --> reg[("GHCR")]
  reg -. image by digest .-> api
```

**Runtime.** Each environment is a namespace containing the API Deployment, a Postgres
StatefulSet with its own PVC and generated credentials, a NetworkPolicy that only lets the API and
migration pods reach Postgres, and (prod only) an HPA (2–4 replicas) and a PodDisruptionBudget. The
API's `/health` (liveness) never touches the database, while `/ready` (readiness) queries the
`releases` table. A database outage therefore takes pods out of the Service without restarting
them.

**Delivery.** Environments are **folders on one branch**, not branches. `make up` creates a single
root Application (app-of-apps, `infrastructure/argocd/root-app.yaml`). It syncs
`gitops/argocd/`: an AppProject and an **ApplicationSet** whose Git directory generator creates one
Application per folder in `gitops/environments/`. Every environment renders the same chart from
`main` with its own `values.yaml` (configuration) and `image.yaml` (the image **digest**, the only
file automation changes). So:

- a merge to `main` → CI builds once, pushes to GHCR and commits the new digest to
  `dev/image.yaml` → Argo CD deploys **dev**;
- **prod** only changes when a pull request that edits `prod/image.yaml` is merged (promotion of
  dev's exact digest, or a rollback);
- a new environment is a new folder (plus its namespace in the AppProject).

![GitOps delivery: root app → ApplicationSet → one Application per environment folder](docs/gitops-architecture.png)

*Source: [docs/gitops-architecture.drawio](docs/gitops-architecture.drawio) (open with draw.io / diagrams.net).*

| Mode | Argo CD watches | Images | `make release / promote / rollback` |
|---|---|---|---|
| **github** (default) | the GitHub repo (`origin`) | GHCR, built only by CI | open a pull request, wait for CI, merge, wait for Argo CD |
| **local** (`make up GITOPS_MODE=local`) | an in-cluster git server mirroring your checkout | local registry `localhost:5001` | commit locally and push to the mirror |

Local mode is for reviewers without push rights to the repository, or offline use: the same
GitOps mechanics, but nothing leaves the laptop. `make up` remembers the mode for later commands.

**Observability.** Prometheus discovers pods via `prometheus.io/*` annotations and keeps
`namespace`/`pod` labels, so dev and prod are separate series. kube-state-metrics adds replica
availability. Alloy tails container logs via the Kubernetes API and sends them to Loki, promoting
the JSON `level` field to a label. Grafana is provisioned with both data sources and a *Release
Notes* dashboard.

## Prerequisites

| Tool | Tested with | Notes |
|---|---|---|
| Docker (Desktop or Engine) | 29.4 | give it **≥ 6 GB RAM** (8 GB comfortable) and 4 CPUs |
| kind | 0.33 | node image pinned to Kubernetes 1.35.1 |
| kubectl | 1.35 | |
| Helm | 4.1 (3.x also works) | charts are installed with `--repo`, no `helm repo add` needed |
| git, curl, openssl, make | any recent | scripts are bash 3.2 compatible (stock macOS) |
| [uv](https://docs.astral.sh/uv/) | 0.12 | tests/lint, and the version bump in `make release` (GitHub mode) |
| [gh](https://cli.github.com/) | 2.x | GitHub mode only: `make release/promote/rollback` open and merge pull requests |

GitHub mode also needs `gh auth login` and push rights to the repository for
`make release/promote/rollback`; Argo CD itself reads the public repo anonymously.

Free host ports: 8080, 8081, 3000, 8090, 8418 (cluster) and 5001 (registry). They bind to
`127.0.0.1` only. The running stack uses about 4 GB of memory and about 6 GB of disk for images.

## Quick start

```bash
make up        # cluster, platform, both environments from GitHub (~4 min measured; longer on first image pulls)
make up GITOPS_MODE=local   # same, but offline: in-cluster git mirror + local registry
make status    # desired state in git vs what Argo CD / Kubernetes report
make e2e       # 38 end-to-end checks against the running stack
```

**Reviewing without push access to this repository?** `make up` works as is (Argo CD only reads
the public repo), but `make release/promote/rollback` and the rollout demos open pull requests here.
Run everything with `make up GITOPS_MODE=local` instead: same GitOps flow, with an in-cluster git
mirror and a local registry, nothing leaves your machine.

`make up` is idempotent; rerun it to converge after a failure. It:

1. checks prerequisites, Docker memory and free ports;
2. starts a local registry and a kind cluster wired to it, then creates the namespaces (`dev`/`prod`
   enforce the *restricted* Pod Security Standard);
3. generates per-environment DB credentials and the Grafana admin password as Kubernetes Secrets
   (never written to git);
4. installs Argo CD, Prometheus, Loki, Alloy, Grafana and metrics-server (pinned chart versions in
   `infrastructure/versions.env`, installed in parallel), plus the in-cluster git server in local
   mode;
5. checks that the image digests in `gitops/environments/*/image.yaml` can be pulled. In GitHub
   mode a missing image is an error (images come only from CI). In local mode it **builds the
   current commit once and commits the digest** (`deploy(bootstrap): ...`) so Argo CD still deploys
   from git;
6. registers the root Application (pointed at your `origin`, or at the mirror in local mode) and
   waits until both environments are *Synced* **and** *Healthy* at the desired commit, then
   smoke-tests them.

Only committed (and, in GitHub mode, pushed) changes are deployed: that's GitOps.

### Access

| What | URL | Credentials |
|---|---|---|
| App, prod | http://localhost:8080 | – |
| App, dev | http://localhost:8081 | – |
| Grafana | http://localhost:3000 → *Dashboards → Release Notes* | anonymous read-only; admin password printed by `make up` |
| Argo CD | http://localhost:8090 | `admin` / printed by `make up` |
| API docs | http://localhost:8080/api/docs | – |

### Using the API

```bash
curl -s -X POST localhost:8080/api/releases -H 'Content-Type: application/json' \
  -d '{"version":"2.4.0","description":"New export button; fixed login timeout"}'   # 201
curl -s 'localhost:8080/api/releases?limit=20'      # newest first
curl -s localhost:8080/version                       # {"version":"1.0.0","git_sha":...,"environment":"prod"}
```

A duplicate version returns `409`, invalid input `422`, and a database outage `503` with
`Retry-After`. Every response carries `X-Request-ID` and `X-App-Version`.

## Tests and validation

```bash
make lint       # ruff (lint + format), shellcheck
make test       # unit + integration (throwaway Postgres container, real Alembic migrations) + chart policy tests
make validate   # helm lint/template for dev and prod + kubeconform (K8s 1.35 + Argo CD CRD schemas)
make e2e        # against the running cluster: API, UI, Argo CD, Prometheus, Loki, Grafana, pod hardening
```

- **Unit** (no DB): validation rules, liveness vs readiness under a DB outage, 503 without leaking
  connection details, request-ID handling, metric label cardinality, JSON log fields.
- **Integration** (Postgres): migrations up/down, create/list, deterministic ordering, `409` on
  duplicates, **8 concurrent duplicate POSTs → exactly one `201`**, persistence across app
  instances, readiness failing when the schema is missing.
- **Chart** (`helm template` + assertions): no Secrets rendered, digests pinned, probes,
  requests/limits, restricted security context, grace period > preStop + drain, rollout strategy,
  sync-wave ordering, per-environment replicas, HPA and log levels.

## Delivery: release, promote, roll back

Each one is a reviewed change to Git; Argo CD does the deploying. In GitHub mode every command
opens a pull request, waits for CI on it, merges it (the merge is the approval) and waits for Argo
CD; in local mode it commits and pushes to the mirror.

```bash
make release VERSION=1.1.0   # github: version-bump PR -> CI builds once, pushes to GHCR, commits dev's digest
                             # local:  build the current commit into the local registry, set dev's digest
make promote                 # gate: dev Synced/Healthy and serving that digest -> same digest to prod
make rollback ENV=prod       # restore prod's previous digest from git history (only image.yaml changes)
TO=<git-rev> make rollback ENV=prod   # ...or the image.yaml as of a specific commit
```

`make rollback` reverts the **image only**. Schema migrations are not rolled back; they are
written to be backward compatible (expand/contract), so the previous image runs against the newer
schema. Data is never rolled back; that would be a restore from backup.

### CI/CD on GitHub

- **`.github/workflows/ci.yml`** runs on every PR and push to `main`:
  1. lint (ruff, shellcheck, hadolint, actionlint);
  2. tests against a Postgres service container (`REQUIRE_DB=1`, so integration tests fail rather
     than skip);
  3. `validate-manifests.sh` and a Trivy config scan;
  4. an image build tagged `<version>-<sha7>`, a smoke test (read-only, non-root, `/version`,
     `alembic history`) and a Trivy vulnerability scan (fails on fixable HIGH/CRITICAL).

  A manual run with `simulate_unready: true` builds the failed-rollout drill image instead and
  publishes it as `<version>-unready-<sha7>` without deploying it (used by
  `make demo-broken-rollout`).

  On `main` only, after all of that, **publish** pushes a multi-arch image (with SBOM and
  provenance) to `ghcr.io/<owner>/release-notes` and commits its digest to
  `gitops/environments/dev/image.yaml`. That commit is made with `GITHUB_TOKEN`, so it does not
  trigger another run, and `paths-ignore` skips image-only commits anyway.
- **`.github/workflows/gitops-change.yml`** (manual) opens a **pull request** that either promotes
  dev's digest to prod or rolls an environment back, for people who prefer the GitHub UI to
  `make`. It reuses `scripts/promote.sh` / `scripts/rollback.sh` with `GITOPS_ONLY=1`. Merging the
  PR is the approval, and Argo CD deploys.

Verified on [github.com/mendelsabb/release-notes-devops](https://github.com/mendelsabb/release-notes-devops/actions)
(runs linked in [docs/verification.md](docs/verification.md)). Repository settings this needs: Actions allowed to *create pull requests* and to write
`contents`/`packages`. The GHCR package must be **public** (or the cluster needs an
`imagePullSecret`). If `main` is protected against direct pushes, change the dev step to open a PR
as well. Argo CD's repository URL is taken from your `origin` remote at `make up`, so a fork
works without editing files.

## Zero-downtime rollout

```bash
make demo-rollout            # or VERSION=1.2.0 make demo-rollout
```

1. Releases the next version to dev (build once) and waits for dev to be Healthy.
2. Starts the **traffic generator as a Job inside the cluster**, against
   `http://release-notes.prod.svc.cluster.local`. No port-forward, so it sees kube-proxy and
   endpoint behaviour as a real client would. By default it sends about 40 req/s with a new
   connection per request and a 5 s timeout, and classifies each request as `ok`, `http_error`,
   `timeout` or `conn_error`.
3. Promotes the same digest to prod, follows `kubectl rollout status` and Argo CD health, and waits
   until the old pods have drained and terminated.
4. Prints the generator's report (totals, failure breakdown, p50/p95/p99, and first/last time each
   version was seen) and **exits non-zero if any request failed**.

Measured: **6,002 requests, 0 failed** during 1.0.0 → 1.1.0 (details in
[docs/verification.md](docs/verification.md)). The version switch is visible in the UI's header
badge, `/version` and the `X-App-Version` header. All of these come from build arguments baked into
the image.

You can also measure manually: run `make traffic ENV=prod DURATION=180` in one terminal and
`make release VERSION=x` / `make promote` / `make rollback ENV=prod` in another. Extra generator flags
(`--keepalive`, `--rps`, `--max-failures`, see `scripts/traffic/traffic.py`) go through the script, e.g.
`scripts/traffic.sh prod 180 --rps 80`.

What makes it work: `maxSurge: 1, maxUnavailable: 0`; readiness gates traffic and `minReadySeconds: 5`;
a `preStop` sleep of 5 s so endpoint removal propagates before shutdown; uvicorn drains in-flight
requests on SIGTERM for up to 20 s; `terminationGracePeriodSeconds: 35` > 5 + 20 (a chart test
enforces this); `progressDeadlineSeconds: 120` turns a stuck rollout into a visible failure.

## Failure scenarios

| Command | What happens | Measured |
|---|---|---|
| `make demo-broken-rollout` | deploys an image whose `/ready` always fails, under traffic | new pod never Ready, 4 old pods keep serving, `ProgressDeadlineExceeded`, Argo CD **Synced/Degraded**; auto `make rollback` → Healthy; **0 of ~9,600** requests failed |
| `make demo-pod-kill` | `kubectl delete pod` on one prod pod, under traffic | replica restored; **0 of 2,400** failed |
| `CRASH=1 make demo-pod-kill` | SIGKILL of the app process (no preStop, no drain) | kubelet restarts the container; **4–8 of ~1,800** failed (connection refused, a few ms window) |
| `make demo-db-restart` | deletes the Postgres pod, under traffic | same PVC re-attached, data intact, back in about 2–3 s, no API restarts (liveness ignores the DB); **48–80 of ~3,600** got `503`. Postgres is a single point of failure |
| `make rollback ENV=prod` | GitOps rollback under traffic | about 35 s to Healthy; **0 of 4,000** failed |
| `scripts/traffic.sh prod 150 --keepalive --max-failures 1000000` during a rollout | persistent connections, no client retry | **11 of 6,003** failed (`RemoteDisconnected` when a draining pod closes idle connections); see DECISIONS.md |

The demos only act on the local kind cluster: `scripts/lib.sh` pins every kubectl call to
`--context kind-release-notes`.

## Logs and metrics

- **Grafana → Release Notes**: available replicas, request rate, 5xx ratio, pods per running
  version (watch it flip during a rollout), latency p50/p95/p99, status distribution, scrape health,
  log volume by level, and an application log panel. *Environment* and *Log level* variables filter
  every panel.
- **Loki** (Grafana → Explore → Loki):
  ```logql
  {namespace="prod", app="release-notes", component="api", level="ERROR"}
  {namespace="dev", pod=~"release-notes-.*"} | json | route="/api/releases" | status >= 400
  ```
- **Prometheus** (Grafana → Explore):
  ```promql
  sum by (namespace, status) (rate(http_requests_total{route!~"/health|/ready|/metrics"}[1m]))
  histogram_quantile(0.95, sum by (namespace, le) (rate(http_request_duration_seconds_bucket[5m])))
  sum by (namespace, version) (release_notes_build_info)
  ```

Log lines are JSON with `timestamp, level, logger, message, service, version, env, request_id,
method, route, path, status, duration_ms` (and `exc_type`/`exc_info` on errors). Probe and scrape
requests log at DEBUG, so they appear in dev but not in prod (INFO). Errors are always visible.
Credentials and connection strings are never logged.

The traffic generator, not Grafana, is the source of truth for downtime. Application metrics can't
count requests that never reached a pod (refused connections, timeouts).

## Repository layout

```text
app/                      FastAPI service (config, db, models, schemas, api, observability) + static UI
alembic/                  migrations (run by the Argo CD sync-hook Job)
tests/                    unit/, integration/ (Postgres), chart/ (helm template policy tests)
Dockerfile                multi-stage, non-root, read-only-rootfs compatible
helm/release-notes/       the one chart (API, Postgres, migration Job, HPA/PDB, NetworkPolicy)
gitops/environments/      one folder per environment: values.yaml + image.yaml (desired state)
gitops/argocd/            AppProject + ApplicationSet (synced by the root app)
infrastructure/           kind config, namespaces, Argo CD root app, platform chart values, dashboard,
                          git server (local mode only)
scripts/                  up/down/status, release/promote/rollback, traffic, verify, demo/*
.github/workflows/        ci.yml, gitops-change.yml
docs/verification.md      what was executed and the results
```

## Clean up

```bash
make down    # deletes the kind cluster: ALL data (both Postgres PVCs, metrics, logs, git mirror) is gone
make clean   # also removes the local registry container + its volume and the git remote
```

## Known limitations

- Postgres is a single instance per environment: persistent, but not HA and not backed up.
- Secrets are generated by `make up` and live only in the cluster. A real setup would use External
  Secrets or Sealed Secrets.
- No TLS, Ingress, alerting rules or SLOs. Grafana allows anonymous read-only viewing on localhost.
- Code and deployment config share one repository (the assignment asks for one). The Argo CD docs
  recommend a separate config repo for cleaner history and access control; the CI loop it warns
  about is avoided here with `paths-ignore` and `GITHUB_TOKEN` commits.
- `make release/promote/rollback` merge their own pull request once CI passes; on a team, branch
  protection with a required reviewer would make the merge a human decision.
- PRs opened by the *GitOps change* workflow use `GITHUB_TOKEN`, so GitHub does not run CI on them
  (the digest was already built and tested on `main`). A GitHub App token would fix that.
- Local mode only: the in-cluster git server accepts anonymous pushes. It's reachable only from
  inside the cluster and from `127.0.0.1`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Host ports already in use` | stop whatever uses 8080/8081/3000/8090/8418, or `make down` an old cluster |
| a platform chart failed | `make up` again; logs are in `.local/logs/helm-<name>.log` |
| app stuck `OutOfSync`/`Progressing` | `make status`; `kubectl -n argocd get application release-notes-prod -o yaml`; check the migration Job logs: `kubectl -n prod logs job/release-notes-migrate` |
| changes not deployed | GitHub mode: they must be merged on `main` (`make status` shows the synced commit); local mode: commit them and rerun `make up` (pushes HEAD to the mirror) |
| `make up` says an image can't be pulled | GitHub mode uses CI-built images only: check the CI run on `main` and that the GHCR package is public, or use `make up GITOPS_MODE=local` |
| pods `ImagePullBackOff` after `make clean` | the registry was wiped; `make up` rebuilds and records new digests |
| Docker out of memory | raise Docker's memory to 6–8 GB |
