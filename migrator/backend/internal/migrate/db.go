package migrate

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5/pgxpool"
)

func (s *Session) appPool(ctx context.Context) (*pgxpool.Pool, error) {
	url, err := s.cfg.AppDBURL()
	if err != nil {
		return nil, err
	}
	return s.pool(ctx, url)
}

func (s *Session) ponderPool(ctx context.Context) (*pgxpool.Pool, error) {
	url, err := s.cfg.PonderDBURL()
	if err != nil {
		return nil, err
	}
	return s.pool(ctx, url)
}

func (s *Session) botPool(ctx context.Context) (*pgxpool.Pool, error) {
	url, err := s.cfg.BotDBURL()
	if err != nil {
		return nil, err
	}
	return s.pool(ctx, url)
}

// pingDB verifies connectivity to a derived database.
func pingDB(ctx context.Context, p *pgxpool.Pool) error {
	var one int
	if err := p.QueryRow(ctx, "SELECT 1").Scan(&one); err != nil {
		return fmt.Errorf("query failed: %w", err)
	}
	return nil
}
