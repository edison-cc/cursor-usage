#!/usr/bin/env bash
# <xbar.title>Cursor Usage</xbar.title>
# <xbar.version>v1.0</xbar.version>
# <xbar.author>Edison Chen</xbar.author>
# <xbar.desc>Shows Cursor included-request and on-demand usage in the menu bar</xbar.desc>
# <xbar.dependencies>sqlite3,curl,python3</xbar.dependencies>

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:$PATH"

DB="$HOME/Library/Application Support/Cursor/User/globalStorage/state.vscdb"

error_exit() {
  echo "⚡ err | color=#ff4444"
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

export USAGE STRIPE EMAIL

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

# Color logic
def pct_color(pct):
    if pct >= 80:
        return "#ff4444"
    if pct >= 50:
        return "#ffaa00"
    return "#4CAF50"

req_color = pct_color(req_pct)
spend_color = pct_color(spend_pct) if has_spend else "#4CAF50"

# Menu bar line (always visible)
overage = max(0, used - total) if total > 0 else 0
if overage > 0:
    parts = [f"({total}+{overage})/{total}"]
else:
    parts = [f"{used}/{total}"]
if has_spend:
    parts.append(f"${spend_dollars:.2f}/${limit_dollars:.0f}")
bar_text = " · ".join(parts)
print(f"⚡ {bar_text} | size=13")

# Dropdown
print("---")

# User info
print(f"{email} | color=#888888 size=12")
print(f"Plan: {membership} | color=#888888 size=12")

# Cycle dates
if start_str:
    try:
        start_dt = datetime.datetime.fromisoformat(start_str.replace("Z", "+00:00"))
        if start_dt.month == 12:
            end_dt = start_dt.replace(year=start_dt.year + 1, month=1)
        else:
            end_dt = start_dt.replace(month=start_dt.month + 1)
        print(f"Cycle: {start_dt.strftime('%b %d')} → {end_dt.strftime('%b %d, %Y')} | color=#888888 size=12")
    except:
        pass

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
print("Refresh | refresh=true size=13")
PYEOF
