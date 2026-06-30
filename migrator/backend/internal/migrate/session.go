// Package migrate is the migrator engine: it mirrors every phase of
// run-migration.sh as an individually triggerable step, gated so a step can run
// only after the previous one succeeds. The migrator is stateful in memory
// (config + step status/logs/data); postgres is connected to only by the steps
// that read or write the migration databases.
package migrate

import (
	"context"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/SFLuv/migrator/backend/internal/config"
	"github.com/jackc/pgx/v5/pgxpool"
)

// traceFileName is the per-run call trace: one "ok <step-id> <ts>" line per
// completed step, used to fast-forward already-finished steps on a resume.
const traceFileName = "migrator-trace.log"

// configStateFileName persists the run's non-secret config overrides so they are
// restored on a resume with the same id. Secrets are never written here.
const configStateFileName = "migrator-config.json"

// StepState is a step's lifecycle status.
type StepState string

const (
	StepPending StepState = "pending"
	StepRunning StepState = "running"
	StepSuccess StepState = "success"
	StepFailed  StepState = "failed"
)

// LogLine is a single timestamped log entry for a step.
type LogLine struct {
	Time time.Time `json:"time"`
	Text string    `json:"text"`
}

// StepRun holds the live state of a step execution.
type StepRun struct {
	mu         sync.Mutex
	status     StepState
	logs       []LogLine
	data       map[string]any
	errMsg     string
	startedAt  *time.Time
	finishedAt *time.Time
	sink       func(string) // persists each log line to the run's log file
}

func newStepRun() *StepRun {
	return &StepRun{status: StepPending, data: map[string]any{}}
}

func (r *StepRun) log(format string, args ...any) {
	text := fmt.Sprintf(format, args...)
	r.mu.Lock()
	r.logs = append(r.logs, LogLine{Time: time.Now().UTC(), Text: text})
	sink := r.sink
	r.mu.Unlock()
	if sink != nil {
		sink(text)
	}
}

// markCompleted marks a run as already succeeded (used to fast-forward steps
// recorded complete in a previous run with the same id).
func (r *StepRun) markCompleted(note string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	now := time.Now().UTC()
	r.status = StepSuccess
	r.finishedAt = &now
	r.logs = append(r.logs, LogLine{Time: now, Text: note})
}

// setData records a named live value (counts, balances, addresses) for the UI.
func (r *StepRun) setData(key string, value any) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.data[key] = value
}

// StepRunView is a JSON-safe snapshot of a StepRun.
type StepRunView struct {
	Status     StepState      `json:"status"`
	Logs       []LogLine      `json:"logs"`
	Data       map[string]any `json:"data"`
	Error      string         `json:"error,omitempty"`
	StartedAt  *time.Time     `json:"started_at,omitempty"`
	FinishedAt *time.Time     `json:"finished_at,omitempty"`
}

func (r *StepRun) view() StepRunView {
	r.mu.Lock()
	defer r.mu.Unlock()
	logs := make([]LogLine, len(r.logs))
	copy(logs, r.logs)
	data := map[string]any{}
	for k, v := range r.data {
		data[k] = v
	}
	return StepRunView{Status: r.status, Logs: logs, Data: data, Error: r.errMsg, StartedAt: r.startedAt, FinishedAt: r.finishedAt}
}

// Step is one migration phase.
type Step struct {
	ID          string
	Name        string
	Description string
	ConfigKeys  []string
	Run         func(ctx context.Context, s *Session, run *StepRun) error
	// Warn, when set, returns a prominent pre-run warning shown for the step
	// (e.g. a manual action the operator must perform before triggering it).
	Warn func(s *Session) string
	// Snippets, when set, returns copyable code/command blocks shown on the step
	// (e.g. config and a run command the operator needs before triggering it).
	Snippets func(s *Session) []Snippet
}

// Snippet is a copyable code or command block shown on a step.
type Snippet struct {
	Title    string `json:"title"`
	Language string `json:"language,omitempty"`
	Content  string `json:"content"`
}

// Session is the migrator's in-memory state for one migration run.
type Session struct {
	cfg     *config.Store
	steps   []*Step
	runs    map[string]*StepRun
	runID   string
	resumed int
	baseCtx context.Context // parent of step contexts; cancel kills running forge

	mu      sync.Mutex
	pools   map[string]*pgxpool.Pool
	running bool // at most one step at a time

	logMu   sync.Mutex
	logFile *os.File // append-only run log at <artifactDir>/migrator.log
}

// writeRunLog appends a timestamped, step-tagged line to the run's log file
// (<artifactDir>/migrator.log), lazily opening it. Best-effort: logging failures
// never block a step.
func (s *Session) writeRunLog(stepID, text string) {
	s.logMu.Lock()
	defer s.logMu.Unlock()
	if s.logFile == nil {
		dir, err := s.ensureArtifactDir()
		if err != nil {
			return
		}
		f, err := os.OpenFile(filepath.Join(dir, "migrator.log"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
		if err != nil {
			return
		}
		s.logFile = f
	}
	fmt.Fprintf(s.logFile, "%s [%s] %s\n", time.Now().UTC().Format(time.RFC3339), stepID, text)
}

// NewSession builds the session with the ordered step registry. runID identifies
// the run for artifacts and state: passing the same id as a previous run resumes
// it — steps recorded complete in that run's trace are fast-forwarded. An empty
// runID gets a fresh UTC-timestamp id.
func NewSession(cfg *config.Store, runID string) *Session {
	runID = strings.TrimSpace(runID)
	if runID == "" {
		runID = time.Now().UTC().Format("20060102T150405Z")
	}
	s := &Session{
		cfg:   cfg,
		runs:  map[string]*StepRun{},
		pools: map[string]*pgxpool.Pool{},
		runID: runID,
	}
	s.steps = buildSteps()
	for _, st := range s.steps {
		s.runs[st.ID] = newStepRun()
	}
	s.loadConfigState()
	s.loadTrace()
	return s
}

// Config exposes the underlying config store.
func (s *Session) Config() *config.Store { return s.cfg }

// SetBaseContext sets the parent context for step execution. Cancelling it (e.g.
// on a SIGINT/SIGTERM shutdown) cancels any running step's context, which kills
// the in-flight forge/cast process so a restart never leaves an orphaned forge
// broadcasting from the same account (the cause of nonce desyncs).
func (s *Session) SetBaseContext(ctx context.Context) {
	s.mu.Lock()
	s.baseCtx = ctx
	s.mu.Unlock()
}

func (s *Session) baseContext() context.Context {
	s.mu.Lock()
	ctx := s.baseCtx
	s.mu.Unlock()
	if ctx == nil {
		return context.Background()
	}
	return ctx
}

// SetConfig applies a config override and persists the run's non-secret
// overrides so they are restored on a resume with the same id.
func (s *Session) SetConfig(key, value string) error {
	if err := s.cfg.Set(key, value); err != nil {
		return err
	}
	s.saveConfigState()
	return nil
}

func (s *Session) configStatePath() string {
	return filepath.Join(s.artifactDir(), configStateFileName)
}

// saveConfigState writes the run's non-secret config overrides to its artifact dir.
func (s *Session) saveConfigState() {
	dir, err := s.ensureArtifactDir()
	if err != nil {
		log.Printf("migrator: could not persist config state: %s", err)
		return
	}
	if err := writeJSONFile(filepath.Join(dir, configStateFileName), s.cfg.NonSecretOverrides()); err != nil {
		log.Printf("migrator: could not write config state: %s", err)
	}
}

// loadConfigState restores non-secret config overrides saved under this run id,
// applied on top of the environment-loaded config.
func (s *Session) loadConfigState() {
	var saved map[string]string
	if err := readJSONFile(s.configStatePath(), &saved); err != nil {
		return // no saved config for this id
	}
	restored := 0
	for k, v := range saved {
		if err := s.cfg.Set(k, v); err == nil {
			restored++
		}
	}
	if restored > 0 {
		log.Printf("migrator: restored %d saved config override(s) for run id %q", restored, s.runID)
	}
}

// RunID returns the id for this run (used for artifacts and resume state).
func (s *Session) RunID() string { return s.runID }

func (s *Session) traceFile() string { return filepath.Join(s.artifactDir(), traceFileName) }

// loadTrace marks any step recorded complete in this run's trace as succeeded,
// so a resume (same --id) fast-forwards finished steps to the next pending one.
func (s *Session) loadTrace() {
	data, err := os.ReadFile(s.traceFile())
	if err != nil {
		return // no prior state for this id
	}
	done := map[string]bool{}
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 2 && fields[0] == "ok" {
			done[fields[1]] = true
		}
	}
	for _, st := range s.steps {
		if done[st.ID] {
			s.runs[st.ID].markCompleted(fmt.Sprintf("fast-forwarded: completed in a previous run (id %s)", s.runID))
			s.resumed++
		}
	}
	if s.resumed > 0 {
		log.Printf("migrator: resuming run id %q — fast-forwarded %d completed step(s)", s.runID, s.resumed)
	}
}

// recordStepDone appends a step to this run's trace so it is fast-forwarded on a
// resume. Dry runs perform no on-chain or DB mutations, so (like run-migration.sh)
// they never mark steps complete.
func (s *Session) recordStepDone(id string) {
	if !s.cfg.Broadcast() {
		return
	}
	dir, err := s.ensureArtifactDir()
	if err != nil {
		log.Printf("migrator: could not persist step state for %q: %s", id, err)
		return
	}
	f, err := os.OpenFile(filepath.Join(dir, traceFileName), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		log.Printf("migrator: could not open trace file: %s", err)
		return
	}
	defer f.Close()
	if _, err := fmt.Fprintf(f, "ok %s %s\n", id, time.Now().UTC().Format(time.RFC3339)); err != nil {
		log.Printf("migrator: could not write trace entry: %s", err)
	}
}

func (s *Session) stepIndex(id string) int {
	for i, st := range s.steps {
		if st.ID == id {
			return i
		}
	}
	return -1
}

// CanRun reports whether a step may be triggered now, with a reason if not.
func (s *Session) CanRun(id string) (bool, string) {
	idx := s.stepIndex(id)
	if idx < 0 {
		return false, "unknown step"
	}
	if missing := s.cfg.MissingRequired(); len(missing) > 0 {
		return false, fmt.Sprintf("missing required configuration: %v", missing)
	}
	s.mu.Lock()
	running := s.running
	s.mu.Unlock()
	if running {
		return false, "another step is running"
	}
	cur := s.runs[id].view().Status
	if cur == StepRunning {
		return false, "step is already running"
	}
	if cur == StepSuccess {
		return false, "step already completed"
	}
	if idx > 0 {
		prev := s.steps[idx-1]
		if s.runs[prev.ID].view().Status != StepSuccess {
			return false, fmt.Sprintf("previous step %q must succeed first", prev.Name)
		}
	}
	return true, ""
}

// Trigger starts a step asynchronously. The caller polls Step for progress.
func (s *Session) Trigger(id string) error {
	ok, reason := s.CanRun(id)
	if !ok {
		return fmt.Errorf("%s", reason)
	}
	step := s.steps[s.stepIndex(id)]
	run := s.runs[id]

	s.mu.Lock()
	s.running = true
	s.mu.Unlock()

	run.mu.Lock()
	now := time.Now().UTC()
	run.status = StepRunning
	run.startedAt = &now
	run.finishedAt = nil
	run.errMsg = ""
	run.logs = nil
	run.data = map[string]any{}
	run.sink = func(line string) { s.writeRunLog(id, line) }
	run.mu.Unlock()

	s.writeRunLog(id, fmt.Sprintf("=== step %q started (broadcast=%v) ===", step.Name, s.cfg.Broadcast()))

	go func() {
		ctx, cancel := context.WithTimeout(s.baseContext(), 30*time.Minute)
		defer cancel()
		err := step.Run(ctx, s, run)
		fin := time.Now().UTC()
		run.mu.Lock()
		run.finishedAt = &fin
		if err != nil {
			run.status = StepFailed
			run.errMsg = err.Error()
		} else {
			run.status = StepSuccess
		}
		run.mu.Unlock()
		if err != nil {
			run.log("step failed: %s", err)
		} else {
			run.log("step completed")
			s.recordStepDone(id)
		}
		s.mu.Lock()
		s.running = false
		s.mu.Unlock()
	}()
	return nil
}

// StepSummary is a list-view of a step (no logs).
type StepSummary struct {
	ID          string             `json:"id"`
	Name        string             `json:"name"`
	Description string             `json:"description"`
	Config      []config.FieldView `json:"config"`
	Status      StepState          `json:"status"`
	Runnable    bool               `json:"runnable"`
	Reason      string             `json:"reason,omitempty"`
	Error       string             `json:"error,omitempty"`
	Warning     string             `json:"warning,omitempty"`
	Snippets    []Snippet          `json:"snippets,omitempty"`
}

// summary builds the list-view of a step, including a dynamic pre-run warning.
func (s *Session) summary(st *Step) StepSummary {
	v := s.runs[st.ID].view()
	runnable, reason := s.CanRun(st.ID)
	sum := StepSummary{
		ID: st.ID, Name: st.Name, Description: st.Description,
		Config: s.cfg.ViewsForKeys(st.ConfigKeys),
		Status: v.Status, Runnable: runnable, Reason: reason, Error: v.Error,
	}
	if st.Warn != nil {
		sum.Warning = st.Warn(s)
	}
	if st.Snippets != nil {
		sum.Snippets = st.Snippets(s)
	}
	return sum
}

// Steps returns a summary of every step with current status and runnability.
func (s *Session) Steps() []StepSummary {
	out := make([]StepSummary, 0, len(s.steps))
	for _, st := range s.steps {
		out = append(out, s.summary(st))
	}
	return out
}

// Step returns the full detail (logs + data) for one step.
func (s *Session) Step(id string) (StepSummary, StepRunView, bool) {
	idx := s.stepIndex(id)
	if idx < 0 {
		return StepSummary{}, StepRunView{}, false
	}
	st := s.steps[idx]
	return s.summary(st), s.runs[id].view(), true
}

// pool returns a cached pgx pool for the given database URL.
func (s *Session) pool(ctx context.Context, dbURL string) (*pgxpool.Pool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if p, ok := s.pools[dbURL]; ok {
		return p, nil
	}
	p, err := pgxpool.New(ctx, dbURL)
	if err != nil {
		return nil, fmt.Errorf("error connecting to database: %w", err)
	}
	s.pools[dbURL] = p
	return p, nil
}

// Close releases all database pools and the run log file.
func (s *Session) Close() {
	s.mu.Lock()
	for _, p := range s.pools {
		p.Close()
	}
	s.pools = map[string]*pgxpool.Pool{}
	s.mu.Unlock()

	s.logMu.Lock()
	if s.logFile != nil {
		s.logFile.Close()
		s.logFile = nil
	}
	s.logMu.Unlock()
}
