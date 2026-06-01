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

1. Before the onchain migration, pause Berachain SFLUV user activity and wait for Berachain Ponder to index through the final paused block.
2. Stop the Berachain Ponder process.
3. Reuse the existing Ponder DB for the Celo Ponder instance if validation confirms Ponder can safely continue from the existing schema/state.
4. Run the Celo balance population with Ponder stopped or with Celo indexing disabled.
5. Record `celo_population_complete_block` and `celo_population_complete_timestamp` in the deployment artifact.
6. Start Celo Ponder at `celo_population_complete_block + 1`.
7. Verify continuity-ledger behavior: Ponder-derived balances equal Celo onchain balances, transaction history excludes distribution txs, and W9 totals include real paid activity across chains without counting migration distribution.
8. If backend/Ponder reads remain active-chain scoped, stop and seed an opening-balance checkpoint or adjust reads before enabling user traffic.

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

- Before token distribution: fix config/deployer/factory issue and rerun from artifact.
- During distribution: rerun idempotently by calculating remaining desired balance per address.
- After final upgrade: do not rerun blindly; compare verification report and use targeted repair script.

## Verification Checklist

- Celo SFLUV proxy exists and implementation matches expected artifact.
- `DEFAULT_ADMIN_ROLE` holder is correct.
- `MINTER_ROLE` and `REDEEMER_ROLE` holders are correct.
- Total SFLUV supply equals allocation sum.
- Backing asset balance equals or exceeds distributed supply under the intended backing model.
- Random sample of user EOAs/indexed smart wallets match Berachain addresses and balances.
- Backend `/config` Celo output references the deployed Celo token and account config.
- Web and mobile can query Celo balances.
