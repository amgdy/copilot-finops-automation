#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE_INPUT=""
ISSUE_NUMBER=""
OUTPUT_ENV_FILE="${GITHUB_ENV:-}"
OUTPUT_SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config-file)
      CONFIG_FILE_INPUT="$2"
      shift 2
      ;;
    --issue-number)
      ISSUE_NUMBER="$2"
      shift 2
      ;;
    --dry-run)
      shift 2
      ;;
    --env-file)
      OUTPUT_ENV_FILE="$2"
      shift 2
      ;;
    --summary-file)
      OUTPUT_SUMMARY_FILE="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$CONFIG_FILE_INPUT" ]]; then
  echo "ERROR: --config-file is required" >&2
  exit 1
fi
if [[ -z "$OUTPUT_ENV_FILE" ]]; then
  echo "ERROR: --env-file or GITHUB_ENV is required" >&2
  exit 1
fi
if [[ -z "$OUTPUT_SUMMARY_FILE" ]]; then
  echo "ERROR: --summary-file or GITHUB_STEP_SUMMARY is required" >&2
  exit 1
fi

resolved_config_file="$CONFIG_FILE_INPUT"
resolved_config_source="file: $CONFIG_FILE_INPUT"
resolved_config_from_issue="false"
issue_url=""
issue_updated_at=""
config_sha256=""

if [[ -n "$ISSUE_NUMBER" ]]; then
  issue_json="$RUNNER_TEMP/budget-policy-issue.json"
  issue_body="$RUNNER_TEMP/budget-policy-issue.md"
  resolved_config_file="$RUNNER_TEMP/budget-policies.yml"

  gh issue view "$ISSUE_NUMBER" --json number,title,state,url,updatedAt,labels,body >"$issue_json"
  jq -r '.body' "$issue_json" >"$issue_body"

  if [[ "$(jq -r '.state' "$issue_json")" != "OPEN" ]]; then
    echo "ERROR: Issue #$ISSUE_NUMBER must be open." >&2
    exit 1
  fi

  if ! jq -e 'any(.labels[].name; . == "budget-policy-config")' "$issue_json" >/dev/null; then
    echo "ERROR: Issue #$ISSUE_NUMBER must have the budget-policy-config label." >&2
    exit 1
  fi

  awk '
    BEGIN { in_section=0; in_fence=0 }
    /^### Budget policies YAML[[:space:]]*$/ { in_section=1; next }
    in_section && /^### / && !in_fence { exit }
    in_section && /^```/ {
      if (!in_fence) { in_fence=1; next }
      exit
    }
    in_section && in_fence { print }
  ' "$issue_body" >"$resolved_config_file"

  if [[ ! -s "$resolved_config_file" ]]; then
    echo "ERROR: Could not extract a fenced YAML block from the 'Budget policies YAML' issue field." >&2
    exit 1
  fi

  resolved_config_source="issue #$ISSUE_NUMBER: Budget policies YAML"
  resolved_config_from_issue="true"
  issue_url="$(jq -r '.url' "$issue_json")"
  issue_updated_at="$(jq -r '.updatedAt' "$issue_json")"
  config_sha256="$(shasum -a 256 "$resolved_config_file" | awk '{print $1}')"
fi

{
  echo "BUDGET_POLICIES_CONFIG_FILE=$resolved_config_file"
  echo "BUDGET_POLICIES_CONFIG_SOURCE=$resolved_config_source"
  echo "BUDGET_POLICIES_CONFIG_FROM_ISSUE=$resolved_config_from_issue"
  echo "BUDGET_POLICIES_ISSUE_NUMBER=$ISSUE_NUMBER"
  echo "BUDGET_POLICIES_ISSUE_URL=$issue_url"
  echo "BUDGET_POLICIES_ISSUE_UPDATED_AT=$issue_updated_at"
  echo "BUDGET_POLICIES_CONFIG_SHA256=$config_sha256"
} >>"$OUTPUT_ENV_FILE"

{
  echo "## Budget policies config"
  echo
  echo "- **Source:** $resolved_config_source"
  if [[ "$resolved_config_from_issue" == "true" ]]; then
    echo "- **Issue:** $issue_url"
    echo "- **Issue updated at:** $issue_updated_at"
    echo "- **Config SHA-256:** \`$config_sha256\`"
  fi
  echo "- **Resolved file:** \`$resolved_config_file\`"
  echo
  echo "<details><summary>Config YAML</summary>"
  echo
  echo '```yaml'
  cat "$resolved_config_file"
  echo '```'
  echo
  echo "</details>"
  echo
} >>"$OUTPUT_SUMMARY_FILE"
