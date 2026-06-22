# SFLuv Migrator

A frontend + backend web app that runs the Berachain → Celo migration as a
guided, manually-stepped process. It mirrors `run-migration.sh`: every phase of
the script is a backend route and a stepper step, gated so a step can only run
after the previous one succeeds.

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
   masked, never echoed), and override/fill any value. The migration is blocked
   until all required settings are present.
2. **Preflight** — read-only: RPC reachability, app/ponder/bot DB connectivity,
   token decimals + `DECIMAL_SCALE`, underlying backing decimals, distributor
   `MINTER_ROLE` + deployer `DEFAULT_ADMIN_ROLE`, **gas balances for all three
   signers**, **distributor backing balance + allowance ≥ the full projected
   distribution total**, and wallet-table integrity.
3. **Database backups** — `pg_dump` app + ponder.
4. **Berachain migration lock** — upgrade old token to `SFLUVBeraWipe`.
5. **Wallet snapshot** — smart-wallet deploy input + snapshot.
6. **Normalize app W9 totals** — 18→6 decimals (marker-guarded).
7. **Normalize Ponder values** — 18→6, recompute `transfer_account` (clamped ≥0),
   clear reorg logs.
8. **Balance artifacts & external wipe** — app/external balance artifacts; on a
   real run, delete non-app `transfer_account` rows (atomic with the wipe marker).
9. **Seed recovery balances** — populate `recovery_balances` (bot DB) for
   non-migrated holders.
10. **Deploy Celo smart wallets** — batched `DeploySmartWalletBatch`.
11. **Distribute Celo balances** — `DistributeBatch` (`depositFor`).
12. **Completion** — resolve the completion block and write `migration-result.json`.

`MIGRATION_BROADCAST=false` makes it a dry run: forge runs without `--broadcast`
and DB-mutating steps are skipped (artifacts/preflight still run).

## Running

Requires `forge`, `cast`, `pg_dump`, and a reachable postgres.

```bash
# backend (defaults to :8090; reads the same env as run-migration.sh + CONTRACTS_DIR)
cd backend && go run ./cmd/server

# frontend (defaults to :3001; talks to http://localhost:8090)
cd frontend && npm install && npm run dev
```

Override the API base with `NEXT_PUBLIC_API_BASE`, the backend port with
`MIGRATOR_PORT`, and load a specific env file with `ENV_FILE`.
