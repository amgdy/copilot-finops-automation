# Cost Center Members Config Patterns

Cost center member sync config lives under `mappings:` in `config/cost-center-members.yml` or `config/cost-center-members.local.yml`.

## Empty Config

```yaml
enterprise_slug: your-enterprise
mappings: []
```

## Naming

Use predictable cost center names:

- Org team cost center: `cc-org-{org}-{team-slug}`
- Enterprise team cost center: `cc-ent-{enterprise}-{team-slug}`

Enterprise team sources use the bare team slug, not `ent:{slug}`.

## Org Team Strict Sync

Adds missing users and removes extra users from the cost center.

```yaml
enterprise_slug: your-enterprise

mappings:
  - name: cc-org-your-org-platform-engineering
    description: Keep org team platform-engineering exactly in sync with its cost center.
    source:
      org: your-org
      team_slug: platform-engineering
    target:
      cost_center: cc-org-your-org-platform-engineering
    sync:
      remove_extra_members: true
      batch_size: 50
```

## Enterprise Team Additive Sync

Adds missing users but keeps extra/manual cost center members.

```yaml
enterprise_slug: your-enterprise

mappings:
  - name: cc-ent-your-enterprise-ai-leads
    description: Add enterprise team ai-leads members to its cost center without removing extras.
    source:
      enterprise: your-enterprise
      team_slug: ai-leads
    target:
      cost_center: cc-ent-your-enterprise-ai-leads
```

## Explicit Additive Sync

Use this when the user wants the intent visible in review.

```yaml
sync:
  remove_extra_members: false
```

## Strict vs Additive Decision

Use strict sync when:

- The cost center should contain exactly the team members.
- Removed team members should stop being charged to that cost center.

Use additive sync when:

- The cost center also contains manually managed users.
- Another process manages removals.
- The user is testing and wants lower blast radius.

## Validation

```bash
scripts/validate-config.sh config/cost-center-members.yml teams
```

Run locally with:

```bash
scripts/sync-cost-center-members.sh --config-file config/cost-center-members.yml --dry-run true
```
