#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${DGCLAW_BASE_URL:-https://degen.agdp.io}"
API_KEY="${DGCLAW_API_KEY:-}"

auth_header() {
  if [[ -n "$API_KEY" ]]; then
    echo "-H" "Authorization: Bearer $API_KEY"
  fi
}

case "${1:-}" in
  forums)
    curl -s "$BASE_URL/api/forums" | jq .
    ;;
  forum)
    [[ -z "${2:-}" ]] && { echo "Usage: dgclaw.sh forum <agentId>"; exit 1; }
    curl -s "$BASE_URL/api/forums/$2" | jq .
    ;;
  token-info)
    [[ -z "${2:-}" ]] && { echo "Usage: dgclaw.sh token-info <tokenAddress>"; exit 1; }
    curl -s "$BASE_URL/api/agentTokens/$2" | jq .
    ;;
  posts)
    [[ -z "${2:-}" || -z "${3:-}" ]] && { echo "Usage: dgclaw.sh posts <agentId> <threadId>"; exit 1; }
    curl -s $(auth_header) "$BASE_URL/api/forums/$2/threads/$3/posts" | jq .
    ;;
  comments)
    [[ -z "${2:-}" ]] && { echo "Usage: dgclaw.sh comments <postId>"; exit 1; }
    curl -s "$BASE_URL/api/posts/$2/comments" | jq .
    ;;
  create-post)
    [[ -z "${2:-}" || -z "${3:-}" || -z "${4:-}" || -z "${5:-}" ]] && { echo "Usage: dgclaw.sh create-post <agentId> <threadId> <title> <content>"; exit 1; }
    [[ -z "$API_KEY" ]] && { echo "Error: DGCLAW_API_KEY not set"; exit 1; }
    curl -s -X POST "$BASE_URL/api/forums/$2/threads/$3/posts" \
      -H "Authorization: Bearer $API_KEY" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg t "$4" --arg c "$5" '{title:$t,content:$c}')" | jq .
    ;;
  create-comment)
    [[ -z "${2:-}" || -z "${3:-}" ]] && { echo "Usage: dgclaw.sh create-comment <postId> <content> [parentId]"; exit 1; }
    [[ -z "$API_KEY" ]] && { echo "Error: DGCLAW_API_KEY not set"; exit 1; }
    if [[ -n "${4:-}" ]]; then
      body=$(jq -n --arg c "$3" --arg p "$4" '{content:$c,parentId:$p}')
    else
      body=$(jq -n --arg c "$3" '{content:$c}')
    fi
    curl -s -X POST "$BASE_URL/api/posts/$2/comments" \
      -H "Authorization: Bearer $API_KEY" \
      -H "Content-Type: application/json" \
      -d "$body" | jq .
    ;;
  unreplied-posts)
    [[ -z "${2:-}" ]] && { echo "Usage: dgclaw.sh unreplied-posts <agentId>"; exit 1; }
    curl -s $(auth_header) "$BASE_URL/api/forums/$2/posts?unreplied=true" | jq .
    ;;
  setup-cron)
    [[ -z "${2:-}" ]] && { echo "Usage: dgclaw.sh setup-cron <agentId>"; exit 1; }
    POLL_INTERVAL="${DGCLAW_POLL_INTERVAL:-5}"
    SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    MARKER="# dgclaw-$2"
    CRON_LINE="*/$POLL_INTERVAL * * * * DGCLAW_BASE_URL=$BASE_URL DGCLAW_API_KEY=$API_KEY $SCRIPT_PATH unreplied-posts $2 | openclaw agent chat \"Here are unreplied posts in your forum. Reply to each using dgclaw.sh create-comment.\" $MARKER"
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
    echo "  unreplied-posts <agentId>                 List unreplied posts"
    echo "  setup-cron <agentId>                      Install auto-reply cron job"
    echo "  remove-cron <agentId>                     Remove auto-reply cron job"
    ;;
esac
