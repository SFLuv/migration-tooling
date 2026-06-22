// Package migrate is the migrator engine: it mirrors every phase of
// run-migration.sh as an individually triggerable step, gated so a step can run
// only after the previous one succeeds. The migrator is stateful in memory
// (config + step status/logs/data); postgres is connected to only by the steps
// that read or write the migration databases.
package migrate

import (
	"context"
	"fmt"
	"sync"
	"time"

	"github.com/SFLuv/migrator/backend/internal/config"
	"github.com/jackc/pgx/v5/pgxpool"
)

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
}

func newStepRun() *StepRun {
	return &StepRun{status: StepPending, data: map[string]any{}}
}

func (r *StepRun) log(format string, args ...any) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.logs = append(r.logs, LogLine{Time: time.Now().UTC(), Text: fmt.Sprintf(format, args...)})
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
}

// Session is the migrator's in-memory state for one migration run.
type Session struct {
	cfg   *config.Store
	steps []*Step
	runs  map[string]*StepRun
	runID string

	mu      sync.Mutex
	pools   map[string]*pgxpool.Pool
	running bool // at most one step at a time
}

// NewSession builds the session with the ordered step registry.
func NewSession(cfg *config.Store) *Session {
	s := &Session{
		cfg:   cfg,
		runs:  map[string]*StepRun{},
		pools: map[string]*pgxpool.Pool{},
		runID: time.Now().UTC().Format("20060102T150405Z"),
	}
	s.steps = buildSteps()
	for _, st := range s.steps {
		s.runs[st.ID] = newStepRun()
	}
	return s
}

// Config exposes the underlying config store.
func (s *Session) Config() *config.Store { return s.cfg }

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
	run.mu.Unlock()

	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
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
}

// Steps returns a summary of every step with current status and runnability.
func (s *Session) Steps() []StepSummary {
	out := make([]StepSummary, 0, len(s.steps))
	for _, st := range s.steps {
		v := s.runs[st.ID].view()
		runnable, reason := s.CanRun(st.ID)
		out = append(out, StepSummary{
			ID: st.ID, Name: st.Name, Description: st.Description,
			Config: s.cfg.ViewsForKeys(st.ConfigKeys),
			Status: v.Status, Runnable: runnable, Reason: reason, Error: v.Error,
		})
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
	v := s.runs[id].view()
	runnable, reason := s.CanRun(id)
	summary := StepSummary{
		ID: st.ID, Name: st.Name, Description: st.Description,
		Config: s.cfg.ViewsForKeys(st.ConfigKeys),
		Status: v.Status, Runnable: runnable, Reason: reason, Error: v.Error,
	}
	return summary, v, true
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

// Close releases all database pools.
func (s *Session) Close() {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, p := range s.pools {
		p.Close()
	}
	s.pools = map[string]*pgxpool.Pool{}
}
