// Package runner executes external tools (forge, cast, pg_dump) used by the
// migration steps, capturing stdout for parsing while streaming every output
// line to a log sink for live progress. It never echoes the command arguments,
// so private keys passed to forge are never written to logs.
package runner

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sort"
	"strings"
)

// LogFunc receives one output line at a time.
type LogFunc func(line string)

type lineWriter struct {
	logf LogFunc
	buf  []byte
}

func (w *lineWriter) Write(p []byte) (int, error) {
	w.buf = append(w.buf, p...)
	for {
		i := bytes.IndexByte(w.buf, '\n')
		if i < 0 {
			break
		}
		line := strings.TrimRight(string(w.buf[:i]), "\r")
		w.buf = w.buf[i+1:]
		if w.logf != nil && strings.TrimSpace(line) != "" {
			w.logf(line)
		}
	}
	return len(p), nil
}

func (w *lineWriter) flush() {
	if len(w.buf) > 0 && w.logf != nil {
		if s := strings.TrimSpace(string(w.buf)); s != "" {
			w.logf(s)
		}
	}
	w.buf = nil
}

// Run executes name+args in dir (cwd if empty), streaming combined output to
// logf as it arrives and returning the trimmed stdout. Pass logf=nil for a quiet
// capture (e.g. cast reads).
func Run(ctx context.Context, logf LogFunc, dir, name string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	if dir != "" {
		cmd.Dir = dir
	}
	var stdout bytes.Buffer
	lw := &lineWriter{logf: logf}
	cmd.Stdout = io.MultiWriter(&stdout, lw)
	cmd.Stderr = lw
	err := cmd.Run()
	lw.flush()
	return strings.TrimSpace(stdout.String()), err
}

// RunEnv is like Run but adds extra environment variables (e.g. forge script
// inputs such as SFLUV_V2_PROXY) on top of the process environment.
func RunEnv(ctx context.Context, logf LogFunc, extraEnv map[string]string, dir, name string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	if dir != "" {
		cmd.Dir = dir
	}
	env := os.Environ()
	keys := make([]string, 0, len(extraEnv))
	for k := range extraEnv {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		env = append(env, fmt.Sprintf("%s=%s", k, extraEnv[k]))
	}
	cmd.Env = env
	var stdout bytes.Buffer
	lw := &lineWriter{logf: logf}
	cmd.Stdout = io.MultiWriter(&stdout, lw)
	cmd.Stderr = lw
	err := cmd.Run()
	lw.flush()
	return strings.TrimSpace(stdout.String()), err
}

// RunInput is like Run but pipes stdinData to the command's stdin (used to pass
// SQL to psql without logging it).
func RunInput(ctx context.Context, logf LogFunc, stdinData, dir, name string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	if dir != "" {
		cmd.Dir = dir
	}
	cmd.Stdin = strings.NewReader(stdinData)
	var stdout bytes.Buffer
	lw := &lineWriter{logf: logf}
	cmd.Stdout = io.MultiWriter(&stdout, lw)
	cmd.Stderr = lw
	err := cmd.Run()
	lw.flush()
	return strings.TrimSpace(stdout.String()), err
}
