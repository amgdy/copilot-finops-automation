# Security Policy

## Security best practices for this repository

- Store admin tokens only in repository or organization secrets.
- Prefer `COPILOT_FINOPS_TOKEN` for automation requiring enterprise-level access.
- Keep mutating workflows defaulted to dry-run.
- Require pull request reviews for workflow and config changes.
- Use branch protections and CODEOWNERS for governance-sensitive paths.

## Reporting vulnerabilities

Please use GitHub Security Advisories or private contact channels configured by repository maintainers.
