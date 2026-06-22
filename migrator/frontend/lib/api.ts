import type { ConfigResponse, StepDetail, StepSummary } from "./types"

const BASE = process.env.NEXT_PUBLIC_API_BASE || "http://localhost:8090"

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(BASE + path, {
    ...init,
    headers: { "Content-Type": "application/json", ...(init?.headers || {}) },
  })
  const text = await res.text()
  let body: unknown = undefined
  try {
    body = text ? JSON.parse(text) : undefined
  } catch {
    body = undefined
  }
  if (!res.ok) {
    let message = `request failed (${res.status})`
    if (body && typeof (body as { error?: unknown }).error === "string") {
      message = (body as { error: string }).error
    }
    throw new Error(message)
  }
  return body as T
}

export const api = {
  getConfig: () => request<ConfigResponse>("/api/config"),
  setConfig: (key: string, value: string) =>
    request<ConfigResponse>("/api/config", { method: "PUT", body: JSON.stringify({ key, value }) }),
  getSteps: () => request<{ steps: StepSummary[] }>("/api/steps"),
  getStep: (id: string) => request<StepDetail>(`/api/steps/${id}`),
  runStep: (id: string) => request<{ status: string }>(`/api/steps/${id}/run`, { method: "POST" }),
}
