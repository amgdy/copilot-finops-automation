#!/usr/bin/env bash
set -euo pipefail

ENTERPRISE_SLUG=""
ENTERPRISE_SLUG_CLI=""
CONFIG_FILE="config/copilot-finops.example.yml"
MAPPING_NAME=""
DRY_RUN="true"
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
      ENTERPRISE_SLUG_CLI="$2"
      shift 2
      ;;
    --config-file)
      CONFIG_FILE="$2"
      shift 2
      ;;
    --mapping-name)
      MAPPING_NAME="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="$2"
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

# v2 merges budgets + member mappings into one file and renames the vocab; it is
# validated with type 'all'. v1 keeps the split cost-center-members file. Detect
# the version once and branch the validation + per-mapping field reads.
CONFIG_VERSION="$(yq eval '.version // 1' "$CONFIG_FILE")"

if [[ "$CONFIG_VERSION" == "2" ]]; then
  scripts/validate-config.sh "$CONFIG_FILE" all >/dev/null
else
  scripts/validate-config.sh "$CONFIG_FILE" teams >/dev/null
fi

if [[ -z "$ENTERPRISE_SLUG" ]]; then
  ENTERPRISE_SLUG="$(yq eval '.enterprise_slug // ""' "$CONFIG_FILE")"
fi

# v2 allows a per-entry enterprise: as a "no top-level slug" convenience. When no
# CLI / top-level slug is set, fall back to the first per-entry enterprise so the
# cost center endpoints still resolve (rule 9: one must resolve at runtime).
if [[ -z "$ENTERPRISE_SLUG" && "$CONFIG_VERSION" == "2" ]]; then
  ENTERPRISE_SLUG="$(yq eval '[.team_cost_center_mappings[].enterprise] | map(select(. != null and . != "")) | .[0] // ""' "$CONFIG_FILE")"
fi

if [[ -z "$ENTERPRISE_SLUG" ]]; then
  echo "ERROR: enterprise slug is required via --enterprise-slug, config.enterprise_slug, or a per-entry enterprise:" >&2
  exit 1
fi

# GA cost center endpoint templates (override only if you proxy the API).
cc_list_tpl="$(yq eval '.api.cost_centers_list_endpoint_template // "/enterprises/{enterprise}/settings/billing/cost-centers"' "$CONFIG_FILE")"
cc_get_tpl="$(yq eval '.api.cost_center_endpoint_template // "/enterprises/{enterprise}/settings/billing/cost-centers/{cost_center_id}"' "$CONFIG_FILE")"
cc_resource_tpl="$(yq eval '.api.cost_center_resource_endpoint_template // "/enterprises/{enterprise}/settings/billing/cost-centers/{cost_center_id}/resource"' "$CONFIG_FILE")"

cc_list_endpoint="${cc_list_tpl//\{enterprise\}/$ENTERPRISE_SLUG}"

has_value() {
  [[ -n "$1" && "$1" != "null" ]]
}

team_source_label() {
  local source_org="$1" source_enterprise="$2" team_slug="$3"
  if has_value "$source_enterprise"; then
    printf 'enterprise team %s/%s' "$source_enterprise" "$team_slug"
  else
    printf 'org team %s/%s' "$source_org" "$team_slug"
  fi
}

# Effective enterprise slug for a v2 mapping's enterprise-team membership reads:
# CLI --enterprise-slug wins, then the per-entry enterprise:, then the run-level
# slug. organization: switches the source to an org team instead.
resolve_entry_enterprise() {
  local entry_ent="$1"
  if [[ -n "$ENTERPRISE_SLUG_CLI" ]]; then
    printf '%s' "$ENTERPRISE_SLUG_CLI"
  elif has_value "$entry_ent"; then
    printf '%s' "$entry_ent"
  else
    printf '%s' "$ENTERPRISE_SLUG"
  fi
}

# Normalize a team-members API response (org array or enterprise object) to logins.
normalize_team_users() {
  jq -r '
    if type == "array" then
      .[]
    elif type == "object" and has("members") then
      .members[]
    else
      empty
    end
    | if type == "string" then .
      elif type == "object" and has("login") then .login
      elif type == "object" and has("user") and .user.login then .user.login
      else empty end
  ' | sort -u
}

# Fetch team members from either an org team or an enterprise team (sorted logins).
fetch_team_members() {
  local source_org="$1"
  local source_enterprise="$2"
  local team_slug="$3"
  local endpoint

  if has_value "$source_enterprise"; then
    endpoint="/enterprises/$source_enterprise/teams/$team_slug/memberships?per_page=100"
  else
    endpoint="/orgs/$source_org/teams/$team_slug/members?per_page=100"
  fi

  gh api --paginate "$endpoint" | normalize_team_users
}

# Resolve a cost center name to its GA string ID (empty if not found).
resolve_cost_center_id() {
  local name="$1"
  gh api --paginate "$cc_list_endpoint" \
    | jq -r --arg n "$name" '
        (.costCenters // []) | .[]
        | select((.state // "active") != "deleted")
        | select(.name == $n) | .id
      ' \
    | head -n1
}

# List current user members of a cost center by ID (sorted logins).
fetch_cost_center_users() {
  local cc_id="$1"
  local endpoint="${cc_get_tpl//\{enterprise\}/$ENTERPRISE_SLUG}"
  endpoint="${endpoint//\{cost_center_id\}/$cc_id}"
  gh api --paginate "$endpoint?per_page=100" \
    | jq -r '
        (.resources // []) | .[]
        | select((.type // "" | ascii_downcase) == "user")
        | .name
      ' \
    | sort -u
}

# Lowercase + slugify a string (spaces/punctuation -> single hyphens) for matching
# a native team resource name against a configured team slug.
slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

# List natively-assigned team resources of a cost center by ID (sorted names).
#
# The "assign enterprise teams to cost centers" feature (GA 2026-06-25) stores an
# enterprise team as a single Team resource and attributes its members dynamically
# (kept current automatically, including via SCIM/IdP sync) instead of expanding
# them into individual user resources. We match any resource whose type contains
# "team" (e.g. "Team", "EnterpriseTeam") to stay robust to the exact label.
fetch_cost_center_teams() {
  local cc_id="$1"
  local endpoint="${cc_get_tpl//\{enterprise\}/$ENTERPRISE_SLUG}"
  endpoint="${endpoint//\{cost_center_id\}/$cc_id}"
  gh api --paginate "$endpoint?per_page=100" \
    | jq -r '
        (.resources // []) | .[]
        | select((.type // "" | ascii_downcase) | test("team"))
        | .name
      ' \
    | sort -u
}

# Add or remove user members of a cost center using the GA resource endpoint.
# add  -> POST   .../resource  {"users":[...]}
# remove -> DELETE .../resource {"users":[...]}
batch_apply() {
  local action="$1"
  local cc_id="$2"
  local batch_size="$3"
  shift 3
  local users=("$@")

  [[ ${#users[@]} -eq 0 ]] && return 0

  local method endpoint idx end
  case "$action" in
    add) method="POST" ;;
    remove) method="DELETE" ;;
    *)
      echo "ERROR: unknown cost center action '$action'" >&2
      return 1
      ;;
  esac

  endpoint="${cc_resource_tpl//\{enterprise\}/$ENTERPRISE_SLUG}"
  endpoint="${endpoint//\{cost_center_id\}/$cc_id}"

  for ((idx = 0; idx < ${#users[@]}; idx += batch_size)); do
    end=$((idx + batch_size))
    if ((end > ${#users[@]})); then end=${#users[@]}; fi
    local slice=("${users[@]:idx:end-idx}")

    if [[ "$DRY_RUN" == "true" ]]; then
      echo "DRY RUN: Would ${action} ${#slice[@]} users on cost center '$cc_id': ${slice[*]}"
      continue
    fi

    local users_json payload
    users_json="$(printf '%s\n' "${slice[@]}" | jq -R . | jq -s '.')"
    payload="$(jq -n --argjson users "$users_json" '{users: $users}')"

    if ! gh api -X "$method" "$endpoint" --input - <<<"$payload" >/dev/null; then
      echo "ERROR: Failed to ${action} users on cost center '$cc_id' via '$endpoint'" >&2
      echo "HINT: A 404 means the enhanced billing feature is not enabled or the cost center ID is wrong." >&2
      return 1
    fi
    echo "Applied ${action} batch (${#slice[@]} users) on cost center '$cc_id'"
  done
}

if [[ "$CONFIG_VERSION" == "2" ]]; then
  mapping_count="$(yq eval '(.team_cost_center_mappings // []) | length' "$CONFIG_FILE")"
else
  mapping_count="$(yq eval '(.mappings // []) | length' "$CONFIG_FILE")"
fi
if [[ "$mapping_count" -eq 0 ]]; then
  echo "No mappings found in $CONFIG_FILE"
  exit 0
fi

failures=0
echo "Starting sync for enterprise '$ENTERPRISE_SLUG' (dry_run=$DRY_RUN)"
for ((i = 0; i < mapping_count; i++)); do
  if [[ "$CONFIG_VERSION" == "2" ]]; then
    # v2 vocab: team/organization/enterprise/cost_center/remove_extra_members.
    # batch_size is not a v2 surface field; it stays an internal default of 50.
    name="$(yq eval ".team_cost_center_mappings[$i].name // \"mapping-$i\"" "$CONFIG_FILE")"
    [[ -n "$MAPPING_NAME" && "$name" != "$MAPPING_NAME" ]] && continue
    m_org="$(yq eval ".team_cost_center_mappings[$i].organization // \"\"" "$CONFIG_FILE")"
    m_entry_ent="$(yq eval ".team_cost_center_mappings[$i].enterprise // \"\"" "$CONFIG_FILE")"
    team_slug="$(yq eval ".team_cost_center_mappings[$i].team // \"\"" "$CONFIG_FILE")"
    cost_center="$(yq eval ".team_cost_center_mappings[$i].cost_center // \"\"" "$CONFIG_FILE")"
    remove_extra="$(yq eval ".team_cost_center_mappings[$i].remove_extra_members // false" "$CONFIG_FILE")"
    m_force="$(yq eval ".team_cost_center_mappings[$i].force_user_sync // false" "$CONFIG_FILE")"
    batch_size=50
    if has_value "$m_org"; then
      source_org="$m_org"
      source_enterprise=""
    else
      source_org=""
      source_enterprise="$(resolve_entry_enterprise "$m_entry_ent")"
    fi
  else
    # v1 vocab: source.org / source.enterprise / source.team_slug / target.cost_center / sync.*.
    name="$(yq eval ".mappings[$i].name // \"mapping-$i\"" "$CONFIG_FILE")"
    [[ -n "$MAPPING_NAME" && "$name" != "$MAPPING_NAME" ]] && continue
    source_org="$(yq eval ".mappings[$i].source.org // \"\"" "$CONFIG_FILE")"
    source_enterprise="$(yq eval ".mappings[$i].source.enterprise // \"\"" "$CONFIG_FILE")"
    team_slug="$(yq eval ".mappings[$i].source.team_slug" "$CONFIG_FILE")"
    cost_center="$(yq eval ".mappings[$i].target.cost_center" "$CONFIG_FILE")"
    remove_extra="$(yq eval ".mappings[$i].sync.remove_extra_members // false" "$CONFIG_FILE")"
    batch_size="$(yq eval ".mappings[$i].sync.batch_size // 50" "$CONFIG_FILE")"
    # v1 is frozen and has no force_user_sync field; only the global
    # --force-user-sync flag can opt a v1 config back into user-level sync.
    m_force="false"
  fi

  # Effective opt-in: the global --force-user-sync flag OR a per-mapping
  # force_user_sync: true. When neither is set, the mapping is skipped (below) in
  # favor of native enterprise-team -> cost center assignment (GA 2026-06-25).
  if [[ "$FORCE_USER_SYNC" == "true" || "$m_force" == "true" ]]; then
    force_user_sync="true"
  else
    force_user_sync="false"
  fi

  # Validate required fields
  if ! has_value "$team_slug"; then
    echo "ERROR: mapping '$name' must include source.team_slug" >&2
    exit 1
  fi
  if ! has_value "$cost_center"; then
    echo "ERROR: mapping '$name' must include target.cost_center" >&2
    exit 1
  fi
  if ! has_value "$source_org" && ! has_value "$source_enterprise"; then
    echo "ERROR: mapping '$name' must include either source.org or source.enterprise" >&2
    exit 1
  fi

  if ((batch_size < 1 || batch_size > 50)); then
    echo "WARN: mapping '$name' batch_size must be between 1 and 50; using 50"
    batch_size=50
  fi

  echo "---"
  echo "Mapping: $name"
  echo "Source: $(team_source_label "$source_org" "$source_enterprise" "$team_slug")"
  echo "Target cost center: $cost_center"

  # Default: defer to native enterprise-team -> cost center assignment (GA
  # 2026-06-25) and SKIP user-level sync. GitHub keeps a natively-assigned team's
  # membership current automatically (incl. SCIM/IdP), so the legacy user-level
  # sync is only needed where native assignment is not usable. Opt in per mapping
  # with force_user_sync: true, or globally with --force-user-sync.
  if [[ "$force_user_sync" != "true" ]]; then
    echo "NOTE: Skipping user-level membership sync for mapping '$name'."
    echo "      Enterprise teams can now be assigned to cost centers natively, which keeps membership"
    echo "      current automatically. Assign team '$team_slug' to cost center '$cost_center' under"
    echo "      Enterprise → Settings → Billing → Cost centers."
    echo "      To run the legacy user-level sync instead, set force_user_sync: true on the mapping"
    echo "      (or pass --force-user-sync true)."
    continue
  fi

  team_file="$(mktemp)"
  cc_file="$(mktemp)"

  if ! fetch_team_members "$source_org" "$source_enterprise" "$team_slug" >"$team_file"; then
    echo "ERROR: Failed to fetch team members for mapping '$name'" >&2
    rm -f "$team_file" "$cc_file"
    failures=$((failures + 1))
    continue
  fi

  cc_id="$(resolve_cost_center_id "$cost_center")"
  if [[ -z "$cc_id" ]]; then
    echo "ERROR: Cost center '$cost_center' not found for enterprise '$ENTERPRISE_SLUG'." >&2
    echo "HINT: Create it first (POST $cc_list_endpoint) or check the name." >&2
    rm -f "$team_file" "$cc_file"
    failures=$((failures + 1))
    continue
  fi
  echo "Resolved cost center ID: $cc_id"

  if ! fetch_cost_center_users "$cc_id" >"$cc_file"; then
    echo "ERROR: Failed to read members of cost center '$cost_center' ($cc_id)" >&2
    rm -f "$team_file" "$cc_file"
    failures=$((failures + 1))
    continue
  fi

  # Defer to native enterprise-team assignment when present (GA 2026-06-25). If
  # this mapping's team is already assigned to the cost center as a native team
  # resource, GitHub keeps that membership current automatically, so user-level
  # sync would redundantly (and conflictingly) re-add the same members as direct
  # user resources. Skip the mapping in that case; warn on any other team resource
  # so operators don't unknowingly double-manage one cost center.
  mapfile -t cc_teams < <(fetch_cost_center_teams "$cc_id")
  if ((${#cc_teams[@]})); then
    team_slug_lc="$(printf '%s' "$team_slug" | tr '[:upper:]' '[:lower:]')"
    team_slug_norm="$(slugify "$team_slug")"
    team_natively_assigned=false
    for cc_team in "${cc_teams[@]}"; do
      cc_team_lc="$(printf '%s' "$cc_team" | tr '[:upper:]' '[:lower:]')"
      if [[ "$cc_team_lc" == "$team_slug_lc" || "$(slugify "$cc_team")" == "$team_slug_norm" ]]; then
        team_natively_assigned=true
        break
      fi
    done

    if [[ "$team_natively_assigned" == "true" ]]; then
      echo "NOTE: Cost center '$cost_center' already has enterprise team '$team_slug' assigned natively."
      echo "      GitHub keeps that membership current automatically (incl. SCIM/IdP sync), so user-level"
      echo "      sync is redundant. Skipping mapping '$name' to avoid double-managing the same members."
      echo "      To run user-level sync anyway, remove the native team assignment from the cost center."
      rm -f "$team_file" "$cc_file"
      continue
    fi

    echo "WARN: Cost center '$cost_center' has natively-assigned team resource(s): ${cc_teams[*]}."
    echo "      Their members are attributed dynamically and are not listed as user resources, so they"
    echo "      are excluded from the diff below. Avoid mixing native team assignment with user-level sync"
    echo "      on the same cost center."
  fi

  mapfile -t to_add < <(comm -23 "$team_file" "$cc_file")
  mapfile -t to_remove < <(comm -13 "$team_file" "$cc_file")

  echo "Team members: $(wc -l < "$team_file" | tr -d ' ')"
  echo "Cost center members: $(wc -l < "$cc_file" | tr -d ' ')"
  echo "Would add: ${#to_add[@]}"
  if [[ "$remove_extra" == "true" ]]; then
    echo "Would remove: ${#to_remove[@]}"
  else
    echo "Would remove: 0 (remove_extra_members=false)"
  fi

  # Optional structured result sink for rich job summaries: one JSON record per
  # member change (JSON Lines). Active only when SYNC_SUMMARY_FILE is set, so the
  # script stays portable for local use.
  if [[ -n "${SYNC_SUMMARY_FILE:-}" ]]; then
    [[ "$DRY_RUN" == "true" ]] && dry_json="true" || dry_json="false"
    if ((${#to_add[@]})); then
      for login in "${to_add[@]}"; do
        jq -nc --arg mapping "$name" --arg team "$team_slug" --arg cost_center "$cost_center" \
          --arg entity "$login" --arg action "add" --argjson dry_run "$dry_json" \
          '{mapping:$mapping, team:$team, cost_center:$cost_center, entity:$entity, action:$action, dry_run:$dry_run}' \
          >>"$SYNC_SUMMARY_FILE"
      done
    fi
    if [[ "$remove_extra" == "true" ]] && ((${#to_remove[@]})); then
      for login in "${to_remove[@]}"; do
        jq -nc --arg mapping "$name" --arg team "$team_slug" --arg cost_center "$cost_center" \
          --arg entity "$login" --arg action "remove" --argjson dry_run "$dry_json" \
          '{mapping:$mapping, team:$team, cost_center:$cost_center, entity:$entity, action:$action, dry_run:$dry_run}' \
          >>"$SYNC_SUMMARY_FILE"
      done
    fi
  fi

  if ! batch_apply add "$cc_id" "$batch_size" "${to_add[@]}"; then
    failures=$((failures + 1))
  fi
  if [[ "$remove_extra" == "true" ]]; then
    if ! batch_apply remove "$cc_id" "$batch_size" "${to_remove[@]}"; then
      failures=$((failures + 1))
    fi
  fi

  rm -f "$team_file" "$cc_file"
done

if ((failures > 0)); then
  echo "Sync completed with $failures failure(s) (dry_run=$DRY_RUN)." >&2
  exit 1
fi

echo "Sync completed (dry_run=$DRY_RUN)."
