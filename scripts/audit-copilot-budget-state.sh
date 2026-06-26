#!/usr/bin/env bash
set -euo pipefail

ENTERPRISE_SLUG=""
TEAMS_CONFIG_FILE="config/copilot-finops.example.yml"
BUDGETS_CONFIG_FILE="config/copilot-finops.example.yml"
REPORT_DIR="reports"
FORCE_USER_SYNC="false"

normalize_bool_flag() {
  local value="$1"
  local flag_name="$2"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    true|false)
      printf '%s' "$value"
      ;;
    *)
      echo "ERROR: $flag_name must be true or false, got '$value'" >&2
      exit 1
      ;;
  esac
}

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
    --force-user-sync)
      FORCE_USER_SYNC="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

FORCE_USER_SYNC="$(normalize_bool_flag "$FORCE_USER_SYNC" "--force-user-sync")"

if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v yq >/dev/null 2>&1; then
  echo "ERROR: gh, jq, and yq are required." >&2
  exit 1
fi

# v2 merges budgets + mappings into one file (validated with 'all'); v1 keeps the
# split files. Detect each file's version, then validate with the right type
# (dedupe when the same merged file is passed for both roles).
TEAMS_VERSION="$(yq eval '.version // 1' "$TEAMS_CONFIG_FILE")"
BUDGETS_VERSION="$(yq eval '.version // 1' "$BUDGETS_CONFIG_FILE")"

# v2 renamed the budgets list key to ai_credit_spend_policies; v1 keeps budget_policies.
if [[ "$BUDGETS_VERSION" == "2" ]]; then ABLIST="ai_credit_spend_policies"; else ABLIST="budget_policies"; fi

if [[ "$TEAMS_VERSION" == "2" ]]; then
  scripts/validate-config.sh "$TEAMS_CONFIG_FILE" all >/dev/null
else
  scripts/validate-config.sh "$TEAMS_CONFIG_FILE" teams >/dev/null
fi
if [[ "$BUDGETS_CONFIG_FILE" != "$TEAMS_CONFIG_FILE" ]]; then
  if [[ "$BUDGETS_VERSION" == "2" ]]; then
    scripts/validate-config.sh "$BUDGETS_CONFIG_FILE" all >/dev/null
  else
    scripts/validate-config.sh "$BUDGETS_CONFIG_FILE" budgets >/dev/null
  fi
fi

if [[ -z "$ENTERPRISE_SLUG" ]]; then
  ENTERPRISE_SLUG="$(yq eval '.enterprise_slug // ""' "$TEAMS_CONFIG_FILE")"
fi
if [[ -z "$ENTERPRISE_SLUG" ]]; then
  ENTERPRISE_SLUG="$(yq eval '.enterprise_slug // ""' "$BUDGETS_CONFIG_FILE")"
fi
if [[ -z "$ENTERPRISE_SLUG" ]]; then
  if [[ "$BUDGETS_VERSION" == "2" ]]; then
    ENTERPRISE_SLUG="$(yq eval '[(.ai_credit_spend_policies // [])[].enterprise] | map(select(. != null and . != "")) | .[0] // ""' "$BUDGETS_CONFIG_FILE")"
  else
    ENTERPRISE_SLUG="$(yq eval '[(.budget_policies // [])[].source.enterprise] | map(select(. != null and . != "")) | .[0] // ""' "$BUDGETS_CONFIG_FILE")"
  fi
fi
if [[ -z "$ENTERPRISE_SLUG" ]]; then
  if [[ "$TEAMS_VERSION" == "2" ]]; then
    ENTERPRISE_SLUG="$(yq eval '[(.team_cost_center_mappings // [])[].enterprise] | map(select(. != null and . != "")) | .[0] // ""' "$TEAMS_CONFIG_FILE")"
  else
    ENTERPRISE_SLUG="$(yq eval '[(.mappings // [])[].source.enterprise] | map(select(. != null and . != "")) | .[0] // ""' "$TEAMS_CONFIG_FILE")"
  fi
fi
if [[ -z "$ENTERPRISE_SLUG" ]]; then
  echo "ERROR: enterprise slug is required via --enterprise-slug, config.enterprise_slug, or a per-entry enterprise:" >&2
  exit 1
fi

mkdir -p "$REPORT_DIR"
report_file="$REPORT_DIR/audit-$(date -u +%Y%m%dT%H%M%SZ).md"

has_value() {
  [[ -n "$1" && "$1" != "null" ]]
}

# Lowercase + slugify a string for matching a native team resource name against a
# configured team slug (see the team-resource note in sync-cost-center-members.sh).
slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
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

count_org_members() {
  local org="$1" count
  if count="$(gh api --paginate "/orgs/$org/members?per_page=100" 2>/dev/null \
      | jq -r 'if type == "array" then .[] else empty end | .login // empty' \
      | sort -u | wc -l | tr -d ' ')"; then
    printf '%s' "$count"
  else
    printf '%s' "unknown"
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
  if [[ "$TEAMS_VERSION" == "2" ]]; then
    map_count="$(yq eval '(.team_cost_center_mappings // []) | length' "$TEAMS_CONFIG_FILE")"
  else
    map_count="$(yq eval '.mappings | length' "$TEAMS_CONFIG_FILE")"
  fi
  if [[ "$map_count" -eq 0 ]]; then
    echo "No mappings found."
  else
    for ((i = 0; i < map_count; i++)); do
      if [[ "$TEAMS_VERSION" == "2" ]]; then
        name="$(yq eval ".team_cost_center_mappings[$i].name // \"mapping-$i\"" "$TEAMS_CONFIG_FILE")"
        m_org="$(yq eval ".team_cost_center_mappings[$i].organization // \"\"" "$TEAMS_CONFIG_FILE")"
        m_ent="$(yq eval ".team_cost_center_mappings[$i].enterprise // \"\"" "$TEAMS_CONFIG_FILE")"
        team_slug="$(yq eval ".team_cost_center_mappings[$i].team // \"\"" "$TEAMS_CONFIG_FILE")"
        cost_center="$(yq eval ".team_cost_center_mappings[$i].cost_center // \"\"" "$TEAMS_CONFIG_FILE")"
        m_force="$(yq eval ".team_cost_center_mappings[$i].force_user_sync // false" "$TEAMS_CONFIG_FILE")"
        if has_value "$m_org"; then
          source_org="$m_org"
          source_enterprise=""
        else
          source_org=""
          if has_value "$m_ent"; then source_enterprise="$m_ent"; else source_enterprise="$ENTERPRISE_SLUG"; fi
        fi
      else
        name="$(yq eval ".mappings[$i].name // \"mapping-$i\"" "$TEAMS_CONFIG_FILE")"
        source_org="$(yq eval ".mappings[$i].source.org // \"\"" "$TEAMS_CONFIG_FILE")"
        source_enterprise="$(yq eval ".mappings[$i].source.enterprise // \"\"" "$TEAMS_CONFIG_FILE")"
        team_slug="$(yq eval ".mappings[$i].source.team_slug" "$TEAMS_CONFIG_FILE")"
        cost_center="$(yq eval ".mappings[$i].target.cost_center" "$TEAMS_CONFIG_FILE")"
        # v1 is frozen (no force_user_sync field); only the global
        # --force-user-sync flag can opt it back into user-level sync.
        m_force="false"
      fi

      if [[ "$FORCE_USER_SYNC" == "true" || "$m_force" == "true" ]]; then
        force_user_sync="true"
      else
        force_user_sync="false"
      fi

      source_label="$(team_source_label "$source_org" "$source_enterprise" "$team_slug")"

      echo "- **$name**: $source_label -> $cost_center"

      team_count="$(count_team_members "$source_org" "$source_enterprise" "$team_slug")"
      cc_count="unknown"
      cc_teams=()

      # GA cost center API: resolve name -> id, then count user resources and detect
      # any natively-assigned enterprise team resources (GA 2026-06-25). Native team
      # members are attributed dynamically and are not listed as user resources, so
      # they are intentionally excluded from the user count below.
      cc_id="$(gh api --paginate "$cc_list_endpoint" 2>/dev/null | jq -r --arg n "$cost_center" '(.costCenters // []) | .[] | select((.state // "active") != "deleted") | select(.name == $n) | .id' | head -n1 || true)"
      if [[ -z "$cc_id" ]]; then
        echo "  - ⚠️ Cost center '$cost_center' not found (create it or check the name)."
      else
        cc_endpoint="/enterprises/$ENTERPRISE_SLUG/settings/billing/cost-centers/$cc_id"
        cc_resources_file="$(mktemp)"
        if gh api --paginate "$cc_endpoint?per_page=100" 2>/dev/null | jq -sc 'map(.resources // []) | add' >"$cc_resources_file"; then
          cc_count="$(jq -r 'map(select((.type // "" | ascii_downcase) == "user")) | length' "$cc_resources_file")"
          mapfile -t cc_teams < <(jq -r 'map(select((.type // "" | ascii_downcase) | test("team"))) | .[].name' "$cc_resources_file")
        else
          echo "  - ⚠️ Could not read members of cost center '$cost_center' ($cc_id)."
        fi
        rm -f "$cc_resources_file"
      fi

      echo "  - Team member count: $team_count"
      echo "  - Cost center member count: $cc_count"

      # Is THIS mapping's team assigned to the cost center natively (GA 2026-06-25)?
      team_natively_assigned=false
      if ((${#cc_teams[@]})); then
        echo "  - Natively-assigned team resource(s): ${cc_teams[*]} (members attributed dynamically; not in the count above)"
        team_slug_lc="$(printf '%s' "$team_slug" | tr '[:upper:]' '[:lower:]')"
        team_slug_norm="$(slugify "$team_slug")"
        for cc_team in "${cc_teams[@]}"; do
          cc_team_lc="$(printf '%s' "$cc_team" | tr '[:upper:]' '[:lower:]')"
          if [[ "$cc_team_lc" == "$team_slug_lc" || "$(slugify "$cc_team")" == "$team_slug_norm" ]]; then
            team_natively_assigned=true
            break
          fi
        done
      fi

      # Report the membership-management state. The sync skips this mapping by
      # default (force_user_sync=false) and defers to native assignment; flag the
      # gap when neither native assignment nor effective force_user_sync is in place.
      if [[ "$team_natively_assigned" == "true" ]]; then
        echo "  - ✅ Team '$team_slug' is assigned to this cost center natively; user-level sync is skipped and native attribution is active."
        if [[ "$force_user_sync" == "true" ]]; then
          echo "  - ⚠️ force_user_sync is active while the team is also assigned natively — forced sync still skips this mapping to avoid redundant user resources. Remove the native assignment or set force_user_sync: false."
        fi
      elif [[ "$force_user_sync" == "true" ]]; then
        echo "  - ↪️ force_user_sync is active; the legacy user-level membership sync is active for this mapping (no native team assignment detected)."
      else
        echo "  - ⚠️ Team '$team_slug' is NOT assigned to this cost center natively and force_user_sync is false, so the sync skips this mapping and its membership is unmanaged. Assign the team natively (recommended) or set force_user_sync: true."
      fi
    done
  fi

  echo
  echo "## Budget policies"
  if [[ "$BUDGETS_VERSION" == "2" ]]; then plabel="scope"; else plabel="type"; fi
  policy_count="$(yq eval "(.${ABLIST} // []) | length" "$BUDGETS_CONFIG_FILE")"
  if [[ "$policy_count" -eq 0 ]]; then
    echo "No budget policies found."
  else
    for ((i = 0; i < policy_count; i++)); do
      if [[ "$BUDGETS_VERSION" == "2" ]]; then
        name="$(yq eval ".${ABLIST}[$i].name // \"policy-$i\"" "$BUDGETS_CONFIG_FILE")"
        policy_type="$(yq eval ".${ABLIST}[$i].scope // \"\"" "$BUDGETS_CONFIG_FILE")"
        sku="ai_credits"
        amount="$(yq eval ".${ABLIST}[$i].amount // 0" "$BUDGETS_CONFIG_FILE")"
        prevent="$(yq eval ".${ABLIST}[$i].stop_at_limit" "$BUDGETS_CONFIG_FILE")"
        if [[ -z "$prevent" || "$prevent" == "null" ]]; then prevent="true"; fi
        # v2 surface field is credit_scope; map to internal coverage vocab.
        case "$(yq eval ".${ABLIST}[$i].credit_scope // \"\"" "$BUDGETS_CONFIG_FILE")" in
          pool_then_metered) coverage="total_spend" ;;
          metered_only) coverage="additional_spend" ;;
          *) coverage="total_spend" ;;
        esac
        b_org="$(yq eval ".${ABLIST}[$i].organization // \"\"" "$BUDGETS_CONFIG_FILE")"
        b_ent="$(yq eval ".${ABLIST}[$i].enterprise // \"\"" "$BUDGETS_CONFIG_FILE")"
        mapfile -t teams_list < <(yq eval ".${ABLIST}[$i].teams[]?" "$BUDGETS_CONFIG_FILE")
        mapfile -t users_list < <(yq eval ".${ABLIST}[$i].users[]?" "$BUDGETS_CONFIG_FILE")
        policy_cost_center="$(yq eval ".${ABLIST}[$i].cost_center // \"\"" "$BUDGETS_CONFIG_FILE")"
        if has_value "$b_org"; then
          source_org="$b_org"
          source_enterprise=""
        else
          source_org=""
          if has_value "$b_ent"; then source_enterprise="$b_ent"; else source_enterprise="$ENTERPRISE_SLUG"; fi
        fi
      else
        name="$(yq eval ".budget_policies[$i].name // \"policy-$i\"" "$BUDGETS_CONFIG_FILE")"
        policy_type="$(yq eval ".budget_policies[$i].type // \"\"" "$BUDGETS_CONFIG_FILE")"
        sku="$(yq eval ".budget_policies[$i].budget.product_sku // \"ai_credits\"" "$BUDGETS_CONFIG_FILE")"
        amount="$(yq eval ".budget_policies[$i].budget.amount // 0" "$BUDGETS_CONFIG_FILE")"
        prevent="$(yq eval ".budget_policies[$i].budget.prevent_further_usage" "$BUDGETS_CONFIG_FILE")"
        if [[ -z "$prevent" || "$prevent" == "null" ]]; then prevent="true"; fi
        coverage="$(yq eval ".budget_policies[$i].coverage // \"total_spend\"" "$BUDGETS_CONFIG_FILE")"
        source_org="$(yq eval ".budget_policies[$i].source.org // \"\"" "$BUDGETS_CONFIG_FILE")"
        source_enterprise="$(yq eval ".budget_policies[$i].source.enterprise // \"\"" "$BUDGETS_CONFIG_FILE")"
        team_slug="$(yq eval ".budget_policies[$i].source.team_slug // \"\"" "$BUDGETS_CONFIG_FILE")"
        policy_cost_center="$(yq eval ".budget_policies[$i].target.cost_center // \"\"" "$BUDGETS_CONFIG_FILE")"
        users_list=()
        teams_list=()
        has_value "$team_slug" && teams_list=("$team_slug")
      fi
      case "$policy_type" in
        enterprise) scope="enterprise" ;;
        all_users | universal) scope="multi_user_customer" ;;
        cost_center) scope="cost_center" ;;
        team)
          if [[ "$coverage" == "additional_spend" ]]; then
            scope="cost_center"
          else
            scope="user"
          fi
          ;;
        organization)
          if [[ "$coverage" == "additional_spend" ]]; then
            scope="organization"
          else
            scope="user"
          fi
          ;;
        user) scope="user" ;;
        *) scope="?" ;;
      esac
      echo "- **$name** [$plabel=$policy_type -> budget_scope=$scope]"
      echo "  - Budget: sku=\`$sku\`, amount=\`$amount\` USD, prevent_further_usage=\`$prevent\`"

      if [[ "$policy_type" == "cost_center" ]]; then
        echo "  - Target cost center: $policy_cost_center"
      fi

      if [[ "$policy_type" == "team" ]]; then
        if [[ "$coverage" == "additional_spend" ]]; then
          echo "  - Coverage: additional_spend (one cost center budget per team)"
          for team_slug in "${teams_list[@]}"; do
            member_count="$(count_team_members "$source_org" "$source_enterprise" "$team_slug")"
            cost_center="$policy_cost_center"
            if [[ ${#teams_list[@]} -gt 1 ]] || ! has_value "$cost_center"; then
              cost_center="$(default_team_cost_center_name "$source_org" "$source_enterprise" "$team_slug")"
            fi
            echo "  - $(team_source_label "$source_org" "$source_enterprise" "$team_slug") -> cost center $cost_center (members: $member_count)"
          done
        else
          echo "  - Coverage: total_spend (one user budget per member)"
          for team_slug in "${teams_list[@]}"; do
            member_count="$(count_team_members "$source_org" "$source_enterprise" "$team_slug")"
            echo "  - $(team_source_label "$source_org" "$source_enterprise" "$team_slug") (members: $member_count)"
          done
        fi
      fi

      if [[ "$policy_type" == "user" ]]; then
        echo "  - Users (one hard-stop user budget each): ${users_list[*]}"
        echo "  - User budget count: ${#users_list[@]}"
      fi

      if [[ "$policy_type" == "organization" ]]; then
        echo "  - Organization: \`$b_org\` (written on the org billing endpoint)"
        if [[ "$coverage" == "additional_spend" ]]; then
          echo "  - Coverage: additional_spend (one organization-scope budget)"
        else
          member_count="$(count_org_members "$b_org")"
          echo "  - Coverage: total_spend (one user budget per org member)"
          echo "  - Organization member count (individual budgets would be applied): $member_count"
        fi
      fi
    done
  fi

  echo
  echo "## Actionable notes"
  echo "- Keep mutating workflows in dry-run mode by default."
  echo "- Budgets are created via \`POST /enterprises/{enterprise}/settings/billing/budgets\` (GA enhanced billing)."
  echo "- Organization-scope budgets (scope: organization) are written on \`POST /organizations/{organization}/settings/billing/budgets\`."
  echo "- Cost center members are managed via \`POST|DELETE /enterprises/{enterprise}/settings/billing/cost-centers/{cost_center_id}/resource\`."
  echo "- Enterprise team mappings use the bare team slug in config (for example, \`my-team-name\`)."
} >"$report_file"

echo "Audit report written: $report_file"
