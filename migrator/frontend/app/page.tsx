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
      setSteps(res.steps)
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

  // Poll the active step's detail (faster while it runs).
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

  return (
    <div className="app">
      <aside className="rail">
        <h1>SFLuv Migrator</h1>
        <div className="sub">Berachain → Celo</div>
        {config && (
          <div style={{ marginBottom: 16 }}>
            <span className={`badge ${config.broadcast ? "live" : "dry"}`}>
              {config.broadcast ? "LIVE — broadcasting" : "DRY RUN"}
            </span>
          </div>
        )}

        <RailItem
          num={1}
          name="Configuration"
          meta={config ? (config.missing.length ? `${config.missing.length} missing` : "complete") : "…"}
          status={config && config.missing.length === 0 ? "success" : "pending"}
          active={activeId === CONFIG_ID}
          locked={false}
          onClick={() => setActiveId(CONFIG_ID)}
        />
        {steps.map((s, i) => (
          <RailItem
            key={s.id}
            num={i + 2}
            name={s.name}
            meta={s.status === "pending" && !s.runnable ? s.reason || "locked" : s.status}
            status={s.status}
            active={activeId === s.id}
            locked={s.status === "pending" && !s.runnable}
            onClick={() => setActiveId(s.id)}
          />
        ))}
      </aside>

      <main className="panel">
        {err && <div className="banner fail">{err}</div>}
        {activeId === CONFIG_ID ? (
          <ConfigPanel config={config} onSave={async (k, v) => { await api.setConfig(k, v); await refreshConfig(); await refreshSteps() }} />
        ) : (
          <StepPanel detail={detail} onRun={() => onRun(activeId)} />
        )}
      </main>
    </div>
  )
}

function RailItem(props: {
  num: number
  name: string
  meta: string
  status: StepState
  active: boolean
  locked: boolean
  onClick: () => void
}) {
  return (
    <div className={`step-item ${props.active ? "active" : ""} ${props.locked ? "locked" : ""}`} onClick={props.onClick}>
      <div className="step-num">{props.num}</div>
      <div style={{ flex: 1 }}>
        <div className="step-name">{props.name}</div>
        <div className="step-meta">{props.meta}</div>
      </div>
      <span className={`dot ${props.status}`} />
    </div>
  )
}

function ConfigPanel({ config, onSave }: { config: ConfigResponse | null; onSave: (key: string, value: string) => Promise<void> }) {
  if (!config) return <p className="desc">Loading configuration…</p>
  // The broadcast/dry-run setting is shown as a dedicated toggle, not a text field.
  const groups = groupFields(config.fields.filter((f) => f.key !== "MIGRATION_BROADCAST"))
  const dryRun = !config.broadcast
  return (
    <>
      <h2>Configuration</h2>
      <p className="desc">
        All settings load from the environment. Override or fill any below. Secrets are write-only — they show as set,
        never echoed. The migration cannot start until every required value is set.
      </p>

      <DryRunToggle dryRun={dryRun} onChange={(on) => onSave("MIGRATION_BROADCAST", on ? "false" : "true")} />

      {config.missing.length > 0 ? (
        <div className="banner warn">{config.missing.length} required setting(s) missing: {config.missing.join(", ")}</div>
      ) : (
        <div className="banner ok">All required configuration is set.</div>
      )}
      {groups.map(([group, fields]) => (
        <div className="section" key={group}>
          <h3>{group}</h3>
          {fields.map((f) => (
            <ConfigField key={f.key} field={f} onSave={onSave} />
          ))}
        </div>
      ))}
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
        <div className="dryrun-title">{dryRun ? "Dry run" : "LIVE — broadcasting"}</div>
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
        {!field.secret && field.is_set && <span className="val">{field.value}</span>}
      </div>
      <div className="purpose">{field.purpose}</div>
      <div style={{ display: "flex", gap: 8 }}>
        <input
          type={field.secret ? "password" : "text"}
          placeholder={field.is_set ? "override…" : "set value…"}
          value={value}
          onChange={(e) => setValue(e.target.value)}
          onKeyDown={(e) => { if (e.key === "Enter" && value.trim()) void save() }}
        />
        <button className="secondary small" disabled={saving || !value.trim()} onClick={() => void save()}>
          Save
        </button>
      </div>
    </div>
  )
}

function StepPanel({ detail, onRun }: { detail: StepDetail | null; onRun: () => void }) {
  if (!detail) return <p className="desc">Loading step…</p>
  const { step, run } = detail
  const running = run.status === "running"
  return (
    <>
      <h2>{step.name}</h2>
      <p className="desc">{step.description}</p>

      {step.error && <div className="banner fail">{step.error}</div>}
      {step.status === "success" && <div className="banner ok">Completed.</div>}
      {!step.runnable && step.status === "pending" && step.reason && <div className="banner warn">{step.reason}</div>}

      <div style={{ marginBottom: 20 }}>
        <button disabled={!step.runnable} onClick={onRun}>
          {running ? "Running…" : step.status === "failed" ? "Retry step" : "Run step"}
        </button>
      </div>

      {step.config.length > 0 && (
        <div className="section">
          <h3>Relevant configuration</h3>
          {step.config.map((f) => (
            <div className="field" key={f.key}>
              <div className="row">
                <div>
                  <span className="label">{f.label}</span>
                  <span className={`tag ${f.is_set ? "set" : "unset"}`} style={{ marginLeft: 8 }}>
                    {f.is_set ? "set" : "not set"}
                  </span>
                </div>
                {!f.secret && f.is_set && <span className="val">{f.value}</span>}
              </div>
              <div className="purpose">{f.purpose}</div>
            </div>
          ))}
        </div>
      )}

      {hasChecks(run.data) && (
        <div className="section">
          <h3>Checks</h3>
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
        <div className="section">
          <h3>Live data</h3>
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
        <div className="section">
          <h3>Logs</h3>
          <div className="logs">
            {run.logs.map((l, i) => (
              <div key={i}>
                <span className="ts">{fmtTime(l.time)} </span>
                {l.text}
              </div>
            ))}
          </div>
        </div>
      )}
    </>
  )
}

// --- helpers ---------------------------------------------------------------

interface CheckResult { name: string; ok: boolean; detail: string }

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
  return Object.entries(data).filter(([k]) => k !== "checks")
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
