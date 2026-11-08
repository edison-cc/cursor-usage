#!/usr/bin/env bash
# generate-report.sh — comprehensive Cursor usage report
#
# Usage:
#   bash generate-report.sh
#   bash generate-report.sh --no-color        # disable ANSI colors
#   bash generate-report.sh > report.txt      # save to file (colors auto-disabled)
#
# Prerequisites:
#   Cursor IDE must be installed and signed in on this machine.
#   Requires: sqlite3 and curl (both ship with macOS), and python3 from the
#   Xcode Command Line Tools.

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
  COOKIE_JAR=$(mktemp "${TMPDIR:-/tmp}/cursor-usage-report-cookie.XXXXXX") || return 1
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

echo "Fetching data from Cursor API..." >&2

STRIPE=$(api_get "https://www.cursor.com/api/auth/stripe")
TEAM_ID=$(echo "$STRIPE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('teamId',''))" 2>/dev/null)

USAGE=$(api_get "https://www.cursor.com/api/usage")
API_ERROR=$(printf '%s' "$USAGE" | api_error_message)
if [ -n "$API_ERROR" ]; then
  echo "ERROR: $API_ERROR" >&2
  exit 1
fi

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
API_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cursor-usage-report-api.XXXXXX")
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

export EMAIL DB

NO_COLOR=""
if [[ "${1:-}" == "--no-color" ]]; then
  NO_COLOR="1"
fi
export NO_COLOR

python3 << 'PYEOF'
import json, os, sys, datetime, sqlite3, glob

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------

_is_tty = sys.stdout.isatty() and not os.environ.get("NO_COLOR")

def _c(code):
    return code if _is_tty else ""

GREEN   = _c("\033[32m")
YELLOW  = _c("\033[33m")
RED     = _c("\033[31m")
CYAN    = _c("\033[36m")
BLUE    = _c("\033[34m")
MAGENTA = _c("\033[35m")
BOLD    = _c("\033[1m")
DIM     = _c("\033[2m")
RESET   = _c("\033[0m")

def pct_color(pct):
    if pct >= 80: return RED
    if pct >= 50: return YELLOW
    return GREEN

W = 70

def header(title, subtitle=""):
    print(f"\n{BOLD}{CYAN}{title}{RESET}  {DIM}{subtitle}{RESET}")
    print(f"{DIM}{'─' * W}{RESET}")

def bar(filled_pct, width=30, color=""):
    f = int(width * min(filled_pct, 100) / 100)
    return f"{color}{'█' * f}{RESET}{'░' * (width - f)}"

def histogram_bar(pct, max_width=30):
    f = max(1, int(max_width * pct / 100)) if pct > 0 else 0
    return "█" * f

# ---------------------------------------------------------------------------
# Load API data from env
# ---------------------------------------------------------------------------

def safe_load(s):
    try:    return json.loads(s)
    except: return {}

def load_api_json(name):
    try:
        with open(os.path.join(os.environ["CURSOR_USAGE_API_DIR"], name), encoding="utf-8") as f:
            return safe_load(f.read())
    except (KeyError, OSError):
        return {}

usage      = load_api_json("usage.json")
stripe     = load_api_json("stripe.json")
spend_data = load_api_json("spend.json")
email      = os.environ.get("EMAIL", "")
db_path    = os.environ.get("DB", "")

gpt4       = usage.get("gpt-4") or {}
used       = gpt4.get("numRequests") or 0
total      = gpt4.get("maxRequestUsage") or 0
tokens     = gpt4.get("numTokens") or 0
start_str  = usage.get("startOfMonth", "")
membership = stripe.get("membershipType", "unknown")
team_id    = stripe.get("teamId", "")

members    = spend_data.get("teamMemberSpend", [])
me         = next((m for m in members if m.get("email", "").lower() == email.lower()), None)
# Usage-based plans (maxRequestUsage null) have no included requests: all usage
# is billed and reported as overallSpendCents. Zero-valued fields are omitted.
spend_key  = "spendCents" if total else "overallSpendCents"
spend_cents = 0
limit_dollars = 0
has_spend  = False
if me and (spend_key in me or not total):
    has_spend = True
    spend_cents = me.get(spend_key, 0)
    limit_dollars = me.get("effectivePerUserLimitDollars", me.get("hardLimitOverrideDollars", 0))

spend_dollars = spend_cents / 100

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
has_included = included_pct is not None and not total and not has_spend

# ---------------------------------------------------------------------------
# Load local DB data
# ---------------------------------------------------------------------------

def db_connect(path):
    conn = sqlite3.connect(path)
    conn.text_factory = str
    return conn

def query_kv(conn, key):
    cur = conn.execute("SELECT value FROM ItemTable WHERE key = ?", (key,))
    row = cur.fetchone()
    return row[0] if row else None

daily_stats = []
model_pref = ""
prompt_count = 0
first_session = ""
if db_path and os.path.exists(db_path):
    conn = db_connect(db_path)

    for key, val in conn.execute(
        "SELECT key, value FROM ItemTable WHERE key LIKE 'aiCodeTracking.dailyStats.v1.5.%' ORDER BY key"
    ):
        try:    daily_stats.append(json.loads(val))
        except: pass

    raw = query_kv(conn, "cursor/lastSingleModelPreference")
    if raw:
        try:    model_pref = json.loads(raw).get("composer", raw)
        except: model_pref = raw

    raw = query_kv(conn, "freeBestOfN.promptCount")
    if raw:
        try:    prompt_count = int(raw)
        except: pass

    first_session = query_kv(conn, "telemetry.firstSessionDate") or ""

    # Per-turn token data
    print("Scanning local token data...", end="", flush=True, file=sys.stderr)
    input_tokens = []
    output_tokens = []
    for (val,) in conn.execute(
        "SELECT value FROM cursorDiskKV "
        "WHERE value LIKE '{%' "
        "AND value LIKE '%\"inputTokens\":%' "
        "AND value NOT LIKE '%\"inputTokens\":0,%'"
    ):
        try:
            tc = json.loads(val).get("tokenCount", {})
            inp = tc.get("inputTokens", 0)
            out = tc.get("outputTokens", 0)
            if inp > 0:
                input_tokens.append(inp)
                output_tokens.append(out)
        except:
            pass
    print(" done.", file=sys.stderr)

    conn.close()

# Workspace-level composer data
ws_base = os.path.expanduser(
    "~/Library/Application Support/Cursor/User/workspaceStorage"
)
all_composers = []
if os.path.isdir(ws_base):
    for ws in os.listdir(ws_base):
        ws_db = os.path.join(ws_base, ws, "state.vscdb")
        if not os.path.exists(ws_db):
            continue
        try:
            wconn = db_connect(ws_db)
            raw = query_kv(wconn, "composer.composerData")
            wconn.close()
            if raw:
                cd = json.loads(raw)
                all_composers.extend(cd.get("allComposers", []))
        except:
            pass

# ---------------------------------------------------------------------------
# Derived metrics
# ---------------------------------------------------------------------------

quota_reached = total > 0 and (used >= total or (has_spend and spend_cents > 0))
display_used = total if quota_reached else used
show_requests = bool(total) or (not has_spend and not has_included)
req_pct = (display_used / total * 100) if total else 0
spend_pct = (spend_dollars / limit_dollars * 100) if limit_dollars else 0
avg_tokens = tokens // used if used else 0

cycle_str = ""
if has_included and period_start and period_end:
    cycle_str = f"{period_start.strftime('%b %d')} -> {period_end.strftime('%b %d, %Y')}"
    if period_label:
        cycle_str += f" ({period_label})"
elif start_str:
    try:
        start_dt = datetime.datetime.fromisoformat(start_str.replace("Z", "+00:00"))
        end_dt = start_dt.replace(
            year=start_dt.year + (1 if start_dt.month == 12 else 0),
            month=(start_dt.month % 12) + 1,
        )
        cycle_str = f"{start_dt.strftime('%b %d')} -> {end_dt.strftime('%b %d, %Y')}"
    except:
        pass

days_using = 0
if first_session:
    try:
        from email.utils import parsedate_to_datetime
        first_dt = parsedate_to_datetime(first_session)
        days_using = (datetime.datetime.now(datetime.timezone.utc) - first_dt).days
    except:
        pass

# Conversation stats
modes = {}
ctx_pcts = []
total_lines_added = 0
total_lines_removed = 0
total_files_changed = 0
durations = []
for c in all_composers:
    m = c.get("unifiedMode", "unknown")
    modes[m] = modes.get(m, 0) + 1
    cp = c.get("contextUsagePercent", 0)
    if cp: ctx_pcts.append(cp)
    total_lines_added += c.get("totalLinesAdded", 0)
    total_lines_removed += c.get("totalLinesRemoved", 0)
    total_files_changed += c.get("filesChangedCount", 0)
    created = c.get("createdAt", 0)
    updated = c.get("lastUpdatedAt", 0)
    if created and updated and updated > created:
        durations.append((updated - created) / 60000)

ctx_pcts.sort()
durations.sort()

def percentile(arr, p):
    if not arr: return 0
    i = int(len(arr) * p / 100)
    return arr[min(i, len(arr) - 1)]

# Token stats
input_tokens.sort()
output_tokens.sort()
n_turns = len(input_tokens)

# ===========================================================================
# Render report
# ===========================================================================

now_str = datetime.datetime.now().strftime("%b %d, %Y %I:%M %p")

print()
print(f"{BOLD}{'═' * W}{RESET}")
print(f"{BOLD}{'CURSOR USAGE REPORT':^{W}}{RESET}")
print(f"{DIM}{email:^{W}}{RESET}")
print(f"{DIM}{('Generated: ' + now_str):^{W}}{RESET}")
print(f"{BOLD}{'═' * W}{RESET}")

# --- Billing Cycle --------------------------------------------------------

header("BILLING CYCLE", f"{cycle_str}    Plan: {membership}")

if has_included:
    ic = pct_color(included_pct)
    inc_label = "Included Usage"
    if period_label:
        inc_label += f" ({period_label})"
    print(f"  {inc_label:<20}{BOLD}{ic}{included_pct:.0f}%{RESET}")
    print(f"  [{bar(included_pct, 30, ic)}] {ic}{included_pct:.0f}%{RESET}")

if show_requests:
    rc = pct_color(req_pct)
    print(f"  Included Requests   {BOLD}{rc}{display_used} / {total}{RESET}  {rc}({req_pct:.0f}%){RESET}")
    print(f"  [{bar(req_pct, 30, rc)}] {rc}{req_pct:.0f}%{RESET}")

if has_spend:
    sc = pct_color(spend_pct)
    if show_requests:
        print()
    spend_label = "On-Demand Spend" if total else "Spend This Cycle"
    print(f"  {spend_label:<20}{BOLD}{sc}${spend_dollars:.2f} / ${limit_dollars:.0f}{RESET}  {sc}({spend_pct:.0f}%){RESET}")
    print(f"  [{bar(spend_pct, 30, sc)}] {sc}{spend_pct:.0f}%{RESET}")

if show_requests:
    print()
    print(f"  Tokens this cycle   {BOLD}{tokens:,}{RESET}")
    print(f"  Avg tokens/request  {BOLD}{avg_tokens:,}{RESET}")

# --- Token Usage ----------------------------------------------------------

header("TOKEN USAGE", f"({n_turns} turns with data)")

if n_turns > 0:
    buckets = [
        (0, 10000), (10000, 25000), (25000, 50000), (50000, 75000),
        (75000, 100000), (100000, 150000), (150000, 200000),
    ]
    max_in_bucket = max(
        sum(1 for t in input_tokens if lo <= t < hi) for lo, hi in buckets
    )

    print("  Input tokens per turn:")
    for lo, hi in buckets:
        cnt = sum(1 for t in input_tokens if lo <= t < hi)
        pct = cnt / n_turns * 100 if n_turns else 0
        bar_w = int(30 * cnt / max_in_bucket) if max_in_bucket else 0
        print(f"    {lo//1000:>3}K-{hi//1000:>3}K  {BLUE}{'█' * bar_w}{RESET}{'·' * (30 - bar_w)}  {pct:4.0f}%  {DIM}({cnt}){RESET}")

    print()
    print(f"  Output tokens per turn:")
    print(
        f"    {DIM}Min:{RESET} {min(output_tokens):,}  "
        f"{DIM}P25:{RESET} {percentile(output_tokens, 25):,}  "
        f"{DIM}Median:{RESET} {BOLD}{percentile(output_tokens, 50):,}{RESET}  "
        f"{DIM}P75:{RESET} {percentile(output_tokens, 75):,}  "
        f"{DIM}P90:{RESET} {percentile(output_tokens, 90):,}"
    )

    total_in = sum(input_tokens)
    total_out = sum(output_tokens)
    ratio = total_in // total_out if total_out else 0
    print(f"\n  Input:Output ratio   {BOLD}{ratio}:1{RESET}")
else:
    print(f"  {DIM}No per-turn token data found in local DB.{RESET}")

# --- Daily Activity -------------------------------------------------------

header("DAILY ACTIVITY", f"(last 14 days)")

recent_daily = daily_stats[-14:] if daily_stats else []
if recent_daily:
    max_lines = max(
        (s.get("composerSuggestedLines", 0) + s.get("tabSuggestedLines", 0))
        for s in recent_daily
    )
    print("  Lines suggested (Tab + Composer):")
    for s in recent_daily:
        d = s.get("date", "")
        lines = s.get("composerSuggestedLines", 0) + s.get("tabSuggestedLines", 0)
        bw = int(30 * lines / max_lines) if max_lines else 0
        try:
            label = datetime.datetime.strptime(d, "%Y-%m-%d").strftime("%b %d")
        except:
            label = d
        print(f"    {label}  {BLUE}{'█' * bw}{RESET}{'·' * (30 - bw)}  {lines:>6,}")
else:
    print(f"  {DIM}No daily stats found in local DB.{RESET}")

# --- Conversations --------------------------------------------------------

header("CONVERSATIONS", f"({len(all_composers)} across all workspaces)")

if all_composers:
    mode_order = ["agent", "chat", "plan", "debug"]
    mode_total = sum(modes.values())
    max_mode_count = max(modes.values()) if modes else 1

    print("  Mode split:")
    mode_colors = {"agent": CYAN, "chat": GREEN, "plan": MAGENTA, "debug": YELLOW}
    for m in mode_order:
        cnt = modes.get(m, 0)
        if cnt == 0: continue
        pct = cnt / mode_total * 100
        bw = int(30 * cnt / max_mode_count) if max_mode_count else 0
        mc = mode_colors.get(m, "")
        print(f"    {m:<8} {mc}{'█' * bw}{RESET}{'·' * (30 - bw)}  {BOLD}{cnt:>4}{RESET}  {DIM}({pct:.0f}%){RESET}")
    for m, cnt in sorted(modes.items(), key=lambda x: -x[1]):
        if m not in mode_order and cnt > 0:
            pct = cnt / mode_total * 100
            bw = int(30 * cnt / max_mode_count) if max_mode_count else 0
            print(f"    {m:<8} {'█' * bw}{'·' * (30 - bw)}  {BOLD}{cnt:>4}{RESET}  {DIM}({pct:.0f}%){RESET}")

    if ctx_pcts:
        print()
        print("  Context window usage:")
        max_ctx = max(ctx_pcts)
        high_ctx = sum(1 for p in ctx_pcts if p > 80)
        print(
            f"    {DIM}Min:{RESET} {min(ctx_pcts):.1f}%  "
            f"{DIM}P25:{RESET} {percentile(ctx_pcts, 25):.1f}%  "
            f"{DIM}Median:{RESET} {BOLD}{percentile(ctx_pcts, 50):.1f}%{RESET}  "
            f"{DIM}P75:{RESET} {percentile(ctx_pcts, 75):.1f}%  "
            f"{DIM}Max:{RESET} {RED if max_ctx > 80 else ''}{max_ctx:.1f}%{RESET}"
        )
        if high_ctx:
            print(f"    {DIM}Conversations >80%:{RESET} {YELLOW}{high_ctx}{RESET}")

    print()
    print("  Code impact:")
    print(f"    Lines added:    {GREEN}{total_lines_added:,}{RESET}")
    print(f"    Lines removed:  {RED}{total_lines_removed:,}{RESET}")
    print(f"    Files changed:  {total_files_changed:,}")

    if durations:
        median_dur = percentile(durations, 50)
        long_convos = sum(1 for d in durations if d > 60)
        print()
        print("  Duration:")
        print(f"    {DIM}Median:{RESET} {BOLD}{median_dur:.1f} min{RESET}    {DIM}>60 min:{RESET} {long_convos} conversations")
else:
    print(f"  {DIM}No composer data found in workspace DBs.{RESET}")

# --- Account --------------------------------------------------------------

header("ACCOUNT")

if model_pref:
    print(f"  Current model:    {BOLD}{model_pref}{RESET}")
if prompt_count:
    print(f"  Total prompts:    {BOLD}{prompt_count:,}{RESET}")
if days_using:
    try:
        since_str = parsedate_to_datetime(first_session).strftime("%b %d, %Y")
    except:
        since_str = first_session
    print(f"  Using Cursor for: {BOLD}{days_using} days{RESET}  {DIM}(since {since_str}){RESET}")
print()
print(f"{BOLD}{'═' * W}{RESET}")
print()
PYEOF
