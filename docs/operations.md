# Operations runbook

Day-to-day tasks for running Release Notes, for whoever is on call. Every change to what runs in
the cluster goes through Git. The commands below assume GitHub mode (the default), where each
`make` delivery command opens a pull request, waits for CI, merges it and waits for Argo CD. In
local mode (`make up GITOPS_MODE=local`) the same commands commit and push to the in-cluster mirror.

## Quick reference

| I want to… | Do this |
|---|---|
| see what is deployed vs what Git wants | `make status` |
| ship a new version to dev | `make release VERSION=1.3.0` |
| ship what is in dev to prod | `make promote` |
| undo the last prod image change | `make rollback ENV=prod` |
| go back to a specific image | `TO=<commit> make rollback ENV=prod` |
| change replicas, log level, resources… | edit `gitops/environments/<env>/values.yaml`, open a PR |
| add / remove an environment | [below](#add-an-environment) |
| check the whole stack works | `make e2e` |
| measure availability while changing something | `make traffic ENV=prod DURATION=300` in a second terminal |

## How a change reaches an environment

```text
gitops/environments/<env>/values.yaml   configuration (people edit via PR)
gitops/environments/<env>/image.yaml    image digest   (CI for dev, PRs for prod)
          │
          ▼  merged to main on GitHub
Argo CD (polls every 60s, the scripts trigger a refresh) renders helm/release-notes
with those two files and applies the result to namespace <env>:
  wave 0  Postgres StatefulSet + Service      (waits until Healthy)
  wave 1  migration Job: alembic upgrade head  (sync hook, waits until Complete)
  wave 2  API Deployment, Service, ConfigMap   (rolling update)
  wave 3  HPA, PodDisruptionBudget
```

Argo CD has two statuses. **Sync** means the manifests match Git. **Health** means the workloads
actually work. A bad release shows as `Synced/Degraded`. Never treat "Synced" alone as success.

## Release, promote, roll back

- **Release** (`make release VERSION=x`): opens a PR bumping `pyproject.toml`. After merge, CI builds
  the image once, pushes it to GHCR and commits its digest to `dev/image.yaml`. Argo CD deploys dev.
- **Promote** (`make promote`): refuses unless dev is `Synced/Healthy` and actually serving the
  digest in Git. Then it opens a PR copying dev's digest into `prod/image.yaml`: same bytes, no
  rebuild.
- **Roll back** (`make rollback ENV=prod`): finds the previous digest in the history of
  `prod/image.yaml` and opens a PR restoring it. Only the image changes; configuration changed
  since then is kept. **The database schema and data are not rolled back.** Migrations must be
  backward compatible (next section), so the old image runs fine on the newer schema.

If a sync is stuck retrying an old commit, the scripts terminate that operation automatically when
they push a new one (same as `argocd app terminate-op`).

## Database schema changes

1. `uv run alembic revision -m "add released_by"` and write `upgrade()`/`downgrade()` in
   `alembic/versions/`.
2. Make it **expand only**: add nullable columns or new tables, never rename or drop in the same
   release. Old pods keep serving during the rollout, so they must work with the new schema.
3. `make test` runs every migration up and down against a real Postgres.
4. Release as usual. The migration Job runs before the new pods start; if it fails, the sync
   stops there and the old version keeps serving.
5. Contract (drop the old column) in a **later** release, once no running version uses it.

## Change environment configuration

Edit `gitops/environments/<env>/values.yaml` (for example `logLevel`, `resources`,
`autoscaling.maxReplicas`) and open a PR. On merge Argo CD applies it. ConfigMap changes roll the
pods automatically through the `checksum/config` annotation. Prod's replica count belongs to the
HPA (`autoscaling.minReplicas/maxReplicas`), not to `replicaCount`.

Don't `kubectl edit` resources Argo CD owns: self-heal reverts the change within seconds. To
experiment, change Git.

## Add an environment

Tested end to end with `staging` (PR #8). Everything goes in **one pull request**:

1. Create `gitops/environments/<name>/values.yaml` with at least `environment: <name>`.
   Leave the Service as ClusterIP unless you also add a kind port mapping.
2. Create `gitops/environments/<name>/image.yaml`. Start from the image another environment runs:
   `bash -c 'source scripts/lib.sh; write_image_file <name> "$(image_field prod repository)" "$(image_field prod digest)" "$(image_field prod version)"'`
3. Allow the namespace in `gitops/argocd/project.yaml` (`destinations`). This is the deliberate
   admin gate: a folder alone can never deploy into an arbitrary namespace.
4. Add the namespace to `infrastructure/namespaces.yaml`, with the `restricted` Pod Security label
   like the others.
5. **Before merging**, run `make up` from the branch. It creates the namespace and the database
   secret for the new folder. If Argo CD syncs before they exist, the first sync fails and auto-sync
   does not retry the same commit.
6. Open the PR. CI validates the new environment's manifests too (`validate-manifests.sh` renders
   every folder). Merge it.
7. The ApplicationSet creates `release-notes-<name>` within about a minute. Check it with
   `make status` and `kubectl -n <name> port-forward svc/release-notes 18090:80`, then
   `curl localhost:18090/version`.

The scripts discover environments from the folders, so nothing else needs editing. Promotion stays
dev → prod by design.

## Remove an environment

Tested with `staging` (PR #9).

1. In one PR: delete `gitops/environments/<name>/`, its AppProject destination and its namespace
   entry. Merge it.
2. The ApplicationSet deletes the Argo CD application, but the **workloads and data keep running**
   (`preserveResourcesOnDeletion`), so a mistaken deletion can't take an environment down.
3. When you are sure: `kubectl --context kind-release-notes delete namespace <name>`. This deletes
   the database volume with it; take a backup first if the data matters.

## When something is wrong

| Symptom | Look at | Usual cause / fix |
|---|---|---|
| app `Synced/Degraded`, pods not Ready | `kubectl -n <env> describe pod`, `/ready` | bad release → `make rollback ENV=<env>` |
| app `Synced/Progressing` for minutes | `kubectl -n <env> rollout status deploy/release-notes` | rollout stuck; after `progressDeadlineSeconds` (120s) it turns Degraded |
| sync `Failed`, migration Job in error | `kubectl -n <env> logs job/release-notes-migrate` | migration bug or DB down; fix forward or roll back the image |
| `OutOfSync` that won't clear | Argo CD UI → app → diff | someone changed the cluster by hand (self-heal reverts it) or a field another controller owns |
| API returns 503, `/health` OK | Postgres pod, `make status` | DB unavailable; readiness takes pods out of the Service until it is back |
| new commit not deployed | `make status` (synced revision) | not merged to `main` yet, or Argo CD hasn't polled: the scripts trigger a refresh |
| CI didn't update dev | the CI run's *Deploy to dev* step | a newer commit's run deploys instead ("Skipping …" in the log) |

Logs: Grafana → Explore → Loki, `{namespace="<env>", app="release-notes", level="ERROR"}`.
Metrics and rollout progress: Grafana → *Release Notes* dashboard (*Pods by version* shows
rollouts as they happen).

## Not automated (yet)

- **Database credential rotation.** Secrets are created once by `make up`. Postgres only reads
  `POSTGRES_PASSWORD` on first initialisation, so a rotation means `ALTER USER`, updating the
  Secret and restarting the pods. In production this belongs to External Secrets plus a secret
  manager.
- **Backups and restore** of the Postgres volumes.
- **Required reviewers.** `make` merges its own PR once CI passes; a team would enforce review
  with branch protection.
