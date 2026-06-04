#!/usr/bin/env bash
set -euo pipefail

ENTERPRISE_SLUG=""
CONFIG_FILE="config/teams-to-cost-centers.example.yml"
MAPPING_NAME=""
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
    --mapping-name)
      MAPPING_NAME="$2"
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

scripts/validate-config.sh "$CONFIG_FILE" teams >/dev/null

if [[ -z "$ENTERPRISE_SLUG" ]]; then
  ENTERPRISE_SLUG="$(yq eval '.enterprise_slug // ""' "$CONFIG_FILE")"
fi

if [[ -z "$ENTERPRISE_SLUG" ]]; then
  echo "ERROR: enterprise slug is required via --enterprise-slug or config.enterprise_slug" >&2
  exit 1
fi

normalize_users() {
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

check_api_error_shape() {
  local err_file="$1"
  if grep -Eq '404|422' "$err_file"; then
    cat >&2 <<'EOF'
ERROR: The Copilot cost center API endpoint returned 404/422.
The endpoint may require adjustment for your enterprise API version.
Update config.api.cost_center_members_endpoint_template if needed.
EOF
  fi
}

fetch_json_or_fail() {
  local endpoint="$1"
  local out err
  out="$(mktemp)"
  err="$(mktemp)"
  if ! gh api "$endpoint" >"$out" 2>"$err"; then
    check_api_error_shape "$err"
    cat "$err" >&2
    rm -f "$out" "$err"
    return 1
  fi
  cat "$out"
  rm -f "$out" "$err"
}

batch_apply() {
  local action="$1"
  local cost_center="$2"
  local batch_size="$3"
  shift 3
  local users=("$@")

  [[ ${#users[@]} -eq 0 ]] && return 0

  local endpoint_template endpoint idx end
  endpoint_template="$(yq eval '.api.cost_center_members_endpoint_template // "/enterprises/{enterprise}/settings/billing/cost-centers/{cost_center}/members"' "$CONFIG_FILE")"
  endpoint="${endpoint_template//\{enterprise\}/$ENTERPRISE_SLUG}"
  endpoint="${endpoint//\{cost_center\}/$cost_center}"

  for ((idx = 0; idx < ${#users[@]}; idx += batch_size)); do
    end=$((idx + batch_size))
    if ((end > ${#users[@]})); then end=${#users[@]}; fi
    local slice=("${users[@]:idx:end-idx}")

    if [[ "$DRY_RUN" == "true" ]]; then
      echo "DRY RUN: Would ${action} ${#slice[@]} users for cost center '$cost_center': ${slice[*]}"
      continue
    fi

    local users_json payload
    users_json="$(printf '%s\n' "${slice[@]}" | jq -R . | jq -s '.')"
    payload="$(jq -n --arg action "$action" --argjson users "$users_json" '{($action): $users}')"

    if ! gh api -X PATCH "$endpoint" --input - <<<"$payload" >/dev/null; then
      echo "ERROR: Failed to ${action} users for cost center '$cost_center' via endpoint '$endpoint'" >&2
      echo "HINT: Endpoint shapes can change; adjust config.api.cost_center_members_endpoint_template." >&2
      return 1
    fi
    echo "Applied ${action} batch (${#slice[@]} users) for cost center '$cost_center'"
  done
}

mapping_count="$(yq eval '.mappings | length' "$CONFIG_FILE")"
if [[ "$mapping_count" -eq 0 ]]; then
  echo "No mappings found in $CONFIG_FILE"
  exit 0
fi

echo "Starting sync for enterprise '$ENTERPRISE_SLUG' (dry_run=$DRY_RUN)"
for ((i = 0; i < mapping_count; i++)); do
  name="$(yq eval ".mappings[$i].name // \"mapping-$i\"" "$CONFIG_FILE")"
  [[ -n "$MAPPING_NAME" && "$name" != "$MAPPING_NAME" ]] && continue

  org="$(yq eval ".mappings[$i].source.org" "$CONFIG_FILE")"
  team_slug="$(yq eval ".mappings[$i].source.team_slug" "$CONFIG_FILE")"
  cost_center="$(yq eval ".mappings[$i].target.cost_center" "$CONFIG_FILE")"
  remove_extra="$(yq eval ".mappings[$i].sync.remove_extra_members // false" "$CONFIG_FILE")"
  batch_size="$(yq eval ".mappings[$i].sync.batch_size // 50" "$CONFIG_FILE")"

  if [[ -z "$org" || -z "$team_slug" || -z "$cost_center" || "$org" == "null" || "$team_slug" == "null" || "$cost_center" == "null" ]]; then
    echo "ERROR: mapping '$name' must include source.org, source.team_slug, target.cost_center" >&2
    exit 1
  fi

  if ((batch_size < 1 || batch_size > 50)); then
    echo "WARN: mapping '$name' batch_size must be between 1 and 50; using 50"
    batch_size=50
  fi

  echo "---"
  echo "Mapping: $name"
  echo "Source team: $org/$team_slug"
  echo "Target cost center: $cost_center"

  team_members_json="$(fetch_json_or_fail "/orgs/$org/teams/$team_slug/members?per_page=100")"

  endpoint_template="$(yq eval '.api.cost_center_members_endpoint_template // "/enterprises/{enterprise}/settings/billing/cost-centers/{cost_center}/members"' "$CONFIG_FILE")"
  cc_endpoint="${endpoint_template//\{enterprise\}/$ENTERPRISE_SLUG}"
  cc_endpoint="${cc_endpoint//\{cost_center\}/$cost_center}"
  cost_center_members_json="$(fetch_json_or_fail "$cc_endpoint?per_page=100")"

  team_file="$(mktemp)"
  cc_file="$(mktemp)"
  printf '%s' "$team_members_json" | normalize_users >"$team_file"
  printf '%s' "$cost_center_members_json" | normalize_users >"$cc_file"

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

  batch_apply add "$cost_center" "$batch_size" "${to_add[@]}"
  if [[ "$remove_extra" == "true" ]]; then
    batch_apply remove "$cost_center" "$batch_size" "${to_remove[@]}"
  fi

  rm -f "$team_file" "$cc_file"
done

echo "Sync completed (dry_run=$DRY_RUN)."
