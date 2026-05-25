# Frontend dynamic config — Landing 1

The first of a multi-landing refactor that converts the web UI from build-time static chain config to runtime config fetched from the backend's `/config` endpoint. This landing introduces the infrastructure with **no consumers**, so production behavior is unchanged but every subsequent landing has somewhere to plug into.

## Current branch notes

The `pjol/config-loadin` implementation has intentionally moved past this original Landing 1 boundary:

- Backend `/config` now loads the per-community Citizen Wallet config by alias at boot, falls back to a root backend JSON file with the same Citizen Wallet shape, and fails boot if neither source loads.
- `/config` returns the Citizen Wallet-shaped payload, not the normalized `active_chain_id` shape sketched below.
- Chain-specific fields with no Citizen Wallet home, such as backing-asset setup, bridge/Zapper contracts, and faucet contracts, are loaded from backend env and exposed under top-level `extras`.
- Web and mobile both fetch `/config` during app boot and use it for chain, token, account factory, paymaster, RPC, explorer, app origin, and implementation-specific extras.
- Citizen Wallet fields remain authoritative wherever they exist. BYUSD/HONEY are resolved from the CW `tokens` map first; extras only fill them when the token entries are absent.
- `frontend/app.config.ts` has been removed instead of kept as a static frontend fallback. The fallback lives in `backend/community-config.json`.
- SSR injection, staleness banners, and parity/debug scripts remain differences from this plan and are still future work.

## Goal

Ship a `ChainConfigProvider` + `useChainConfig()` hook that fetches `GET /config` on app boot, transforms the payload into the runtime shape the rest of the app needs, and falls back to the current static `lib/constants.ts` values if the fetch fails. No existing code reads from the hook yet — `lib/constants.ts` exports stay exactly as they are. After this lands, the dynamic config payload is live in production, observable, and one Edit away from being adopted.

## Non-goals

- Refactoring `Providers.tsx`, `lib/paymaster/client.ts`, or `lib/wallets/wallets.ts` to consume the hook. That's Landing 2.
- SSR injection of the config into HTML. Optional optimization for Landing 2 or later.
- CSP changes to allow Celo RPC origins. Belongs with the chain flip itself.
- Per-user feature flag (`chain_preference` column). Layered on top later.
- Mobile-side dynamic config. Parallel track; same wire format but separate code.
- Actually moving anything to Celo. This landing happens entirely with active_chain_id = 80094.

## Motivation

Right now `app/frontend/app.config.ts` is a hardcoded TypeScript module that bakes Berachain chain ID, SFLUV token address, factory, paymaster, and the viem `Chain` object into the bundle at build time. Every file in the frontend that needs any of these imports from `lib/constants.ts`, which re-exports the static module. The result is that flipping chains requires a code change and a redeploy.

The Go backend already serves a fully-formed `/config` endpoint (`app/backend/handlers/app_client_config.go:143`) with everything the frontend needs: `active_chain_id`, chain map, token map, account map, migration state, feature flags. The infrastructure is half-built — the consumer side is what's missing.

By introducing the consumer with no callsites, we get to:

1. Verify the fetch works in production and the transform produces values byte-identical to today's static config (parity check before we trust anything else).
2. Set up observability so we'll notice if `/config` starts returning unexpected shapes after backend env changes.
3. Make Landing 2 a focused PR (consumer refactor only) rather than a sprawling one (provider + consumers + tests + rollback).

## The shape we're building

### File layout

```
app/frontend/
├── context/
│   └── ChainConfigProvider.tsx       # NEW — provider + hook
├── lib/
│   ├── chainConfig/
│   │   ├── types.ts                  # NEW — ResolvedChainConfig type
│   │   ├── transform.ts              # NEW — wire payload → runtime shape
│   │   ├── fallback.ts               # NEW — static fallback derived from app.config.ts
│   │   └── fetch.ts                  # NEW — /config fetcher
│   └── constants.ts                  # UNCHANGED in this landing
└── app/
    └── layout.tsx                    # MODIFIED — wrap children in ChainConfigProvider
```

`lib/constants.ts` exports stay identical so nothing breaks. The provider mounts above the existing providers in `app/layout.tsx` but its value is read by zero callsites in this landing.

### Runtime shape

```ts
// lib/chainConfig/types.ts
import type { Chain, Address } from "viem";
import type { CommunityConfig } from "@citizenwallet/sdk";

export type ResolvedChainConfig = {
  source: "remote" | "fallback";        // observability
  configVersion: string;                // from /config response
  fetchedAt: string;                    // ISO timestamp
  chain: Chain;                         // viem Chain, built from payload
  chainId: number;                      // primary chain (active_chain_id)
  tokenAddress: Address;                // SFLUV ERC20 on active chain
  tokenDecimals: number;
  tokenSymbol: string;
  factoryAddress: Address;
  entrypointAddress: Address;
  paymasterAddress: Address;
  paymasterType: string;
  rpcUrl: string;
  engineRpcUrl: string;
  engineWsUrl: string;
  explorerUrl: string;
  community: CommunityConfig;           // CitizenWallet SDK config
  migrationState: "pre_cutover" | "in_progress" | "post_cutover" | string;
  features: {
    migrationBanner: boolean;
    sendsEnabled: boolean;
    redemptionsEnabled: boolean;
    workflowPayoutsEnabled: boolean;
    merchantPaymentsEnabled: boolean;
  };
};
```

### Provider behavior

```ts
// context/ChainConfigProvider.tsx (sketch)
"use client";

export function ChainConfigProvider({ children }: { children: ReactNode }) {
  const [config, setConfig] = useState<ResolvedChainConfig | null>(null);

  useEffect(() => {
    let cancelled = false;
    fetchClientConfig()
      .then(payload => transformPayload(payload))
      .catch(err => {
        // Loud log, then fall back so production keeps working
        console.error("[ChainConfig] /config fetch failed, using fallback", err);
        return staticFallback();
      })
      .then(resolved => { if (!cancelled) setConfig(resolved); });
    return () => { cancelled = true; };
  }, []);

  if (!config) return <>{children}</>;  // L1: don't block render — provider value is null until ready
  return <ChainConfigContext.Provider value={config}>{children}</ChainConfigContext.Provider>;
}

export const useChainConfig = (): ResolvedChainConfig | null => useContext(ChainConfigContext);
```

Notes on this shape:

- **The provider does not block render in Landing 1.** It can't — no consumers yet, and blocking would make this landing user-visible. The hook returns `null` until config resolves, and any consumer added in Landing 2 will need to handle the loading state (or we switch to a blocking variant at that point).
- **Static fallback always succeeds.** It's pure code, no network. Worst case is `/config` is down and we use the same values we'd use today.
- **`source` field on the resolved config** lets us tell at a glance whether we're running on remote or fallback. Useful for both runtime debugging and the parity verification step.

### Transform

The transform is where the `/config` wire shape and the CitizenWallet SDK shape disagree. The backend keys tokens as `"primary"` (logical) and accounts as `"primary"`. The CitizenWallet `CommunityConfig` constructor wants composite keys (`"<chainId>:<address>"`). The transform handles the remapping.

```ts
// lib/chainConfig/transform.ts (sketch)
export function transformPayload(p: ClientConfigResponse): ResolvedChainConfig {
  const activeChain = p.chains[String(p.active_chain_id)];
  if (!activeChain) {
    throw new Error(`active_chain_id ${p.active_chain_id} missing from chains map`);
  }
  const primaryToken = p.tokens["primary"];
  const primaryAccount = p.accounts["primary"];
  if (!primaryToken || !primaryAccount) {
    throw new Error("/config response missing primary token or account");
  }

  // Build the shape CommunityConfig expects (composite keys, nested community fields)
  const cwConfig = {
    community: {
      name: p.community.name,
      alias: p.community.alias,
      custom_domain: p.community.custom_domain,
      logo: p.community.logo,
      profile: { address: p.community.profile_address, chain_id: p.active_chain_id },
      primary_token: { address: primaryToken.address, chain_id: primaryToken.chain_id },
      primary_account_factory: {
        address: primaryAccount.account_factory_address,
        chain_id: primaryAccount.chain_id,
      },
    },
    tokens: {
      [`${primaryToken.chain_id}:${primaryToken.address}`]: primaryToken,
    },
    accounts: {
      [`${primaryAccount.chain_id}:${primaryAccount.account_factory_address}`]: primaryAccount,
    },
    chains: {
      [String(activeChain.id)]: {
        id: activeChain.id,
        node: { url: activeChain.engine_rpc_url, ws_url: activeChain.engine_ws_url },
      },
    },
    version: 4,
  };

  return {
    source: "remote",
    configVersion: p.config_version,
    fetchedAt: p.source.fetched_at,
    chain: {
      id: activeChain.id,
      name: activeChain.name,
      nativeCurrency: activeChain.native_currency,
      rpcUrls: { default: { http: [activeChain.rpc_url] } },
      blockExplorers: { default: activeChain.explorer },
    },
    chainId: p.active_chain_id,
    tokenAddress: primaryToken.address as Address,
    tokenDecimals: primaryToken.decimals,
    tokenSymbol: primaryToken.symbol,
    factoryAddress: primaryAccount.account_factory_address as Address,
    entrypointAddress: primaryAccount.entrypoint_address as Address,
    paymasterAddress: primaryAccount.paymaster_address as Address,
    paymasterType: primaryAccount.paymaster_type,
    rpcUrl: activeChain.rpc_url,
    engineRpcUrl: activeChain.engine_rpc_url,
    engineWsUrl: activeChain.engine_ws_url,
    explorerUrl: activeChain.explorer.url,
    community: new CommunityConfig(cwConfig),
    migrationState: p.migration?.state ?? "pre_cutover",
    features: {
      migrationBanner: p.features?.migration_banner ?? false,
      sendsEnabled: p.features?.sends_enabled ?? true,
      redemptionsEnabled: p.features?.redemptions_enabled ?? true,
      workflowPayoutsEnabled: p.features?.workflow_payouts_enabled ?? true,
      merchantPaymentsEnabled: p.features?.merchant_payments_enabled ?? true,
    },
  };
}
```

### Static fallback

The fallback returns the same `ResolvedChainConfig` shape, populated from today's `lib/constants.ts` / `app.config.ts` values. This is what gets returned if `/config` is unreachable, malformed, or times out.

```ts
// lib/chainConfig/fallback.ts (sketch)
import config, { chain } from "@/app.config";
import { CommunityConfig } from "@citizenwallet/sdk";

export function staticFallback(): ResolvedChainConfig {
  const community = new CommunityConfig(config);
  const primaryAccount = community.accounts[Object.keys(config.accounts)[0]];
  const primaryToken = (config.tokens as any)[Object.keys(config.tokens)[0]];
  return {
    source: "fallback",
    configVersion: "static",
    fetchedAt: new Date().toISOString(),
    chain,
    chainId: config.community.primary_token.chain_id,
    tokenAddress: config.community.primary_token.address as Address,
    tokenDecimals: primaryToken.decimals,
    tokenSymbol: primaryToken.symbol,
    factoryAddress: primaryAccount.account_factory_address as Address,
    entrypointAddress: primaryAccount.entrypoint_address as Address,
    paymasterAddress: primaryAccount.paymaster_address as Address,
    paymasterType: primaryAccount.paymaster_type,
    rpcUrl: process.env.NEXT_PUBLIC_CHAIN_RPC_URL ?? "https://rpc.berachain.com",
    engineRpcUrl: (config.chains as any)["80094"].node.url,
    engineWsUrl: (config.chains as any)["80094"].node.ws_url,
    explorerUrl: "https://berascan.com",
    community,
    migrationState: "pre_cutover",
    features: {
      migrationBanner: false,
      sendsEnabled: true,
      redemptionsEnabled: true,
      workflowPayoutsEnabled: true,
      merchantPaymentsEnabled: true,
    },
  };
}
```

### Fetcher

Single-purpose: hit `/config`, parse, return. No retry logic in Landing 1 — if it fails, fallback wins and we log loudly.

```ts
// lib/chainConfig/fetch.ts
import { BACKEND } from "@/lib/constants";
import type { ClientConfigResponse } from "@/types/clientConfig";

const TIMEOUT_MS = 5000;

export async function fetchClientConfig(): Promise<ClientConfigResponse> {
  const controller = new AbortController();
  const t = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(`${BACKEND}/config`, {
      signal: controller.signal,
      headers: { Accept: "application/json" },
    });
    if (!res.ok) throw new Error(`/config returned ${res.status}`);
    return await res.json();
  } finally {
    clearTimeout(t);
  }
}
```

The `ClientConfigResponse` type should be hand-typed against `app/backend/structs/app_client_config.go`. Easy enough; the struct is stable.

## Work items

| # | Task | Files | Est |
|---|------|-------|-----|
| 1 | Verify `/config` is live in prod by curling `https://api.sfluv.org/config` from a network-reachable machine | (none) | 5m |
| 2 | Add `types/clientConfig.ts` matching the Go struct | `types/clientConfig.ts` | 1h |
| 3 | Implement `lib/chainConfig/fetch.ts` | `lib/chainConfig/fetch.ts` | 30m |
| 4 | Implement `lib/chainConfig/transform.ts` with unit tests against a snapshot of the prod `/config` response | `lib/chainConfig/transform.ts`, `lib/chainConfig/transform.test.ts` | 3h |
| 5 | Implement `lib/chainConfig/fallback.ts` | `lib/chainConfig/fallback.ts` | 1h |
| 6 | Implement `context/ChainConfigProvider.tsx` (non-blocking variant) | `context/ChainConfigProvider.tsx` | 2h |
| 7 | Wrap `<Providers>` with `<ChainConfigProvider>` in `app/layout.tsx` | `app/layout.tsx` | 15m |
| 8 | Write a `chainConfigDiff()` utility that compares two `ResolvedChainConfig` objects field-by-field and returns the diffs as a string. Used in the parity verification step. | `lib/chainConfig/diff.ts` | 1h |
| 9 | Add a temporary dev-only `<ChainConfigDebugBanner>` component that renders the resolved config and any diffs against the static fallback at the top of the page when `NEXT_PUBLIC_CHAIN_CONFIG_DEBUG=true`. Strip after parity confirmed. | `components/dev/ChainConfigDebugBanner.tsx` | 2h |
| 10 | Add a one-off parity check: in a CI step or local script, snapshot the prod `/config` response, run it through `transformPayload`, compare to `staticFallback()` output, fail if they don't match on the chain-coupling fields (chain, chainId, tokenAddress, factoryAddress, paymasterAddress, entrypointAddress) | `scripts/check-config-parity.ts` | 2h |
| 11 | Sentry/Datadog event when `source === "fallback"` (or use whatever observability the app uses — verify what's already wired) | `context/ChainConfigProvider.tsx`, observability infra | 1-2h |
| 12 | Deploy to prod, watch fallback rate for a week | (none) | 5d bake |

**Implementation effort:** ~14 hours of focused work, ideally one engineer over 2-3 days. Plus the bake period.

## Acceptance criteria

A reasonable reviewer should be able to confirm all of these before approving:

1. `useChainConfig()` exists and returns a `ResolvedChainConfig | null`.
2. `app/layout.tsx` mounts `<ChainConfigProvider>` above `<Providers>`.
3. With the debug banner enabled (`NEXT_PUBLIC_CHAIN_CONFIG_DEBUG=true`), the rendered banner shows `source: remote` in non-degraded conditions and `source: fallback` if `/config` is killed (verifiable by temporarily setting `BACKEND` to a black-hole URL in a dev build).
4. The parity check script passes against the current prod `/config` response. The diff is empty for chain-coupling fields. Any non-empty diff for non-chain fields (e.g., `features` toggles, `migrationState`, `tokenSymbol`) is documented in the PR description.
5. `lib/constants.ts` exports are unchanged. No existing imports of `CHAIN`, `CHAIN_ID`, `SFLUV_TOKEN`, etc. are affected.
6. Production smoke test: page loads, wallet connects, balance reads work, sends work. (i.e., business as usual since no consumers were migrated.)
7. After a week of production traffic, fallback rate logged via observability is < 0.1%. If higher, root-cause before starting Landing 2.

## Risks and mitigations

**Risk: `/config` isn't actually deployed in production.** The handler exists on `main` as of May 15 commit `52cc690`, but I couldn't verify from this environment that it's live on `api.sfluv.org`. Mitigation: Work item #1 verifies before any other work starts. If it's not deployed, run `update-production-backend.sh` first.

**Risk: transform misses a field, fallback masks the bug.** If `/config` succeeds but the transform crashes on an unexpected shape, the fallback kicks in and nothing visibly breaks — but we're silently running on stale config. Mitigation: log `source: fallback` events at error level, set up an alert for fallback rate > some threshold (e.g., 1%). The parity check (work item #10) catches this at PR review time.

**Risk: `/config` is slow and delays first render.** Right now there are no consumers, so the provider doesn't block render. But the fetch still runs on every page load. Mitigation: 5-second timeout in `fetch.ts`, fast fallback. If we observe slowness in practice, consider moving to SSR injection in Landing 2.

**Risk: CitizenWallet `CommunityConfig` constructor rejects the transformed payload.** The composite-key remapping is fiddly and the SDK might require fields we didn't include. Mitigation: unit test the transform end-to-end including the `new CommunityConfig(cwConfig)` call, against a snapshot of real prod `/config`. If the SDK is strict about extra fields like `scan`, `ipfs`, or `plugins` that today's `app.config.ts` has but `/config` doesn't, either add them to `/config` (small backend PR) or supply sensible defaults in the transform.

**Risk: backend tokens map contains `celo_usdc` and other entries the transform doesn't expect.** The `/config` handler returns both `"primary"` and `"celo_usdc"` in the tokens map. Mitigation: transform reads only `tokens["primary"]` and ignores the rest. Make this explicit in the transform code so future additions don't surprise us.

**Risk: drift between static fallback and dynamic config over time.** Once we add the layer, there are two sources of truth. Mitigation: Landing 2 migrates consumers off the static side, so the duplication is short-lived. While it exists, the parity check in CI catches drift.

**Risk: `CommunityConfig` is constructed twice on every page load — once in fallback, once in transform — and might be expensive.** Mitigation: measure before optimizing. If it's slow, lazy-construct on first use of `community` field. Probably not worth it.

## Verification plan

Before starting:

- [ ] Curl `https://api.sfluv.org/config` from a network-reachable machine. Save the response as a fixture.
- [ ] Confirm the response shape matches `structs.ClientConfigResponse` in `app/backend/structs/app_client_config.go`.
- [ ] Confirm `active_chain_id` is 80094 in prod (sanity check we're not already on Celo somehow).

During development:

- [ ] Unit test `transformPayload(promoFixture)` against expected output.
- [ ] Unit test `transformPayload({})` and other malformed inputs — expect explicit errors, not silent fallback.
- [ ] Unit test `staticFallback()` returns a valid `ResolvedChainConfig`.
- [ ] Integration test: render `<ChainConfigProvider>` with a mocked successful fetch and assert the hook returns the transformed value.
- [ ] Integration test: same but with a failing fetch — assert the hook returns the fallback.

Before merging:

- [ ] Run `scripts/check-config-parity.ts` against prod `/config` — must produce no diffs on chain-coupling fields.
- [ ] Manual smoke: dev build with `NEXT_PUBLIC_CHAIN_CONFIG_DEBUG=true`. Confirm banner appears, shows `source: remote`. Confirm wallet connects and works exactly as today.
- [ ] Manual smoke with `BACKEND` set to a black-hole URL: confirm banner shows `source: fallback`, app still functions identically.

After deploying:

- [ ] Observability dashboard: fallback rate per hour. Target < 0.1% sustained.
- [ ] One week bake. No user-facing incidents tied to ChainConfigProvider.
- [ ] Remove `<ChainConfigDebugBanner>` before tagging the bake-complete commit. Land that as the close-out of Landing 1.

## Pre-flight checklist (things to confirm before opening the branch)

1. `/config` returns 200 from `https://api.sfluv.org/config` with the expected shape. If 404, deploy the backend first (`app/update-production-backend.sh`).
2. `NEXT_PUBLIC_BACKEND_URL` (or its aliases `NEXT_PUBLIC_BACKEND_BASE_URL` / `NEXT_PUBLIC_APP_BASE_URL`) is set in the prod frontend's env so `BACKEND` in `lib/constants.ts:23-27` resolves to the real backend, not `localhost:8080`.
3. Confirm whoever currently owns `app.config.ts` is OK with it becoming legacy. It stays in the repo (the fallback reads from it) but its role shrinks.
4. Pick observability target: existing logging? Sentry? A new endpoint that logs fallback events to the backend? Lowest effort: `console.error` at startup with a recognizable tag and grep the browser console during smoke. For the production bake, something queryable is preferable.

## After Landing 1

Once Landing 1 has baked for a week with low fallback rate, Landings 2 and 3 can proceed in order:

**Landing 2:** Migrate the chain-coupled consumers. `Providers.tsx` reads `chain` from the hook, `lib/paymaster/client.ts` becomes a factory taking config as an argument, `lib/wallets/wallets.ts` likewise, the handful of pages reading `CHAIN`/`CHAIN_ID`/`SFLUV_TOKEN` switch to the hook. This is where the provider becomes blocking — it has to resolve before mounting `<PrivyProvider>`. SSR injection of `/config` into the HTML is the natural way to make this non-jarring; that's worth doing in this landing rather than as a future cleanup.

**Landing 3:** Wire the per-user `chain_preference` flag. Backend migration adds the column and an admin endpoint. `/config` becomes auth-aware and returns per-user values when a Privy session token is present. Cookie-based steering keeps the SSR injection working without round-tripping auth.

**Landing 4 (the chain flip):** Bump the backend env block (`CHAIN_ID=42220`, `RPC_URL=https://forno.celo.org`, `TOKEN_ID=<celo SFLUV>`, etc.). Add Celo RPC to CSP allowlist. Flip individual users via the `chain_preference` mechanism, monitor, then default new users to Celo, then force-flip the long tail.

Each subsequent landing assumes its predecessor has baked. The bake periods are where the value of this incremental approach lives — every landing has a real production audience before the next one starts.
