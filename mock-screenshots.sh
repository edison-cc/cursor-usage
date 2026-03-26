#!/usr/bin/env bash
# Generate mock xbar output for screenshots at different usage levels.
# Usage:
#   bash mock-screenshots.sh green|yellow|red   — preview one preset in terminal
#   bash mock-screenshots.sh all                — preview all three presets
#   bash mock-screenshots.sh install            — install all three as SwiftBar plugins
#   bash mock-screenshots.sh uninstall          — remove mock plugins from SwiftBar

set -euo pipefail

SWIFTBAR_DIR="${SWIFTBAR_DIR:-$HOME/swiftbar-plugins}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------------------
# Mock data shared across presets
# ---------------------------------------------------------------------------

MOCK_EMAIL="dev@example.com"
MOCK_STRIPE='{"membershipType":"pro"}'
MOCK_FIRST_SESSION="2025-06-15T10:00:00Z"
MOCK_RECENT_COMMIT='{"aiPercentage":42}'

# 14 days of fake daily stats (ascending activity pattern)
MOCK_DAILY_STATS=$(cat <<'DS'
{"tabSuggestedLines":12,"composerSuggestedLines":5}
{"tabSuggestedLines":20,"composerSuggestedLines":10}
{"tabSuggestedLines":8,"composerSuggestedLines":3}
{"tabSuggestedLines":35,"composerSuggestedLines":18}
{"tabSuggestedLines":50,"composerSuggestedLines":25}
{"tabSuggestedLines":15,"composerSuggestedLines":8}
{"tabSuggestedLines":42,"composerSuggestedLines":20}
{"tabSuggestedLines":60,"composerSuggestedLines":30}
{"tabSuggestedLines":28,"composerSuggestedLines":14}
{"tabSuggestedLines":55,"composerSuggestedLines":22}
{"tabSuggestedLines":70,"composerSuggestedLines":35}
{"tabSuggestedLines":45,"composerSuggestedLines":19}
{"tabSuggestedLines":65,"composerSuggestedLines":32}
{"tabSuggestedLines":80,"composerSuggestedLines":40}
DS
)

# startOfMonth: 1st of the current month so countdown looks realistic
MOCK_START=$(date -u -v1d +"%Y-%m-01T00:00:00Z" 2>/dev/null \
  || date -u -d "$(date +%Y-%m-01)" +"%Y-%m-01T00:00:00Z" 2>/dev/null \
  || echo "2026-03-01T00:00:00Z")

# ---------------------------------------------------------------------------
# Preset definitions — only numRequests differs
# ---------------------------------------------------------------------------

usage_json() {
  local used=$1 total=$2 tokens=$3
  echo "{\"gpt-4\":{\"numRequests\":${used},\"maxRequestUsage\":${total},\"numTokens\":${tokens}},\"startOfMonth\":\"${MOCK_START}\"}"
}

# ---------------------------------------------------------------------------
# Renderer — the same Python heredoc from cursor-usage.5m.sh
# ---------------------------------------------------------------------------

render() {
  local used=$1 total=$2 tokens=$3

  export USAGE
  USAGE=$(usage_json "$used" "$total" "$tokens")
  export STRIPE="$MOCK_STRIPE"
  export EMAIL="$MOCK_EMAIL"
  export SPEND_JSON=""
  export DAILY_STATS="$MOCK_DAILY_STATS"
  export FIRST_SESSION="$MOCK_FIRST_SESSION"
  export RECENT_COMMIT="$MOCK_RECENT_COMMIT"

  python3 << 'PYEOF'
import json, os, sys, datetime

def safe_load(s):
    try:
        return json.loads(s)
    except:
        return {}

usage = safe_load(os.environ.get("USAGE", "{}"))
stripe = safe_load(os.environ.get("STRIPE", "{}"))
spend_data = safe_load(os.environ.get("SPEND_JSON", "{}"))
email = os.environ.get("EMAIL", "")
daily_stats_raw = os.environ.get("DAILY_STATS", "")
first_session_raw = os.environ.get("FIRST_SESSION", "")
recent_commit_raw = os.environ.get("RECENT_COMMIT", "")

gpt4 = usage.get("gpt-4", {})
used = gpt4.get("numRequests", 0)
total = gpt4.get("maxRequestUsage", 0)
tokens = gpt4.get("numTokens", 0)
start_str = usage.get("startOfMonth", "")
membership = stripe.get("membershipType", "unknown")

# Find own spend in team data
spend_cents = 0
limit_dollars = 0
has_spend = False

members = spend_data.get("teamMemberSpend", [])
me = next((m for m in members if m.get("email", "").lower() == email.lower()), None)
if me and "spendCents" in me:
    has_spend = True
    spend_cents = me["spendCents"]
    limit_dollars = me.get("effectivePerUserLimitDollars", me.get("hardLimitOverrideDollars", 0))

spend_dollars = spend_cents / 100
quota_reached = (total > 0 and used >= total) or (has_spend and spend_cents > 0)
display_used = total if quota_reached else used
req_pct = (display_used / total * 100) if total else 0
spend_pct = (spend_dollars / limit_dollars * 100) if limit_dollars else 0

def pct_color(pct):
    if pct >= 80:
        return "#ff4444"
    if pct >= 50:
        return "#ffaa00"
    return "#4CAF50"

def pct_dot(pct):
    if pct >= 80:
        return "\033[31m●\033[0m"
    if pct >= 50:
        return "\033[33m●\033[0m"
    return "\033[32m●\033[0m"

req_color = pct_color(req_pct)
spend_color = pct_color(spend_pct) if has_spend else "#4CAF50"

# --- Countdown to reset ---
now = datetime.datetime.now(datetime.timezone.utc)
countdown_str = ""
countdown_compact = ""
countdown_color = "#4CAF50"
start_dt = None
end_dt = None

if start_str:
    try:
        start_dt = datetime.datetime.fromisoformat(start_str.replace("Z", "+00:00"))
        if start_dt.month == 12:
            end_dt = start_dt.replace(year=start_dt.year + 1, month=1)
        else:
            end_dt = start_dt.replace(month=start_dt.month + 1)
        delta = end_dt - now
        if delta.total_seconds() > 0:
            d = delta.days
            h = delta.seconds // 3600
            m = (delta.seconds % 3600) // 60
            countdown_str = f"{d}d {h}h {m}m" if d > 0 else f"{h}h {m}m"
            countdown_compact = f"{d}d" if d > 0 else f"{h}h"
            if d < 3:
                countdown_color = "#ff4444"
            elif d < 7:
                countdown_color = "#ffaa00"
    except:
        pass

# --- Pace indicator ---
pace_label = ""
pace_color = "#888888"
if start_dt and end_dt:
    elapsed_s = (now - start_dt).total_seconds()
    total_s = (end_dt - start_dt).total_seconds()
    if total_s > 0 and elapsed_s > 0:
        expected_pct = (elapsed_s / total_s) * 100
        usage_pct = spend_pct if has_spend else req_pct
        pace = usage_pct / expected_pct if expected_pct > 0 else 0
        if pace < 1.0:
            pace_label, pace_color = f"{pace:.1f}x (Cruising)", "#4CAF50"
        elif pace < 1.2:
            pace_label, pace_color = f"{pace:.1f}x (On Track)", "#4CAF50"
        elif pace < 1.5:
            pace_label, pace_color = f"{pace:.1f}x (Burning Fast)", "#ffaa00"
        else:
            pace_label, pace_color = f"{pace:.1f}x (Token Anxiety)", "#ff4444"

# --- Motivational message ---
if has_spend:
    if spend_pct >= 95:
        motto = "Budget limit. Touch grass."
    elif spend_pct >= 80:
        motto = "Wallet getting nervous."
    elif spend_pct >= 50:
        motto = "Money well spent... right?"
    elif spend_pct >= 20:
        motto = "Investing in velocity."
    else:
        motto = "On the meter. Worth every cent."
else:
    if req_pct >= 95:
        motto = "Limit reached. Touch grass."
    elif req_pct >= 80:
        motto = "Running hot."
    elif req_pct >= 50:
        motto = "In the zone."
    elif req_pct >= 20:
        motto = "Steady pace. Shipping."
    else:
        motto = "Fresh start. Go build."

# --- Sparkline from daily stats ---
sparkline = ""
if daily_stats_raw.strip():
    spark_chars = "▁▂▃▄▅▆▇█"
    daily_values = []
    for line in daily_stats_raw.strip().split("\n"):
        try:
            d = json.loads(line)
            daily_values.append(d.get("tabSuggestedLines", 0) + d.get("composerSuggestedLines", 0))
        except:
            pass
    daily_values.reverse()
    if daily_values:
        max_val = max(daily_values) or 1
        sparkline = "".join(
            spark_chars[min(int(v / max_val * 7), 7)] for v in daily_values
        )

# --- Session tenure ---
tenure_str = ""
if first_session_raw.strip():
    try:
        first_dt = datetime.datetime.fromisoformat(first_session_raw.strip().replace("Z", "+00:00"))
        tenure_str = f"{(now - first_dt).days}d"
    except:
        try:
            first_dt = datetime.datetime.strptime(first_session_raw.strip()[:10], "%Y-%m-%d")
            tenure_str = f"{(now.replace(tzinfo=None) - first_dt).days}d"
        except:
            pass

# --- AI code attribution ---
ai_pct_str = ""
recent_commit = safe_load(recent_commit_raw)
if recent_commit and "aiPercentage" in recent_commit:
    try:
        ai_pct_str = f"{float(recent_commit['aiPercentage']):.0f}%"
    except:
        pass

# ====== OUTPUT ======

# Menu bar title
dot = pct_dot(spend_pct) if has_spend else pct_dot(req_pct)
if has_spend:
    bar_text = f"{dot} {total} · ${spend_dollars:.0f}/${limit_dollars:.0f}"
else:
    bar_text = f"{dot} {display_used}/{total}"
print(f"{bar_text} | size=13 ansi=true")

print("---")

# User info
plan_line = f"Plan: {membership}"
if tenure_str:
    plan_line += f"  ·  Cursor user for {tenure_str}"
print(f"{email} | color=#888888 size=12")
print(f"{plan_line} | color=#888888 size=12")

# Cycle dates + countdown
if start_dt and end_dt:
    print(f"Cycle: {start_dt.strftime('%b %d')} → {end_dt.strftime('%b %d, %Y')} | color=#888888 size=12")
    if countdown_str:
        print(f"⏳ Resets in: {countdown_str} | color={countdown_color} size=12 font=Menlo")

print("---")

# Status & activity section
print(f'"{motto}" | size=13')
if pace_label:
    print(f"Pace: {pace_label} | color={pace_color} size=12 font=Menlo")
if sparkline:
    print(f"Activity (14d): {sparkline} | size=12 font=Menlo color=#888888")
if ai_pct_str:
    print(f"Last commit: {ai_pct_str} AI-generated | size=12 color=#888888")

print("---")

# Included requests
req_bar = "█" * int(20 * min(req_pct, 100) / 100) + "░" * (20 - int(20 * min(req_pct, 100) / 100))
print(f"Included Requests | size=13")
print(f"  {display_used} / {total}  ({req_pct:.0f}%) | color={req_color} size=13 font=Menlo")
print(f"  {req_bar} | size=11 font=Menlo color={req_color}")
print(f"  Tokens: {tokens:,} | color=#888888 size=12 font=Menlo")

# On-demand
if has_spend:
    print("---")
    spend_bar = "█" * int(20 * min(spend_pct, 100) / 100) + "░" * (20 - int(20 * min(spend_pct, 100) / 100))
    print(f"On-Demand Usage | size=13")
    print(f"  ${spend_dollars:.2f} / ${limit_dollars:.0f}  ({spend_pct:.0f}%) | color={spend_color} size=13 font=Menlo")
    print(f"  {spend_bar} | size=11 font=Menlo color={spend_color}")

print("---")
print("Open Cursor Settings | href=https://cursor.com/settings size=13")
print("Source Code | href=https://github.com/edison-cc/cursor-usage size=13")
print("Refresh | refresh=true size=13")
PYEOF
}

# ---------------------------------------------------------------------------
# Install / uninstall helpers
# ---------------------------------------------------------------------------

generate_plugin() {
  local name=$1 used=$2 total=$3 tokens=$4
  local dest="${SWIFTBAR_DIR}/mock-${name}.5m.sh"
  local mock_start
  mock_start=$(date -u -v1d +"%Y-%m-01T00:00:00Z" 2>/dev/null \
    || date -u -d "$(date +%Y-%m-01)" +"%Y-%m-01T00:00:00Z" 2>/dev/null \
    || echo "2026-03-01T00:00:00Z")

  cat > "$dest" << 'SELF_CONTAINED_TOP'
#!/usr/bin/env bash
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:$PATH"
SELF_CONTAINED_TOP

  cat >> "$dest" << SELF_CONTAINED_VARS
export USAGE='{"gpt-4":{"numRequests":${used},"maxRequestUsage":${total},"numTokens":${tokens}},"startOfMonth":"${mock_start}"}'
export STRIPE='{"membershipType":"pro"}'
export EMAIL="dev@example.com"
export SPEND_JSON=""
export FIRST_SESSION="2025-06-15T10:00:00Z"
export RECENT_COMMIT='{"aiPercentage":42}'
SELF_CONTAINED_VARS

  cat >> "$dest" << 'SELF_CONTAINED_STATS'
export DAILY_STATS='{"tabSuggestedLines":12,"composerSuggestedLines":5}
{"tabSuggestedLines":20,"composerSuggestedLines":10}
{"tabSuggestedLines":8,"composerSuggestedLines":3}
{"tabSuggestedLines":35,"composerSuggestedLines":18}
{"tabSuggestedLines":50,"composerSuggestedLines":25}
{"tabSuggestedLines":15,"composerSuggestedLines":8}
{"tabSuggestedLines":42,"composerSuggestedLines":20}
{"tabSuggestedLines":60,"composerSuggestedLines":30}
{"tabSuggestedLines":28,"composerSuggestedLines":14}
{"tabSuggestedLines":55,"composerSuggestedLines":22}
{"tabSuggestedLines":70,"composerSuggestedLines":35}
{"tabSuggestedLines":45,"composerSuggestedLines":19}
{"tabSuggestedLines":65,"composerSuggestedLines":32}
{"tabSuggestedLines":80,"composerSuggestedLines":40}'
SELF_CONTAINED_STATS

  # Append the Python renderer (identical to cursor-usage.5m.sh lines 59-287)
  cat >> "$dest" << 'SELF_CONTAINED_PY'

python3 << 'PYEOF'
import json, os, sys, datetime

def safe_load(s):
    try:
        return json.loads(s)
    except:
        return {}

usage = safe_load(os.environ.get("USAGE", "{}"))
stripe = safe_load(os.environ.get("STRIPE", "{}"))
spend_data = safe_load(os.environ.get("SPEND_JSON", "{}"))
email = os.environ.get("EMAIL", "")
daily_stats_raw = os.environ.get("DAILY_STATS", "")
first_session_raw = os.environ.get("FIRST_SESSION", "")
recent_commit_raw = os.environ.get("RECENT_COMMIT", "")

gpt4 = usage.get("gpt-4", {})
used = gpt4.get("numRequests", 0)
total = gpt4.get("maxRequestUsage", 0)
tokens = gpt4.get("numTokens", 0)
start_str = usage.get("startOfMonth", "")
membership = stripe.get("membershipType", "unknown")

spend_cents = 0
limit_dollars = 0
has_spend = False

members = spend_data.get("teamMemberSpend", [])
me = next((m for m in members if m.get("email", "").lower() == email.lower()), None)
if me and "spendCents" in me:
    has_spend = True
    spend_cents = me["spendCents"]
    limit_dollars = me.get("effectivePerUserLimitDollars", me.get("hardLimitOverrideDollars", 0))

spend_dollars = spend_cents / 100
quota_reached = (total > 0 and used >= total) or (has_spend and spend_cents > 0)
display_used = total if quota_reached else used
req_pct = (display_used / total * 100) if total else 0
spend_pct = (spend_dollars / limit_dollars * 100) if limit_dollars else 0

def pct_color(pct):
    if pct >= 80:
        return "#ff4444"
    if pct >= 50:
        return "#ffaa00"
    return "#4CAF50"

def pct_dot(pct):
    if pct >= 80:
        return "\033[31m●\033[0m"
    if pct >= 50:
        return "\033[33m●\033[0m"
    return "\033[32m●\033[0m"

req_color = pct_color(req_pct)
spend_color = pct_color(spend_pct) if has_spend else "#4CAF50"

now = datetime.datetime.now(datetime.timezone.utc)
countdown_str = ""
countdown_compact = ""
countdown_color = "#4CAF50"
start_dt = None
end_dt = None

if start_str:
    try:
        start_dt = datetime.datetime.fromisoformat(start_str.replace("Z", "+00:00"))
        if start_dt.month == 12:
            end_dt = start_dt.replace(year=start_dt.year + 1, month=1)
        else:
            end_dt = start_dt.replace(month=start_dt.month + 1)
        delta = end_dt - now
        if delta.total_seconds() > 0:
            d = delta.days
            h = delta.seconds // 3600
            m = (delta.seconds % 3600) // 60
            countdown_str = f"{d}d {h}h {m}m" if d > 0 else f"{h}h {m}m"
            countdown_compact = f"{d}d" if d > 0 else f"{h}h"
            if d < 3:
                countdown_color = "#ff4444"
            elif d < 7:
                countdown_color = "#ffaa00"
    except:
        pass

pace_label = ""
pace_color = "#888888"
if start_dt and end_dt:
    elapsed_s = (now - start_dt).total_seconds()
    total_s = (end_dt - start_dt).total_seconds()
    if total_s > 0 and elapsed_s > 0:
        expected_pct = (elapsed_s / total_s) * 100
        usage_pct = spend_pct if has_spend else req_pct
        pace = usage_pct / expected_pct if expected_pct > 0 else 0
        if pace < 1.0:
            pace_label, pace_color = f"{pace:.1f}x (Cruising)", "#4CAF50"
        elif pace < 1.2:
            pace_label, pace_color = f"{pace:.1f}x (On Track)", "#4CAF50"
        elif pace < 1.5:
            pace_label, pace_color = f"{pace:.1f}x (Burning Fast)", "#ffaa00"
        else:
            pace_label, pace_color = f"{pace:.1f}x (Token Anxiety)", "#ff4444"

if has_spend:
    if spend_pct >= 95:
        motto = "Budget limit. Touch grass."
    elif spend_pct >= 80:
        motto = "Wallet getting nervous."
    elif spend_pct >= 50:
        motto = "Money well spent... right?"
    elif spend_pct >= 20:
        motto = "Investing in velocity."
    else:
        motto = "On the meter. Worth every cent."
else:
    if req_pct >= 95:
        motto = "Limit reached. Touch grass."
    elif req_pct >= 80:
        motto = "Running hot."
    elif req_pct >= 50:
        motto = "In the zone."
    elif req_pct >= 20:
        motto = "Steady pace. Shipping."
    else:
        motto = "Fresh start. Go build."

sparkline = ""
if daily_stats_raw.strip():
    spark_chars = "▁▂▃▄▅▆▇█"
    daily_values = []
    for line in daily_stats_raw.strip().split("\n"):
        try:
            d = json.loads(line)
            daily_values.append(d.get("tabSuggestedLines", 0) + d.get("composerSuggestedLines", 0))
        except:
            pass
    daily_values.reverse()
    if daily_values:
        max_val = max(daily_values) or 1
        sparkline = "".join(
            spark_chars[min(int(v / max_val * 7), 7)] for v in daily_values
        )

tenure_str = ""
if first_session_raw.strip():
    try:
        first_dt = datetime.datetime.fromisoformat(first_session_raw.strip().replace("Z", "+00:00"))
        tenure_str = f"{(now - first_dt).days}d"
    except:
        try:
            first_dt = datetime.datetime.strptime(first_session_raw.strip()[:10], "%Y-%m-%d")
            tenure_str = f"{(now.replace(tzinfo=None) - first_dt).days}d"
        except:
            pass

ai_pct_str = ""
recent_commit = safe_load(recent_commit_raw)
if recent_commit and "aiPercentage" in recent_commit:
    try:
        ai_pct_str = f"{float(recent_commit['aiPercentage']):.0f}%"
    except:
        pass

dot = pct_dot(spend_pct) if has_spend else pct_dot(req_pct)
if has_spend:
    bar_text = f"{dot} {total} · ${spend_dollars:.0f}/${limit_dollars:.0f}"
else:
    bar_text = f"{dot} {display_used}/{total}"
print(f"{bar_text} | size=13 ansi=true")

print("---")

plan_line = f"Plan: {membership}"
if tenure_str:
    plan_line += f"  ·  Cursor user for {tenure_str}"
print(f"{email} | color=#888888 size=12")
print(f"{plan_line} | color=#888888 size=12")

if start_dt and end_dt:
    print(f"Cycle: {start_dt.strftime('%b %d')} → {end_dt.strftime('%b %d, %Y')} | color=#888888 size=12")
    if countdown_str:
        print(f"⏳ Resets in: {countdown_str} | color={countdown_color} size=12 font=Menlo")

print("---")

print(f'"{motto}" | size=13')
if pace_label:
    print(f"Pace: {pace_label} | color={pace_color} size=12 font=Menlo")
if sparkline:
    print(f"Activity (14d): {sparkline} | size=12 font=Menlo color=#888888")
if ai_pct_str:
    print(f"Last commit: {ai_pct_str} AI-generated | size=12 color=#888888")

print("---")

req_bar = "█" * int(20 * min(req_pct, 100) / 100) + "░" * (20 - int(20 * min(req_pct, 100) / 100))
print(f"Included Requests | size=13")
print(f"  {display_used} / {total}  ({req_pct:.0f}%) | color={req_color} size=13 font=Menlo")
print(f"  {req_bar} | size=11 font=Menlo color={req_color}")
print(f"  Tokens: {tokens:,} | color=#888888 size=12 font=Menlo")

if has_spend:
    print("---")
    spend_bar = "█" * int(20 * min(spend_pct, 100) / 100) + "░" * (20 - int(20 * min(spend_pct, 100) / 100))
    print(f"On-Demand Usage | size=13")
    print(f"  ${spend_dollars:.2f} / ${limit_dollars:.0f}  ({spend_pct:.0f}%) | color={spend_color} size=13 font=Menlo")
    print(f"  {spend_bar} | size=11 font=Menlo color={spend_color}")

print("---")
print("Open Cursor Settings | href=https://cursor.com/settings size=13")
print("Source Code | href=https://github.com/edison-cc/cursor-usage size=13")
print("Refresh | refresh=true size=13")
PYEOF
SELF_CONTAINED_PY

  chmod +x "$dest"
  echo "Installed: $dest"
}

do_install() {
  mkdir -p "$SWIFTBAR_DIR"
  generate_plugin green  50  500  24680
  generate_plugin yellow 300 500 148200
  generate_plugin red    450 500 312750
  echo ""
  echo "Three mock plugins installed in ${SWIFTBAR_DIR}."
  echo "Refresh SwiftBar to see them, then take your screenshots."
  echo "Run 'bash mock-screenshots.sh uninstall' to clean up."
}

do_uninstall() {
  for f in mock-green.5m.sh mock-yellow.5m.sh mock-red.5m.sh; do
    rm -f "${SWIFTBAR_DIR}/${f}" && echo "Removed: ${SWIFTBAR_DIR}/${f}"
  done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

case "${1:-}" in
  green)   render  50  500  24680  ;;
  yellow)  render 300  500 148200  ;;
  red)     render 450  500 312750  ;;
  all)
    for preset in green yellow red; do
      echo "=== $(echo "$preset" | tr '[:lower:]' '[:upper:]') ==="
      bash "$0" "$preset"
      echo ""
    done
    ;;
  install)   do_install   ;;
  uninstall) do_uninstall ;;
  *)
    echo "Usage: bash mock-screenshots.sh <green|yellow|red|all|install|uninstall>"
    exit 1
    ;;
esac
