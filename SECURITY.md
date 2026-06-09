# Security Policy

## Supported versions

This project is distributed as source automation. Security fixes are provided on the default branch unless maintainers publish release branches or tags with separate support windows.

## Security best practices for this repository

- Store admin tokens only in repository or organization secrets.
- Prefer `COPILOT_FINOPS_TOKEN` for automation requiring enterprise-level access.
- Keep mutating workflows defaulted to dry-run.
- Require pull request reviews for workflow and config changes.
- Use branch protections and CODEOWNERS for governance-sensitive paths.
- Do not publish live config files, generated reports, logs, JSONL summaries, or screenshots that expose enterprise names, team membership, cost center names, user logins, or budget amounts.
- Rotate any token that was committed, pasted into an issue, uploaded as an artifact, or printed in a workflow log.

## Reporting vulnerabilities

Please use GitHub Security Advisories or private contact channels configured by repository maintainers. Do not open a public issue that includes tokens, private enterprise identifiers, user lists, audit reports, or other sensitive billing data.

If a secret is exposed, revoke or rotate it before filing the report.
