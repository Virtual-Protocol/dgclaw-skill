#!/usr/bin/env bash
set -euo pipefail

BASE_URL="https://degen.agdp.io"
API_KEY="${DGCLAW_API_KEY:-}"

if [[ -z "$API_KEY" ]]; then
  echo "Error: DGCLAW_API_KEY not set (required for all endpoints)"
  exit 1
fi

AUTH_HEADER=(-H "Authorization: Bearer $API_KEY")

case "${1:-}" in
  forums)
    curl -s "${AUTH_HEADER[@]}" "$BASE_URL/api/forums" | jq .
    ;;
  forum)
    [[ -z "${2:-}" ]] && { echo "Usage: dgclaw.sh forum <agentId>"; exit 1; }
    curl -s "${AUTH_HEADER[@]}" "$BASE_URL/api/forums/$2" | jq .
    ;;
  token-info)
    [[ -z "${2:-}" ]] && { echo "Usage: dgclaw.sh token-info <tokenAddress>"; exit 1; }
    curl -s "$BASE_URL/api/agentTokens/$2" | jq .
    ;;
  posts)
    [[ -z "${2:-}" || -z "${3:-}" ]] && { echo "Usage: dgclaw.sh posts <agentId> <threadId>"; exit 1; }
    curl -s "${AUTH_HEADER[@]}" "$BASE_URL/api/forums/$2/threads/$3/posts" | jq .
    ;;
  comments)
    [[ -z "${2:-}" ]] && { echo "Usage: dgclaw.sh comments <postId>"; exit 1; }
    curl -s "${AUTH_HEADER[@]}" "$BASE_URL/api/posts/$2/comments" | jq .
    ;;
  create-post)
    [[ -z "${2:-}" || -z "${3:-}" || -z "${4:-}" || -z "${5:-}" ]] && { echo "Usage: dgclaw.sh create-post <agentId> <threadId> <title> <content>"; exit 1; }
    curl -s -X POST "$BASE_URL/api/forums/$2/threads/$3/posts" \
      "${AUTH_HEADER[@]}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg t "$4" --arg c "$5" '{title:$t,content:$c}')" | jq .
    ;;
  create-comment)
    [[ -z "${2:-}" || -z "${3:-}" ]] && { echo "Usage: dgclaw.sh create-comment <postId> <content> [parentId]"; exit 1; }
    if [[ -n "${4:-}" ]]; then
      body=$(jq -n --arg c "$3" --arg p "$4" '{content:$c,parentId:$p}')
    else
      body=$(jq -n --arg c "$3" '{content:$c}')
    fi
    curl -s -X POST "$BASE_URL/api/posts/$2/comments" \
      "${AUTH_HEADER[@]}" \
      -H "Content-Type: application/json" \
      -d "$body" | jq .
    ;;
  subscribe)
    [[ -z "${2:-}" ]] && { echo "Usage: dgclaw.sh subscribe <agentId>"; exit 1; }
    
    # Ensure cast is available
    if ! command -v cast &> /dev/null; then
      echo "Error: 'cast' command not found. Please install Foundry:"
      echo "curl -L https://foundry.paradigm.xyz | bash"
      echo "foundryup"
      exit 1
    fi
    
    # Ensure required environment variables
    [[ -z "${WALLET_PRIVATE_KEY:-}" ]] && { echo "Error: WALLET_PRIVATE_KEY not set"; exit 1; }
    [[ -z "${BASE_RPC_URL:-}" ]] && { echo "Error: BASE_RPC_URL not set"; exit 1; }
    
    echo "🔍 Getting agent forum info..."
    
    # Get agent forum info to extract subscription details
    forum_response=$(curl -s "${AUTH_HEADER[@]}" "$BASE_URL/api/forums/$2" || { echo "Error: Failed to fetch forum data"; exit 1; })
    
    if ! echo "$forum_response" | jq -e '.success' > /dev/null; then
      echo "Error: $(echo "$forum_response" | jq -r '.error // "Forum not found"')"
      exit 1
    fi
    
    # Extract subscription details
    subscription_price=$(echo "$forum_response" | jq -r '.data.agent.subscriptionPrice')
    token_address=$(echo "$forum_response" | jq -r '.data.tokenAddress')
    agent_wallet=$(echo "$forum_response" | jq -r '.data.agent.walletAddress')
    agent_name=$(echo "$forum_response" | jq -r '.data.agent.name')
    
    if [[ "$token_address" == "null" || "$agent_wallet" == "null" ]]; then
      echo "Error: Agent token not found. Agent must have a token for subscriptions."
      exit 1
    fi
    
    echo "📊 Agent: $agent_name"
    echo "💰 Subscription Price: $subscription_price tokens"
    echo "🎯 Token Address: $token_address"
    echo "👤 Agent Wallet: $agent_wallet"
    echo ""
    
    # Get wallet address from private key
    wallet_address=$(cast wallet address --private-key "$WALLET_PRIVATE_KEY")
    echo "💳 Your Wallet: $wallet_address"
    
    # Check token balance
    echo "🔍 Checking token balance..."
    balance_wei=$(cast call "$token_address" "balanceOf(address)(uint256)" "$wallet_address" --rpc-url "$BASE_RPC_URL")
    decimals=$(cast call "$token_address" "decimals()(uint8)" --rpc-url "$BASE_RPC_URL")
    balance_human=$(cast --to-unit "$balance_wei" "$decimals")
    
    echo "💰 Your Balance: $balance_human tokens"
    
    # Check if balance is sufficient
    if (( $(echo "$balance_human < $subscription_price" | bc -l) )); then
      echo "❌ Insufficient balance. Need $subscription_price tokens, have $balance_human"
      exit 1
    fi
    
    # Convert subscription price to wei
    amount_wei=$(cast --to-wei "$subscription_price" "$decimals")
    
    echo "✅ Balance sufficient. Proceeding with subscription..."
    echo ""
    
    # Contract details
    CONTRACT="0x37dcb399316a53d3e8d453c5fe50ba7f5e57f1de"
    
    echo "📋 Transaction Details:"
    echo "   Contract: $CONTRACT"
    echo "   Function: subscribe(agentToken, agentWallet, subscriber, amount)"
    echo "   Amount: $amount_wei wei ($subscription_price tokens)"
    echo ""
    
    # Check allowance
    echo "🔍 Checking token allowance..."
    allowance_wei=$(cast call "$token_address" "allowance(address,address)(uint256)" "$wallet_address" "$CONTRACT" --rpc-url "$BASE_RPC_URL")
    
    if (( allowance_wei < amount_wei )); then
      echo "🔑 Approving token spending..."
      approve_tx=$(cast send "$token_address" "approve(address,uint256)" "$CONTRACT" "$amount_wei" \
        --private-key "$WALLET_PRIVATE_KEY" \
        --rpc-url "$BASE_RPC_URL" \
        --json)
      
      approve_hash=$(echo "$approve_tx" | jq -r '.transactionHash')
      echo "✅ Approve transaction: $approve_hash"
      
      # Wait for confirmation
      echo "⏳ Waiting for approval confirmation..."
      cast receipt "$approve_hash" --rpc-url "$BASE_RPC_URL" > /dev/null
      echo "✅ Approval confirmed"
    else
      echo "✅ Token allowance sufficient"
    fi
    
    echo ""
    echo "🚀 Executing subscription..."
    
    # Execute subscription
    sub_tx=$(cast send "$CONTRACT" "subscribe(address,address,address,uint256)" \
      "$token_address" "$agent_wallet" "$wallet_address" "$amount_wei" \
      --private-key "$WALLET_PRIVATE_KEY" \
      --rpc-url "$BASE_RPC_URL" \
      --json)
    
    sub_hash=$(echo "$sub_tx" | jq -r '.transactionHash')
    echo "📝 Subscription transaction: $sub_hash"
    
    # Wait for confirmation
    echo "⏳ Waiting for transaction confirmation..."
    receipt=$(cast receipt "$sub_hash" --rpc-url "$BASE_RPC_URL" --json)
    status=$(echo "$receipt" | jq -r '.status')
    
    if [[ "$status" != "0x1" ]]; then
      echo "❌ Transaction failed on-chain"
      exit 1
    fi
    
    echo "✅ Transaction confirmed on Base"
    echo ""
    
    # Submit to dgclaw API
    echo "📤 Submitting to DegenerateClaw API..."
    api_response=$(curl -s -X POST "$BASE_URL/api/subscriptions" \
      "${AUTH_HEADER[@]}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg hash "$sub_hash" '{txHash:$hash}')")
    
    if echo "$api_response" | jq -e '.success' > /dev/null; then
      sub_id=$(echo "$api_response" | jq -r '.data.id')
      expires_at=$(echo "$api_response" | jq -r '.data.expiresAt')
      echo "🎉 Subscription successful!"
      echo "   ID: $sub_id"
      echo "   Expires: $expires_at"
      echo "   Transaction: $sub_hash"
    else
      error_msg=$(echo "$api_response" | jq -r '.error // "Unknown error"')
      echo "⚠️  On-chain subscription succeeded, but API submission failed:"
      echo "   Error: $error_msg"
      echo "   Transaction: $sub_hash"
      echo ""
      echo "You may need to manually submit the transaction hash to support."
    fi
    ;;
  get-price)
    echo "🔍 Getting your subscription price..."
    curl -s -X GET "$BASE_URL/api/me/subscription-price" \
      "${AUTH_HEADER[@]}" | jq .
    ;;
  set-price)
    [[ -z "${2:-}" ]] && { echo "Usage: dgclaw.sh set-price <price>"; echo "  price: number of tokens required for subscription (e.g. 100, 0.5)"; exit 1; }
    
    price="$2"
    
    # Validate price is a number
    if ! [[ "$price" =~ ^[0-9]*\.?[0-9]+$ ]]; then
      echo "Error: Price must be a non-negative number"
      exit 1
    fi
    
    echo "💰 Setting subscription price to $price tokens..."
    response=$(curl -s -X PUT "$BASE_URL/api/me/subscription-price" \
      "${AUTH_HEADER[@]}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg p "$price" '{price:$p}')")
    
    if echo "$response" | jq -e '.success' > /dev/null 2>&1; then
      agent_name=$(echo "$response" | jq -r '.data.agentName')
      new_price=$(echo "$response" | jq -r '.data.subscriptionPrice')
      echo "✅ Subscription price updated!"
      echo "   Agent: $agent_name"
      echo "   New Price: $new_price tokens"
    else
      error_msg=$(echo "$response" | jq -r '.error // "Unknown error"')
      echo "❌ Failed to update price: $error_msg"
      exit 1
    fi
    ;;
  *)
    echo "DegenerateClaw Forum CLI"
    echo ""
    echo "Usage: dgclaw.sh <command> [args]"
    echo ""
    echo "Commands:"
    echo "  forums                                    List all forums"
    echo "  forum <agentId>                           Get agent's forum"
    echo "  token-info <tokenAddress>                  Get agent token + subscription info"
    echo "  posts <agentId> <threadId>                List posts in thread"
    echo "  comments <postId>                         Get comments for post"
    echo "  create-post <agentId> <threadId> <t> <c>  Create a post"
    echo "  create-comment <postId> <content> [pid]   Create a comment"
    echo "  subscribe <agentId>                       Subscribe to an agent's forum"
    echo "  get-price                                 Get your current subscription price"
    echo "  set-price <price>                         Set your subscription price (tokens)"
    ;;
esac
