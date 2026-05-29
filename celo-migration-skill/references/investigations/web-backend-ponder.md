# Web, Backend, And Ponder Investigation

## Web Frontend

The web app is currently static-configured:

- `app/frontend/app.config.ts:1` imports `berachain`.
- `app/frontend/app.config.ts:4` exports a hardcoded Citizen Wallet config object.
- Hardcoded Berachain values include chain id `80094`, token `0x881cad4f885c6701d8481c0ed347f6d35444ea7e`, factory `0x7cC54D54bBFc65d1f0af7ACee5e4042654AF8185`, paymaster, entrypoint, engine URLs, and config URL.
- `app/frontend/lib/constants.ts:6` derives `CHAIN_ID`, `CHAIN`, token, factory, paymaster, decimals, and symbol from that static config.
- `app/frontend/context/Providers.tsx:48` locks Privy to the static chain.
- `app/frontend/lib/paymaster/client.ts:8` uses static `CHAIN` and `COMMUNITY.primaryRPCUrl`.

Other Berachain assumptions:

- `berascan.com` transaction link in `app/frontend/components/transactions/transaction-modal.tsx:231`.
- Redeem alias in `app/frontend/lib/redeem-link.ts:1`.
- Stargate `srcChainKey: "bera"` in `app/frontend/lib/wallets/wallets.ts:923`.
- CSP Berachain RPC default in `app/frontend/middleware.ts:51`.

Recommendation: move web to backend `/config` as runtime authority, with bundled defaults matching current Berachain config until cutover.

## Backend Config Touchpoints

Backend chain config is env-scattered:

- `TOKEN_ID`, `UNDERLYING_TOKEN_ID`, `TOKEN_DECIMALS`, `RPC_URL`, backing assets, bot/admin/redeemer values in `app/backend/.env.example:20`.
- As of the `repos/app` main update to `c978d92` on 2026-05-25, first-class `CHAIN_ID`, `/config`, and `/client-version` exist in `app/backend/handlers/app_client_config.go`, `app/backend/structs/app_client_config.go`, and `app/backend/router/router.go`.
- Transaction/Ponder routes are registered in `app/backend/router/router.go:275`.

Direct onchain services:

- Bot reads `BOT_KEY`, `TOKEN_ID`, `RPC_URL` in `app/backend/bot/bot.go:74`.
- Bot gets chain id from RPC at signing time in `app/backend/bot/bot.go:175`.
- Bot verifies tx receipts/logs by hash/token/from/to/amount in `app/backend/bot/bot.go:206`.
- Redeemer reads `RPC_URL`/`TOKEN_ID` in `app/backend/handlers/redeemer.go:58`.
- Minter reads `RPC_URL`/`TOKEN_ID` in `app/backend/handlers/minter.go:35`.
- Workflow payout confirmation depends on bot hash verification in `app/backend/handlers/app_workflow.go:261`.

Wallet metadata:

- Wallet table has no chain dimension in `app/backend/db/app.go:270`.
- Wallet struct has `eoa_address`, `smart_address`, and `smart_index` only in `app/backend/structs/app_wallet.go:5`.
- Wallet CRUD/lookups are address-only in `app/backend/db/app_wallet.go:59`.
- User primary wallet fields are address-only in `app/backend/db/app_user.go:75`.
- Location payment wallets and W9 totals are also address-only. Relevant files: `app/backend/db/app_location_wallet.go:13`, `app/backend/db/ponder_w9.go:11`, and `app/backend/db/app.go:2685`.

This is acceptable only if smart-wallet addresses match on Celo. Even then, transaction/hash data needs chain identity.

## Ponder History

Ponder is single-chain Berachain:

- `app/ponder/ponder.config.ts:10` hardcodes chain `berachain`, id `80094`, and the Berachain SFLUV token.
- `transfer_account` primary key is address-only in `app/ponder/ponder.schema.ts:3`.
- `transfer_event` has `id`, `hash`, `amount`, `timestamp`, `from`, `to` only in `app/ponder/ponder.schema.ts:14`.
- `allowance` primary key is owner/spender only in `app/ponder/ponder.schema.ts:44`.
- Hook payloads omit chain id in `app/ponder/src/index.ts:63`.
- Hooks subscribe by address only in `app/ponder/src/db.ts:15`.

Backend transaction queries are address/hash-only:

- `app/backend/db/ponder_transactions.go:12`
- `app/backend/db/ponder_transactions.go:90`
- `app/backend/handlers/ponder_transactions.go:12`
- Memos are keyed by `tx_hash` only in `app/backend/db/app_memo.go:9` and schema `app/backend/db/app.go:400`.
- App DB transaction-hash fields are not yet consistently chain-tagged, including memo rows, W9 `last_tx_hash`, workflow payout hashes, manager payout hashes, and unwrap tx hashes.
- Bot/redeemer/minter transaction verification logs should include chain id in addition to tx hash/token/from/to/amount.

2026-05-27 update from current `repos/app` state:

- Ponder event/account/allowance schema now carries `chain_id` and uses chain-aware primary keys/indexes in `repos/app/ponder/ponder.schema.ts`.
- Ponder hooks and W9 transaction hook payloads include `chain_id` in `repos/app/ponder/src/index.ts`.
- Ponder config is still operationally single-chain in `repos/app/ponder/ponder.config.ts`, hardcoded to Berachain id `80094`, Berachain SFLUV token, and Berachain default start block. Celo cutover still needs runtime chain/token/start-block config or a Celo-specific deployment config.
- `ponder_hooks` and app-side Ponder subscriptions remain address-only. That is acceptable only if exactly one live Ponder chain emits hooks at a time. Dual live Berachain+Celo notification indexing would need hook/subscription chain scoping.
- 2026-05-28 implementation update: backend Ponder-backed transaction history, historical balance, W9 paid totals, analytics transfers, analytics `transfer_account` balances, and analytics role indexing now read the reused Ponder DB as a continuity ledger instead of filtering by the active chain. Transaction rows still return `chain_id`, memo storage remains keyed by `(chain_id, tx_hash)`, and explicit memo authorization may use a supplied transaction chain id only to disambiguate a hash.
- 2026-05-28 decimal-scale finding: Ponder stores `transfer_event.amount`, `transfer_account.balance`, allowances, hooks, W9 totals, and analytics values as raw on-chain base units. Existing Berachain rows are therefore 18-decimal units. If Celo SFLUV is deployed with 6 decimals while reusing the Ponder DB as a cross-chain continuity ledger, legacy Ponder rows must be normalized or chain/token scale must be carried through balance/history/W9/analytics queries before summing or formatting them. Otherwise a legacy `1 SFLUV` row (`1e18`) and a new Celo `1 SFLUV` row (`1e6`) will be interpreted in the same unit and reports/balances/W9 thresholds will be wrong.
- 2026-05-28 preferred 6-decimal normalization direction: before starting Celo Ponder, transform legacy Berachain Ponder raw-unit transaction values from 18-decimal scale to 6-decimal scale by integer-dividing `transfer_event.amount` by `1e12`. Then recompute and overwrite `transfer_account.balance` from the transformed transfer events so balances remain internally consistent even if any event had truncated dust. Apply the same scale conversion to persisted app DB raw totals such as `w9_wallet_earnings.amount_received` if those cached rows are retained. Allowance tables (`allowance.amount`, `approval_event.amount`) can also be scaled for historical consistency, but they should not drive migrated Celo balances.

## Ponder Cutover Recommendation

Preferred continuity-ledger model, revised 2026-05-27:

If the Celo Ponder instance can safely reuse the existing Ponder DB, preserve that DB as the canonical cross-chain SFLuv ledger. In this model the existing Berachain-derived balances remain the logical opening balances for Celo, so no explicit Celo opening-balance adjustment is needed in Ponder.

1. Put app/backend mutation paths into maintenance or otherwise pause sends, redemptions, workflow payouts, and merchant/payment activity.
2. Pause or deprecate the Berachain SFLUV contract so no more Berachain transfer events can occur.
3. Let Berachain Ponder index through the final paused block, then stop the Berachain Ponder process.
4. Keep the existing Ponder DB in place for the Celo Ponder instance. Do not wipe, rebuild, or reseed Ponder balance rows.
5. Snapshot Berachain balances at the final Berachain block and run Celo deployment/distribution while Ponder indexing is stopped or Celo indexing is disabled.
6. Record `celo_population_complete_block` and `celo_population_complete_timestamp`.
7. Start Celo Ponder with the Celo SFLUV token and `PONDER_START_BLOCK=celo_population_complete_block + 1`.
8. Switch backend config to Celo only after the reused Ponder DB and start block are verified.

Continuity requirements:

- Transaction history and W9 totals should query the reused Ponder ledger across chains unless the product explicitly asks for per-chain filtering. This is now implemented in backend Ponder-backed reads.
- Current/logical balances should sum all `(chain_id, address)` `transfer_account` rows for the address. With chain-keyed `transfer_account`, a first Celo send from a migrated holder can create a negative Celo row, but the sum of Berachain row plus Celo row is the intended migrated-token balance. Analytics balance reads now do this.
- The continuity-ledger sum assumes all indexed chains use the same token base-unit scale. If Berachain remains 18 decimals and Celo launches at 6 decimals, add an explicit decimal normalization strategy before relying on cross-chain sums.
- If normalizing the Ponder DB in place to 6 decimals, run it while Ponder and backend writers are stopped, after final Berachain indexing and before Celo indexing begins. Snapshot the DB first and persist a transform audit artifact with row counts, total-before/after checks, non-zero remainder counts, and recomputed balance totals. Use the recomputed 6-decimal `transfer_account` balances as the source for Celo population.
- Explicit `chain_id` remains useful metadata for explorer links, display, and any future chain-specific debugging, but it should not be required for the core Ponder balance/history lookup during this migration.
- If we instead keep active-chain-only Ponder reads, then a separate Celo opening-balance checkpoint or seed is still required.

W9 handling:

- Celo migration distribution transfers must not be counted as paid admin income. Starting Ponder after distribution achieves this.
- During dry runs, also ensure the Celo distributor/migration admin address is not accidentally configured as `PAID_ADMIN_ADDRESSES` while distribution events are being indexed.
- Cross-chain W9 totals are likely the desired tax behavior for a same-user, same-wallet, same-year migration. Chain-filtered W9 totals can undercount a user who earned on Berachain before cutover and Celo after cutover in the same tax year.

## Preservation Options

Preferred low-risk option:

- Keep old Berachain Ponder DB read-only as `ponder_berachain`.
- Launch a Celo Ponder DB as active.
- Backend routes transaction queries to a chain-specific Ponder DB using `chain_id`.
- Missing `chain_id` defaults to Berachain only for legacy clients until a sunset date.

Alternate option:

- Add `chain_id` and `contract_address` to existing Ponder tables.
- Backfill current rows with `80094` and the Berachain SFLUV token.
- Change primary keys/indexes to include chain identity, then index Celo in the same DB.

## Required Schema Direction

Use `(chain_id, tx_hash)` at minimum. For indexed events, prefer `(chain_id, tx_hash, log_index)` or Ponder event id plus chain id.

Add or carry `chain_id` through:

- frontend transaction types
- backend Ponder structs
- memo authorization and storage
- W9 request/totals
- Ponder hooks
- transfer events/accounts
- onchain confirmation jobs
- bot/redeemer/minter tx storage, verification, and logs
- workflow payout and manager payout tx metadata
- unwrap and account-deletion balance/transaction checks where tx hashes are stored or reported

## Boot Backfill Requirement

Every service that owns transaction storage must run an idempotent startup migration before processing new events:

1. Read the active chain id from current backend config/env.
2. Ensure transaction-bearing tables have a nullable `chain_id` column before constraints are tightened.
3. Backfill only untagged rows (`chain_id IS NULL` or missing during migration) to the active chain id.
4. Leave already-tagged rows untouched, even if they differ from the current active chain.
5. Log the active chain id, table name, and updated row count so operators can verify the migration.
6. After backfill, new writes must provide `chain_id`; later migrations may add not-null constraints and `(chain_id, tx_hash)` indexes.

For backwards compatibility, legacy clients that omit `chain_id` should default to Berachain only where that preserves old behavior.
