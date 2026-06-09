#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${1:-}"
CONFIG_TYPE="${2:-}"

if [[ -z "$CONFIG_FILE" || -z "$CONFIG_TYPE" ]]; then
  echo "Usage: $0 <config-file> <teams|budgets>" >&2
  exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Config file does not exist: $CONFIG_FILE" >&2
  exit 1
fi

if ! command -v yq >/dev/null 2>&1; then
  echo "ERROR: yq is required for config validation." >&2
  exit 1
fi

yq eval '.' "$CONFIG_FILE" >/dev/null

config_value() {
  yq eval "$1 // \"\"" "$CONFIG_FILE"
}

has_value() {
  [[ -n "$1" && "$1" != "null" ]]
}

read_default_true() {
  local expression="$1" value
  # Read raw (not via //) so explicit false stays false.
  value="$(yq eval "$expression" "$CONFIG_FILE")"
  if ! has_value "$value"; then
    value="true"
  fi
  printf '%s' "$value"
}

case "$CONFIG_TYPE" in
  teams)
    if [[ "$(yq eval 'has("mappings")' "$CONFIG_FILE")" != "true" ]]; then
      echo "ERROR: teams config must include top-level key: mappings" >&2
      exit 1
    fi
    if [[ "$(yq eval '.mappings | type' "$CONFIG_FILE")" != "!!seq" ]]; then
      echo "ERROR: teams config .mappings must be a list" >&2
      exit 1
    fi
    # Validate each mapping has required fields
    count="$(yq eval '.mappings | length' "$CONFIG_FILE")"
    for ((i = 0; i < count; i++)); do
      name="$(config_value ".mappings[$i].name")"
      has_value "$name" || name="mapping-$i"
      team_slug="$(config_value ".mappings[$i].source.team_slug")"
      cost_center="$(config_value ".mappings[$i].target.cost_center")"
      source_org="$(config_value ".mappings[$i].source.org")"
      source_ent="$(config_value ".mappings[$i].source.enterprise")"
      if ! has_value "$team_slug"; then
        echo "ERROR: mapping '$name' is missing source.team_slug" >&2
        exit 1
      fi
      if ! has_value "$cost_center"; then
        echo "ERROR: mapping '$name' is missing target.cost_center" >&2
        exit 1
      fi
      if ! has_value "$source_org" && ! has_value "$source_ent"; then
        echo "ERROR: mapping '$name' must have source.org or source.enterprise" >&2
        exit 1
      fi
    done
    ;;
  budgets)
    if [[ "$(yq eval 'has("budget_policies")' "$CONFIG_FILE")" != "true" ]]; then
      echo "ERROR: budget config must include top-level key: budget_policies" >&2
      exit 1
    fi
    if [[ "$(yq eval '.budget_policies | type' "$CONFIG_FILE")" != "!!seq" ]]; then
      echo "ERROR: budget config .budget_policies must be a list" >&2
      exit 1
    fi
    # Validate each policy has required fields
    count="$(yq eval '.budget_policies | length' "$CONFIG_FILE")"
    for ((i = 0; i < count; i++)); do
      name="$(config_value ".budget_policies[$i].name")"
      has_value "$name" || name="policy-$i"
      policy_type="$(config_value ".budget_policies[$i].type")"
      if ! has_value "$policy_type"; then
        echo "ERROR: budget policy '$name' is missing required field: type (enterprise|universal|cost_center|team)" >&2
        exit 1
      fi
      case "$policy_type" in
        enterprise | universal | cost_center | team) ;;
        *)
          echo "ERROR: budget policy '$name' has invalid type '$policy_type'. Valid: enterprise, universal, cost_center, team" >&2
          exit 1
          ;;
      esac

      # GA budgets API: budget_amount is required. budget.product_sku is optional
      # and defaults to ai_credits in the apply scripts when omitted.
      amount="$(config_value ".budget_policies[$i].budget.amount")"
      if ! [[ "$amount" =~ ^[0-9]+$ ]]; then
        echo "ERROR: budget policy '$name' budget.amount must be a non-negative whole number (USD)" >&2
        exit 1
      fi

      # user / multi_user_customer scopes always hard-stop: prevent_further_usage
      # defaults to true and may not be set to false. This applies to `universal`
      # and to `team` policies that materialize as per-member user budgets
      # (coverage: total_spend). A `team` policy with coverage: additional_spend
      # materializes as a cost center budget, where the hard stop is optional
      # (checked below).
      prevent="$(read_default_true ".budget_policies[$i].budget.prevent_further_usage")"
      if [[ "$policy_type" == "universal" ]]; then
        if [[ "$prevent" != "true" ]]; then
          echo "ERROR: budget policy '$name' (type=$policy_type) must not set budget.prevent_further_usage: false (user-level budgets always hard-stop)" >&2
          exit 1
        fi
      fi

      if [[ "$policy_type" == "team" ]]; then
        team_slug="$(config_value ".budget_policies[$i].source.team_slug")"
        source_org="$(config_value ".budget_policies[$i].source.org")"
        source_ent="$(config_value ".budget_policies[$i].source.enterprise")"
        coverage="$(config_value ".budget_policies[$i].coverage")"
        has_value "$coverage" || coverage="total_spend"
        if ! has_value "$team_slug"; then
          echo "ERROR: budget policy '$name' (type=team) is missing source.team_slug" >&2
          exit 1
        fi
        if ! has_value "$source_org" && ! has_value "$source_ent"; then
          echo "ERROR: budget policy '$name' (type=team) must have source.org or source.enterprise" >&2
          exit 1
        fi
        case "$coverage" in
          total_spend)
            # Materialized as per-member user budgets, which always hard-stop.
            if [[ "$prevent" != "true" ]]; then
              echo "ERROR: budget policy '$name' (type=team, coverage=total_spend) must not set budget.prevent_further_usage: false (per-member user budgets always hard-stop)" >&2
              exit 1
            fi
            ;;
          additional_spend)
            # Materialized as one cost center budget. target.cost_center is
            # optional: when omitted the apply step derives a name from the team
            # source and auto-creates the cost center. The hard stop is optional
            # here (cost center budgets may alert-only), so no prevent check.
            :
            ;;
          *)
            echo "ERROR: budget policy '$name' (type=team) has invalid coverage '$coverage'. Valid: total_spend (per-member user budgets), additional_spend (cost center budget)" >&2
            exit 1
            ;;
        esac
      fi

      # cost_center budgets target a single cost center by name (resolved to its
      # ID at apply time) and must include target.cost_center.
      if [[ "$policy_type" == "cost_center" ]]; then
        cost_center="$(config_value ".budget_policies[$i].target.cost_center")"
        if ! has_value "$cost_center"; then
          echo "ERROR: budget policy '$name' (type=cost_center) is missing target.cost_center" >&2
          exit 1
        fi
      fi
    done
    ;;
  *)
    echo "ERROR: Unknown config type '$CONFIG_TYPE'. Use teams or budgets." >&2
    exit 1
    ;;
esac

echo "Config validation passed: $CONFIG_FILE ($CONFIG_TYPE)"
