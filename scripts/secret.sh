#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 <set|check|rotate|delete> <app-manifest.yaml> <dev|prod> <SECRET_NAME> <AWS_REGION>" >&2
  exit 2
}

[[ $# -eq 5 ]] || usage
action=$1
manifest=$2
environment=$3
secret_name=$4
region=$5

case "$action" in
  set|check|rotate|delete) ;;
  *) usage ;;
esac

[[ -f "$manifest" ]] || { echo "manifest not found: $manifest" >&2; exit 2; }
[[ "$environment" == "dev" || "$environment" == "prod" ]] || usage
[[ "$secret_name" =~ ^[A-Z][A-Z0-9_]{0,63}$ ]] || {
  echo "secret name must match ^[A-Z][A-Z0-9_]{0,63}$" >&2
  exit 2
}

app=$(yq '.name' "$manifest")
[[ "$app" =~ ^[a-z][a-z0-9-]{0,15}$ ]] || {
  echo "manifest has an invalid app name" >&2
  exit 2
}

if [[ "$action" != "delete" ]]; then
  yq -e ".secrets // [] | contains([\"$secret_name\"])" "$manifest" >/dev/null || {
    echo "$secret_name is not declared in $manifest; declare its name before storing a value" >&2
    exit 2
  }
fi

parameter_name="/flightdeck/$app/$environment/$secret_name"
account=$(aws sts get-caller-identity --region "$region" --query Account --output text)
echo "target: account $account, region $region, parameter $parameter_name"

check_parameter() {
  aws ssm get-parameter \
    --region "$region" \
    --name "$parameter_name" \
    --query 'Parameter.[Name,Type,Version,LastModifiedDate]' \
    --output table
}

if [[ "$action" == "check" ]]; then
  check_parameter
  exit 0
fi

if [[ "$action" == "delete" ]]; then
  echo "Revoke the credential at its provider before deleting the SSM parameter."
  read -r -p "Type DELETE to remove $parameter_name: " confirmation
  [[ "$confirmation" == "DELETE" ]] || { echo "delete cancelled"; exit 2; }
  aws ssm delete-parameter --region "$region" --name "$parameter_name"
  echo "parameter deleted; the provider credential must already be revoked"
  exit 0
fi

secret_file=$(mktemp)
chmod 600 "$secret_file"
trap 'rm -f "$secret_file"' EXIT

read -r -s -p "Value for $parameter_name: " secret_value
echo
[[ -n "$secret_value" ]] || { echo "secret value cannot be empty" >&2; exit 2; }
printf '%s' "$secret_value" >"$secret_file"
unset secret_value

put_args=(
  ssm put-parameter
  --region "$region"
  --name "$parameter_name"
  --type SecureString
  --tier Standard
  --key-id alias/aws/ssm
  --value "file://$secret_file"
  --query '[Version,Tier]'
  --output table
)
[[ "$action" == "rotate" ]] && put_args+=(--overwrite)
aws "${put_args[@]}"

if [[ "$action" == "rotate" ]]; then
  service=$app
  [[ "$environment" == "dev" ]] && service="$app-dev"
  aws ecs update-service \
    --region "$region" \
    --cluster flightdeck \
    --service "$service" \
    --force-new-deployment \
    --query 'service.[serviceName,deployments[0].status]' \
    --output table
  echo "rotation stored; ECS replacement started for $service"
else
  echo "secret created; deploy the app to inject it into a new task"
fi
