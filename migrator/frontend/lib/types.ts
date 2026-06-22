export interface FieldView {
  key: string
  label: string
  group: string
  secret: boolean
  required: boolean
  purpose: string
  is_set: boolean
  value: string
}

export interface ConfigResponse {
  fields: FieldView[]
  missing: string[]
  broadcast: boolean
}

export type StepState = "pending" | "running" | "success" | "failed"

export interface StepSummary {
  id: string
  name: string
  description: string
  config: FieldView[]
  status: StepState
  runnable: boolean
  reason?: string
  error?: string
}

export interface LogLine {
  time: string
  text: string
}

export interface StepRunView {
  status: StepState
  logs: LogLine[]
  data: Record<string, unknown>
  error?: string
  started_at?: string
  finished_at?: string
}

export interface StepDetail {
  step: StepSummary
  run: StepRunView
}
