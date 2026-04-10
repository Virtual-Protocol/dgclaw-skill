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

const UserSetAbstractionTypes = {
  'HyperliquidTransaction:UserSetAbstraction': [
    { name: 'hyperliquidChain', type: 'string' },
    { name: 'user', type: 'address' },
    { name: 'abstraction', type: 'string' },
    { name: 'nonce', type: 'uint64' },
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
    console.error('');
    console.error(err.stderr || err.message);
    process.exit(1);
  }
}

async function main() {
  const args = process.argv.slice(2);

  if (args.includes('--help') || args.includes('-h')) {
    console.log('Usage: npx tsx scripts/activate-unified.ts');
    console.log('');
    console.log('Activates Hyperliquid unified account mode for your ACP agent wallet.');
    console.log('Unified mode combines spot and perp balances into a single account.');
    console.log('Your USDC balance lives in the spot account and is used for both perp and HIP-3 trading.');
    console.log('This is required before trading.');
    process.exit(0);
  }

  const nonce = Date.now();

  const walletAddress = getWalletAddress();
  console.log(`Wallet: ${walletAddress}`);

  const action = {
    type: 'userSetAbstraction' as const,
    signatureChainId: `0x${CHAIN_ID.toString(16)}`,
    hyperliquidChain: 'Mainnet',
    user: walletAddress,
    abstraction: 'unifiedAccount',
    nonce,
  };

  const primaryType = Object.keys(UserSetAbstractionTypes)[0];
  const typedData = {
    domain: {
      name: 'HyperliquidSignTransaction',
      version: '1',
      chainId: CHAIN_ID,
      verifyingContract: ZERO_ADDRESS,
    },
    types: UserSetAbstractionTypes,
    primaryType,
    message: {
      hyperliquidChain: 'Mainnet',
      user: walletAddress,
      abstraction: 'unifiedAccount',
      nonce,
    },
  };

  console.log('\nSigning unified account activation...');

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
    console.log('\nUnified account activated successfully!');
    console.log('Spot and perp balances are now combined.');
  } else {
    console.error('\nFailed to activate unified account:');
    console.error(JSON.stringify(result, null, 2));
    process.exit(1);
  }
}

main().catch(console.error);
