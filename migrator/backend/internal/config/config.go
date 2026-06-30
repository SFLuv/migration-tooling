// Package config holds the migrator's in-memory configuration: every setting
// the migration needs (RPCs, token addresses, DB connection, private keys,
// parameters), loaded from the environment and overridable at runtime. Nothing
// here is persisted; the migrator is stateful only in memory.
package config

import (
	"fmt"
	"net/url"
	"os"
	"strings"
	"sync"
)

// Group labels for organizing fields in the configuration UI.
const (
	GroupChain   = "Chain & Tokens"
	GroupDB      = "Databases"
	GroupKeys    = "Signers (private keys)"
	GroupParams  = "Parameters"
	GroupRuntime = "Migrator runtime"
)

// Field describes a single configuration setting.
type Field struct {
	Key      string
	Label    string
	Group    string
	Secret   bool   // mask the value in any response
	Required bool   // must be set before the migration can run
	Default  string // applied when neither env nor an override provides a value
	Purpose  string
}

// Fields is the full configuration registry. Step definitions reference these
// keys so each step can show exactly which settings it uses and why.
var Fields = []Field{
	{Key: "OLD_CHAIN_RPC", Label: "Berachain RPC URL", Group: GroupChain, Required: true, Purpose: "Source chain JSON-RPC for reading balances, the lock upgrade, and the backing sweep."},
	{Key: "NEW_CHAIN_RPC", Label: "Celo RPC URL", Group: GroupChain, Required: true, Purpose: "Target chain JSON-RPC for smart-wallet deployment and distribution."},
	{Key: "OLD_TOKEN", Label: "Berachain SFLUV proxy", Group: GroupChain, Required: true, Purpose: "Old token proxy: decimals, admin role, lock upgrade, and sweep target."},
	{Key: "NEW_TOKEN", Label: "Celo SFLUV proxy", Group: GroupChain, Required: true, Purpose: "New token proxy: decimals, MINTER role, underlying backing, and distribution target."},
	{Key: "BERA_CHAIN_ID", Label: "Berachain chain id", Group: GroupChain, Default: "80094", Purpose: "Chain id tagging the legacy Berachain rows copied into the Celo Ponder DB during backfill."},
	{Key: "NEW_CHAIN_ID", Label: "Celo chain id", Group: GroupChain, Default: "42220", Purpose: "Celo chain id the new Ponder instance indexes; used in the generated Celo Ponder config."},

	{Key: "MIGRATION_DB_CONNECTION_STRING", Label: "Postgres connection string", Group: GroupDB, Secret: true, Required: true, Purpose: "Base postgres URL; the app/ponder/bot databases are derived from it via the suffixes."},
	{Key: "MIGRATION_DB_APP_SUFFIX", Label: "App DB name", Group: GroupDB, Required: true, Default: "migration_app", Purpose: "App database: wallet snapshot and W9 decimal normalization."},
	{Key: "MIGRATION_DB_PONDER_SUFFIX", Label: "Ponder DB name", Group: GroupDB, Required: true, Default: "migration_ponder", Purpose: "Ponder database: balance normalization, recompute, balance artifacts, and external wipe."},
	{Key: "MIGRATION_DB_BOT_SUFFIX", Label: "Bot DB name", Group: GroupDB, Required: true, Default: "migration_bot", Purpose: "Bot database: recovery_balances seeding for non-migrated holders."},
	{Key: "MIGRATION_DB_CELO_PONDER_SUFFIX", Label: "Celo Ponder DB name", Group: GroupDB, Default: "migration_celo_ponder", Purpose: "Dedicated database the new Celo Ponder instance runs against; the Berachain history is backfilled into it for cross-chain continuity."},
	{Key: "CELO_PONDER_SCHEMA", Label: "Celo Ponder schema", Group: GroupDB, Default: "public", Purpose: "Schema the Celo Ponder instance writes its tables to in the Celo Ponder database."},

	{Key: "CONTRACT_DEPLOYER_PRIVATE_KEY", Label: "Contract deployer key", Group: GroupKeys, Secret: true, Required: true, Purpose: "Holds DEFAULT_ADMIN_ROLE on the old token; performs the Berachain lock upgrade (and sweep)."},
	{Key: "WALLET_DEPLOYER_PRIVATE_KEY", Label: "Wallet deployer key", Group: GroupKeys, Secret: true, Required: true, Purpose: "Deploys Celo smart wallets via the account factory; needs CELO gas."},
	{Key: "DISTRIBUTOR_PRIVATE_KEY", Label: "Distributor key", Group: GroupKeys, Secret: true, Required: true, Purpose: "Holds MINTER_ROLE and backing USDC; distributes Celo balances; needs CELO gas."},
	{Key: "CELO_ADMIN_PRIVATE_KEY", Label: "Celo token admin key", Group: GroupKeys, Secret: true, Purpose: "Celo SFLUV admin (DEFAULT_ADMIN, or MINTER_ADMIN+REDEEMER_ADMIN). Used to replicate Berachain MINTER/REDEEMER role holders onto Celo; needs CELO gas."},
	{Key: "REDEEMER_PRIVATE_KEY", Label: "Redeemer key (wrap check)", Group: GroupKeys, Secret: true, Purpose: "Optional REDEEMER on Celo SFLUV used to unwrap during the wrap/unwrap check. If unset, the distributor must also hold REDEEMER_ROLE."},

	{Key: "ACCOUNT_FACTORY_ADDRESS", Label: "Account factory", Group: GroupParams, Required: true, Default: "0x7cC54D54bBFc65d1f0af7ACee5e4042654AF8185", Purpose: "CW account factory used to derive/deploy smart wallets on Celo (must match Berachain)."},
	{Key: "MIGRATION_EXTRA_FUNDED_ADDRESSES", Label: "Extra funded addresses", Group: GroupParams, Required: true, Purpose: "Comma-separated service accounts (e.g. faucet) funded on Celo alongside wallets-table addresses; 'none' to fund only wallets."},
	{Key: "MIGRATION_DECIMAL_SCALE", Label: "Decimal scale (old→new)", Group: GroupParams, Required: true, Default: "1000000000000", Purpose: "10^(old decimals − new decimals); divides legacy 18-decimal values to 6-decimal units. Verified against on-chain decimals in preflight."},
	{Key: "SMART_WALLET_BATCH_SIZE", Label: "Smart wallet batch size", Group: GroupParams, Required: true, Default: "50", Purpose: "Number of smart wallets deployed per forge batch transaction."},
	{Key: "WRAP_CHECK_AMOUNT", Label: "Wrap/unwrap check amount", Group: GroupParams, Default: "1", Purpose: "Backing base units wrapped then unwrapped by the backing-recovery check before distribution."},
	{Key: "TREASURY", Label: "Sweep treasury", Group: GroupParams, Purpose: "Destination safe for the deferred Berachain backing sweep (point of no return)."},

	{Key: "CONTRACTS_DIR", Label: "Contracts repo path", Group: GroupRuntime, Required: true, Default: "../../repos/contracts", Purpose: "Path to the forge contracts repo holding the migration scripts."},
	{Key: "MIGRATION_ARTIFACT_ROOT", Label: "Artifact directory", Group: GroupRuntime, Required: true, Default: "./migration-artifacts", Purpose: "Where snapshots, balance artifacts, backups, and the result JSON are written."},
	{Key: "MIGRATION_BROADCAST", Label: "Broadcast transactions", Group: GroupRuntime, Required: true, Default: "true", Purpose: "true runs forge with --broadcast and applies DB mutations; false is a dry run (read-only)."},
	{Key: "MIGRATION_FORGE_CUPS", Label: "Forge RPC rate limit (CUPS)", Group: GroupRuntime, Purpose: "Optional cap on forge's RPC requests/sec (--compute-units-per-second) for rate-limited providers. Batches always run with --slow (one confirmed tx at a time). Empty uses foundry's default (330)."},
}

func fieldByKey(key string) (Field, bool) {
	for _, f := range Fields {
		if f.Key == key {
			return f, true
		}
	}
	return Field{}, false
}

// Store is the thread-safe in-memory configuration. env holds the values loaded
// from the environment (the authoritative base); values holds runtime overrides
// set via the API. Overrides win over env, which wins over the registry default.
type Store struct {
	mu     sync.RWMutex
	env    map[string]string
	values map[string]string
}

// FieldView is a display-safe projection of a field's current state.
type FieldView struct {
	Key      string `json:"key"`
	Label    string `json:"label"`
	Group    string `json:"group"`
	Secret   bool   `json:"secret"`
	Required bool   `json:"required"`
	Purpose  string `json:"purpose"`
	IsSet    bool   `json:"is_set"`
	Value    string `json:"value"`    // actual value; redacted for secrets
	Redacted bool   `json:"redacted"` // true when Value is a masked secret
}

// redactSecret masks a secret for display: for URLs it keeps everything but the
// password; otherwise it shows the first/last few characters. Lets the operator
// verify which value is set without exposing it.
func redactSecret(v string) string {
	v = strings.TrimSpace(v)
	if v == "" {
		return ""
	}
	if u, err := url.Parse(v); err == nil && u.Scheme != "" && u.Host != "" {
		if u.User != nil {
			if _, hasPw := u.User.Password(); hasPw {
				// Use a letters-only sentinel so url.String() does not percent-encode
				// the mask, then swap it for the display mask.
				const sentinel = "REDACTEDPASSWORD"
				u.User = url.UserPassword(u.User.Username(), sentinel)
				return strings.ReplaceAll(u.String(), sentinel, "••••")
			}
		}
		return u.String()
	}
	if len(v) > 12 {
		return v[:6] + "…" + v[len(v)-4:]
	}
	return "••••"
}

// New loads the registry's keys from the environment (kept as the base) and
// starts with no runtime overrides.
func New() *Store {
	s := &Store{env: map[string]string{}, values: map[string]string{}}
	for _, f := range Fields {
		if v := strings.TrimSpace(os.Getenv(f.Key)); v != "" {
			s.env[f.Key] = v
		}
	}
	return s
}

// Get returns the effective value: a runtime override if set, else the
// environment value, else the registry default.
func (s *Store) Get(key string) string {
	s.mu.RLock()
	v, ok := s.values[key]
	e := s.env[key]
	s.mu.RUnlock()
	if ok && strings.TrimSpace(v) != "" {
		return strings.TrimSpace(v)
	}
	if strings.TrimSpace(e) != "" {
		return strings.TrimSpace(e)
	}
	if f, found := fieldByKey(key); found {
		return f.Default
	}
	return ""
}

// Set overrides a value. An empty value clears the override (falling back to the
// default). Unknown keys are rejected.
func (s *Store) Set(key, value string) error {
	if _, ok := fieldByKey(key); !ok {
		return fmt.Errorf("unknown config key %q", key)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if strings.TrimSpace(value) == "" {
		delete(s.values, key)
	} else {
		s.values[key] = strings.TrimSpace(value)
	}
	return nil
}

// Views returns display-safe projections of every field.
func (s *Store) Views() []FieldView {
	out := make([]FieldView, 0, len(Fields))
	for _, f := range Fields {
		effective := s.Get(f.Key)
		view := FieldView{
			Key: f.Key, Label: f.Label, Group: f.Group, Secret: f.Secret,
			Required: f.Required, Purpose: f.Purpose, IsSet: effective != "",
		}
		if f.Secret {
			view.Value = redactSecret(effective)
			view.Redacted = effective != ""
		} else {
			view.Value = effective
		}
		out = append(out, view)
	}
	return out
}

// ViewsForKeys returns display-safe projections for a subset of keys, preserving
// the order given. Used to show a step's relevant configuration.
func (s *Store) ViewsForKeys(keys []string) []FieldView {
	all := map[string]FieldView{}
	for _, v := range s.Views() {
		all[v.Key] = v
	}
	out := make([]FieldView, 0, len(keys))
	for _, k := range keys {
		if v, ok := all[k]; ok {
			out = append(out, v)
		}
	}
	return out
}

// NonSecretOverrides returns the explicitly-set (overridden) values for
// non-secret fields. Used to persist run state by id; secrets are deliberately
// excluded so private keys and the DB connection string never touch disk.
func (s *Store) NonSecretOverrides() map[string]string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := map[string]string{}
	for k, v := range s.values {
		if f, ok := fieldByKey(k); ok && !f.Secret {
			out[k] = v
		}
	}
	return out
}

// MissingRequired returns the keys of required fields that have no value.
func (s *Store) MissingRequired() []string {
	missing := []string{}
	for _, f := range Fields {
		if f.Required && s.Get(f.Key) == "" {
			missing = append(missing, f.Key)
		}
	}
	return missing
}

// Broadcast reports whether transactions/DB mutations are applied (vs dry run).
func (s *Store) Broadcast() bool {
	return strings.EqualFold(s.Get("MIGRATION_BROADCAST"), "true")
}

// dbURL derives a database URL from the base connection string by replacing the
// path with the given database name. Mirrors run-migration.sh db_url_for.
func (s *Store) dbURL(dbName string) (string, error) {
	base := s.Get("MIGRATION_DB_CONNECTION_STRING")
	if base == "" {
		return "", fmt.Errorf("MIGRATION_DB_CONNECTION_STRING is not set")
	}
	if dbName == "" || strings.Contains(dbName, "/") {
		return "", fmt.Errorf("invalid database name %q", dbName)
	}
	u, err := url.Parse(base)
	if err != nil {
		return "", fmt.Errorf("invalid connection string: %w", err)
	}
	if u.Scheme != "postgres" && u.Scheme != "postgresql" {
		return "", fmt.Errorf("unsupported postgres URL scheme %q", u.Scheme)
	}
	u.Path = "/" + dbName
	return u.String(), nil
}

// AppDBURL, PonderDBURL, BotDBURL return the derived database URLs.
func (s *Store) AppDBURL() (string, error) {
	return s.dbURL(s.Get("MIGRATION_DB_APP_SUFFIX"))
}

func (s *Store) PonderDBURL() (string, error) {
	return s.dbURL(s.Get("MIGRATION_DB_PONDER_SUFFIX"))
}

func (s *Store) BotDBURL() (string, error) {
	return s.dbURL(s.Get("MIGRATION_DB_BOT_SUFFIX"))
}

func (s *Store) CeloPonderDBURL() (string, error) {
	return s.dbURL(s.Get("MIGRATION_DB_CELO_PONDER_SUFFIX"))
}

// MaintenanceDBURL returns a connection URL on the same server pointing at the
// default "postgres" maintenance database, used to CREATE the dedicated Celo
// Ponder database (Ponder connects to an existing database; it does not create
// databases itself).
func (s *Store) MaintenanceDBURL() (string, error) {
	return s.dbURL("postgres")
}

// CeloPonderDBURLRedacted returns the Celo Ponder DB URL with the password
// masked, safe to display in the UI (e.g. the backfill step warning).
func (s *Store) CeloPonderDBURLRedacted() (string, error) {
	raw, err := s.CeloPonderDBURL()
	if err != nil {
		return "", err
	}
	u, err := url.Parse(raw)
	if err != nil {
		return "", err
	}
	if u.User != nil {
		if _, hasPw := u.User.Password(); hasPw {
			u.User = url.UserPassword(u.User.Username(), "****")
		}
	}
	return u.String(), nil
}
