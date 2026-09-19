# Agent Guidance

This repository automates GitHub Enterprise Copilot AI-credit **budget** governance as a self-contained Node.js GitHub Action. Treat changes as governance-sensitive: they can affect billing budgets, cost centers, and workflow permissions.

## Core Principles

- Config-as-code is the only production path: budgets live in one reviewed YAML file (`config/copilot-finops.yml`, `version: 3`).
- The `apply` operation is dry-run by default. Manual workflow runs preview; only the scheduled run (and an explicit `dry_run=false`) writes.
- The enterprise slug is an **action/CLI input** (`COPILOT_FINOPS_ENTERPRISE` variable), never a config field. Keep real slugs out of tracked config.
- Preserve local/private config safety: files matching `config/*.local.yml` must remain gitignored.
- Do not commit tokens, generated reports, logs, private enterprise names, user logins, or private cost center data unless the user explicitly confirms they are safe to publish.
- Use AI-credit terminology only. Do not use deprecated request-based Copilot billing terms.

## Architecture

A Node.js action (`action.yml` + committed `dist/index.js`, `runs.using: node24`). Source is ESM under `src/` (`"type": "module"`, Node 24+).

- Deps: `@actions/core`, `@actions/github` (Octokit), `js-yaml`, `ajv` + `ajv-formats`; bundler `@vercel/ncc` (dev only).
- Structure: `src/config/{load,validate}.js`, `src/apply-engine.js`, `src/github/{client,costcenters}.js`, `src/report.js`, `src/config-path.js`, `src/operations.js`, `src/migrate.js`, `src/index.js`; CLI `bin/copilot-finops.js`; schema-docs generator `bin/gen-schema-docs.js`.
- Config Studio: browser source under `site/`; `npm run build:site` bundles `js-yaml`, the v3 schema, and the shared config validator into committed `site/app.bundle.js` for GitHub Pages.
- Schema: `schemas/v3/copilot-finops.schema.json` (JSON Schema draft 2020-12). Generated field reference: `docs/config-schema.md` (via `npm run docs:schema`).
- Tests: `tests/*.test.js` (`node:test`), config contract cases in `tests/cases/v3/copilot-finops.yml`, fake client in `tests/helpers/`.

## Operations

The action has two operations (input `operation`):

- `apply` — apply desired budget state. `dry-run` (default) previews the CREATE/UPDATE/NO CHANGE drift (this preview is the audit); live mode writes. Requires the `enterprise` input and a token with `admin:enterprise`. Never deletes budgets.
- `validate` — config lint only. No token, no network.

`apply` writes every budget on the **enterprise** billing endpoint (the 2026-03-10 API accepts every `budget_scope` there, including `organization` — confirmed live). `team` budgets are applied through a cost center (found, or created and the team assigned); an `organization` budget is written directly. The engine never enumerates team or organization members.

## Config Rules

- `config/copilot-finops.yml` is the tracked v3 config; `config/copilot-finops.example.yml` is the public-safe worked example (covers every scope); `config/copilot-finops.local.yml` is the gitignored private form. All declare `version: 3`.
- The document is one object with an optional `budgets:` list. An omitted/empty list is a valid no-op. There is **no** enterprise field.
- Each budget requires `scope` (one of `all_users`, `user`, `cost_center`, `team`, `organization`, `enterprise`) and `amount` (integer USD ≥ 0).
- Identity fields are per-scope: `users` (required for `user`), `cost_center` (for `cost_center`), `team` (for `team`), `organization` (for `organization`); each is forbidden on the other scopes. `all_users`/`enterprise` take no identity field.
- `metered_credits_only` (boolean, default false) is valid on `cost_center`/`team`/`organization`. `true` = the group's collective metered cap; `false` = a per-user pool+metered cap.
- `scope: organization` is always a **direct** collective metered cap on the enterprise endpoint (like `enterprise`, scoped to one org): no cost center, no member enumeration. Because a `multi_user_cost_center` budget rejects an Org resource, the per-user path is impossible via a cost center, so the per-member org path (`metered_credits_only: false`) is **not yet supported** — gated in the semantic validator, NOT the schema (which allows the boolean shape). Use `metered_credits_only: true` (or omit it); to cap specific org users per-member, put them in an enterprise team and budget it with `scope: team`.
- `enforce` (boolean, default true) is only valid on collective metered budgets: `scope: enterprise` or `organization`, or `cost_center`/`team` with `metered_credits_only: true`. Pool/per-user budgets (`all_users`, `user`, and default `cost_center`/`team`) are always hard-stop and forbid `enforce`.
- `allow_shared_cost_center` (boolean, default false) is only valid on `team`. Default: a resolved cost center that also holds other resources is skipped and reported; `true` budgets it anyway.
- `alerts` is an optional list of logins; a non-empty list enables alerting.
- Uniqueness (semantic layer): at most one `all_users`, at most one `enterprise`, at most one `organization` budget per org, and at most one budget per (`cost_center` + `metered_credits_only`). `all_users` is optional, not required.
- `scope: cost_center` targets an **existing** cost center (resolved by name). To auto-create one, use `scope: team`. A `scope: organization` budget is written directly (no cost center).
- Do not add a product SKU or budget type — the engine defaults to `ai_credits` (BundlePricing). Do not add an `api:`/endpoint field or an enterprise field; the schema rejects unknown keys.

## Schema / validator boundary

Keep the boundary intact when changing rules:

- The **v3 schema** encodes shape, types, enums (`oneOf` + `const` + `title` + `description`), typo protection (`additionalProperties: false`), per-scope required/forbidden fields, and the `metered_credits_only` → `enforce` gating. Annotate every property with `title`/`description`/`examples`.
- The **semantic layer** (`src/config/validate.js`) owns the friendly messages and the cardinality/uniqueness rules above.
- The **apply engine** (`src/apply-engine.js`) owns the live rules: cost center resolution, finding/creating cost centers, and value defaulting (`enforce` → true, `alerts` → []).

A JSON Schema describes one document's shape but cannot read live GitHub state, so live rules never go in the schema.

## Tests

- `npm test` runs the whole `node:test` suite. It must stay green.
- Config contract cases live in `tests/cases/v3/copilot-finops.yml`: each case has `name`, `valid` (`true` must pass, `false` must be rejected), and `config`; invalid cases assert on the expected error.
- When you change a config field, constraint, enum, default, or scope rule: update `schemas/v3/copilot-finops.schema.json`, update `src/config/validate.js` if the rule is semantic (cardinality/uniqueness), add a **valid** and an **invalid** case, regenerate the docs and bundle, and keep `npm test` green.

## Workflow Rules

- `.github/workflows/finops-validate.yml` runs `validate` on PRs touching config/schema/action (token-free).
- `.github/workflows/finops-apply.yml` runs `apply`: manual dispatch (dry-run by default) + weekly schedule (live). The enterprise slug comes from the `COPILOT_FINOPS_ENTERPRISE` variable and the token from the `COPILOT_FINOPS_TOKEN` secret — neither is a config field. The workflow exposes `log_level` and maps it to the action's `log-level` input (`info` by default; `debug` adds resolution, matching, payload, request, retry, and pagination diagnostics). The job summary always contains the full report.
- `.github/workflows/ci.yml` runs `npm test` and fails if the committed `dist/`, `site/app.bundle.js`, or `docs/config-schema.md` is stale.
- Keep workflow YAML thin: the logic lives in the action (`src/`), not in shell.
- After changing anything under `src/`, rebuild the bundle (`npm run build`) and **commit `dist/`**. After changing the schema, regenerate (`npm run docs:schema`) and **commit `docs/config-schema.md`**.
- After changing the Studio, schema, or config validator, rebuild the browser bundle (`npm run build:site`) and **commit `site/app.bundle.js`**.

## Requirement Changes Must Update The Skill

Whenever requirements change for any of these areas, update the Copilot skill in `.github/skills/copilot-finops-config/` in the same change:

- config file name or structure
- the schema (`schemas/v3/`) or the `version` field
- budget fields, defaults, scopes, or the metered/enforce gating
- cost center resolution or the shared-cost-center behavior
- workflow inputs or behavior
- validation or local run commands
- public/private data safety guidance
- billing terminology or API behavior

At minimum, check and update:

- `.github/skills/copilot-finops-config/SKILL.md`
- `.github/skills/copilot-finops-config/references/interview.md`
- `.github/skills/copilot-finops-config/references/budgets.md`
- `.github/skills/copilot-finops-config/references/cost-centers.md`
- `.github/skills/copilot-finops-config/references/validation.md`

## Validation

Run after changes:

```bash
npm test
npm run build         # rebuild dist/ — commit it
npm run build:site    # rebuild the Config Studio browser bundle — commit it
npm run docs:schema   # regenerate docs/config-schema.md — commit it
node bin/copilot-finops.js validate config/copilot-finops.yml
node bin/copilot-finops.js validate config/copilot-finops.example.yml
git status --short    # expect no diff from build/docs:schema
git diff --check
```

If available, also run:

```bash
actionlint .github/workflows/*.yml
```

## Documentation Expectations

When changing behavior, update the relevant docs in the same change:

- `README.md`
- `docs/workflows.md`
- `docs/setup.md`
- `docs/api-reference.md`
- `docs/config-schema.md` (generated — regenerate, do not hand-edit)
- `docs/troubleshooting.md`
- `docs/permissions.md` when permissions change
- `docs/public-release.md` when public-safety guidance changes
- `schemas/README.md` when the schema or its role changes

Keep docs, the worked example, and the skill consistent with the schema and the engine.
