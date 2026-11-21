#!/usr/bin/env bash
#
# Send a notification to Microsoft Teams or Discord.
# Payloads are built with jq, so quotes and newlines in messages are safe.
#
# Usage: send_webhook.sh --type teams|discord --url URL --message TEXT [--title TEXT]
#
# Teams: legacy Office 365 connector URLs (*.webhook.office.com) get a
# MessageCard; anything else (Teams Workflows / Power Automate) gets an
# Adaptive Card.

set -uo pipefail

TYPE="" URL="" MESSAGE="" TITLE=""

usage() { sed -n '3,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
  --type) TYPE="${2:-}"; shift 2 ;;
  --url) URL="${2:-}"; shift 2 ;;
  --message) MESSAGE="${2:-}"; shift 2 ;;
  --title) TITLE="${2:-}"; shift 2 ;;
  -h | --help) usage; exit 0 ;;
  *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$TYPE" || -z "$URL" || -z "$MESSAGE" ]]; then
  echo "Error: --type, --url and --message are required" >&2
  usage >&2
  exit 2
fi
command -v jq >/dev/null || { echo "Error: jq is required" >&2; exit 1; }

case "$TYPE" in
discord)
  # Discord content limit is 2000 characters
  PAYLOAD=$(jq -n --arg t "$TITLE" --arg m "$MESSAGE" \
    '{username: "OPNsense Backup",
      content: ((if $t != "" then "**\($t)**\n" else "" end) + $m)[0:2000]}')
  ;;
teams)
  if [[ "$URL" == *.webhook.office.com/* ]]; then
    PAYLOAD=$(jq -n --arg t "$TITLE" --arg m "$MESSAGE" \
      '{"@type": "MessageCard", "@context": "http://schema.org/extensions",
        summary: (if $t != "" then $t else "OPNsense Backup" end),
        themeColor: (if ($t | test("FAIL"; "i")) then "D13438" else "2EB886" end),
        title: $t,
        text: ($m | gsub("\n"; "<br>"))}')
  else
    PAYLOAD=$(jq -n --arg t "$TITLE" --arg m "$MESSAGE" \
      '{type: "message",
        attachments: [{
          contentType: "application/vnd.microsoft.card.adaptive",
          content: {
            "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
            type: "AdaptiveCard", version: "1.4",
            body: ([if $t != "" then {type: "TextBlock", text: $t, weight: "Bolder", size: "Medium", wrap: true} else empty end]
                   + [{type: "TextBlock", text: $m, wrap: true}])
          }}]}')
  fi
  ;;
*)
  echo "Error: --type must be 'teams' or 'discord'" >&2
  exit 2
  ;;
esac

# URL is passed via a curl config on stdin so it stays out of the process list.
HTTP_STATUS=$(
  printf 'url = "%s"\n' "$URL" |
    curl --config - --silent --output /dev/null --write-out '%{http_code}' \
      --max-time 30 --header 'Content-Type: application/json' \
      --data-binary @<(printf '%s' "$PAYLOAD")
)

if [[ "$HTTP_STATUS" =~ ^2[0-9][0-9]$ ]]; then
  echo "Webhook ($TYPE) sent (HTTP $HTTP_STATUS)"
else
  echo "Webhook ($TYPE) FAILED (HTTP ${HTTP_STATUS:-none})" >&2
  exit 1
fi
