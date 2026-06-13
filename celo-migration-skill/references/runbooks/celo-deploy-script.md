# Celo Deploy Script Runbook

Working name: `celo-deploy-script`.

## Objective

Deploy SFLUV on Celo so every eligible Berachain user receives the matching Celo balance at the same smart wallet address whenever possible.

Implemented orchestration script: `run-migration.sh` in the migration-tooling repo root.

## Inputs

- Backend DB connection string.
- Berachain RPC URL.
- Celo RPC URL.
- Celo deployer private key, prefunded with CELO.
- Account factory address: `0x7cC54D54bBFc65d1f0af7ACee5e4042654AF8185`.
- Berachain SFLUV token/proxy: `0x881cad4f885c6701d8481c0ed347f6d35444ea7e`.
- Celo backing asset address and amount/source.
- Celo SFLUV governance/admin address.
- Explicit exception list for excluded, overridden, or manually handled accounts.

## Snapshot Data

Pull from backend DB:

- user id
- EOA address
- smart wallet address
- smart wallet index
- wallet active/hidden flags
- primary wallet
- merchant/location payment wallets
- reward payout wallets

Read from chain:

- Berachain SFLUV balance for each EOA/smart wallet.
- Smart wallet deployment status on Berachain.
- Celo smart wallet derived address for each EOA/index.
- Celo smart wallet deployment status before migration.

Pull from normalized Ponder DB:

- App-linked wallet balances after 18-to-6 decimal normalization.
- All non-zero holder balances whose addresses are not present in the app `wallets` table. Write these to a separate artifact so non-app accounts can be repopulated by a later migration step without being mixed into app-wallet deployment/distribution.

## Preflight Checks

Implemented in `run-migration.sh` as of 2026-06-12 (`Preflight Assertions` phase, all before the Berachain lock):

- Old/new token `decimals()` are read onchain and `DECIMAL_SCALE` must equal `10^(old - new)`.
- New token `underlying()` must exist and report the same decimals as the new token.
- Distributor must hold `MINTER_ROLE` on the new token; contract deployer must hold `DEFAULT_ADMIN_ROLE` on the old token.
- Projected app distribution total is computed read-only from Ponder transfer events (scale applied on the fly if not yet normalized); distributor backing balance and allowance must cover `projected_total - newToken.totalSupply()`.
- Contract deployer (old chain), wallet deployer, and distributor (new chain) must have nonzero gas balances.

1. Confirm each configured RPC returns a latest block. The automation intentionally does not enforce production chain IDs so local fork testing works.
2. For production runs, manually confirm Celo chain id is `42220` and Berachain chain id is `80094`.
3. Confirm account factory bytecode/address on Celo.
4. For sample EOAs and indices, compare stored Berachain smart wallet address to Celo factory `getAddress(owner, index)`.
5. Fail if any non-exception smart wallet does not match expected address.
6. Confirm deployer CELO balance covers wallet deployment plus token deployment/distribution gas.
7. Confirm backing asset balance/allowance is enough for total distribution.
8. Confirm storage layout if using a temporary distribution implementation.
9. Write immutable snapshot artifacts before broadcasting.

## Deployment Flow

1. Load and validate config.
2. Query backend DB and normalize wallet records.
3. Build unique address set for balances.
4. Upgrade Berachain SFLUV to the reversible migration-lock implementation without sweeping backing assets.
5. Normalize legacy 18-decimal Ponder transfer values and retained app W9 raw totals to 6 decimals, with before/after audit artifacts and DB marker rows to prevent accidental double-scaling.
6. Recompute Ponder `transfer_account` balances from normalized transfer events.
7. Write app-linked balance allocation and separate non-app external holder balance artifacts.
8. Delete non-app-wallet `transfer_account` balance rows from Ponder after writing `external-holder-balances.json`; this is intentional because those holders will be repopulated by a separate Celo path and normal indexing.
9. Deploy missing Celo smart wallets for each EOA/index.
10. Distribute balances:
   - safest: use ERC20 mint/deposit internals that update balances and total supply coherently.
   - avoid raw storage writes unless the implementation was built for this and layout is proven.
11. Record `celo_distribution_complete_block`; start Celo Ponder at the following block for app-linked distribution exclusion.
12. Verify implementation, roles, total supply, backing balance, and sample balances.
13. Write final artifact with tx hashes and addresses.
14. Run the separate Berachain backing sweep script only after manual verification.

## Ponder And History Cutover

Revised 2026-06-12: the Celo Ponder instance runs against its own dedicated database (Ponder refuses to start against a schema owned by a different build id — see open-questions.md). The Berachain DB is normalized in place and its history is then backfilled into the Celo DB, which becomes the single cross-chain continuity ledger the backend reads.

1. Before the onchain migration, pause Berachain SFLUV user activity, **manually verify the token is paused/locked correctly**, and wait for Berachain Ponder to index through the final paused block. This verification is an operator responsibility; the migration script does not gate on it.
2. Stop the Berachain Ponder process. Never restart it against the normalized DB (same-build crash recovery would replay stale 18-decimal reorg rows).
3. Run `run-migration.sh` (normalizes the legacy Ponder DB, wipes external balances, deploys wallets, distributes on Celo).
4. Create the dedicated Celo Ponder database (`MIGRATION_DB_CELO_PONDER_SUFFIX`) and boot the Celo Ponder instance against it with `PONDER_START_BLOCK = celo_distribution_complete_block + 1` so it creates its tables and goes live. Set `PONDER_CHAIN_ID=42220` on that instance: `src/index.ts` reads `context.chain.id` (fixed 2026-06-12 — Ponder 0.15 renamed `context.network`, so the old read always fell back to env/80094) with the env value as fallback, and a wrong chain id would tag every Celo row as Berachain and corrupt the ledger.
5. Run `backfill-bera-history.sh` to copy the normalized Berachain rows (`transfer_event`, `transfer_account`, `allowance`, `approval_event`) into the Celo Ponder DB. It refuses to run unless the source carries both the normalization and external-wipe markers, inserts with `ON CONFLICT DO NOTHING` (idempotent), and dies on any row-count or value-total mismatch. Ponder's reorg triggers log every insert into `_reorg__*` tables and crash recovery replays that log in reverse, so each table copy deletes its Berachain-tagged reorg-log entries in the same transaction — that cleanup is what makes the backfill safe to run while Celo Ponder is live.
6. Point backend Ponder reads at the Celo Ponder DB; continuity queries sum across `(chain_id, address)` rows as already implemented.
7. Verify continuity-ledger behavior: Ponder-derived balances equal Celo onchain balances, transaction history excludes distribution txs, and W9 totals include real paid activity across chains without counting migration distribution.
8. Keep the legacy Berachain Ponder DB as a read-only archive.

## Required Artifacts

- `wallet-snapshot.json`
- `balance-snapshot.json`
- `external-holder-balances.json`
- `app-wallet-distribution.json`
- `deployed-smart-wallets.json`
- `deployed-smart-wallet-balances.json`
- `allocation-plan.json`
- `exceptions.json`
- `deployment-result.json`
- `verification-report.json`
- `ponder-continuity-report.json`

Each artifact should include:

- timestamp
- source chain id/block
- target chain id/block
- script git commit if available
- deployer address
- config hash

## Failure Handling

- `run-migration.sh` keeps a per-run call trace (`call-trace.log` in the artifact dir, 2026-06-12). Each completed step (backups, lock upgrade, snapshot, normalizations, external wipe, each smart wallet batch, distribution, completion) is recorded. Rerunning with the same `--id` resumes exactly where the previous run failed: completed steps are skipped and their artifacts (including the pre-mutation DB dumps and the original `external-holder-balances.json`) are preserved, never recomputed or overwritten.
- The external-balance delete and its DB marker commit atomically in one statement; if the marker exists but the run id has no external artifacts, the script refuses to proceed and points the operator at the original `--id` (`ALLOW_EXTERNAL_BALANCE_WIPE_RERUN=true` remains the explicit escape hatch for restored DBs).
- Before token distribution: fix config/deployer/factory issue and rerun with the same `--id`.
- During distribution: rerun idempotently by calculating remaining desired balance per address.
- After final upgrade: do not rerun blindly; compare verification report and use targeted repair script.

## Script Behavior Decisions (2026-06-12)

- All `wallets` rows are funded — the `active = TRUE` and `is_eoa = FALSE` filters were removed from the snapshot, smart-wallet deployment, and distribution sets. Deactivating a wallet row must not strand its onchain funds, and any row with a valid `smart_address` plus `smart_index` is deployed regardless of `is_eoa`. The snapshot relies strictly on the `wallets` table (location/payment/primary address columns elsewhere are not snapshot inputs).
- `MIGRATION_EXTRA_FUNDED_ADDRESSES` (required env, 2026-06-12) names service-account addresses outside the `wallets` table whose Berachain balances are retained in the continuity ledger and repopulated on Celo — currently the backend faucet/bot address. The list joins the funded-address set everywhere (external-wipe boundary, distribution artifact, projected-total funding check) and is echoed in preflight plus `extra-funded-addresses.txt`. These addresses are funded but never deployed, so they must be EOAs. Set to `none` to explicitly fund only wallets-table addresses; the env being required prevents forgetting the faucet. Add future service accounts to this list.
- A `Wallets table integrity` preflight dies (with row ids in `wallet-integrity.json`) on any row that would otherwise be silently excluded: malformed `eoa_address`, malformed `smart_address`, valid `smart_address` with NULL `smart_index`, or duplicate `(eoa_address, smart_index)` pairs with conflicting smart addresses. Non-EOA rows with no `smart_address` at all are reported as warnings (nothing fundable for them).
- `--dry-run` is fully dry: it skips the W9 normalization, Ponder normalization/recompute, and the external balance wipe (in addition to forge `--broadcast`), and never marks call-trace steps as completed. Balance artifacts are derived from transfer events with the decimal scale applied on the fly, so dry-run artifacts match what a real run would produce.

- Recomputed Ponder `transfer_account` balances are clamped to zero: per-event FLOOR can leave dust-level negative balances for emptied wallets, and the continuity ledger must never report a negative legacy balance. Clamp stats (rows, total clamped up, excluding the zero address) are written to the ponder-normalization-after artifact.
- `celo_distribution_complete_block` is `max(chain head, highest block across forge broadcast receipts written by this run)` so a lagging load-balanced RPC head can never place the Ponder start block at or before the distribution transactions.
- Non-app external holder balances are intentionally deleted and not auto-migrated: some external account setups would lose keys or switch accounts cross-chain, and funds must not be locked into unrecoverable Celo accounts. Externals are handled by a separate, manual path from `external-holder-balances.json`.
- The backend is assumed to be shut down for the whole migration window; backend chain config and `TOKEN_DECIMALS` are redefined manually before it boots against Celo. The script intentionally does not enforce a maintenance mode.
- The Ponder normalization and external-wipe transactions truncate the `_reorg__*` operation-log tables they touch (second-pass fix, 2026-06-12). The manual `UPDATE`/`INSERT`/`DELETE` statements fire Ponder's reorg triggers (cloned with the prod DB), and a same-build restart of the old Berachain Ponder replays that log in reverse — without the cleanup it would revert the normalized tables back to raw 18-decimal values. With it, an accidental restart finds an empty log and reverts nothing.
- The forge-broadcast epoch used to filter `run-latest.json` receipts for the completion block is pinned in `run-start-epoch` inside the artifact dir on the first invocation, so a resumed run still recognizes receipts written by the original invocation.

## Verification Checklist

- Celo SFLUV proxy exists and implementation matches expected artifact.
- `DEFAULT_ADMIN_ROLE` holder is correct.
- `MINTER_ROLE` and `REDEEMER_ROLE` holders are correct.
- Total SFLUV supply equals allocation sum.
- Backing asset balance equals or exceeds distributed supply under the intended backing model.
- Random sample of user EOAs/indexed smart wallets match Berachain addresses and balances.
- Backend `/config` Celo output references the deployed Celo token and account config.
- Web and mobile can query Celo balances.
