# Cursor Usage -- Data Sources and Metrics

> **Purpose**: This document catalogs all data sources from Cursor's local SQLite database
> and web dashboard APIs used by the cursor-usage scripts. It serves as a reference for
> developers working on enhancements.
> Load this file as context when working on cursor-usage changes.

## What the Scripts Show

### Menu bar plugin ([cursor-usage.5m.sh](../cursor-usage.5m.sh))

- **Included requests** with on-demand breakdown (e.g. (500+2)/500), percentage bar
- **Aggregate token count** for the billing cycle
- **On-demand spend**: dollars used / limit (team plans)
- **Plan type, email, billing cycle dates**

### Terminal report ([generate-report.sh](../generate-report.sh))

Everything the plugin shows, plus:

- **Daily AI code stats** -- lines suggested per day (Tab vs Composer)
- **Per-turn token distribution** -- input/output token histograms
- **Conversation analytics** -- mode split, context usage, lines changed, duration
- **Model preference** -- currently selected model
- **Session tenure** -- days since first use
- **Prompt count** -- cumulative total

### Data sources used

- `GET /api/usage` -- aggregate requests and tokens per billing cycle
- `GET /api/auth/stripe` -- plan info, team membership
- `POST /api/dashboard/get-team-spend` -- per-member spend (team only)
- Local SQLite databases (global + per-workspace) -- see Source A below

---

## Data Sources

### Source A: Local Database (zero network cost)

All data is SQLite. Query with `sqlite3` CLI or Python's `sqlite3` module.

**Global DB**: `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`

- Table `ItemTable` (key TEXT, value TEXT) -- key/value store with auth, settings, daily stats, telemetry
- Table `cursorDiskKV` (key BLOB, value BLOB) -- 53K+ rows of conversation blobs, per-turn token data

**Per-workspace DBs**: `~/Library/Application Support/Cursor/User/workspaceStorage/<hash>/state.vscdb`

- Same schema. Contains per-workspace composer sessions, AI generation logs.
- Each workspace has a `workspace.json` mapping the hash to a folder URI.

### Source B: Web Dashboard API (already authenticated via session cookie)

Base URL: `https://www.cursor.com`

Auth: Cookie `WorkosCursorSessionToken={userId}::{accessToken}` (extracted from local DB; `userId` is the JWT `sub` claim).

`cursorAuth/accessToken` is a plain JWT on older Cursor builds. Newer builds encrypt it at rest
(`cursor.storage.authTokenEncryptionAtRest` = `true`) as `cursor-safe-storage:v1:` + base64 of an
Electron `safeStorage` blob, which must be decrypted first:

- **Key:** PBKDF2-SHA1 of the "Cursor Safe Storage" Keychain password (salt `saltysalt`, 1003 iterations, 16 bytes). Some installs have two items under that service (accounts `Cursor` and `Cursor Key`); the scripts try both and keep the one that decrypts to a JWT.
- **Blob after base64:** `v10` + AES-128-CBC ciphertext (IV = 16 spaces, PKCS#7).

A rejected session returns HTTP 401 with `{"error":"not_authenticated", ...}`.

- `GET /api/usage` -- aggregate requests and tokens per billing cycle
- `GET /api/auth/stripe` -- plan info, team membership
- `POST /api/dashboard/get-team-spend` -- per-member spend (team only)

---

## Terminology

- **"composer"** in the DB refers to a **conversation session** (the chat/agent panel), not a model. Each composer has a `composerId`, name, timestamps, and line-change stats.
- **"bubble"** is a single turn (message) within a conversation. Type 1 = user, type 2 = assistant.
- **"Tab" vs "Composer"** distinguishes the *source* of AI code suggestions -- Tab autocomplete vs agent/chat panel.
- **`contextUsagePercent`** is **per-conversation** -- the fraction of the model's context window that conversation consumed. It is a snapshot, not a live value.
- **`gpt-4`** in the `/api/usage` response is a misleading key name -- it is the **aggregate across all models**, not GPT-4 specifically.

---

## Metrics Used by generate-report.sh

These metrics are read from local databases and used in the terminal report.

### Average Tokens per Request (Source B)

Derived from the API response: `numTokens / numRequests`.

Example: 50M tokens / 200 requests = ~250K tokens/request. Indicates how "heavy" each interaction is on average.

### Per-Turn Token Breakdown (Source A -- global DB)

The `cursorDiskKV` table stores per-bubble `tokenCount` with `inputTokens` (context sent to model) and `outputTokens` (model response).

Typical distribution:

- Input tokens per turn: median ~**66K**, P90 ~**130K**, max ~**180K**
- Output tokens per turn: median ~**2K**, P90 ~**6K**, max ~**300K**
- **Input:Output ratio is ~19:1** -- context dominates token usage
- Most turns land in the 25K-150K input token range

Query:

```sql
SELECT value FROM cursorDiskKV
WHERE value LIKE '{%'
  AND value LIKE '%"inputTokens":%'
  AND value NOT LIKE '%"inputTokens":0,%'
```

Each matching row is JSON with structure:

```json
{
  "tokenCount": {"inputTokens": 65000, "outputTokens": 2000},
  "bubbleId": "uuid",
  "type": 2
}
```

**Performance note**: linking bubbles back to specific conversations requires scanning all blob rows. Aggregate stats are fast; per-conversation rollups take 30+ seconds.

### Daily AI Code Stats (Source A -- global DB)

Key pattern: `aiCodeTracking.dailyStats.v1.5.YYYY-MM-DD`

```json
{
  "date": "2026-01-15",
  "tabSuggestedLines": 0,
  "composerSuggestedLines": 100
}
```

Each day records lines suggested via Tab autocomplete vs the Composer panel. Data spans back months. Useful for daily activity trend / sparkline.

**Note on suggested vs accepted fields**: The DB also stores `tabAcceptedLines` and `composerAcceptedLines`, but these are unreliable -- Cursor's agent mode applies code changes directly without requiring an explicit "accept" click, so the accepted count does not reflect actual usage.

### Conversation-Level Metadata (Source A -- per-workspace DBs)

Key: `composer.composerData` in each workspace's `state.vscdb`.

Each composer entry has these fields:

- `composerId` -- unique ID
- `name` -- auto-generated conversation title
- `unifiedMode` -- `agent`, `chat`, `plan`, or `debug`
- `contextUsagePercent` -- how full the context window got
- `totalLinesAdded` / `totalLinesRemoved` -- code impact
- `filesChangedCount` -- scope of changes
- `createdAt` / `lastUpdatedAt` -- epoch ms timestamps (duration derivable)
- `isArchived`, `isDraft`, `isWorktree`, `isSpec`, `isProject`
- `committedToBranch` / `createdOnBranch` / `activeBranch`
- `numSubComposers` -- sub-agent count

### Model Preference (Source A -- global DB)

Key: `cursor/lastSingleModelPreference`

```json
{"composer": "claude-4.6-opus-high-thinking"}
```

Only shows current selection, not per-turn history.

### Session Tenure (Source A -- global DB)

- `telemetry.firstSessionDate` -- first Cursor use ever
- `telemetry.lastSessionDate` / `telemetry.currentSessionDate` -- recent sessions
- `cursorAuth/onboardingDate` -- account creation date

Useful for "Using Cursor for N days" display.

### Prompt Count (Source A -- global DB)

Key: `freeBestOfN.promptCount` -- cumulative prompt count.

---

## Available but Unused Metrics

These data sources exist but are not currently used by either script.

### AI Code Attribution (Source A -- global DB)

Key: `aiCodeTracking.recentCommit`

```json
{"commitHash": "...", "aiPercentage": "100.00", "composerLinesAdded": 300}
```

Shows what fraction of the most recent commit was AI-generated.

### Team-Level Insights (Source B -- in API response but not parsed)

The `/api/dashboard/get-team-spend` response includes fields not currently used:

- `totalMembers` -- team size
- `limitedUserCount` -- users who hit their spend limit
- `maxUserSpendCents` -- highest spender on team
- `hasAnySpendLimitOverrides`
- `nextCycleStart` -- next billing cycle start

---

## Observations and Caveats

- **No per-model breakdown** exists in the local DB or web dashboard API.
- **The API `numTokens` can be roughly 2x the local bubble total** -- the gap likely comes from garbage-collected blobs, older conversations, or interactions not stored as bubbles.
- **Bubble-to-conversation linking is expensive** -- the main conversation blob references bubble IDs via `fullConversationHeadersOnly`, and each bubble's token data is stored separately in `agentKv:blob:*` rows. A full join scans 53K+ rows.
- **Accepted lines metrics are unreliable** -- Cursor's agent mode applies changes directly without explicit user acceptance, making `*AcceptedLines` fields inaccurate.

