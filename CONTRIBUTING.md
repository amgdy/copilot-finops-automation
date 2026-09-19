# Contributing

Thanks for improving this project.

## Before opening a pull request

- Do not include real enterprise slugs, team slugs, cost center names, user logins, generated reports, logs, or tokens.
- Keep examples generic and use placeholder names such as `your-enterprise`, `acme`, and `platform-engineering`.
- Keep `apply` defaulted to `dry_run=true` in workflows.
- Avoid behavior changes that create, update, or delete live billing objects without a dry-run path.
- When config, schema, workflow, validation, or terminology requirements change, update `AGENTS.md` and `.github/skills/copilot-finops-config/` in the same pull request.

## Validation

Run the checks for what you changed. For most changes, start with:

```bash
npm test
node bin/copilot-finops.js validate config/copilot-finops.yml
node bin/copilot-finops.js validate config/copilot-finops.example.yml
git diff --check
```

When you change a config field, constraint, enum, default, scope rule, or the schema, keep the whole chain consistent in the same change:

1. Update `schemas/v3/copilot-finops.schema.json`.
2. Update the semantic layer in `src/config/validate.js` if the rule is cardinality/uniqueness/live (not pure shape) — see the schema ↔ validator boundary in `AGENTS.md`.
3. Append a **valid** case and an **invalid** case to `tests/cases/v3/copilot-finops.yml` (the invalid case must assert on its error).
4. Rebuild the bundle and regenerate the docs, and commit both:

   ```bash
   npm run build         # refresh dist/
   npm run build:site    # refresh site/app.bundle.js
   npm run docs:schema   # refresh docs/config-schema.md
   ```

5. Keep `npm test` green.

CI (`.github/workflows/ci.yml`) runs `npm test` and fails if the committed `dist/`, `site/app.bundle.js`, or `docs/config-schema.md` is stale, so rebuild and regenerate before pushing.

If available, also lint the workflows:

```bash
actionlint .github/workflows/*.yml
```

## Pull request notes

In the pull request description, include:

- What changed.
- Whether it affects `validate` (read-only) or `apply` (mutating).
- What validation you ran.
