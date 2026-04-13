import 'dotenv/config';
import { execSync } from 'child_process';
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts';
import { readFileSync, writeFileSync, existsSync } from 'fs';
import { join, dirname, resolve } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ENV_PATH = join(__dirname, '..', '.env');

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
const CHAIN_ID = 42161; // Arbitrum
const HL_API_URL = 'https://api.hyperliquid.xyz/exchange';

// EIP-712 types for Hyperliquid approveAgent action
const ApproveAgentTypes = {
  'HyperliquidTransaction:ApproveAgent': [
    { name: 'hyperliquidChain', type: 'string' },
    { name: 'agentAddress', type: 'address' },
    { name: 'agentName', type: 'string' },
    { name: 'nonce', type: 'uint64' },
  ],
} as const;

function parseArgs(): { agentName: string | null } {
  const args = process.argv.slice(2);

  if (args.includes('--help') || args.includes('-h')) {
    console.log('Usage: npx tsx scripts/add-api-wallet.ts [--name <walletName>]');
    console.log('');
    console.log('Generates a new EVM wallet and registers it as a Hyperliquid API wallet.');
    console.log('Uses your ACP agent wallet to sign the approval transaction.');
    console.log('');
    console.log('Options:');
    console.log('  --name <name>     Optional name for the API wallet');
    console.log('');
    console.log('Output: Saves HL_API_WALLET_KEY and HL_API_WALLET_ADDRESS to .env');
    process.exit(0);
  }

  const nameIdx = args.indexOf('--name');
  const agentName = nameIdx !== -1 && args[nameIdx + 1] ? args[nameIdx + 1] : null;

  return { agentName };
}

function buildTypedData(apiWalletAddress: string, agentName: string | null) {
  const nonce = Date.now();

  const domain = {
    name: 'HyperliquidSignTransaction',
    version: '1',
    chainId: CHAIN_ID,
    verifyingContract: ZERO_ADDRESS,
  };

  const primaryType = Object.keys(ApproveAgentTypes)[0];

  const message = {
    hyperliquidChain: 'Mainnet',
    agentAddress: apiWalletAddress,
    agentName: agentName ?? '',
    nonce,
  };

  const action = {
    type: 'approveAgent' as const,
    signatureChainId: `0x${CHAIN_ID.toString(16)}`,
    hyperliquidChain: 'Mainnet',
    agentAddress: apiWalletAddress,
    agentName: agentName ?? null,
    nonce,
  };

  return { domain, types: ApproveAgentTypes, primaryType, message, action, nonce };
}

function parseSignature(sig: string): { r: string; s: string; v: number } {
  const raw = sig.startsWith('0x') ? sig.slice(2) : sig;
  return {
    r: `0x${raw.slice(0, 64)}`,
    s: `0x${raw.slice(64, 128)}`,
    v: parseInt(raw.slice(128, 130), 16),
  };
}

function appendToEnv(key: string, value: string) {
  let content = '';
  if (existsSync(ENV_PATH)) {
    content = readFileSync(ENV_PATH, 'utf-8');
    // Remove existing key if present
    content = content
      .split('\n')
      .filter((line) => !line.startsWith(`${key}=`))
      .join('\n');
    if (content && !content.endsWith('\n')) content += '\n';
  }
  content += `${key}=${value}\n`;
  writeFileSync(ENV_PATH, content);
}

async function main() {
  const { agentName } = parseArgs();

  // Step 1: Get master wallet address from ACP CLI
  console.log('Getting agent wallet address...');
  let masterAddress: string;
  try {
    const whoami = execSync(`${ACP} agent whoami --json`, {
      encoding: 'utf-8',
      cwd: ACP_DIR,
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    const parsed = JSON.parse(whoami);
    masterAddress = parsed.wallet?.address ?? parsed.address ?? parsed.data?.wallet?.address;
    if (!masterAddress) {
      throw new Error('Could not find wallet address in whoami output');
    }
    console.log(`Master wallet address: ${masterAddress}`);
  } catch (err: any) {
    console.error('Failed to get agent wallet address from ACP CLI.');
    console.error(err.stderr || err.message);
    process.exit(1);
  }

  // Step 2: Generate a new EVM wallet pair
  console.log('Generating new EVM wallet pair...');
  const privateKey = generatePrivateKey();
  const account = privateKeyToAccount(privateKey);
  console.log(`API wallet address: ${account.address}`);

  // Step 3: Build the approveAgent typed data
  const { domain, types, primaryType, message, action, nonce } = buildTypedData(
    account.address,
    agentName,
  );

  const typedData = { domain, types, primaryType, message };
  console.log('\nSigning approveAgent...');

  // Step 4: Sign via ACP CLI
  // The ACP CLI signs typed data using the agent's managed wallet
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

  // Step 5: Broadcast to Hyperliquid
  console.log('Broadcasting to Hyperliquid...');
  const response = await fetch(HL_API_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ action, signature: { r, s, v }, nonce }),
  });

  const result = await response.json();

  if (result.status === 'ok') {
    // Step 6: Save to .env
    appendToEnv('HL_API_WALLET_KEY', privateKey);
    appendToEnv('HL_API_WALLET_ADDRESS', account.address);
    appendToEnv('HL_MASTER_ADDRESS', masterAddress);

    console.log('\nAPI wallet registered successfully!');
    console.log(`  Address: ${account.address}`);
    console.log(`  Saved to: ${ENV_PATH}`);
    console.log('\nYou can now trade with: npx tsx scripts/trade.ts open --pair ETH --side long --size 500');
  } else {
    console.error('\nFailed to register API wallet:');
    console.error(JSON.stringify(result, null, 2));
    console.error('\nThe private key was NOT saved. Fix the issue and retry.');
    process.exit(1);
  }
}

main().catch(console.error);
