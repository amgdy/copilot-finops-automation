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

Ask when generating `ai_credit_spend_policies`.

General:

> Any non-empty budget set must include exactly one all-users default (required). An enterprise cap is optional but limited to one. If the user wants budgets at all, always generate the all-users default, plus whatever else they ask for.

- An all-users default user budget is **required** when defining budgets (exactly one). Confirm its amount.
- An enterprise metered-spend cap is **optional** (at most one). Offer it and confirm its amount if wanted.
- Do you want to budget one or more specific users (`scope: user`)? If yes, which logins and amount?
- Do you want one or more cost center metered-spend caps?
- Do you want team-based budgets?
- Do you need alerts? If yes, which GitHub logins should receive alerts?

All-users budget:

- Amount in whole USD.
- Confirm the budget hard-stops (`stop_at_limit` omitted or `true`) because user-level budgets always hard-stop.

User budget (`scope: user`):

- The GitHub login(s) to budget (`users:` — one or more).
- Amount in whole USD (applied to each listed login).
- Always hard-stops (user-level budgets cannot alert-only).

Enterprise budget:

- Amount in whole USD.
- Should it hard-stop at the cap (`stop_at_limit: true`, the default) or alert-only (`stop_at_limit: false`)?
- Alert recipients, if any (`alert_admins`).

Cost center budget:

- Cost center display name.
- Amount in whole USD.
- Hard-stop or alert-only.
- Alert recipients, if any.

Team budget:

- Is the source an org team or enterprise team? (org team -> set `organization:`; enterprise team -> omit it, the enterprise is inferred.)
- Org login, if org team.
- Enterprise slug, if enterprise team and different from top-level.
- Bare team slug(s) (`teams:` — one or more; the policy is applied to each).
- Which credit scope?
  - `pool_then_metered`: per-member user budgets (members unioned + deduped across the listed teams); covers shared pool + metered usage; always hard-stop.
  - `metered_only`: one cost center budget per listed team; covers collective metered usage after the shared pool; hard-stop optional.
- For `metered_only`, ask whether to use an existing `cost_center:` (single team only) or let the script derive/create one per team, and whether to prune members who left the team (`remove_extra_members`).
- Amount in whole USD.

Organization budget:

- Which organization login (`organization:`)?
- Which credit scope?
  - `pool_then_metered`: one user budget per org member; always hard-stop.
  - `metered_only`: one org-scope budget for the org's collective metered usage; hard-stop optional.
- Amount in whole USD.
- Note: if org members also receive a team total-spend budget, the last policy in the file wins for any shared login (flagged in the summary).

## Cost Center Member Sync Questions

Ask when generating `team_cost_center_mappings`.

First confirm the approach, because user-level sync is now opt-in:

- Can the enterprise team be assigned to the cost center **natively** ([changelog](https://github.blog/changelog/2026-06-25-assign-enterprise-teams-to-cost-centers/), [docs](https://docs.github.com/en/enterprise-cloud@latest/billing/tutorials/control-costs-at-scale))? Recommend that — the sync skips every mapping by default and defers to native assignment.
- If native assignment is not usable, set `force_user_sync: true` on the mapping (or run the workflow with the `force_user_sync` input) to run the legacy user-level sync as a bridge.

For each mapping:

- Source type: org team (set `organization:`) or enterprise team (omit it).
- Org login, if org team.
- Enterprise slug, if enterprise team and different from top-level.
- Bare team slug.
- Destination cost center name (`cost_center:`).
- Run the legacy user-level sync for this mapping (`force_user_sync: true`)? Default is to skip and defer to native assignment.
- Should sync remove extra users not in the team (`remove_extra_members`)? Only applies when `force_user_sync` is true.
  - `true`: strict reconciliation.
  - `false` or omitted: additive only, preserves manual members.

## Safety Questions

Ask before writing or suggesting production config:

- Should the config be written to a tracked file or an ignored `.local.yml` file?
- Are enterprise/team/cost-center names safe to commit?
- Should the workflow be run in dry-run first?

Always recommend dry-run before live apply/sync.
