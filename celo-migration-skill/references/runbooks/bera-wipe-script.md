# Berachain Wipe Script Runbook

Working name: `bera-wipe-script`.

## Objective

After successful Celo cutover, upgrade the Berachain SFLUV proxy to a deprecation implementation that sweeps backing assets and causes user-facing methods to revert with:

```text
SFLuv has migrated to CELO.
```

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
3. Simulate `upgradeToAndCall` against a fork:
   - upgrades proxy
   - calls sweep initializer
   - sends backing assets to safe
   - leaves proxy in deprecated state
4. Broadcast `upgradeToAndCall`.
5. Verify:
   - proxy implementation slot is wipe implementation
   - backing assets moved to safe
   - transfer/deposit/withdraw paths revert with migration message
   - read-only methods needed for explorer/debugging behave as expected, if any are intentionally kept
6. Record tx hash and final balances.

## Important Risk

This is the point of no return. Do not run until Celo client cutover is confirmed across all supported clients.

## Open Design Choices

- Whether `balanceOf`, `totalSupply`, `name`, and `symbol` should continue to return old data or revert.
- Whether `transfer`/`approve` should all revert or whether some ERC20 reads should remain explorer-friendly.
- Which ERC20 backing assets are swept if multiple assets back SFLUV by cutover time.
