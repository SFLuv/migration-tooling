package main

import (
	"log"
	"net/http"
	"os"

	"github.com/SFLuv/migrator/backend/internal/api"
	"github.com/SFLuv/migrator/backend/internal/config"
	"github.com/SFLuv/migrator/backend/internal/migrate"
	"github.com/joho/godotenv"
)

func main() {
	// Load a .env if present (errors ignored: env may be set externally).
	if envFile := os.Getenv("ENV_FILE"); envFile != "" {
		_ = godotenv.Load(envFile)
	} else {
		_ = godotenv.Load()
	}

	cfg := config.New()
	session := migrate.NewSession(cfg)
	defer session.Close()

	handler := api.NewRouter(session)

	port := os.Getenv("MIGRATOR_PORT")
	if port == "" {
		port = "8090"
	}
	log.Printf("migrator backend listening on :%s", port)
	if err := http.ListenAndServe(":"+port, handler); err != nil {
		log.Fatal(err)
	}
}
