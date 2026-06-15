# SFLuv Berachain → Celo Migration Checklist

Operator runbook for the full cutover. Work top to bottom. Every box must be
checked (or consciously skipped with a note) before moving to the next phase.
Detailed rationale lives in
[celo-migration-skill/references/](celo-migration-skill/references/); this file
is the executable sequence.

**Golden rules**
- Do not run any broadcasting / DB-mutating step until Phase 0–3 are fully green.
- The backend stays **shut down** for the entire window (Phase 4 onward until cutover).
- The Berachain backing sweep (`SweepBeraBacking`) is the **point of no return** — it runs last, manually, only after Celo is verified.
- Never restart the old Berachain Ponder against the normalized DB.
- Rerun `run-migration.sh` with the **same `--id`** to resume; never start a fresh id mid-migration.

---

## Phase 0 — Preconditions (days before, reversible)

### Clients & comms
- [ ] Preliminary mobile release live with backend `/config` + `/client-version` and a force-update/maintenance screen.
- [ ] Mobile adoption high enough to enforce `minimum` build.
- [ ] Web app consuming backend `/config` as chain authority.
- [ ] Citizen Wallet same-alias config flip tested (or new alias decided).
- [ ] User + internal comms scheduled; support playbook ready.

### Decisions confirmed
- [ ] Celo SFLUV decimals = **6**, backing = **native USDC** (`0xcebA9300f2b948710d2653dD7B07f33A8B32118C`).
- [ ] `DEFAULT_ADMIN_ROLE` (governance) holder for Celo SFLUV decided.
- [ ] Treasury/safe address for the Berachain backing sweep decided.
- [ ] Backend faucet/bot address (and any other service accounts) identified for `MIGRATION_EXTRA_FUNDED_ADDRESSES`.

### Tooling
- [ ] `node`, `psql`, `pg_dump`, `forge`, `cast` installed and on PATH.
- [ ] Submodules materialized: `git submodule update --init --recursive`.
- [ ] Contracts deps present: `repos/contracts/lib/forge-std/src/Script.sol` exists.

---

## Phase 1 — Deploy Celo SFLUV v3 (reversible)

Deploy the new token **before** the migration run; `run-migration.sh` only
distributes into an existing proxy.

- [ ] Fund the v3 deployer EOA with CELO for gas.
- [ ] Run the deploy:
  ```bash
  cd repos/contracts
  GOVERNANCE=<celo-admin-address> \
  BACKING_TOKEN=0xcebA9300f2b948710d2653dD7B07f33A8B32118C \
  forge script script/DeploySFLUVv3.s.sol:DeploySFLUVv3 \
    --rpc-url https://forno.celo.org \
    --private-key $DEPLOYER_KEY --broadcast
  ```
- [ ] Record the **SFLUVv3 UUPS proxy** address from the output → this becomes `NEW_TOKEN`.
- [ ] Verify `decimals() == 6` and `underlying() == <Celo USDC>` on the proxy.
- [ ] Grant the distributor `MINTER_ROLE` on the v3 proxy (distributor address = `cast wallet address --private-key $DISTRIBUTOR_PRIVATE_KEY`).
- [ ] Distributor holds enough **native USDC** to cover total distribution (all wallets + extra funded addresses).
- [ ] Distributor has approved the v3 proxy to spend that USDC (`allowance(distributor, v3) >= total`).
- [ ] Distributor and wallet-deployer EOAs funded with CELO for gas.

---

## Phase 2 — Configure environment (`.env` in repo root)

Copy `example.env` → `.env` and fill every value. `x` placeholders must be replaced.

### Required by `run-migration.sh`
- [ ] `OLD_CHAIN_RPC` = `https://rpc.berachain.com`
- [ ] `NEW_CHAIN_RPC` = `https://forno.celo.org`
- [ ] `OLD_TOKEN` = `0x881cad4f885c6701d8481c0ed347f6d35444ea7e`
- [ ] `NEW_TOKEN` = **Celo v3 proxy from Phase 1**
- [ ] `MIGRATION_DB_CONNECTION_STRING` = postgres URL (the suffix DBs hang off this)
- [ ] `MIGRATION_DB_PONDER_SUFFIX` = `migration_ponder` (the working Ponder DB — see Phase 4)
- [ ] `MIGRATION_DB_APP_SUFFIX` = `migration_app`
- [ ] `CONTRACT_DEPLOYER_PRIVATE_KEY` = holds `DEFAULT_ADMIN_ROLE` on `OLD_TOKEN` (does the Bera lock upgrade)
- [ ] `WALLET_DEPLOYER_PRIVATE_KEY` = deploys Celo smart wallets (needs CELO gas)
- [ ] `DISTRIBUTOR_PRIVATE_KEY` = holds USDC + `MINTER_ROLE` on `NEW_TOKEN` (needs CELO gas)
- [ ] `ACCOUNT_FACTORY_ADDRESS` = `0x7cC54D54bBFc65d1f0af7ACee5e4042654AF8185`
- [ ] `MIGRATION_EXTRA_FUNDED_ADDRESSES` = faucet/bot address(es), comma-separated, **or** `none`. Must be EOAs. (Required — the run refuses to start if unset.)

### Required by `backfill-bera-history.sh`
- [ ] `MIGRATION_DB_CELO_PONDER_SUFFIX` = `migration_celo_ponder` (dedicated Celo Ponder DB)

### Optional overrides (defaults are correct for this migration)
- [ ] `MIGRATION_DECIMAL_SCALE` (default `1000000000000` = 10^(18−6); preflight asserts it matches token decimals)
- [ ] `SMART_WALLET_BATCH_SIZE` (default `50`; **do not change between a run and its resume**)
- [ ] `MIGRATION_ARTIFACT_ROOT` (default `./migration-artifacts`)
- [ ] `BERA_CHAIN_ID` (backfill, default `80094`)
- [ ] `CELO_PONDER_SCHEMA` (backfill, default `public` — the schema the Celo Ponder app writes to)

---

## Phase 3 — Dry run (no mutations)

`--dry-run` skips all DB mutations and forge `--broadcast`, runs every read-only
audit, and never marks call-trace steps. Safe to run against production DBs.

- [ ] Pick and record a stable run id, e.g. `RUN_ID=celo-cutover-01`.
- [ ] Execute:
  ```bash
  ./run-migration.sh --id "$RUN_ID" --dry-run
  ```
- [ ] **Preflight all green**, in particular:
  - [ ] `Wallets table integrity` — 0 critical rows (check `wallet-integrity.json`; fix any flagged rows and re-run).
  - [ ] `Extra funded addresses` — lists the faucet (or shows `none` intentionally).
  - [ ] DECIMAL_SCALE matches token decimals; underlying decimals match.
  - [ ] Distributor has `MINTER_ROLE`; contract deployer has `DEFAULT_ADMIN_ROLE` on old token.
  - [ ] Distributor USDC balance **and** allowance ≥ remaining distribution total.
  - [ ] All three signer EOAs have gas.
- [ ] Review artifacts in `migration-artifacts/$RUN_ID/`:
  - [ ] `app-wallet-distribution.json` — recipient count + total look right.
  - [ ] `external-holder-balances.json` — these holders will be **dropped** (not migrated); confirm faucet is **not** in here.
  - [ ] `*-normalization-before.json` — remainder/row counts sane.
- [ ] Final go/no-go checklist in [open-questions.md](celo-migration-skill/references/open-questions.md) reviewed.

> Optional but recommended: full end-to-end rehearsal in the tmux harness
> (`migration-test-tmux.sh`) including booting the Celo Ponder on a fresh DB and
> running the backfill, before touching production.

---

## Phase 4 — Freeze Berachain & stop Ponder (manual)

- [ ] Put backend mutation paths into maintenance / **shut the backend down** (sends, redemptions, payouts, merchant activity all stopped).
- [ ] Pause Berachain SFLUV user activity.
- [ ] **Manually verify the Berachain token is paused/locked correctly** — the script does not gate on this.
- [ ] Let Berachain Ponder index through the final paused block.
- [ ] Stop the Berachain Ponder process. **Do not restart it against this DB afterward.**
- [ ] Confirm the working Ponder DB (`MIGRATION_DB_PONDER_SUFFIX`) is the up-to-date copy the migration will read/normalize. Take/confirm a fresh snapshot if needed.

---

## Phase 5 — Migration run (broadcasts + mutates)

Same `--id` as the dry run is fine (the dry run wrote no trace marks). This phase
locks the old token, normalizes the DBs, deploys wallets, and distributes on Celo.

- [ ] Execute (broadcasts on by default):
  ```bash
  ./run-migration.sh --id "$RUN_ID"
  ```
- [ ] Phases complete in order: Preflight → Backups → **Berachain Migration Lock** → Wallet Snapshot → Decimal Normalization → Balance Artifacts (external wipe) → Smart Wallet Deployment → Celo Distribution → Completion.
- [ ] On any failure: fix the cause, re-run with the **same `--id`** (completed steps skip via `call-trace.log`).
- [ ] Verify DB backups exist: `app-db-before.dump`, `ponder-db-before.dump`.
- [ ] Verify `migration-result.json` written; record:
  - [ ] `celo_distribution_complete_block`
  - [ ] `ponder_start_block` (= complete block + 1)
- [ ] Spot-check a few smart wallets: Celo `getAddress(owner, index)` matches the Berachain address (parity already proven, but confirm a sample).
- [ ] Spot-check sample on-chain Celo balances vs `app-wallet-distribution.json`.

---

## Phase 6 — Celo Ponder + history backfill

- [ ] Create the dedicated Celo Ponder database (`MIGRATION_DB_CELO_PONDER_SUFFIX`).
- [ ] Configure the Celo Ponder instance for Celo:
  - [ ] `ponder.config.ts` points at Celo chain/token (⚠️ **currently hardcoded to Berachain — must be parameterized first**).
  - [ ] `PONDER_CHAIN_ID=42220` (indexer reads `context.chain.id`; env is the fallback — a wrong value mis-tags every Celo row).
  - [ ] `PONDER_RPC_URL_1` = Celo RPC.
  - [ ] `PONDER_START_BLOCK` = `ponder_start_block` from `migration-result.json`.
  - [ ] `W9_TRANSACTION_URL`, `PAID_ADMIN_ADDRESSES`, `ADMIN_KEY` set (and the distributor/migration admin is **not** in `PAID_ADMIN_ADDRESSES`).
- [ ] Boot the Celo Ponder instance against the dedicated DB; confirm it creates its tables and indexes forward from the start block.
- [ ] Run the history backfill:
  ```bash
  ./backfill-bera-history.sh --id "$RUN_ID"
  ```
- [ ] Backfill audit (`bera-backfill-audit.json`) shows matching row counts + value totals for all four tables (transfer_event, transfer_account, allowance, approval_event). Script dies on mismatch — investigate if so.

---

## Phase 7 — Cutover (manual)

- [ ] Switch backend `/config` to Celo.
- [ ] Flip backend env: `RPC_URL`, `TOKEN_ID`/token addr, **`TOKEN_DECIMALS` (18 → 6)**, backing asset, paymaster/entrypoint, etc. (Faucet/bot amounts scale by `TOKEN_DECIMALS` at runtime — a missed flip mis-scales every send by 10^12.)
- [ ] Point backend Ponder reads at the Celo Ponder DB.
- [ ] Bring the backend back up.
- [ ] Verify continuity-ledger reads: Ponder-derived balances == Celo on-chain balances.
- [ ] Confirm migration distribution transfers are **absent** from `/transactions` history and W9 yearly totals.
- [ ] Smoke test: web boot, mobile boot, send/receive, redemption, workflow payout, merchant lookup, transaction history.
- [ ] Confirm Citizen Wallet behavior for existing SFLuv users.
- [ ] Monitor errors, support channels, backend logs.

> **Rollback boundary:** up to here, rollback = switch backend config back to
> Berachain and pause Celo actions. After Phase 8 it is not practical.

---

## Phase 8 — Berachain deprecation (point of no return)

Only after Phase 7 is fully verified on web, new mobile, old-mobile behavior, and Citizen Wallet.

- [ ] Confirm Berachain SFLUV was upgraded to `SFLUVBeraWipe` (done in Phase 5 lock; if deferred, run `UpgradeToBeraWipe` now).
- [ ] Run the backing sweep:
  ```bash
  cd repos/contracts
  SFLUV_V2_PROXY=0x881cad4f885c6701d8481c0ed347f6d35444ea7e \
  TREASURY=<treasury-safe-address> \
  forge script script/SweepBeraBacking.s.sol:SweepBeraBacking \
    --rpc-url https://rpc.berachain.com \
    --private-key $CONTRACT_DEPLOYER_PRIVATE_KEY --broadcast
  ```
- [ ] Confirm `BackingSwept` event; underlying ERC20 now in treasury.
- [ ] Confirm user-facing Berachain token methods revert with `SFLuv has migrated to CELO.`
- [ ] Leave old Berachain Ponder DB as a **read-only** archive.

---

## Post-migration verification

- [ ] Celo SFLUV total supply == sum of distributed allocation.
- [ ] Backing (USDC) balance ≥ distributed supply.
- [ ] `DEFAULT_ADMIN_ROLE`, `MINTER_ROLE`, `REDEEMER_ROLE` holders correct on Celo.
- [ ] Faucet (and any extra funded addresses) hold their expected Celo balances.
- [ ] Random sample of user EOAs/smart wallets: addresses + balances match the Berachain snapshot.
- [ ] Archive the full `migration-artifacts/$RUN_ID/` directory somewhere durable.

---

## Quick reference — scripts

| Script | Phase | What it does |
| --- | --- | --- |
| `repos/contracts/script/DeploySFLUVv3.s.sol` | 1 | Deploy Celo v3 proxy (→ `NEW_TOKEN`) |
| `run-migration.sh --id <id> --dry-run` | 3 | Read-only audit, no mutations |
| `run-migration.sh --id <id>` | 5 | Lock Bera, normalize, deploy wallets, distribute |
| `backfill-bera-history.sh --id <id>` | 6 | Copy normalized Bera history into Celo Ponder DB |
| `repos/contracts/script/SweepBeraBacking.s.sol` | 8 | Irreversible backing sweep to treasury |

## Quick reference — addresses

| What | Value |
| --- | --- |
| Account factory (both chains) | `0x7cC54D54bBFc65d1f0af7ACee5e4042654AF8185` |
| Berachain SFLUV (OLD_TOKEN) | `0x881cad4f885c6701d8481c0ed347f6d35444ea7e` |
| Celo native USDC (backing) | `0xcebA9300f2b948710d2653dD7B07f33A8B32118C` |
| Berachain chain id | `80094` |
| Celo chain id | `42220` |
