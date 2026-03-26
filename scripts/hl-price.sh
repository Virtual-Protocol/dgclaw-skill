#!/usr/bin/env bash
# hl-price.sh — Query token prices from Hyperliquid
# Usage:
#   hl-price.sh ETH              # Single token price
#   hl-price.sh ETH BTC SOL      # Multiple tokens
#   hl-price.sh --all             # All available tokens (top 30 by name)
#   hl-price.sh --search doge     # Search by name (case-insensitive)

set -euo pipefail

API_URL="https://api.hyperliquid.xyz/info"

fetch_all_mids() {
  curl -s -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -d '{"type":"allMids"}'
}

if [[ $# -eq 0 ]]; then
  echo "Usage: hl-price.sh <TOKEN...> | --all | --search <query>"
  echo ""
  echo "Examples:"
  echo "  hl-price.sh ETH"
  echo "  hl-price.sh ETH BTC SOL"
  echo "  hl-price.sh --all"
  echo "  hl-price.sh --search doge"
  exit 0
fi

DATA=$(fetch_all_mids)

if [[ "$1" == "--all" ]]; then
  echo "$DATA" | python3 -c "
import sys, json
d = json.load(sys.stdin)
pairs = sorted(d.items(), key=lambda x: x[0])
print(f'{'Token':<12} {'Price':>14}')
print('-' * 28)
for k, v in pairs[:30]:
    print(f'{k:<12} \${float(v):>13,.2f}')
print(f'\n({len(d)} tokens total, showing top 30)')
"
elif [[ "$1" == "--search" ]]; then
  QUERY="${2:-}"
  if [[ -z "$QUERY" ]]; then
    echo "Usage: hl-price.sh --search <query>"
    exit 1
  fi
  echo "$DATA" | python3 -c "
import sys, json
d = json.load(sys.stdin)
q = '${QUERY}'.lower()
matches = [(k, v) for k, v in sorted(d.items()) if q in k.lower()]
if not matches:
    print(f'No tokens matching \"{q}\"')
    sys.exit(0)
print(f'{'Token':<12} {'Price':>14}')
print('-' * 28)
for k, v in matches:
    print(f'{k:<12} \${float(v):>13,.2f}')
"
else
  for TOKEN in "$@"; do
    UPPER=$(echo "$TOKEN" | tr '[:lower:]' '[:upper:]')
    PRICE=$(echo "$DATA" | python3 -c "
import sys, json
d = json.load(sys.stdin)
p = d.get('$UPPER')
if p: print(f'$UPPER: \${float(p):,.2f}')
else: print(f'$UPPER: not found')
")
    echo "$PRICE"
  done
fi
