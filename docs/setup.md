# Setup

## Prerequisites

- GitHub repository with Actions enabled.
- A token with enterprise/admin permissions needed for Copilot FinOps operations.
- `COPILOT_FINOPS_TOKEN` repository secret configured (recommended).

If `COPILOT_FINOPS_TOKEN` is not set, workflows fall back to `GITHUB_TOKEN` where access permits.

## Configure files

1. Copy and adapt:
   - `config/teams-to-cost-centers.example.yml`
   - `config/user-budget-policies.example.yml`
2. Commit config changes through pull requests.
3. Run audit workflow first, then run mutating workflows with `dry_run=true`.
