# Open Questions And Validation Checklist

## Product / Release

- What adoption threshold is enough for the preliminary mobile release before setting `minimum` build?
- What App Store / Play Store URLs should `/client-version` return?
- What is the exact backend blocking strategy for old mobile builds after migration, given old builds must stop working once SFLuv no longer interacts with Berachain?
- Current old mobile builds do not appear to send app version/build/platform metadata to the shared app backend. Can they be blocked indirectly after cutover by disabling legacy Berachain-backed backend behavior, or do we need another server-side compatibility signal?

## Config

- Which exact SFLuv community selector should backend use against Citizen Wallet config: alias, custom domain, or token address?
- What is the Celo RPC/engine/paymaster/entrypoint configuration?
- What explorer URL should clients use on Celo?
- Should the SFLuv alias remain `wallet.berachain.sfluv.org`, change to a Celo alias, or keep custom domain `wallet.sfluv.org` as the stable public identity?

## Mobile

- Which build metadata convention should be canonical: iOS build number and Android version code, or an app-defined build integer?
- Should dynamic config be cached offline, and how long should stale config be accepted?
- How should QR chain/token mismatches be presented to users?

## Citizen Wallet

- Does Celo factory `getAddress(owner, 0)` match existing saved Berachain smart wallet addresses for real SFLuv users?
- Does same-alias config flip leave a stale cached chain id?
- Can Citizen Wallet tolerate a Berachain-to-Celo config update without requiring users to reinstall or reimport?
- If not, who coordinates a Citizen Wallet app update?

## Backend / Ponder

- Product requirement: backend must expose unified user transaction history across Berachain and Celo for accounting and continuity. Implementation can be one chain-aware transaction database or separate chain indexers/DBs behind the same backend API. After cutover, Berachain history remains queryable but no longer needs live ingestion.
- What is the default behavior for old clients that omit `chain_id` after cutover?
- Should transaction memos be migrated to `(chain_id, tx_hash)` with `80094` backfill?
- Should W9 yearly earning keys include `chain_id`, or should migrated Celo balances intentionally share wallet-year totals?

## Contracts / Onchain

- Celo backing asset is USDC at `0xcebA9300f2b948710d2653dD7B07f33A8B32118C`.
- Will Celo deployment use final wrapper minting/deposit flow or a temporary distribution implementation?
- If temporary distribution is used, has storage layout been proven identical to final implementation?
- Which new Celo wallet addresses control `DEFAULT_ADMIN_ROLE`, `MINTER_ROLE`, `REDEEMER_ROLE`, and operational deployer/distribution permissions? These should mirror the role pattern on current Berachain SFLUV/Zapper contracts where appropriate.
- What are the current active Berachain SFLUV/Zapper role holders? Discover from AccessControl events plus `hasRole` and record before Celo deployment.
- What exact new Celo/safe account receives swept Berachain backing assets?

## Final Go / No-Go Checklist

- Mobile preliminary release live.
- Minimum mobile build enforceable.
- Backend `/config` and `/client-version` live.
- Web consumes backend config.
- Backend supports Celo RPC/token and chain-aware tx verification.
- Ponder legacy history preserved.
- Celo Ponder ready.
- All money-movement flows pauseable from backend/operator controls.
- Celo deploy script dry-run complete.
- Berachain wipe script dry-run complete.
- Citizen Wallet same-alias migration tested.
- Communications scheduled.
- Support playbook ready.
