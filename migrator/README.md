# SFLuv Migrator

A frontend + backend web app that runs the Berachain → Celo migration as a
guided, manually-stepped process. **This is the tool we run for the live
migration** — it supersedes the standalone `run-migration.sh` /
`backfill-bera-history.sh` scripts, which remain in the tree as a CLI reference
but have diverged (they still normalize the legacy Ponder in place and wipe
external rows; the migrator does neither — see "Relationship to the old scripts"
below). Every migration phase is a backend route and a stepper step, gated so a
step can only run after the previous one succeeds.

The migrator is **stateful in memory** — loaded config (incl. private keys) and
per-step status/logs/live-data live in the backend process only. Postgres is
connected to (via pgx) only by the steps that read or write the migration
databases. Chain operations shell out to `forge`/`cast`; backups to `pg_dump`.

## Structure (mirrors the `app` repo)

```
migrator/
  backend/                  Go service
    cmd/server/             entrypoint
    internal/config/        config registry + in-memory store
    internal/runner/        forge/cast/pg_dump command runner (streams logs)
    internal/migrate/       step engine, preflight, chain + DB step impls
    internal/api/           chi HTTP router
  frontend/                 Next.js stepper UI (config + steps, live logs/data)
```

## Steps (in order)

1. **Configuration** — load every setting from the environment, show it (secrets
   masked, never echoed), and override/fill any value (including the dry-run
   toggle). The migration is blocked until all required settings are present.
2. **Preflight** — read-only: RPC reachability, app/ponder/bot DB connectivity,
   token decimals + `DECIMAL_SCALE`, underlying backing decimals, distributor
   `MINTER_ROLE` + deployer `DEFAULT_ADMIN_ROLE`, **gas balances for all three
   signers**, **distributor backing balance + allowance ≥ the full projected
   distribution total**, and wallet-table integrity.
3. **Database backups** — `pg_dump` app + ponder.
4. **Berachain migration lock** — upgrade old token to `SFLUVBeraWipe`.
5. **Wallet snapshot** — smart-wallet deploy input + snapshot.
6. **Normalize app W9 totals** — 18→6 decimals in the app DB (marker-guarded).
   Skipped on dry run.
7. **Balance artifacts** — **read-only**: derive the app-wallet distribution and
   external-holder balance artifacts from the legacy Ponder transfer events,
   normalizing 18→6 on the fly. The legacy Ponder DB is **never mutated** (no
   in-place normalization, no external wipe).
8. **Seed recovery balances** — populate `recovery_balances` (bot DB) for
   non-migrated (external/Citizen Wallet) holders. Skipped on dry run.
9. **Deploy Celo smart wallets** — batched `DeploySmartWalletBatch`, with a
   progress indicator.
10. **Backing recovery check** — simulate wrapping a tiny amount of backing into
    Celo SFLUV and immediately unwrapping it, proving the backing can be locked
    AND recovered before minting anything. **Always a dry-run simulation against
    a fork of the live chain (never broadcasts)**; aborts the migration if the
    roundtrip would fail.
11. **Distribute Celo balances** — batched `DistributeBatch` (`depositFor`), with
    a progress indicator; idempotent (only the remaining delta per address).
12. **Replicate MINTER/REDEEMER roles** — scan all Berachain SFLUV holders (plus
    the funded service accounts), detect who holds `MINTER_ROLE`/`REDEEMER_ROLE`
    on the old token, and grant the same on Celo SFLUV using
    `CELO_ADMIN_PRIVATE_KEY`. Detection runs even on a dry run; the grant is
    skipped on dry run.
13. **Completion** — resolve the completion block and write `migration-result.json`.
14. **Backfill Celo Ponder history** — copy the Berachain Ponder history into the
    dedicated Celo Ponder DB (`MIGRATION_DB_CELO_PONDER_SUFFIX`), normalizing
    18→6 **during the copy**, so it becomes the cross-chain continuity ledger.
    The step shows a prominent warning + copyable snippets to **start the new
    Celo Ponder instance at the resolved Ponder start block, pointing at that DB,
    before running it** (Ponder must create its tables first); the start snippet
    also creates the Celo Ponder database if it doesn't exist. `transfer_account`
    is rebuilt from the app distribution (app + funded only; external holders
    excluded) and the custom `ponder_hooks` registrations are migrated too.
    Idempotent; verifies per-table counts and value totals. Skipped on dry run.

The dry-run toggle (config) sets `MIGRATION_BROADCAST=false`: forge runs without
`--broadcast` and DB-mutating steps are skipped (configuration, preflight,
artifacts, the backing-recovery simulation, and role detection still run).

Artifacts (and the per-run log `migrator.log`) are written to
`MIGRATION_ARTIFACT_ROOT/<id>`. The forge steps exchange JSON with the migrator
through those files, so `repos/contracts/foundry.toml` grants `fs_permissions`
read-write to the repo tree (`../../`). Keep `MIGRATION_ARTIFACT_ROOT` inside the
`migration-tooling` tree (the default) or widen that path if you relocate it,
otherwise forge reports `vm.readFile: the path … is not allowed`.

Preflight blocks the migration until gas is present for every signer on **both
chains** and the distributor's Celo backing balance **and** allowance cover the
full Berachain SFLUV total supply converted to new-token units (the 18→6 decimal
difference is applied via `MIGRATION_DECIMAL_SCALE`).

### Config keys beyond `run-migration.sh`

In addition to everything `run-migration.sh` reads, the migrator uses:

- `CELO_ADMIN_PRIVATE_KEY` (secret) — Celo SFLUV admin (`DEFAULT_ADMIN`, or
  `MINTER_ADMIN`+`REDEEMER_ADMIN`); signs the role-replication grants. Needs CELO gas.
- `REDEEMER_PRIVATE_KEY` (secret, optional) — used as the unwrap signer in the
  backing-recovery check; defaults to the distributor (which then must hold
  `REDEEMER_ROLE`).
- `WRAP_CHECK_AMOUNT` (default `1`) — underlying base units wrapped/unwrapped by
  the backing-recovery check.
- `MIGRATION_DB_BOT_SUFFIX` — bot DB (recovery balances).
- `MIGRATION_DB_CELO_PONDER_SUFFIX` / `CELO_PONDER_SCHEMA` — the dedicated Celo
  Ponder database and schema the backfill targets.

### Relationship to the old scripts

The migrator is authoritative for the live migration. The shell scripts predate
the current model and have **diverged**:

- `run-migration.sh` still runs `normalize_ponder` (in-place 18→6 normalization
  of the legacy Ponder) and `balance_artifacts_external_wipe` (deleting external
  `transfer_account` rows). The migrator does **neither** — the legacy Ponder is
  read-only and normalization happens during the backfill copy into the dedicated
  Celo Ponder DB.
- The scripts have no backing-recovery check and no MINTER/REDEEMER role
  replication; the migrator adds both.
- The scripts split the Ponder history copy into a separate
  `backfill-bera-history.sh`; in the migrator it's the final **Backfill** step.

Prefer the migrator. Treat the scripts as a lower-level reference only.

## Running

Requires `forge`, `cast`, `pg_dump`, and a reachable postgres.

```bash
# backend (defaults to :8090)
cd backend && go run ./cmd/server

# resume a previous run: reuse its id and completed steps are fast-forwarded
cd backend && go run ./cmd/server --id 20260623T120000Z

# frontend (defaults to :3001; talks to http://localhost:8090)
cd frontend && npm install && npm run dev
```

The backend loads the **same env file as `run-migration.sh`**: by default the
`.env` beside `run-migration.sh` (the repo root), found by walking up from the
working directory. Override it with `ENV_FILE`, or with `ROOT_ENV` (the script's
own variable) so both tools point at the same file. Values already present in
the process environment take precedence over the file.

Override the API base with `NEXT_PUBLIC_API_BASE` and the backend port with
`MIGRATOR_PORT`.

## Run id & resume

Each run has an id (`--id`, else `MIGRATION_RUN_ID`, else a UTC timestamp). All
of a run's state lives under its artifact directory `MIGRATION_ARTIFACT_ROOT/<id>`:

- **Artifacts** — every snapshot, balance artifact, DB backup, deploy/distribution
  JSON, and the result JSON are written there.
- **Step state** — `<id>/migrator-trace.log` records `ok <step> <ts>` for each
  step completed in a real run. **Starting with the same id fast-forwards those
  steps to done**, so you resume at the next pending step and reuse the prior
  run's artifacts. Like `run-migration.sh`, dry runs never record completion.
- **Config state** — `<id>/migrator-config.json` stores the run's non-secret
  config overrides (e.g. the dry-run toggle), restored on resume. Secrets
  (private keys, DB connection string) are **never** persisted — they always
  come from the environment — and the environment remains authoritative for any
  value you didn't override in the UI.

The current id shows in the top bar and `GET /api/config` (`run_id`).
