# Renders a per-member Markdown summary from the cost-center membership records
# emitted by scripts/sync-cost-center-members.sh (SYNC_SUMMARY_FILE, JSON Lines).
# Usage: jq -rs -f sync-summary.jq sync-summary.jsonl
#
# Each input record looks like:
#   {mapping, team, cost_center, entity, action, dry_run}
# action is one of: add | remove

def verb(r):
  if r.dry_run then
    (if r.action == "add" then "Add" else "Remove" end)
  else
    (if r.action == "add" then "Added" else "Removed" end)
  end;

def mode($dry): if $dry then "dry-run (preview only)" else "live (changes applied)" end;

def label_or_dash(x): if (x // "") == "" then "—" else "`" + (x | tostring) + "`" end;
def count_action($action): map(select(.action == $action)) | length;
def add_label($dry): if $dry then "to add" else "added" end;
def remove_label($dry): if $dry then "to remove" else "removed" end;

. as $all
| ($all[0].dry_run) as $dry
| (
   # ---- Run overview ----
   ["### Run overview", "", "| Metric | Value |", "| --- | ---: |",
    "| Mode | " + mode($dry) + " |",
    "| Mappings with changes | " + (($all | map(.mapping) | unique | length) | tostring) + " |",
    "| Membership actions | " + ($all | length | tostring) + " |",
    "| Users " + add_label($dry) + " | " + (($all | count_action("add")) | tostring) + " |",
    "| Users " + remove_label($dry) + " | " + (($all | count_action("remove")) | tostring) + " |",
     ""]

   # ---- Mapping rollup ----
   + ["### Changes by mapping", "",
     "| Mapping | Team | Cost center | Add | Remove | Total |", "| --- | --- | --- | ---: | ---: | ---: |"]
   + ( $all
      | sort_by(.mapping // "")
      | group_by(.mapping // "")
      | map(. as $rows | (.[0]) as $h |
       "| " + label_or_dash($h.mapping) + " | "
       + label_or_dash($h.team) + " | "
       + label_or_dash($h.cost_center) + " | "
       + (($rows | count_action("add")) | tostring) + " | "
       + (($rows | count_action("remove")) | tostring) + " | "
       + ($rows | length | tostring) + " |" ) )
   + [""]

   # ---- Removals deserve a separate review section ----
   + ( ($all | map(select(.action == "remove"))) as $removals
    | if ($removals | length) > 0 then
      ["### Removal review", "",
      "| Mapping | User | Action |", "| --- | --- | --- |"]
      + ($removals
        | sort_by([(.mapping // ""), (.entity // "")])
        | map("| " + label_or_dash(.mapping) + " | " + label_or_dash(.entity) + " | " + verb(.) + " |"))
      + [""]
    else [] end )

    # ---- Per mapping (team -> cost center) ----
    + ( $all
        | group_by(.mapping)
        | map(
            (.[0]) as $h
            | ["### Mapping `" + $h.mapping + "`", "",
               "- **Team:** `" + ($h.team // "—") + "`",
               "- **Cost center:** `" + ($h.cost_center // "—") + "`",
          "- **Users " + add_label($dry) + ":** " + ((. | count_action("add")) | tostring),
          "- **Users " + remove_label($dry) + ":** " + ((. | count_action("remove")) | tostring),
               "",
               "| User | Action |", "| --- | --- |"]
            + (sort_by(.entity) | map("| `" + .entity + "` | " + verb(.) + " |"))
            + [""] )
        | add )
  )
| flatten
| join("\n")
