# Mobile App Investigation

## Summary

The mobile app is Expo/React Native TypeScript. It does not currently have a force-update path, remote config, maintenance mode, or backend compatibility handshake. Chain config is build-time env with Berachain defaults, so the preliminary mobile release is mandatory.

## Current Metadata

- Package version is `0.1.0` in `mobile-app/mobile/package.json:1`.
- Expo app version is also `0.1.0` in `mobile-app/mobile/app.config.ts:24`.
- iOS bundle id defaults to `org.sfluv.wallet`; Android package is `org.sfluv.wallet`; app links target `app.sfluv.org` in `mobile-app/mobile/app.config.ts:34`.
- EAS `preview` hardcodes Berachain env values in `mobile-app/mobile/eas.json:15`.
- `expo-application` is installed in `mobile-app/mobile/package.json:27`, but no version enforcement code uses it.
- No `ios.buildNumber`, `android.versionCode`, `runtimeVersion`, `updates`, or `expo-updates` setup was found.

## Existing Enforcement Paths

No direct update enforcement exists.

Current shared app backend requests do not include app version, build number, or platform metadata in request headers or bodies. `AppBackendClient.authFetch` sends the Privy `Access-Token` header only, and public shared-backend calls such as `/locations` and `/redeem` also omit version/build/platform metadata.

Reusable pieces:

- Blocking screen pattern: `MissingPrivyConfigScreen` in `mobile-app/mobile/App.tsx:2586`.
- Wallet-shell bootstrap errors can block runtime in `mobile-app/mobile/App.tsx:2086`.
- Non-blocking sync notice exists for contacts/settings via `mobile-app/mobile/App.tsx:927`, `mobile-app/mobile/src/screens/ContactsScreen.tsx:156`, and `mobile-app/mobile/src/screens/SettingsScreen.tsx:279`.
- Toast path exists at `mobile-app/mobile/App.tsx:1930`, but is transient and unsuitable for a required update.

The shared app backend client has fixed endpoints and no config/version/status methods. See `mobile-app/mobile/src/services/appBackend.ts:336`.

## Current Chain Config

Config is static/build-time:

- `mobile-app/mobile/src/config.ts:49` defines `mobileConfig`.
- Defaults include Berachain chain `80094`, RPC `https://rpc.berachain.com`, token `0x881cad4f885c6701d8481c0ed347f6d35444ea7e`, entrypoint, factory, paymaster, and Citizen Wallet engine URL in `mobile-app/mobile/src/config.ts:33`.
- Privy supported chain is named `Berachain` and native currency `BERA` in `mobile-app/mobile/App.tsx:2602`.
- Smart wallet provider network name is hardcoded as `berachain` in `mobile-app/mobile/src/services/smartWallet.ts:241` and `mobile-app/mobile/src/services/smartWallet.ts:574`.
- Universal link fallback host is `wallet.berachain.sfluv.org` in `mobile-app/mobile/src/utils/universalLinks.ts:38`.
- QR parsing captures `chainId`/`token`, but send flow does not validate those values before sending. Relevant files: `mobile-app/mobile/src/utils/qr.ts:54`, `mobile-app/mobile/src/utils/universalLinks.ts:448`, `mobile-app/mobile/src/screens/SendScreen.tsx:559`.

## Mobile Backend Note

`mobile-app/backend` is a custom AA/RPC backend, not the shared app backend used for app user, wallet, merchant, location, and Ponder APIs.

- Routes are RPC/accounts/activity/push/events only in `mobile-app/backend/internal/api/server.go:40`.
- It stores `app_version` for push devices in `mobile-app/backend/internal/api/server.go:196` and `mobile-app/backend/internal/store/sqlite.go:57`.
- The mobile app does not appear to call this backend push endpoint.
- Server-side chain config is loaded from startup config and is not published to the mobile client. See `mobile-app/backend/internal/config/config.go:11`.

The current mobile app also talks directly to Citizen Wallet engine-style JSON-RPC for account-abstraction operations. `mobileConfig.wallet.backendURL` defaults to `https://80094.engine.citizenwallet.xyz`, and `BackendClient` sends `pm_sponsorUserOperation`, `eth_sendUserOperation`, and `eth_getTransactionReceipt` there. This is separate from the shared app backend at `EXPO_PUBLIC_APP_BACKEND_URL`.

## Required Implementation

1. Add real native build metadata:
   - `ios.buildNumber`
   - `android.versionCode`
   - optionally `runtimeVersion`
2. Add `AppBackendClient.getClientVersion(platform, version, build)` and `AppBackendClient.getConfig()`.
   - Add version/build/platform metadata to shared-backend requests so the backend can intentionally block old clients instead of relying only on broken Berachain-era behavior after cutover.
3. Fetch version/config before rendering `PrivyProvider` in `mobile-app/mobile/App.tsx:2599`.
4. Use a blocking screen, patterned after `MissingPrivyConfigScreen`, for forced update, maintenance, incompatible chain, or config fetch failure when required.
5. Dynamicize all chain config:
   - chain id/name
   - native currency
   - RPC/WS URLs
   - token address/decimals/symbol
   - entrypoint/factory/paymaster/paymaster type
   - engine/backend URL
   - explorer URL
   - app origin/universal link alias
6. Validate QR chain/token before send. A mismatched QR should fail closed with a clear message.
7. Include app version/build in backend calls where useful for telemetry, especially push notification sync.

## Migration-Specific Recommendation

Ship the preliminary release while config still points to Berachain. Once adoption is high enough, set backend `minimum` to that build and only then switch config to Celo.
