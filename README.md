# 💰 Copilot FinOps Automation

Govern GitHub Copilot spend as code. Apply AI-credit budgets for your GitHub Enterprise from one version-controlled config file — validated before it runs, previewed as a dry run, and applied by the reusable **Copilot FinOps v3** GitHub Action.

## ✨ Why use it

- 📝 **Config as code** — every AI-credit budget lives in one reviewed YAML file, so each change ships through a pull request with full history.
- 🛡️ **Safe by default** — the `apply` operation previews as a dry run (that preview *is* the audit), and config is validated against a JSON Schema before any API call reaches your enterprise.
- 🔄 **Idempotent apply** — a scheduled workflow applies desired budget state from your config: it creates and updates, and never deletes.
- 🔒 **Secrets stay out of config** — the enterprise slug is an action input (a repo/org Variable), never a tracked config field.
- 🔌 **Reusable v3 action** — load `amgdy/copilot-finops-automation@v3` from any enterprise config repo. No need to fork this whole repo just to run the engine.
- ⚙️ **Zero install** — a self-contained Node.js action (`node24`, committed `dist/`). No `gh`/`jq`/`yq`/`pipx` on the runner.
- 🖥️ **Config Studio** — a browser-only visual editor, hosted on GitHub Pages, for building, reviewing, and downloading valid v3 configuration.

## 🪄 Config Studio

Use the **Config Studio** GitHub Pages site to start from an empty v3 configuration or open an existing YAML file. It provides guided policy forms, local validation, a policy hierarchy, and a downloadable `copilot-finops.yml`. The editor runs entirely in the browser: it does not require a token or enterprise slug, and it does not upload config data.

The deployed browser bundle includes `js-yaml`, the v3 JSON Schema, and the same validator used by the CLI. Rebuild and commit it with `npm run build:site` after changing the studio, schema, or config validator.

The coverage diagram uses an enterprise house: an enterprise-wide roof, organization wings, cost-center vaults, team workspaces, personal desks, and an all-user foundation. Select any budget to open it in the editor. Per-user and collective caps remain distinct; only identical explicit targets are grouped, since the config does not define group membership. Overlapping caps are not added together. Icons ship in the browser bundle, with no external asset requests.

Amounts show exact USD values with a separate per-user or collective label. New policies animate into view, and edits briefly emphasize the updated cap; selecting a policy does not replay the animation. Offscreen effects wait until the policy is visible, and the diagram respects reduced-motion preferences.

A copyable GitHub Actions workflow follows the YAML preview. It runs manually with `dry-run: "true"`, reads `config/copilot-finops.yml`, and uses the `COPILOT_FINOPS_ENTERPRISE` variable and `COPILOT_FINOPS_TOKEN` secret. Configure both in the consuming repository; the token needs `admin:enterprise` for apply.

Enable **Settings → Pages → GitHub Actions** once for this repository. Subsequent updates to `site/` on `main` deploy automatically through [Deploy Config Studio](.github/workflows/deploy-pages.yml).

The Studio is an authoring aid, not an apply surface. Keep downloaded configurations under review, then run `node bin/copilot-finops.js validate config/copilot-finops.yml` (or the repository validation workflow) before a dry-run apply.

## ⚙️ How it works

The project ships as a **Node.js GitHub Action** with two operations:

| Operation | What it does | Token |
| --- | --- | --- |
| `validate` | Lints the config against the v3 JSON Schema and the semantic rules. No network. | none |
| `apply` | Applies AI-credit budgets to match config. `dry-run` (default) previews the drift; live mode writes. | `admin:enterprise` |

Two workflows wire those operations up:

| Workflow | Trigger | Operation |
| --- | --- | --- |
| [`finops-validate.yml`](.github/workflows/finops-validate.yml) | Pull requests that touch config/schema/action | `validate` (token-free) |
| [`finops-apply.yml`](.github/workflows/finops-apply.yml) | Manual (dry-run by default) + weekly schedule (live) | `apply` |

Budgets that target a **team** are applied through a cost center: the action finds the cost center that groups the team, or creates one and assigns the team to it. An **organization** budget is written directly (a collective metered cap). It never enumerates individual members — GitHub expands the cap across the members for you.

See [docs/workflows.md](docs/workflows.md) for triggers, inputs, and the reconciliation and billing-flow diagrams.

## 💳 How Copilot AI-credit billing works

Copilot usage is metered in **AI credits**. Every license includes an allotment of AI credits pooled across the enterprise: while the pool has credits, requests are served from it at no extra cost; once it is exhausted, additional usage is metered per AI credit and capped by the budgets you set. Code completions and next edit suggestions are included in every plan and don't consume AI credits.

Budgets work together, each governing a layer of spend:

| Budget scope | What it governs |
| --- | --- |
| `all_users` | Each licensed user's total AI-credit usage (pool + metered) |
| `user` | Specific users' total usage (overrides the all-users default) |
| `cost_center` | A cost center — per-member pool+metered, or the cost center's collective metered spend |
| `team` | A team, applied through its cost center (per-member, or collective metered) |
| `organization` | An org — a direct collective metered cap after the pool |
| `enterprise` | The enterprise's total metered usage after the pool |

For the full level tree and billing-flow diagrams, see [docs/workflows.md](docs/workflows.md).

## 🚀 Use The Hosted v3 Action

The simplest way to use this solution is to keep only your **config** and **workflows** in your enterprise repository, and load the reusable action from:

```yaml
uses: amgdy/copilot-finops-automation@v3
```

This is simpler than the older model where every enterprise had to fork the whole automation repo. The FinOps engine now lives in one reusable action, and each consuming repo only owns its reviewed config, secret, variable, and schedule.

In your enterprise config repo, add `config/copilot-finops.yml`:

```yaml
version: 3
budgets:
  - name: all-users-default
    scope: all_users
    amount: 30
```

Add a token secret and enterprise variable:

```text
COPILOT_FINOPS_TOKEN       # classic PAT with admin:enterprise
COPILOT_FINOPS_ENTERPRISE  # enterprise slug, for example your-enterprise
```

Then add two workflows to your enterprise repo — one that runs `validate` on pull requests, and one that runs `apply` on a schedule. Copy the ready-made **validate** and **apply** workflows from [docs/workflows.md](docs/workflows.md#reusable-v3-action); they preview by default (dry-run) and apply live only on the schedule.

Keep the schedule disabled, or keep `config/copilot-finops.yml` as a no-op (`version: 3`), until you are ready.

## 🚀 Quick start for this repo

1. 📥 **Use the hosted v3 action** from `amgdy/copilot-finops-automation@v3` in your enterprise config repo. Fork this repository only if you want to develop the engine itself.
2. 🔑 **Create a token** with `admin:enterprise` (see [docs/permissions.md](docs/permissions.md)) and save it as the repository secret `COPILOT_FINOPS_TOKEN`. ([Create the PAT](https://github.com/settings/tokens/new?description=Copilot%20FinOps%20Automation&scopes=admin%3Aenterprise).)
3. 🏷️ **Set your enterprise slug** as the repository (or org) **Variable** `COPILOT_FINOPS_ENTERPRISE`. It is deliberately *not* a config field.
4. 📝 **Author your config** from the worked example:

   ```bash
   cp config/copilot-finops.example.yml config/copilot-finops.yml
   ```

   Keep only the budgets you need. Let Copilot help — open the file and ask it to author config, guided by the [Copilot FinOps skill](.github/skills/copilot-finops-config/SKILL.md).
5. ✅ **Validate** before you run anything (no token needed):

   ```bash
   node bin/copilot-finops.js validate config/copilot-finops.yml
   ```

   Add the Red Hat **YAML** extension for live validation, autocomplete, and hover docs as you edit.
6. 👀 **Preview, then apply.** Run `finops-apply.yml` manually with `dry_run=true` and review the job summary (the dry-run *is* the audit). `log_level=info` is the default; use `log_level=debug` when you need budget-resolution, matching, payload, request, retry, or pagination detail. Switch to `dry_run=false` — or enable the schedule — only once the preview looks right.

The smallest valid config is a safe no-op:

```yaml
version: 3
```

Add `budgets:` to set caps. The worked example in [`config/copilot-finops.example.yml`](config/copilot-finops.example.yml) covers every scope; [`docs/config-schema.md`](docs/config-schema.md) is the authoritative field-by-field reference.

## 🖥️ Local CLI

The same engine runs from the command line via [`bin/copilot-finops.js`](bin/copilot-finops.js) (Node.js 24+):

```bash
npm install                                              # dev/test deps

node bin/copilot-finops.js validate config/copilot-finops.yml   # lint (no token)
node bin/copilot-finops.js apply    config/copilot-finops.yml \
  --enterprise your-enterprise                           # dry-run preview
node bin/copilot-finops.js apply    config/copilot-finops.yml \
  --enterprise your-enterprise --live                    # write budgets
```

`apply` reads the token from `COPILOT_FINOPS_TOKEN` (or `GITHUB_TOKEN`) and the enterprise from `--enterprise` or `COPILOT_FINOPS_ENTERPRISE`. A local `.env` in the working directory is loaded automatically. Migrate a legacy v2 file with `node bin/copilot-finops.js migrate <v2-in> <v3-out>`.

## 🧪 Development

```bash
npm test                 # node:test suite
npm run build            # bundle src/ -> dist/ with @vercel/ncc (commit dist/)
npm run build:site       # bundle the static Config Studio (commit site/app.bundle.js)
npm run docs:schema      # regenerate docs/config-schema.md (commit it)
```

CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs the tests and fails if the committed `dist/`, `site/app.bundle.js`, or `docs/config-schema.md` is stale.

## 📚 Documentation

| Doc | Contents |
| --- | --- |
| [docs/setup.md](docs/setup.md) | Token, enterprise variable, prerequisites, authoring config, naming conventions. |
| [docs/workflows.md](docs/workflows.md) | Workflow triggers, inputs, and the reconciliation and billing-flow diagrams. |
| [docs/config-schema.md](docs/config-schema.md) | Generated field-by-field config reference. |
| [docs/permissions.md](docs/permissions.md) | Token scopes per operation. |
| [docs/api-reference.md](docs/api-reference.md) | The exact billing API calls and request bodies. |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Common validation, permission, and API errors. |
| [docs/public-release.md](docs/public-release.md) | Checklist before publishing a fork or template. |
| [schemas/README.md](schemas/README.md) | The schema, its editor/CI role, and the schema ↔ validator boundary. |
| [Copilot FinOps skill](.github/skills/copilot-finops-config/SKILL.md) | The Copilot skill that authors and validates config. |

## 🔒 Safety

- 🧪 Manual `apply` runs default to `dry_run=true`; keep the schedule disabled until your config and token are ready.
- 👮 Protect `.github/workflows/**` and `config/**` with CODEOWNERS and required reviews on `main`.
- 🔐 Use a private repository for live enterprise configuration, and review [docs/public-release.md](docs/public-release.md) before making any copy public.
