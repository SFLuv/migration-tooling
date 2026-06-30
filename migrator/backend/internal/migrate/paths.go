package migrate

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"github.com/SFLuv/migrator/backend/internal/runner"
)

// artifactDir is the per-run artifact directory (artifact root + run id),
// resolved to an absolute path so artifact paths handed to forge — which runs
// with its working directory set to the contracts repo — resolve correctly
// regardless of the caller's working directory.
func (s *Session) artifactDir() string {
	dir := filepath.Join(s.cfg.Get("MIGRATION_ARTIFACT_ROOT"), s.runID)
	if abs, err := filepath.Abs(dir); err == nil {
		return abs
	}
	return dir
}

func (s *Session) ensureArtifactDir() (string, error) {
	dir := s.artifactDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("creating artifact directory: %w", err)
	}
	return dir, nil
}

func (s *Session) contractsDir() string {
	return s.cfg.Get("CONTRACTS_DIR")
}

// logger adapts a StepRun to a runner.LogFunc so external command output streams
// into the step's live logs.
func (r *StepRun) logger() runner.LogFunc {
	return func(line string) { r.log("%s", line) }
}

func writeJSONFile(path string, v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(b, '\n'), 0o644)
}

func readJSONFile(path string, v any) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(b, v)
}
