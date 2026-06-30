package main

import (
	"context"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"

	"github.com/SFLuv/migrator/backend/internal/api"
	"github.com/SFLuv/migrator/backend/internal/config"
	"github.com/SFLuv/migrator/backend/internal/migrate"
	"github.com/joho/godotenv"
)

// runIDPattern keeps the id safe to use as an artifact directory name.
var runIDPattern = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)

func main() {
	var idFlag string
	flag.StringVar(&idFlag, "id", "", "migration run id; reuse a previous id to resume it (completed steps are fast-forwarded). Default: MIGRATION_RUN_ID env, else a UTC timestamp.")
	flag.Parse()

	loadEnv()

	// Resolve the run id: --id flag wins, then MIGRATION_RUN_ID (matching
	// run-migration.sh), else NewSession assigns a fresh timestamp.
	runID := strings.TrimSpace(idFlag)
	if runID == "" {
		runID = strings.TrimSpace(os.Getenv("MIGRATION_RUN_ID"))
	}
	if runID != "" && !runIDPattern.MatchString(runID) {
		log.Fatalf("invalid run id %q: use only letters, digits, '.', '_' or '-'", runID)
	}

	// On SIGINT/SIGTERM this context cancels, which cancels any running step and
	// kills its in-flight forge/cast process — so stopping/restarting the migrator
	// never leaves an orphaned forge broadcasting from the same account.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	cfg := config.New()
	session := migrate.NewSession(cfg, runID)
	session.SetBaseContext(ctx)
	defer session.Close()

	log.Printf("migrator run id: %s", session.RunID())

	port := os.Getenv("MIGRATOR_PORT")
	if port == "" {
		port = "8090"
	}
	srv := &http.Server{Addr: ":" + port, Handler: api.NewRouter(session)}

	go func() {
		log.Printf("migrator backend listening on :%s", port)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatal(err)
		}
	}()

	<-ctx.Done()
	log.Printf("migrator: shutting down (stopping any in-flight migration step)…")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutdownCtx)
}

// loadEnv loads configuration from the same env file run-migration.sh uses: by
// default the .env next to run-migration.sh (the repo root), overridable with
// ENV_FILE or ROOT_ENV (the script's own variable) so both tools read the same
// file. Values already set in the process environment take precedence.
func loadEnv() {
	if envFile := os.Getenv("ENV_FILE"); envFile != "" {
		loadEnvFile(envFile)
		return
	}
	if rootEnv := os.Getenv("ROOT_ENV"); rootEnv != "" {
		loadEnvFile(rootEnv)
		return
	}
	loadEnvFile(defaultRootEnv())
}

func loadEnvFile(path string) {
	if err := godotenv.Load(path); err != nil {
		log.Printf("migrator: no env file loaded from %s (%v); relying on the process environment", path, err)
		return
	}
	log.Printf("migrator: loaded configuration from %s", path)
}

// defaultRootEnv finds the .env beside run-migration.sh by walking up from the
// working directory, mirroring the script's ROOT_DIR resolution. Falls back to a
// local .env if the script is not found.
func defaultRootEnv() string {
	dir, err := os.Getwd()
	if err != nil {
		return ".env"
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "run-migration.sh")); err == nil {
			return filepath.Join(dir, ".env")
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return ".env"
		}
		dir = parent
	}
}
