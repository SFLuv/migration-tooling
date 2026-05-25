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
