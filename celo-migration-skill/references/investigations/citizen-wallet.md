# Citizen Wallet Investigation

## Summary

Citizen Wallet can dynamically consume updated community config, including chain/RPC/token/account factory values, if the remote config is updated under the same alias. The sharp risk is that existing saved wallet records are keyed by account address and alias, not by chain, and the app does not automatically rewrite saved account addresses.

## Config Loading

- Native startup initializes `ConfigService` with `WALLET_CONFIG_URL`, opens app DB `appv4`, and refreshes remote configs on load in `cw-app/lib/main.dart:73`, `cw-app/lib/main.dart:78`, and `cw-app/lib/main.dart:140`.
- Remote all-community fetch uses `/v4/communities.json` from the configured endpoint in `cw-app/lib/services/config/service.dart:209`.
- The app DB seeds bundled v4 configs on first create and remote configs are upserted by alias using replace behavior in `cw-app/lib/services/db/app/communities.dart:146` and `cw-app/lib/services/db/app/communities.dart:173`.
- Web mode tries host-local `/config/community.json` in `cw-app/lib/services/config/service.dart:46` and `cw-app/lib/services/config/service.dart:70`.

## Dynamic Config Capabilities

For the same alias, remote config can switch:

- `community.primary_token`
- `community.primary_account_factory`
- token entry
- chain node URL
- entrypoint
- paymaster
- account factory
- explorer and plugin metadata

Selection is based on `chainId:address` keys:

- `cw-app/lib/services/config/config.dart:100`
- `cw-app/lib/services/config/config.dart:709`
- `cw-app/lib/services/config/config.dart:718`

RPC is derived from chain node URL plus paymaster address in `cw-app/lib/services/config/config.dart:743`.

Wallet init consumes current config values directly in:

- `cw-app/lib/services/wallet/wallet.dart:165`
- `cw-app/lib/services/wallet/wallet.dart:173`
- `cw-app/lib/services/wallet/wallet.dart:246`

## Saved Account Risk

Existing saved accounts are keyed by `accountAddress@alias`, not chain:

- `cw-app/lib/services/db/backup/accounts.dart:28`
- `cw-app/lib/services/db/backup/accounts.dart:62`

Opening an existing wallet loads the stored address/private key and applies the current config around it:

- `cw-app/lib/state/wallet/logic.dart:324`
- `cw-app/lib/state/wallet/logic.dart:333`
- `cw-app/lib/state/wallet/logic.dart:374`

If the same alias flips from Berachain to Celo, the app may keep the old stored account address while using new Celo RPC/factory/paymaster/token config. This only works if the stored smart wallet address is exactly the Celo-derived address. **Confirmed: cross-chain address parity holds.** The same `AccountFactory` (`0x7cC5…8185`) and Safe singleton are deployed at identical addresses on both chains, so `CREATE2` produces the same wallet address for the same `(owner, nonce)`. See `/cross-chain-wallet-parity.md` for the full derivation and mainnet PoC.

## Deterministic Account Behavior

Account derivation calls the configured factory with owner and constant salt/index `0`:

- `cw-app/lib/services/wallet/contracts/account_factory.dart:13`
- `cw-app/lib/services/wallet/contracts/account_factory.dart:63`
- `cw-app/lib/services/wallet/contracts/account_factory.dart:101`

Chain id is not passed to `getAddress`; it only determines which RPC/factory is contacted.

UserOp signing is chain/entrypoint dependent:

- `cw-app/lib/services/wallet/contracts/entrypoint.dart:42`
- `cw-app/lib/services/wallet/wallet.dart:1303`
- local hash helper includes entrypoint and chain id in `cw-app/lib/services/wallet/models/userop.dart:134`.

## SFLuv-Specific Config State

- Checked-in v4 visible SFLuv Berachain alias is `wallet.berachain.sfluv.org`, custom domain `wallet.sfluv.org`, chain `80094`, token `0x881c...`, factory `0x7cC5...` in `cw-app/assets/config/v4/communities.json:251`, `:264`, and `:288`.
- Old/hidden SFLuv Polygon alias is `wallet.sfluv.org`, chain `137`, token `0x58a2...`, factory `0x5e98...` in `cw-app/assets/config/v4/communities.json:331`, `:345`, and `:369`.
- v3 legacy SFLuv was also Polygon `wallet.sfluv.org` in `cw-app/assets/config/v3/communities.json:599`, `:620`, and `:636`.

## Balances And Indexer

Balances are fetched directly from chain via RPC, not from the indexer. `getBalance` at `cw-app/lib/services/wallet/wallet.dart:109` calls `_contractToken.getBalance()` — a standard ERC20 `balanceOf` through `web3dart`. Balances will work on Celo as soon as the config points to Celo RPC and the new token address.

Transaction history and real-time events come from the indexer via WebSocket at `/v1/events/{contractAddress}/{topic}` (`cw-app/lib/services/engine/events.dart:76`). The indexer is also used for account registration (`cw-app/lib/services/accounts/utils.dart:47`) and health checks (`cw-app/lib/services/config/service.dart:223`).

Indexer config is part of the community JSON as `IndexerConfig` with `url`, `ipfs_url`, and `key` fields (`cw-app/lib/services/config/config.dart:170`).

**Multi-chain history concern:** Ideally the indexer would preserve Berachain transaction history and start indexing new Celo transactions seamlessly. It is unclear whether the CW indexer supports multi-chain continuity within a single community — and even if the schema allows it, this is unlikely to be well tested. Additionally, the CW app client may not handle mixed-chain transaction lists correctly (e.g., explorer links would point to the wrong chain for old transactions).

**Pragmatic fallback:** Accept that CW transaction history resets at cutover. Old Berachain transaction history remains available through the SFLuv backend Ponder data, which the migration plan already preserves as read-only.

## Additional Risks

- Hardcoded legacy AA lookup knows Polygon/Base/Celo bundles and aliases containing `celo` return `null` before the later `ceur.celo` case can match. See `cw-app/lib/services/config/config.dart:425` and `cw-app/lib/services/config/config.dart:452`.
- No SFLuv alias correction exists in `cw-app/lib/services/config/utils.dart:3`.
- Chain id is cached per alias and reused without validating against the new RPC. See `cw-app/lib/services/wallet/wallet.dart:212` and `cw-app/lib/services/preferences/preferences.dart:62`.

## Recommendation

Before relying on silent Citizen Wallet migration:

1. Verify Celo account factory produces the exact same account address for representative SFLuv EOAs and index `0`.
2. Test same-alias config flip on a device with an existing Berachain SFLuv wallet.
3. Clear or validate the per-alias chain-id cache during migration.
4. Confirm first post-migration user operation uses a sender/initCode pair consistent with the Celo factory.
5. If address matching fails, prefer a new alias plus explicit account migration/update path.
