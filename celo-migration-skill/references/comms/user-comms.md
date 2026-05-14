# Migration Communications

## Audiences

- Mobile app users who must update before migration.
- Web app users who will be moved automatically.
- Merchants and organizers who depend on payment/reward flows.
- Citizen Wallet legacy users.
- Internal operators running deployment and support.

## Message Principles

- Lead with continuity: balances and wallet addresses are intended to carry over.
- Be precise about required action: mobile users must update when prompted.
- Do not over-explain chain mechanics in user-facing copy.
- Mention that transaction history remains available, but old Berachain activity may appear separately or read-only.
- Avoid announcing irreversible Berachain wipe until after cutover is verified.

## Timeline Copy

### Pre-Update Notice

SFLuv is preparing a network upgrade from Berachain to Celo. Before the migration, mobile wallet users will need to install the latest app update. This update keeps your wallet compatible and lets SFLuv safely switch network settings when the migration is ready.

No balance action is required right now.

### Forced Mobile Update

An SFLuv Wallet update is required.

Please update to the latest version to continue using SFLuv. This version includes the compatibility checks needed for the upcoming Celo migration.

### Migration Scheduled

SFLuv is scheduled to migrate from Berachain to Celo on `[date/time/timezone]`.

During the migration, sends, redemptions, and merchant payments may be temporarily paused. Your SFLuv balance is expected to carry over to the same wallet address on Celo. We will post an update when the migration is complete.

### Cutover In Progress

SFLuv migration is in progress.

Some wallet actions may be temporarily unavailable while balances and services move from Berachain to Celo. Please avoid retrying payments repeatedly during this window.

### Complete

SFLuv has migrated to Celo.

You can continue using SFLuv through the latest web and mobile apps. Your migrated balance should now appear on Celo. Legacy Berachain transaction history will remain available for lookup.

### Support / Issue Report

If your balance or wallet does not look right after the migration, contact SFLuv support with:

- your wallet address
- app platform and version
- a screenshot of the issue
- the transaction hash, if applicable

## Merchant/Organizer Notes

- Confirm your payment wallet appears correctly after cutover.
- Avoid changing wallet settings during the migration window.
- Reward and workflow payouts may be paused during cutover and resumed after verification.

## Internal Comms Checklist

- Announce preliminary mobile update.
- Monitor update adoption.
- Announce migration window only after backend/client/Ponder/contracts are staged.
- Announce temporary pause before onchain deploy starts.
- Announce completion after web, mobile, Citizen Wallet, backend, and Ponder smoke tests pass.
- Hold Berachain deprecation/wipe announcement until after final verification.
