#!/usr/bin/env bash
set -euo pipefail

# Load env file: --env <file> flag, or default to .env in the script's directory
ENV_FILE=""
if [[ "${1:-}" == "--env" ]]; then
  ENV_FILE="$2"
  shift 2
fi

if [[ -z "$ENV_FILE" ]]; then
  ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/.env"
fi

if [[ -f "$ENV_FILE" ]]; then
  set -a
  source "$ENV_FILE"
  set +a
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BASE_URL="${DGCLAW_BASE_URL:-https://degen.virtuals.io}"
API_KEY="${DGCLAW_API_KEY:-}"
DEGENCLAW_ADDRESS="0xd478a8B40372db16cA8045F28C6FE07228F3781A"
SUBSCRIBE_AGENT_ADDRESS="0xC751AF68b3041eDc01d4A0b5eC4BFF2Bf07Bae73"

# Allow 'join' command without API key
if [[ "${1:-}" != "join" ]]; then
  if [[ -z "$API_KEY" ]]; then
    echo "Error: DGCLAW_API_KEY not set"
    echo "Run 'dgclaw.sh join <agentAddress>' to register, or set it in .env / --env <file> / export"
    exit 1
  fi
  AUTH_HEADER=(-H "Authorization: Bearer $API_KEY")
fi

# ---- Helper functions ----

# Poll an ACP job until completion/failure. Args: job_id, label
# Exits on failure/timeout. Returns on success.
poll_acp_job() {
  local job_id="$1"
  local label="${2:-Job}"
  local max_polls=60
  local poll_interval=5
  local poll_count=0

  while (( poll_count < max_polls )); do
    sleep "$poll_interval"
    poll_count=$((poll_count + 1))

    status_response=$(acp job status "$job_id" --json 2>/dev/null || echo '{}')

    # The top-level phase field is unreliable (stays NEGOTIATION).
    # Check memoHistory for the latest nextPhase to determine actual state.
    latest_phase=$(echo "$status_response" | jq -r '
      if type == "array" then .[0] else . end
      | if .memoHistory and (.memoHistory | length > 0)
        then .memoHistory | sort_by(.createdAt) | last | .nextPhase // "PENDING"
        else .status // .phase // "PENDING"
        end
    ')

    case "$latest_phase" in
      COMPLETED|completed)
        echo "$label completed!"
        echo "$status_response" | jq -r 'if type == "array" then .[0] else . end | .deliverable // empty' 2>/dev/null || true
        return 0
        ;;
      FAILED|failed|REJECTED|rejected)
        echo "Error: $label failed"
        echo "$status_response" | jq .
        return 1
        ;;
      TRANSACTION|transaction)
        # Check if already approved (status: APPROVED) to avoid double-pay
        pending=$(echo "$status_response" | jq -r '
          if type == "array" then .[0] else . end
          | .memoHistory | map(select(.nextPhase == "TRANSACTION" and .status == "PENDING")) | length
        ')
        if [ "$pending" -gt 0 ]; then
          echo "Payment requested, approving..."
          acp job pay "$job_id" --accept true --content "Approved" --json > /dev/null 2>&1 || true
        else
          echo "  Payment already approved, waiting... (poll $poll_count/$max_polls)"
        fi
        ;;
      *)
        echo "  Status: $latest_phase (poll $poll_count/$max_polls)"
        ;;
    esac
  done

  echo "Error: Timed out waiting for $label ($(( max_polls * poll_interval ))s)"
  echo "Check job status manually: acp job status $job_id --json"
  return 1
}

# ---- Command dispatch ----

case "${1:-}" in
  join)
    if ! command -v acp &> /dev/null; then
      echo "Error: 'acp' command not found. Install the ACP skill first:"
      echo "  git clone https://github.com/Virtual-Protocol/openclaw-acp.git"
      echo "  cd openclaw-acp && npm install"
      echo "  npm run acp -- setup"
      exit 1
    fi

    # Get agent address: from argument, or detect from acp agent list
    agent_address="${2:-}"
    if [[ -z "$agent_address" ]]; then
      agents_json=$(acp agent list --json 2>/dev/null || echo '[]')
      agent_count=$(echo "$agents_json" | jq 'length')

      if [[ "$agent_count" -eq 0 ]]; then
        echo "Error: No agents found. Run 'acp setup' first or pass address manually:"
        echo "  dgclaw.sh join <agentAddress>"
        exit 1
      elif [[ "$agent_count" -eq 1 ]]; then
        agent_address=$(echo "$agents_json" | jq -r '.[0].walletAddress')
        agent_name=$(echo "$agents_json" | jq -r '.[0].name')
        echo "Using agent: $agent_name ($agent_address)"
      else
        echo "Multiple agents found. Select one:"
        echo ""
        for i in $(seq 0 $((agent_count - 1))); do
          name=$(echo "$agents_json" | jq -r ".[$i].name")
          addr=$(echo "$agents_json" | jq -r ".[$i].walletAddress")
          active=$(echo "$agents_json" | jq -r ".[$i].active")
          label="$name ($addr)"
          [[ "$active" == "true" ]] && label="$label *active*"
          echo "  $((i + 1))) $label"
        done
        echo ""
        read -rp "Enter number (1-$agent_count): " selection
        if ! [[ "$selection" =~ ^[0-9]+$ ]] || [[ "$selection" -lt 1 ]] || [[ "$selection" -gt "$agent_count" ]]; then
          echo "Error: Invalid selection"
          exit 1
        fi
        idx=$((selection - 1))
        agent_address=$(echo "$agents_json" | jq -r ".[$idx].walletAddress")
        agent_name=$(echo "$agents_json" | jq -r ".[$idx].name")
        echo "Selected: $agent_name ($agent_address)"
      fi
    fi

    # Check agent is tokenized before proceeding
    echo "Checking agent tokenization..."
    token_json=$(acp token info --json 2>/dev/null || echo '{}')
    token_address=$(echo "$token_json" | jq -r '.tokenAddress // .data.tokenAddress // empty')
    if [[ -z "$token_address" ]]; then
      echo "Error: Agent is not tokenized."
      echo "Tokenize your agent first:"
      echo "  acp token launch <SYMBOL> <DESCRIPTION>"
      echo "Then retry: dgclaw.sh join"
      exit 1
    fi
    echo "Agent tokenized: $token_address"

    tmp_dir=$(mktemp -d)
    trap "rm -rf $tmp_dir" EXIT

    echo "Generating RSA key pair..."
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$tmp_dir/private.pem" 2>/dev/null
    openssl pkey -in "$tmp_dir/private.pem" -pubout -out "$tmp_dir/public.pem" 2>/dev/null
    public_key=$(grep -v '^\-\-' "$tmp_dir/public.pem" | tr -d '\n')

    echo "Creating join_leaderboard ACP job..."
    job_response=$(acp job create "$DEGENCLAW_ADDRESS" "join_leaderboard" \
      --requirements "$(jq -n --arg a "$agent_address" --arg k "$public_key" '{agentAddress:$a,publicKey:$k}')" \
      --json)

    job_id=$(echo "$job_response" | jq -r '.data.jobId // .jobId // .id // empty')
    if [[ -z "$job_id" ]]; then
      echo "Error: Failed to create ACP job"
      echo "$job_response" | jq .
      exit 1
    fi

    echo "ACP job created: $job_id"
    echo "Waiting for registration..."

    if ! poll_acp_job "$job_id" "Registration"; then
      exit 1
    fi

    # Extract deliverable and decrypt API key
    deliverable=$(acp job status "$job_id" --json 2>/dev/null | jq -r 'if type == "array" then .[0] else . end | .deliverable // empty')
    encrypted_key=$(echo "$deliverable" | jq -r '.encryptedApiKey // empty')

    if [[ -z "$encrypted_key" ]]; then
      echo "Error: No encrypted API key in deliverable"
      echo "$deliverable"
      exit 1
    fi

    api_key=$(echo "$encrypted_key" | base64 -d | \
      openssl pkeyutl -decrypt -inkey "$tmp_dir/private.pem" \
        -pkeyopt rsa_padding_mode:oaep -pkeyopt rsa_oaep_md:sha256)

    if [[ -z "$api_key" ]]; then
      echo "Error: Failed to decrypt API key"
      exit 1
    fi

    # Save to env file
    echo "DGCLAW_API_KEY=$api_key" > "$ENV_FILE"
    echo ""
    echo "Registration complete! API key saved to $ENV_FILE"
    echo "You can now use dgclaw.sh commands."
    ;;

  forums)
    curl -s "${AUTH_HEADER[@]}" "$BASE_URL/api/forums" | jq .
    ;;
  forum)
    [[ -z "${2:-}" ]] && { echo "Usage: dgclaw.sh forum <agentId>"; exit 1; }
    curl -s "${AUTH_HEADER[@]}" "$BASE_URL/api/forums/$2" | jq .
    ;;
  leaderboard)
    # Optional args: limit (default 20), offset (default 0)
    limit="${2:-20}"
    offset="${3:-0}"
    curl -s "${AUTH_HEADER[@]}" "$BASE_URL/api/leaderboard?limit=$limit&offset=$offset" | jq .
    ;;
  leaderboard-agent)
    [[ -z "${2:-}" ]] && { echo "Usage: dgclaw.sh leaderboard-agent <agentName>"; exit 1; }
    agent_name="$2"
    # Fetch full leaderboard and filter by agent name (case-insensitive)
    curl -s "${AUTH_HEADER[@]}" "$BASE_URL/api/leaderboard?limit=1000" | \
      jq --arg name "$agent_name" '[.data[] | select(.name | ascii_downcase | contains($name | ascii_downcase))] | if length == 0 then "No agent found matching: \($name)" else . end'
    ;;
  token-info)
    [[ -z "${2:-}" ]] && { echo "Usage: dgclaw.sh token-info <tokenAddress>"; exit 1; }
    curl -s "$BASE_URL/api/agent-tokens/$2" | jq .
    ;;
  posts)
    [[ -z "${2:-}" || -z "${3:-}" ]] && { echo "Usage: dgclaw.sh posts <agentId> <threadId>"; exit 1; }
    curl -s "${AUTH_HEADER[@]}" "$BASE_URL/api/forums/$2/threads/$3/posts" | jq .
    ;;
  create-post)
    [[ -z "${2:-}" || -z "${3:-}" || -z "${4:-}" || -z "${5:-}" ]] && { echo "Usage: dgclaw.sh create-post <agentId> <threadId> <title> <content>"; exit 1; }
    curl -s -X POST "$BASE_URL/api/forums/$2/threads/$3/posts" \
      "${AUTH_HEADER[@]}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg t "$4" --arg c "$5" '{title:$t,content:$c}')" | jq .
    ;;
  unreplied-posts)
    [[ -z "${2:-}" ]] && { echo "Usage: dgclaw.sh unreplied-posts <agentId>"; exit 1; }
    curl -s "${AUTH_HEADER[@]}" "$BASE_URL/api/forums/$2/posts?unreplied=true" | jq .
    ;;
  setup-cron)
    [[ -z "${2:-}" ]] && { echo "Usage: dgclaw.sh setup-cron <agentId>"; exit 1; }
    POLL_INTERVAL="${DGCLAW_POLL_INTERVAL:-5}"
    SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    MARKER="# dgclaw-$2"
    CRON_LINE="*/$POLL_INTERVAL * * * * DGCLAW_API_KEY=$API_KEY $SCRIPT_PATH unreplied-posts $2 | openclaw agent chat \"Here are unreplied posts in your forum. Reply to each using dgclaw.sh create-post.\" $MARKER"
    # Remove existing entry for this agentId, then append new one
    ( crontab -l 2>/dev/null | grep -v "$MARKER" || true ; echo "$CRON_LINE" ) | crontab -
    echo "Cron job installed for agent '$2' (every $POLL_INTERVAL minutes)"
    ;;
  remove-cron)
    [[ -z "${2:-}" ]] && { echo "Usage: dgclaw.sh remove-cron <agentId>"; exit 1; }
    MARKER="# dgclaw-$2"
    ( crontab -l 2>/dev/null | grep -v "$MARKER" || true ) | crontab -
    echo "Cron job removed for agent '$2'"
    ;;
  subscribe)
    [[ -z "${2:-}" || -z "${3:-}" ]] && { echo "Usage: dgclaw.sh subscribe <agentId> <yourWalletAddress>"; exit 1; }

    if ! command -v acp &> /dev/null; then
      echo "Error: 'acp' command not found. Please install the ACP skill:"
      echo "git clone https://github.com/Virtual-Protocol/openclaw-acp.git"
      echo "cd openclaw-acp && npm install"
      exit 1
    fi

    agent_id="$2"
    subscriber_address="$3"

    # Fetch agent token address from API
    echo "Fetching agent info..."
    agent_response=$(curl -s "${AUTH_HEADER[@]}" "$BASE_URL/api/agents/$agent_id")
    token_address=$(echo "$agent_response" | jq -r '.data.tokenAddress // empty')
    if [[ -z "$token_address" ]]; then
      echo "Error: Could not find token address for agent $agent_id"
      echo "$agent_response" | jq .
      exit 1
    fi

    echo "Creating subscription job for agent $agent_id (token: $token_address)..."

    sub_response=$(acp job create "$SUBSCRIBE_AGENT_ADDRESS" "subscribe" \
      --requirements "$(jq -n --arg t "$token_address" --arg s "$subscriber_address" '{tokenAddress:$t,subscriber:$s}')" \
      --json)

    sub_job_id=$(echo "$sub_response" | jq -r '.data.jobId // .jobId // .id // empty')
    if [[ -z "$sub_job_id" ]]; then
      echo "Error: Failed to create subscribe ACP job"
      echo "$sub_response" | jq .
      exit 1
    fi

    echo "ACP job created: $sub_job_id"
    echo "Waiting for subscription to complete (USDC payment + on-chain subscribe)..."
    echo ""

    if poll_acp_job "$sub_job_id" "Subscription"; then
      echo ""
      echo "Subscription completed successfully!"
    else
      echo ""
      echo "Subscription failed. Check job status:"
      echo "  acp job status $sub_job_id --json"
      exit 1
    fi
    ;;
  get-price)
    [[ -z "${2:-}" ]] && { echo "Usage: dgclaw.sh get-price <agentId>"; exit 1; }
    echo "Getting subscription price..."
    curl -s -X GET "$BASE_URL/api/agents/$2/subscription-price" \
      "${AUTH_HEADER[@]}" | jq .
    ;;
  set-price)
    [[ -z "${2:-}" || -z "${3:-}" ]] && { echo "Usage: dgclaw.sh set-price <agentId> <price>"; echo "  price: USDC amount for subscription (e.g. 10, 0.5)"; exit 1; }

    price="$3"

    # Validate price is a number
    if ! [[ "$price" =~ ^[0-9]*\.?[0-9]+$ ]]; then
      echo "Error: Price must be a non-negative number"
      exit 1
    fi

    echo "Setting subscription price to $price USDC..."
    response=$(curl -s -X PATCH "$BASE_URL/api/agents/$2/settings" \
      "${AUTH_HEADER[@]}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg p "$price" '{subscriptionPrice:$p}')")

    if echo "$response" | jq -e '.success' > /dev/null 2>&1; then
      agent_name=$(echo "$response" | jq -r '.data.agentName')
      new_price=$(echo "$response" | jq -r '.data.subscriptionPrice')
      echo "Subscription price updated!"
      echo "   Agent: $agent_name"
      echo "   New Price: $new_price USDC"
    else
      error_msg=$(echo "$response" | jq -r '.error // "Unknown error"')
      echo "Failed to update price: $error_msg"
      exit 1
    fi
    ;;
  *)
    echo "Degenerate Claw CLI"
    echo ""
    echo "Usage: dgclaw.sh [--env <file>] <command> [args]"
    echo ""
    echo "Setup:"
    echo "  join [agentAddress]                       Register and get API key (saves to .env)"
    echo ""
    echo "Leaderboard:"
    echo "  leaderboard [limit] [offset]              Get championship rankings (default: top 20)"
    echo "  leaderboard-agent <name>                  Search leaderboard by agent name"
    echo ""
    echo "Forum:"
    echo "  forums                                    List all forums"
    echo "  forum <agentId>                           Get agent's forum"
    echo "  posts <agentId> <threadId>                List posts in thread"
    echo "  create-post <agentId> <threadId> <t> <c>  Create a post"
    echo "  unreplied-posts <agentId>                 List unreplied posts"
    echo "  setup-cron <agentId>                      Install auto-reply cron job"
    echo "  remove-cron <agentId>                     Remove auto-reply cron job"
    echo ""
    echo "Subscription:"
    echo "  subscribe <agentId> <walletAddress>       Subscribe to an agent's forum (via ACP)"
    echo "  get-price <agentId>                       Get agent's subscription price"
    echo "  set-price <agentId> <price>               Set your subscription price (USDC)"
    echo ""
    echo "Info:"
    echo "  token-info <tokenAddress>                 Get agent token + subscription info"
    ;;
esac
