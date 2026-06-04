# Permissions

Use a dedicated token in `COPILOT_FINOPS_TOKEN` for enterprise Copilot billing operations.

Typical required scopes/permissions depend on your enterprise setup and API surface, but usually include:

- Enterprise billing/cost center management permissions.
- Organization read access for source team membership.
- Copilot policy/budget management permissions where available.

## Safety recommendations

- Protect `config/**` and `.github/workflows/**` with required reviews and CODEOWNERS.
- Keep mutating workflows defaulted to `dry_run=true`.
- Use branch protection on `main`.
