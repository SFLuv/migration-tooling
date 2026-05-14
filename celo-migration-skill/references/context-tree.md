# Context Tree

This file is the entry point for migration context. Load only the branch needed for the current task.

## Source Repo Submodules

- `repos/app` -> `https://github.com/SFLuv/app.git`
  - `frontend`: SFLuv web application.
  - `backend`: shared SFLuv backend, app DB, bot/redeemer/minter services, Ponder API proxy.
  - `ponder`: SFLuv ERC20 transaction indexer and webhook service.
- `repos/mobile-app` -> `https://github.com/SFLuv/mobile-app.git`
  - `mobile`: Expo/React Native SFLuv wallet.
  - `backend`: custom AA/RPC backend, not the shared app backend.
- `repos/contracts` -> `https://github.com/SFLuv/contracts.git`
  - Foundry SFLUV token contracts and scripts.
- `repos/cw-app` -> `https://github.com/citizenwallet/app.git`
  - Citizen Wallet Flutter app.

The `repos/` entries are git submodules. Treat `./repos` as the canonical source locator for all checked references. After cloning or pulling the root migration repo, run `git submodule update --init --recursive` to materialize missing source checkouts. Do not use previously existing sibling/local copies such as `../app`, `../mobile-app`, `../contracts`, or `../cw-app` as reference authority unless the user explicitly asks for that local checkout.

## What To Read

- Overall sequencing: [migration-plan.md](migration-plan.md).
- Mobile version/config work: [investigations/mobile-app.md](investigations/mobile-app.md) plus [schemas/backend-config.md](schemas/backend-config.md).
- Web app config work: [investigations/web-backend-ponder.md](investigations/web-backend-ponder.md).
- Backend config/version endpoints: [schemas/backend-config.md](schemas/backend-config.md) and [investigations/web-backend-ponder.md](investigations/web-backend-ponder.md).
- Ponder or transaction-history changes: [investigations/web-backend-ponder.md](investigations/web-backend-ponder.md).
- Citizen Wallet support: [investigations/citizen-wallet.md](investigations/citizen-wallet.md).
- Contract/deployment work: [investigations/contracts.md](investigations/contracts.md), [runbooks/celo-deploy-script.md](runbooks/celo-deploy-script.md), and [runbooks/bera-wipe-script.md](runbooks/bera-wipe-script.md).
- External/internal comms: [comms/user-comms.md](comms/user-comms.md).
- Known gaps: [open-questions.md](open-questions.md).

## Migration Anchors

- Existing Berachain chain id: `80094`.
- Target Celo chain id: `42220`.
- Account factory expected to be identical on Berachain and Celo: `0x7cC54D54bBFc65d1f0af7ACee5e4042654AF8185`.
- Existing Berachain SFLUV proxy/token in code: `0x881cad4f885c6701d8481c0ed347f6d35444ea7e`.
- Citizen Wallet public config source to mirror/fallback from: `https://config.internal.citizenwallet.xyz/v4/communities.json`.

## Working Assumptions

- User EOA addresses and smart wallet indices in the backend DB are sufficient to derive matching Celo smart wallet addresses if the Celo factory is byte-for-byte compatible and configured identically.
- Merchant payment wallets, contact addresses, primary rewards accounts, and user primary wallets should continue to work by address if smart-wallet address derivation matches.
- Legacy transaction history does not need to remain live-indexed on Berachain after cutover, but it must remain queryable for clients and backend workflows.
- Mobile rollout gating is the long pole. A preliminary mobile release should ship dynamic config and version enforcement before the chain switch.

## Root Git Layout

The root repo tracks migration documentation, `.gitmodules`, and submodule gitlinks only. Source contents remain owned by their upstream repos.

```text
migration-tooling/
├── .git/
├── .gitignore
├── .gitmodules
├── celo-migration-skill/
└── repos/
    ├── app/          # submodule: https://github.com/SFLuv/app.git
    ├── mobile-app/   # submodule: https://github.com/SFLuv/mobile-app.git
    ├── contracts/    # submodule: https://github.com/SFLuv/contracts.git
    └── cw-app/       # submodule: https://github.com/citizenwallet/app.git
```
