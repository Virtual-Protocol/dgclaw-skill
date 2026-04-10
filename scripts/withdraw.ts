import 'dotenv/config';
import { execSync } from 'child_process';
import { existsSync } from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));

const ACP_DIR = process.env.ACP_CLI_DIR || resolve(__dirname, '..', '..', 'acp-cli');

function getAcpBin(): string {
  const bin = resolve(ACP_DIR, 'bin', 'acp.ts');
  if (!existsSync(bin)) {
    console.error(`acp-cli not found at ${bin}`);
    console.error('Set ACP_CLI_DIR or clone acp-cli as a sibling directory.');
    process.exit(1);
  }
  return `npx tsx ${bin}`;
}

const ACP = getAcpBin();

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';
const CHAIN_ID = 42161;
const HL_API_URL = 'https://api.hyperliquid.xyz/exchange';

const Withdraw3Types = {
  'HyperliquidTransaction:Withdraw': [
    { name: 'hyperliquidChain', type: 'string' },
    { name: 'destination', type: 'string' },
    { name: 'amount', type: 'string' },
    { name: 'time', type: 'uint64' },
  ],
} as const;

function parseSignature(sig: string): { r: string; s: string; v: number } {
  const raw = sig.startsWith('0x') ? sig.slice(2) : sig;
  return {
    r: `0x${raw.slice(0, 64)}`,
    s: `0x${raw.slice(64, 128)}`,
    v: parseInt(raw.slice(128, 130), 16),
  };
}

function getWalletAddress(): string {
  try {
    const result = execSync(`${ACP} agent whoami --json`, { encoding: 'utf-8', cwd: ACP_DIR, stdio: ['pipe', 'pipe', 'pipe'] });
    const parsed = JSON.parse(result);
    return parsed.walletAddress ?? parsed.data?.walletAddress ?? parsed.address;
  } catch (err: any) {
    console.error('Failed to get wallet address. Make sure acp-cli is configured:');
    console.error('  acp configure && acp agent create');
    process.exit(1);
  }
}

async function main() {
  const args = process.argv.slice(2);

  if (args.includes('--help') || args.includes('-h') || args.length === 0) {
    console.log('Usage: npx tsx scripts/withdraw.ts --amount <usdc> [--destination <address>]');
    console.log('');
    console.log('Withdraw USDC from Hyperliquid to Arbitrum.');
    console.log('Builds the withdrawal transaction and signs it via ACP CLI (master wallet).');
    console.log('');
    console.log('Options:');
    console.log('  --amount <usdc>          USDC amount to withdraw (required)');
    console.log('  --destination <address>  Arbitrum address to receive USDC (default: your agent wallet)');
    process.exit(args.length === 0 ? 1 : 0);
  }

  const amountIdx = args.indexOf('--amount');
  if (amountIdx === -1 || !args[amountIdx + 1]) {
    console.error('--amount is required');
    process.exit(1);
  }
  const amount = args[amountIdx + 1];

  const walletAddress = getWalletAddress();

  const destIdx = args.indexOf('--destination');
  const destination = destIdx !== -1 && args[destIdx + 1] ? args[destIdx + 1] : walletAddress;

  const nonce = Date.now();

  const action = {
    type: 'withdraw3' as const,
    signatureChainId: `0x${CHAIN_ID.toString(16)}`,
    hyperliquidChain: 'Mainnet',
    destination,
    amount,
    time: nonce,
  };

  const primaryType = Object.keys(Withdraw3Types)[0];
  const typedData = {
    domain: {
      name: 'HyperliquidSignTransaction',
      version: '1',
      chainId: CHAIN_ID,
      verifyingContract: ZERO_ADDRESS,
    },
    types: Withdraw3Types,
    primaryType,
    message: {
      hyperliquidChain: 'Mainnet',
      destination,
      amount,
      time: nonce,
    },
  };

  console.log(`Withdrawing ${amount} USDC to ${destination}`);
  console.log('\nSigning withdrawal transaction...');

  let signature: string;
  try {
    const typedDataJson = JSON.stringify(typedData);
    const result = execSync(`${ACP} wallet sign-typed-data --data '${typedDataJson}' --json`, {
      encoding: 'utf-8',
      cwd: ACP_DIR,
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    const parsed = JSON.parse(result);
    signature = parsed.signature ?? parsed.data?.signature ?? result.trim();
  } catch (err: any) {
    console.error('Failed to sign with ACP CLI. Make sure acp-cli is configured:');
    console.error('  acp configure && acp agent add-signer');
    console.error('');
    console.error(err.stderr || err.message);
    process.exit(1);
  }

  const { r, s, v } = parseSignature(signature);

  console.log('Broadcasting to Hyperliquid...');
  const response = await fetch(HL_API_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ action, signature: { r, s, v }, nonce }),
  });

  const result = await response.json();

  if (result.status === 'ok') {
    console.log('\nWithdrawal submitted successfully!');
    console.log(`  Amount: ${amount} USDC`);
    console.log(`  Destination: ${destination}`);
    console.log('  Note: Withdrawal may take a few minutes to process on Arbitrum.');
  } else {
    console.error('\nWithdrawal failed:');
    console.error(JSON.stringify(result, null, 2));
    process.exit(1);
  }
}

main().catch(console.error);
