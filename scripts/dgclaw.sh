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
    ;;
esac
