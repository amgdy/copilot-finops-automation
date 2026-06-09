# Contributing

Thanks for improving this project.

## Before opening a pull request

- Do not include real enterprise slugs, team slugs, cost center names, user logins, generated reports, logs, JSONL summaries, or tokens.
- Keep examples generic and use placeholder names such as `your-enterprise`, `your-org`, and `platform-engineering`.
- Keep mutating workflows defaulted to `dry_run=true`.
- Avoid behavior changes that create, update, or delete live billing objects without an explicit dry-run path.
- When config, workflow, issue-template, label, validation, or terminology requirements change, update `AGENTS.md` and `.github/skills/copilot-finops-config/` in the same pull request.

## Validation

Run the focused checks for the files you changed. For most changes, start with:

```bash
bash -n scripts/*.sh
scripts/validate-config.sh config/cost-center-members.example.yml teams
scripts/validate-config.sh config/budget-policies.example.yml budgets
awk 'NR==1 {next} /^---$/ {exit} {print}' .github/skills/copilot-finops-config/SKILL.md | yq eval '.' >/dev/null
git diff --check
```

If available, also run:

```bash
shellcheck scripts/*.sh
actionlint .github/workflows/*.yml
```

## Pull request notes

In the pull request description, include:

- What changed.
- Whether it affects a read-only or mutating workflow.
- What validation you ran.
