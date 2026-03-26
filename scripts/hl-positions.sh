#!/usr/bin/env bash
# hl-positions.sh — Check positions, TP/SL, and account summary directly from Hyperliquid
# Usage:
#   hl-positions.sh                          # Use HL address from .env
#   hl-positions.sh <walletAddress>          # Explicit address
#   hl-positions.sh --orders                 # Show raw open orders
#   hl-positions.sh --json                   # Raw JSON output

set -euo pipefail

API_URL="https://api.hyperliquid.xyz/info"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"

# Load env for HL_ADDRESS default
if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
fi

# Parse flags
SHOW_ORDERS=false
JSON_MODE=false
ADDRESS=""

for arg in "$@"; do
  case "$arg" in
    --orders) SHOW_ORDERS=true ;;
    --json)   JSON_MODE=true ;;
    0x*)      ADDRESS="$arg" ;;
    *)        echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

# Resolve address: arg > env > error
if [[ -z "$ADDRESS" ]]; then
  ADDRESS="${HL_ADDRESS:-}"
fi
if [[ -z "$ADDRESS" ]]; then
  echo "Error: No HL address provided."
  echo "Set HL_ADDRESS in .env or pass address as argument."
  echo "Usage: hl-positions.sh [<address>] [--orders] [--json]"
  exit 1
fi

# Fetch data in parallel
STATE=$(curl -s -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -d "{\"type\":\"clearinghouseState\",\"user\":\"$ADDRESS\"}")

ORDERS=$(curl -s -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -d "{\"type\":\"openOrders\",\"user\":\"$ADDRESS\"}")

if $JSON_MODE; then
  echo "{\"state\":$STATE,\"orders\":$ORDERS}"
  exit 0
fi

if $SHOW_ORDERS; then
  echo "$ORDERS" | python3 -m json.tool
  exit 0
fi

python3 - "$ADDRESS" <<'PYEOF'
import sys, json, os

address = sys.argv[1]

state_raw = sys.stdin.read()
PYEOF

# Pass both via env vars to python
export _HL_STATE="$STATE"
export _HL_ORDERS="$ORDERS"

python3 - "$ADDRESS" <<'PYEOF'
import sys, json, os

address = sys.argv[1]
state  = json.loads(os.environ["_HL_STATE"])
orders = json.loads(os.environ["_HL_ORDERS"])

ms = state.get("marginSummary", {})
positions = [ap["position"] for ap in state.get("assetPositions", [])]

# Build TP/SL map from open orders (reduceOnly orders grouped by coin)
tp_sl = {}
for o in orders:
    coin = o["coin"]
    if coin not in tp_sl:
        tp_sl[coin] = {"tp": None, "sl": None}
    px = float(o["limitPx"])
    # For a short position: TP is lower price (buy back cheaper), SL is higher price
    # For a long position: TP is higher price, SL is lower price
    # We infer by looking at position side
    tp_sl[coin].setdefault("_orders", [])
    tp_sl[coin]["_orders"].append(px)

# Assign TP/SL per coin by matching position side
for ap in state.get("assetPositions", []):
    pos = ap["position"]
    coin = pos["coin"]
    szi = float(pos["szi"])
    if coin not in tp_sl or "_orders" not in tp_sl[coin]:
        continue
    prices = sorted(tp_sl[coin]["_orders"])
    if szi < 0:  # short: TP = lower, SL = higher
        tp_sl[coin]["tp"] = prices[0] if prices else None
        tp_sl[coin]["sl"] = prices[-1] if len(prices) > 1 else None
    else:  # long: TP = higher, SL = lower
        tp_sl[coin]["tp"] = prices[-1] if prices else None
        tp_sl[coin]["sl"] = prices[0] if len(prices) > 1 else None

# Account summary
print(f"Address : {address}")
print(f"{'─'*62}")
print(f"  Account Value   : ${float(ms.get('accountValue',0)):>10,.4f} USDC")
print(f"  Total Notional  : ${float(ms.get('totalNtlPos',0)):>10,.4f}")
print(f"  Margin Used     : ${float(ms.get('totalMarginUsed',0)):>10,.4f}")
print(f"  Withdrawable    : ${float(ms.get('withdrawable', state.get('withdrawable',0))):>10,.4f} USDC")
print(f"{'─'*62}")

if not positions:
    print("  No open positions.")
else:
    # Header
    print(f"  {'Pair':<8} {'Side':<6} {'Entry':>10} {'Mark':>10} {'Size':>8} {'Margin':>8} {'uPnL':>9} {'ROE':>7} {'TP':>10} {'SL':>10}")
    print(f"  {'─'*8} {'─'*6} {'─'*10} {'─'*10} {'─'*8} {'─'*8} {'─'*9} {'─'*7} {'─'*10} {'─'*10}")
    for pos in positions:
        coin    = pos["coin"]
        szi     = float(pos["szi"])
        side    = "Short" if szi < 0 else "Long"
        entry   = float(pos["entryPx"])
        mark    = float(pos.get("positionValue", 0)) / abs(szi) if szi != 0 else 0
        margin  = float(pos["marginUsed"])
        upnl    = float(pos["unrealizedPnl"])
        roe     = float(pos["returnOnEquity"]) * 100
        liq_raw = pos.get("liquidationPx")
        liq     = float(liq_raw) if liq_raw is not None else 0.0

        tpsl    = tp_sl.get(coin, {})
        tp_str  = f"${tpsl['tp']:,.4f}" if tpsl.get("tp") else "—"
        sl_str  = f"${tpsl['sl']:,.4f}" if tpsl.get("sl") else "—"

        upnl_str = f"{upnl:+.4f}"
        roe_str  = f"{roe:+.2f}%"
        size_str = f"{abs(szi)}"

        print(f"  {coin:<8} {side:<6} ${entry:>9,.4f} ${mark:>9,.4f} {size_str:>8} ${margin:>7,.3f} {upnl_str:>9} {roe_str:>7} {tp_str:>10} {sl_str:>10}")
        if liq > 0:
            print(f"  {'':8} {'':6} {'Liq:':>10} ${liq:>9,.2f}")

print(f"{'─'*62}")
PYEOF
