"use client"

import { Fragment, useCallback, useEffect, useState } from "react"
import { api } from "@/lib/api"
import type { ConfigResponse, FieldView, StepDetail, StepState, StepSummary } from "@/lib/types"

const CONFIG_ID = "config"

export default function Page() {
  const [config, setConfig] = useState<ConfigResponse | null>(null)
  const [steps, setSteps] = useState<StepSummary[]>([])
  const [activeId, setActiveId] = useState<string>(CONFIG_ID)
  const [detail, setDetail] = useState<StepDetail | null>(null)
  const [err, setErr] = useState<string | null>(null)

  const refreshConfig = useCallback(async () => {
    try {
      setConfig(await api.getConfig())
    } catch (e) {
      setErr(errMsg(e))
    }
  }, [])

  const refreshSteps = useCallback(async () => {
    try {
      const res = await api.getSteps()
      setSteps(res.steps ?? [])
    } catch (e) {
      setErr(errMsg(e))
    }
  }, [])

  useEffect(() => {
    void refreshConfig()
    void refreshSteps()
    const t = setInterval(() => void refreshSteps(), 2500)
    return () => clearInterval(t)
  }, [refreshConfig, refreshSteps])

  useEffect(() => {
    if (activeId === CONFIG_ID) {
      setDetail(null)
      return
    }
    let cancelled = false
    const load = async () => {
      try {
        const d = await api.getStep(activeId)
        if (!cancelled) setDetail(d)
      } catch (e) {
        if (!cancelled) setErr(errMsg(e))
      }
    }
    void load()
    const t = setInterval(load, 1500)
    return () => {
      cancelled = true
      clearInterval(t)
    }
  }, [activeId])

  const onRun = useCallback(
    async (id: string) => {
      setErr(null)
      try {
        await api.runStep(id)
        await refreshSteps()
      } catch (e) {
        setErr(errMsg(e))
      }
    },
    [refreshSteps],
  )

  const orderedIds = [CONFIG_ID, ...steps.map((s) => s.id)]
  const total = orderedIds.length
  const activeIndex = Math.max(0, orderedIds.indexOf(activeId))
  const nextId = orderedIds[activeIndex + 1]
  const nextLabel = nextId === undefined ? undefined : nextId === CONFIG_ID ? "Configuration" : steps.find((s) => s.id === nextId)?.name
  const goNext = nextId ? () => setActiveId(nextId) : undefined
  const configComplete = Boolean(config && (config.missing?.length ?? 0) === 0)

  return (
    <div className="shell">
      <header className="topbar">
        <div className="brand">
          <img className="brand-mark" src="/icon.png" alt="SFLuv" />
          <div>
            <div className="brand-name">SFLuv Migrator</div>
            <div className="brand-sub">Berachain → Celo</div>
          </div>
        </div>
        <div style={{ marginLeft: "auto", display: "flex", alignItems: "center", gap: 12 }}>
          {config?.run_id && <span className="run-id">run {config.run_id}</span>}
          {config && (
            <span className={`pill ${config.broadcast ? "failed" : "running"}`}>
              {config.broadcast ? "Live — broadcasting" : "Dry run"}
            </span>
          )}
        </div>
      </header>

      <div className="body">
        <aside className="rail">
          <div className="rail-head">Migration</div>
          <StepNode
            num={1}
            name="Configuration"
            meta={config ? ((config.missing?.length ?? 0) ? `${config.missing.length} missing` : "Complete") : "Loading…"}
            status={configComplete ? "success" : "pending"}
            active={activeId === CONFIG_ID}
            locked={false}
            onClick={() => setActiveId(CONFIG_ID)}
          />
          {steps.map((s, i) => (
            <StepNode
              key={s.id}
              num={i + 2}
              name={s.name}
              meta={s.status === "pending" && !s.runnable ? s.reason || "Locked" : capitalize(s.status)}
              status={s.status}
              active={activeId === s.id}
              locked={s.status === "pending" && !s.runnable}
              onClick={() => setActiveId(s.id)}
            />
          ))}
        </aside>

        <main className="content">
          {err && <div className="banner fail">{err}</div>}
          {activeId === CONFIG_ID ? (
            <ConfigPanel
              config={config}
              stepLabel={`Step 1 of ${total}`}
              nextLabel={configComplete ? nextLabel : undefined}
              onNext={configComplete ? goNext : undefined}
              onSave={async (k, v) => {
                await api.setConfig(k, v)
                await refreshConfig()
                await refreshSteps()
              }}
            />
          ) : (
            <StepPanel
              detail={detail}
              stepLabel={`Step ${activeIndex + 1} of ${total}`}
              nextLabel={nextLabel}
              onNext={goNext}
              onRun={() => onRun(activeId)}
            />
          )}
        </main>
      </div>
    </div>
  )
}

function StepNode(props: {
  num: number
  name: string
  meta: string
  status: StepState
  active: boolean
  locked: boolean
  onClick: () => void
}) {
  const { status, active } = props
  const markerClass = status === "success" ? "success" : status === "running" ? "running" : status === "failed" ? "failed" : active ? "active" : ""
  return (
    <div
      className={`snode ${active ? "active" : ""} ${props.locked ? "locked" : ""} ${status === "success" ? "done" : ""}`}
      onClick={props.locked ? undefined : props.onClick}
    >
      <div className={`marker ${markerClass}`}>
        {status === "success" ? "✓" : status === "failed" ? "✕" : status === "running" ? <span className="spinner" /> : props.num}
      </div>
      <div className="snode-body">
        <div className="snode-name">{props.name}</div>
        <div className="snode-meta">{props.meta}</div>
      </div>
    </div>
  )
}

function SnippetBlock({ snippet }: { snippet: { title: string; language?: string; content: string } }) {
  const [copied, setCopied] = useState(false)
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(snippet.content)
      setCopied(true)
      setTimeout(() => setCopied(false), 1500)
    } catch {
      /* clipboard unavailable */
    }
  }
  return (
    <div className="snippet">
      <div className="snippet-head">
        <span className="snippet-title">{snippet.title}</span>
        <button className="ghost small" onClick={() => void copy()}>
          {copied ? "Copied ✓" : "Copy"}
        </button>
      </div>
      <pre className="snippet-body">{snippet.content}</pre>
    </div>
  )
}

function NextButton({ label, onNext }: { label?: string; onNext?: () => void }) {
  if (!onNext || !label) return null
  return (
    <button className="ghost" onClick={onNext}>
      Next: {label} →
    </button>
  )
}

function ConfigPanel(props: {
  config: ConfigResponse | null
  stepLabel: string
  nextLabel?: string
  onNext?: () => void
  onSave: (key: string, value: string) => Promise<void>
}) {
  const { config, onSave } = props
  if (!config) return <p className="muted-note">Loading configuration…</p>
  const groups = groupFields((config.fields ?? []).filter((f) => f.key !== "MIGRATION_BROADCAST"))
  const dryRun = !config.broadcast
  const missing = config.missing ?? []
  return (
    <>
      <div className="content-head">
        <h2>Configuration</h2>
      </div>
      <div className="step-counter">{props.stepLabel}</div>
      <p className="desc">
        Settings load from the environment. Override or fill any below — secrets are write-only and never echoed back.
        Every required value must be set before the migration can run.
      </p>

      <DryRunToggle dryRun={dryRun} onChange={(on) => onSave("MIGRATION_BROADCAST", on ? "false" : "true")} />

      {missing.length > 0 ? (
        <div className="banner warn">
          {missing.length} required setting{missing.length === 1 ? "" : "s"} missing: {missing.join(", ")}
        </div>
      ) : (
        <div className="banner ok">All required configuration is set.</div>
      )}

      {groups.map(([group, fields], idx) => {
        const missingInGroup = fields.filter((f) => f.required && !f.is_set).length
        return (
          <details className="cfg-group" key={group} open={idx === 0 || missingInGroup > 0}>
            <summary>
              <span className="chev">▶</span>
              {group}
              <span className="count">{fields.filter((f) => f.is_set).length}/{fields.length} set</span>
            </summary>
            <div className="cfg-group-body">
              {fields.map((f) => (
                <ConfigField key={f.key} field={f} onSave={onSave} />
              ))}
            </div>
          </details>
        )
      })}

      {props.onNext && (
        <div className="actions" style={{ marginTop: 22 }}>
          <NextButton label={props.nextLabel} onNext={props.onNext} />
        </div>
      )}
    </>
  )
}

function DryRunToggle({ dryRun, onChange }: { dryRun: boolean; onChange: (on: boolean) => Promise<void> }) {
  const [busy, setBusy] = useState(false)
  const toggle = async () => {
    setBusy(true)
    try {
      await onChange(!dryRun)
    } finally {
      setBusy(false)
    }
  }
  return (
    <div className={`dryrun ${dryRun ? "on" : "live"}`}>
      <div>
        <div className="dryrun-title">{dryRun ? "Dry run" : "Live — broadcasting"}</div>
        <div className="dryrun-sub">
          {dryRun
            ? "Read-only: forge runs without --broadcast and DB-mutating steps are skipped. Preflight and artifact steps still run."
            : "Transactions are broadcast on-chain and database mutations are applied. This is a real migration run."}
        </div>
      </div>
      <button
        type="button"
        role="switch"
        aria-checked={dryRun}
        aria-label="Dry run"
        className={`switch ${dryRun ? "on" : ""}`}
        disabled={busy}
        onClick={() => void toggle()}
      >
        <span className="knob" />
      </button>
    </div>
  )
}

function ConfigField({ field, onSave }: { field: FieldView; onSave: (key: string, value: string) => Promise<void> }) {
  const [value, setValue] = useState("")
  const [saving, setSaving] = useState(false)
  const save = async () => {
    setSaving(true)
    try {
      await onSave(field.key, value)
      setValue("")
    } finally {
      setSaving(false)
    }
  }
  return (
    <div className="field">
      <div className="row">
        <div>
          <span className="label">{field.label}</span>
          <span className={`tag ${field.is_set ? "set" : "unset"}`} style={{ marginLeft: 8 }}>
            {field.is_set ? "set" : "not set"}
          </span>
          {field.required && <span className="tag req">required</span>}
        </div>
        {field.is_set && field.value && (
          <span className="val">
            {field.value}
            {field.redacted && <span className="redacted-tag"> redacted</span>}
          </span>
        )}
      </div>
      <div className="purpose">{field.purpose}</div>
      <div className="editor">
        <input
          type={field.secret ? "password" : "text"}
          placeholder={field.is_set ? "override…" : "set value…"}
          value={value}
          onChange={(e) => setValue(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && value.trim()) void save()
          }}
        />
        <button className="ghost small" disabled={saving || !value.trim()} onClick={() => void save()}>
          Save
        </button>
      </div>
    </div>
  )
}

function StepPanel(props: {
  detail: StepDetail | null
  stepLabel: string
  nextLabel?: string
  onNext?: () => void
  onRun: () => void
}) {
  const { detail, onRun } = props
  if (!detail) return <p className="muted-note">Loading step…</p>
  const { step, run } = detail
  const running = run.status === "running"
  return (
    <>
      <div className="content-head">
        <h2>{step.name}</h2>
        <span className={`pill ${step.status}`}>{step.status}</span>
      </div>
      <div className="step-counter">{props.stepLabel}</div>

      {step.warning && (
        <div className="bigwarn">
          <span className="bigwarn-icon">⚠</span>
          <span>{step.warning}</span>
        </div>
      )}

      {step.snippets && step.snippets.length > 0 && (
        <div className="section">
          {step.snippets.map((sn, i) => (
            <SnippetBlock key={i} snippet={sn} />
          ))}
        </div>
      )}

      <p className="desc">{step.description}</p>

      {step.error && <div className="banner fail">{step.error}</div>}
      {step.status === "success" && <div className="banner ok">Step completed successfully.</div>}
      {!step.runnable && step.status === "pending" && step.reason && <div className="banner warn">{step.reason}</div>}

      <div className="actions">
        <button className="primary" disabled={!step.runnable} onClick={onRun}>
          {running ? "Running…" : step.status === "failed" ? "Retry step" : step.status === "success" ? "Run again" : "Run step"}
        </button>
        {step.status === "success" && <NextButton label={props.nextLabel} onNext={props.onNext} />}
        {!step.runnable && step.status === "pending" && step.reason && <span className="reason">{step.reason}</span>}
      </div>

      {step.config.length > 0 && (
        <div className="card">
          <h3 className="section-title">Configuration used</h3>
          {step.config.map((f) => (
            <div className="field" key={f.key}>
              <div className="row">
                <div>
                  <span className="label">{f.label}</span>
                  <span className={`tag ${f.is_set ? "set" : "unset"}`} style={{ marginLeft: 8 }}>
                    {f.is_set ? "set" : "not set"}
                  </span>
                </div>
                {f.is_set && f.value && (
                  <span className="val">
                    {f.value}
                    {f.redacted && <span className="redacted-tag"> redacted</span>}
                  </span>
                )}
              </div>
              <div className="purpose">{f.purpose}</div>
            </div>
          ))}
        </div>
      )}

      {hasProgress(run.data) && <ProgressBar progress={run.data.progress as ProgressData} />}

      {hasChecks(run.data) && (
        <div className="card">
          <h3 className="section-title">Checks</h3>
          <div className="checks">
            {(run.data.checks as CheckResult[]).map((c, i) => (
              <div className={`check ${c.ok ? "ok" : "fail"}`} key={i}>
                <span className="name">{c.name}</span>
                <span className="detail">{c.detail}</span>
              </div>
            ))}
          </div>
        </div>
      )}

      {dataEntries(run.data).length > 0 && (
        <div className="card">
          <h3 className="section-title">Live data</h3>
          <div className="kv">
            {dataEntries(run.data).map(([k, v]) => (
              <Fragment key={k}>
                <span className="k">{k}</span>
                <span className="v">{renderVal(v)}</span>
              </Fragment>
            ))}
          </div>
        </div>
      )}

      {run.logs.length > 0 && (
        <details className="logs-wrap" open={running}>
          <summary>
            <span className="chev">▶</span> Logs ({run.logs.length})
          </summary>
          <div className="logs">
            {run.logs.map((l, i) => (
              <div key={i}>
                <span className="ts">{fmtTime(l.time)} </span>
                {l.text}
              </div>
            ))}
          </div>
        </details>
      )}
    </>
  )
}

// --- helpers ---------------------------------------------------------------

interface CheckResult {
  name: string
  ok: boolean
  detail: string
}

interface ProgressData {
  done: number
  total: number
  label?: string
}

function ProgressBar({ progress }: { progress: ProgressData }) {
  const total = progress.total > 0 ? progress.total : 1
  const done = Math.min(Math.max(progress.done, 0), total)
  const pct = Math.round((done / total) * 100)
  return (
    <div className="card">
      <div className="progress-head">
        <span className="progress-label">{progress.label || "Working…"}</span>
        <span className="progress-count">{done} / {progress.total} · {pct}%</span>
      </div>
      <div className="progress-track">
        <div className="progress-fill" style={{ width: `${pct}%` }} />
      </div>
    </div>
  )
}

function hasProgress(data: Record<string, unknown>): boolean {
  const p = data.progress as ProgressData | undefined
  return Boolean(p && typeof p.total === "number" && typeof p.done === "number")
}

function capitalize(s: string): string {
  return s ? s.charAt(0).toUpperCase() + s.slice(1) : s
}

function groupFields(fields: FieldView[]): [string, FieldView[]][] {
  const order: string[] = []
  const map: Record<string, FieldView[]> = {}
  for (const f of fields) {
    if (!map[f.group]) {
      map[f.group] = []
      order.push(f.group)
    }
    map[f.group].push(f)
  }
  return order.map((g) => [g, map[g]])
}

function hasChecks(data: Record<string, unknown>): boolean {
  return Array.isArray(data.checks) && (data.checks as unknown[]).length > 0
}

function dataEntries(data: Record<string, unknown>): [string, unknown][] {
  return Object.entries(data).filter(([k]) => k !== "checks" && k !== "progress")
}

function renderVal(v: unknown): string {
  if (v === null || v === undefined) return ""
  if (typeof v === "object") return JSON.stringify(v)
  return String(v)
}

function fmtTime(iso: string): string {
  try {
    return new Date(iso).toLocaleTimeString()
  } catch {
    return iso
  }
}

function errMsg(e: unknown): string {
  return e instanceof Error ? e.message : "request failed"
}
