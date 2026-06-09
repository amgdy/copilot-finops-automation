#!/usr/bin/env bash
set -euo pipefail

ENTERPRISE_SLUG=""
CONFIG_FILE="config/budget-policies.example.yml"
POLICY_NAME=""
DRY_RUN="true"

# Latest billing (budgets) REST API version. Override only if you pin a different one.
GH_API_VERSION="${GH_API_VERSION:-2026-03-10}"

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

# GA budgets endpoint (override only if you proxy the API).
budgets_tpl="$(yq eval '.api.budgets_endpoint_template // "/enterprises/{enterprise}/settings/billing/budgets"' "$CONFIG_FILE")"
budgets_endpoint="${budgets_tpl//\{enterprise\}/$ENTERPRISE_SLUG}"

# GA cost-centers list endpoint, used to resolve a cost center name to its ID
# (the budgets API references cost centers by ID, not by display name).
cc_list_tpl="$(yq eval '.api.cost_centers_list_endpoint_template // "/enterprises/{enterprise}/settings/billing/cost-centers"' "$CONFIG_FILE")"
cc_list_endpoint="${cc_list_tpl//\{enterprise\}/$ENTERPRISE_SLUG}"

# GA cost-center get-by-id + resource endpoints, used to populate a cost center
# with a team's members for an additional_spend budget (so the cost center the
# budget caps actually contains the people whose metered spend it limits).
cc_get_tpl="$(yq eval '.api.cost_center_endpoint_template // "/enterprises/{enterprise}/settings/billing/cost-centers/{cost_center_id}"' "$CONFIG_FILE")"
cc_resource_tpl="$(yq eval '.api.cost_center_resource_endpoint_template // "/enterprises/{enterprise}/settings/billing/cost-centers/{cost_center_id}/resource"' "$CONFIG_FILE")"

policy_count="$(yq eval '.budget_policies | length' "$CONFIG_FILE")"
if [[ "$policy_count" -eq 0 ]]; then
  echo "No budget policies found in $CONFIG_FILE"
  exit 0
fi

has_value() {
  [[ -n "$1" && "$1" != "null" ]]
}

read_prevent_further_usage() {
  local policy_index="$1" value
  value="$(yq eval ".budget_policies[$policy_index].budget.prevent_further_usage" "$CONFIG_FILE")"
  if ! has_value "$value"; then
    value="true"
  fi
  printf '%s' "$value"
}

derive_budget_type() {
  local sku="$1"
  case "$sku" in
    ai_credits) printf '%s' "BundlePricing" ;;
    *) printf '%s' "ProductPricing" ;;
  esac
}

team_source_label() {
  local source_org="$1" source_enterprise="$2" team_slug="$3"
  if has_value "$source_enterprise"; then
    printf 'enterprise team %s/%s' "$source_enterprise" "$team_slug"
  else
    printf 'org team %s/%s' "$source_org" "$team_slug"
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

# Fetch all members of an org team or enterprise team, returns sorted, unique logins.
# Both org teams (array response) and enterprise teams (object with members[] field) are handled.
fetch_team_logins() {
  local source_org="$1"
  local source_enterprise="$2"
  local team_slug="$3"
  local endpoint

  if has_value "$source_enterprise"; then
    endpoint="/enterprises/$source_enterprise/teams/$team_slug/memberships?per_page=100"
  else
    endpoint="/orgs/$source_org/teams/$team_slug/members?per_page=100"
  fi

  # gh api errors are intentionally left on stderr so callers can detect failures.
  gh api --paginate "$endpoint" | jq -r '
    if type == "array" then .[]
    elif type == "object" and has("members") then .members[]
    else empty end
    | if type == "object" and has("login") then .login
      elif type == "string" then .
      elif type == "object" and has("user") and .user.login then .user.login
      else empty end
  ' | sort -u
}

# List the current User members of a cost center by ID (sorted, unique logins).
# Errors are swallowed so callers can treat a missing/unreadable cost center as
# "no current members" (e.g. a not-yet-created cost center during a dry run).
fetch_cost_center_logins() {
  local cc_id="$1" endpoint
  endpoint="${cc_get_tpl//\{enterprise\}/$ENTERPRISE_SLUG}"
  endpoint="${endpoint//\{cost_center_id\}/$cc_id}"
  gh api --paginate "$endpoint?per_page=100" 2>/dev/null \
    | jq -r '
        (.resources // []) | .[]
        | select((.type // "" | ascii_downcase) == "user")
        | .name
      ' \
    | sort -u
}

# Add user logins to a cost center via the resource endpoint
# (POST .../cost-centers/{id}/resource {"users":[...]}), in batches of up to 50.
# Honors DRY_RUN. Diagnostics go to stderr/stdout; returns non-zero on failure.
add_cost_center_members() {
  local cc_id="$1"
  shift
  local users=("$@")
  [[ ${#users[@]} -eq 0 ]] && return 0

  local endpoint idx end batch_size=50
  endpoint="${cc_resource_tpl//\{enterprise\}/$ENTERPRISE_SLUG}"
  endpoint="${endpoint//\{cost_center_id\}/$cc_id}"

  for ((idx = 0; idx < ${#users[@]}; idx += batch_size)); do
    end=$((idx + batch_size))
    ((end > ${#users[@]})) && end=${#users[@]}
    local slice=("${users[@]:idx:end-idx}")

    if [[ "$DRY_RUN" == "true" ]]; then
      echo "DRY RUN: Would add ${#slice[@]} member(s) to cost center '$cc_id': ${slice[*]}"
      continue
    fi

    local payload
    payload="$(printf '%s\n' "${slice[@]}" | jq -R . | jq -s '{users: .}')"
    if ! gh api -X POST "$endpoint" \
        -H "X-GitHub-Api-Version: $GH_API_VERSION" \
        --input - <<<"$payload" >/dev/null 2>&1; then
      echo "ERROR: Failed to add members to cost center '$cc_id' via '$endpoint'." >&2
      echo "HINT: A 404 means the enhanced billing feature is not enabled or the cost center ID is wrong." >&2
      return 1
    fi
    echo "Added ${#slice[@]} member(s) to cost center '$cc_id': ${slice[*]}"
  done
}

# Cache of all existing budgets (a single JSON array), populated once by
# load_live_budgets and queried by find_live_budget during reconciliation.
LIVE_BUDGETS_CACHE=""

# Optional structured result sink for rich job summaries. When BUDGET_SUMMARY_FILE
# is set, each reconciled entity appends one JSON record (JSON Lines) describing
# the entity (enterprise / cost center / user) and the action taken. When the
# variable is unset the script behaves exactly as before (portable for local use).
SUMMARY_POLICY=""
SUMMARY_TYPE=""
SUMMARY_SKU=""
SUMMARY_GROUP=""

record_result() {
  [[ -n "${BUDGET_SUMMARY_FILE:-}" ]] || return 0
  local scope="$1" entity_key="$2" action="$3" old_amount="${4:-null}" new_amount="${5:-null}"
  local entity_type entity dry_json
  case "$scope" in
    enterprise)          entity_type="enterprise";  entity="$ENTERPRISE_SLUG" ;;
    multi_user_customer) entity_type="universal";   entity="all licensed users" ;;
    cost_center)         entity_type="cost_center"; entity="$entity_key" ;;
    user)                entity_type="user";        entity="$entity_key" ;;
    *)                   entity_type="$scope";      entity="$entity_key" ;;
  esac
  [[ "$DRY_RUN" == "true" ]] && dry_json="true" || dry_json="false"
  jq -nc \
    --arg policy "$SUMMARY_POLICY" \
    --arg type "$SUMMARY_TYPE" \
    --arg sku "$SUMMARY_SKU" \
    --arg entity_type "$entity_type" \
    --arg entity "$entity" \
    --arg group "$SUMMARY_GROUP" \
    --arg action "$action" \
    --argjson old_amount "$old_amount" \
    --argjson new_amount "$new_amount" \
    --argjson dry_run "$dry_json" '
      {policy:$policy, type:$type, sku:$sku, entity_type:$entity_type, entity:$entity,
       group:(if $group == "" then null else $group end),
       action:$action, old_amount:$old_amount, new_amount:$new_amount, dry_run:$dry_run}
    ' >>"$BUDGET_SUMMARY_FILE"
}

# Fetch every existing budget into LIVE_BUDGETS_CACHE as one JSON array.
# The list endpoint paginates (max 10 per page) but DOES send Link headers, so
# --paginate is followed; each page's {budgets:[...]} object is then merged.
load_live_budgets() {
  local raw
  if raw="$(gh api --paginate "$budgets_endpoint?per_page=10" \
    -H "X-GitHub-Api-Version: $GH_API_VERSION" 2>/dev/null \
    | jq -s 'map(.budgets // []) | add')"; then
    printf '%s' "$raw" >"$LIVE_BUDGETS_CACHE"
    echo "Loaded $(jq 'length' "$LIVE_BUDGETS_CACHE") existing budget(s) for reconciliation."
  else
    echo "[]" >"$LIVE_BUDGETS_CACHE"
    echo "WARN: Could not list existing budgets; reconciliation degraded (will attempt creates only)." >&2
    echo "HINT: A 404 means enhanced billing is not enabled; check the token has enterprise billing access." >&2
  fi
}

# Resolve a cost center name to its GA string ID (empty if not found). Deleted
# cost centers are skipped. The budgets API references cost centers by this ID.
resolve_cost_center_id() {
  local name="$1"
  gh api --paginate "$cc_list_endpoint" 2>/dev/null \
    | jq -r --arg n "$name" '
        (.costCenters // []) | .[]
        | select((.state // "active") != "deleted")
        | select(.name == $n) | .id
      ' \
    | head -n1
}

# Resolve a cost center name to its ID, CREATING the cost center when none
# exists yet (POST .../cost-centers, body {"name": ...}). This lets a team's
# additional_spend budget provision its own cost center instead of failing when
# no mapping exists. Honors DRY_RUN (prints intent, echoes a placeholder ID).
# The ID is written to stdout; all diagnostics go to stderr so the surrounding
# command substitution captures only the ID. Returns non-zero on create failure.
ensure_cost_center_id() {
  local name="$1" id created
  id="$(resolve_cost_center_id "$name")"
  if [[ -n "$id" ]]; then
    printf '%s' "$id"
    return 0
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY RUN: Would CREATE cost center '$name' (no existing cost center for this team)" >&2
    printf '%s' "<new-cost-center-id>"
    return 0
  fi
  if ! created="$(gh api -X POST "$cc_list_endpoint" \
      -H "X-GitHub-Api-Version: $GH_API_VERSION" \
      --input - <<<"$(jq -nc --arg name "$name" '{name: $name}')" 2>/dev/null)"; then
    echo "ERROR: Failed to create cost center '$name' via POST '$cc_list_endpoint'." >&2
    echo "HINT: A 409 conflict means the name is already taken (possibly by a deleted cost center); choose a different target.cost_center." >&2
    return 1
  fi
  id="$(printf '%s' "$created" | jq -r '.id // empty')"
  # Fall back to a re-resolve in case the create response shape differs.
  [[ -z "$id" ]] && id="$(resolve_cost_center_id "$name")"
  if [[ -z "$id" ]]; then
    echo "ERROR: Created cost center '$name' but could not determine its ID." >&2
    return 1
  fi
  echo "Created cost center: $name (id=$id)" >&2
  printf '%s' "$id"
}

# Find an existing budget by its natural identity key. Echoes the matching
# budget JSON object, or nothing when there is no match.
# Args: scope sku match_field match_value [match_value2]
#   match_field: "user"   -> match .user (per-member budgets)
#                "entity" -> match .budget_entity_name (e.g. cost center). The
#                            optional match_value2 lets a cost center match by
#                            either its ID or its name (the API takes the ID on
#                            create but may echo the name on read).
#                "none"   -> scope + sku is unique (enterprise, universal)
find_live_budget() {
  local scope="$1" sku="$2" match_field="$3" match_value="$4" match_value2="${5:-}"
  jq -c \
    --arg scope "$scope" \
    --arg sku "$sku" \
    --arg mf "$match_field" \
    --arg mv "$match_value" \
    --arg mv2 "$match_value2" '
      [ .[]
        | select(.budget_scope == $scope)
        | select((.budget_product_sku == $sku)
                 or (((.budget_product_skus // []) | index($sku)) != null))
        | select(
            if $mf == "user" then (.user == $mv)
            elif $mf == "entity" then (.budget_entity_name == $mv
                                       or ($mv2 != "" and .budget_entity_name == $mv2))
            else true end)
      ] | (.[0] // empty)
    ' "$LIVE_BUDGETS_CACHE"
}

# Return 0 when the live budget already matches the desired mutable fields
# (amount, prevent_further_usage, alerting), 1 when it differs (needs PATCH).
budget_is_current() {
  local live="$1" amount="$2" prevent="$3" will_alert="$4" recipients_json="$5"
  local same
  same="$(jq -n \
    --argjson live "$live" \
    --argjson amount "$amount" \
    --argjson prevent "$prevent" \
    --argjson will_alert "$will_alert" \
    --argjson recipients "$recipients_json" '
      ($live.budget_amount == $amount)
      and ($live.prevent_further_usage == $prevent)
      and (($live.budget_alerting.will_alert // false) == $will_alert)
      and ((($live.budget_alerting.alert_recipients // []) | sort) == ($recipients | sort))
    ')"
  [[ "$same" == "true" ]]
}

# Reconcile one budget so live state matches desired config: create it if it
# does not exist, PATCH it if mutable fields differ, or skip if already current.
# Args: label scope sku match_field match_value amount prevent will_alert recipients_json create_payload [match_value2]
upsert_budget() {
  local label="$1" scope="$2" sku="$3" match_field="$4" match_value="$5"
  local amount="$6" prevent="$7" will_alert="$8" recipients_json="$9" create_payload="${10}" match_value2="${11:-}"

  local live
  live="$(find_live_budget "$scope" "$sku" "$match_field" "$match_value" "$match_value2")"

  # No existing budget for this identity -> CREATE.
  if [[ -z "$live" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "DRY RUN: Would CREATE budget $label: $(echo "$create_payload" | jq -c '.')"
      record_result "$scope" "$match_value" "create" "null" "$amount"
      return 0
    fi
    if ! gh api -X POST "$budgets_endpoint" \
      -H "X-GitHub-Api-Version: $GH_API_VERSION" \
      --input - <<<"$create_payload" >/dev/null; then
      echo "ERROR: Failed to create budget $label via '$budgets_endpoint'" >&2
      echo "HINT: A 404 means the enhanced billing feature is not enabled; 422 means the payload was rejected (check scope/SKU/amount)." >&2
      record_result "$scope" "$match_value" "create-failed" "null" "$amount"
      return 1
    fi
    echo "Created budget: $label"
    record_result "$scope" "$match_value" "create" "null" "$amount"
    return 0
  fi

  local budget_id old_amount
  budget_id="$(echo "$live" | jq -r '.id')"
  old_amount="$(echo "$live" | jq -r '.budget_amount // "null"')"

  # Existing budget already matches desired state -> NO-OP.
  if budget_is_current "$live" "$amount" "$prevent" "$will_alert" "$recipients_json"; then
    echo "No change: $label (budget $budget_id already up to date)"
    record_result "$scope" "$match_value" "nochange" "$old_amount" "$amount"
    return 0
  fi

  # Existing budget differs -> UPDATE the mutable fields via PATCH. Identity
  # fields (scope, sku, entity, user) are immutable and are not sent.
  local patch_payload
  patch_payload="$(jq -n \
    --argjson amount "$amount" \
    --argjson prevent "$prevent" \
    --argjson will_alert "$will_alert" \
    --argjson recipients "$recipients_json" '
      {
        budget_amount: $amount,
        prevent_further_usage: $prevent,
        budget_alerting: { will_alert: $will_alert, alert_recipients: $recipients }
      }')"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY RUN: Would UPDATE budget $label (id=$budget_id): $(echo "$patch_payload" | jq -c '.')"
    record_result "$scope" "$match_value" "update" "$old_amount" "$amount"
    return 0
  fi
  if ! gh api -X PATCH "$budgets_endpoint/$budget_id" \
    -H "X-GitHub-Api-Version: $GH_API_VERSION" \
    --input - <<<"$patch_payload" >/dev/null; then
    echo "ERROR: Failed to update budget $label (id=$budget_id) via '$budgets_endpoint/$budget_id'" >&2
    echo "HINT: 422 means the payload was rejected (user/multi_user_customer budgets must keep prevent_further_usage=true)." >&2
    record_result "$scope" "$match_value" "update-failed" "$old_amount" "$amount"
    return 1
  fi
  echo "Updated budget: $label (id=$budget_id)"
  record_result "$scope" "$match_value" "update" "$old_amount" "$amount"
}

# Build a GA budget request body.
# Args: scope amount prevent sku type will_alert recipients_json [user] [entity_name]
# For the `user` scope, the target login is sent in a dedicated `user` field
# (see the GA "add user-level budget" example); other scopes leave it empty.
# For non-user/enterprise scopes (e.g. cost_center), the target entity is named
# via the `budget_entity_name` field.
build_budget_payload() {
  local scope="$1"
  local amount="$2"
  local prevent="$3"
  local sku="$4"
  local btype="$5"
  local will_alert="$6"
  local recipients_json="$7"
  local user="${8:-}"
  local entity_name="${9:-}"

  jq -n \
    --arg scope "$scope" \
    --argjson amount "$amount" \
    --argjson prevent "$prevent" \
    --arg sku "$sku" \
    --arg btype "$btype" \
    --argjson will_alert "$will_alert" \
    --argjson recipients "$recipients_json" \
    --arg user "$user" \
    --arg entity_name "$entity_name" \
    '{
       budget_scope: $scope,
       budget_amount: $amount,
       prevent_further_usage: $prevent,
       budget_product_sku: $sku,
       budget_type: $btype,
       budget_alerting: { will_alert: $will_alert, alert_recipients: $recipients }
     }
     | if $user != "" then . + { user: $user } else . end
     | if $entity_name != "" then . + { budget_entity_name: $entity_name } else . end'
}

failures=0
echo "Applying budget policies for enterprise '$ENTERPRISE_SLUG' (dry_run=$DRY_RUN)"
echo "Budgets endpoint: $budgets_endpoint"
echo "API version: $GH_API_VERSION"

# Reconcile against existing budgets: load them once, then upsert (create/update)
# by each budget's natural identity key instead of blindly creating duplicates.
LIVE_BUDGETS_CACHE="$(mktemp)"
trap 'rm -f "$LIVE_BUDGETS_CACHE"' EXIT
load_live_budgets

for ((i = 0; i < policy_count; i++)); do
  name="$(yq eval ".budget_policies[$i].name // \"policy-$i\"" "$CONFIG_FILE")"
  [[ -n "$POLICY_NAME" && "$name" != "$POLICY_NAME" ]] && continue

  policy_type="$(yq eval ".budget_policies[$i].type // \"\"" "$CONFIG_FILE")"
  description="$(yq eval ".budget_policies[$i].description // \"\"" "$CONFIG_FILE")"
  sku="$(yq eval ".budget_policies[$i].budget.product_sku // \"ai_credits\"" "$CONFIG_FILE")"
  amount="$(yq eval ".budget_policies[$i].budget.amount // 0" "$CONFIG_FILE")"
  # Per-policy context for the structured result records (see record_result).
  SUMMARY_POLICY="$name"
  SUMMARY_TYPE="$policy_type"
  SUMMARY_SKU="$sku"
  SUMMARY_GROUP=""
  prevent="$(read_prevent_further_usage "$i")"

  # budget_type follows the SKU. Explicit budget.type still wins for rare cases.
  btype="$(yq eval ".budget_policies[$i].budget.type // \"\"" "$CONFIG_FILE")"
  if ! has_value "$btype"; then
    btype="$(derive_budget_type "$sku")"
  fi
  will_alert="$(yq eval ".budget_policies[$i].budget.alerting.will_alert // false" "$CONFIG_FILE")"
  recipients_json="$(yq eval -o=json ".budget_policies[$i].budget.alerting.alert_recipients // []" "$CONFIG_FILE" | jq -c '.')"

  echo "---"
  echo "Policy: $name  [type=$policy_type]"
  has_value "$description" && echo "Description: $description"
  echo "Budget: sku=$sku, amount=$amount, prevent_further_usage=$prevent, type=$btype"

  case "$policy_type" in

    enterprise)
      payload="$(build_budget_payload "enterprise" "$amount" "$prevent" "$sku" "$btype" "$will_alert" "$recipients_json")"
      if ! upsert_budget "$name" "enterprise" "$sku" "none" "" "$amount" "$prevent" "$will_alert" "$recipients_json" "$payload"; then
        failures=$((failures + 1))
      fi
      ;;

    universal)
      payload="$(build_budget_payload "multi_user_customer" "$amount" "$prevent" "$sku" "$btype" "$will_alert" "$recipients_json")"
      if ! upsert_budget "$name" "multi_user_customer" "$sku" "none" "" "$amount" "$prevent" "$will_alert" "$recipients_json" "$payload"; then
        failures=$((failures + 1))
      fi
      ;;

    cost_center)
      cost_center="$(yq eval ".budget_policies[$i].target.cost_center // \"\"" "$CONFIG_FILE")"
      if ! has_value "$cost_center"; then
        echo "ERROR: policy '$name' (type=cost_center) must include target.cost_center" >&2
        failures=$((failures + 1))
        continue
      fi
      # The budgets API identifies a cost center by its GA string ID, not its
      # display name. Resolve the name -> ID for both the create payload and the
      # reconciliation match (a 404 here otherwise means "cost center not found").
      cc_id="$(resolve_cost_center_id "$cost_center")"
      if [[ -z "$cc_id" ]]; then
        echo "ERROR: policy '$name' (type=cost_center): cost center '$cost_center' not found (or is deleted) for enterprise '$ENTERPRISE_SLUG'." >&2
        echo "HINT: Names are matched exactly against '$cc_list_endpoint'." >&2
        failures=$((failures + 1))
        continue
      fi
      echo "Target cost center: $cost_center (id=$cc_id)"
      payload="$(build_budget_payload "cost_center" "$amount" "$prevent" "$sku" "$btype" "$will_alert" "$recipients_json" "" "$cc_id")"
      if ! upsert_budget "$name" "cost_center" "$sku" "entity" "$cost_center" "$amount" "$prevent" "$will_alert" "$recipients_json" "$payload" "$cc_id"; then
        failures=$((failures + 1))
      fi
      ;;

    team)
      source_org="$(yq eval ".budget_policies[$i].source.org // \"\"" "$CONFIG_FILE")"
      source_enterprise="$(yq eval ".budget_policies[$i].source.enterprise // \"\"" "$CONFIG_FILE")"
      team_slug="$(yq eval ".budget_policies[$i].source.team_slug // \"\"" "$CONFIG_FILE")"
      # coverage decides how a team budget is materialized:
      #   total_spend (default) -> the cap covers the shared pool + additional
      #                 spend, which can only be enforced per user, so one
      #                 user-level budget is applied to each team member
      #                 (always hard-stop).
      #   additional_spend -> the cap covers additional (metered) spend only,
      #                 which is a group-level concern, so a single cost center
      #                 budget is applied to the cost center named in
      #                 target.cost_center.
      coverage="$(yq eval ".budget_policies[$i].coverage // \"total_spend\"" "$CONFIG_FILE")"

      if ! has_value "$team_slug"; then
        echo "ERROR: policy '$name' (type=team) must include source.team_slug" >&2
        failures=$((failures + 1))
        continue
      fi
      if ! has_value "$source_org" && ! has_value "$source_enterprise"; then
        echo "ERROR: policy '$name' (type=team) must include source.org or source.enterprise" >&2
        failures=$((failures + 1))
        continue
      fi

      echo "Source: $(team_source_label "$source_org" "$source_enterprise" "$team_slug")"

      # ── coverage: additional_spend — cap metered spend via one cost center ──
      # Additional (overspend) is a group-level concern, so the team's collective
      # metered spend is capped by a single cost center budget rather than N
      # per-member budgets. The cost center is provisioned (auto-created when no
      # target.cost_center is given) AND populated with the team's current
      # members, so the budget actually caps the people it is meant to cover.
      # target.cost_center is optional: when omitted, a name is derived by
      # convention so a team can provision its own without a mapping.
      if [[ "$coverage" == "additional_spend" ]]; then
        cost_center="$(yq eval ".budget_policies[$i].target.cost_center // \"\"" "$CONFIG_FILE")"
        if ! has_value "$cost_center"; then
          cost_center="$(default_team_cost_center_name "$source_org" "$source_enterprise" "$team_slug")"
          echo "No target.cost_center set; using derived name '$cost_center' (auto-create if missing)."
        fi
        # Resolve the cost center, creating it when no cost center exists yet.
        if ! cc_id="$(ensure_cost_center_id "$cost_center")"; then
          failures=$((failures + 1))
          continue
        fi
        echo "Coverage: additional spend (metered) -> cost center budget on '$cost_center' (id=$cc_id)"

        # Populate the cost center with the team's current members so the budget
        # caps their metered spend (an empty cost center budget caps nothing).
        # This is additive — members who leave the team are pruned by the
        # sync-cost-center-members workflow (which also handles removals).
        SUMMARY_GROUP="$team_slug"
        members_tmp="$(mktemp)"
        if ! fetch_team_logins "$source_org" "$source_enterprise" "$team_slug" >"$members_tmp"; then
          echo "ERROR: Failed to fetch members for team '$team_slug' in policy '$name'" >&2
          echo "HINT: Check that the token has org/enterprise read permissions and the team slug is correct." >&2
          rm -f "$members_tmp"
          failures=$((failures + 1))
          continue
        fi
        mapfile -t team_logins <"$members_tmp"
        echo "Team members found: ${#team_logins[@]}"
        if [[ ${#team_logins[@]} -eq 0 ]]; then
          echo "WARN: team '$team_slug' has no members; cost center '$cost_center' will be left empty."
        else
          # Only add members not already in the cost center (idempotent).
          cc_members_tmp="$(mktemp)"
          fetch_cost_center_logins "$cc_id" >"$cc_members_tmp" || true
          mapfile -t to_add < <(comm -23 "$members_tmp" "$cc_members_tmp")
          rm -f "$cc_members_tmp"
          if [[ ${#to_add[@]} -eq 0 ]]; then
            echo "Cost center '$cost_center' already contains all ${#team_logins[@]} team member(s); no membership change."
          elif ! add_cost_center_members "$cc_id" "${to_add[@]}"; then
            failures=$((failures + 1))
          fi
        fi
        rm -f "$members_tmp"

        payload="$(build_budget_payload "cost_center" "$amount" "$prevent" "$sku" "$btype" "$will_alert" "$recipients_json" "" "$cc_id")"
        if ! upsert_budget "$name" "cost_center" "$sku" "entity" "$cost_center" "$amount" "$prevent" "$will_alert" "$recipients_json" "$payload" "$cc_id"; then
          failures=$((failures + 1))
        fi
        continue
      fi

      # ── coverage: total_spend — cap pool + additional via per-member budgets ─
      # The shared-pool allotment is per user with no group-level construct, so
      # capping pool + additional means giving every member their own user budget.
      echo "Coverage: total spend (shared pool + additional) -> per-member user budgets"
      # Group the per-member budget records under this team in the job summary.
      SUMMARY_GROUP="$team_slug"

      members_tmp="$(mktemp)"
      if ! fetch_team_logins "$source_org" "$source_enterprise" "$team_slug" >"$members_tmp"; then
        echo "ERROR: Failed to fetch members for team '$team_slug' in policy '$name'" >&2
        echo "HINT: Check that the token has org/enterprise read permissions and the team slug is correct." >&2
        rm -f "$members_tmp"
        failures=$((failures + 1))
        continue
      fi
      mapfile -t logins <"$members_tmp"
      rm -f "$members_tmp"
      echo "Team members found: ${#logins[@]}"

      if [[ ${#logins[@]} -eq 0 ]]; then
        echo "WARN: No members found for policy '$name'; skipping."
        continue
      fi

      for login in "${logins[@]}"; do
        payload="$(build_budget_payload "user" "$amount" "$prevent" "$sku" "$btype" "$will_alert" "$recipients_json" "$login")"
        if ! upsert_budget "$name ($login)" "user" "$sku" "user" "$login" "$amount" "$prevent" "$will_alert" "$recipients_json" "$payload"; then
          failures=$((failures + 1))
        fi
      done
      ;;

    *)
      echo "ERROR: policy '$name' has unknown or missing type '$policy_type'. Valid types: enterprise, universal, cost_center, team." >&2
      failures=$((failures + 1))
      ;;
  esac
done

if ((failures > 0)); then
  echo "Completed with $failures failure(s)." >&2
  exit 1
fi

echo "Budget policy apply flow completed (dry_run=$DRY_RUN)."
