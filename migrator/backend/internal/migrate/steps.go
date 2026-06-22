package migrate

// buildSteps defines the ordered migration steps, mirroring run-migration.sh.
// The "configuration" step is handled by the config endpoints, not here; these
// are the executable phases, each gated on the previous one succeeding.
func buildSteps() []*Step {
	return []*Step{
		{
			ID:          "preflight",
			Name:        "Preflight checks",
			Description: "Validate RPCs, databases, token decimals, roles, gas balances, and that the distributor holds enough backing token for the full distribution. Read-only.",
			ConfigKeys: []string{
				"OLD_CHAIN_RPC", "NEW_CHAIN_RPC", "OLD_TOKEN", "NEW_TOKEN",
				"MIGRATION_DB_CONNECTION_STRING", "MIGRATION_DB_APP_SUFFIX", "MIGRATION_DB_PONDER_SUFFIX", "MIGRATION_DB_BOT_SUFFIX",
				"CONTRACT_DEPLOYER_PRIVATE_KEY", "WALLET_DEPLOYER_PRIVATE_KEY", "DISTRIBUTOR_PRIVATE_KEY",
				"ACCOUNT_FACTORY_ADDRESS", "MIGRATION_EXTRA_FUNDED_ADDRESSES", "MIGRATION_DECIMAL_SCALE",
			},
			Run: runPreflight,
		},
		{
			ID:          "backups",
			Name:        "Database backups",
			Description: "pg_dump the app and Ponder databases to the artifact directory before any mutation.",
			ConfigKeys:  []string{"MIGRATION_DB_CONNECTION_STRING", "MIGRATION_DB_APP_SUFFIX", "MIGRATION_DB_PONDER_SUFFIX", "MIGRATION_ARTIFACT_ROOT"},
			Run:         runBackups,
		},
		{
			ID:          "lock",
			Name:        "Berachain migration lock",
			Description: "Upgrade the old SFLUV token to the write-locking SFLUVBeraWipe implementation (reversible; does not sweep backing).",
			ConfigKeys:  []string{"OLD_CHAIN_RPC", "OLD_TOKEN", "CONTRACT_DEPLOYER_PRIVATE_KEY", "CONTRACTS_DIR", "MIGRATION_BROADCAST"},
			Run:         runBeraLock,
		},
		{
			ID:          "snapshot",
			Name:        "Wallet snapshot",
			Description: "Snapshot all wallets-table addresses and smart-wallet deploy inputs from the app DB to immutable artifacts.",
			ConfigKeys:  []string{"MIGRATION_DB_CONNECTION_STRING", "MIGRATION_DB_APP_SUFFIX", "MIGRATION_EXTRA_FUNDED_ADDRESSES", "MIGRATION_ARTIFACT_ROOT"},
			Run:         runWalletSnapshot,
		},
		{
			ID:          "normalize-app",
			Name:        "Normalize app W9 totals",
			Description: "Divide retained app W9 earnings from 18-decimal to 6-decimal units (once, marker-guarded). Skipped on dry run.",
			ConfigKeys:  []string{"MIGRATION_DB_CONNECTION_STRING", "MIGRATION_DB_APP_SUFFIX", "MIGRATION_DECIMAL_SCALE", "MIGRATION_BROADCAST", "MIGRATION_ARTIFACT_ROOT"},
			Run:         runNormalizeApp,
		},
		{
			ID:          "normalize-ponder",
			Name:        "Normalize Ponder values",
			Description: "Divide Ponder transfer/allowance amounts to 6-decimal units, recompute transfer_account balances (clamped ≥0), and clear reorg logs. Skipped on dry run.",
			ConfigKeys:  []string{"MIGRATION_DB_CONNECTION_STRING", "MIGRATION_DB_PONDER_SUFFIX", "MIGRATION_DECIMAL_SCALE", "MIGRATION_BROADCAST", "MIGRATION_ARTIFACT_ROOT"},
			Run:         runNormalizePonder,
		},
		{
			ID:          "artifacts",
			Name:        "Balance artifacts & external wipe",
			Description: "Write app distribution and external-holder balance artifacts from transfer events; on a real run, delete non-app transfer_account rows (atomic with the wipe marker).",
			ConfigKeys:  []string{"MIGRATION_DB_CONNECTION_STRING", "MIGRATION_DB_PONDER_SUFFIX", "MIGRATION_EXTRA_FUNDED_ADDRESSES", "MIGRATION_DECIMAL_SCALE", "MIGRATION_ARTIFACT_ROOT", "MIGRATION_BROADCAST"},
			Run:         runBalanceArtifacts,
		},
		{
			ID:          "recovery",
			Name:        "Seed recovery balances",
			Description: "Seed recovery_balances in the bot DB from the external-holder artifact so non-migrated (Citizen Wallet) holders can claim post-migration. Skipped on dry run.",
			ConfigKeys:  []string{"MIGRATION_DB_CONNECTION_STRING", "MIGRATION_DB_BOT_SUFFIX", "OLD_CHAIN_RPC", "MIGRATION_ARTIFACT_ROOT", "MIGRATION_BROADCAST"},
			Run:         runSeedRecovery,
		},
		{
			ID:          "deploy",
			Name:        "Deploy Celo smart wallets",
			Description: "Deploy each non-deployed smart wallet on Celo via the account factory, in bounded batches, verifying each address matches the expected CREATE2 address.",
			ConfigKeys:  []string{"NEW_CHAIN_RPC", "ACCOUNT_FACTORY_ADDRESS", "WALLET_DEPLOYER_PRIVATE_KEY", "SMART_WALLET_BATCH_SIZE", "CONTRACTS_DIR", "MIGRATION_ARTIFACT_ROOT", "MIGRATION_BROADCAST"},
			Run:         runDeploySmartWallets,
		},
		{
			ID:          "distribute",
			Name:        "Distribute Celo balances",
			Description: "Mint/deposit each holder's exact balance on Celo SFLUV via depositFor (idempotent: only the remaining delta per address is sent).",
			ConfigKeys:  []string{"NEW_CHAIN_RPC", "NEW_TOKEN", "DISTRIBUTOR_PRIVATE_KEY", "CONTRACTS_DIR", "MIGRATION_ARTIFACT_ROOT", "MIGRATION_BROADCAST"},
			Run:         runDistribute,
		},
		{
			ID:          "completion",
			Name:        "Completion",
			Description: "Resolve the Celo completion block (max of chain head and broadcast receipts) and write the migration result with the Ponder start block.",
			ConfigKeys:  []string{"NEW_CHAIN_RPC", "OLD_TOKEN", "NEW_TOKEN", "MIGRATION_ARTIFACT_ROOT"},
			Run:         runCompletion,
		},
	}
}
