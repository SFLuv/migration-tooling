# Open Questions And Validation Checklist

## Product / Release

- What adoption threshold is enough for the preliminary mobile release before setting `minimum` build?
- What App Store / Play Store URLs should `/client-version` return?
- Should old mobile builds be blocked by backend API errors after the minimum build is enforced, or only by the new client-side version screen?
- Should sends/redemptions/workflow payouts be paused during the migration window through backend feature flags?

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

- Will Berachain and Celo Ponder data live in separate databases or one migrated schema?
- What is the default behavior for old clients that omit `chain_id` after cutover?
- Should transaction memos be migrated to `(chain_id, tx_hash)` with `80094` backfill?
- Should W9 yearly earning keys include `chain_id`, or should migrated Celo balances intentionally share wallet-year totals?

## Contracts / Onchain

- What Celo backing asset backs SFLUV at launch?
- Will Celo deployment use final wrapper minting/deposit flow or a temporary distribution implementation?
- If temporary distribution is used, has storage layout been proven identical to final implementation?
- Who controls `DEFAULT_ADMIN_ROLE` after Celo deployment?
- What exact safe receives swept Berachain backing assets?

## Final Go / No-Go Checklist

- Mobile preliminary release live.
- Minimum mobile build enforceable.
- Backend `/config` and `/client-version` live.
- Web consumes backend config.
- Backend supports Celo RPC/token and chain-aware tx verification.
- Ponder legacy history preserved.
- Celo Ponder ready.
- Celo deploy script dry-run complete.
- Berachain wipe script dry-run complete.
- Citizen Wallet same-alias migration tested.
- Communications scheduled.
- Support playbook ready.
