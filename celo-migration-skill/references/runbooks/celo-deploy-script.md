# Celo Deploy Script Runbook

Working name: `celo-deploy-script`.

## Objective

Deploy SFLUV on Celo so every eligible Berachain user receives the matching Celo balance at the same smart wallet address whenever possible.

## Inputs

- Backend DB connection string.
- Berachain RPC URL.
- Celo RPC URL.
- Celo deployer private key, prefunded with CELO.
- Account factory address: `0x7cC54D54bBFc65d1f0af7ACee5e4042654AF8185`.
- Berachain SFLUV token/proxy: `0x881cad4f885c6701d8481c0ed347f6d35444ea7e`.
- Berachain Zapper: `0xd0EBD0495750899D18b915BDeba789E2defdC394`.
- Celo backing asset: USDC at `0xcebA9300f2b948710d2653dD7B07f33A8B32118C`, plus amount/source.
- Celo SFLUV governance/admin/minter/redeemer wallet addresses, expected to be newly created Celo accounts equivalent to current Berachain SFLUV/Zapper role holders.
- Explicit exception list for excluded, overridden, or manually handled accounts.

## Snapshot Data

Pull from backend DB:

- user id
- EOA address
- smart wallet address
- smart wallet index
- wallet active/hidden flags
- primary wallet
- merchant/location payment wallets
- reward payout wallets

Read from chain:

- Berachain SFLUV balance for each EOA/smart wallet.
- Smart wallet deployment status on Berachain.
- Celo smart wallet derived address for each EOA/index.
- Celo smart wallet deployment status before migration.

## Preflight Checks

1. Confirm Celo chain id is `42220`.
2. Confirm Berachain chain id is `80094`.
3. Confirm account factory bytecode/address on Celo. CeloScan shows `0x7cC54D54bBFc65d1f0af7ACee5e4042654AF8185` as a Celo contract with successful `createAccount(address,uint256)` activity, including tx `0x7d47e2303db3177f8aa88ad4ad069f47ac5763459a8f33e8a34df27f2c2e7b05`.
4. For sample EOAs and indices, compare stored Berachain smart wallet address to Celo factory `getAddress(owner, index)`. This is expected from Citizen Wallet design but not yet broadly verified for SFLuv users.
5. Initial sample verification passed for EOA `0x0e314f1F33Ddf60D28D25d381aD871f2eF096640`: index `0` matched `0x72441d9C8fbf917495f69798757e3D7A18a6c63d`; index `1` matched `0x0f3dE0f4ce42C059165cf60d7361d8C5AE38B498`.
6. Fail if any non-exception smart wallet does not match expected address.
7. Confirm deployer CELO balance covers wallet deployment plus token deployment/distribution gas.
8. Confirm backing asset balance/allowance is enough for total distribution.
9. Confirm storage layout if using a temporary distribution implementation.
10. Discover and record active Berachain SFLUV/Zapper role holders.
11. Write immutable snapshot artifacts before broadcasting.

## Deployment Flow

1. Load and validate config.
2. Query backend DB and normalize wallet records.
3. Build unique address set for balances.
4. Read Berachain balances at a fixed block tag if possible.
5. Apply exception list and write final allocation plan.
6. Deploy missing Celo smart wallets for each EOA/index.
7. Deploy Celo SFLUV implementation and ERC1967 proxy, or temporary distribution implementation and proxy.
8. Grant distribution/minter roles to deployer if needed.
9. Distribute balances:
   - safest: use ERC20 mint/deposit internals that update balances and total supply coherently.
   - avoid raw storage writes unless the implementation was built for this and layout is proven.
10. Add backing assets equal to distributed supply.
11. If temporary distribution implementation was used, upgrade proxy to final `SFLUVv2`.
12. Grant final roles and revoke temporary roles.
13. Verify implementation, roles, total supply, backing balance, and sample balances.
14. Write final artifact with tx hashes and addresses.

## Required Artifacts

- `wallet-snapshot.json`
- `balance-snapshot.json`
- `allocation-plan.json`
- `exceptions.json`
- `deployment-result.json`
- `verification-report.json`

Each artifact should include:

- timestamp
- source chain id/block
- target chain id/block
- script git commit if available
- deployer address
- config hash

## Failure Handling

- Before token distribution: fix config/deployer/factory issue and rerun from artifact.
- During distribution: rerun idempotently by calculating remaining desired balance per address.
- After final upgrade: do not rerun blindly; compare verification report and use targeted repair script.

## Verification Checklist

- Celo SFLUV proxy exists and implementation matches expected artifact.
- `DEFAULT_ADMIN_ROLE` holder is correct.
- `MINTER_ROLE` and `REDEEMER_ROLE` holders are correct.
- Total SFLUV supply equals allocation sum.
- Backing asset balance equals or exceeds distributed supply under the intended backing model.
- Random sample of user EOAs/indexed smart wallets match Berachain addresses and balances.
- Backend `/config` Celo output references the deployed Celo token and account config.
- Web and mobile can query Celo balances.
