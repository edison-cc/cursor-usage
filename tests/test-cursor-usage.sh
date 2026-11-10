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
            fail("Keychain access to Cursor Safe Storage was denied — allow it, then retry")
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

# The session cookie stays in a 0600 file. curl then reads that file, so the
# token is not visible in the process list.
cleanup() {
  if [ -n "${API_DIR:-}" ]; then rm -rf "$API_DIR"; fi
  if [ -n "${COOKIE_JAR:-}" ]; then rm -f "$COOKIE_JAR"; fi
}
trap cleanup EXIT INT HUP TERM

write_cookie_jar() {
  COOKIE_JAR=$(mktemp "${TMPDIR:-/tmp}/cursor-usage-test-cookie.XXXXXX") || return 1
  chmod 600 "$COOKIE_JAR" || return 1
  {
    printf '%s\n' '# Netscape HTTP Cookie File'
    printf '.cursor.com\tTRUE\t/\tTRUE\t0\tWorkosCursorSessionToken\t%s\n' \
      "${1#WorkosCursorSessionToken=}"
  } > "$COOKIE_JAR"
}

ACCESS_TOKEN=$(sqlite3 "$DB" "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken';")
if [ -z "$ACCESS_TOKEN" ]; then
  echo "ERROR: No access token found in DB. Are you signed in to Cursor?"
  exit 1
fi

if ! COOKIE=$(session_cookie "$ACCESS_TOKEN"); then
  echo "ERROR: $COOKIE"
  exit 1
fi
if ! write_cookie_jar "$COOKIE"; then
  echo "ERROR: Could not store the session cookie"
  exit 1
fi
unset COOKIE ACCESS_TOKEN

EMAIL=$(sqlite3 "$DB" "SELECT value FROM ItemTable WHERE key = 'cursorAuth/cachedEmail';")

api_get() {
  curl -sL --max-time 15 -b "$COOKIE_JAR" "$1"
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
    -b "$COOKIE_JAR" "$1"
}

echo "=== Cursor Usage ==="
echo ""

STRIPE=$(api_get "https://www.cursor.com/api/auth/stripe")
TEAM_ID=$(echo "$STRIPE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('teamId',''))" 2>/dev/null)

USAGE=$(api_get "https://www.cursor.com/api/usage")
API_ERROR=$(printf '%s' "$USAGE" | api_error_message)
if [ -n "$API_ERROR" ]; then
  echo "ERROR: $API_ERROR"
  exit 1
fi

# Included-usage plans have no request quota. /api/usage then stays at 0/null.
# The dashboard card uses the weekly included cents from usage-status; the
# current period endpoint is the fallback when that meter is absent.
PERIOD=$(api_post "https://www.cursor.com/api/dashboard/get-current-period-usage" "{}")
PLAN=$(api_post "https://www.cursor.com/api/dashboard/get-plan-info" "{}")
STATUS=$(api_get "https://www.cursor.com/api/dashboard/v2/usage-status?scope=user")

SPEND_JSON=""
if [ -n "$TEAM_ID" ]; then
  SPEND_JSON=$(api_post "https://www.cursor.com/api/dashboard/get-team-spend" "{\"teamId\":$TEAM_ID}")
fi

# Team spend JSON lists every member and can exceed ARG_MAX, so API responses
# go through files instead of the environment.
API_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cursor-usage-test-api.XXXXXX")
printf '%s' "$STRIPE" > "$API_DIR/stripe.json"
printf '%s' "$USAGE" > "$API_DIR/usage.json"
if [ -n "$SPEND_JSON" ]; then
  printf '%s' "$SPEND_JSON" > "$API_DIR/spend.json"
else
  printf '%s' '{}' > "$API_DIR/spend.json"
fi
# ${var:-{}} is not a safe "{}" default: the first } closes the expansion
# and the second is written literally, which breaks JSON parsing.
if [ -n "$PERIOD" ]; then printf '%s' "$PERIOD" > "$API_DIR/period.json"; else printf '%s' '{}' > "$API_DIR/period.json"; fi
if [ -n "$PLAN" ]; then printf '%s' "$PLAN" > "$API_DIR/plan.json"; else printf '%s' '{}' > "$API_DIR/plan.json"; fi
if [ -n "$STATUS" ]; then printf '%s' "$STATUS" > "$API_DIR/status.json"; else printf '%s' '{}' > "$API_DIR/status.json"; fi
export CURSOR_USAGE_API_DIR="$API_DIR"

export EMAIL

python3 << 'PYEOF'
import json, os, datetime

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

gpt4 = usage.get("gpt-4") or {}
used = gpt4.get("numRequests") or 0
total = gpt4.get("maxRequestUsage") or 0
tokens = gpt4.get("numTokens") or 0
start_str = usage.get("startOfMonth", "")
membership = stripe.get("membershipType", "unknown")
team_id = stripe.get("teamId", "")

def epoch_ms(value):
    try:
        n = int(value)
    except (TypeError, ValueError):
        return None
    if n < 10 ** 11:
        return None
    return datetime.datetime.fromtimestamp(n / 1000, datetime.timezone.utc)

period = load_api_json("period.json")
plan_info = (load_api_json("plan.json").get("planInfo") or {})
plan_usage = period.get("planUsage") or {}
included_pct = plan_usage.get("totalPercentUsed")
if included_pct is None:
    included_pct = plan_usage.get("autoPercentUsed")
try:
    included_pct = float(included_pct) if included_pct is not None else None
except (TypeError, ValueError):
    included_pct = None
period_start = epoch_ms(period.get("billingCycleStart"))
period_end = epoch_ms(period.get("billingCycleEnd")) or epoch_ms(plan_info.get("includedUsageResetsAt"))
usage_period = str(plan_info.get("includedUsagePeriod") or "")
if "WEEK" in usage_period:
    period_label = "weekly"
elif "MONTH" in usage_period:
    period_label = "monthly"
else:
    period_label = ""

def parse_iso(value):
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        dt = datetime.datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    return dt

PRODUCT_LABELS = {
    "chat": "Chat",
    "imagine": "Imagine",
    "grok-build": "Grok Build",
    "voice": "Voice",
    "api": "API",
    "app-builder": "App Builder",
    "automations": "Automations",
    "plugins": "Plugins",
    "grok-bot": "Grok Bot",
    "cursor": "Cursor",
    "bugbot": "Bugbot",
    "other": "Other",
}
PRODUCT_ALIASES = {
    "grok-chat": "chat",
    "grok-imagine": "imagine",
    "grok-build": "grok-build",
    "grok-voice": "voice",
    "grok-api": "api",
    "api": "api",
    "grok-app-builder": "app-builder",
    "grok-tasks": "automations",
    "grok-plugins": "plugins",
    "grok-bot": "grok-bot",
    "sand": "grok-bot",
    "cursor": "cursor",
    "bugbot": "bugbot",
}
PRODUCT_ORDER = list(PRODUCT_LABELS)

def included_product_split(percent_used, by_product):
    # Largest remainder against the floored total, so the labels add up to it.
    totals = {}
    for item in by_product or []:
        if not isinstance(item, dict):
            continue
        try:
            cents = float(item.get("cents"))
        except (TypeError, ValueError):
            continue
        if cents <= 0:
            continue
        key = PRODUCT_ALIASES.get(str(item.get("product") or ""), "other")
        totals[key] = totals.get(key, 0.0) + cents
    total_cents = sum(totals.values())
    shown = shown_included_pct(percent_used)
    if shown <= 0 or total_cents <= 0:
        return []
    rows = []
    for key, cents in totals.items():
        share = cents / total_cents * shown
        floored = int(share)
        rows.append({"product": key, "percent": floored, "remainder": share - floored})
    leftover = shown - sum(row["percent"] for row in rows)
    for row in sorted(rows, key=lambda row: row["remainder"], reverse=True):
        if leftover <= 0:
            break
        row["percent"] += 1
        leftover -= 1
    visible = [row for row in rows if row["percent"] > 0]
    visible.sort(key=lambda row: (
        row["product"] == "other",
        -row["percent"],
        PRODUCT_ORDER.index(row["product"]) if row["product"] in PRODUCT_ORDER else len(PRODUCT_ORDER),
    ))
    return [(PRODUCT_LABELS.get(row["product"], "Other"), row["percent"]) for row in visible]

# The dashboard card divides weekly included cents. The period percent is the
# fallback when that meter is absent.
status = load_api_json("status.json")
weekly = status.get("weeklyIncludedUsage") if isinstance(status, dict) else None
weekly_state = status.get("weeklyIncludedStatus") if isinstance(status, dict) else None
weekly_status = weekly_state.get("status") if isinstance(weekly_state, dict) else None
product_usage = status.get("weeklyIncludedUsageByProduct") if isinstance(status, dict) else None
if not isinstance(product_usage, list):
    product_usage = []
if weekly_status == "metered" and isinstance(weekly, dict):
    try:
        used_cents = float(weekly.get("usedCents"))
        budget_cents = float(weekly.get("budgetCents"))
    except (TypeError, ValueError):
        used_cents = budget_cents = None
    if budget_cents and budget_cents > 0 and used_cents is not None:
        included_pct = 100.0 * max(0.0, used_cents) / budget_cents
        weekly_start = parse_iso(weekly.get("periodStart"))
        weekly_end = parse_iso(weekly.get("resetsAt"))
        if weekly_start and weekly_end:
            period_start = weekly_start
            period_end = weekly_end
        period_label = "weekly"

print(f"User:  {email}")
print(f"Plan:  {membership}" + (f"  (team {team_id})" if team_id else ""))

# On-demand spend (enterprise/team plans only) is resolved before the cycle
# line so included-usage plans can show their own window.
members = spend_data.get("teamMemberSpend", [])
me = next((m for m in members if m.get("email", "").lower() == email.lower()), None)
# Usage-based plans (maxRequestUsage null) have no included requests: all usage
# is billed and reported as overallSpendCents. Zero-valued fields are omitted.
spend_key = "spendCents" if total else "overallSpendCents"
spend_cents = 0
has_spend = False
if me and (spend_key in me or not total):
    has_spend = True
    spend_cents = me.get(spend_key, 0)
has_included = included_pct is not None and not total and not has_spend

def shown_included_pct(pct):
    # The dashboard floors the included-usage integer. A fraction under 1%
    # still shows as 1%, so a little usage does not read as none.
    bounded = min(100.0, max(0.0, pct))
    if 0 < bounded < 1:
        return 1
    return int(bounded)

included_split = included_product_split(included_pct, product_usage) if has_included else []

if has_included and period_start and period_end:
    cycle = f"{period_start.strftime('%b %d')} → {period_end.strftime('%b %d, %Y')}"
    if period_label:
        cycle += f"  ({period_label})"
    print(f"Cycle: {cycle}")
elif start_str:
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

quota_reached = total > 0 and (used >= total or (has_spend and spend_cents > 0))
display_used = total if quota_reached else used
req_pct = (display_used / total * 100) if total else 0
filled = int(bar_len * min(req_pct, 100) / 100)
req_bar = "█" * filled + "░" * (bar_len - filled)

if has_included:
    filled = int(bar_len * min(included_pct, 100) / 100)
    inc_bar = "█" * filled + "░" * (bar_len - filled)
    label = "Included Usage:"
    if period_label:
        label = f"Included Usage ({period_label}):"
    print()
    shown_pct = shown_included_pct(included_pct)
    print(f"{label} {shown_pct}%")
    print(f"  [{inc_bar}] {shown_pct}%")
    if included_split:
        print("  " + " · ".join(f"{label} {pct}%" for label, pct in included_split))

if total or (not has_spend and not has_included):
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

    spend_label = "On-Demand Usage:" if total else "Spend This Cycle:"
    print()
    print(f"{spend_label:<20}${spend_dollars:.2f} / ${limit_dollars:.0f}")
    print(f"  [{spend_bar}] {spend_pct:.0f}%")
elif me:
    print()
    print("On-Demand Usage:    $0.00 (no on-demand charges yet)")
PYEOF

echo ""
