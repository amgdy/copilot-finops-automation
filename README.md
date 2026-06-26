# 💰 Copilot FinOps Automation

Govern GitHub Copilot spend as code. Manage AI-credit budgets, cost centers, and team membership for your GitHub Enterprise from one version-controlled config file — validated before it runs, previewed as a dry run, and applied by GitHub Actions.

> ⚠️ **Public repository:** this repo ships with placeholder values only. Keep real enterprise slugs, team names, cost center names, user logins, budget amounts, reports, logs, and tokens out of public branches — put them in a private fork or private repository.

## ✨ Why use it

- 📝 **Config as code** — budgets and cost center membership live in one reviewed YAML file, so every change ships through a pull request with full history.
- 🛡️ **Safe by default** — manual runs preview as a dry run, and config is validated against a JSON Schema before any API call reaches your enterprise.
- 🔄 **Stays in sync** — scheduled workflows reconcile live budgets and cost center membership with your config, idempotently.
- 👀 **Clear visibility** — an audit workflow reports your config against current GitHub state as markdown, and every run writes a detailed job summary.
- 🔌 **Built on GitHub's GA billing APIs** — uses the Budget and usage management (enhanced billing) endpoints.

## 🆕 What's new in v2

v2 makes config simpler to author and safer to ship:

- 📦 **One merged config file.** `config/copilot-finops.yml` replaces the two v1 split files. It holds budgets (`ai_credit_spend_policies`) and team → cost center syncs (`team_cost_center_mappings`); both lists are optional, so you write only what you need.
- ✅ **Schema-validated config.** The config you author is checked against a versioned JSON Schema (`schemas/v2/`) for structure, types, allowed values, and per-scope rules — live in your editor with the Red Hat **YAML** extension, and again in CI, before any budget is created. Run the same check yourself with `scripts/validate-config.sh config/copilot-finops.yml all`.
- 🤖 **AI-assisted authoring.** The included [Copilot FinOps skill](.github/skills/copilot-finops-config/SKILL.md) helps you write and validate config interactively: describe the budgets and team mappings you want, and Copilot produces a valid file grounded in the schema.

v1's split files (`config/budget-policies.yml`, `config/cost-center-members.yml`) are frozen but still supported. Convert an existing pair with `scripts/migrate-v1-to-v2.sh`. See [docs/setup.md](docs/setup.md) and [schemas/README.md](schemas/README.md).

## 💳 How Copilot AI-credit billing works

Copilot usage is metered in **AI credits**. Every license includes an allotment of AI credits pooled across the enterprise: while the pool has credits, requests are served from it at no extra cost, and once it is exhausted, additional usage is metered per AI credit and capped by the budgets you set. Code completions and next edit suggestions are included in every plan and don't consume AI credits.

Four budget controls work together, each governing a layer of spend:

| Control | What it governs |
| --- | --- |
| All-users default budget | Each licensed user's total AI-credit usage (pool + metered) |
| Individual user budget | A specific user's total usage (overrides the all-users default) |
| Cost center budget | A cost center's metered usage after the pool is exhausted |
| Enterprise budget | The enterprise's total metered usage after the pool is exhausted |

For the full level tree and billing-flow diagrams, see [docs/workflows.md](docs/workflows.md).

## ⚙️ How it works

Three operations, each a GitHub Actions workflow you can run manually or on a schedule:

| Operation | Workflow | What it does |
| --- | --- | --- |
| 🔍 **Audit** | `audit-copilot-budget-state.yml` | Compares your config to live GitHub state and writes a markdown report. |
| 💵 **Apply budgets** | `apply-user-budgets.yml` | Creates or updates AI-credit budgets to match your config (idempotent; never deletes). |
| 👥 **Sync members** | `sync-cost-center-members.yml` | Bridges cost center membership from current team membership. Skips every mapping by default in favor of [native enterprise-team assignment](https://github.blog/changelog/2026-06-25-assign-enterprise-teams-to-cost-centers/); set `force_user_sync` to run the legacy user-level sync. |
| 🚀 **Apply both (v2)** | `apply-copilot-finops.yml` | Validates the merged config once, then applies budgets and syncs members in parallel. |

Manual runs start in `dry_run=true` and print exactly what would change. Scheduled runs reconcile reviewed file-based config live. See [docs/workflows.md](docs/workflows.md) for triggers, inputs, and diagrams.

## 🚀 Quick start

1. 📥 **Use this repository** as a template, or fork it into a **private** repository for real config.
2. 🔑 **Create a token** with the scopes in [docs/permissions.md](docs/permissions.md) and save it as the repository secret `COPILOT_FINOPS_TOKEN`. ([Create the PAT](https://github.com/settings/tokens/new?description=Copilot%20FinOps%20Automation&scopes=admin%3Aenterprise,read%3Aenterprise,read%3Aorg).)
3. 📝 **Create your config** from the worked example:

   ```bash
   cp config/copilot-finops.example.yml config/copilot-finops.yml
   ```

   Set `enterprise_slug`, then add the budgets and team mappings you need. Let Copilot help — open the file and ask it to author config, guided by the [Copilot FinOps skill](.github/skills/copilot-finops-config/SKILL.md).
4. ✅ **Validate** before you run anything:

   ```bash
   scripts/validate-config.sh config/copilot-finops.yml all
   ```

   Install `check-jsonschema` (`pipx install check-jsonschema`) for the full schema check, and add the Red Hat **YAML** extension for live validation as you edit.
5. 👀 **Preview, then apply.** Run the audit workflow, then run apply manually with `dry_run=true` and review the job summary. Switch to `dry_run=false` — or enable the schedules — only once the preview looks right.

The smallest valid config is a safe no-op:

```yaml
version: 2
enterprise_slug: your-enterprise
```

Add `ai_credit_spend_policies` to set budgets and `team_cost_center_mappings` to sync members. The worked example in [`config/copilot-finops.example.yml`](config/copilot-finops.example.yml) covers every scope; the [Copilot FinOps skill](.github/skills/copilot-finops-config/SKILL.md) and [schemas/README.md](schemas/README.md) are the authoritative field-by-field reference.

## 📋 Requirements

- A GitHub repository with Actions enabled and the `COPILOT_FINOPS_TOKEN` secret set.
- For local validation and runs: `gh`, `jq`, `yq`, Bash 4+, and optionally `check-jsonschema`. (GitHub-hosted runners already include these; the workflows install `check-jsonschema` for you.)

## 📚 Documentation

| Doc | Contents |
| --- | --- |
| [docs/setup.md](docs/setup.md) | Token, prerequisites, configuring files, naming conventions. |
| [docs/workflows.md](docs/workflows.md) | Workflow triggers, inputs, and billing-flow and reconciliation diagrams. |
| [docs/permissions.md](docs/permissions.md) | Token scopes per operation. |
| [docs/api-reference.md](docs/api-reference.md) | The exact GA billing API calls and request bodies. |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Common validation, permission, and API errors. |
| [docs/public-release.md](docs/public-release.md) | Checklist before publishing a fork or template. |
| [schemas/README.md](schemas/README.md) | Config field reference, schema validation, and the v1 ↔ v2 map. |
| [Copilot FinOps skill](.github/skills/copilot-finops-config/SKILL.md) | The Copilot skill that authors and validates config. |

## 🔒 Safety

- 🧪 Manual mutating runs default to `dry_run=true`; keep schedules disabled until your config and token are ready.
- 👮 Protect `.github/workflows/**` and `config/**` with CODEOWNERS and required reviews on `main`.
- 🔐 Use a private repository for live enterprise configuration, and review [docs/public-release.md](docs/public-release.md) before making any copy public.
