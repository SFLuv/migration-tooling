# Migration Plan

## Goals

- Move SFLuv from Berachain to Celo without changing user-facing wallet addresses.
- Preserve legacy Berachain transaction history for lookup.
- Move all clients to dynamic backend-hosted config.
- Enforce mobile client compatibility before the migration cutover.
- Deploy Celo SFLUV balances to match Berachain balances, then deprecate Berachain SFLUV safely.

## Phase 0: Mobile Gating And Dynamic Config

Ship a preliminary mobile release before any chain cutover:

1. Add native version metadata and a public backend `/client-version` check.
2. Add runtime config bootstrapping from backend `/config` before wallet/service boot.
3. Render a blocking update/maintenance screen before `PrivyProvider` when the backend marks the installed build incompatible.
4. Dynamicize chain name, native currency, RPC, token, paymaster, entrypoint, factory, explorer, app origin, Citizen Wallet engine/backend values, and backend-provided chain extras.
5. Wait until adoption is high enough to safely enforce `minimum` build.

Reason: current mobile app has Berachain defaults baked into source/env and no force-update path. See [investigations/mobile-app.md](investigations/mobile-app.md).

## Phase 1: Config Authority

Add backend-hosted config and version endpoints:

- `GET /config`: public, cacheable, no secrets, loaded from the per-community Citizen Wallet config endpoint and merged with backend env extras for fields Citizen Wallet does not model.
- `GET /client-version`: public, platform-aware compatibility policy for web/mobile/Citizen Wallet-facing surfaces.

Load order:

1. Backend attempts the configured per-community Citizen Wallet config URL, normally `${CITIZEN_WALLET_CONFIG_BASE_URL}/${CITIZEN_WALLET_COMMUNITY_ALIAS}.json`.
2. Backend falls back to a local JSON file in the backend root with the same Citizen Wallet config shape.
3. Backend fails to boot if neither remote nor local config loads.
4. Backend adds top-level `extras` from known chain env values only when there is no Citizen Wallet field for the value. Examples include underlying/backing asset setup, bridge/Zapper contracts, and faucet contracts. BYUSD/HONEY token metadata should come from the Citizen Wallet `tokens` map whenever those token entries exist.
5. Web/mobile fetch backend config at boot and use it as the chain source of truth. Client-side chain constants/env values should not define blockchain addresses, RPCs, or integration contracts.

Schema notes live in [schemas/backend-config.md](schemas/backend-config.md).

## Phase 2: Client And Server Readiness

Prepare code changes across clients and backend:

- Web app: replace static `app.config.ts` authority with backend config, while keeping build-time defaults.
- Mobile app: consume backend config and version policy before wallet/service boot.
- Backend: parameterize chain/token/RPC config and add chain-aware transaction verification.
- Ponder: preserve Berachain history and add Celo indexing with explicit chain identity.
- Citizen Wallet: validate remote config update behavior and chain-id cache behavior before relying on silent config switch.

Important backend transaction work:

- Add `chain_id` to transaction identity at API boundaries.
- Add `chain_id` anywhere transactions or transaction hashes are stored in Ponder, bot DBs, or app DBs.
- Add `chain_id` to Ponder transfer events or route to chain-specific Ponder DBs.
- Include `chain_id` in bot, Ponder, and app logs for transaction ingestion, verification, redemption, payout, and memo paths.
- Use `(chain_id, tx_hash)` for memo authorization, transaction lookup, and onchain confirmation.
- Add idempotent service-boot backfills for untagged transaction rows. Each service should read the active chain id from current backend config/env, update only rows where `chain_id` is missing or null, log per-table counts, and leave any already-tagged row untouched.
- Default missing legacy `chain_id` at old API boundaries only where needed for compatibility; persisted records should be backfilled/tagged rather than staying ambiguous.

## Phase 3: Celo Onchain Execution

Run the Celo deployment script:

1. Connect to backend DB.
2. Snapshot users' EOA addresses, smart wallet addresses, smart indices, and migration-eligible account balances.
3. Read Berachain balances for every relevant EOA/smart wallet address, with explicit exception handling.
4. Load a prefunded deployer private key.
5. Deploy each smart wallet on Celo using the stored EOA and smart index.
6. Deploy Celo SFLUV proxy/implementation or distribution implementation.
7. Distribute Celo SFLUV balances to match Berachain snapshot balances.
8. Add backing assets to match distributed supply.
9. Upgrade to final SFLUV implementation if a temporary distribution implementation was used.
10. Verify supply, backing, roles, implementations, sample balances, and client config output.

Script design lives in [runbooks/celo-deploy-script.md](runbooks/celo-deploy-script.md).

Ponder/W9 cutover note, added 2026-05-27:

- Pause user-facing Berachain token activity first, then let Berachain Ponder index through the final paused block before stopping it.
- Treat the existing Ponder DB as a cross-chain continuity ledger if we can run the Celo Ponder instance against it. In that model, do not reset or reseed Ponder balances; existing Berachain-derived balances are the logical opening balances for Celo.
- Ponder event identity can rely on Ponder's chain-aware event id scheme for uniqueness. Explicit `chain_id` remains useful metadata for explorer links/display, but Ponder balance/history/W9 lookups should not require chain-filtered reads.
- Backfill/tag app/bot transaction records where backend verification or UI needs explicit chain metadata, but avoid operationally depending on Ponder-row retagging for the cutover.
- Distribute Celo opening balances while Ponder is stopped or while Celo indexing is disabled.
- Start Celo Ponder at the block after the final balance population transaction, so migration distribution transfers do not appear in user transaction history and do not trigger W9 or notification hooks.
- 2026-05-28 update: backend Ponder-backed balance, history, analytics, and W9 reads now aggregate the continuity ledger across chains rather than filtering only the active chain. A checkpoint is only needed if we reintroduce chain-scoped Ponder balance reads.
- If Celo SFLUV launches with 6 decimals, normalize legacy 18-decimal Ponder transfer amounts to 6-decimal units before Celo indexing begins, then recompute `transfer_account` balances from the transformed transfer events. Apply the same scale conversion to retained app DB raw totals such as W9 earnings. Use the recomputed 6-decimal balances for Celo population, and have the migration script audit row counts, totals, remainder counts, and recomputed balance totals.
- 2026-06-01 update: the Berachain deprecation step is split. The migration script may upgrade Berachain SFLUV to a write-locking `SFLUVBeraWipe` implementation before Celo distribution, but it must not sweep backing assets during that script. The backing sweep is a separate manually executed owner-gated call after Celo balances, clients, backend config, and Ponder start block have been verified.
- 2026-06-01 update: after writing a separate `external-holder-balances.json` artifact for non-app-wallet Ponder holders, the migration script intentionally deletes those non-app `transfer_account` balance rows from the reused Ponder DB. Those external balances are expected to be repopulated by a separate Celo migration path and normal Celo indexing, not preserved as old continuity balances.
- 2026-06-12 update: the "reuse the same Ponder DB" model is replaced. Ponder 0.15 refuses to start against a schema owned by a different build id, so the Celo Ponder instance runs against a dedicated database (`MIGRATION_DB_CELO_PONDER_SUFFIX`). After it boots, `backfill-bera-history.sh` copies the normalized Berachain history into it; the Celo DB then becomes the single cross-chain continuity ledger. External holders are intentionally not auto-migrated (some external account setups lose keys or switch accounts cross-chain; funds must not be locked into unrecoverable Celo accounts). The migration script funds every `wallets`-table row (active or not) and fails loudly via a wallet-integrity preflight rather than silently excluding rows. `--dry-run` performs no DB mutations.
- 2026-06-30 update: **the on-chain + DB execution now runs through the [migrator web app](../../migrator/README.md)** (Go backend + Next.js stepper), not the shell scripts. The migrator is the live tool; `run-migration.sh` / `backfill-bera-history.sh` remain as a CLI reference but have **diverged** and should not be used for the cutover. Current migrator step order: preflight → backups → Bera lock → wallet snapshot → normalize app W9 → balance artifacts → seed recovery balances → deploy Celo wallets → **backing recovery check** → distribute → **replicate MINTER/REDEEMER roles** → completion → **backfill**. Notable model changes vs the scripts:
  - The legacy Berachain Ponder is **read-only**. There is no in-place Ponder normalization and no external-row wipe; the 18→6 conversion happens during the backfill copy into the dedicated Celo Ponder DB. (App-DB W9 totals are still normalized in place, marker-guarded.) The `external-holder-balances.json` holders are excluded from Celo distribution but seeded into `recovery_balances` (bot DB) so they can claim via the recovery flow.
  - **Backing recovery check** (new): before distributing, simulate wrapping a tiny amount of backing into Celo SFLUV and unwrapping it (always a dry-run simulation against a fork; never broadcasts) to prove backing is recoverable; aborts the migration if not.
  - **Role replication** (new): scan all Berachain SFLUV holders + funded accounts, detect `MINTER_ROLE`/`REDEEMER_ROLE` holders on the old token, and grant the same on Celo using `CELO_ADMIN_PRIVATE_KEY` (detection runs on dry runs; grant does not).
  - The backfill step provides copyable snippets (a ready Celo `ponder.config.ts` and a start command that **creates the Celo Ponder database if missing** before booting Ponder).

## Phase 4: Cutover

After Celo deployment verifies:

1. Switch backend config to Celo.
2. Switch deployed backend env/RPC/token values to Celo.
3. Switch or launch Celo Ponder from `celo_population_complete_block + 1`.
4. Verify Ponder continuity balances match Celo onchain balances after applying post-cutover deltas.
5. Confirm migration distribution transfers are absent from `/transactions` history and W9 yearly totals.
6. Confirm web boot, mobile boot, send/receive, redemption, workflow payout, merchant lookup, and transaction history.
7. Confirm Citizen Wallet behavior for existing SFLuv users.
8. Monitor errors, support channels, and backend logs.

## Phase 5: Berachain Deprecation

Only after manual verification:

1. Confirm Berachain SFLUV was upgraded to the migration-lock/deprecation implementation, or run the upgrade-only script if it was deferred.
2. Run the separate Berachain backing sweep script.
3. Sweep underlying backing ERC20s to the designated treasury/safe address.
4. Revert all user-facing token methods with `SFLuv has migrated to CELO.`
5. Leave read-only Berachain Ponder data available.

Script design lives in [runbooks/bera-wipe-script.md](runbooks/bera-wipe-script.md).

## Rollback Stance

- Before Berachain wipe: rollback should mean switching backend config back to Berachain and pausing Celo-facing actions.
- After Berachain wipe: rollback is not practical. Treat wipe as the point of no return.
- Never run wipe until client cutover has been verified on web, new mobile, old mobile behavior, and Citizen Wallet.
