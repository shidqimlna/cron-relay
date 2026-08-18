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
# well above current pool sizes). Writes the combined, trimmed item list
# (number/title/html_url only) to $1. Uses temp files + --slurpfile
# throughout instead of --argjson on large blobs, since passing a big
# JSON array as a command-line argument can exceed the OS arg-length
# limit ("Argument list too long").
api_search_all() {
  local query="$1"
  local out_file="$2"
  local tmpdir
  tmpdir=$(mktemp -d)
  echo '[]' > "$tmpdir/combined.json"

  local page=1
  while true; do
    local pagefile="$tmpdir/page.json"
    api_search_page "$query" "$page" > "$pagefile"

    if ! jq -e '.items' "$pagefile" > /dev/null 2>&1; then
      echo "null" > "$out_file"
      rm -rf "$tmpdir"
      return
    fi

    jq '[.items[] | {number, title, html_url}]' "$pagefile" > "$tmpdir/items.json"
    jq -s '.[0] + .[1]' "$tmpdir/combined.json" "$tmpdir/items.json" > "$tmpdir/combined_new.json"
    mv "$tmpdir/combined_new.json" "$tmpdir/combined.json"

    local page_count
    page_count=$(jq 'length' "$tmpdir/items.json")

    if [ "$page_count" -lt 100 ] || [ "$page" -ge 5 ]; then
      break
    fi
    page=$((page + 1))
  done

  mv "$tmpdir/combined.json" "$out_file"
  rm -rf "$tmpdir"
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

  local items_file
  items_file=$(mktemp)
  api_search_all "$query" "$items_file"

  if [ "$(cat "$items_file")" = "null" ]; then
    echo "WARN: bad response for $key, skipping"
    rm -f "$items_file"
    return
  fi

  local initialized
  initialized=$(jq -r '.initialized' "$STATE_FILE")

  local current_numbers_file
  current_numbers_file=$(mktemp)
  jq '[.[].number]' "$items_file" > "$current_numbers_file"

  if [ "$initialized" = "false" ]; then
    jq --slurpfile nums "$current_numbers_file" ".${key} = \$nums[0]" "$STATE_FILE" > tmp_state.json && mv tmp_state.json "$STATE_FILE"
    echo "Seeded $key with $(jq 'length' "$current_numbers_file") existing issues (no notifications sent)"
    rm -f "$items_file" "$current_numbers_file"
    return
  fi

  local seen_numbers_file
  seen_numbers_file=$(mktemp)
  jq -c ".${key}" "$STATE_FILE" > "$seen_numbers_file"

  local new_items_file
  new_items_file=$(mktemp)
  jq --slurpfile seen "$seen_numbers_file" '[.[] | select(([.number] - $seen[0]) | length > 0)]' "$items_file" > "$new_items_file"

  local count
  count=$(jq 'length' "$new_items_file")

  if [ "$count" -gt 0 ]; then
    jq -c '.[]' "$new_items_file" | while read -r item; do
      number=$(echo "$item" | jq -r '.number')
      title=$(echo "$item" | jq -r '.title')
      url=$(echo "$item" | jq -r '.html_url')
      post_discord "${label_emoji} #${number}: ${title}
${url}"
    done
  fi

  local merged_file
  merged_file=$(mktemp)
  jq -s '(.[0] + .[1]) | unique | sort | .[-2000:]' "$seen_numbers_file" "$current_numbers_file" > "$merged_file"
  jq --slurpfile nums "$merged_file" ".${key} = \$nums[0]" "$STATE_FILE" > tmp_state.json && mv tmp_state.json "$STATE_FILE"

  rm -f "$items_file" "$current_numbers_file" "$seen_numbers_file" "$new_items_file" "$merged_file"
}

process_category "help_wanted" 'repo:Expensify/App is:open is:issue label:"Help Wanted"' "🟢 [Help Wanted]"
process_category "external" 'repo:Expensify/App is:open is:issue label:External -label:"Help Wanted"' "🔵 [External]"

jq '.initialized = true' "$STATE_FILE" > tmp_state.json && mv tmp_state.json "$STATE_FILE"
