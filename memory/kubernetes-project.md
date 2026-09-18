# Kubernetes — Deploy Status Checker

## 1. Services

| Service | K8s Service name | Namespace | Port | Type |
|---|---|---|---|---|
| Postgres | `postgres` | `deploy-status-checker` | 5432 | ClusterIP + PVC (`postgres-pvc`, 1Gi) |
| Redis | `redis` | `deploy-status-checker` | 6379 | ClusterIP, no PVC (cache only) |
| deploy-service | `deploy-service` | `deploy-status-checker` | 3001 | ClusterIP |
| log-service | `log-service` | `deploy-status-checker` | 3002 | ClusterIP |
| api-gateway | `api-gateway` | `deploy-status-checker` | 3000 | ClusterIP + Ingress (`deploy-status-ingress`, host `deploy-status.local`) |

## 2. ConfigMap vs Secret rule

Would the value cause a security incident if it appeared in a CI log or PR diff → `Secret`; otherwise → `ConfigMap`. (Only exception applied: `POSTGRES_USER` kept in ConfigMap even though it's DB-related — username alone isn't sensitive.)

## 3. In-cluster DNS pattern

- Same namespace → short name only: `postgres`, `redis`, `deploy-service`, `log-service`, `api-gateway`.
- Full form: `<service>.deploy-status-checker.svc.cluster.local`.
- K8s Service names were chosen identical to the old Docker Compose service keys → zero `DATABASE_URL`/`REDIS_URL`/`*_SERVICE_URL` values needed changing when migrating from Compose.

## 4. Apply order

1. `postgres-init-cm` (via `kubectl create configmap --from-file=infra/init/01-databases.sh`) + `postgres-pvc` + `postgres-secret`/`postgres-cm` (Secret/ConfigMap must pre-exist)
2. `postgres` Deployment+Service → must be `Running 1/1` before step 3
3. `redis` Deployment+Service (no hard dependency, but grouped here)
4. `deploy-service`, `log-service` Deployment+Service (parallel — both only need `postgres`)
5. `api-gateway` Deployment+Service (needs `deploy-service` + `log-service` reachable, though not strictly ordered by K8s — app itself doesn't hard-fail if they're briefly unavailable)
6. `infra/k8s/ingress.yaml` — last, once `api-gateway` Service exists

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

## Auth notes (api-gateway)

- `POST /deploys`, `PATCH /deploys` → require header `x-api-key` (= `CI_API_KEY`)
- `GET /deploys`, `GET /deploys/:id`, `GET /overview` → require `Authorization: Bearer <JWT signed with JWT_SECRET, HS256>`
- `GET/POST /deploys/:id/logs` → accepts **either** `x-api-key` or JWT
