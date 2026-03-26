#!/usr/bin/env bash
# <xbar.title>Cursor Usage</xbar.title>
# <xbar.version>v1.0</xbar.version>
# <xbar.desc>Shows Cursor included-request and on-demand usage in the menu bar</xbar.desc>

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:$PATH"

DB="$HOME/Library/Application Support/Cursor/User/globalStorage/state.vscdb"

error_exit() {
  echo "$(printf '\033[31m●\033[0m') err | ansi=true"
  echo "---"
  echo "$1 | color=#ff4444"
  exit 0
}

[ -f "$DB" ] || error_exit "Cursor DB not found"

ACCESS_TOKEN=$(sqlite3 "$DB" "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken';" 2>/dev/null)
[ -n "$ACCESS_TOKEN" ] || error_exit "No access token — sign in to Cursor"

USER_ID=$(echo "$ACCESS_TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['sub'])" 2>/dev/null)
COOKIE="WorkosCursorSessionToken=${USER_ID}::${ACCESS_TOKEN}"

EMAIL=$(sqlite3 "$DB" "SELECT value FROM ItemTable WHERE key = 'cursorAuth/cachedEmail';" 2>/dev/null)

api_get() {
  curl -sL --max-time 15 -b "$COOKIE" "$1" 2>/dev/null
}

api_post() {
  curl -sL --max-time 30 \
    -X POST -H "Content-Type: application/json" \
    -H "Origin: https://cursor.com" \
    -d "$2" \
    -b "$COOKIE" "$1" 2>/dev/null
}

STRIPE=$(api_get "https://www.cursor.com/api/auth/stripe")
TEAM_ID=$(echo "$STRIPE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('teamId',''))" 2>/dev/null)

USAGE=$(api_get "https://www.cursor.com/api/usage")

export SPEND_JSON=""
if [ -n "$TEAM_ID" ]; then
  export SPEND_JSON=$(api_post "https://www.cursor.com/api/dashboard/get-team-spend" "{\"teamId\":$TEAM_ID}")
fi

DAILY_STATS=$(sqlite3 "$DB" \
  "SELECT value FROM ItemTable WHERE key LIKE 'aiCodeTracking.dailyStats.v1.5.%' ORDER BY key DESC LIMIT 14;" 2>/dev/null)
FIRST_SESSION=$(sqlite3 "$DB" \
  "SELECT value FROM ItemTable WHERE key = 'telemetry.firstSessionDate';" 2>/dev/null)
RECENT_COMMIT=$(sqlite3 "$DB" \
  "SELECT value FROM ItemTable WHERE key = 'aiCodeTracking.recentCommit';" 2>/dev/null)

export USAGE STRIPE EMAIL DAILY_STATS FIRST_SESSION RECENT_COMMIT

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
