#!/usr/bin/env bash
# <xbar.title>Cursor Usage</xbar.title>
# <xbar.version>v1.0</xbar.version>
# <xbar.desc>Shows Cursor usage in the menu bar: included usage, request quota, or on-demand spend</xbar.desc>

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:$PATH"

DB="$HOME/Library/Application Support/Cursor/User/globalStorage/state.vscdb"

# Cursor's menu-bar cube. SwiftBar 2.1.1 ignores templateImage, and its
# light/dark image pair does not follow this menu bar, so pick one tint from
# the system appearance. Loaded from the installed app so a later agent plugin
# can point the same helper at a different icon.
menu_icon_param() {
  python3 - << 'PY'
import base64, struct, zlib
from pathlib import Path

def find_icon():
    names = ("trayTemplate@2x.png", "trayTemplate.png")
    roots = [Path("/Applications/Cursor.app"), Path.home() / "Applications/Cursor.app"]
    for root in roots:
        base = root / "Contents/Resources/app/molten/dist/tray/darwin"
        for name in names:
            path = base / name
            if path.is_file():
                return path
    return None

def read_png(path):
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a png")
    pos = 8
    width = height = None
    raw = b""
    while pos + 8 <= len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        kind = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            width, height, bit, color = struct.unpack(">IIBB", chunk[:10])
            if bit != 8 or color != 6:
                raise ValueError("unsupported png")
        elif kind == b"IDAT":
            raw += chunk
        elif kind == b"IEND":
            break
    rows = []
    stride = width * 4
    decoded = zlib.decompress(raw)
    prev = bytearray(stride)
    i = 0
    for _ in range(height):
        filt = decoded[i]
        i += 1
        row = bytearray(decoded[i:i + stride])
        i += stride
        for x in range(stride):
            left = row[x - 4] if x >= 4 else 0
            up = prev[x]
            up_left = prev[x - 4] if x >= 4 else 0
            if filt == 0:
                pred = 0
            elif filt == 1:
                pred = left
            elif filt == 2:
                pred = up
            elif filt == 3:
                pred = (left + up) // 2
            elif filt == 4:
                p = left + up - up_left
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - up_left)
                pred = left if pa <= pb and pa <= pc else up if pb <= pc else up_left
            else:
                raise ValueError("bad png filter")
            row[x] = (row[x] + pred) & 255
        rows.append(row)
        prev = row
    return width, height, rows

def write_png(width, height, rows):
    def chunk(kind, payload):
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    raw = b"".join(b"\x00" + bytes(row) for row in rows)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")

def tint(rows, rgb):
    out = []
    for row in rows:
        tinted = bytearray(row)
        for x in range(0, len(row), 4):
            tinted[x:x + 3] = bytes(rgb)
        out.append(tinted)
    return out

path = find_icon()
if path is None:
    raise SystemExit(0)
width, height, rows = read_png(path)
appearance = __import__("subprocess").run(
    ["defaults", "read", "-g", "AppleInterfaceStyle"],
    capture_output=True, text=True,
).stdout.strip()
rgb = (255, 255, 255) if appearance == "Dark" else (0, 0, 0)
print(base64.b64encode(write_png(width, height, tint(rows, rgb))).decode())
PY
}

MENU_ICON=$(menu_icon_param)
export MENU_ICON

error_exit() {
  local icon=""
  if [ -n "$MENU_ICON" ]; then
    icon=" image=$MENU_ICON"
  fi
  echo "$(printf '\033[31m●\033[0m') err | ansi=true${icon}"
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

# The session cookie stays in a 0600 file. curl then reads that file, so the
# token is not visible in the process list.
cleanup() {
  if [ -n "${API_DIR:-}" ]; then rm -rf "$API_DIR"; fi
  if [ -n "${COOKIE_JAR:-}" ]; then rm -f "$COOKIE_JAR"; fi
}
trap cleanup EXIT INT HUP TERM

write_cookie_jar() {
  COOKIE_JAR=$(mktemp "${TMPDIR:-/tmp}/cursor-usage-5m-cookie.XXXXXX") || return 1
  chmod 600 "$COOKIE_JAR" || return 1
  {
    printf '%s\n' '# Netscape HTTP Cookie File'
    printf '.cursor.com\tTRUE\t/\tTRUE\t0\tWorkosCursorSessionToken\t%s\n' \
      "${1#WorkosCursorSessionToken=}"
  } > "$COOKIE_JAR"
}

ACCESS_TOKEN=$(sqlite3 "$DB" "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken';" 2>/dev/null)
[ -n "$ACCESS_TOKEN" ] || error_exit "No access token — sign in to Cursor"

COOKIE=$(session_cookie "$ACCESS_TOKEN") || error_exit "$COOKIE"
write_cookie_jar "$COOKIE" || error_exit "Could not store the session cookie"
unset COOKIE ACCESS_TOKEN

EMAIL=$(sqlite3 "$DB" "SELECT value FROM ItemTable WHERE key = 'cursorAuth/cachedEmail';" 2>/dev/null)

api_get() {
  curl -sL --max-time 15 -b "$COOKIE_JAR" "$1" 2>/dev/null
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
    -b "$COOKIE_JAR" "$1" 2>/dev/null
}

STRIPE=$(api_get "https://www.cursor.com/api/auth/stripe")
TEAM_ID=$(echo "$STRIPE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('teamId',''))" 2>/dev/null)

USAGE=$(api_get "https://www.cursor.com/api/usage")
API_ERROR=$(printf '%s' "$USAGE" | api_error_message)
[ -z "$API_ERROR" ] || error_exit "$API_ERROR"

# Included-usage plans have no request quota. /api/usage then stays at 0/null;
# the current period endpoint is what the dashboard percent comes from.
PERIOD=$(api_post "https://www.cursor.com/api/dashboard/get-current-period-usage" "{}")
PLAN=$(api_post "https://www.cursor.com/api/dashboard/get-plan-info" "{}")

SPEND_JSON=""
if [ -n "$TEAM_ID" ]; then
  SPEND_JSON=$(api_post "https://www.cursor.com/api/dashboard/get-team-spend" "{\"teamId\":$TEAM_ID}")
fi

# Team spend JSON lists every member and can exceed ARG_MAX, so API responses
# go through files instead of the environment.
API_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cursor-usage-5m-api.XXXXXX") || error_exit "mktemp failed"
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
export CURSOR_USAGE_API_DIR="$API_DIR"

DAILY_STATS=$(sqlite3 "$DB" \
  "SELECT value FROM ItemTable WHERE key LIKE 'aiCodeTracking.dailyStats.v1.5.%' ORDER BY key DESC LIMIT 14;" 2>/dev/null)
FIRST_SESSION=$(sqlite3 "$DB" \
  "SELECT value FROM ItemTable WHERE key = 'telemetry.firstSessionDate';" 2>/dev/null)
RECENT_COMMIT=$(sqlite3 "$DB" \
  "SELECT value FROM ItemTable WHERE key = 'aiCodeTracking.recentCommit';" 2>/dev/null)

export EMAIL DAILY_STATS FIRST_SESSION RECENT_COMMIT

python3 << 'PYEOF'
import json, os, datetime
from email.utils import parsedate_to_datetime

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
menu_icon = os.environ.get("MENU_ICON", "").strip()
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
# Request-quota and team-spend plans keep their existing meter.
has_included = included_pct is not None and not total and not has_spend

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

def bar20(pct):
    bounded = min(max(pct, 0), 100)
    filled = int(20 * bounded / 100)
    if pct > 0 and filled == 0:
        filled = 1
    return "█" * filled + "░" * (20 - filled)

def opt_pct(mapping, key):
    value = mapping.get(key) if isinstance(mapping, dict) else None
    if value is None or isinstance(value, bool):
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None

def as_dollars(key, value):
    # This API states cents in the field name. Other integer amounts at or
    # above 100 are also cents; smaller numbers and floats are already dollars.
    if "cent" in key.lower():
        return value / 100.0
    if isinstance(value, int) and abs(value) >= 100:
        return value / 100.0
    return float(value)

def numeric_field(mapping, key):
    if not isinstance(mapping, dict) or key not in mapping:
        return None
    value = mapping.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return value

def dollars_left(mapping):
    """Remaining allowance, only when planUsage actually carries spend and limit."""
    limit = None
    for key in ("limitCents", "includedLimitCents", "limit", "includedLimit"):
        raw = numeric_field(mapping, key)
        if raw is not None:
            limit = as_dollars(key, raw)
            break
    if limit is None or limit <= 0:
        return None
    for key in ("remainingCents", "remaining"):
        raw = numeric_field(mapping, key)
        if raw is not None:
            return max(0.0, as_dollars(key, raw))
    used = None
    for key in ("totalSpendCents", "includedSpendCents", "totalSpend", "includedSpend"):
        raw = numeric_field(mapping, key)
        if raw is not None:
            used = as_dollars(key, raw)
            break
    if used is None:
        return None
    return max(0.0, limit - used)

def money(amount):
    if abs(amount - round(amount)) < 0.005:
        return f"${amount:.0f}"
    return f"${amount:.2f}"

def duration_phrase(seconds):
    if seconds <= 0:
        return ""
    total_min = int(seconds // 60)
    days, rem = divmod(total_min, 60 * 24)
    hours, minutes = divmod(rem, 60)
    if days > 0:
        parts = [f"{days}d", f"{hours}h"]
        if minutes:
            parts.append(f"{minutes}m")
        return " ".join(parts)
    if hours > 0:
        return f"{hours}h" if minutes == 0 else f"{hours}h {minutes}m"
    if minutes > 0:
        return f"{minutes}m"
    return "<1m"

def menu_bar_remaining(seconds):
    if seconds <= 0:
        return ""
    total_min = int(seconds // 60)
    days, rem = divmod(total_min, 60 * 24)
    hours, minutes = divmod(rem, 60)
    if days > 0:
        return f"{days}d"
    if hours > 0:
        return f"{hours}h"
    if minutes > 0:
        return f"{minutes}m"
    return "<1m"

def parse_session_date(raw):
    raw = (raw or "").strip()
    if not raw:
        return None
    try:
        dt = datetime.datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        dt = None
    if dt is None:
        try:
            dt = parsedate_to_datetime(raw)
        except (TypeError, ValueError):
            dt = None
    if dt is None:
        try:
            dt = datetime.datetime.strptime(raw[:10], "%Y-%m-%d")
        except ValueError:
            return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    return dt

# --- Countdown to reset ---
now = datetime.datetime.now(datetime.timezone.utc)
countdown_str = ""
countdown_compact = ""
start_dt = None
end_dt = None

if has_included and period_start and period_end:
    start_dt = period_start
    end_dt = period_end
elif start_str:
    try:
        start_dt = datetime.datetime.fromisoformat(start_str.replace("Z", "+00:00"))
        if start_dt.month == 12:
            end_dt = start_dt.replace(year=start_dt.year + 1, month=1)
        else:
            end_dt = start_dt.replace(month=start_dt.month + 1)
    except:
        pass

remaining_s = None
if start_dt and end_dt:
    delta = end_dt - now
    remaining_s = delta.total_seconds()
    if remaining_s > 0:
        countdown_str = duration_phrase(remaining_s)
        countdown_compact = menu_bar_remaining(remaining_s)

# The meter that answers "will this run out?": included percent, else spend, else requests.
if has_included:
    usage_pct = included_pct
elif has_spend:
    usage_pct = spend_pct
elif total:
    usage_pct = req_pct
else:
    usage_pct = None

pace = None
projected = None
elapsed_frac = None
cycle_s = None
if start_dt and end_dt and usage_pct is not None:
    elapsed_s = (now - start_dt).total_seconds()
    cycle_s = (end_dt - start_dt).total_seconds()
    if cycle_s > 0 and elapsed_s > 0:
        elapsed_frac = elapsed_s / cycle_s
        if elapsed_frac > 0:
            pace = usage_pct / (elapsed_frac * 100)
            projected = usage_pct / elapsed_frac

def signal_pct(actual):
    # Early in the cycle, or after it has ended, a projection is not meaningful.
    if actual is None:
        return 0
    if remaining_s is not None and remaining_s <= 0:
        return actual
    if projected is None or elapsed_frac is None or elapsed_frac < 0.10:
        return actual
    return projected

forecast_text = ""
forecast_color = "#4CAF50"
cycle_open = remaining_s is None or remaining_s > 0
if usage_pct is not None and usage_pct >= 100:
    forecast_text, forecast_color = "The allowance is used up", "#ff4444"
elif cycle_open and pace is not None and elapsed_frac is not None and elapsed_frac >= 0.10:
    if pace < 0.95:
        forecast_text = f"At this pace you'll finish near {projected:.0f}%"
        forecast_color = "#4CAF50"
    elif pace < 1.2:
        forecast_text = "About on pace to use the full allowance"
        forecast_color = "#4CAF50" if pace < 1.05 else "#ffaa00"
    elif cycle_s:
        before = duration_phrase(cycle_s * (1 - 1 / pace))
        if before:
            forecast_text = f"At this pace you'll hit the limit about {before} before reset"
            forecast_color = "#ffaa00" if pace < 1.5 else "#ff4444"

daily_room = ""
if (
    usage_pct is not None
    and usage_pct < 100
    and remaining_s is not None
    and remaining_s > 0
):
    remaining_pct = max(0.0, 100 - usage_pct)
    if remaining_s >= 86400:
        daily_room = f"About {remaining_pct / (remaining_s / 86400):.0f}% per day still available"
    elif remaining_s >= 3600:
        daily_room = f"About {remaining_pct / (remaining_s / 3600):.0f}% per hour still available"
    else:
        per_min = remaining_pct / max(remaining_s / 60, 1 / 60)
        daily_room = f"About {per_min:.0f}% per minute still available"

auto_pct = opt_pct(plan_usage, "autoPercentUsed")
api_pct = opt_pct(plan_usage, "apiPercentUsed")
included_dollars_left = dollars_left(plan_usage) if has_included else None

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

# Install age comes from the first local session, not the account onboarding date.
install_since = ""
first_dt = parse_session_date(first_session_raw)
if first_dt is not None:
    install_since = first_dt.astimezone().strftime("%b %Y")

# --- AI code attribution ---
ai_pct_str = ""
recent_commit = safe_load(recent_commit_raw)
if recent_commit and "aiPercentage" in recent_commit:
    try:
        ai_pct_str = f"{float(recent_commit['aiPercentage']):.0f}%"
    except:
        pass

# ====== OUTPUT ======

def meter(title, value_line, color, bar):
    print(f"{title} | size=13")
    print(f"{value_line} | color={color} size=13 font=Menlo")
    print(f"{bar} | size=11 font=Menlo color={color}")

# Menu bar title. The dot follows the projected end-of-cycle usage.
if has_included:
    dot = pct_dot(signal_pct(included_pct))
    bar_text = f"{dot} {included_pct:.0f}%"
elif has_spend:
    dot = pct_dot(signal_pct(spend_pct))
    req_prefix = f"{total} · " if total else ""
    bar_text = f"{dot} {req_prefix}${spend_dollars:.0f}/${limit_dollars:.0f}"
else:
    dot = pct_dot(signal_pct(req_pct))
    bar_text = f"{dot} {display_used}/{total}"
if countdown_compact:
    bar_text += f" · {countdown_compact}"
icon_param = f" image={menu_icon} width=16 height=16" if menu_icon else ""
print(f"{bar_text} | size=13 ansi=true{icon_param}")

print("---")

# Included usage (percent plans) or included requests (quota plans)
show_requests = bool(total) or (not has_spend and not has_included)
if has_included:
    inc_color = pct_color(included_pct)
    used_shown = int(round(included_pct))
    left_shown = max(0, 100 - used_shown)
    value_line = f"{used_shown}% used · {left_shown}% left"
    if included_dollars_left is not None:
        value_line += f" · {money(included_dollars_left)} left"
    if period_label == "weekly":
        inc_title = "Included this week"
    elif period_label == "monthly":
        inc_title = "Included this month"
    else:
        inc_title = "Included usage"
    meter(inc_title, value_line, inc_color, bar20(included_pct))
if show_requests:
    req_used_shown = int(round(req_pct))
    req_left_shown = max(0, 100 - req_used_shown)
    meter(
        "Included Requests",
        f"{display_used} / {total} · {req_used_shown}% used · {req_left_shown}% left",
        req_color,
        bar20(req_pct),
    )
    print(f"Tokens: {tokens:,} | color=#888888 size=12 font=Menlo")

if has_spend:
    spend_used_shown = int(round(spend_pct))
    spend_left_shown = max(0, 100 - spend_used_shown)
    meter(
        "On-Demand Usage" if total else "Spend This Cycle",
        f"${spend_dollars:.2f} / ${limit_dollars:.0f} · {spend_used_shown}% used · {spend_left_shown}% left",
        spend_color,
        bar20(spend_pct),
    )

if end_dt is not None:
    when = end_dt.astimezone().strftime("%a, %b %-d, %-I:%M %p")
    reset_line = f"Resets {when}"
    if countdown_str:
        reset_line += f" · {countdown_str}"
    print(f"{reset_line} | color=#888888 size=12")
if forecast_text:
    print(f"{forecast_text} | color={forecast_color} size=12")
if daily_room:
    print(f"{daily_room} | color=#888888 size=12")
if has_included and auto_pct is not None and api_pct is not None:
    print(f"Auto {auto_pct:.0f}% · API {api_pct:.0f}% | size=12 font=Menlo")

print("---")

def display_plan(info, fallback):
    # planName is already "Premium" on current plans. membershipType is the
    # lowercase slug (premium, pro_plus), so title-case whichever we show.
    name = str((info or {}).get("planName") or "").strip()
    source = name or str(fallback or "unknown")
    words = []
    for word in source.replace("_", " ").replace("-", " ").split():
        plus = word.endswith("+")
        core = word[:-1] if plus else word
        words.append(core[:1].upper() + core[1:].lower() + ("+" if plus else ""))
    return " ".join(words) or "Unknown"

account = display_plan(plan_info, membership)
if email:
    account += f" · {email}"
print(f"{account} | color=#888888 size=12")
if install_since:
    print(f"On this Mac since {install_since} | color=#888888 size=12")
if sparkline:
    print(f"Activity (14d): {sparkline} | size=12 font=Menlo color=#888888")
if ai_pct_str:
    print(f"Last commit: {ai_pct_str} AI-generated | size=12 color=#888888")

print("---")
print("Open Cursor Settings | href=https://cursor.com/settings size=13")
print("Refresh | refresh=true size=13")
print("More | size=13")
print("--Source Code | href=https://github.com/edison-cc/cursor-usage size=13")
PYEOF
