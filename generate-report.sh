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
#   Requires: sqlite3, curl, python3 (all ship with macOS).

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

echo "Fetching data from Cursor API..." >&2

STRIPE=$(api_get "https://www.cursor.com/api/auth/stripe")
TEAM_ID=$(echo "$STRIPE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('teamId',''))" 2>/dev/null)

USAGE=$(api_get "https://www.cursor.com/api/usage")

export SPEND_JSON=""
if [ -n "$TEAM_ID" ]; then
  export SPEND_JSON=$(api_post "https://www.cursor.com/api/dashboard/get-team-spend" "{\"teamId\":$TEAM_ID}")
fi

export USAGE STRIPE EMAIL DB

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

usage      = safe_load(os.environ.get("USAGE", "{}"))
stripe     = safe_load(os.environ.get("STRIPE", "{}"))
spend_data = safe_load(os.environ.get("SPEND_JSON", "{}"))
email      = os.environ.get("EMAIL", "")
db_path    = os.environ.get("DB", "")

gpt4       = usage.get("gpt-4", {})
used       = gpt4.get("numRequests", 0)
total      = gpt4.get("maxRequestUsage", 0)
tokens     = gpt4.get("numTokens", 0)
start_str  = usage.get("startOfMonth", "")
membership = stripe.get("membershipType", "unknown")
team_id    = stripe.get("teamId", "")

members    = spend_data.get("teamMemberSpend", [])
me         = next((m for m in members if m.get("email", "").lower() == email.lower()), None)
spend_cents = 0
limit_dollars = 0
has_spend  = False
if me and "spendCents" in me:
    has_spend = True
    spend_cents = me["spendCents"]
    limit_dollars = me.get("effectivePerUserLimitDollars", me.get("hardLimitOverrideDollars", 0))

spend_dollars = spend_cents / 100

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

quota_reached = (total > 0 and used >= total) or (has_spend and spend_cents > 0)
display_used = total if quota_reached else used
req_pct = (display_used / total * 100) if total else 0
spend_pct = (spend_dollars / limit_dollars * 100) if limit_dollars else 0
avg_tokens = tokens // used if used else 0

cycle_str = ""
if start_str:
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

rc = pct_color(req_pct)
print(f"  Included Requests   {BOLD}{rc}{display_used} / {total}{RESET}  {rc}({req_pct:.0f}%){RESET}")
print(f"  [{bar(req_pct, 30, rc)}] {rc}{req_pct:.0f}%{RESET}")

if has_spend:
    sc = pct_color(spend_pct)
    print()
    print(f"  On-Demand Spend     {BOLD}{sc}${spend_dollars:.2f} / ${limit_dollars:.0f}{RESET}  {sc}({spend_pct:.0f}%){RESET}")
    print(f"  [{bar(spend_pct, 30, sc)}] {sc}{spend_pct:.0f}%{RESET}")

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
