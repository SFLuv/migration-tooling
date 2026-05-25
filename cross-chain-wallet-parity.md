# Cross-chain smart wallet address parity: Berachain ↔ Celo

A Citizen Wallet user controlled by the same EOA gets the **same smart-contract wallet address on Berachain and Celo**, without any cross-chain machinery. This document explains why, and includes the empirical PoC that confirms it on mainnet.

## TL;DR

- The Citizen Wallet smart account is a Safe v1.4.1 proxy deployed via `CREATE2` by `AccountFactory`.
- Because the factory, salt, proxy bytecode, and Safe singleton are at identical addresses on both chains, `CREATE2` produces the same wallet address for the same `(owner, nonce)` pair.
- Empirically confirmed: EOA `0xd04131…9360` with nonce `0` deploys to `0x04e37f13…b3f8` on both Berachain and Celo.

## How the address is derived

`AccountFactory` (`src/Modules/Community/AccountFactory.sol` in `citizenwallet/contractforge`) builds a `CREATE2` input from four parts:

```solidity
function _getCreate2Input(address _owner, uint256 _nonce) internal view returns (bytes32) {
    bytes32 salt = keccak256(abi.encodePacked(_owner, _nonce));
    return keccak256(abi.encodePacked(
        bytes1(0xff),
        address(this),                                            // factory address
        salt,
        keccak256(abi.encodePacked(
            proxyCreationCode(),                                  // Safe proxy initcode
            uint256(uint160(SafeSuiteLib.SAFE_Safe_ADDRESS))      // Safe v1.4.1 singleton
        ))
    ));
}
```

The deployed wallet address is the last 20 bytes of that hash — standard EIP-1014 `CREATE2`. The Safe owner is not part of the bytecode hash; it lives only in the salt and in the initializer call that runs post-deployment, so the *address* depends only on `(factory, salt, proxyCreationCode, singleton)`.

For the same `(owner, nonce)` to land at the same address on two chains, all four inputs must match:

| Input | Source | Same on Bera & Celo? |
|---|---|---|
| `factory` (`address(this)`) | Your deployed `AccountFactory` | Yes — `0x7cC54D54bBFc65d1f0af7ACee5e4042654AF8185` on both |
| `salt` (`keccak256(owner ‖ nonce)`) | Pure function of inputs | Yes |
| `proxyCreationCode` | `SafeProxyFactory` | Yes — same compiled Safe contracts |
| `singleton` (`SafeSuiteLib.SAFE_Safe_ADDRESS`) | Safe v1.4.1 master copy | Yes — `0x41675C099F32341bf84BFc5382aF534df5C7461a` on both |

Why the factory itself ends up at the same address on both chains: `AccountFactory.s.sol` deploys it via a CREATE2 deployer (`Create2.sol`) with a fixed string salt — `keccak256("SAFE_ACCOUNT_FACTORY_05/06/2025")`. As long as the `Create2` deployer is at the same address on each chain and the constructor arg (`_communityModule`) resolves to the same address on each chain, the resulting factory address matches.

## Key on-chain addresses

| Contract | Address | Notes |
|---|---|---|
| `AccountFactory` | `0x7cC54D54bBFc65d1f0af7ACee5e4042654AF8185` | Same on Berachain, Celo, Base, Gnosis |
| Safe v1.4.1 singleton | `0x41675C099F32341bf84BFc5382aF534df5C7461a` | Canonical Safe deployment |
| Citizen Wallet EntryPoint (v0.6) | `0x7079253c0358eF9Fd87E16488299Ef6e06F403B6` | Citizen Wallet's own EntryPoint, not the canonical eth-infinitism one |
| Safe fallback handler (compat) | `0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99` | Configured by `AccountFactory._getInitializer` |

The Celo communities config (`citizenwallet/app/assets/config/v4/communities.json`) lists 11 different factory addresses for chain 42220, none of which match the Berachain one. Those are legacy factories that predate the unified deterministic deployment. The unified factory `0x7cC5…8185` *is* deployed on Celo — it just isn't (yet) the one wired up in the existing Celo community configs.

## Bundler / RPC endpoints

Citizen Wallet's bundler/paymaster/RPC are all served from a single host per chain, gated by an `Origin` header (set in `mobile-app/lib/services/wallet/wallet.dart`):

- Berachain (80094): `https://80094.engine.citizenwallet.xyz`
- Celo (42220): `https://42220.engine.citizenwallet.xyz`

`paymaster_type` is `cw-safe`. The full community list is at `https://config.internal.citizenwallet.xyz/v4/communities.json`; per-community configs are at `https://config.internal.citizenwallet.xyz/v4/<alias>.json` (e.g. `wallet.sfluv.org.json`).

For read-only checks from `cast`, use the public RPCs instead (the CW endpoints return `401` without the `Origin` header):

- Berachain: `https://rpc.berachain.com`
- Celo: `https://forno.celo.org`

## PoC: reproducing the parity check

These commands assume `cast` (foundry) is on `PATH`.

### 1. Confirm prerequisites on both chains

```bash
FACTORY=0x7cC54D54bBFc65d1f0af7ACee5e4042654AF8185
ENTRYPOINT=0x7079253c0358eF9Fd87E16488299Ef6e06F403B6
SAFE_SINGLETON=0x41675C099F32341bf84BFc5382aF534df5C7461a

has_code () {
  local code
  code=$(cast code "$1" --rpc-url "$2" 2>/dev/null) || { echo "RPC ERROR"; return; }
  [[ ${#code} -gt 2 && "$code" == 0x* ]] && echo yes || echo no
}

for rpc in https://rpc.berachain.com https://forno.celo.org; do
  echo "=== $rpc ==="
  echo "  factory:        $(has_code $FACTORY $rpc)"
  echo "  entrypoint:     $(has_code $ENTRYPOINT $rpc)"
  echo "  safe singleton: $(has_code $SAFE_SINGLETON $rpc)"
done
```

Expected: all `yes` on both chains.

### 2. Predict the wallet address on both chains

```bash
EOA=0xd04131b641f32cA7cd3AB805189467492c9e9360   # any owner EOA
NONCE=0

for rpc in https://rpc.berachain.com https://forno.celo.org; do
  echo -n "$rpc  "
  cast call $FACTORY "getAddress(address,uint256)(address)" $EOA $NONCE --rpc-url $rpc
done
```

Expected: both return the same address. For the EOA above, the predicted wallet is `0x04e37f13ea865cd38e47e2686f7dead98c64b3f8`.

### 3. Deploy the wallet on each chain

`createAccount` is permissionless — anyone can call it for any EOA, because the initializer hard-codes `owners[0] = _owner`. The caller's EOA doesn't end up with any privilege over the wallet.

```bash
DEPLOYER_KEY=0x...   # any funded EOA on each chain

# Berachain
cast send $FACTORY "createAccount(address,uint256)(address)" $EOA $NONCE \
  --rpc-url https://rpc.berachain.com --private-key $DEPLOYER_KEY

# Celo
cast send $FACTORY "createAccount(address,uint256)(address)" $EOA $NONCE \
  --rpc-url https://forno.celo.org --private-key $DEPLOYER_KEY
```

The two receipts will share `gasUsed` (281,266) and emit the same `ProxyCreation` and `SafeSetup` log data, modulo chain-specific receipt fields (Celo has OP-stack `l1Fee` fields; Berachain does not).

### 4. Verify both wallets have the same configuration

```bash
WALLET=0x04e37f13ea865cd38e47e2686f7dead98c64b3f8

for rpc in https://rpc.berachain.com https://forno.celo.org; do
  echo "=== $rpc ==="
  cast call $WALLET "getOwners()(address[])"   --rpc-url $rpc
  cast call $WALLET "getThreshold()(uint256)"  --rpc-url $rpc
done
```

Confirmed result for owner `0xd04131…9360`:

```
=== https://rpc.berachain.com ===
[0xd04131b641f32cA7cd3AB805189467492c9e9360]
1
=== https://forno.celo.org ===
[0xd04131b641f32cA7cd3AB805189467492c9e9360]
1
```

Same address, same owner, same threshold, two distinct chains. Parity confirmed end-to-end.

## What's the same and what isn't

**Same across chains:**
- Wallet contract address.
- Safe configuration: owners, threshold, fallback handler, singleton.
- The fact that `enableModule` was called during `setup`.

**Different across chains:**
- The address passed to `enableModule` is the `_communityModule` baked into the factory at construction. Both factories happen to have been constructed with the same `_communityModule` (one of the conditions that lets the factory be at the same address in the first place), but the *contract behind* that address is a chain-local deployment, not a cross-chain construct.
- The Citizen Wallet bundler/paymaster: each chain has its own at `https://<chainId>.engine.citizenwallet.xyz`.
- Any tokens, balances, or on-chain state held by the wallet — those live per-chain. "Same address" does not imply "same balance".

## Replay-attack note

A wallet at the same address on multiple chains needs every signed payload to bind `chainId`, otherwise a signature valid on Berachain could be replayed on Celo. The standard paths already handle this:

- Safe's EIP-712 domain separator includes `chainId`.
- ERC-4337 UserOp hashes include `chainId`.

Custom signing flows (session keys, recovery, off-chain attestations) need to explicitly include `chainId` in the signed payload.

## Implications for migration tooling

- **Account discovery:** for any EOA, `factory.getAddress(eoa, nonce)` on either chain yields the canonical address — no need to query both chains to determine the wallet.
- **Lazy deployment:** the wallet only physically exists on whichever chain has had `createAccount` called for that `(eoa, nonce)`. Migration tools can deploy on-demand by calling `createAccount` from any funded EOA without touching the user's private key.
- **Legacy Celo communities:** existing Celo communities use older, non-unified factories (`0x940C…`, `0x0a9F…`, etc.), so users of those communities have *different* Celo addresses from their Berachain addresses. Migrating those communities to factory `0x7cC5…8185` would give new wallets on the unified address scheme, but existing wallets stay at their legacy addresses. Any migration UX needs to surface both addresses to the user.
- **PoC EOA in this doc:** `0xd04131b641f32cA7cd3AB805189467492c9e9360` was used as a real test. The deployed Safe at `0x04e37f13ea865cd38e47e2686f7dead98c64b3f8` exists on both chains and is owned by that EOA.

## Repository workflow note

`repos/app` and `repos/mobile-app` are submodules configured with `.gitmodules` `branch = .`. After switching or pulling a root migration branch, run:

```bash
git submodule update --remote --merge repos/app repos/mobile-app
```

This moves those submodules to the branch matching the current root branch when it exists remotely. Plain `git pull` updates the top-level repo and recorded gitlinks, but it does not by itself float submodules to their remote branch heads.

## References

- `citizenwallet/contractforge/src/Modules/Community/AccountFactory.sol` — factory + address derivation.
- `citizenwallet/contractforge/src/utils/SafeSuiteLib.sol` — Safe v1.4.1 canonical addresses.
- `citizenwallet/contractforge/script/AccountFactory.s.sol` — CREATE2 deployment of the factory itself.
- `citizenwallet/app/assets/config/v4/communities.json` — per-community factory/paymaster/entrypoint addresses.
- `citizenwallet/app/lib/services/wallet/wallet.dart` — bundler/RPC wiring and `Origin`-header gate.
- EIP-1014 — CREATE2 address derivation.
- Safe v1.4.1 singleton: `0x41675C099F32341bf84BFc5382aF534df5C7461a`.
