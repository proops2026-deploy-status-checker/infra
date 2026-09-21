# EKS Practice — Deploy Status Checker (Day 17)

## 1. Create command

```bash
export AWS_REGION=us-west-2
cd infra/eks
eksctl create cluster -f cluster.yaml     # 15-20 min
```

`cluster.yaml` (full, as used — account: 241533152550):

```yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: dsc-tien-lab
  region: us-west-2
  version: "1.33"
availabilityZones: [us-west-2a, us-west-2b]
vpc:
  nat:
    gateway: Disable
managedNodeGroups:
  - name: ng-spot
    instanceTypes: [t3.medium]
    spot: true
    desiredCapacity: 1
    minSize: 1
    maxSize: 1
    privateNetworking: false
    iam:
      attachPolicyARNs:
        - arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
        - arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
        - arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
        - arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy
      attachPolicy:
        Version: "2012-10-17"
        Statement:
          - Effect: Allow
            Action: ec2:DescribeAvailabilityZones
            Resource: "*"
addons:
  - name: aws-ebs-csi-driver
```

## 2. Connect command

```bash
aws eks update-kubeconfig --region us-west-2 --name dsc-tien-lab
kubectl config current-context
```

`eksctl create cluster` writes `~/.kube/config` automatically — this command is only needed
to reconnect a shell that didn't run `create`, or after re-auth.

## 3. Image URL pattern

```
[account-id].dkr.ecr.[region].amazonaws.com/[repo]:[tag]
241533152550.dkr.ecr.us-west-2.amazonaws.com/api-gateway:v1
```

| Build rule | Command |
|---|---|
| Apple Silicon → EKS amd64 nodes, always build cross-platform | `docker buildx build --platform=linux/amd64 -t [repo]:v1 .` |
| Migration image = separate build target, same Dockerfile | `docker buildx build --platform=linux/amd64 --target migrator -t [repo]-migrate:v1 .` |
| Layer reuse | Same base image (`node:24-alpine`) across services reuses layer at ECR registry level — first push slow, rest report `Layer already exists`. |

## 4. Cost stack (this config)

| Resource | Rate | Notes |
|---|---|---|
| EKS control plane | $0.10/hr | Bills from ACTIVE, regardless of workload |
| 1× t3.medium spot node | ~$0.012/hr | ~70% cheaper than on-demand |
| EBS gp3 (3× 1Gi PVC) | ~$0.0005/hr total | Postgres primary + read + Redis |
| Classic ELB | ~$0.025/hr | Only while `type: LoadBalancer` Service exists |
| NAT Gateway | $0/hr | **Disabled** — `vpc.nat.gateway: Disable` |
| **Total burn rate** | **~$0.14/hr** | ~$1.10 for an 8h lab day |
| If NAT left on + forgotten | ~$30/mo + control plane | The actual danger case |

## 5. Skip-list (training cluster — do not enable)

| Skip | Why |
|---|---|
| AWS Load Balancer Controller | `Service type=LoadBalancer` → Classic ELB is enough |
| IRSA / OIDC | Node IAM role covers a 1-node lab; `oidc: disabled` on this cluster |
| Cluster Autoscaler / HPA | Fixed `desiredCapacity: 1`, no scaling needed for a lab |
| Fargate | Managed node group + spot is faster/cheaper to learn on |
| Private EKS API endpoint | Public endpoint = `kubectl` from laptop just works |
| CloudWatch Container Insights | `kubectl logs` is enough for a 1-day lab |
| NAT Gateway | `vpc.nat.gateway: Disable` — node in public subnet pulls ECR via public IP |

## 6. Common errors + fixes (real, this session)

| # | Error | Root cause | Fix |
|---|---|---|---|
| 1 | `ecr:CreateRepository` → `AccessDenied` (old account 868737222758) | Tag-enforcement policy — conditional Allow requires `Owner`+`Email` request tags; same generic deny text as a total missing-permission case | Retry with `--tags Key=Owner,Value=<x> Key=Email,Value=<x>` |
| 2 | `eksctl create cluster` → `iam:CreateRole` denied, `HandlerErrorCode: UnauthorizedTaggingOperation` (old account) | IAM has no conditional-allow-with-tags like ECR; `iam:CreateRole`+`iam:TagRole` are both needed to create a tagged role, neither granted | Not fixable with tags — needs explicit IAM grant, or switch account |
| 3 | `eksctl delete cluster` → `ResourceNotFoundException: No cluster found` after a failed create | Stack rolled back before the actual EKS cluster resource was created — nothing for the EKS API to describe | Delete the CloudFormation stack directly: `aws cloudformation delete-stack --stack-name eksctl-[name]-cluster` |
| 4 | `cloudformation delete-stack` → `Stack cannot be deleted while TerminationProtection is enabled` | eksctl enables termination protection on the cluster stack by default | `aws cloudformation update-termination-protection --stack-name [name] --no-enable-termination-protection`, then delete. If this itself is denied, retry later — permission was granted mid-session without any config change on our end. |
| 5 | `ebs-csi-controller-*` pods `CrashLoopBackOff` | Startup health check dry-runs `ec2:DescribeAvailabilityZones`; `AmazonEBSCSIDriverPolicy` doesn't include this action | Attach inline policy granting `ec2:DescribeAvailabilityZones` to node role; delete pods to retry |
| 6 | Postgres/Redis PVCs stuck `Pending` | Cluster's only StorageClass (`gp2`) uses the old in-tree provisioner (`kubernetes.io/aws-ebs`, not `ebs.csi.aws.com`) and isn't marked default | Create a `gp3` StorageClass with `provisioner: ebs.csi.aws.com` + `storageclass.kubernetes.io/is-default-class: "true"`; delete stuck PVCs so StatefulSet recreates them |
| 7 | `postgres-primary-0` `CreateContainerConfigError`: `secret "postgres-secret" not found` | Chart values reference `primary.extraEnvVarsSecret: postgres-secret` (used by the init script that creates per-service DB users) but the secret was never created on this fresh cluster | `kubectl create secret generic postgres-secret` with `POSTGRES_USER`/`POSTGRES_PASSWORD`/`DEPLOY_DB_PASSWORD`/`LOG_DB_PASSWORD` before/with the Helm install |
| 8 | `curl` to ELB port 3000 times out; SG, health check, and in-cluster NodePort test all pass | Classic ELB **Cross-Zone Load Balancing defaults to OFF**; ELB spans 2 AZs but the 1 node is in only 1 AZ, so ~half of DNS-resolved traffic hits an AZ with no target | `aws elb modify-load-balancer-attributes --load-balancer-name [name] --load-balancer-attributes "CrossZoneLoadBalancing={Enabled=true}"` |
| 9 | Still times out after enabling cross-zone, both locally and from Claude's own sandbox | Port 3000 (non-standard) blocked by local network/ISP outbound filtering, unrelated to AWS — confirmed by suspiciously fast (<200ms) "connection refused" for a Vietnam↔Oregon round trip | Change Service to expose standard port 80 (`targetPort` stays 3000 inside the pod) |
| 10 | `POST /deploys` → `500`, log: `table public.deploys does not exist` | App Deployments were applied before the DB schema existed (Prisma migration hadn't run) | Run migration Jobs — and in the **correct** order, do DB → migrate → app, not app → DB |

## 7. Delete sequence (verified, this session)

```bash
helm uninstall my-redis my-postgres -n deploy-status-checker

eksctl delete cluster --name dsc-tien-lab --region us-west-2 --wait

# verify — all four must come back empty/clean
eksctl get cluster --region us-west-2                      # no clusters
aws eks list-clusters --region us-west-2                   # clusters: []
aws ec2 describe-volumes --region us-west-2 \
  --filters "Name=tag-value,Values=*dsc-tien-lab*" \
  --query 'Volumes[].VolumeId'                              # [] — if not, delete manually (PVCs don't always release cleanly)
aws elb describe-load-balancers --region us-west-2 \
  --query 'LoadBalancerDescriptions[].LoadBalancerName'     # [] (or none tagged to this cluster)
aws ec2 describe-vpcs --region us-west-2 \
  --filters "Name=tag-key,Values=alpha.eksctl.io/cluster-name" \
  --query 'Vpcs[].VpcId'                                    # []

# optional — ECR storage is cheap but images are dev-only
aws ecr delete-repository --repository-name [repo] --force --region us-west-2
```

**Real orphan hit this session:** `eksctl delete cluster --wait` reported success, but 3 EBS
volumes (Postgres primary/read + Redis PVCs) were left `available` — PVCs did not release
cleanly. Always run the EC2 Volumes check; don't trust `--wait` alone.

## 8. Minikube vs EKS — what changes

| Aspect | Minikube | EKS |
|---|---|---|
| Image | `docker build` → `minikube image load` | `docker buildx build --platform=linux/amd64` → push to ECR |
| Public Service | `type: ClusterIP` + Ingress + `minikube tunnel` | `type: LoadBalancer` → real Classic ELB (or ALB via controller, not used here) |
| Persistence | Default StorageClass often broken/absent | Must create a `gp3` StorageClass (`provisioner: ebs.csi.aws.com`), mark default |
| Secret source | `kubectl create secret generic`, manual | Same command, same manual step — no Secrets Manager in this lab |
| Node IAM / RBAC | N/A (local) | Node IAM role needs `AmazonEC2ContainerRegistryReadOnly` to pull from ECR |
| Cost | $0 | ~$0.14/hr — must be deleted same day |
