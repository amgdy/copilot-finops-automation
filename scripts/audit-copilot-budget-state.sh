#!/usr/bin/env bash
set -euo pipefail

ENTERPRISE_SLUG=""
TEAMS_CONFIG_FILE="config/cost-center-members.example.yml"
BUDGETS_CONFIG_FILE="config/budget-policies.example.yml"
REPORT_DIR="reports"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --enterprise-slug)
      ENTERPRISE_SLUG="$2"
      shift 2
      ;;
    --teams-config-file)
      TEAMS_CONFIG_FILE="$2"
      shift 2
      ;;
    --budgets-config-file)
      BUDGETS_CONFIG_FILE="$2"
      shift 2
      ;;
    --report-dir)
      REPORT_DIR="$2"
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

scripts/validate-config.sh "$TEAMS_CONFIG_FILE" teams >/dev/null
scripts/validate-config.sh "$BUDGETS_CONFIG_FILE" budgets >/dev/null

if [[ -z "$ENTERPRISE_SLUG" ]]; then
  ENTERPRISE_SLUG="$(yq eval '.enterprise_slug // ""' "$TEAMS_CONFIG_FILE")"
fi
if [[ -z "$ENTERPRISE_SLUG" ]]; then
  ENTERPRISE_SLUG="$(yq eval '.enterprise_slug // ""' "$BUDGETS_CONFIG_FILE")"
fi
if [[ -z "$ENTERPRISE_SLUG" ]]; then
  echo "ERROR: enterprise slug is required via --enterprise-slug or config.enterprise_slug" >&2
  exit 1
fi

mkdir -p "$REPORT_DIR"
report_file="$REPORT_DIR/audit-$(date -u +%Y%m%dT%H%M%SZ).md"

has_value() {
  [[ -n "$1" && "$1" != "null" ]]
}

team_members_endpoint() {
  local source_org="$1" source_enterprise="$2" team_slug="$3"
  if has_value "$source_enterprise"; then
    printf '/enterprises/%s/teams/%s/memberships?per_page=100' "$source_enterprise" "$team_slug"
  else
    printf '/orgs/%s/teams/%s/members?per_page=100' "$source_org" "$team_slug"
  fi
}

team_source_label() {
  local source_org="$1" source_enterprise="$2" team_slug="$3"
  if has_value "$source_enterprise"; then
    printf 'enterprise:%s/%s' "$source_enterprise" "$team_slug"
  else
    printf 'org:%s/%s' "$source_org" "$team_slug"
  fi
}

count_team_members() {
  local source_org="$1" source_enterprise="$2" team_slug="$3" endpoint count
  endpoint="$(team_members_endpoint "$source_org" "$source_enterprise" "$team_slug")"
  if count="$(gh api --paginate "$endpoint" 2>/dev/null | jq -r '
      if type == "array" then .[]
      elif type == "object" and has("members") then .members[]
      else empty end
      | if type == "string" then .
        elif type == "object" and has("login") then .login
        elif type == "object" and has("user") and .user.login then .user.login
        else empty end
    ' | sort -u | wc -l | tr -d ' ')"; then
    printf '%s' "$count"
  else
    printf '%s' "unknown"
  fi
}

default_team_cost_center_name() {
  local source_org="$1" source_enterprise="$2" team_slug="$3"
  if has_value "$source_enterprise"; then
    printf 'cc-ent-%s-%s' "$source_enterprise" "$team_slug"
  else
    printf 'cc-org-%s-%s' "$source_org" "$team_slug"
  fi
}

{
  echo "# Copilot FinOps Audit"
  echo
  echo "- Enterprise: \`$ENTERPRISE_SLUG\`"
  echo "- Generated (UTC): $(date -u +'%Y-%m-%d %H:%M:%S')"
  echo

  echo "## Team to Cost Center mappings"
  cc_list_endpoint="/enterprises/$ENTERPRISE_SLUG/settings/billing/cost-centers"
  map_count="$(yq eval '.mappings | length' "$TEAMS_CONFIG_FILE")"
  if [[ "$map_count" -eq 0 ]]; then
    echo "No mappings found."
  else
    for ((i = 0; i < map_count; i++)); do
      name="$(yq eval ".mappings[$i].name // \"mapping-$i\"" "$TEAMS_CONFIG_FILE")"
      source_org="$(yq eval ".mappings[$i].source.org // \"\"" "$TEAMS_CONFIG_FILE")"
      source_enterprise="$(yq eval ".mappings[$i].source.enterprise // \"\"" "$TEAMS_CONFIG_FILE")"
      team_slug="$(yq eval ".mappings[$i].source.team_slug" "$TEAMS_CONFIG_FILE")"
      cost_center="$(yq eval ".mappings[$i].target.cost_center" "$TEAMS_CONFIG_FILE")"

      source_label="$(team_source_label "$source_org" "$source_enterprise" "$team_slug")"

      echo "- **$name**: $source_label -> $cost_center"

      team_count="$(count_team_members "$source_org" "$source_enterprise" "$team_slug")"
      cc_count="unknown"

      # GA cost center API: resolve name -> id, then count user resources.
      cc_id="$(gh api --paginate "$cc_list_endpoint" 2>/dev/null | jq -r --arg n "$cost_center" '(.costCenters // []) | .[] | select((.state // "active") != "deleted") | select(.name == $n) | .id' | head -n1 || true)"
      if [[ -z "$cc_id" ]]; then
        echo "  - ⚠️ Cost center '$cost_center' not found (create it or check the name)."
      else
        cc_endpoint="/enterprises/$ENTERPRISE_SLUG/settings/billing/cost-centers/$cc_id"
        if cc_count="$(gh api --paginate "$cc_endpoint?per_page=100" 2>/dev/null | jq -sc 'map(.resources // []) | add | map(select((.type // "" | ascii_downcase) == "user")) | length')"; then
          :
        else
          echo "  - ⚠️ Could not read members of cost center '$cost_center' ($cc_id)."
        fi
      fi

      echo "  - Team member count: $team_count"
      echo "  - Cost center member count: $cc_count"
    done
  fi

  echo
  echo "## Budget policies"
  policy_count="$(yq eval '.budget_policies | length' "$BUDGETS_CONFIG_FILE")"
  if [[ "$policy_count" -eq 0 ]]; then
    echo "No budget policies found."
  else
    for ((i = 0; i < policy_count; i++)); do
      name="$(yq eval ".budget_policies[$i].name // \"policy-$i\"" "$BUDGETS_CONFIG_FILE")"
      policy_type="$(yq eval ".budget_policies[$i].type // \"\"" "$BUDGETS_CONFIG_FILE")"
      sku="$(yq eval ".budget_policies[$i].budget.product_sku // \"ai_credits\"" "$BUDGETS_CONFIG_FILE")"
      amount="$(yq eval ".budget_policies[$i].budget.amount // 0" "$BUDGETS_CONFIG_FILE")"
      # Read raw (not via //, which coalesces false to the default) then default
      # an omitted value to true.
      prevent="$(yq eval ".budget_policies[$i].budget.prevent_further_usage" "$BUDGETS_CONFIG_FILE")"
      if [[ -z "$prevent" || "$prevent" == "null" ]]; then prevent="true"; fi
      coverage="$(yq eval ".budget_policies[$i].coverage // \"total_spend\"" "$BUDGETS_CONFIG_FILE")"
      case "$policy_type" in
        enterprise) scope="enterprise" ;;
        universal) scope="multi_user_customer" ;;
        cost_center) scope="cost_center" ;;
        team)
          if [[ "$coverage" == "additional_spend" ]]; then
            scope="cost_center"
          else
            scope="user"
          fi
          ;;
        *) scope="?" ;;
      esac
      echo "- **$name** [type=$policy_type -> budget_scope=$scope]"
      echo "  - Budget: sku=\`$sku\`, amount=\`$amount\` USD, prevent_further_usage=\`$prevent\`"

      if [[ "$policy_type" == "cost_center" ]]; then
        cost_center="$(yq eval ".budget_policies[$i].target.cost_center // \"\"" "$BUDGETS_CONFIG_FILE")"
        echo "  - Target cost center: $cost_center"
      fi

      if [[ "$policy_type" == "team" ]]; then
        source_org="$(yq eval ".budget_policies[$i].source.org // \"\"" "$BUDGETS_CONFIG_FILE")"
        source_enterprise="$(yq eval ".budget_policies[$i].source.enterprise // \"\"" "$BUDGETS_CONFIG_FILE")"
        team_slug="$(yq eval ".budget_policies[$i].source.team_slug // \"\"" "$BUDGETS_CONFIG_FILE")"
        member_count="$(count_team_members "$source_org" "$source_enterprise" "$team_slug")"
        echo "  - Source: $(team_source_label "$source_org" "$source_enterprise" "$team_slug")"
        if [[ "$coverage" == "additional_spend" ]]; then
          cost_center="$(yq eval ".budget_policies[$i].target.cost_center // \"\"" "$BUDGETS_CONFIG_FILE")"
          if ! has_value "$cost_center"; then
            cost_center="$(default_team_cost_center_name "$source_org" "$source_enterprise" "$team_slug")"
          fi
          echo "  - Coverage: additional_spend (one cost center budget)"
          echo "  - Target cost center: $cost_center"
          echo "  - Team member count (cost center should contain these users): $member_count"
        else
          echo "  - Coverage: total_spend (one user budget per member)"
          echo "  - Team member count (individual budgets would be applied): $member_count"
        fi
      fi
    done
  fi

  echo
  echo "## Actionable notes"
  echo "- Keep mutating workflows in dry-run mode by default."
  echo "- Budgets are created via \`POST /enterprises/{enterprise}/settings/billing/budgets\` (GA enhanced billing)."
  echo "- Cost center members are managed via \`POST|DELETE /enterprises/{enterprise}/settings/billing/cost-centers/{cost_center_id}/resource\`."
  echo "- Enterprise team mappings use the bare team slug in config (for example, \`my-team-name\`)."
} >"$report_file"

echo "Audit report written: $report_file"
