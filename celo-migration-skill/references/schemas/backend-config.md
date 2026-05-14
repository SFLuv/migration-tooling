# Backend Config And Client Version Schemas

## Endpoint: `GET /config`

Purpose: public runtime configuration for web/mobile clients. This endpoint must contain no secrets.

Recommended response:

```json
{
  "schema_version": 1,
  "config_version": "2026-05-14.0",
  "environment": "production",
  "active_chain_id": 80094,
  "legacy_chain_ids": [80094],
  "community": {
    "name": "SFLUV Community",
    "alias": "wallet.berachain.sfluv.org",
    "custom_domain": "wallet.sfluv.org",
    "logo": "https://assets.citizenwallet.xyz/wallet-config/_images/sfluv.svg",
    "profile_address": "0x05e2Fb34b4548990F96B3ba422eA3EF49D5dAa99"
  },
  "chains": {
    "80094": {
      "id": 80094,
      "name": "Berachain",
      "native_currency": { "name": "BERA", "symbol": "BERA", "decimals": 18 },
      "rpc_url": "https://rpc.berachain.com",
      "engine_rpc_url": "https://80094.engine.citizenwallet.xyz",
      "engine_ws_url": "wss://80094.engine.citizenwallet.xyz",
      "explorer": { "name": "Berascan", "url": "https://berascan.com" }
    }
  },
  "tokens": {
    "primary": {
      "standard": "erc20",
      "name": "SFLUV",
      "symbol": "SFLUV",
      "address": "0x881cad4f885c6701d8481c0ed347f6d35444ea7e",
      "chain_id": 80094,
      "decimals": 18
    },
    "backing_assets": []
  },
  "accounts": {
    "primary": {
      "chain_id": 80094,
      "entrypoint_address": "0x7079253c0358eF9Fd87E16488299Ef6e06F403B6",
      "account_factory_address": "0x7cC54D54bBFc65d1f0af7ACee5e4042654AF8185",
      "paymaster_address": "0x9A5be02B65f9Aa00060cB8c951dAFaBAB9B860cd",
      "paymaster_type": "cw-safe"
    }
  },
  "urls": {
    "app_origin": "https://app.sfluv.org",
    "backend": "https://api.sfluv.org",
    "citizen_wallet_config_location": "https://config.internal.citizenwallet.xyz/v4/wallet.sfluv.org.json",
    "ipfs": "https://ipfs.internal.citizenwallet.xyz"
  },
  "features": {
    "migration_banner": false,
    "sends_enabled": true,
    "redemptions_enabled": true,
    "workflow_payouts_enabled": true
  },
  "migration": {
    "state": "pre_cutover",
    "message": "",
    "cutover_started_at": null
  },
  "source": {
    "provider": "citizenwallet",
    "fallback_used": false,
    "fetched_at": "2026-05-14T00:00:00Z"
  }
}
```

## Backend Config Resolution

1. Fetch Citizen Wallet `v4/communities.json`.
2. Select SFLuv community by alias/custom domain.
3. Normalize to the backend schema.
4. If remote fetch/parse/select fails, load internal JSON.
5. If internal JSON fails, use hardcoded defaults.
6. Include `source.fallback_used` so clients and logs can identify degraded mode.

## Endpoint: `GET /client-version`

Purpose: public compatibility policy. Keep it separate from Citizen Wallet config `version`.

Recommended request query:

```text
/client-version?platform=ios&version=0.1.0&build=1
```

Recommended response:

```json
{
  "schema_version": 1,
  "server_time": "2026-05-14T00:00:00Z",
  "config_version": "2026-05-14.0",
  "platform": "ios",
  "status": "ok",
  "minimum": { "version": "0.1.0", "build": 1 },
  "recommended": { "version": "0.2.0", "build": 2 },
  "current": { "version": "0.2.0", "build": 2 },
  "force_update": false,
  "maintenance": false,
  "update_url": "https://apps.apple.com/app/id...",
  "message": "",
  "features": {
    "dynamic_config_required": true,
    "celo_required": false
  }
}
```

Statuses:

- `ok`: proceed.
- `update_recommended`: show non-blocking update prompt.
- `update_required`: block app with store link.
- `maintenance`: block app with maintenance message.
- `unsupported_platform`: block app.

## Mobile Enforcement Rules

- Compare native build numbers, not only semantic version.
- Fetch before rendering wallet services or Privy chain config.
- If version endpoint is unavailable, allow only if bundled config says compatibility checks are optional for that build.
- Once migration cutover begins, set `dynamic_config_required=true`.
- Once enough users have the preliminary release, set `minimum` to that build.

## Chain-Aware Transaction Schema Additions

Add `chain_id` to:

- transaction list query and response
- transaction memo write/read
- balance-at-timestamp query
- Ponder hook subscriptions and callbacks
- W9 transaction and yearly earning records
- workflow payout tx confirmation metadata

Prefer identity:

```text
(chain_id, tx_hash)
```

For event rows:

```text
(chain_id, tx_hash, log_index)
```
