# AWS staging provisioning (TIE-23)

**Status: not executed.** `provision-staging.sh` is written and reviewed but has
never been run against the real account (868737222758, `tien_nht`,
us-west-2). Read this whole file — especially the blockers and the cost
tension below — before running it.

## What it does

Provisions the Deploy Status Checker staging environment per DOP-001 §9 and
IRD-005 (AWS Infrastructure Standards): a non-default VPC across 3 AZs, 1 NAT
Gateway, S3/DynamoDB Gateway endpoints, an EC2 instance in a private subnet
(no public IP, IMDSv2 required, SSM-only shell access) running Docker, and an
ALB in the public subnets as the only externally-reachable entry point
(forwarding to the api-gateway container's port). Matches TIE-23's AC: "only
the gateway port answers from outside" — that's the ALB, not the instance
itself, which has no public IP at all.

```
./provision-staging.sh              # all phases
./provision-staging.sh network      # just one phase — see PHASES in the script
```

## Blocked by an explicit account guardrail — not just missing permissions

While validating this script (via read-only calls and EC2 `--dry-run`, which
checks permissions/syntax without creating anything), several calls hit an
**explicit deny** from a policy named `proops-trainee-guardrails` attached to
`tien_nht`, not just an absent grant:

- `ec2:AllocateAddress` — blocks the NAT Gateway's Elastic IP (Phase 1)
- `ssm:GetParameter` — blocks resolving the Amazon Linux AMI ID (Phase 5)
- `budgets:*`, `ce:*` (Cost Anomaly Detection) — blocks Phase 0 entirely
- `iam:ListUsers` — blocks verifying "no access keys exist" (DOP-002 AC #7)

Everything else dry-run-tested clean: `ec2:CreateVpc`, `CreateInternetGateway`,
`CreateSecurityGroup`, `CreateSubnet` all returned "Request would have
succeeded."

This looks like a deliberate sandbox boundary, not an oversight. **Don't try
to route around it** — either run the blocked phases under a more privileged
principal, or get the guardrail policy adjusted, before executing.

## Cost tension: IRD-005's own numbers don't fit its own budget

IRD-005's environment table specifies `m7g.medium` + 1 NAT Gateway + (this
issue's) ALB for `stag`, with a $50/month budget alarm. Rough on-demand
pricing for that exact footprint in us-west-2, running 24/7:

| Component | ~Monthly cost |
|---|---|
| `m7g.medium` compute | ~$45 |
| NAT Gateway (hourly) | ~$33 (+ $0.045/GB processed) |
| ALB (hourly) | ~$16 (+ LCU usage) |
| EBS gp3 30GB | ~$2 |
| Public IPv4 charges (NAT EIP + ALB nodes, billed since Feb 2024) | ~$4 |
| **Total** | **~$100** |

That's roughly **2x** the $50 budget IRD-005 itself sets for `stag`. IRD-005
does sanction off-hours shutdown for `stag` ("Yes... ≈65% saving"), which
would bring this much closer to budget — but that's scheduled start/stop
automation (e.g. an EventBridge-triggered Lambda or SSM automation) that
doesn't exist yet and isn't part of this script. Until it does, running this
24/7 will exceed IRD-005's own stated stag budget. Flagging this rather than
picking a workaround unilaterally — it's a real conflict between two of
IRD-005's own numbers.

## Open decision: getting `infra/` onto the instance

User-data installs Docker only, deliberately (matches TIE-23's "fresh VM with
only Docker installed"). Actually deploying — getting
`docker-compose.yml`/`docker-compose.prod.yml` onto the box and running
`generate-secrets.sh` (TIE-24) + `docker compose pull && up -d` — is a second,
deliberate step, not automatic on boot.

Proposed (not yet built): the instance role gets read-only access to one S3
object (`DEPLOY_BUNDLE_BUCKET` in the script) containing just the compose
files — no secrets, since those are generated on-instance per TIE-24's
per-host design. Needs a decision on who populates that bucket and how
(manually, or a step added to the existing per-service CI in TIE-20/21).

## Before running

- Fill in `BUDGET_NOTIFY_EMAIL` and `DEPLOY_BUNDLE_BUCKET` (marked CHANGE-ME)
- Resolve the guardrail-blocked calls above
- Decide on the cost tension above
- Decide on the deploy-bundle mechanism above
