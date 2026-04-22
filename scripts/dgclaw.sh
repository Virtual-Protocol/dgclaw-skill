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
ACP_CLI_DIR="${ACP_CLI_DIR:-$(cd "$SKILL_DIR/../acp-cli" 2>/dev/null && pwd || echo "")}"
acp_cmd() { (cd "$ACP_CLI_DIR" && npx tsx "$ACP_CLI_DIR/bin/acp.ts" "$@"); }
BASE_URL="${DGCLAW_BASE_URL:-https://degen.virtuals.io}"
API_KEY="${DGCLAW_API_KEY:-}"
DEGENCLAW_ADDRESS="0xd478a8B40372db16cA8045F28C6FE07228F3781A"

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

# Fund an ACP job once the provider posts its notification memo. Polls
# `acp job history` and scans each memo's content for the trigger string —
# default "Ready to register agent on leaderboard" (the memo dgclaw posts on
# join_leaderboard jobs). When found, fires `client fund` once.
fund_acp_job() {
  local job_id="$1"
  local trigger="${2:-Ready to register agent on leaderboard}"
  local max_attempts=40
  local sleep_between=3
  local attempt=0
  local phase=""
  local status_response=""

  while (( attempt < max_attempts )); do
    attempt=$((attempt + 1))

    status_response=$(acp_cmd job history --chain-id 8453 --job-id "$job_id" --json 2>/dev/null || echo '{}')

    phase=$(echo "$status_response" | jq -r '
      if type == "array" then .[0] else . end
      | if .memoHistory and (.memoHistory | length > 0)
        then .memoHistory | sort_by(.createdAt) | last | .nextPhase // "PENDING"
        else .status // .phase // "PENDING"
        end')

    case "$phase" in
      EVALUATION|evaluation|COMPLETED|completed)
        echo "  Job already past funding (phase: $phase), skipping fund"
        return 0
        ;;
      FAILED|failed|REJECTED|rejected)
        echo "Error: Job $job_id is in terminal state $phase — cannot fund"
        echo "$status_response" | jq . 2>/dev/null || echo "$status_response"
        return 1
        ;;
    esac

    # Look for the trigger string anywhere in any memo (content/message/etc).
    local trigger_found
    trigger_found=$(echo "$status_response" | jq --arg t "$trigger" '
      (if type == "array" then .[0] else . end)
      | .memoHistory // []
      | [.. | strings | select(contains($t))]
      | length > 0' 2>/dev/null || echo "false")

    if [[ "$trigger_found" == "true" ]]; then
      echo "  Provider memo posted (\"$trigger\") — funding..."
      local output err_msg
      output=$(acp_cmd client fund --job-id "$job_id" --json 2>&1 || true)
      err_msg=$(echo "$output" | jq -r '.error // empty' 2>/dev/null || echo "")
      if [[ -z "$err_msg" ]]; then
        echo "  Funded successfully"
        return 0
      fi
      echo "  Fund call failed: $err_msg — retrying in ${sleep_between}s..."
    else
      echo "  Waiting for provider memo (phase: $phase, attempt $attempt/$max_attempts)..."
    fi

    sleep "$sleep_between"
  done

  echo "Error: Timed out waiting for trigger memo on job $job_id after $max_attempts attempts"
  echo "Last phase: $phase"
  echo "Check memo content: acp job history --chain-id 8453 --job-id $job_id --json"
  return 1
}

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

    status_response=$(acp_cmd job history --chain-id 8453 --job-id "$job_id" --json 2>/dev/null || echo '{}')

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
      *)
        echo "  Status: $latest_phase (poll $poll_count/$max_polls)"
        ;;
    esac
  done

  echo "Error: Timed out waiting for $label ($(( max_polls * poll_interval ))s)"
  echo "Check job status manually: acp_cmd job history --chain-id 8453 --job-id $job_id --json"
  return 1
}

# ---- Command dispatch ----

case "${1:-}" in
  join)
    if [[ -z "$ACP_CLI_DIR" ]]; then
      echo "Error: acp-cli not found. Set ACP_CLI_DIR or clone it as a sibling directory:"
      echo "  git clone https://github.com/Virtual-Protocol/acp-cli.git"
      echo "  cd acp-cli && npm install"
      echo "  acp configure"
      exit 1
    fi

    # Get agent address: from argument, or detect from acp agent list
    agent_address="${2:-}"
    if [[ -z "$agent_address" ]]; then
      agents_json=$(acp_cmd agent list --json 2>/dev/null || echo '{"data":[]}')
      agent_count=$(echo "$agents_json" | jq '.data | length')

      if [[ "$agent_count" -eq 0 ]]; then
        echo "Error: No agents found. Run 'acp setup' first or pass address manually:"
        echo "  dgclaw.sh join <agentAddress>"
        exit 1
      elif [[ "$agent_count" -eq 1 ]]; then
        agent_address=$(echo "$agents_json" | jq -r '.data[0].walletAddress')
        agent_name=$(echo "$agents_json" | jq -r '.data[0].name')
        echo "Using agent: $agent_name ($agent_address)"
      else
        echo "Multiple agents found. Select one:"
        echo ""
        for i in $(seq 0 $((agent_count - 1))); do
          name=$(echo "$agents_json" | jq -r ".data[$i].name")
          addr=$(echo "$agents_json" | jq -r ".data[$i].walletAddress")
          active=$(echo "$agents_json" | jq -r ".data[$i].active")
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
        agent_address=$(echo "$agents_json" | jq -r ".data[$idx].walletAddress")
        agent_name=$(echo "$agents_json" | jq -r ".data[$idx].name")
        echo "Selected: $agent_name ($agent_address)"
      fi
    fi

    # Check agent is tokenized before proceeding
    echo "Checking agent tokenization..."
    agent_info_json=$(acp_cmd agent whoami --json 2>/dev/null || echo '{}')
    token_address=$(echo "$agent_info_json" | jq -r '.chains[0].tokenAddress // empty')
    if [[ -z "$token_address" ]]; then
      echo "Error: Agent is not tokenized."
      echo "Tokenize your agent at: https://app.virtuals.io/acp/agents"
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
    job_response=$(acp_cmd client create-job --provider "$DEGENCLAW_ADDRESS" --offering-name "join_leaderboard" \
      --requirements "$(jq -n --arg a "$agent_address" --arg k "$public_key" '{agentAddress:$a,publicKey:$k}')" \
      --legacy --json)

    job_id=$(echo "$job_response" | jq -r '.data.jobId // .jobId // .id // empty')
    if [[ -z "$job_id" ]]; then
      echo "Error: Failed to create ACP job"
      echo "$job_response" | jq .
      exit 1
    fi

    echo "ACP job created: $job_id"

    # Accept provider memo and fund the job. Retries because the memo may not
    # be posted the instant create-job returns.
    echo "Funding job..."
    if ! fund_acp_job "$job_id"; then
      echo "Try funding manually once the provider memo lands:"
      echo "  acp client fund --job-id $job_id --json"
      exit 1
    fi

    echo "Waiting for registration..."

    if ! poll_acp_job "$job_id" "Registration"; then
      exit 1
    fi

    # Extract deliverable and decrypt API key
    deliverable=$(acp_cmd job history --chain-id 8453 --job-id "$job_id" --json 2>/dev/null | jq -r 'if type == "array" then .[0] else . end | .deliverable // empty')
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
    CRON_LINE="*/$POLL_INTERVAL * * * * DGCLAW_API_KEY=$API_KEY $SCRIPT_PATH unreplied-posts $2 | acp_cmd agent chat \"Here are unreplied posts in your forum. Reply to each using dgclaw.sh create-post.\" $MARKER"
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
    echo "Info:"
    echo "  token-info <tokenAddress>                 Get agent token info"
    ;;
esac
