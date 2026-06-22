package migrate

import (
	"context"
	"fmt"
	"math/big"
	"strings"

	"github.com/SFLuv/migrator/backend/internal/runner"
)

// castCall runs `cast call` for a typed function signature and returns the
// decoded scalar result (first whitespace-delimited token of the first line).
func castCall(ctx context.Context, rpc, to, sig string, args ...string) (string, error) {
	cargs := append([]string{"call", "--rpc-url", rpc, to, sig}, args...)
	out, err := runner.Run(ctx, nil, "", "cast", cargs...)
	if err != nil {
		return "", fmt.Errorf("cast call %s: %w (%s)", sig, err, firstLine(out))
	}
	return firstToken(out), nil
}

func castBalance(ctx context.Context, rpc, address string) (string, error) {
	out, err := runner.Run(ctx, nil, "", "cast", "balance", address, "--rpc-url", rpc)
	if err != nil {
		return "", fmt.Errorf("cast balance %s: %w (%s)", address, err, firstLine(out))
	}
	return firstToken(out), nil
}

func castChainID(ctx context.Context, rpc string) (string, error) {
	out, err := runner.Run(ctx, nil, "", "cast", "chain-id", "--rpc-url", rpc)
	if err != nil {
		return "", fmt.Errorf("cast chain-id: %w (%s)", err, firstLine(out))
	}
	return firstToken(out), nil
}

func castBlockNumber(ctx context.Context, rpc string) (string, error) {
	out, err := runner.Run(ctx, nil, "", "cast", "block-number", "--rpc-url", rpc)
	if err != nil {
		return "", fmt.Errorf("cast block-number: %w (%s)", err, firstLine(out))
	}
	return firstToken(out), nil
}

func castKeccak(ctx context.Context, text string) (string, error) {
	out, err := runner.Run(ctx, nil, "", "cast", "keccak", text)
	if err != nil {
		return "", fmt.Errorf("cast keccak: %w (%s)", err, firstLine(out))
	}
	return firstToken(out), nil
}

func privateKeyAddress(ctx context.Context, key string) (string, error) {
	out, err := runner.Run(ctx, nil, "", "cast", "wallet", "address", "--private-key", key)
	if err != nil {
		return "", fmt.Errorf("deriving signer address: %w", err)
	}
	return firstToken(out), nil
}

// forgeArgs assembles a forge-script invocation. broadcast appends --broadcast.
func forgeArgs(scriptRef, rpc, privateKey string, broadcast bool, sigAndArgs ...string) []string {
	args := []string{"script", scriptRef}
	args = append(args, sigAndArgs...)
	args = append(args, "--rpc-url", rpc, "--private-key", privateKey)
	if broadcast {
		args = append(args, "--broadcast")
	}
	return args
}

// --- big.Int helpers --------------------------------------------------------

func parseBig(s string) (*big.Int, bool) {
	v, ok := new(big.Int).SetString(strings.TrimSpace(s), 10)
	return v, ok
}

func bigGTE(a, b *big.Int) bool { return a.Cmp(b) >= 0 }

func bigSubFloorZero(a, b *big.Int) *big.Int {
	if a.Cmp(b) > 0 {
		return new(big.Int).Sub(a, b)
	}
	return big.NewInt(0)
}

func bigMax(a, b *big.Int) *big.Int {
	if a.Cmp(b) >= 0 {
		return a
	}
	return b
}

func firstToken(s string) string {
	return firstField(firstLine(s))
}

func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return strings.TrimSpace(s[:i])
	}
	return s
}

func firstField(s string) string {
	return strings.TrimSpace(strings.SplitN(strings.TrimSpace(s), " ", 2)[0])
}
