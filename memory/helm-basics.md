# Helm Basics — Deploy Status Checker

## 1. Core concepts

| Term | Definition |
|---|---|
| Chart | A versioned package of K8s manifests + parameterized values (templates + `values.yaml`). |
| Release | A named installed instance of a chart, tracked in the cluster with revision history. |
| Repository | A server hosting versioned charts — like apt/npm for K8s manifests. |

## 2. Install workflow — exact commands

1. `helm repo add bitnami https://charts.bitnami.com/bitnami`
2. `helm repo update`
3. `helm search repo [name]` — confirm chart name, chart version, app version
4. `helm show values bitnami/[chart] | grep -A N "[key]:"` — find the real key path before writing overrides, never guess
5. Write `[my-service]-values.yaml` with **only** the keys that differ from chart defaults
6. `helm install [release] bitnami/[chart] -f [my-service]-values.yaml -n [namespace]`
   - If the chart needs an init script that must stay in sync with another environment (e.g. Docker Compose), pass it with `--set-file 'path.to.key\.with\.dots=./script.sh'` instead of copying the script into the values file — Helm values can't `include`/`source` another file. **Escaping**: wrap the whole `key=value` in single quotes or bash strips the `\` before Helm sees it, silently turning one key into nested keys.
7. Read the NOTES output **in full** — it has the real Service hostname and a connection test command. Never guess the hostname from a naming pattern.

## 3. Five operations

| Operation | Syntax |
|---|---|
| Install | `helm install [release] [chart] -f values.yaml -n [ns]` |
| Upgrade | `helm upgrade [release] [chart] -f values.yaml -n [ns]` |
| Upgrade or install (idempotent, CI-safe) | `helm upgrade --install [release] [chart] -f values.yaml -n [ns]` |
| Rollback | `helm rollback [release] [revision] -n [ns]` |
| List | `helm list -n [ns]` |
| History | `helm history [release] -n [ns]` |
| Uninstall | `helm uninstall [release] -n [ns]` |

## 4. Values override precedence

`values.yaml` (chart default) → `-f overrides.yaml` (rightmost file wins if multiple `-f`) → `--set` (wins over all files) → `--set-file` (same precedence tier as `--set`, keyed the same way).

## 5. Finding the real Service hostname after install

- Read NOTES.txt from the install output (best source).
- Or: `kubectl get svc -n [ns] | grep [release-name]`.
- Naming pattern is **not reliable** — varies by chart/component (e.g. Redis master → `[release]-master`, standalone Postgres → `[release]-[chart-name]`, no `-primary` suffix). Confirm from real output every time, don't assume.

## 6. Common failure modes

| Symptom | Cause | Fix |
|---|---|---|
| PVC `Pending` in minikube | Default StorageClass missing/misconfigured | `--set persistence.enabled=false` for a throwaway dev cache — never for a DB you need to survive a restart |
| `Error: cannot re-use a name that is still in use` / `resource already exists` | Release name conflict, or a previous `helm install` failed but left the release registered | `helm upgrade --install` for idempotent CI use; or `helm uninstall [release]` first if it's a genuinely dead/failed release |
| App can't connect to the chart's service | Wrong hostname assumed instead of read from output | Check NOTES.txt for the real Service name; `kubectl exec [app-pod] -- nslookup [service]` to confirm DNS resolves |
| `helm list` shows `STATUS: deployed` but the Pod is broken | Helm's `deployed` only means "manifests applied", not "Pods are healthy" — it doesn't wait/verify by default | Always `kubectl get pods` after `install`/`upgrade`; never trust `helm list` STATUS alone |
| `helm rollback` succeeds, `helm history` shows it, but the Pod keeps failing with the *old* bad spec | StatefulSet rollback reverts `updateRevision` on the object, but an already-stuck Pod isn't automatically deleted/recreated to pick it up | `kubectl delete pod [pod]` to force the StatefulSet controller to recreate it from the current (correct) revision |
| `prisma migrate deploy` → `P3009 failed migrations found` | An earlier attempt died mid-migration (e.g. OOMKilled), leaving a `failed` row in `_prisma_migrations` | On a DB with no real data yet: `DROP SCHEMA public CASCADE; CREATE SCHEMA public;` + re-grant, then retry |
| `prisma migrate deploy` → `P3018 permission denied for database [db]` on `CREATE SCHEMA IF NOT EXISTS "public"` | Schema-level `GRANT ... ON SCHEMA public` ≠ database-level `CREATE` privilege — Postgres checks the latter for this statement even when the schema already exists | `GRANT CREATE ON DATABASE [db] TO [user];` — put it in the init script itself, not a one-off manual fix |
| Job/Pod `OOMKilled` right after installing a chart | Old hand-written Deployment + new Helm release running side by side double the real memory footprint | Delete the old, now-redundant resources once cutover is verified — don't run both stacks longer than needed |
| `Rolling tag detected (bitnami/[x]:latest)` warning on every install | Bitnami's free/public catalog (post Aug 2025) serves rolling `latest` tags, not pinned versions — violates "never use latest in prod" | Fine for lab; for real production, pin `image.tag` explicitly in the values file |

## 7. Project's installed charts

| Release | Chart | Service hostname | Provides |
|---|---|---|---|
| `my-redis` | `bitnami/redis` (`architecture: standalone`) | `my-redis-master` | Cache for `deploy-service` (`REDIS_URL`, password-protected — value lives in `deploy-service-secret`, not ConfigMap) |
| `my-postgres` | `bitnami/postgresql` | `my-postgres-postgresql` | Primary DB — 2 isolated databases/users (`deploy_db`/`deploy_user`, `log_db`/`log_user`), schema created via `infra/init/01-databases.sh` passed at install time with `--set-file` |
