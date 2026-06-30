# SFLuv Berachain → Celo Migration Checklist

Operator runbook for the full cutover. Work top to bottom. Every box must be
checked (or consciously skipped with a note) before moving to the next phase.
Detailed rationale lives in
[celo-migration-skill/references/](celo-migration-skill/references/); this file
is the executable sequence.

**The on-chain + DB migration runs through the [migrator web app](migrator/README.md)**
(Go backend + Next.js stepper), not the standalone shell scripts. The migrator is
a gated, manually-stepped UI over the same phases, with live logs, per-run
artifacts, a dry-run toggle, and resume-by-run-id. The old `run-migration.sh` /
`backfill-bera-history.sh` still exist as a CLI reference but have **diverged**
(they normalize the legacy Ponder in place and wipe external rows; the migrator
does neither) — use the migrator. Phases 1, 2, 4, 7, and 8 are still manual /
`forge`-script work as noted.

**Golden rules**
- Do not run any broadcasting / DB-mutating step until Phase 0–3 are fully green.
- The backend stays **shut down** for the entire window (Phase 4 onward until cutover).
- The Berachain backing sweep (`SweepBeraBacking`) is the **point of no return** — it runs last, manually, only after Celo is verified.
- The legacy Berachain Ponder is **read-only**: never mutate or re-normalize it, and never restart it against a mutated DB. Normalization happens only during the backfill copy into the dedicated Celo Ponder DB.
- Use the **same run id** to resume (migrator `--id` / `MIGRATION_RUN_ID`, or the run-id chip in the UI); never start a fresh id mid-migration. Completed real-run steps fast-forward; dry runs never record completion.

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

Copy `example.env` → `.env` and fill every value. `x` placeholders must be
replaced. The migrator backend loads the **same `.env`** as the scripts (walk-up
from the working dir, or `ENV_FILE`/`ROOT_ENV`), and the Configuration step shows
every value (secrets masked) so you can confirm/override before running.

### Required
- [ ] `OLD_CHAIN_RPC` = `https://rpc.berachain.com`
- [ ] `NEW_CHAIN_RPC` = `https://forno.celo.org`
- [ ] `OLD_TOKEN` = `0x881cad4f885c6701d8481c0ed347f6d35444ea7e`
- [ ] `NEW_TOKEN` = **Celo v3 proxy from Phase 1**
- [ ] `MIGRATION_DB_CONNECTION_STRING` = postgres URL (the suffix DBs hang off this)
- [ ] `MIGRATION_DB_PONDER_SUFFIX` = `migration_ponder` (the legacy Ponder DB, read-only — see Phase 4)
- [ ] `MIGRATION_DB_APP_SUFFIX` = `migration_app`
- [ ] `MIGRATION_DB_BOT_SUFFIX` = `migration_bot` (recovery balances)
- [ ] `CONTRACT_DEPLOYER_PRIVATE_KEY` = holds `DEFAULT_ADMIN_ROLE` on `OLD_TOKEN` (does the Bera lock upgrade)
- [ ] `WALLET_DEPLOYER_PRIVATE_KEY` = deploys Celo smart wallets (needs CELO gas)
- [ ] `DISTRIBUTOR_PRIVATE_KEY` = holds USDC + `MINTER_ROLE` on `NEW_TOKEN` (needs CELO gas)
- [ ] `CELO_ADMIN_PRIVATE_KEY` = Celo SFLUV admin (`DEFAULT_ADMIN`, or `MINTER_ADMIN`+`REDEEMER_ADMIN`); signs the MINTER/REDEEMER role replication (needs CELO gas)
- [ ] `ACCOUNT_FACTORY_ADDRESS` = `0x7cC54D54bBFc65d1f0af7ACee5e4042654AF8185`
- [ ] `MIGRATION_EXTRA_FUNDED_ADDRESSES` = faucet/bot address(es), comma-separated, **or** `none`. Must be EOAs. (Required — the run refuses to start if unset.)
- [ ] `MIGRATION_DB_CELO_PONDER_SUFFIX` = `migration_celo_ponder` (dedicated Celo Ponder DB — backfill target, Phase 6)

### Optional overrides (defaults are correct for this migration)
- [ ] `MIGRATION_DECIMAL_SCALE` (default `1000000000000` = 10^(18−6); preflight asserts it matches token decimals)
- [ ] `SMART_WALLET_BATCH_SIZE` (default `50`; **do not change between a run and its resume**)
- [ ] `MIGRATION_ARTIFACT_ROOT` (default `./migration-artifacts`)
- [ ] `BERA_CHAIN_ID` (default `80094`) / `NEW_CHAIN_ID` (default `42220`)
- [ ] `CELO_PONDER_SCHEMA` (backfill, default `public` — the schema the Celo Ponder app writes to)
- [ ] `REDEEMER_PRIVATE_KEY` (backing-recovery check unwrap signer; defaults to the distributor, which must then hold `REDEEMER_ROLE`)
- [ ] `WRAP_CHECK_AMOUNT` (default `1` underlying base unit for the backing-recovery check)

---

## Phase 3 — Dry run (no mutations)

A dry run skips all DB mutations and forge `--broadcast`, runs every read-only
audit (preflight, artifacts, the backing-recovery simulation, role detection),
and never records step completion. Safe to run against production DBs.

- [ ] Pick and record a stable run id, e.g. `celo-cutover-01`.
- [ ] Start the migrator backend + frontend (see [migrator/README.md](migrator/README.md)):
  ```bash
  cd migrator/backend && go run ./cmd/server --id celo-cutover-01
  cd migrator/frontend && npm install && npm run dev
  ```
  In the Configuration step, **enable the dry-run toggle** (sets `MIGRATION_BROADCAST=false`).
  CLI equivalent (legacy): `./run-migration.sh --id celo-cutover-01 --dry-run`.
- [ ] Step through every read-only step in order; **Preflight all green**, in particular:
  - [ ] `Wallets table integrity` — 0 critical rows (check `wallet-integrity.json`; fix any flagged rows and re-run).
  - [ ] `Extra funded addresses` — lists the faucet (or shows `none` intentionally).
  - [ ] DECIMAL_SCALE matches token decimals; underlying decimals match.
  - [ ] Distributor has `MINTER_ROLE`; contract deployer has `DEFAULT_ADMIN_ROLE` on old token.
  - [ ] Distributor USDC balance **and** allowance ≥ remaining distribution total.
  - [ ] All three signer EOAs have gas.
- [ ] Review artifacts in `migration-artifacts/<run-id>/`:
  - [ ] `app-wallet-distribution.json` — recipient count + total look right.
  - [ ] `external-holder-balances.json` — these holders are **not auto-migrated** to Celo, but are seeded into `recovery_balances` so they can claim later (recovery flow); confirm faucet is **not** in here.
  - [ ] app W9 `*-normalization-before.json` — remainder/row counts sane (app DB only; the legacy Ponder is not normalized in place).
  - [ ] `migrator.log` — the per-run log, for any warnings.
- [ ] Final go/no-go checklist in [open-questions.md](celo-migration-skill/references/open-questions.md) reviewed.

> Optional but recommended: full end-to-end rehearsal in the **local test
> harness** (`migration-test-tmux.sh`) including booting the Celo Ponder on a
> fresh DB and running the backfill, before touching production.
>
> **The tmux harness is for local testing only — it is never used in the real
> production run.** It clones production databases into local copies and stands up
> anvil forks of Berachain and Celo (and, for testing, deals fake backing and
> storage-pranks the migration roles to the anvil key). The live migration runs
> the migrator against the real chains and real databases; the harness plays no
> part in it.

---

## Phase 4 — Freeze Berachain & stop Ponder (manual)

- [ ] Put backend mutation paths into maintenance / **shut the backend down** (sends, redemptions, payouts, merchant activity all stopped).
- [ ] Pause Berachain SFLUV user activity.
- [ ] **Manually verify the Berachain token is paused/locked correctly** — the script does not gate on this.
- [ ] Let Berachain Ponder index through the final paused block.
- [ ] Stop the Berachain Ponder process. **Do not restart it against this DB afterward.**
- [ ] Confirm the legacy Ponder DB (`MIGRATION_DB_PONDER_SUFFIX`) is the up-to-date copy the migration will read. The migrator only **reads** it (no in-place normalization); take/confirm a fresh snapshot if needed.

---

## Phase 5 — Migration run (broadcasts + mutates)

Reuse the **same run id** as the dry run (dry runs record no completion). Turn the
dry-run toggle **off** in Configuration. This phase locks the old token,
normalizes app W9 totals, deploys wallets, runs the backing-recovery check,
distributes on Celo, and replicates roles. The legacy Ponder is read-only — its
history is copied (normalized) into the Celo Ponder DB in Phase 6, not here.

- [ ] Step through the migrator with broadcasts on (dry-run toggle off). Steps run in order, each gated on the previous:
  Preflight → Database backups → **Berachain migration lock** → Wallet snapshot → Normalize app W9 totals → Balance artifacts (read-only) → Seed recovery balances → Deploy Celo smart wallets → **Backing recovery check** (wrap/unwrap simulation) → Distribute Celo balances → **Replicate MINTER/REDEEMER roles** → Completion.
  CLI equivalent (legacy, diverged — no recovery check / role replication, and it normalizes + wipes the legacy Ponder): `./run-migration.sh --id <run-id>`.
- [ ] On any failure: fix the cause and re-run/continue with the **same run id** (completed real-run steps fast-forward).
- [ ] **Backing recovery check** passed ("backing is recoverable") before distribution proceeded.
- [ ] Verify DB backups exist: `app-db-before.dump`, `ponder-db-before.dump`.
- [ ] **Role replication**: review `bera-roles.json` (detected MINTER/REDEEMER holders) and confirm the grants on Celo (`MINTER/REDEEMER granted N of N`).
- [ ] Verify `migration-result.json` written; record:
  - [ ] `celo_distribution_complete_block`
  - [ ] `ponder_start_block` (= complete block + 1)
- [ ] Spot-check a few smart wallets: Celo `getAddress(owner, index)` matches the Berachain address (parity already proven, but confirm a sample).
- [ ] Spot-check sample on-chain Celo balances vs `app-wallet-distribution.json`.

---

## Phase 6 — Celo Ponder + history backfill

The migrator's final **Backfill** step copies the legacy Berachain Ponder history
(normalizing 18→6 on the way) into the dedicated Celo Ponder DB, which becomes the
single cross-chain continuity ledger. The step shows a warning + **copyable
snippets** for everything below. **Boot the Celo Ponder instance before running
the Backfill step** (Ponder must create its tables first).

- [ ] From the Backfill step, copy the ready `ponder.config.ts` into `repos/app/ponder/ponder.config.ts` (already pointed at Celo chain/token/start block — no hand-editing).
- [ ] Copy + run the start snippet. It **creates the `MIGRATION_DB_CELO_PONDER_SUFFIX` database if missing** (Ponder connects to an existing DB; it does not create databases), then boots Ponder with `DATABASE_URL`/`DATABASE_SCHEMA`, `PONDER_RPC_URL_1`=Celo RPC, `PONDER_CHAIN_ID=42220`, `PONDER_START_BLOCK`=`ponder_start_block`. (`psql` must be on PATH; otherwise `createdb` the DB by hand once.)
  - [ ] Confirm `W9_TRANSACTION_URL`, `PAID_ADMIN_ADDRESSES`, `ADMIN_KEY` set, and the distributor/migration admin is **not** in `PAID_ADMIN_ADDRESSES`.
- [ ] Confirm Ponder boots, creates its tables, and indexes forward from the start block (historical sync can take several minutes before it serves).
- [ ] Run the migrator's **Backfill** step (CLI equivalent, legacy: `./backfill-bera-history.sh --id <run-id>`).
- [ ] Backfill audit (`bera-backfill-audit.json`) shows matching row counts + value totals for all four tables (transfer_event, transfer_account, allowance, approval_event) and that `ponder_hooks` registrations were migrated. The step fails on mismatch — investigate if so.

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
- [ ] Archive the full `migration-artifacts/<run-id>/` directory (artifacts + `migrator.log`) somewhere durable.

---

## Quick reference — what runs each phase

| Tool | Phase | What it does |
| --- | --- | --- |
| `repos/contracts/script/DeploySFLUVv3.s.sol` (manual `forge`) | 1 | Deploy Celo v3 proxy (→ `NEW_TOKEN`) |
| **Migrator** (dry-run toggle on) | 3 | Read-only audit, no mutations |
| **Migrator** (broadcasts on) | 5 | Lock Bera, normalize app W9, deploy wallets, backing-recovery check, distribute, replicate roles, completion |
| **Migrator** — Backfill step | 6 | Copy normalized Bera history into the dedicated Celo Ponder DB |
| `repos/contracts/script/SweepBeraBacking.s.sol` (manual `forge`) | 8 | Irreversible backing sweep to treasury |

> Legacy CLI (diverged — see [migrator/README.md](migrator/README.md#relationship-to-the-old-scripts)):
> `run-migration.sh --id <id> [--dry-run]` covers Phases 3/5 and
> `backfill-bera-history.sh --id <id>` covers Phase 6, but they still normalize +
> wipe the legacy Ponder and lack the backing-recovery and role-replication steps.
> Prefer the migrator.

## Quick reference — addresses

| What | Value |
| --- | --- |
| Account factory (both chains) | `0x7cC54D54bBFc65d1f0af7ACee5e4042654AF8185` |
| Berachain SFLUV (OLD_TOKEN) | `0x881cad4f885c6701d8481c0ed347f6d35444ea7e` |
| Celo native USDC (backing) | `0xcebA9300f2b948710d2653dD7B07f33A8B32118C` |
| Berachain chain id | `80094` |
| Celo chain id | `42220` |
