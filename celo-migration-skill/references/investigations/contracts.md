# Contracts Investigation

## Architecture

SFLUV is `SFLUVv2` at `contracts/src/SFLUVv2.sol:8`.

It is an upgradeable wrapper ERC20:

- `ERC20WrapperUpgradeable`
- `AccessControlUpgradeable`
- `UUPSUpgradeable`

The proxy pattern is UUPS behind `ERC1967Proxy`, not Transparent Proxy:

- Deploy script imports `ERC1967Proxy` in `contracts/script/DeploySFLUVv2.s.sol:5`.
- Deploys `new SFLUVv2()` in `contracts/script/DeploySFLUVv2.s.sol:18`.
- Initializes the proxy in `contracts/script/DeploySFLUVv2.s.sol:20`.

Upgrade authorization is `onlyRole(DEFAULT_ADMIN_ROLE)` in `contracts/src/SFLUVv2.sol:39`.

The Berachain mainnet proxy/token address appears hardcoded as `0x881cAd4f885c6701D8481c0eD347f6d35444eA7e` in:

- `contracts/script/GrantSFLUVv2.s.sol:10`
- `contracts/script/MintSFLUVv2.s.sol:13`
- `contracts/NOTES.txt:14`

The deployed implementation address is not recorded in repo. It lives in the ERC1967 implementation slot.

## Storage Layout Hazards

A distribution-mode implementation is feasible only if it preserves the final SFLUV/OpenZeppelin upgradeable storage layout.

Safe pattern:

- Temporary implementation uses the same inheritance order as `SFLUVv2`.
- Temporary implementation initializes the same parent contracts.
- Distribution happens through ERC20 internals so balances, total supply, and events remain coherent.
- Final upgrade is validated with Foundry storage layout output before broadcast.

Unsafe pattern:

- Ad hoc `mapping(address => uint256)` for balances.
- Writing arbitrary balance storage slots without updating total supply.
- Changing inheritance order.
- Changing OpenZeppelin major/minor upgradeable layout.
- Adding temporary child storage that final code assumes absent.
- Corrupting AccessControl storage that gates upgrades.

Wrapper backing token is initialized at `contracts/src/SFLUVv2.sol:27`. Current deploy hardcodes Berachain HONEY at `contracts/script/DeploySFLUVv2.s.sol:11`; the Celo deploy must parameterize backing token.

## Tooling

Foundry is used.

- `contracts/foundry.toml:5` enables `ffi`.
- `contracts/foundry.toml:6` enables AST/build info.
- `contracts/foundry.toml:8` enables `storageLayout` output.
- OpenZeppelin remaps are in `contracts/remappings.txt:1`.

Existing scripts:

- `DeployMockCoin.s.sol`
- `DeploySFLUVv2.s.sol`
- `GrantSFLUVv2.s.sol`
- `MintSFLUVv2.s.sol`

Minting currently uses approve plus `depositFor` in `contracts/script/MintSFLUVv2.s.sol:31`, `:32`, and `:34`.

## Account Factory Assumptions

The contracts repo does not contain smart wallet factory, CREATE2, salt, or index logic. SFLUV only accepts generic `account` params:

- `contracts/src/SFLUVv2.sol:41`
- `contracts/src/SFLUVv2.sol:45`

The Celo deploy script therefore needs an external snapshot from the backend DB plus the account factory contract on Celo.

## Recommendations

- Treat storage-layout validation as mandatory before any upgrade.
- Parameterize all addresses and chain values by env or JSON, not constants.
- Build script outputs as durable artifacts: wallet snapshot, balance snapshot, deployment addresses, tx hashes, verification summary, and rollback status.
- Use dry-run mode against forked Berachain/Celo before production broadcast.
- Do not run Berachain wipe until Celo deployment and client cutover have been manually verified.
