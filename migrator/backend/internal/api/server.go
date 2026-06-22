// Package api exposes the migrator session over HTTP: read/override config,
// list/inspect steps, and trigger a step.
package api

import (
	"encoding/json"
	"net/http"

	"github.com/SFLuv/migrator/backend/internal/migrate"
	"github.com/go-chi/chi/v5"
	"github.com/go-chi/cors"
)

type Server struct {
	session *migrate.Session
}

// NewRouter builds the HTTP handler for the migrator session.
func NewRouter(session *migrate.Session) http.Handler {
	s := &Server{session: session}
	r := chi.NewRouter()
	r.Use(cors.Handler(cors.Options{
		AllowedOrigins:   []string{"*"},
		AllowedMethods:   []string{"GET", "POST", "PUT", "OPTIONS"},
		AllowedHeaders:   []string{"Content-Type"},
		AllowCredentials: false,
	}))

	r.Get("/api/health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	r.Get("/api/config", s.getConfig)
	r.Put("/api/config", s.putConfig)
	r.Get("/api/steps", s.getSteps)
	r.Get("/api/steps/{id}", s.getStep)
	r.Post("/api/steps/{id}/run", s.runStep)
	return r
}

func (s *Server) getConfig(w http.ResponseWriter, r *http.Request) {
	cfg := s.session.Config()
	writeJSON(w, http.StatusOK, map[string]any{
		"fields":    cfg.Views(),
		"missing":   cfg.MissingRequired(),
		"broadcast": cfg.Broadcast(),
	})
}

func (s *Server) putConfig(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Key   string `json:"key"`
		Value string `json:"value"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}
	if err := s.session.Config().Set(body.Key, body.Value); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	s.getConfig(w, r)
}

func (s *Server) getSteps(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"steps": s.session.Steps()})
}

func (s *Server) getStep(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	summary, run, ok := s.session.Step(id)
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "unknown step"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"step": summary, "run": run})
}

func (s *Server) runStep(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	if err := s.session.Trigger(id); err != nil {
		writeJSON(w, http.StatusConflict, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]string{"status": "running"})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
