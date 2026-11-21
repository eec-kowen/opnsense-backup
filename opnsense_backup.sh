#!/usr/bin/env bash
#
# OPNsense configuration backup over the REST API.
#
# For each firewall in OPNSENSE_LIST:
#   GET /api/core/backup/download/this  ->  config_<name>.xml
# The download is validated (HTTP 200, well-formed XML, <opnsense> root, no
# sudden shrink) before it replaces the previous copy, then changes are
# committed to git and pushed. Failures alert via Teams/Discord webhooks,
# de-duplicated so a dead firewall doesn't page every hour.
#
# Usage: opnsense_backup.sh [-n|--dry-run] [-h|--help]

set -uo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${OPNSENSE_BACKUP_ENV:-$SCRIPT_DIR/.env}"
DRY_RUN=false

usage() {
  sed -n '3,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Options:
  -n, --dry-run   Fetch and validate only; write nothing, commit nothing, send no alerts.
  -h, --help      Show this help.

Configuration is read from .env next to this script (override with OPNSENSE_BACKUP_ENV).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  -n | --dry-run) DRY_RUN=true ;;
  -h | --help) usage; exit 0 ;;
  *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: $ENV_FILE not found. Copy .env.example to .env and edit it." >&2
  exit 1
fi
set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

# Defaults for optional settings
: "${API_KEY_DIR:=$HOME/.config/opnsense-backup/keys}"
: "${STATE_DIR:=$HOME/.local/state/opnsense-backup}"
: "${CURL_CONNECT_TIMEOUT:=15}"
: "${CURL_MAX_TIME:=120}"
: "${MIN_SIZE_PERCENT:=50}"
: "${GIT_PUSH:=true}"
: "${GIT_COMMIT_PREFIX:=Automated OPNsense configuration backup}"
: "${WEBHOOK_NOTIFY_ERRORS_ONLY:=true}"
: "${WEBHOOK_REPEAT_HOURS:=24}"
: "${DISCORD_WEBHOOK_ENABLED:=false}"
: "${DISCORD_WEBHOOK_URL:=}"
: "${TEAMS_WEBHOOK_ENABLED:=false}"
: "${TEAMS_WEBHOOK_URL:=}"

# ---------------------------------------------------------------- helpers

log() {
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') - $*"
  if [[ "$DRY_RUN" == true ]]; then
    echo "$line"
  else
    echo "$line" >>"$LOG_FILE"
    [[ -t 1 ]] && echo "$line"
  fi
  return 0
}

die() {
  log "FATAL: $*"
  [[ -t 1 ]] || echo "FATAL: $*" >&2
  exit 1
}

notify() { # notify <title> <message>
  [[ "$DRY_RUN" == true ]] && { log "(dry run) would notify: $1 - $2"; return 0; }
  if [[ "$DISCORD_WEBHOOK_ENABLED" == true && -n "$DISCORD_WEBHOOK_URL" ]]; then
    "$SCRIPT_DIR/send_webhook.sh" --type discord --url "$DISCORD_WEBHOOK_URL" \
      --title "$1" --message "$2" >>"$LOG_FILE" 2>&1 || log "Discord webhook failed"
  fi
  if [[ "$TEAMS_WEBHOOK_ENABLED" == true && -n "$TEAMS_WEBHOOK_URL" ]]; then
    "$SCRIPT_DIR/send_webhook.sh" --type teams --url "$TEAMS_WEBHOOK_URL" \
      --title "$1" --message "$2" >>"$LOG_FILE" 2>&1 || log "Teams webhook failed"
  fi
}

# Alert de-duplication. State per key: "OK" or "FAIL <epoch of last alert>".
# Alerts on the first failure, again every WEBHOOK_REPEAT_HOURS while it keeps
# failing, and once when it recovers.
alert_state() { # alert_state <key> <OK|FAIL> <message>
  local key="$1" status="$2" msg="$3" file="$STATE_DIR/alert_$1"
  local prev="" prev_time=0 now
  now=$(date +%s)
  [[ -f "$file" ]] && read -r prev prev_time <"$file"
  [[ "$prev_time" =~ ^[0-9]+$ ]] || prev_time=0

  if [[ "$status" == FAIL ]]; then
    if [[ "$prev" != FAIL ]] || ((now - prev_time >= WEBHOOK_REPEAT_HOURS * 3600)); then
      notify "OPNsense backup FAILED: $key" "$msg"
      [[ "$DRY_RUN" == true ]] || echo "FAIL $now" >"$file"
    fi
  else
    if [[ "$prev" == FAIL ]]; then
      notify "OPNsense backup recovered: $key" "$msg"
    fi
    [[ "$DRY_RUN" == true ]] || echo "OK $now" >"$file"
  fi
}

validate_environment() {
  local var
  for var in BACKUP_DIR OPNSENSE_LIST LOG_FILE; do
    [[ -n "${!var:-}" ]] || die "Required variable $var is not set in $ENV_FILE"
  done
  for cmd in curl xmllint git flock; do
    command -v "$cmd" >/dev/null || die "Required command '$cmd' not found"
  done
  [[ -f "$OPNSENSE_LIST" ]] || die "OPNSENSE_LIST file not found: $OPNSENSE_LIST"
  [[ "$MIN_SIZE_PERCENT" =~ ^[0-9]+$ ]] || die "MIN_SIZE_PERCENT must be a whole number"
  [[ "$WEBHOOK_REPEAT_HOURS" =~ ^[0-9]+$ ]] || die "WEBHOOK_REPEAT_HOURS must be a whole number"
}

# ---------------------------------------------------------------- backup

# backup_host <name> <base_url> <tls> <result_dir>
# Writes "OK <msg>", "CHANGED <msg>" or "FAIL <msg>" to <result_dir>/<name>.
backup_host() {
  local name="$1" base_url="${2%/}" tls="$3" result="$4/$1"
  local key_file="$API_KEY_DIR/$name.txt"
  local out="$BACKUP_DIR/config_${name}.xml"
  local tmp http_code key secret err

  fail() { echo "FAIL $*" >"$result"; log "[$name] FAILED: $*"; }

  if [[ ! -r "$key_file" ]]; then
    fail "API key file not readable: $key_file"; return
  fi
  if [[ "$(stat -c %a "$key_file")" != 600 && "$(stat -c %a "$key_file")" != 400 ]]; then
    log "[$name] WARNING: $key_file is not mode 600"
  fi
  # OPNsense key files look like:  key=XXXX  /  secret=YYYY
  key=$(sed -n 's/^key=//p' "$key_file" | tr -d '\r')
  secret=$(sed -n 's/^secret=//p' "$key_file" | tr -d '\r')
  if [[ -z "$key" || -z "$secret" ]]; then
    fail "API key file $key_file must contain key= and secret= lines"; return
  fi

  local -a tls_args
  case "$tls" in
  sha256//*) tls_args=(--insecure --pinnedpubkey "$tls") ;; # chain skipped, key pin enforced
  ca:*) tls_args=(--cacert "${tls#ca:}") ;;
  system) tls_args=() ;;
  insecure)
    tls_args=(--insecure)
    log "[$name] WARNING: TLS verification disabled for this host"
    ;;
  *) fail "Unknown TLS setting '$tls' (use sha256//<pin>, ca:<file>, system or insecure)"; return ;;
  esac

  tmp=$(mktemp "$BACKUP_DIR/.config_${name}.XXXXXX") || { fail "mktemp failed"; return; }
  err=$(mktemp) || { rm -f "$tmp"; fail "mktemp failed"; return; }

  log "[$name] Downloading configuration from $base_url"
  # Credentials go to curl on stdin (-K -) so they never appear in the process list.
  http_code=$(
    printf 'user = "%s:%s"\n' "$key" "$secret" |
      curl --config - --silent --show-error \
        --proto '=https' --tlsv1.2 \
        --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
        "${tls_args[@]}" \
        --header 'Accept: application/xml, text/xml, */*' \
        --output "$tmp" --write-out '%{http_code}' \
        "$base_url/api/core/backup/download/this" 2>"$err"
  )
  local curl_rc=$?
  unset key secret

  if ((curl_rc != 0)); then
    local why
    why=$(tr '\n' ' ' <"$err")
    case "$curl_rc" in
    90) why="TLS public key does not match the pinned key (certificate changed?) $why" ;;
    28) why="timed out $why" ;;
    esac
    rm -f "$tmp" "$err"; fail "curl error $curl_rc: $why"; return
  fi
  rm -f "$err"

  case "$http_code" in
  200) ;;
  401) rm -f "$tmp"; fail "HTTP 401: API key/secret rejected"; return ;;
  403) rm -f "$tmp"; fail "HTTP 403: API user lacks the 'Diagnostics: Configuration History' privilege"; return ;;
  *)
    local body
    body=$(head -c 300 "$tmp" | tr '\n' ' ')
    rm -f "$tmp"; fail "HTTP $http_code: $body"; return
    ;;
  esac

  # --- validation: never replace a good copy with a bad one
  local size root
  size=$(stat -c %s "$tmp")
  if ((size < 1024)); then
    mv -f "$tmp" "$out.failed"; fail "download is only $size bytes (saved as $(basename "$out").failed)"; return
  fi
  if ! xmllint --noout --nonet "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$out.failed"; fail "download is not well-formed XML (saved as $(basename "$out").failed)"; return
  fi
  root=$(xmllint --nonet --xpath 'name(/*)' "$tmp" 2>/dev/null)
  if [[ "$root" != opnsense ]]; then
    mv -f "$tmp" "$out.failed"; fail "XML root is <$root>, expected <opnsense> (saved as $(basename "$out").failed)"; return
  fi
  if [[ -f "$out" ]]; then
    local old_size
    old_size=$(stat -c %s "$out")
    if ((old_size > 0 && size * 100 < old_size * MIN_SIZE_PERCENT)); then
      mv -f "$tmp" "$out.failed"
      fail "new config is $size bytes vs $old_size before (<${MIN_SIZE_PERCENT}%); kept the old copy, new one saved as $(basename "$out").failed"
      return
    fi
  fi

  if [[ "$DRY_RUN" == true ]]; then
    local note="unchanged"
    [[ -f "$out" ]] && ! cmp -s "$tmp" "$out" && note="differs from saved copy"
    [[ -f "$out" ]] || note="no saved copy yet"
    rm -f "$tmp"
    echo "OK valid, $size bytes, $note" >"$result"
    log "[$name] OK (dry run): valid <opnsense> XML, $size bytes, $note"
    return
  fi

  rm -f "$out.failed"
  if [[ -f "$out" ]] && cmp -s "$tmp" "$out"; then
    rm -f "$tmp"
    echo "OK unchanged ($size bytes)" >"$result"
    log "[$name] OK: unchanged"
  else
    chmod 600 "$tmp"
    mv -f "$tmp" "$out"
    echo "CHANGED $size bytes" >"$result"
    log "[$name] OK: configuration changed, saved $(basename "$out") ($size bytes)"
  fi
}

# ---------------------------------------------------------------- git

git_commit_and_push() { # git_commit_and_push <changed names...>
  local msg
  msg="$GIT_COMMIT_PREFIX $(date '+%Y-%m-%d %H:%M:%S')"
  (($# > 0)) && msg+=$'\n\n'"Changed: $*"

  git -C "$BACKUP_DIR" add -- 'config_*.xml' >>"$LOG_FILE" 2>&1
  if git -C "$BACKUP_DIR" diff --cached --quiet; then
    log "git: nothing to commit"
  else
    if ! git -C "$BACKUP_DIR" commit --quiet -m "$msg" >>"$LOG_FILE" 2>&1; then
      log "git: commit FAILED"
      alert_state git FAIL "git commit failed in $BACKUP_DIR - see $LOG_FILE"
      return 1
    fi
    log "git: committed ($*)"
  fi

  [[ "$GIT_PUSH" == true ]] || { alert_state git OK "git working again"; return 0; }
  git -C "$BACKUP_DIR" remote get-url origin >/dev/null 2>&1 || {
    log "git: no 'origin' remote, not pushing"; alert_state git OK "git working again"; return 0; }

  # Push whenever local is ahead (also retries earlier failed pushes).
  local ahead
  ahead=$(git -C "$BACKUP_DIR" rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo unknown)
  if [[ "$ahead" == 0 ]]; then
    alert_state git OK "git push working again"
    return 0
  fi
  if timeout 120 git -C "$BACKUP_DIR" push --quiet >>"$LOG_FILE" 2>&1; then
    log "git: pushed"
    alert_state git OK "git push to origin working again"
  else
    log "git: push FAILED"
    alert_state git FAIL "git push from $BACKUP_DIR failed; commits are safe locally and will be pushed on the next successful run. See $LOG_FILE"
    return 1
  fi
}

# ---------------------------------------------------------------- main

main() {
  validate_environment
  mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"

  exec 9>"$STATE_DIR/lock"
  flock -n 9 || { log "Another backup run is still active, exiting"; exit 0; }

  [[ -d "$BACKUP_DIR" ]] || die "BACKUP_DIR does not exist: $BACKUP_DIR"
  if [[ "$DRY_RUN" != true ]]; then
    git -C "$BACKUP_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
      die "BACKUP_DIR is not a git repository: $BACKUP_DIR"
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log "=== OPNsense backup run started (dry run)"
  else
    log "=== OPNsense backup run started"
  fi

  # global so the EXIT trap can still see it after main returns
  result_dir=$(mktemp -d)
  trap 'rm -rf "$result_dir"' EXIT

  local -a names=()
  local name url tls
  while read -r name url tls _ || [[ -n "$name" ]]; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ || -z "$url" ]]; then
      log "Skipping malformed line in $OPNSENSE_LIST: $name $url $tls"
      continue
    fi
    names+=("$name")
    backup_host "$name" "$url" "${tls:-system}" "$result_dir" &
  done <"$OPNSENSE_LIST"
  wait

  ((${#names[@]} > 0)) || die "No firewalls listed in $OPNSENSE_LIST"

  local ok=0 failed=0 status detail
  local -a changed=() summary=()
  for name in "${names[@]}"; do
    if [[ -f "$result_dir/$name" ]]; then
      read -r status detail <"$result_dir/$name"
    else
      status=FAIL detail="backup process produced no result"
    fi
    summary+=("$name: $status $detail")
    case "$status" in
    OK) ((ok++)); alert_state "$name" OK "$name: backup succeeded again ($detail)" ;;
    CHANGED) ((ok++)); changed+=("$name"); alert_state "$name" OK "$name: backup succeeded again ($detail)" ;;
    *) ((failed++)); alert_state "$name" FAIL "$name: $detail" ;;
    esac
  done

  local git_rc=0
  if [[ "$DRY_RUN" != true ]]; then
    git_commit_and_push "${changed[@]}" || git_rc=1
  fi

  log "=== Summary: $ok succeeded (${#changed[@]} changed), $failed failed"
  if [[ "$WEBHOOK_NOTIFY_ERRORS_ONLY" != true ]] && ((failed == 0 && git_rc == 0)); then
    notify "OPNsense backup succeeded" "$(printf '%s\n' "${summary[@]}")"
  fi

  ((failed == 0 && git_rc == 0))
}

main
