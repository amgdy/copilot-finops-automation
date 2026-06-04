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
    ;;
  *)
    echo "ERROR: Unknown config type '$CONFIG_TYPE'. Use teams or budgets." >&2
    exit 1
    ;;
esac

echo "Config validation passed: $CONFIG_FILE ($CONFIG_TYPE)"
