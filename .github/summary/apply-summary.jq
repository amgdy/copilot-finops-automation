# Renders a policy-first Markdown summary from the budget reconciliation records
# emitted by scripts/apply-user-budgets.sh (BUDGET_SUMMARY_FILE, JSON Lines).
# Usage: jq -rs -f apply-summary.jq budget-summary.jsonl
#
# Each input record looks like:
#   {policy, type, sku, entity_type, entity, group, action, old_amount, new_amount, dry_run}
# entity_type is one of: enterprise | universal | cost_center | user
# action is one of: create | update | nochange | create-failed | update-failed

def money(x): if x == null then "—" else "$" + (x | tostring) end;

def outcome(r):
  (if r.dry_run then
     {"create": "Would create", "update": "Would update", "nochange": "No change",
      "create-failed": "Create FAILED", "update-failed": "Update FAILED"}
   else
     {"create": "Created", "update": "Updated", "nochange": "No change",
      "create-failed": "Create FAILED", "update-failed": "Update FAILED"}
   end)[r.action] // r.action;

def amt(r):
  if (r.action | startswith("create")) then "→ " + money(r.new_amount)
  elif (r.action | startswith("update")) then money(r.old_amount) + " → " + money(r.new_amount)
  else money(r.new_amount) end;

def mode($dry): if $dry then "dry-run (preview only)" else "live (changes applied)" end;

def is_failed: (.action // "" | endswith("-failed"));
def is_changed: (.action // "") != "nochange";

def policy_name(r):
  if (r.policy // "") == "" then "(unnamed policy)" else r.policy end;

def code_or_dash(x):
  if (x // "") == "" then "—" else "`" + (x | tostring) + "`" end;

def target(r):
  if r.entity_type == "enterprise" then "Enterprise `" + r.entity + "`"
  elif r.entity_type == "universal" then r.entity
  elif r.entity_type == "cost_center" then "Cost center `" + r.entity + "`"
  elif r.entity_type == "user" then "User `" + r.entity + "`"
  else (r.entity_type // "target") + " `" + (r.entity // "—") + "`" end;

def action_counts($dry):
  sort_by(.action)
  | group_by(.action)
  | map(outcome({action: .[0].action, dry_run: $dry}) + ": " + (length | tostring))
  | join("<br/>");

def count_action($action): map(select(.action == $action)) | length;
def count_changed: map(select(is_changed)) | length;
def count_failed: map(select(is_failed)) | length;

def scope_summary:
  map(.entity_type // empty)
  | unique
  | if length == 0 then "—" else map("`" + . + "`") | join(", ") end;

def groups_summary:
  map(.group // empty)
  | unique
  | if length == 0 then "—" else map("`" + . + "`") | join(", ") end;

. as $all
| ($all[0].dry_run) as $dry
| (
    # ---- Run overview ----
    ["### Run overview", "",
     "| Metric | Value |", "| --- | ---: |",
     "| Mode | " + mode($dry) + " |",
     "| Policies processed | " + (($all | map(.policy // "") | unique | length) | tostring) + " |",
     "| Targets reconciled | " + ($all | length | tostring) + " |",
     "| Targets with changes | " + ($all | count_changed | tostring) + " |",
     "| Failed actions | " + ($all | count_failed | tostring) + " |",
     ""]

    # ---- Totals ----
    + ["### Actions summary", "", "| Outcome | Count |", "| --- | ---: |"]
    + ( $all
        | group_by(.action)
        | sort_by(length) | reverse
        | map("| " + outcome({action: .[0].action, dry_run: $dry}) + " | " + (length | tostring) + " |") )
    + [""]

      # ---- Scope rollup ----
      + ["### Targets by scope", "",
         "| Scope | Targets | Changed | Failed | Actions |", "| --- | ---: | ---: | ---: | --- |"]
      + ( $all
        | sort_by(.entity_type // "")
        | group_by(.entity_type // "")
        | map(. as $rows | .[0] as $scope |
          "| " + code_or_dash($scope.entity_type) + " | "
          + ($rows | length | tostring) + " | "
          + ($rows | count_changed | tostring) + " | "
          + ($rows | count_failed | tostring) + " | "
          + ($rows | action_counts($dry)) + " |" ) )
      + [""]

      # ---- Attention ----
      + ( ($all | map(select(is_failed))) as $failed
        | if ($failed | length) > 0 then
          ["### Needs attention", "",
           "| Policy | Target | Action | Amount |", "| --- | --- | --- | --- |"]
          + ($failed
             | sort_by([(.policy // ""), (.entity_type // ""), (.entity // "")])
             | map("| `" + policy_name(.) + "` | " + target(.) + " | " + outcome(.) + " | " + amt(.) + " |"))
          + [""]
        else [] end )

      # ---- Policy rollup ----
      + ["### Actions by policy", "",
         "| Policy | Type | SKU | Scope(s) | Group/team | Targets | Changed | Failed | Actions |", "| --- | --- | --- | --- | --- | ---: | ---: | ---: | --- |"]
      + ( $all
        | sort_by(.policy // "")
        | group_by(.policy // "")
        | map(. as $rows | .[0] as $policy |
          "| `" + policy_name($policy) + "` | "
          + code_or_dash($policy.type) + " | "
          + code_or_dash($policy.sku) + " | "
          + ($rows | scope_summary) + " | "
          + ($rows | groups_summary) + " | "
          + ($rows | length | tostring) + " | "
          + ($rows | count_changed | tostring) + " | "
          + ($rows | count_failed | tostring) + " | "
          + ($rows | action_counts($dry)) + " |" ) )
      + [""]

      # ---- Policy details ----
      + ["### Policy details"]
      + ( $all
        | sort_by([(.policy // ""), (.entity_type // ""), (.entity // "")])
        | group_by(.policy // "")
        | map(. as $rows | .[0] as $policy |
          ["", "#### `" + policy_name($policy) + "`", "",
           "- **Type:** " + code_or_dash($policy.type),
           "- **SKU:** " + code_or_dash($policy.sku),
           "- **Scope(s):** " + ($rows | scope_summary),
           "- **Group/team:** " + ($rows | groups_summary),
           "- **Actions:** " + ($rows | action_counts($dry)),
           "",
           "| Target | Scope | Action | Old amount | New amount | Amount |", "| --- | --- | --- | ---: | ---: | --- |"]
          + ($rows
             | sort_by([(.entity_type // ""), (.entity // "")])
             | map("| " + target(.) + " | " + code_or_dash(.entity_type) + " | " + outcome(.) + " | " + money(.old_amount) + " | " + money(.new_amount) + " | " + amt(.) + " |")) )
        | add )
  )
| flatten
| join("\n")
