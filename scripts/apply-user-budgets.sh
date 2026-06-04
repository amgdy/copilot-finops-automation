#!/usr/bin/env bash
set -euo pipefail

ENTERPRISE_SLUG=""
CONFIG_FILE="config/user-budget-policies.example.yml"
POLICY_NAME=""
DRY_RUN="true"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --enterprise-slug)
      ENTERPRISE_SLUG="$2"
      shift 2
      ;;
    --config-file)
      CONFIG_FILE="$2"
      shift 2
      ;;
    --policy-name)
      POLICY_NAME="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v yq >/dev/null 2>&1; then
  echo "ERROR: gh, jq, and yq are required." >&2
  exit 1
fi

scripts/validate-config.sh "$CONFIG_FILE" budgets >/dev/null

if [[ -z "$ENTERPRISE_SLUG" ]]; then
  ENTERPRISE_SLUG="$(yq eval '.enterprise_slug // ""' "$CONFIG_FILE")"
fi

if [[ -z "$ENTERPRISE_SLUG" ]]; then
  echo "ERROR: enterprise slug is required via --enterprise-slug or config.enterprise_slug" >&2
  exit 1
fi

endpoint_template="$(yq eval '.api.apply_budget_endpoint_template // ""' "$CONFIG_FILE")"
policy_count="$(yq eval '.budget_policies | length' "$CONFIG_FILE")"

if [[ "$policy_count" -eq 0 ]]; then
  echo "No budget policies found in $CONFIG_FILE"
  exit 0
fi

failures=0
echo "Applying budget policies for enterprise '$ENTERPRISE_SLUG' (dry_run=$DRY_RUN)"

for ((i = 0; i < policy_count; i++)); do
  name="$(yq eval ".budget_policies[$i].name // \"policy-$i\"" "$CONFIG_FILE")"
  [[ -n "$POLICY_NAME" && "$name" != "$POLICY_NAME" ]] && continue

  description="$(yq eval ".budget_policies[$i].description // \"\"" "$CONFIG_FILE")"
  product="$(yq eval ".budget_policies[$i].budget.product // \"copilot\"" "$CONFIG_FILE")"
  limit_usd="$(yq eval ".budget_policies[$i].budget.limit_usd // 0" "$CONFIG_FILE")"
  period="$(yq eval ".budget_policies[$i].budget.period // \"monthly\"" "$CONFIG_FILE")"
  target_json="$(yq eval -o=json ".budget_policies[$i].target" "$CONFIG_FILE")"

  echo "---"
  echo "Policy: $name"
  [[ -n "$description" && "$description" != "null" ]] && echo "Description: $description"
  echo "Target: $(echo "$target_json" | jq -c '.')"
  echo "Budget: product=$product, limit_usd=$limit_usd, period=$period"

  payload="$(jq -n \
    --arg name "$name" \
    --arg product "$product" \
    --argjson limit "$limit_usd" \
    --arg period "$period" \
    --argjson target "$target_json" \
    '{name:$name,budget:{product:$product,limit_usd:$limit,period:$period},target:$target}')"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY RUN: Would apply policy payload: $(echo "$payload" | jq -c '.')"
    continue
  fi

  if [[ -z "$endpoint_template" || "$endpoint_template" == "null" ]]; then
    echo "ERROR: Applying is not implemented without config.api.apply_budget_endpoint_template." >&2
    echo "Add a known endpoint template (for example /enterprises/{enterprise}/copilot/budgets/policies/{policy_name})." >&2
    failures=$((failures + 1))
    continue
  fi

  endpoint="${endpoint_template//\{enterprise\}/$ENTERPRISE_SLUG}"
  endpoint="${endpoint//\{policy_name\}/$name}"

  if ! gh api -X PUT "$endpoint" --input - <<<"$payload" >/dev/null; then
    echo "ERROR: Failed to apply policy '$name' via endpoint '$endpoint'" >&2
    echo "HINT: Endpoint may differ by enterprise API capability." >&2
    failures=$((failures + 1))
    continue
  fi

  echo "Applied policy: $name"
done

if ((failures > 0)); then
  echo "Completed with $failures failure(s)." >&2
  exit 1
fi

echo "Budget policy apply flow completed (dry_run=$DRY_RUN)."
