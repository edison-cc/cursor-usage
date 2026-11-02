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

# Prints the session cookie for the stored token, or an error message and exits 1.
# Newer Cursor builds encrypt the token at rest: "cursor-safe-storage:v1:" + base64
# of an Electron safeStorage blob keyed by the "Cursor Safe Storage" Keychain item.
# Older builds store a plain JWT. The JWT is parsed in Python because its segments
# are unpadded base64url, which `base64 -d` silently truncates.
session_cookie() {
  CURSOR_ACCESS_TOKEN="$1" python3 - <<'COOKIEPY'
import base64, ctypes, hashlib, json, os, subprocess, sys

def fail(msg):
    print(msg)
    sys.exit(1)

UNREADABLE = "Could not decrypt the Cursor token — sign in to Cursor again"
PREFIX = "cursor-safe-storage:v1:"
token = os.environ["CURSOR_ACCESS_TOKEN"].strip()
if token.startswith(PREFIX):
    try:
        blob = base64.b64decode(token[len(PREFIX):], validate=True)
    except ValueError:
        fail(UNREADABLE)
    if blob[:3] != b"v10":
        fail(UNREADABLE)
    ct = blob[3:]
    cccrypt = ctypes.CDLL("/usr/lib/libSystem.B.dylib").CCCrypt
    cccrypt.restype = ctypes.c_int32
    cccrypt.argtypes = [ctypes.c_uint32] * 3 + [
        ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_size_t,
        ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t),
    ]
    found = denied = False
    # Some installs have both accounts under this service; only one holds the key
    # that encrypted the token.
    for account in ("Cursor", "Cursor Key"):
        r = subprocess.run(
            ["security", "find-generic-password", "-w", "-s", "Cursor Safe Storage", "-a", account],
            capture_output=True,
        )
        if r.returncode == 44:  # errSecItemNotFound
            continue
        if r.returncode != 0:
            denied = True
            continue
        found = True
        key = hashlib.pbkdf2_hmac("sha1", r.stdout.rstrip(b"\n"), b"saltysalt", 1003, 16)
        out = ctypes.create_string_buffer(len(ct))
        moved = ctypes.c_size_t()
        # kCCDecrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding; the IV is 16 spaces.
        if cccrypt(1, 0, 1, key, 16, b" " * 16, ct, len(ct), out, len(out), ctypes.byref(moved)):
            continue
        try:
            plain = out.raw[:moved.value].decode("utf-8")
        except UnicodeDecodeError:
            continue
        # A wrong key can still yield valid-looking padding, so check the result.
        if plain.count(".") == 2:
            token = plain
            break
    else:
        if denied:
            fail("Keychain access to Cursor Safe Storage was denied — allow it, then Refresh")
        if not found:
            fail("Cursor Safe Storage is missing from the Keychain — sign in to Cursor again")
        fail(UNREADABLE)

parts = token.split(".")
payload = parts[1] if len(parts) > 1 else ""
try:
    claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
except ValueError:
    claims = None
sub = claims.get("sub") if isinstance(claims, dict) else None
if not sub:
    fail("Invalid Cursor token — sign in to Cursor again")
print("WorkosCursorSessionToken=%s::%s" % (sub, token))
COOKIEPY
}

ACCESS_TOKEN=$(sqlite3 "$DB" "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken';" 2>/dev/null)
[ -n "$ACCESS_TOKEN" ] || error_exit "No access token — sign in to Cursor"

COOKIE=$(session_cookie "$ACCESS_TOKEN") || error_exit "$COOKIE"

EMAIL=$(sqlite3 "$DB" "SELECT value FROM ItemTable WHERE key = 'cursorAuth/cachedEmail';" 2>/dev/null)

api_get() {
  curl -sL --max-time 15 -b "$COOKIE" "$1" 2>/dev/null
}

# A rejected session still returns JSON ({"error":"not_authenticated"}).
# Prints a message for an API error response, else nothing.
api_error_message() {
  python3 -c '
import json, sys
try:
    err = json.load(sys.stdin).get("error")
except (ValueError, AttributeError):
    err = None
if err == "not_authenticated":
    print("Cursor session expired — open Cursor and sign in again")
elif err:
    print("Cursor API error: %s" % err)
'
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
API_ERROR=$(printf '%s' "$USAGE" | api_error_message)
[ -z "$API_ERROR" ] || error_exit "$API_ERROR"

SPEND_JSON=""
if [ -n "$TEAM_ID" ]; then
  SPEND_JSON=$(api_post "https://www.cursor.com/api/dashboard/get-team-spend" "{\"teamId\":$TEAM_ID}")
fi

# Team spend JSON lists every member and can exceed ARG_MAX, so API responses
# go through files instead of the environment.
API_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cursor-usage-5m-api.XXXXXX") || error_exit "mktemp failed"
trap 'rm -rf "$API_DIR"' EXIT INT HUP TERM
printf '%s' "$STRIPE" > "$API_DIR/stripe.json"
printf '%s' "$USAGE" > "$API_DIR/usage.json"
if [ -n "$SPEND_JSON" ]; then
  printf '%s' "$SPEND_JSON" > "$API_DIR/spend.json"
else
  printf '%s' '{}' > "$API_DIR/spend.json"
fi
export CURSOR_USAGE_API_DIR="$API_DIR"

DAILY_STATS=$(sqlite3 "$DB" \
  "SELECT value FROM ItemTable WHERE key LIKE 'aiCodeTracking.dailyStats.v1.5.%' ORDER BY key DESC LIMIT 14;" 2>/dev/null)
FIRST_SESSION=$(sqlite3 "$DB" \
  "SELECT value FROM ItemTable WHERE key = 'telemetry.firstSessionDate';" 2>/dev/null)
RECENT_COMMIT=$(sqlite3 "$DB" \
  "SELECT value FROM ItemTable WHERE key = 'aiCodeTracking.recentCommit';" 2>/dev/null)

export EMAIL DAILY_STATS FIRST_SESSION RECENT_COMMIT

python3 << 'PYEOF'
import json, os, sys, datetime

def safe_load(s):
    try:
        return json.loads(s)
    except:
        return {}

def load_api_json(name):
    try:
        with open(os.path.join(os.environ["CURSOR_USAGE_API_DIR"], name), encoding="utf-8") as f:
            return safe_load(f.read())
    except (KeyError, OSError):
        return {}

usage = load_api_json("usage.json")
stripe = load_api_json("stripe.json")
spend_data = load_api_json("spend.json")
email = os.environ.get("EMAIL", "")
daily_stats_raw = os.environ.get("DAILY_STATS", "")
first_session_raw = os.environ.get("FIRST_SESSION", "")
recent_commit_raw = os.environ.get("RECENT_COMMIT", "")

gpt4 = usage.get("gpt-4") or {}
used = gpt4.get("numRequests") or 0
total = gpt4.get("maxRequestUsage") or 0
tokens = gpt4.get("numTokens") or 0
start_str = usage.get("startOfMonth", "")
membership = stripe.get("membershipType", "unknown")

# Find own spend in team data
spend_cents = 0
limit_dollars = 0
has_spend = False

members = spend_data.get("teamMemberSpend", [])
me = next((m for m in members if m.get("email", "").lower() == email.lower()), None)
# Usage-based plans (maxRequestUsage null) have no included requests: all usage
# is billed and reported as overallSpendCents. Zero-valued fields are omitted.
spend_key = "spendCents" if total else "overallSpendCents"
if me and (spend_key in me or not total):
    has_spend = True
    spend_cents = me.get(spend_key, 0)
    limit_dollars = me.get("effectivePerUserLimitDollars", me.get("hardLimitOverrideDollars", 0))

spend_dollars = spend_cents / 100
quota_reached = total > 0 and (used >= total or (has_spend and spend_cents > 0))
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
    req_prefix = f"{total} · " if total else ""
    bar_text = f"{dot} {req_prefix}${spend_dollars:.0f}/${limit_dollars:.0f}"
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
show_requests = bool(total) or not has_spend
if show_requests:
    req_bar = "█" * int(20 * min(req_pct, 100) / 100) + "░" * (20 - int(20 * min(req_pct, 100) / 100))
    print(f"Included Requests | size=13")
    print(f"  {display_used} / {total}  ({req_pct:.0f}%) | color={req_color} size=13 font=Menlo")
    print(f"  {req_bar} | size=11 font=Menlo color={req_color}")
    print(f"  Tokens: {tokens:,} | color=#888888 size=12 font=Menlo")

# On-demand
if has_spend:
    if show_requests:
        print("---")
    spend_bar = "█" * int(20 * min(spend_pct, 100) / 100) + "░" * (20 - int(20 * min(spend_pct, 100) / 100))
    print(f"{'On-Demand Usage' if total else 'Spend This Cycle'} | size=13")
    print(f"  ${spend_dollars:.2f} / ${limit_dollars:.0f}  ({spend_pct:.0f}%) | color={spend_color} size=13 font=Menlo")
    print(f"  {spend_bar} | size=11 font=Menlo color={spend_color}")

print("---")
print("Open Cursor Settings | href=https://cursor.com/settings size=13")
print("Source Code | href=https://github.com/edison-cc/cursor-usage size=13")
print("Refresh | refresh=true size=13")
PYEOF
