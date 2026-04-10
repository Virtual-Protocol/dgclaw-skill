import 'dotenv/config';
import { privateKeyToAccount } from 'viem/accounts';
import { HttpTransport, ExchangeClient, InfoClient } from '@nktkas/hyperliquid';

// ---- Config ----

const HL_API_URL = 'https://api.hyperliquid.xyz';

interface TradeArgs {
  command: string;
  pair?: string;
  side?: 'long' | 'short';
  size?: string;
  leverage?: number;
  orderType?: 'market' | 'limit';
  limitPrice?: string;
  stopLoss?: string;
  takeProfit?: string;
}

// ---- CLI Parsing ----

function printUsage(): never {
  console.log(`Degenerate Claw — Hyperliquid Trading CLI

Usage: npx tsx scripts/trade.ts <command> [options]

Commands:
  open        Open a new position
  close       Close an existing position
  modify      Modify TP/SL/leverage on an open position
  positions   List open positions
  balance     Show account balance (spot + perp)
  tickers     List available trading pairs

Note: For deposits, use ACP job (see SKILL.md). For withdrawals, use scripts/withdraw.ts.

Options:
  --pair <symbol>       Asset symbol (e.g. ETH, BTC, xyz:TSLA)
  --side <long|short>   Position side (required for open)
  --size <usd>          Position size in USD notional (required for open)
  --leverage <n>        Leverage multiplier (default: 1)
  --type <market|limit> Order type (default: market)
  --limit-price <px>    Limit price (required for limit orders)
  --sl <px>             Stop loss trigger price
  --tp <px>             Take profit trigger price

Environment:
  HL_API_WALLET_KEY     API wallet private key (required)
  HL_MASTER_ADDRESS     Master account address (required — the ACP agent wallet)

Examples:
  npx tsx scripts/trade.ts open --pair ETH --side long --size 500 --leverage 5
  npx tsx scripts/trade.ts open --pair BTC --side short --size 1000 --leverage 3 --sl 105000 --tp 95000
  npx tsx scripts/trade.ts close --pair ETH
  npx tsx scripts/trade.ts modify --pair ETH --sl 3200 --tp 4000
  npx tsx scripts/trade.ts positions
  npx tsx scripts/trade.ts balance`);
  process.exit(1);
}

function parseArgs(): TradeArgs {
  const args = process.argv.slice(2);
  if (args.length === 0 || args.includes('--help') || args.includes('-h')) printUsage();

  const command = args[0];
  const result: TradeArgs = { command };

  for (let i = 1; i < args.length; i++) {
    switch (args[i]) {
      case '--pair':
        result.pair = args[++i];
        break;
      case '--side':
        result.side = args[++i] as 'long' | 'short';
        break;
      case '--size':
        result.size = args[++i];
        break;
      case '--leverage':
        result.leverage = parseInt(args[++i]);
        break;
      case '--type':
        result.orderType = args[++i] as 'market' | 'limit';
        break;
      case '--limit-price':
        result.limitPrice = args[++i];
        break;
      case '--sl':
        result.stopLoss = args[++i];
        break;
      case '--tp':
        result.takeProfit = args[++i];
        break;
      default:
        if (!args[i].startsWith('--')) break;
        console.error(`Unknown option: ${args[i]}`);
        process.exit(1);
    }
  }

  return result;
}

// ---- Helpers ----

interface AssetMeta {
  name: string;
  szDecimals: number;
  maxLeverage: number;
}

async function getAssetIndex(
  info: InfoClient,
  pair: string,
): Promise<{ index: number; meta: AssetMeta }> {
  const metaResponse = await info.meta();
  const universe = metaResponse.universe;
  const idx = universe.findIndex(
    (a: any) => a.name.toUpperCase() === pair.toUpperCase(),
  );
  if (idx === -1) {
    console.error(`Unknown pair: ${pair}`);
    console.error(`Available: ${universe.map((a: any) => a.name).join(', ')}`);
    process.exit(1);
  }
  return { index: idx, meta: universe[idx] as AssetMeta };
}

function formatPrice(price: number, significantFigures: number = 5): string {
  return price.toPrecision(significantFigures);
}

function formatSize(usdSize: number, price: number, szDecimals: number): string {
  const rawSize = usdSize / price;
  return rawSize.toFixed(szDecimals);
}

// ---- Commands ----

async function openPosition(
  exchange: ExchangeClient,
  info: InfoClient,
  args: TradeArgs,
  masterAddress: string,
) {
  if (!args.pair) { console.error('--pair is required'); process.exit(1); }
  if (!args.side) { console.error('--side is required'); process.exit(1); }
  if (!args.size) { console.error('--size is required'); process.exit(1); }

  const { index: assetId, meta } = await getAssetIndex(info, args.pair);
  const isBuy = args.side === 'long';
  const leverage = args.leverage ?? 1;

  // Set leverage first
  await exchange.updateLeverage({
    asset: assetId,
    isCross: true,
    leverage,
  });
  console.log(`Leverage set to ${leverage}x (cross margin)`);

  // Get current mid price for market orders
  const mids = await info.allMids();
  const midPrice = parseFloat(mids[args.pair!.toUpperCase()]);
  if (!midPrice) {
    console.error(`Could not get mid price for ${args.pair}`);
    process.exit(1);
  }

  let orderPrice: string;
  let tif: 'Ioc' | 'Gtc';

  if (args.orderType === 'limit' && args.limitPrice) {
    orderPrice = args.limitPrice;
    tif = 'Gtc';
  } else {
    // Market order: use IoC with 1% slippage buffer
    const slippage = isBuy ? 1.01 : 0.99;
    orderPrice = formatPrice(midPrice * slippage);
    tif = 'Ioc';
  }

  const sz = formatSize(parseFloat(args.size), midPrice, meta.szDecimals);

  console.log(`Opening ${args.side} ${args.pair} — size: ${sz} ($${args.size}), price: ${orderPrice}, leverage: ${leverage}x`);

  const result = await exchange.order({
    orders: [{
      a: assetId,
      b: isBuy,
      r: false,
      p: orderPrice,
      s: sz,
      t: { limit: { tif } },
    }],
    grouping: 'na',
  });

  console.log(JSON.stringify(result, null, 2));

  // Place TP/SL trigger orders if specified
  if (args.takeProfit) {
    console.log(`Setting take profit at ${args.takeProfit}...`);
    const tpResult = await exchange.order({
      orders: [{
        a: assetId,
        b: !isBuy,
        r: true,
        p: args.takeProfit,
        s: sz,
        t: {
          trigger: {
            triggerPx: args.takeProfit,
            isMarket: true,
            tpsl: 'tp',
          },
        },
      }],
      grouping: 'na',
    });
    console.log('Take profit set:', JSON.stringify(tpResult, null, 2));
  }

  if (args.stopLoss) {
    console.log(`Setting stop loss at ${args.stopLoss}...`);
    const slResult = await exchange.order({
      orders: [{
        a: assetId,
        b: !isBuy,
        r: true,
        p: args.stopLoss,
        s: sz,
        t: {
          trigger: {
            triggerPx: args.stopLoss,
            isMarket: true,
            tpsl: 'sl',
          },
        },
      }],
      grouping: 'na',
    });
    console.log('Stop loss set:', JSON.stringify(slResult, null, 2));
  }
}

async function closePosition(
  exchange: ExchangeClient,
  info: InfoClient,
  args: TradeArgs,
  masterAddress: string,
) {
  if (!args.pair) { console.error('--pair is required'); process.exit(1); }

  const { index: assetId } = await getAssetIndex(info, args.pair);

  // Get current position to determine size and side
  const state = await info.clearinghouseState({ user: masterAddress as `0x${string}` });
  const position = state.assetPositions.find(
    (p: any) => p.position.coin.toUpperCase() === args.pair!.toUpperCase(),
  );

  if (!position) {
    console.error(`No open position for ${args.pair}`);
    process.exit(1);
  }

  const posSize = parseFloat(position.position.szi);
  const isBuy = posSize < 0; // Close short = buy, close long = sell
  const sz = Math.abs(posSize).toString();

  // Market close with 1% slippage
  const mids = await info.allMids();
  const midPrice = parseFloat(mids[args.pair!.toUpperCase()]);
  const slippage = isBuy ? 1.01 : 0.99;
  const orderPrice = formatPrice(midPrice * slippage);

  console.log(`Closing ${args.pair} position — size: ${sz}, price: ${orderPrice}`);

  const result = await exchange.order({
    orders: [{
      a: assetId,
      b: isBuy,
      r: true,
      p: orderPrice,
      s: sz,
      t: { limit: { tif: 'Ioc' } },
    }],
    grouping: 'na',
  });

  console.log(JSON.stringify(result, null, 2));
}

async function modifyPosition(
  exchange: ExchangeClient,
  info: InfoClient,
  args: TradeArgs,
  masterAddress: string,
) {
  if (!args.pair) { console.error('--pair is required'); process.exit(1); }
  if (!args.leverage && !args.stopLoss && !args.takeProfit) {
    console.error('At least one of --leverage, --sl, or --tp is required');
    process.exit(1);
  }

  const { index: assetId } = await getAssetIndex(info, args.pair);

  // Get current position
  const state = await info.clearinghouseState({ user: masterAddress as `0x${string}` });
  const position = state.assetPositions.find(
    (p: any) => p.position.coin.toUpperCase() === args.pair!.toUpperCase(),
  );

  if (!position) {
    console.error(`No open position for ${args.pair}`);
    process.exit(1);
  }

  const posSize = parseFloat(position.position.szi);
  const isBuy = posSize > 0; // Long position
  const sz = Math.abs(posSize).toString();

  if (args.leverage) {
    await exchange.updateLeverage({
      asset: assetId,
      isCross: true,
      leverage: args.leverage,
    });
    console.log(`Leverage updated to ${args.leverage}x`);
  }

  // Cancel existing TP/SL orders before placing new ones
  const openOrders = await info.openOrders({ user: masterAddress as `0x${string}` });
  const tpslOrders = openOrders.filter(
    (o: any) => o.coin?.toUpperCase() === args.pair!.toUpperCase() && o.orderType?.includes('trigger'),
  );
  if (tpslOrders.length > 0) {
    for (const order of tpslOrders) {
      try {
        await exchange.cancel({ cancels: [{ a: assetId, o: order.oid }] });
      } catch {
        // Ignore cancel failures for already-filled orders
      }
    }
  }

  if (args.takeProfit) {
    console.log(`Setting take profit at ${args.takeProfit}...`);
    const tpResult = await exchange.order({
      orders: [{
        a: assetId,
        b: !isBuy,
        r: true,
        p: args.takeProfit,
        s: sz,
        t: {
          trigger: {
            triggerPx: args.takeProfit,
            isMarket: true,
            tpsl: 'tp',
          },
        },
      }],
      grouping: 'na',
    });
    console.log('Take profit set:', JSON.stringify(tpResult, null, 2));
  }

  if (args.stopLoss) {
    console.log(`Setting stop loss at ${args.stopLoss}...`);
    const slResult = await exchange.order({
      orders: [{
        a: assetId,
        b: !isBuy,
        r: true,
        p: args.stopLoss,
        s: sz,
        t: {
          trigger: {
            triggerPx: args.stopLoss,
            isMarket: true,
            tpsl: 'sl',
          },
        },
      }],
      grouping: 'na',
    });
    console.log('Stop loss set:', JSON.stringify(slResult, null, 2));
  }
}

async function showPositions(info: InfoClient, masterAddress: string) {
  const state = await info.clearinghouseState({ user: masterAddress as `0x${string}` });
  const positions = state.assetPositions.filter(
    (p: any) => parseFloat(p.position.szi) !== 0,
  );

  if (positions.length === 0) {
    console.log('No open positions');
    return;
  }

  console.log(JSON.stringify(positions, null, 2));
}

async function showBalance(info: InfoClient, masterAddress: string) {
  const user = masterAddress as `0x${string}`;

  // Spot balance (primary balance in unified account mode)
  const spotState = await info.spotClearinghouseState({ user });
  const spotBalances = spotState.balances.filter(
    (b: any) => parseFloat(b.hold) !== 0 || parseFloat(b.total) !== 0,
  );

  // Perp balance (margin summary)
  const perpState = await info.clearinghouseState({ user });

  console.log(
    JSON.stringify(
      {
        spot: {
          balances: spotBalances,
        },
        perp: {
          accountValue: perpState.marginSummary.accountValue,
          totalMarginUsed: perpState.marginSummary.totalMarginUsed,
          withdrawable: perpState.withdrawable,
          crossMaintenanceMarginUsed: perpState.crossMaintenanceMarginUsed,
        },
      },
      null,
      2,
    ),
  );
}

async function showTickers(info: InfoClient) {
  const meta = await info.meta();
  const mids = await info.allMids();

  const tickers = meta.universe.map((asset: any, i: number) => ({
    symbol: asset.name,
    midPrice: mids[asset.name] ?? 'N/A',
    maxLeverage: asset.maxLeverage,
    szDecimals: asset.szDecimals,
  }));

  console.log(JSON.stringify(tickers, null, 2));
}

// ---- Main ----

async function main() {
  const args = parseArgs();

  const apiWalletKey = process.env.HL_API_WALLET_KEY;
  const masterAddress = process.env.HL_MASTER_ADDRESS;

  if (!apiWalletKey) {
    console.error('HL_API_WALLET_KEY not set. Run scripts/add-api-wallet.ts first.');
    process.exit(1);
  }
  if (!masterAddress) {
    console.error('HL_MASTER_ADDRESS not set. Set it to your ACP agent wallet address.');
    console.error('  Find it with: acp whoami --json');
    process.exit(1);
  }

  const account = privateKeyToAccount(apiWalletKey as `0x${string}`);

  const transport = new HttpTransport({ url: HL_API_URL });
  const info = new InfoClient({ transport });
  const exchange = new ExchangeClient({
    wallet: account,
    transport,
  });

  switch (args.command) {
    case 'open':
      await openPosition(exchange, info, args, masterAddress);
      break;
    case 'close':
      await closePosition(exchange, info, args, masterAddress);
      break;
    case 'modify':
      await modifyPosition(exchange, info, args, masterAddress);
      break;
    case 'positions':
      await showPositions(info, masterAddress);
      break;
    case 'balance':
      await showBalance(info, masterAddress);
      break;
    case 'tickers':
      await showTickers(info);
      break;
    default:
      console.error(`Unknown command: ${args.command}`);
      printUsage();
  }
}

main().catch((err) => {
  console.error('Error:', err.message);
  process.exit(1);
});
