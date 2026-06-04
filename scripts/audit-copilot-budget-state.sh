#!/usr/bin/env bash
set -euo pipefail

ENTERPRISE_SLUG=""
TEAMS_CONFIG_FILE="config/teams-to-cost-centers.example.yml"
BUDGETS_CONFIG_FILE="config/user-budget-policies.example.yml"
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

{
  echo "# Copilot FinOps Audit"
  echo
  echo "- Enterprise: \\`$ENTERPRISE_SLUG\\`"
  echo "- Generated (UTC): $(date -u +'%Y-%m-%d %H:%M:%S')"
  echo

  echo "## Team to Cost Center mappings"
  map_count="$(yq eval '.mappings | length' "$TEAMS_CONFIG_FILE")"
  if [[ "$map_count" -eq 0 ]]; then
    echo "No mappings found."
  else
    for ((i = 0; i < map_count; i++)); do
      name="$(yq eval ".mappings[$i].name // \"mapping-$i\"" "$TEAMS_CONFIG_FILE")"
      org="$(yq eval ".mappings[$i].source.org" "$TEAMS_CONFIG_FILE")"
      team_slug="$(yq eval ".mappings[$i].source.team_slug" "$TEAMS_CONFIG_FILE")"
      cost_center="$(yq eval ".mappings[$i].target.cost_center" "$TEAMS_CONFIG_FILE")"
      echo "- **$name**: $org/$team_slug -> $cost_center"

      team_count="unknown"
      cc_count="unknown"

      if team_json="$(gh api "/orgs/$org/teams/$team_slug/members?per_page=100" 2>/dev/null)"; then
        team_count="$(echo "$team_json" | jq 'length')"
      fi

      endpoint_template="$(yq eval '.api.cost_center_members_endpoint_template // "/enterprises/{enterprise}/settings/billing/cost-centers/{cost_center}/members"' "$TEAMS_CONFIG_FILE")"
      cc_endpoint="${endpoint_template//\{enterprise\}/$ENTERPRISE_SLUG}"
      cc_endpoint="${cc_endpoint//\{cost_center\}/$cost_center}"
      if cc_json="$(gh api "$cc_endpoint?per_page=100" 2>/dev/null)"; then
        cc_count="$(echo "$cc_json" | jq 'if type=="array" then length elif has("members") then .members|length else 0 end')"
      else
        echo "  - ⚠️ Could not read cost center members from $cc_endpoint (endpoint may need adjustment)."
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
      target="$(yq eval -o=json ".budget_policies[$i].target" "$BUDGETS_CONFIG_FILE" | jq -c '.')"
      budget="$(yq eval -o=json ".budget_policies[$i].budget" "$BUDGETS_CONFIG_FILE" | jq -c '.')"
      echo "- **$name**"
      echo "  - Target: \\`$target\\`"
      echo "  - Budget: \\`$budget\\`"
    done

    endpoint_template="$(yq eval '.api.apply_budget_endpoint_template // ""' "$BUDGETS_CONFIG_FILE")"
    if [[ -n "$endpoint_template" && "$endpoint_template" != "null" ]]; then
      echo
      echo "### API spot checks"
      for ((i = 0; i < policy_count; i++)); do
        name="$(yq eval ".budget_policies[$i].name // \"policy-$i\"" "$BUDGETS_CONFIG_FILE")"
        endpoint="${endpoint_template//\{enterprise\}/$ENTERPRISE_SLUG}"
        endpoint="${endpoint//\{policy_name\}/$name}"
        if gh api "$endpoint" >/dev/null 2>&1; then
          echo "- ✅ Endpoint reachable for policy '$name': \\`$endpoint\\`"
        else
          echo "- ⚠️ Endpoint not reachable for policy '$name': \\`$endpoint\\`"
        fi
      done
    else
      echo "- ⚠️ No budget endpoint template configured. API-level budget drift checks skipped."
    fi
  fi

  echo
  echo "## Actionable notes"
  echo "- Keep mutating workflows in dry-run mode by default."
  echo "- If cost center or budget endpoints return 404/422, update endpoint templates in config files."
} >"$report_file"

echo "Audit report written: $report_file"
