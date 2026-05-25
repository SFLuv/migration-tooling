# Frontend dynamic config — Landing 2

The second landing in the dynamic-config series. Landing 1 introduced the provider with no consumers. Landing 2 makes the provider the source of truth: every chain-coupled file in the frontend stops reading from `lib/constants.ts` and starts reading from the `useChainConfig()` hook. The provider becomes blocking (its config has to resolve before `<PrivyProvider>` mounts), and we adopt SSR injection of `/config` into the HTML so the blocking is effectively zero-latency for the user.

After this lands, switching the active chain is a backend env change and a redeploy of the Go backend — no frontend rebuild needed.

## Current branch notes

The `pjol/config-loadin` branch implements the consumer migration differently from this staged Landing 2 plan:

- Backend `/config` is the single chain source for web and mobile, and the clients no longer define BYUSD/HONEY/Zapper/faucet/backing-assets in client env or hardcoded constants.
- `extras` is now the bridge only for chain-specific values that Citizen Wallet config does not model. The backend reads `HONEY_*`, `BYUSD_*`, `ZAPPER_*`, `FAUCET_*`, and `BACKING_ASSETS` env aliases, merges them into `/config.extras`, and preserves unknown extras fields.
- Citizen Wallet fields remain authoritative wherever they exist. Web resolves BYUSD/HONEY from the CW `tokens` map first, then falls back to extras only if those tokens are not present. Existing callsites still expose convenience fields like `byusdTokenAddress`, `honeyTokenAddress`, `zapperContractAddress`, and `faucetAddress`.
- Mobile maps the same `/config.extras` fields into `AppClientConfig`; reward labeling now uses fetched `faucetAddress` instead of a bundled faucet address.
- The branch does not yet implement SSR injection, the `__sfluv_config` script tag, staleness banner, or config parity scripts from this document.
- The original plan kept `app.config.ts` as a frontend fallback. The branch removes it and relies on backend boot-time remote/fallback config instead.

## Goal

Replace every build-time chain reference in `app/frontend/` with a runtime read from `useChainConfig()`, fed by a `/config` payload embedded in the initial HTML by the Next.js server. The provider blocks render until config is resolved (which, with SSR injection, is synchronous at first paint). After this landing, the only place `app.config.ts` is read is inside `staticFallback()` — and the fallback only runs when the SSR fetch itself fails.

## Non-goals

- The chain flip itself. We're still pointed at Berachain after this lands. The backend's env block still has `CHAIN_ID=80094`.
- CSP changes. The middleware still hardcodes `rpc.berachain.com` in the allowlist — that gets updated in the chain-flip landing.
- Per-user `chain_preference`. Landing 3 layers that on top once the consumer side is settled.
- Removing the Berachain-specific DeFi integrations (Zapper, Honey, BYUSD). They get feature-gated, not deleted. Their actual removal happens once Celo is live and these features are off.
- Mobile-side consumer migration. Parallel track; same shape but different files.

## Why this landing matters

Landing 1 proved that fetching `/config` works and the transform produces config equivalent to today's static defaults. Landing 2 cashes in on that work by actually using it.

Two specific reasons this is the right moment:

1. **It unblocks the per-user feature flag (Landing 3).** Until consumers read from the provider, a per-user `chain_preference` value coming back from `/config` has nowhere to go. After Landing 2, the same payload that already drives the global chain choice can be steered per-user without any further consumer-side changes.

2. **It removes the redeploy-to-flip-chains requirement.** Today, flipping chains means a code change to `app.config.ts`, a build, and a deploy. After Landing 2, the same change is a backend env update and a 30-second CDN cache invalidation. That's the gap that turns the chain migration from a "release event" into a routine operation.

## Two architectural shifts

### Shift 1: SSR injection of `/config`

The provider becomes blocking — it must resolve before `<PrivyProvider>` mounts, because PrivyProvider locks in `defaultChain` at construction. If we did this with a client-side fetch, every user would see a spinner on every page load while the provider resolves. Worse, if the fetch is slow, Privy might mount with stale-cached config and then need to remount when the real config arrives.

The fix is to fetch `/config` server-side, in a React Server Component at the root of `app/layout.tsx`, and embed the resolved payload in the HTML as a script tag. The client-side provider reads it synchronously on first render — no spinner, no double-mount, no race.

```tsx
// app/layout.tsx (sketch)
import { transformPayload, staticFallback } from "@/lib/chainConfig";
import { ChainConfigProvider } from "@/context/ChainConfigProvider";

async function loadConfig() {
  const backend = process.env.BACKEND_BASE_URL!;
  try {
    const res = await fetch(`${backend}/config`, { next: { revalidate: 30 } });
    if (!res.ok) throw new Error(`status ${res.status}`);
    return transformPayload(await res.json());
  } catch (err) {
    console.error("[ChainConfig] SSR fetch failed, embedding fallback", err);
    return { ...staticFallback(), source: "fallback" as const, fallbackReason: String(err) };
  }
}

export default async function RootLayout({ children }: { children: React.ReactNode }) {
  const config = await loadConfig();
  return (
    <html>
      <body>
        <script
          id="__sfluv_config"
          type="application/json"
          dangerouslySetInnerHTML={{ __html: JSON.stringify(config) }}
        />
        <ChainConfigProvider initialConfig={config}>
          {children}
        </ChainConfigProvider>
      </body>
    </html>
  );
}
```

The provider, in turn, accepts `initialConfig` as a prop, uses it as the initial state, and never blocks render in the SSR path. On client-side navigation, the script tag is already there. The provider does set up a refresh mechanism (see Shift 2) but it's never the gate for first paint.

The `revalidate: 30` window means a backend env change propagates to the edge in 30 seconds. That's fast enough for routine operations and slow enough that the backend doesn't get hammered on cold paths.

### Shift 2: consumers read from the hook (or accept config as an argument)

Every file that today imports `CHAIN`, `CHAIN_ID`, `SFLUV_TOKEN`, `FACTORY`, `PAYMASTER`, `COMMUNITY`, etc. from `lib/constants.ts` switches to one of two patterns:

**Pattern A — React components:** swap the import for `useChainConfig()`.

```tsx
// before
import { CHAIN, SYMBOL } from "@/lib/constants";
function ReceiveModal() { return <p>Send {SYMBOL} on {CHAIN.name}</p>; }

// after
import { useChainConfig } from "@/context/ChainConfigProvider";
function ReceiveModal() {
  const { tokenSymbol, chain } = useChainConfig();
  return <p>Send {tokenSymbol} on {chain.name}</p>;
}
```

**Pattern B — non-React lib modules:** convert from "exports a singleton built at module load" to "exports a factory that takes config." Callers (always React components) construct an instance from the hook and memoize.

```tsx
// before — lib/paymaster/client.ts
import { CHAIN } from "@/lib/constants";
export const bundler = createBundlerClient({ chain: CHAIN, transport: http(...) });

// after — lib/paymaster/client.ts
export function createViemClients(config: ResolvedChainConfig) {
  return {
    bundler: createBundlerClient({ chain: config.chain, transport: http(config.community.primaryRPCUrl) }),
    cw_bundler: new BundlerService(config.community),
    publicClient: createPublicClient({ chain: config.chain, transport: http(config.community.primaryRPCUrl) }),
  };
}

// new — context/ViemClientsProvider.tsx (or just inline the useMemo at callsites)
export function useViemClients() {
  const config = useChainConfig();
  return useMemo(() => createViemClients(config), [config]);
}
```

For class-based modules like `lib/wallets/wallets.ts`, the cleanest fix is to thread `ResolvedChainConfig` into the constructor and reference `this.chainConfig` instead of imported constants throughout the methods. That's a wide diff (59 references in one file) but a mechanical one — every `CHAIN` becomes `this.chainConfig.chain`, every `SFLUV_TOKEN` becomes `this.chainConfig.tokenAddress`, etc.

## Consumer inventory

Pulled from a grep of `lib/constants.ts` imports across the frontend. Files split by category:

### Chain-coupled — must migrate in this landing

**Lib modules (Pattern B — factory or constructor-arg refactor):**

| File | Imports | Refs | Approach |
|---|---|---|---|
| `lib/paymaster/client.ts` | `CHAIN`, `COMMUNITY` | 3 module-level singletons | Convert exports to `createViemClients(config)` factory. Add `useViemClients()` hook. |
| `lib/wallets/wallets.ts` | `CHAIN`, `SFLUV_DECIMALS`, `FACTORY`, `SFLUV_TOKEN`, plus Berachain DeFi (`BYUSD_*`, `HONEY_*`, `ZAPPER_*`) | 59 in one ~1300 line file | Thread `ResolvedChainConfig` into `AppWallet` constructor, replace all imports with `this.chainConfig.*`. Feature-gate the zapper/honey/byusd methods behind `features.zapperEnabled`. |
| `lib/redeem-link.ts` | (no constants import, but hardcodes `"wallet.berachain.sfluv.org"` as `DEFAULT_CW_ALIAS`) | 1 string literal | Read from `config.community.alias` via a small `getCwAlias(config)` helper. |

**React contexts and components (Pattern A — hook swap):**

| File | Imports | Refs | Notes |
|---|---|---|---|
| `context/Providers.tsx` | `CHAIN` | 2 (PrivyProvider config) | **Critical.** This file determines whether the whole tree mounts at all. Must read from the hook *or* receive config as a prop from the layout. |
| `context/AppProvider.tsx` | `CHAIN`, `CHAIN_ID`, `COMMUNITY`, `COMMUNITY_ACCOUNT`, `FACTORY`, `PAYMASTER` | 6 | Uses `switchChain(CHAIN_ID)` and constructs smart accounts with `FACTORY`. Swap to hook. |
| `context/TransactionProvider.tsx` | `FAUCET_ADDRESS`, `HONEY_TOKEN`, `SFLUV_DECIMALS` | a few | `FAUCET_ADDRESS` and `HONEY_TOKEN` are Berachain-specific — keep behind feature flag for now. |
| `components/wallets/receive-crypto-modal.tsx` | `CHAIN`, `SYMBOL` | 2 | Display only. |
| `components/wallets/wallet-balance-card.tsx` | `SYMBOL` | 1 | Display only. |
| `components/wallets/send-crypto-modal.tsx` | `SFLUV_DECIMALS`, `SYMBOL` | 2 | Display + parseUnits. |
| `components/wallets/cashOut_crypto_modal.tsx` | `SFLUV_DECIMALS` | 1 | parseUnits. |
| `components/transactions/transaction-list.tsx` | `SYMBOL` | 1 | Display. |
| `components/transactions/transaction-modal.tsx` | `SYMBOL` | 1 | Display. |
| `components/admin/admin-analytics-panel.tsx` | `SFLUV_DECIMALS` | 1 | formatUnits. |
| `app/wallets/[address]/page.tsx` | `CHAIN`, `HONEY_TOKEN` | 2 | `CHAIN.nativeCurrency.symbol` for gas display; `HONEY_TOKEN` is Berachain-only. |
| `app/wallets/[address]/transactions/page.tsx` | `SFLUV_DECIMALS`, `SYMBOL` | 2 | Display + format. |
| `app/admin/page.tsx` | `FAUCET_ADDRESS`, `SFLUV_DECIMALS`, `SFLUV_TOKEN` | 3 | Faucet is Berachain-only. |
| `app/redirect/page.tsx` | `COMMUNITY` | 1 | Used for CW redirect URL — needs the community alias. |

### Not chain-coupled — leave alone

Imports of `BACKEND`, `PRIVY_ID`, `PRIVY_CLIENT_ID`, `GOOGLE_MAPS_API_KEY`, `MAP_ID`, `MAP_CENTER`, `MAP_RADIUS`, `LAT_DIF`, `LNG_DIF`, `IDLE_TIMER_SECONDS`, `IDLE_TIMER_PROMPT_SECONDS`, `CW_APP_BASE_URL`, `ADMIN_ADDRESS`. These are not chain-coupled (or are configuration that doesn't change with chain), and `lib/constants.ts` keeps exporting them.

### Special cases

- **`middleware.ts`** hardcodes `https://rpc.berachain.com` in the CSP `connect-src` defaults. Not migrated in this landing — the active chain is still Berachain, the CSP is still correct. Flagged for the chain-flip landing.
- **`app.config.ts`** stays in the repo because `staticFallback()` reads from it. Its role shrinks from "primary source of truth" to "last-resort fallback when SSR fetch fails."
- **Server-side fetch CSP**: the Next.js server itself fetches `/config` server-to-server, which isn't subject to browser CSP. No change needed.

## The `ResolvedChainConfig` shape grows in Landing 2

Landing 1 defined the chain-core fields. Landing 2 adds the Berachain-specific extras as an optional block so the wallet methods that use them can still work, and so the same shape can host Celo-specific extras (or none) later:

```ts
export type ResolvedChainConfig = {
  // ... existing L1 fields ...
  extras: {
    // Berachain-only DeFi integrations. Optional because Celo won't have them.
    honeyTokenAddress?: Address;
    honeyDecimals?: number;
    byusdTokenAddress?: Address;
    byusdDecimals?: number;
    zapperAddress?: Address;
    backingAssets?: Address[];
    faucetAddress?: Address;
  };
  // Existing features block from L1
  features: { ...; zapperEnabled: boolean; };
};
```

The `extras` block is populated from the Go backend's `/config` response. In the current branch, the backend accepts server-side aliases such as `HONEY_ADDRESS`, `BYUSD_ADDRESS`, `ZAPPER_ADDRESS`, `FAUCET_ADDRESS`, and `BACKING_ASSETS`, plus the earlier `NEXT_PUBLIC_*` names for compatibility. Values are emitted under `/config.extras`; empty values are omitted. If BYUSD/HONEY are present in the Citizen Wallet `tokens` map, their env extras are omitted from the served payload and clients use the CW token entries. Clients should treat missing implementation extras as disabled integrations.

The wallet methods that use these (`zapIn`, `unwrapSwapAndBridge`, etc. in `lib/wallets/wallets.ts`) check `features.zapperEnabled` and throw a clear error if disabled. UI surfaces that expose these flows check the same flag and hide themselves.

## Work items

Ordered to keep production working at every step. Each item should be its own PR.

| # | Task | Files | Est |
|---|------|-------|-----|
| 1 | Extend Go backend `/config` payload with `extras` map (honey, byusd, zapper, backing assets, faucet, etc.) from backend env. Current branch implements this in `backend/clientconfig`. | `app/backend/clientconfig/config.go`, `app/backend/handlers/app_client_config.go` | Done |
| 2 | Extend `ResolvedChainConfig`, `transformPayload()`, `staticFallback()` from Landing 1 to include the new `extras` and `zapperEnabled` fields. Update L1's parity check to assert the new fields match between remote and static. | `lib/chainConfig/*` | 3h |
| 3 | Add `initialConfig` prop to `<ChainConfigProvider>`. Internalize it as initial state. The hook is no longer nullable — it returns `ResolvedChainConfig` directly. Update L1 typings. | `context/ChainConfigProvider.tsx`, `lib/chainConfig/types.ts` | 2h |
| 4 | Add SSR fetch in `app/layout.tsx`. Embed config script tag. Pass `initialConfig` to provider. | `app/layout.tsx` | 4h |
| 5 | Add `useViemClients()` hook backed by `createViemClients(config)` factory. Delete the three module-level singletons from `lib/paymaster/client.ts`. | `lib/paymaster/client.ts`, `lib/paymaster/index.ts`, `context/ViemClientsProvider.tsx` (or inline `useMemo`) | 4h |
| 6 | Migrate `context/Providers.tsx` — `<PrivyProvider>` reads chain from the hook. **Critical PR.** | `context/Providers.tsx` | 2h |
| 7 | Migrate `context/AppProvider.tsx` — all 6 chain refs read from hook. Verify `switchChain(chainId)` flow still works. | `context/AppProvider.tsx` | 4h |
| 8 | Refactor `lib/wallets/wallets.ts` — thread `ResolvedChainConfig` into `AppWallet` constructor. Replace all 59 chain-coupled references with `this.chainConfig.*` (or `this.chainConfig.extras.*` for DeFi). Feature-gate zapper/honey/byusd methods on `features.zapperEnabled`. | `lib/wallets/wallets.ts` | 8h |
| 9 | Migrate `context/TransactionProvider.tsx` — hook conversion, feature-gate honey-token logic. | `context/TransactionProvider.tsx` | 2h |
| 10 | Migrate display-only React consumers in bulk (`receive-crypto-modal`, `wallet-balance-card`, `send-crypto-modal`, `cashOut_crypto_modal`, `transaction-list`, `transaction-modal`, `admin-analytics-panel`, `app/wallets/[address]/page.tsx`, `app/wallets/[address]/transactions/page.tsx`, `app/admin/page.tsx`, `app/redirect/page.tsx`). | (~11 files) | 6h |
| 11 | Migrate `lib/redeem-link.ts` to read alias from a config arg instead of hardcoded literal. Update callers. | `lib/redeem-link.ts` and callers | 2h |
| 12 | Delete chain-coupled exports from `lib/constants.ts` (`CHAIN`, `CHAIN_ID`, `SFLUV_TOKEN`, `SFLUV_DECIMALS`, `SYMBOL`, `FACTORY`, `PAYMASTER`, `PAYMASTER_TYPE`, `COMMUNITY`, `COMMUNITY_TOKEN`, `COMMUNITY_ACCOUNT`, `HONEY_TOKEN`, `BYUSD_TOKEN`, `ZAPPER_CONTRACT_ADDRESS`, `FAUCET_ADDRESS`, `HONEY_DECIMALS`, `BYUSD_DECIMALS`, `BACKING_ASSETS`). Keep `BACKEND`, `PRIVY_ID`, `PRIVY_CLIENT_ID`, map config, idle timer. TypeScript surfaces every remaining caller. | `lib/constants.ts` | 1h (plus whatever the compiler turns up) |
| 13 | Add staleness detection: periodically refetch `/config` (every 5 min, or on tab visibility change) and compare `active_chain_id` and `config_version` to what's currently loaded. If they differ, show a `<ConfigStaleBanner>` prompting reload. | `context/ChainConfigProvider.tsx`, `components/banners/ConfigStaleBanner.tsx` | 4h |
| 14 | Update Landing 1's parity-check script to also assert that no chain-coupled imports of `lib/constants.ts` remain in the codebase. Lint rule or grep-in-CI. | `scripts/check-config-parity.ts` | 1h |
| 15 | Run the existing test suite against the migrated build. Fix breakages — most likely place is unit tests that import directly from `lib/constants.ts`. | (tests) | 4h |
| 16 | Manual smoke regression: login, balance, send, receive, redeem, merchant payment, admin panel. With and without the staleness banner triggered. | (none) | 4h |
| 17 | Deploy to staging, then prod. Watch for two weeks. | (none) | 2w bake |

**Implementation effort:** ~50 hours of focused work, ideally one engineer over 2 weeks. Plus the bake.

## Acceptance criteria

1. `grep -rn "from \"@/lib/constants\"" app/frontend/` returns no imports of chain-coupled constants. Only the survivor list (BACKEND, PRIVY_*, map, idle timer) appears.
2. `<PrivyProvider>` mounts exactly once per page load, with `defaultChain` matching the SSR-injected config.
3. View-source on any page contains a `<script id="__sfluv_config" type="application/json">` tag with the resolved config.
4. The wallet detail page, send modal, receive modal, redeem flow, and admin panel all work identically to today. (We're still on Berachain — behavior should be byte-identical.)
5. In a dev build with `BACKEND_BASE_URL` pointed at a black hole, SSR fetch fails, the page still renders with the static fallback, and the embedded script tag has `source: "fallback"` and a `fallbackReason`.
6. The Landing 1 parity check passes against the extended `/config` payload (including new `extras` and `zapperEnabled`).
7. Staleness banner appears when `/config` returns a different `active_chain_id` than what's loaded. Reloading clears the banner. (Test by manually flipping the backend's `CHAIN_ID` env value on a staging box and observing the banner appear in an open tab.)
8. Production bake: fallback rate stays under 0.1% for two weeks. Zero user-facing incidents tied to the migration.

## Risks and mitigations

**Risk: SSR fetch fails in production, every user gets the fallback.** The fallback equals today's static config (Berachain), so the visible behavior is the same. But it means dynamic config is silently dead and a backend env change won't propagate. Mitigation: SSR fallback is logged at error level on the Next.js server. Alert if fallback rate exceeds a threshold. The `source: "fallback"` field in the resolved config can be displayed in the admin panel for quick diagnosis.

**Risk: Next.js cache becomes too sticky and config changes don't propagate.** `revalidate: 30` should be enough, but Vercel/CDN layers can extend caching. Mitigation: verify in staging that flipping `CHAIN_ID` on the backend env causes a fresh page load to pick up the new chain within ~30 seconds. If the actual propagation is much longer, consider `cache: "no-store"` instead (every request goes to the backend).

**Risk: PrivyProvider's `defaultChain` change semantics aren't what we think.** Today PrivyProvider gets `defaultChain: CHAIN` at construction and never receives a new value. If we ever swap the underlying config without remounting, Privy might keep using the old chain. Mitigation: the staleness banner forces a full page reload when active_chain_id changes; Privy gets a fresh mount with the new chain. Don't try to be clever and reactively update Privy's chain without a remount.

**Risk: `lib/wallets/wallets.ts` refactor introduces a regression.** It's a 1300-line file with 59 chain-coupled references. The mechanical part (replace `CHAIN` with `this.chainConfig.chain`) is low-risk, but it touches a lot of surface. Mitigation: do this PR last, with full smoke regression. If the project has wallet integration tests, run them. If not, this is a reason to write some.

**Risk: the Berachain DeFi feature gating breaks the Berachain user experience.** If we accidentally set `features.zapperEnabled = false` for the Berachain config, the zapper/honey/byusd UI disappears. Mitigation: the Go backend sets the flag based on `ZAPPER_ADDRESS != ""`. As long as the env is set on Berachain prod (it is), the flag is true. Verify in the parity check.

**Risk: stale tabs send transactions to the wrong chain after the staleness banner appears but before the user reloads.** Theoretical concern — a user opens a tab today, the chain flips tomorrow, the banner appears, they ignore it and click "send." Their tx goes to Berachain (the chain their loaded config points at) instead of Celo (the active chain). Mitigation: the staleness banner is dismissable but persistent. Optionally, on `migrationState: "post_cutover"`, the send button is disabled until reload. Re-evaluate when planning the chain-flip landing.

**Risk: Sentry/observability sees a flood of `source: "fallback"` events during the first deployment because Vercel hasn't yet warmed the SSR cache.** Mitigation: prewarm with a manual page hit after deploy, or accept the brief warmup spike. Set the alert threshold to avoid first-deploy noise.

## Testing strategy

The mechanical-replacement nature of most of L2 means the unit test surface is small but the integration test surface is large.

**Unit tests:**

- Extend Landing 1's `transformPayload()` tests to cover the new `extras` and `zapperEnabled` fields.
- Add a test that `createViemClients(config)` produces clients pointing at the expected chain and RPC.
- For `AppWallet`, add a constructor test that asserts the right addresses are baked in. (Smart-contract calls themselves are integration territory.)

**Integration / e2e:**

- A test that loads the page, asserts the script tag is present, asserts `useChainConfig()` returns the expected values.
- A test that flips the backend env between two runs and asserts the next page load picks up the new chain.
- An e2e flow: login → see balance → send → receive → redeem. Validates the end-to-end refactor didn't break the user flow.

**Pre-merge manual smoke:**

A dev build pointed at a staging backend with `active_chain_id = 80094` should:

1. Render with the script tag embedded.
2. Connect via Privy with `chain.id === 80094`.
3. Show the SFLUV balance correctly.
4. Send a tiny amount between two test accounts.
5. Show the zapper UI.

The same build with the backend's `CHAIN_ID` flipped to 42220 (staging only, no real users) should:

1. Show the staleness banner after the polling interval if the tab was already open.
2. After reload, mount with `chain.id === 42220`.
3. Connect to Celo via Privy.
4. Hide the zapper UI (because `features.zapperEnabled = false` when ZAPPER_ADDRESS is unset on Celo).

This second flow is exactly the L2 acceptance gate. If it works on staging, the consumer migration is complete and the chain flip becomes a backend env change.

## What landing 2 enables

Once L2 is done and baked:

- **Landing 3 (per-user `chain_preference`):** the `/config` endpoint becomes auth-aware. When a request includes a valid Privy session token, the backend looks up the user's `chain_preference` and serves a per-user payload. The SSR layer in `app/layout.tsx` passes the user's session cookie when fetching, so the embedded script tag reflects per-user steering. No further frontend work in the consumer layer.
- **Landing 4 (the chain flip):** Bump the backend env block (`CHAIN_ID=42220`, `RPC_URL=https://forno.celo.org`, `TOKEN_ID=<celo SFLUV>`, account factory, paymaster, etc.). Add Celo RPC to CSP allowlist (the only frontend change needed for the flip itself — and it's a one-line edit to `middleware.ts`). Deploy backend. Within 30 seconds, every new page load points at Celo.

The cumulative effect: after L2 lands, the cost of every subsequent chain decision drops dramatically. The thing that's currently a redeploy becomes a config push. That's the actual business value of this landing.

## Open questions for the implementer

- **Does the existing observability stack support per-event tagging from the Next.js server?** The fallback-on-SSR-fetch event needs to be visible to whoever monitors prod. If Sentry is wired up server-side, easy. If only client-side, this needs a small backend logging endpoint.
- **Does `CommunityConfig`'s `primaryRPCUrl` getter resolve from the chains map in the way the transform builds it?** The transform constructs `cwConfig.chains[chainId].node.url = engine_rpc_url`. Verify in L1's transform tests that `community.primaryRPCUrl` matches the expected engine URL — if not, adjust the transform.
- **Is there appetite to also remove `app.config.ts` as part of L2?** The fallback could be built from env vars or a separate `lib/chainConfig/static-defaults.ts` instead of the legacy module. Removing `app.config.ts` clarifies that the dynamic path is the only path. But it's a cosmetic change and can be a follow-up.
- **Are there any non-frontend consumers of `app.config.ts`?** A grep for `from "@/app.config"` outside the chainConfig module should return nothing after L2. Worth running to confirm.
