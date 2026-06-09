# Interview Checklist

Use this checklist to gather only the missing information. Do not ask everything if the user already provided enough context.

## First Questions

Ask these first:

1. What output do you want?
   - budget policies config
   - cost center member sync config
   - both
   - YAML for an issue-form request
2. Is this for a public repo config, private repo config, or ignored local config?
3. What is the GitHub Enterprise slug?
4. Should this be a reviewed production config file or a test/request config?

## Budget Policy Questions

Ask when generating `budget_policies`.

General:

- Do you want a universal default user budget?
- Do you want an enterprise metered-spend cap?
- Do you want one or more cost center metered-spend caps?
- Do you want team-based budgets?
- Do you need alerts? If yes, which GitHub logins should receive alerts?

Universal budget:

- Amount in whole USD.
- Confirm `prevent_further_usage: true` because user-level budgets always hard-stop.

Enterprise budget:

- Amount in whole USD.
- Should it hard-stop at the cap (`prevent_further_usage: true`) or alert-only (`false`)?
- Alert recipients, if any.

Cost center budget:

- Cost center display name.
- Amount in whole USD.
- Hard-stop or alert-only.
- Alert recipients, if any.

Team budget:

- Is the source an org team or enterprise team?
- Org name, if org team.
- Enterprise slug, if enterprise team and different from top-level.
- Bare team slug.
- Which coverage mode?
  - `total_spend`: per-member user budgets; caps shared pool + metered usage; always hard-stop.
  - `additional_spend`: one cost center budget; caps collective metered usage after the shared pool; hard-stop optional.
- For `additional_spend`, ask whether to use an existing `target.cost_center` or let the script derive/create one.
- Amount in whole USD.

## Cost Center Member Sync Questions

Ask when generating `mappings`.

For each mapping:

- Source type: org team or enterprise team.
- Org name, if org team.
- Enterprise slug, if enterprise team and different from top-level.
- Bare team slug.
- Target cost center display name.
- Should sync remove extra users not in the team?
  - `true`: strict reconciliation.
  - `false` or omitted: additive only, preserves manual members.
- Batch size if user cares; otherwise omit or use 50.

## Safety Questions

Ask before writing or suggesting production config:

- Should the config be written to a tracked file or an ignored `.local.yml` file?
- Are enterprise/team/cost-center names safe to commit?
- Should the workflow be run in dry-run first?

Always recommend dry-run before live apply/sync.
