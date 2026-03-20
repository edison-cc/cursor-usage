#!/usr/bin/env bash
# test-cursor-usage.sh — CLI test
#
# Usage:
#   bash test-cursor-usage.sh
#
# Prerequisites:
#   Cursor IDE must be installed and signed in on this machine.


set -euo pipefail

DB="$HOME/Library/Application Support/Cursor/User/globalStorage/state.vscdb"

if [ ! -f "$DB" ]; then
  echo "ERROR: Cursor DB not found at: $DB"
  echo "Make sure Cursor has been opened and you are signed in."
  exit 1
fi

ACCESS_TOKEN=$(sqlite3 "$DB" "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken';")
if [ -z "$ACCESS_TOKEN" ]; then
  echo "ERROR: No access token found in DB. Are you signed in to Cursor?"
  exit 1
fi

USER_ID=$(echo "$ACCESS_TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['sub'])")
COOKIE="WorkosCursorSessionToken=${USER_ID}::${ACCESS_TOKEN}"

EMAIL=$(sqlite3 "$DB" "SELECT value FROM ItemTable WHERE key = 'cursorAuth/cachedEmail';")

api_get() {
  curl -sL --max-time 15 -b "$COOKIE" "$1"
}

api_post() {
  curl -sL --max-time 30 \
    -X POST -H "Content-Type: application/json" \
    -H "Origin: https://cursor.com" \
    -d "$2" \
    -b "$COOKIE" "$1"
}

echo "=== Cursor Usage ==="
echo ""

STRIPE=$(api_get "https://www.cursor.com/api/auth/stripe")
TEAM_ID=$(echo "$STRIPE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('teamId',''))" 2>/dev/null)

USAGE=$(api_get "https://www.cursor.com/api/usage")

export SPEND_JSON=""
if [ -n "$TEAM_ID" ]; then
  export SPEND_JSON=$(api_post "https://www.cursor.com/api/dashboard/get-team-spend" "{\"teamId\":$TEAM_ID}")
fi

export USAGE STRIPE EMAIL

python3 << 'PYEOF'
import json, os, datetime

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
team_id = stripe.get("teamId", "")

print(f"User:  {email}")
print(f"Plan:  {membership}" + (f"  (team {team_id})" if team_id else ""))

if start_str:
    try:
        start_dt = datetime.datetime.fromisoformat(start_str.replace("Z", "+00:00"))
        if start_dt.month == 12:
            end_dt = start_dt.replace(year=start_dt.year + 1, month=1)
        else:
            end_dt = start_dt.replace(month=start_dt.month + 1)
        print(f"Cycle: {start_dt.strftime('%b %d')} → {end_dt.strftime('%b %d, %Y')}")
    except:
        pass

bar_len = 30

# On-demand spend (enterprise/team plans only)
members = spend_data.get("teamMemberSpend", [])
me = next((m for m in members if m.get("email", "").lower() == email.lower()), None)
spend_cents = 0
has_spend = False
if me and "spendCents" in me:
    has_spend = True
    spend_cents = me["spendCents"]

quota_reached = (total > 0 and used >= total) or (has_spend and spend_cents > 0)
display_used = total if quota_reached else used
req_pct = (display_used / total * 100) if total else 0
filled = int(bar_len * min(req_pct, 100) / 100)
req_bar = "█" * filled + "░" * (bar_len - filled)

print()
print(f"Included Requests:  {display_used} / {total}")
print(f"  [{req_bar}] {req_pct:.0f}%")
print(f"  Tokens used: {tokens:,}")

if has_spend:
    spend_dollars = spend_cents / 100
    limit_dollars = me.get("effectivePerUserLimitDollars", me.get("hardLimitOverrideDollars", 0))
    spend_pct = (spend_dollars / limit_dollars * 100) if limit_dollars else 0
    filled = int(bar_len * min(spend_pct, 100) / 100)
    spend_bar = "█" * filled + "░" * (bar_len - filled)

    print()
    print(f"On-Demand Usage:    ${spend_dollars:.2f} / ${limit_dollars:.0f}")
    print(f"  [{spend_bar}] {spend_pct:.0f}%")
elif me:
    print()
    print("On-Demand Usage:    $0.00 (no on-demand charges yet)")
PYEOF

echo ""
