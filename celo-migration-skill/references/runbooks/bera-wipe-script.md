# Berachain Wipe Script Runbook

Working name: `bera-wipe-script`.

## Objective

Upgrade the Berachain SFLUV proxy to a deprecation implementation that causes user-facing methods to revert with:

```text
SFLuv has migrated to CELO.
```

The upgrade-only step does not sweep backing assets. The irreversible backing sweep is a separate owner-gated call that must run only after successful Celo migration verification.

## Preconditions

- Celo deployment verified.
- Backend config points clients to Celo.
- New Ponder/Celo transaction path verified.
- Web app verified.
- Mobile latest verified.
- Old mobile behavior understood and acceptable.
- Citizen Wallet behavior verified.
- Treasury/safe sweep destination approved.
- DEFAULT_ADMIN key/signer for Berachain SFLUV proxy available.

## Design

Add a Berachain-only implementation that:

- Preserves UUPS upgrade authorization storage layout enough for the upgrade call.
- Can execute a one-time sweep from the proxy context.
- Transfers all underlying/backing ERC20 balances from the proxy to a designated address.
- Reverts all normal token operations with the migration message after sweep.
- Avoids `selfdestruct`.

The sweep should transfer underlying ERC20 directly from the proxy context, not call `withdrawTo`, because roles and wrapper accounting may be deprecated or intentionally blocked.

## Execution Flow

1. Deploy wipe implementation on Berachain.
2. Verify implementation bytecode/source.
3. Simulate upgrade-only `upgradeToAndCall(address(impl), "")` against a fork:
   - upgrades proxy
   - disables write methods
   - keeps backing assets in the proxy
   - confirms governance can still upgrade back before sweeping
4. Broadcast the upgrade-only script.
5. Complete and manually verify Celo wallet deployment, token distribution, client config, and Ponder start block.
6. Simulate and then broadcast `sweepBacking(treasury)` using the separate sweep script.
7. Verify:
   - proxy implementation slot is wipe implementation
   - backing assets moved to safe
   - transfer/deposit/withdraw paths revert with migration message
   - read-only methods needed for explorer/debugging behave as expected, if any are intentionally kept
8. Record tx hash and final balances.

## Important Risk

The backing sweep is the point of no return. Do not run `sweepBacking` until Celo client cutover is confirmed across all supported clients. The upgrade-only lock is designed to be reversible by governance before backing assets are swept.

## Open Design Choices

- Whether `balanceOf`, `totalSupply`, `name`, and `symbol` should continue to return old data or revert.
- Whether `transfer`/`approve` should all revert or whether some ERC20 reads should remain explorer-friendly.
- Which ERC20 backing assets are swept if multiple assets back SFLUV by cutover time.
