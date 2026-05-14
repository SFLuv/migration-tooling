---
name: celo-migration-skill
description: SFLuv ecosystem Berachain-to-Celo migration context, runbooks, codebase findings, communications drafts, and implementation guidance. Use when planning, implementing, reviewing, or explaining the SFLuv migration across app/frontend, app/backend, app/ponder, mobile-app/mobile, mobile-app/backend, cw-app, and contracts.
---

# SFLuv Celo Migration

Use this skill whenever work touches the SFLuv migration from Berachain to Celo. Start with the context tree, then load only the reference file for the current task.

## Quick Start

1. Read [references/context-tree.md](references/context-tree.md) to choose the right reference.
2. For implementation work, read [references/migration-plan.md](references/migration-plan.md) and the relevant investigation file.
3. For operator work, read the matching runbook in `references/runbooks/`.
4. For public/internal messaging, read [references/comms/user-comms.md](references/comms/user-comms.md).
5. For source-code verification, resolve repo references through `./repos` first. Do not inspect old sibling/local checkouts such as `../app`, `../mobile-app`, `../contracts`, or `../cw-app` as the authority unless the user explicitly points to a specific local checkout for active implementation work.

## Living Context

Treat this skill as shared migration memory. When a conversation that has loaded this skill produces a new decision, preference, constraint, correction, implementation finding, runbook change, or comms wording that should guide future migration work, update the relevant reference file before finishing the turn. Keep updates concise, dated when timing matters, and placed in the most specific file rather than duplicating content across the tree.

## Non-Negotiables

- Treat client versioning as phase 0. The native mobile app cannot be reliably migrated until a released build can fetch backend config and enforce minimum compatible versions.
- Treat chain identity as data. New transaction, memo, W9, Ponder, and confirmation flows should carry `chain_id`; legacy Berachain defaults are only a compatibility bridge.
- Preserve Berachain Ponder history as read-only or explicitly backfilled with `chain_id=80094` before indexing Celo data.
- Keep smart-wallet derivation anchored to the existing account factory `0x7cC54D54bBFc65d1f0af7ACee5e4042654AF8185` and the stored user EOA plus smart wallet index.
- Do not assume Citizen Wallet silently rewrites saved account addresses. Dynamic config updates work, but saved account/address and cached chain-id behavior must be validated.
- Do not hand-edit token storage unless the temporary implementation exactly preserves the final ERC20/OpenZeppelin upgradeable storage layout.

## Repository Map

The migration workspace root contains a git repo for migration docs and git submodule references under `repos/`. The root repo tracks submodule gitlinks and `.gitmodules`, not vendored source code. Use these submodules as the canonical local source paths:

- `repos/app` -> `https://github.com/SFLuv/app.git`
- `repos/mobile-app` -> `https://github.com/SFLuv/mobile-app.git`
- `repos/contracts` -> `https://github.com/SFLuv/contracts.git`
- `repos/cw-app` -> `https://github.com/citizenwallet/app.git`

After cloning this migration repo, materialize source checkouts with:

```bash
git submodule update --init --recursive
```

When checking or refreshing source references, treat `repos/` as the canonical source locator. Avoid silently falling back to previously existing local copies outside this migration repo, because they may be stale or from a different branch. If a submodule is intentionally moved to another branch or commit for investigation, record that branch/commit in the relevant reference file.

## Reference Index

- [references/context-tree.md](references/context-tree.md): navigation and source-of-truth map.
- [references/migration-plan.md](references/migration-plan.md): phase plan, dependencies, cutover order.
- [references/investigations/mobile-app.md](references/investigations/mobile-app.md): mobile versioning/config findings.
- [references/investigations/web-backend-ponder.md](references/investigations/web-backend-ponder.md): web, backend, Ponder findings.
- [references/investigations/citizen-wallet.md](references/investigations/citizen-wallet.md): Citizen Wallet dynamic config risks.
- [references/investigations/contracts.md](references/investigations/contracts.md): contracts/proxy/storage/script findings.
- [references/schemas/backend-config.md](references/schemas/backend-config.md): proposed `/config` and `/client-version` schemas.
- [references/runbooks/celo-deploy-script.md](references/runbooks/celo-deploy-script.md): deploy/mirror/balance distribution script design.
- [references/runbooks/bera-wipe-script.md](references/runbooks/bera-wipe-script.md): Berachain deprecation/sweep script design.
- [references/comms/user-comms.md](references/comms/user-comms.md): communication audiences, draft copy, timing.
- [references/open-questions.md](references/open-questions.md): unresolved decisions and validation checklist.
