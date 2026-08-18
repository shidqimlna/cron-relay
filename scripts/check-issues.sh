#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="state.json"
: "${DISCORD_WEBHOOK_URL:?missing}"
: "${GH_TOKEN:?missing}"

api_search_page() {
  local query="$1"
  local page="$2"
  curl -sS -G \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    --data-urlencode "q=$query" \
    --data-urlencode "sort=created" \
    --data-urlencode "order=desc" \
    --data-urlencode "per_page=100" \
    --data-urlencode "page=$page" \
    "https://api.github.com/search/issues"
}

# Paginates through all matching issues (capped at 5 pages / 500 items,
# well above current pool sizes) so issues beyond the first 100 results
# aren't silently dropped.
api_search() {
  local query="$1"
  local page=1
  local all_items="[]"
  local page_count

  while true; do
    local resp
    resp=$(api_search_page "$query" "$page")

    if ! echo "$resp" | jq -e '.items' > /dev/null 2>&1; then
      echo '{"items":null}'
      return
    fi

    all_items=$(jq -n --argjson a "$all_items" --argjson b "$(echo "$resp" | jq -c '.items')" '$a + $b')
    page_count=$(echo "$resp" | jq '.items | length')

    if [ "$page_count" -lt 100 ] || [ "$page" -ge 5 ]; then
      break
    fi
    page=$((page + 1))
  done

  jq -n --argjson items "$all_items" '{items: $items}'
}

post_discord() {
  local content="$1"
  local payload
  payload=$(jq -n --arg content "$content" '{content: $content}')
  curl -sS -H "Content-Type: application/json" -X POST -d "$payload" "$DISCORD_WEBHOOK_URL" > /dev/null
  sleep 1
}

process_category() {
  local key="$1"
  local query="$2"
  local label_emoji="$3"

  local response
  response=$(api_search "$query")

  if ! echo "$response" | jq -e '.items' > /dev/null 2>&1; then
    echo "WARN: bad response for $key, skipping"
    return
  fi

  local initialized
  initialized=$(jq -r '.initialized' "$STATE_FILE")

  local current_numbers
  current_numbers=$(echo "$response" | jq '[.items[].number]')

  local seen_numbers
  seen_numbers=$(jq -c ".${key}" "$STATE_FILE")

  if [ "$initialized" = "false" ]; then
    jq --argjson nums "$current_numbers" ".${key} = \$nums" "$STATE_FILE" > tmp.json && mv tmp.json "$STATE_FILE"
    echo "Seeded $key with $(echo "$current_numbers" | jq 'length') existing issues (no notifications sent)"
    return
  fi

  local new_items
  new_items=$(echo "$response" | jq --argjson seen "$seen_numbers" '[.items[] | select(([.number] - $seen) | length > 0)]')

  local count
  count=$(echo "$new_items" | jq 'length')

  if [ "$count" -gt 0 ]; then
    echo "$new_items" | jq -c '.[]' | while read -r item; do
      number=$(echo "$item" | jq -r '.number')
      title=$(echo "$item" | jq -r '.title')
      url=$(echo "$item" | jq -r '.html_url')
      post_discord "${label_emoji} #${number}: ${title}
${url}"
    done
  fi

  local merged
  merged=$(jq -n --argjson a "$seen_numbers" --argjson b "$current_numbers" '($a + $b) | unique | sort | .[-2000:]')
  jq --argjson nums "$merged" ".${key} = \$nums" "$STATE_FILE" > tmp.json && mv tmp.json "$STATE_FILE"
}

process_category "help_wanted" 'repo:Expensify/App is:open is:issue label:"Help Wanted"' "🟢 [Help Wanted]"
process_category "external" 'repo:Expensify/App is:open is:issue label:External -label:"Help Wanted"' "🔵 [External]"

jq '.initialized = true' "$STATE_FILE" > tmp.json && mv tmp.json "$STATE_FILE"
