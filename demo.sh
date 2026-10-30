#!/usr/bin/env bash
# Demo + preflight helper. Talks to the ALB directly (curl --resolve), so it works with or without
# the DNS delegation / hosts entry. Usage: ./demo.sh <preflight|valid|invalid|protected|burst [n]|failover>
set -euo pipefail

cd "$(dirname "$0")"
CLUSTER="${CLUSTER:-n8n-dev}"
export AWS_PROFILE="${AWS_PROFILE:-dev}" AWS_REGION="${AWS_REGION:-eu-central-1}"

# Hostname from the Terraform output unless H is set.
if [[ -z "${H:-}" ]]; then
  H="$(terraform output -raw url 2>/dev/null || true)"; H="${H#https://}"; H="${H%%/*}"
fi
[[ -n "$H" ]] || { echo "No hostname: run terraform apply first or set H=..." >&2; exit 1; }

ALB_DNS="${ALB_DNS:-$(terraform output -raw alb_dns_name 2>/dev/null)}" \
  || { echo "No ALB found: run terraform apply first or set ALB_DNS=..." >&2; exit 1; }
IP="$(dig +short "$ALB_DNS" | head -1)"
# -k only while certificate_mode = "self_signed" (INSECURE= disables it)
CURL=(curl -sS --max-time 30 --resolve "$H:443:$IP" ${INSECURE--k})
URL="https://$H/webhook/partner-order"

post() { "${CURL[@]}" -w '\nHTTP %{http_code}\n' -X POST "$URL" -H 'content-type: application/json' -d "$1"; }

case "${1:-}" in
  preflight)
    echo "== AWS identity";      aws sts get-caller-identity --query Arn --output text
    echo "== ALB IPs";           dig +short "$ALB_DNS" | tr '\n' ' '; echo
    echo "== /etc/hosts";        grep "$H" /etc/hosts || echo "(no entry)"
    echo "== ECS services"
    aws ecs describe-services --cluster "$CLUSTER" \
      --services "$CLUSTER-main" "$CLUSTER-webhook" "$CLUSTER-worker" \
      --query 'services[].[serviceName,runningCount,desiredCount]' --output text
    echo "== Webhook";           post '{"orderId":"PREFLIGHT","partner":"demo","amount":1}' | tail -1
    ;;
  valid)
    post '{"orderId":"A-1001","partner":"acme","amount":1499}' ;;
  invalid)
    post '{"partner":"acme"}' ;;
  protected)
    for p in / /rest/settings /api/v1/workflows /webhook/partner-order; do
      printf '%-24s ' "$p"
      "${CURL[@]}" -o /dev/null -w '%{http_code} %{redirect_url}\n' "https://$H$p" | cut -c1-100
    done ;;
  burst)
    n="${2:-50}"
    echo "Sending $n events, 10 in parallel..."
    seq 1 "$n" | xargs -P 10 -I{} "${CURL[@]}" -o /dev/null -w '%{http_code}\n' -X POST "$URL" \
      -H 'content-type: application/json' -d '{"orderId":"B-{}","partner":"burst","amount":{}}' \
      | sort | uniq -c ;;
  failover)
    # Sends events for ~60 s while one webhook task is stopped. Expect only 202s.
    out="$(mktemp)"
    ( end=$((SECONDS + 60)); i=0
      while (( SECONDS < end )); do i=$((i + 1))
        "${CURL[@]}" -o /dev/null -w '%{http_code}\n' -X POST "$URL" -H 'content-type: application/json' \
          -d "{\"orderId\":\"F-$i\",\"partner\":\"failover\",\"amount\":10}" >> "$out" || echo ERR >> "$out"
        sleep 0.3
      done ) &
    sleep 5
    task="$(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$CLUSTER-webhook" --query 'taskArns[0]' --output text)"
    echo "Stopping webhook task ${task##*/} while traffic is running..."
    aws ecs stop-task --cluster "$CLUSTER" --task "$task" --reason "failover demo" --query 'task.lastStatus' --output text
    wait
    echo "Results:"; sort "$out" | uniq -c; rm -f "$out" ;;
  *)
    sed -n '2,3p' "$0"; exit 1 ;;
esac
