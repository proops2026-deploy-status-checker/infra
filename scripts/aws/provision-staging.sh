#!/usr/bin/env bash
# Provisions the Deploy Status Checker staging environment on AWS.
#
# STATUS: written for review, NOT executed against the live account
# (868737222758) as of TIE-23. Read it, adjust the placeholders marked
# CHANGE-ME below, and run it deliberately when you're ready to spend
# real money.
#
# Governs: DOP-001 §9 (staging: single VM), DOP-002 (AWS Infrastructure,
# CLI/console at this stage — not Terraform, that's IRD-006/Week 4),
# IRD-005 (AWS Infrastructure Standards — every decision below cites the
# rule it satisfies), IRD-003 §6 (only the gateway is publicly reachable).
#
# Idempotent-ish: each phase looks up its resource by the Name tag before
# creating it, so re-running after fixing a permissions error or a partial
# failure won't create duplicates.
#
# Usage:
#   ./provision-staging.sh              # run every phase
#   ./provision-staging.sh <phase-name> # run just one phase (see PHASES below)

set -euo pipefail

# ---------------------------------------------------------------------------
# Config — IRD-005 naming convention: {project}-{environment}-{...}
# ---------------------------------------------------------------------------
PROJECT="proops2026"
ENVIRONMENT="stag"
REGION="us-west-2"                             # IRD-005 #12: never us-east-1 where a choice exists
AZS=("us-west-2a" "us-west-2b" "us-west-2c")   # IRD-005 #1: three AZs, never two

VPC_CIDR="10.1.0.0/16"
PUBLIC_SUBNET_CIDRS=("10.1.0.0/20" "10.1.16.0/20" "10.1.32.0/20")
PRIVATE_SUBNET_CIDRS=("10.1.128.0/20" "10.1.144.0/20" "10.1.160.0/20")

INSTANCE_TYPE="m7g.medium"     # IRD-005 stag row; Graviton per #6, never T-family per #5
GATEWAY_PORT=3000              # api-gateway's port (PORT env var / DOP-001 §5)

BUDGET_LIMIT_USD="50"          # IRD-005's stag row
BUDGET_NOTIFY_EMAIL="CHANGE-ME@example.com"

# PLACEHOLDER — the S3 bucket the instance will read infra/docker-compose.yml
# + docker-compose.prod.yml from at deploy time (compose files only, no
# secrets — secrets are generated on-instance via generate-secrets.sh, per
# TIE-24). Finalize the bucket name before running phase_iam / phase_instance;
# see the open decision in scripts/README.md.
DEPLOY_BUNDLE_BUCKET="CHANGE-ME-${PROJECT}-${ENVIRONMENT}-deploy"

# Mandatory tags (IRD-005) — used two ways below: TAGS for commands that want
# space-separated "Key=k,Value=v" shorthand (iam, elbv2), and tag_spec() for
# ec2's bracketed "ResourceType=..,Tags=[{...},{...}]" shorthand.
TAG_PAIRS=(
  "Key=Project,Value=${PROJECT}"
  "Key=Environment,Value=${ENVIRONMENT}"
  "Key=Owner,Value=tien"
  "Key=ManagedBy,Value=console"
  "Key=CostCenter,Value=training"
)
TAGS="${TAG_PAIRS[*]}"

tag_spec() {
  # $1 = EC2 resource type (vpc, subnet, security-group, ...)
  # $2 = this resource's Name tag value
  local braced="{Key=Name,Value=$2}"
  for t in "${TAG_PAIRS[@]}"; do braced+=",{$t}"; done
  echo "ResourceType=$1,Tags=[${braced}]"
}

log() { echo "==> $*"; }

# ---------------------------------------------------------------------------
# Phase 0 — Cost Anomaly Detection + budget alarm, before anything billable
# (IRD-005 #10 / Required Config "Observability and cost")
#
# NOTE: confirmed during TIE-23 that the `tien_nht` user lacks budgets:*
# and ce:* permissions. Run this phase under a principal that has them
# (e.g. an admin role), not as tien_nht.
# ---------------------------------------------------------------------------
phase_cost_controls() {
  log "Phase 0: Cost Anomaly Detection + budget alarm"

  local monitor_arn
  monitor_arn="$(aws ce get-anomaly-monitors \
    --query "AnomalyMonitors[?MonitorName=='${PROJECT}-${ENVIRONMENT}-monitor'].MonitorArn | [0]" \
    --output text 2>/dev/null || echo None)"

  if [[ -z "$monitor_arn" || "$monitor_arn" == "None" ]]; then
    monitor_arn="$(aws ce create-anomaly-monitor --anomaly-monitor "{
      \"MonitorName\": \"${PROJECT}-${ENVIRONMENT}-monitor\",
      \"MonitorType\": \"DIMENSIONAL\",
      \"MonitorDimension\": \"SERVICE\"
    }" --query 'MonitorArn' --output text)"
    log "Created cost anomaly monitor: $monitor_arn"
  else
    log "Cost anomaly monitor already exists: $monitor_arn"
  fi

  if ! aws budgets describe-budget --account-id "$ACCOUNT_ID" --budget-name "${PROJECT}-${ENVIRONMENT}-budget" >/dev/null 2>&1; then
    aws budgets create-budget --account-id "$ACCOUNT_ID" \
      --budget "{
        \"BudgetName\": \"${PROJECT}-${ENVIRONMENT}-budget\",
        \"BudgetLimit\": {\"Amount\": \"${BUDGET_LIMIT_USD}\", \"Unit\": \"USD\"},
        \"TimeUnit\": \"MONTHLY\",
        \"BudgetType\": \"COST\",
        \"CostFilters\": {\"TagKeyValue\": [\"user:Environment\$${ENVIRONMENT}\"]}
      }" \
      --notifications-with-subscribers "[
        {\"Notification\":{\"NotificationType\":\"FORECASTED\",\"ComparisonOperator\":\"GREATER_THAN\",\"Threshold\":50},\"Subscribers\":[{\"SubscriptionType\":\"EMAIL\",\"Address\":\"${BUDGET_NOTIFY_EMAIL}\"}]},
        {\"Notification\":{\"NotificationType\":\"FORECASTED\",\"ComparisonOperator\":\"GREATER_THAN\",\"Threshold\":80},\"Subscribers\":[{\"SubscriptionType\":\"EMAIL\",\"Address\":\"${BUDGET_NOTIFY_EMAIL}\"}]},
        {\"Notification\":{\"NotificationType\":\"ACTUAL\",\"ComparisonOperator\":\"GREATER_THAN\",\"Threshold\":100},\"Subscribers\":[{\"SubscriptionType\":\"EMAIL\",\"Address\":\"${BUDGET_NOTIFY_EMAIL}\"}]}
      ]"
    log "Created \$${BUDGET_LIMIT_USD}/mo budget with 50/80/100% alerts"
  else
    log "Budget ${PROJECT}-${ENVIRONMENT}-budget already exists"
  fi
}

# ---------------------------------------------------------------------------
# Phase 1 — VPC, subnets, IGW, NAT Gateway, route tables
# (IRD-005 #1 three AZs, #2 never the default VPC)
# ---------------------------------------------------------------------------
phase_network() {
  log "Phase 1: VPC and subnets"

  VPC_ID="$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${PROJECT}-${ENVIRONMENT}-vpc" \
    --query 'Vpcs[0].VpcId' --output text)"
  if [[ "$VPC_ID" == "None" ]]; then
    VPC_ID="$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" \
      --tag-specifications "$(tag_spec vpc "${PROJECT}-${ENVIRONMENT}-vpc")" \
      --query 'Vpc.VpcId' --output text)"
    aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support
    aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames
    log "Created VPC $VPC_ID ($VPC_CIDR)"
  else
    log "VPC already exists: $VPC_ID"
  fi

  IGW_ID="$(aws ec2 describe-internet-gateways --filters "Name=tag:Name,Values=${PROJECT}-${ENVIRONMENT}-igw" \
    --query 'InternetGateways[0].InternetGatewayId' --output text)"
  if [[ "$IGW_ID" == "None" ]]; then
    IGW_ID="$(aws ec2 create-internet-gateway \
      --tag-specifications "$(tag_spec internet-gateway "${PROJECT}-${ENVIRONMENT}-igw")" \
      --query 'InternetGateway.InternetGatewayId' --output text)"
    aws ec2 attach-internet-gateway --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID"
    log "Created and attached IGW $IGW_ID"
  else
    log "IGW already exists: $IGW_ID"
  fi

  PUBLIC_SUBNET_IDS=()
  PRIVATE_SUBNET_IDS=()
  for i in 0 1 2; do
    local az="${AZS[$i]}"
    local az_letter="${az: -1}"

    local pub_name="${PROJECT}-${ENVIRONMENT}-public-${az_letter}"
    local pub_id
    pub_id="$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=${pub_name}" --query 'Subnets[0].SubnetId' --output text)"
    if [[ "$pub_id" == "None" ]]; then
      pub_id="$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "${PUBLIC_SUBNET_CIDRS[$i]}" --availability-zone "$az" \
        --tag-specifications "$(tag_spec subnet "$pub_name")" \
        --query 'Subnet.SubnetId' --output text)"
      aws ec2 modify-subnet-attribute --subnet-id "$pub_id" --map-public-ip-on-launch
      log "Created public subnet $pub_id ($az)"
    fi
    PUBLIC_SUBNET_IDS+=("$pub_id")

    local priv_name="${PROJECT}-${ENVIRONMENT}-private-${az_letter}"
    local priv_id
    priv_id="$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=${priv_name}" --query 'Subnets[0].SubnetId' --output text)"
    if [[ "$priv_id" == "None" ]]; then
      priv_id="$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "${PRIVATE_SUBNET_CIDRS[$i]}" --availability-zone "$az" \
        --tag-specifications "$(tag_spec subnet "$priv_name")" \
        --query 'Subnet.SubnetId' --output text)"
      log "Created private subnet $priv_id ($az)"
    fi
    PRIVATE_SUBNET_IDS+=("$priv_id")
  done

  # Public route table -> IGW
  PUBLIC_RT_ID="$(aws ec2 describe-route-tables --filters "Name=tag:Name,Values=${PROJECT}-${ENVIRONMENT}-public-rt" \
    --query 'RouteTables[0].RouteTableId' --output text)"
  if [[ "$PUBLIC_RT_ID" == "None" ]]; then
    PUBLIC_RT_ID="$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
      --tag-specifications "$(tag_spec route-table "${PROJECT}-${ENVIRONMENT}-public-rt")" \
      --query 'RouteTable.RouteTableId' --output text)"
    aws ec2 create-route --route-table-id "$PUBLIC_RT_ID" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null
    for sid in "${PUBLIC_SUBNET_IDS[@]}"; do
      aws ec2 associate-route-table --route-table-id "$PUBLIC_RT_ID" --subnet-id "$sid" >/dev/null
    done
    log "Created public route table $PUBLIC_RT_ID -> $IGW_ID"
  fi

  # 1 NAT Gateway for stag (IRD-005 environment table: stag = 1, prod = 3)
  NAT_GW_ID="$(aws ec2 describe-nat-gateways --filter "Name=tag:Name,Values=${PROJECT}-${ENVIRONMENT}-nat" "Name=state,Values=available,pending" \
    --query 'NatGateways[0].NatGatewayId' --output text)"
  if [[ "$NAT_GW_ID" == "None" ]]; then
    local eip_alloc
    eip_alloc="$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text)"
    NAT_GW_ID="$(aws ec2 create-nat-gateway --subnet-id "${PUBLIC_SUBNET_IDS[0]}" --allocation-id "$eip_alloc" \
      --tag-specifications "$(tag_spec natgateway "${PROJECT}-${ENVIRONMENT}-nat")" \
      --query 'NatGateway.NatGatewayId' --output text)"
    log "Created NAT Gateway $NAT_GW_ID — waiting for it to become available"
    aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_GW_ID"
  fi

  # Private route table -> NAT
  PRIVATE_RT_ID="$(aws ec2 describe-route-tables --filters "Name=tag:Name,Values=${PROJECT}-${ENVIRONMENT}-private-rt" \
    --query 'RouteTables[0].RouteTableId' --output text)"
  if [[ "$PRIVATE_RT_ID" == "None" ]]; then
    PRIVATE_RT_ID="$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
      --tag-specifications "$(tag_spec route-table "${PROJECT}-${ENVIRONMENT}-private-rt")" \
      --query 'RouteTable.RouteTableId' --output text)"
    aws ec2 create-route --route-table-id "$PRIVATE_RT_ID" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_GW_ID" >/dev/null
    for sid in "${PRIVATE_SUBNET_IDS[@]}"; do
      aws ec2 associate-route-table --route-table-id "$PRIVATE_RT_ID" --subnet-id "$sid" >/dev/null
    done
    log "Created private route table $PRIVATE_RT_ID -> $NAT_GW_ID"
  fi
}

# ---------------------------------------------------------------------------
# Phase 2 — Gateway endpoints (IRD-005 #8: mandatory whenever a NAT Gateway exists)
# ---------------------------------------------------------------------------
phase_gateway_endpoints() {
  log "Phase 2: S3 + DynamoDB Gateway endpoints"
  for svc in s3 dynamodb; do
    local existing
    existing="$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=${VPC_ID}" "Name=service-name,Values=com.amazonaws.${REGION}.${svc}" \
      --query 'VpcEndpoints[0].VpcEndpointId' --output text)"
    if [[ "$existing" == "None" ]]; then
      aws ec2 create-vpc-endpoint --vpc-id "$VPC_ID" --service-name "com.amazonaws.${REGION}.${svc}" \
        --route-table-ids "$PRIVATE_RT_ID" \
        --tag-specifications "$(tag_spec vpc-endpoint "${PROJECT}-${ENVIRONMENT}-${svc}-endpoint")" >/dev/null
      log "Created $svc Gateway endpoint"
    else
      log "$svc Gateway endpoint already exists: $existing"
    fi
  done
}

# ---------------------------------------------------------------------------
# Phase 3 — Security groups (IRD-005 Network table: no 0.0.0.0/0 except
# 80/443 on the LB SG; reference other SGs by ID for internal traffic)
# ---------------------------------------------------------------------------
phase_security_groups() {
  log "Phase 3: security groups"

  WEB_SG_ID="$(aws ec2 describe-security-groups --filters "Name=tag:Name,Values=${PROJECT}-${ENVIRONMENT}-web-sg" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' --output text)"
  if [[ "$WEB_SG_ID" == "None" ]]; then
    WEB_SG_ID="$(aws ec2 create-security-group --vpc-id "$VPC_ID" --group-name "${PROJECT}-${ENVIRONMENT}-web-sg" \
      --description "ALB — public HTTP, forwards to app-sg" \
      --tag-specifications "$(tag_spec security-group "${PROJECT}-${ENVIRONMENT}-web-sg")" \
      --query 'GroupId' --output text)"
    aws ec2 authorize-security-group-ingress --group-id "$WEB_SG_ID" --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null
    log "Created web-sg $WEB_SG_ID (80 from 0.0.0.0/0 — the one IRD-005-sanctioned exception)"
  fi

  APP_SG_ID="$(aws ec2 describe-security-groups --filters "Name=tag:Name,Values=${PROJECT}-${ENVIRONMENT}-app-sg" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' --output text)"
  if [[ "$APP_SG_ID" == "None" ]]; then
    APP_SG_ID="$(aws ec2 create-security-group --vpc-id "$VPC_ID" --group-name "${PROJECT}-${ENVIRONMENT}-app-sg" \
      --description "Staging app instance — reachable only from web-sg" \
      --tag-specifications "$(tag_spec security-group "${PROJECT}-${ENVIRONMENT}-app-sg")" \
      --query 'GroupId' --output text)"
    aws ec2 authorize-security-group-ingress --group-id "$APP_SG_ID" --protocol tcp --port "$GATEWAY_PORT" --source-group "$WEB_SG_ID" >/dev/null
    log "Created app-sg $APP_SG_ID (port $GATEWAY_PORT from web-sg only, by SG ID)"
  fi
}

# ---------------------------------------------------------------------------
# Phase 4 — IAM role for SSM + scoped S3 read (IRD-005: instance roles only,
# no long-lived access keys; least privilege)
# ---------------------------------------------------------------------------
phase_iam() {
  log "Phase 4: IAM role and instance profile"

  local role_name="${PROJECT}-${ENVIRONMENT}-app-role"
  if ! aws iam get-role --role-name "$role_name" >/dev/null 2>&1; then
    aws iam create-role --role-name "$role_name" --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [{"Effect": "Allow", "Principal": {"Service": "ec2.amazonaws.com"}, "Action": "sts:AssumeRole"}]
    }' --tags $TAGS >/dev/null
    aws iam attach-role-policy --role-name "$role_name" \
      --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
    log "Created role $role_name with SSM managed policy"

    # Scoped read-only access to the deploy bundle only (least privilege —
    # not full s3:GetObject on the whole account). Finalize
    # DEPLOY_BUNDLE_BUCKET above before running this.
    aws iam put-role-policy --role-name "$role_name" --policy-name "deploy-bundle-read" --policy-document "{
      \"Version\": \"2012-10-17\",
      \"Statement\": [{\"Effect\": \"Allow\", \"Action\": \"s3:GetObject\", \"Resource\": \"arn:aws:s3:::${DEPLOY_BUNDLE_BUCKET}/*\"}]
    }"
  fi

  if ! aws iam get-instance-profile --instance-profile-name "$role_name" >/dev/null 2>&1; then
    aws iam create-instance-profile --instance-profile-name "$role_name" >/dev/null
    aws iam add-role-to-instance-profile --instance-profile-name "$role_name" --role-name "$role_name"
    log "Created instance profile $role_name"
    sleep 10  # IAM propagation delay before EC2 can use the new profile
  fi
}

# ---------------------------------------------------------------------------
# Phase 5 — EC2 instance (IRD-005: IMDSv2 hop-limit 1, Graviton, gp3
# encrypted root, no public IP, SSM-only shell access)
# ---------------------------------------------------------------------------
phase_instance() {
  log "Phase 5: EC2 instance"

  local existing
  existing="$(aws ec2 describe-instances --filters "Name=tag:Name,Values=${PROJECT}-${ENVIRONMENT}-app-01" "Name=instance-state-name,Values=pending,running,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text)"
  if [[ "$existing" != "None" ]]; then
    log "Instance already exists: $existing"
    INSTANCE_ID="$existing"
    return
  fi

  # Amazon Linux 2023, arm64 (Graviton) — resolved via SSM public parameter,
  # never a hardcoded AMI ID that goes stale.
  local ami_id
  ami_id="$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64 \
    --query 'Parameter.Value' --output text)"

  # User-data installs Docker ONLY, per TIE-23's "fresh VM with only Docker
  # installed" framing. Fetching infra/ and running generate-secrets.sh +
  # docker compose up is a deliberate second step, not automatic on boot —
  # see the open S3-deploy-bundle decision in scripts/README.md.
  local user_data
  user_data="$(cat <<'USERDATA'
#!/bin/bash
set -euo pipefail
dnf install -y docker
systemctl enable --now docker
usermod -aG docker ec2-user
DOCKER_COMPOSE_VERSION="v2.29.7"
curl -SL "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-aarch64" \
  -o /usr/libexec/docker/cli-plugins/docker-compose
chmod +x /usr/libexec/docker/cli-plugins/docker-compose
USERDATA
)"

  INSTANCE_ID="$(aws ec2 run-instances \
    --image-id "$ami_id" \
    --instance-type "$INSTANCE_TYPE" \
    --subnet-id "${PRIVATE_SUBNET_IDS[0]}" \
    --security-group-ids "$APP_SG_ID" \
    --no-associate-public-ip-address \
    --iam-instance-profile "Name=${PROJECT}-${ENVIRONMENT}-app-role" \
    --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled" \
    --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeType":"gp3","Encrypted":true,"DeleteOnTermination":true}}]' \
    --user-data "$user_data" \
    --tag-specifications "$(tag_spec instance "${PROJECT}-${ENVIRONMENT}-app-01")" \
    --query 'Instances[0].InstanceId' --output text)"
  log "Launched instance $INSTANCE_ID (private subnet, no public IP, IMDSv2 required)"
}

# ---------------------------------------------------------------------------
# Phase 6 — ALB: the only public entry point (IRD-003 §6 / this issue's AC)
# ---------------------------------------------------------------------------
phase_load_balancer() {
  log "Phase 6: Application Load Balancer"

  local alb_arn
  alb_arn="$(aws elbv2 describe-load-balancers --names "${PROJECT}-${ENVIRONMENT}-alb" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || echo None)"
  if [[ "$alb_arn" == "None" ]]; then
    alb_arn="$(aws elbv2 create-load-balancer --name "${PROJECT}-${ENVIRONMENT}-alb" \
      --subnets "${PUBLIC_SUBNET_IDS[@]}" --security-groups "$WEB_SG_ID" --scheme internet-facing --type application \
      --tags $TAGS \
      --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
    log "Created ALB $alb_arn"
  fi

  local tg_arn
  tg_arn="$(aws elbv2 describe-target-groups --names "${PROJECT}-${ENVIRONMENT}-app-tg" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || echo None)"
  if [[ "$tg_arn" == "None" ]]; then
    tg_arn="$(aws elbv2 create-target-group --name "${PROJECT}-${ENVIRONMENT}-app-tg" --protocol HTTP --port "$GATEWAY_PORT" \
      --vpc-id "$VPC_ID" --target-type instance --health-check-path /health \
      --tags $TAGS \
      --query 'TargetGroups[0].TargetGroupArn' --output text)"
    aws elbv2 register-targets --target-group-arn "$tg_arn" --targets "Id=${INSTANCE_ID}"
    aws elbv2 create-listener --load-balancer-arn "$alb_arn" --protocol HTTP --port 80 \
      --default-actions "Type=forward,TargetGroupArn=${tg_arn}" >/dev/null
    log "Created target group + listener -> instance:$GATEWAY_PORT (health check: /health)"
  fi
}

PHASES=(cost_controls network gateway_endpoints security_groups iam instance load_balancer)

main() {
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
  if [[ $# -eq 1 ]]; then
    "phase_$1"
    return
  fi
  for p in "${PHASES[@]}"; do
    "phase_$p"
  done
  log "Done. Instance: ${INSTANCE_ID:-n/a}  ALB: check 'aws elbv2 describe-load-balancers --names ${PROJECT}-${ENVIRONMENT}-alb'"
}

main "$@"
