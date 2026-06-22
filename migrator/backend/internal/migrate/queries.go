package migrate

import (
	"context"
	"fmt"
	"math/big"
	"regexp"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"
)

var hexAddrRe = regexp.MustCompile(`^0x[0-9a-f]{40}$`)

// parseExtraFunded parses MIGRATION_EXTRA_FUNDED_ADDRESSES into lowercased
// addresses. "none" (or empty) yields no extra addresses.
func parseExtraFunded(raw string) ([]string, error) {
	norm := strings.ToLower(strings.TrimSpace(raw))
	norm = strings.ReplaceAll(norm, " ", "")
	if norm == "" || norm == "none" {
		return nil, nil
	}
	var out []string
	for _, part := range strings.Split(norm, ",") {
		p := strings.TrimSpace(part)
		if p == "" {
			continue
		}
		if !hexAddrRe.MatchString(p) {
			return nil, fmt.Errorf("invalid address in MIGRATION_EXTRA_FUNDED_ADDRESSES: %s", p)
		}
		out = append(out, p)
	}
	return out, nil
}

// ponderNormalized reports whether the Ponder DB already carries the
// ponder_18_to_6 decimal-normalization marker.
func ponderNormalized(ctx context.Context, p *pgxpool.Pool) (bool, error) {
	var tableCount int
	if err := p.QueryRow(ctx, `SELECT COUNT(*) FROM pg_tables WHERE tablename = 'migration_decimal_normalization'`).Scan(&tableCount); err != nil {
		return false, err
	}
	if tableCount == 0 {
		return false, nil
	}
	var n int
	if err := p.QueryRow(ctx, `SELECT COUNT(*) FROM migration_decimal_normalization WHERE id = 'ponder_18_to_6'`).Scan(&n); err != nil {
		return false, err
	}
	return n > 0, nil
}

// amountExpr returns the SQL expression for a transfer_event amount in 6-decimal
// units: raw when already normalized, else divided by the (validated) scale.
func amountExpr(normalized bool, scale string) string {
	if normalized {
		return "amount"
	}
	return fmt.Sprintf("FLOOR(amount / %s)", scale)
}

// fundedAddresses returns the canonical funded set: every valid wallets-table
// address plus the configured extra funded addresses, all lowercased.
func fundedAddresses(ctx context.Context, appPool *pgxpool.Pool, extra []string) ([]string, error) {
	rows, err := appPool.Query(ctx, `
		SELECT addr FROM (
			SELECT LOWER(TRIM(eoa_address)) AS addr FROM wallets
			WHERE LOWER(TRIM(eoa_address)) ~ '^0x[0-9a-f]{40}$'
			UNION
			SELECT LOWER(TRIM(smart_address)) AS addr FROM wallets
			WHERE LOWER(TRIM(COALESCE(smart_address, ''))) ~ '^0x[0-9a-f]{40}$'
		) t;
	`)
	if err != nil {
		return nil, fmt.Errorf("querying wallet addresses: %w", err)
	}
	defer rows.Close()

	seen := map[string]struct{}{}
	var out []string
	for rows.Next() {
		var a string
		if err := rows.Scan(&a); err != nil {
			return nil, err
		}
		if _, ok := seen[a]; !ok {
			seen[a] = struct{}{}
			out = append(out, a)
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for _, a := range extra {
		if _, ok := seen[a]; !ok {
			seen[a] = struct{}{}
			out = append(out, a)
		}
	}
	return out, nil
}

// projectedDistributionTotal sums the positive normalized balances for the
// funded address set from the Ponder transfer events — the total the distributor
// must be able to back.
func projectedDistributionTotal(ctx context.Context, ponderPool *pgxpool.Pool, funded []string, amtExpr string) (*big.Int, error) {
	q := fmt.Sprintf(`
		WITH funded AS (
			SELECT DISTINCT LOWER(a) AS address FROM unnest($1::text[]) a
		),
		movements AS (
			SELECT LOWER("from") AS address, -(%s) AS delta FROM transfer_event
			UNION ALL
			SELECT LOWER("to") AS address, (%s) AS delta FROM transfer_event
		),
		balances AS (
			SELECT m.address, SUM(m.delta) AS bal
			FROM movements m
			JOIN funded f ON f.address = m.address
			GROUP BY m.address
		)
		SELECT COALESCE(SUM(bal) FILTER (WHERE bal > 0), 0)::text FROM balances;
	`, amtExpr, amtExpr)

	var total string
	if err := ponderPool.QueryRow(ctx, q, funded).Scan(&total); err != nil {
		return nil, fmt.Errorf("computing projected distribution total: %w", err)
	}
	v, ok := new(big.Int).SetString(strings.TrimSpace(total), 10)
	if !ok {
		return nil, fmt.Errorf("unexpected projected total %q", total)
	}
	return v, nil
}

// walletIntegrity counts wallet rows that would be silently dropped from the
// snapshot/deploy/distribution sets (critical), and non-EOA rows with no smart
// address (warnings).
func walletIntegrity(ctx context.Context, appPool *pgxpool.Pool) (critical, warnings int, err error) {
	row := appPool.QueryRow(ctx, `
		WITH w AS (
			SELECT id, is_eoa, smart_index,
			       LOWER(TRIM(COALESCE(eoa_address, ''))) AS eoa,
			       LOWER(TRIM(COALESCE(smart_address, ''))) AS sm
			FROM wallets
		)
		SELECT
			(SELECT COUNT(*) FROM w WHERE eoa !~ '^0x[0-9a-f]{40}$')
			+ (SELECT COUNT(*) FROM w WHERE sm <> '' AND sm !~ '^0x[0-9a-f]{40}$')
			+ (SELECT COUNT(*) FROM w WHERE sm ~ '^0x[0-9a-f]{40}$' AND smart_index IS NULL)
			+ (SELECT COUNT(*) FROM (
				SELECT eoa, smart_index FROM w
				WHERE sm ~ '^0x[0-9a-f]{40}$' AND smart_index IS NOT NULL
				GROUP BY eoa, smart_index HAVING COUNT(DISTINCT sm) > 1
			) d) AS critical,
			(SELECT COUNT(*) FROM w WHERE is_eoa = FALSE AND sm = '') AS warnings;
	`)
	if err = row.Scan(&critical, &warnings); err != nil {
		return 0, 0, fmt.Errorf("checking wallet integrity: %w", err)
	}
	return critical, warnings, nil
}
