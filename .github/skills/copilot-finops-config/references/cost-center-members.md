# Cost Center Members Config Patterns (v2)

Cost center member sync lives under `team_cost_center_mappings:` in the merged v2 file
`config/copilot-finops.yml` (or `config/copilot-finops.local.yml`). A v2 file declares `version: 2`;
`ai_credit_spend_policies` and `team_cost_center_mappings` are both optional (include only what you need).

> **Authoritative shape:** the full mapping field list and rules live in
> `schemas/v2/copilot-finops.schema.json` and `config/copilot-finops.example.yml`. This file shows
> idiomatic examples and the strict-vs-additive judgment — if it disagrees with the schema, the schema wins.

> Editing an existing v1 file (`config/cost-center-members.yml`)? Use the v1 `mappings:` shape
> (`source` / `target` / `sync`) and validate with `... teams`. See the v1 → v2 map in `SKILL.md`.

## Native enterprise team assignment (recommended)

GitHub now supports adding an **enterprise team directly as a cost center resource**
([changelog](https://github.blog/changelog/2026-06-25-assign-enterprise-teams-to-cost-centers/)).
When you do this in the enterprise **Billing and licensing → Cost centers** UI (add the team under
"Resources"), GitHub attributes all member usage to that cost center and keeps membership current
automatically — including via SCIM/IdP sync — with no reassignment.

Prefer native assignment over `team_cost_center_mappings` whenever you can: it is the platform's own
mechanism and needs no scheduled job. The `team_cost_center_mappings` user-level sync remains a
**bridge** for config-as-code / automated scenarios, because the REST resource endpoint does not yet
expose a team write field (it still accepts only `users`/`organizations`/`repositories`).

Because native assignment is now the recommended path, the v2 schema marks `team_cost_center_mappings`
(and each `mapping`) as `deprecated: true` (a soft annotation — it still validates and runs; nothing is
removed). See the GitHub tutorial
[Control costs at scale](https://docs.github.com/en/enterprise-cloud@latest/billing/tutorials/control-costs-at-scale)
for the native flow.

### Default behavior: mappings are skipped (`force_user_sync`)

`sync-cost-center-members.sh` now **skips every mapping by default** and defers to native assignment —
it logs a `NOTE` and makes no membership writes. To run the legacy user-level sync for a mapping, set
`force_user_sync: true` on that mapping (or run the workflow with the `force_user_sync` input, which
passes `--force-user-sync true` to the script — this also forces frozen v1 configs that have no such
field). `remove_extra_members` only takes effect when the mapping is forced. Recommend native assignment
first; reach for `force_user_sync` only where native assignment is not usable. The audit workflow flags a
mapping that is neither assigned natively nor forced as **membership unmanaged**; if sync/apply uses the
global `force_user_sync` workflow input (especially for frozen v1 config), run audit with that input too.

**Do not run both against the same cost center.** Even when forced, if a mapping's team is already
assigned natively, `sync-cost-center-members.sh` logs a `NOTE` and **skips that mapping** (re-adding the
same members as direct user resources would be redundant and conflict with the native assignment). A
different natively-assigned team produces a `WARN`.

## Empty / sync-only Config

```yaml
version: 2
enterprise_slug: your-enterprise
team_cost_center_mappings: []
```

## Naming

Use predictable cost center names:

- Org team cost center: `cc-org-{org}-{team}`
- Enterprise team cost center: `cc-ent-{enterprise}-{team}`

Use the bare team slug. `organization:` selects an org team source; omit it for an enterprise team
(the enterprise is inferred). `enterprise:` and `organization:` are mutually exclusive.

## Org Team Strict Sync

Adds missing users and removes extra users from the cost center. Requires `force_user_sync: true`
(otherwise the mapping is skipped in favor of native assignment).

```yaml
team_cost_center_mappings:
  - name: cc-org-your-org-platform-engineering
    description: Keep org team platform-engineering exactly in sync with its cost center.
    organization: your-org
    team: platform-engineering
    cost_center: cc-org-your-org-platform-engineering
    force_user_sync: true
    remove_extra_members: true
```

## Enterprise Team Additive Sync

Adds missing users but keeps extra/manual cost center members. Requires `force_user_sync: true`.

```yaml
team_cost_center_mappings:
  - name: cc-ent-your-enterprise-ai-leads
    description: Add enterprise team ai-leads members to its cost center without removing extras.
    team: ai-leads
    cost_center: cc-ent-your-enterprise-ai-leads
    force_user_sync: true
```

## Explicit Additive Sync

Use this when the user wants the intent visible in review — set `remove_extra_members: false`
explicitly on the mapping (same effect as omitting it). Still requires `force_user_sync: true` to run:

```yaml
team_cost_center_mappings:
  - name: cc-ent-your-enterprise-ai-leads
    team: ai-leads
    cost_center: cc-ent-your-enterprise-ai-leads
    force_user_sync: true
    remove_extra_members: false
```

## Strict vs Additive Decision

Use strict sync (`remove_extra_members: true`) when:

- The cost center should contain exactly the team members.
- Removed team members should stop being charged to that cost center.

Use additive sync (omit or `false`) when:

- The cost center also contains manually managed users.
- Another process manages removals.
- The user is testing and wants lower blast radius.

## Validate and dry-run

See `./validation.md` for the full command matrix (v1/v2, dry-run, workflow inputs). Quick check after authoring:

```bash
scripts/validate-config.sh config/copilot-finops.yml all
```
