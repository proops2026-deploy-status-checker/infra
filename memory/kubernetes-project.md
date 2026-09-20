# Kubernetes — Deploy Status Checker

## 1. Services

| Service | K8s Service name | Namespace | Port | Type |
|---|---|---|---|---|
| Postgres | `my-postgres-postgresql-primary` (write) / `my-postgres-postgresql-read` (replica) — Helm release `my-postgres`, chart `bitnami/postgresql`, **`architecture: replication`** (TIE-28, Day 17) | `deploy-status-checker` | 5432 | 2 StatefulSets (`...-primary`, 1 replica; `...-read`, 1 replica) + 2 PVCs (`data-my-postgres-postgresql-primary-0`, `data-my-postgres-postgresql-read-0`, 1Gi each). 2 isolated DBs: `deploy_db`/`deploy_user`, `log_db`/`log_user` — same least-privilege model as the old hand-written setup, recreated via `infra/init/01-databases.sh` (shared with Docker Compose — see § Apply order for how it's wired into `helm install/upgrade`, no longer duplicated inline in `my-postgres-values.yaml`). See § 6 for the replication/failover procedure. |
| Redis | `my-redis-master` (Helm release `my-redis`, chart `bitnami/redis`, `architecture: standalone`) | `deploy-status-checker` | 6379 | ClusterIP + StatefulSet + PVC (`redis-data-my-redis-master-0`, 1Gi), **AUTH enabled** (`auth.password`) — unlike the old bare Redis, connecting now requires a password embedded in `REDIS_URL` |
| deploy-service | `deploy-service` | `deploy-status-checker` | 3001 | ClusterIP |
| log-service | `log-service` | `deploy-status-checker` | 3002 | ClusterIP |
| api-gateway | `api-gateway` | `deploy-status-checker` | 3000 | ClusterIP + Ingress (`deploy-status-ingress`, host `deploy-status.local`) |

Old hand-written `postgres`/`redis` Deployments + Services + `postgres-pvc` + `postgres-cm` + imperative `postgres-init-cm` were **deleted** on Day 16 after cutover to Helm — do not re-`kubectl apply` the old `infra/k8s/{postgres,redis}-{deployment,svc}.yaml` files, they no longer exist in the repo on purpose.

## 2. ConfigMap vs Secret rule

Would the value cause a security incident if it appeared in a CI log or PR diff → `Secret`; otherwise → `ConfigMap`. (Exception applied: `POSTGRES_USER` was kept in ConfigMap in the old setup — username alone isn't sensitive.)

**Day 16 addition:** a value's classification can flip when its *shape* changes, not just its content. `REDIS_URL` was ConfigMap-safe when Redis had no password (`redis://redis:6379`). Once Redis gained `auth.password`, the same env var now embeds a credential (`redis://:<password>@my-redis-master:6379`) and had to move to Secret — check this on every dependency upgrade, not just at initial design time.

## 3. In-cluster DNS pattern

- Same namespace → short name only: `my-postgres-postgresql-primary`, `my-postgres-postgresql-read`, `my-redis-master`, `deploy-service`, `log-service`, `api-gateway`.
- Full form: `<service>.deploy-status-checker.svc.cluster.local`.
- Unlike the original Compose→K8s migration (Day 15, zero hostnames changed), the **Day 16 Helm cutover did change hostnames** (`postgres`→`my-postgres-postgresql`, `redis`→`my-redis-master`) — Helm chart service names follow `[release-name]-[chart-name]` (or `[release-name]-[component]` for multi-role charts), not whatever name you'd pick by hand. Always confirm the real name from the chart's post-install `NOTES` output — never assume it matches the old hostname.
- **Day 17 addition:** the hostname changed *again*, silently, as a side effect of an unrelated flag. Flipping `architecture: standalone` → `replication` on the same `bitnami/postgresql` chart renames the service from `my-postgres-postgresql` to `my-postgres-postgresql-primary` (and adds `...-read`) — nothing about the rename is mentioned by the flag name itself, it only shows up in the post-upgrade `NOTES`. Any app `DATABASE_URL` pointing at the old name breaks the moment the upgrade lands. Same lesson as Day 16, sharper: **re-read the `NOTES` output on every chart upgrade that touches `architecture`/topology, not just on first install.**

## 4. Apply order

**App services (plain `kubectl apply -f`):**
1. `namespace.yaml`
2. `deploy-service`, `log-service` ConfigMap → Secret → Deployment → Service (parallel, both only need Postgres)
3. `api-gateway` ConfigMap → Deployment → Service
4. `deploy-service/k8s/migrate-job.yaml`, `log-service/k8s/migrate-job.yaml` — must run (and reach `Completed`) **after** Postgres is `Running` and **before** relying on any app endpoint that touches `deploys`/`logs` tables. Re-run (delete + re-apply the Job) any time `DATABASE_URL`'s host changes — a `Completed` Job from a previous Postgres instance does NOT mean the current one has a schema.
5. `infra/k8s/ingress.yaml` — last, once `api-gateway` Service exists

**3rd-party dependencies (Helm, separate lifecycle from the app manifests above):**
1. `helm repo add bitnami ... && helm repo update`
2. `helm install my-postgres bitnami/postgresql -f infra/k8s/my-postgres-values.yaml --set-file 'primary.initdb.scripts.01-databases\.sh=infra/init/01-databases.sh' -n deploy-status-checker` — the `--set-file` (not a copy pasted into `my-postgres-values.yaml`) keeps `infra/init/01-databases.sh` the single source of truth for both Compose and K8s. **Escaping matters**: the key literally contains a dot (`01-databases.sh`), so the `\.` before `sh` must reach Helm unescaped by the shell — wrap the whole `key=value` in single quotes, or bash strips the backslash and Helm parses it as 3 nested keys instead of one. Wait for `my-postgres-postgresql-0` `Running 1/1` before anything touches Postgres
3. `helm install my-redis bitnami/redis -f infra/k8s/my-redis-values.yaml -n deploy-status-checker`
4. Only after both charts are `Running` — patch `deploy-service-secret`/`log-service-secret` (`DATABASE_URL`) and `deploy-service-secret` (`REDIS_URL`) to the Helm service hostnames, then `kubectl rollout restart` the affected Deployments, then re-run migrate Jobs (step 4 above)

## 5. Failures hit today + fixes

| Failure | Root cause | Fix |
|---|---|---|
| Brief said ConfigMap needs `stringData` | Wrong — `stringData` only exists on `Secret`. ConfigMap only has `data`/`binaryData` | Use `data:` in all ConfigMaps |
| `deploy-service` `ImagePullBackOff` | Custom `:local` image built on host Docker Desktop, invisible to minikube's runtime | `docker build` normally, then `minikube image load <image>:local` |
| `eval $(minikube docker-env)` + `docker build` → buildx error `404 page not found` booting buildkit | minikube here runs **containerd** runtime, not docker — `minikube docker-env` is "highly experimental" on containerd and breaks buildx's containerized builder | Never use `minikube docker-env` on this cluster. Always: build on host → `minikube image load` |
| `api-gateway` Deployment referenced `secretKeyRef.key: DATABASE_URL` | Copy-pasted from `deploy-service` pattern without updating — `api-gateway-secret` only has `JWT_SECRET`/`CI_API_KEY`, no `DATABASE_URL` | Caught in review before apply (would've been `CreateContainerConfigError`) — reference only keys that actually exist in the target Secret |
| `api-gateway/k8s/svc.yaml` had `metadata.name: log-service` + `selector: app: log-service` | Copy-pasted from `log-service/k8s/svc.yaml`, forgot to rename | Caught in review — would've silently overwritten the real `log-service` Service (same namespace+name) and broken its routing |
| `deploy-service`/`log-service` `/health` wired as `livenessProbe` | Their `/health` actively queries Postgres (`SELECT 1`) — a transient DB blip flips it to 503, causing K8s to needlessly **restart the app container** (doesn't fix anything, DB is what's down) | Changed to `readinessProbe` — DB down just pulls the Pod out of Service endpoints, no restart. `api-gateway`'s `/health` is DB-independent, correctly left as `livenessProbe` |
| `kubectl apply -f infra/k8s/ingress.yaml` → `no matches for kind "Ingress" in version "v1"` | `Ingress` belongs to API group `networking.k8s.io/v1`, not core `v1` (unlike Pod/Service/ConfigMap/Secret/PVC/Namespace) | `apiVersion: networking.k8s.io/v1` |
| Ingress unreachable via `curl http://$(minikube ip):<nodePort>/...` | `docker` driver on macOS doesn't expose the minikube VM's IP directly to the host network | Must use `minikube tunnel` (separate terminal) + `curl http://127.0.0.1/...` with `Host:` header |
| `deploy_user`/`log_user` Postgres auth would fail silently if passwords mismatch | `DEPLOY_DB_PASSWORD`/`LOG_DB_PASSWORD` in `postgres-secret` must be byte-identical to the password embedded in `deploy-service-secret`/`log-service-secret`'s `DATABASE_URL` — `init/01-databases.sh` uses the former to `CREATE USER`, the app connects with the latter | Keep both in sync manually; a mismatch shows as Postgres auth failure in app logs, not `CreateContainerConfigError` |
| `POST /deploys` → `500`, log shows `PrismaClientKnownRequestError: table "public.deploys" does not exist` | No `prisma/migrations/` in either `deploy-service` or `log-service` — schema was only ever pushed by hand (`db push`), and this exact gap already bit the Day 12 EC2 deploy (see `daily-logs/day-12.md`) for the same reason. Production image also has no `prisma` CLI (`npm ci --omit=dev` drops the devDependency) | **Fixed for real, not just worked around**: generated real migrations (`prisma migrate diff --from-empty --to-schema-datamodel` + `prisma migrate resolve --applied`, baselined without data loss), added a `migrator` Docker build stage (`FROM builder AS migrator`, reuses the CLI-having `builder` stage) to both Dockerfiles, and a `k8s/migrate-job.yaml` `Job` in each service repo — apply the Job once before rolling that Deployment. Verified live: both Jobs ran in-cluster, logged `No pending migrations to apply`. See `infra/scripts/README.md` § Database schema migrations. Tracked in Linear (this project's real tracker — not Jira, that was a stale memory note): **TIE-36** (this exact gap, filed 2026-09-14, resolved 2026-09-18 by this fix) and follow-up **TIE-39** (write the pattern into IRD-001/IRD-002, still open) |
| **(Day 16)** minikube node flapped `NotReady` mid-work, API server `TLS handshake timeout` on many `kubectl` calls, unrelated Pods (`api-gateway`) restart-looping | Host-level Docker Desktop/minikube instability, not a manifest bug — confirmed via `kubectl describe node` showing a real `NodeNotReady` transition event | `minikube stop && minikube start` (state, PVCs, and Helm release history all survive — they're stored in the VM/etcd, not lost on stop) |
| **(Day 16)** `deploy-service-migrate` Job `OOMKilled` repeatedly right after installing `my-redis`+`my-postgres` | Two extra StatefulSets running **alongside** the still-live old bare `redis`/`postgres` Deployments doubled real memory pressure on the node | Delete the old, now-redundant `redis`/`postgres` Deployments+Services+PVC once cutover is confirmed — don't run both stacks side by side longer than needed to verify |
| **(Day 16)** `prisma migrate deploy` → `Error: P3009 migrate found failed migrations` | A previous attempt was `OOMKilled` mid-migration, leaving a `failed` row in `_prisma_migrations` | DB was fresh/no real data yet → `DROP SCHEMA public CASCADE; CREATE SCHEMA public;` + re-grant, instead of `prisma migrate resolve` |
| **(Day 16)** `prisma migrate deploy` → `Error: P3018 ... permission denied for database deploy_db` applying `CREATE SCHEMA IF NOT EXISTS "public"` | `GRANT USAGE, CREATE ON SCHEMA public` (schema-level) is **not** the same privilege as `CREATE` on the *database* (needed to create a schema at all, even one that already exists — Postgres checks this permission before the `IF NOT EXISTS` short-circuit) | `GRANT CREATE ON DATABASE deploy_db TO deploy_user;` (and same for `log_db`/`log_user`) — added directly to `infra/init/01-databases.sh` (the shared script), not patched by hand or duplicated into a Helm-only copy |
| **(Day 16, follow-up)** first version of the Postgres cutover duplicated `01-databases.sh`'s SQL inline inside `my-postgres-values.yaml` (`primary.initdb.scripts`) — two copies of the same logic, already diverging (different `--username`, missing `PGPASSWORD`, missing the `GRANT CREATE ON DATABASE` fix above) | Helm values files can't `include`/`source` another file — `initdb.scripts` needs literal script text at parse time | Made one script work in both environments (`${POSTGRES_USER:-postgres}`, always `export PGPASSWORD`), stopped inlining it, pass it at install/upgrade time with `--set-file` instead (see § Apply order) |
| **(Day 16)** `helm upgrade my-redis` with a bad `image.tag` → `helm list` still shows `STATUS: deployed`, Pod `ImagePullBackOff` | Helm's `deployed` status means "manifests applied successfully", not "Pods are healthy" — it does not wait for or verify Pod readiness by default | Always check `kubectl get pods` after any `helm upgrade`, never trust `helm list`/`helm history` STATUS alone |
| **(Day 16)** `helm rollback my-redis 3` succeeded, `helm history` showed the rollback, but the StatefulSet Pod kept retrying the pull of the *old bad image* | `helm rollback` correctly reverted the StatefulSet's `updateRevision`, but the already-stuck Pod (created by the bad upgrade) was never automatically deleted/recreated to pick up the reverted template | `kubectl delete pod my-redis-master-0` — forces the StatefulSet controller to recreate it from the current (correct) revision. Confirm via `controller-revision-hash` label matching `status.updateRevision` on the StatefulSet |
| **(Day 17)** `helm upgrade my-postgres ... --set architecture=replication` → `execution error: PASSWORDS ERROR: The secret "my-postgres-postgresql" does not contain the key "replication-password"` | The chart's password-generation logic only populates secret keys that were relevant *at install time* (standalone mode never needed `replication-password`); `helm upgrade` does not retroactively add missing keys to an existing Secret it detects, it just validates and fails | `kubectl patch secret my-postgres-postgresql --type=json -p='[{"op":"add","path":"/data/replication-password","value":"<base64>"}]'` to add the missing key by hand, then retry the upgrade |
| **(Day 17)** after the above upgrade succeeded, `deploy-service`/`log-service` started erroring `P1001: Can't reach database server at my-postgres-postgresql:5432` even though Postgres was `Running` | Flipping `architecture: standalone` → `replication` doesn't relabel/rename the *existing* StatefulSet — it creates **two brand-new StatefulSets** (`...-primary`, `...-read`), each with its **own fresh PVC**. The old `my-postgres-postgresql` StatefulSet + its PVC (`data-my-postgres-postgresql-0`) are torn down; the new primary starts with an *empty* volume (roles/schemas gone, not migrated). This is not an in-place topology change, it's closer to standing up a new cluster next to the old one and cutting over. | Re-point `DATABASE_URL` in both app Secrets to the new `my-postgres-postgresql-primary` host, `rollout restart` both Deployments, and **re-run both `migrate-job.yaml` Jobs** (delete + re-apply) — same "Job must re-run whenever `DATABASE_URL`'s host changes" rule from § Apply order, now confirmed to also apply to an `architecture` flag flip, not just a full chart swap |

## 6. PostgreSQL replication & failover (TIE-28, Day 17)

Enabled via `helm upgrade`/`install` with `architecture: replication` (see
`infra/k8s/my-postgres-values.yaml`) — one primary (`my-postgres-postgresql-primary`,
write) + one streaming read replica (`my-postgres-postgresql-read`). This is
the plain `bitnami/postgresql` chart, **not** `postgresql-ha` — there is no
automatic failover (no repmgr), which matches DOP-001 §10's own wording
("ready to be promoted if the primary fails") rather than requiring
unattended auto-promotion. `auth.replicationPassword` is passed via
`--set-file` at install/upgrade time, same pattern as `01-databases.sh` —
never committed to `my-postgres-values.yaml`.

**Install/upgrade command** (from `infra/`):
```
helm upgrade --install my-postgres bitnami/postgresql \
  -f k8s/my-postgres-values.yaml \
  --set-file 'primary.initdb.scripts.01-databases\.sh=init/01-databases.sh' \
  --set-file auth.replicationPassword=<path to a file holding the password> \
  -n deploy-status-checker
```

**Verifying replication is real** (don't trust `kubectl get pods` alone):
write a row via the app on the primary, then on the replica:
`SELECT pg_is_in_recovery();` must return `t`, and the row must be visible
there too (read-only — writes on the replica are rejected by Postgres itself).

**Failover rehearsal procedure** (tested live on Day 17):
1. Simulate primary loss: `kubectl scale statefulset my-postgres-postgresql-primary --replicas=0` (NOT `kubectl delete pod` — a StatefulSet just recreates the same pod from the same PVC, proving nothing). Wait for the pod to fully disappear (`kubectl get pod ... ` → not found) — it lingers "Terminating" during its grace period and **still serves traffic** until then; testing too early gives a false "still works" result.
2. Confirm the outage is real: a write through the app now 500s.
3. Promote: `kubectl exec my-postgres-postgresql-read-0 -- psql -U postgres -c "SELECT pg_promote();"`. Confirm with `SELECT pg_is_in_recovery();` → `f`.
4. Re-point both app Secrets' `DATABASE_URL` host to `my-postgres-postgresql-read`, `kubectl rollout restart` both Deployments.
5. Verify for real, not just "pod is Running": `POST /deploys` (write), `GET /overview` (read) — and confirm data written *before* the outage is still there post-promotion (this is what "no manual data restoration" in DOP-001 AC-05 actually means — the promoted replica already had it via streaming replication, nothing was restored from a backup).

**Returning to a clean steady state after rehearsing:** don't try to hand-patch
the old (now-stale, diverged) primary back into the replication topology —
`helm uninstall my-postgres`, delete the now-orphaned PVCs
(`kubectl get pvc` — anything not currently mounted), then fresh
`helm install` with replication configured from the start, then re-run both
`migrate-job.yaml` Jobs, then re-point both app Secrets to
`my-postgres-postgresql-primary` (the steady-state name) and roll out
restart. Same "test destructively for real, then rebuild clean" pattern as
the TIE-22 rollback rehearsal and the TIE-29 backup/restore rehearsal — not
specific to Postgres.

**Known gap, not fixed by this:** `auth.postgresPassword` in
`my-postgres-values.yaml` is still a hardcoded plaintext dev password,
predating TIE-28 — tracked separately (TIE-40).

## Auth notes (api-gateway)

- `POST /deploys`, `PATCH /deploys` → require header `x-api-key` (= `CI_API_KEY`)
- `GET /deploys`, `GET /deploys/:id`, `GET /overview` → require `Authorization: Bearer <JWT signed with JWT_SECRET, HS256>`
- `GET/POST /deploys/:id/logs` → accepts **either** `x-api-key` or JWT
