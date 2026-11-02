# Cursor Usage

A macOS menu bar plugin that shows your Cursor IDE usage at a glance: included requests consumed and on-demand spend.

## Demo

The plugin displays your usage summary directly in the macOS menu bar. The dot color changes based on how much of your quota you've used:

| Green (< 50%) | Yellow (50–79%) | Red (80%+) |
|:-:|:-:|:-:|
| <img src="docs/assets/green-menubar.png" alt="Green menubar" width="90"> | <img src="docs/assets/yellow-menubar.png" alt="Yellow menubar" width="90"> | <img src="docs/assets/red-menubar.png" alt="Red menubar" width="90"> |
| <img src="docs/assets/green-dropdown.png" alt="Green dropdown" width="280"> | <img src="docs/assets/yellow-dropdown.png" alt="Yellow dropdown" width="280"> | <img src="docs/assets/red-dropdown.png" alt="Red dropdown" width="280"> |

## Prerequisites

- **macOS** (Catalina 10.15+)
- **Cursor IDE** — must be installed and signed in at least once
- **[SwiftBar](https://github.com/swiftbar/SwiftBar)**

## Installation

First, install SwiftBar if you haven't already:

```bash
brew install --cask swiftbar
```

Then pick one of the options below to install the plugin.

### Option A: Quick Install (curl)

```bash
mkdir -p ~/swiftbar-plugins
curl -fsSL \
  https://raw.githubusercontent.com/edison-cc/cursor-usage/main/cursor-usage.5m.sh \
  -o ~/swiftbar-plugins/cursor-usage.5m.sh
chmod +x ~/swiftbar-plugins/cursor-usage.5m.sh
```

### Option B: Clone + Symlink

Best for development or easy updates via `git pull`.

```bash
git clone https://github.com/edison-cc/cursor-usage.git
cd cursor-usage
mkdir -p ~/swiftbar-plugins
ln -sf "$(pwd)/cursor-usage.5m.sh" ~/swiftbar-plugins/cursor-usage.5m.sh
```

### After installing

Launch SwiftBar and select `~/swiftbar-plugins` as the plugin directory. You can open SwiftBar from the terminal (`open -a SwiftBar`), the Applications folder, or Spotlight (Cmd+Space and type "SwiftBar"):

If SwiftBar is already running and you need to change the directory:

```bash
defaults write com.ameba.SwiftBar PluginDirectory "$HOME/swiftbar-plugins"
```

Then restart SwiftBar.

The plugin will run immediately and refresh every **5 minutes** (based on the `5m` in the filename).

## Testing

Run the test script to verify API connectivity and auth without SwiftBar:

```bash
bash tests/test-cursor-usage.sh
```

This calls the same Cursor APIs as the plugin and prints a plain-text summary. If you see your usage data, everything is working correctly.

## Report

Generate a comprehensive usage report with metrics from both the Cursor API and local database:

```bash
bash generate-report.sh
```

The report includes: billing cycle overview, per-turn token distribution, daily activity trends, conversation analytics, AI code attribution, and account info. All output is terminal-based with colored ASCII charts -- no browser or dependencies needed.

Save to a file (colors are automatically disabled when piped):

```bash
bash generate-report.sh > report.txt
```

Use `--no-color` to explicitly disable colors:

```bash
bash generate-report.sh --no-color
```

For details on all available data sources and metrics, see [docs/data-sources.md](docs/data-sources.md).

## Customization

### Change refresh interval

Rename the plugin file. The interval is encoded in the filename:

```bash
mv cursor-usage.5m.sh cursor-usage.10m.sh   # every 10 minutes
mv cursor-usage.5m.sh cursor-usage.30s.sh   # every 30 seconds
mv cursor-usage.5m.sh cursor-usage.1h.sh    # every hour
```

Supported suffixes: `s` (seconds), `m` (minutes), `h` (hours), `d` (days).

## Troubleshooting

### Menu bar shows a red dot with "err"

Click it to see the error in the dropdown. Common causes:

- **"Cursor DB not found"** — Cursor IDE hasn't been opened on this machine, or is installed in a non-standard location.
- **"No access token"** — You're not signed in to Cursor. Open Cursor, sign in, then click Refresh.
- **"Keychain access to Cursor Safe Storage was denied"** — see [Keychain prompt](#keychain-prompt) below, then click Refresh.
- **"Cursor session expired"** — Cursor's API rejected the stored login. Open Cursor (signed in) so it refreshes the token, then click Refresh.
- **"Invalid Cursor token"** / **"Could not decrypt the Cursor token"** — Sign out of Cursor and back in.

### Keychain prompt

Newer Cursor builds encrypt the stored login token (setting `cursor.storage.authTokenEncryptionAtRest`). To decrypt it, the plugin reads the **Cursor Safe Storage** key from your login Keychain, so the first run shows a prompt asking to let `security` access it. Enter your login password and choose **Always Allow**; with **Allow**, the prompt returns on every refresh. Some Macs have two **Cursor Safe Storage** items (accounts `Cursor` and `Cursor Key`); if the first one doesn't decrypt the token, a second prompt appears for the other.

### Usage-based plans

On usage-based (token-based) plans there are no included requests, so the menu bar shows spend only (e.g. `$82/$1000`) and the dropdown labels it **Spend This Cycle**.

### Plugin doesn't appear in menu bar

- Verify SwiftBar is running (check for its icon in the menu bar).
- Confirm the plugin directory is set: `defaults read com.ameba.SwiftBar PluginDirectory`
- Check the plugin is executable: `ls -la ~/swiftbar-plugins/cursor-usage.5m.sh`
- If using a symlink, verify it's not broken: `file ~/swiftbar-plugins/cursor-usage.5m.sh`

### Data looks stale

- Click the plugin in the menu bar and select **Refresh**.
- Or right-click the SwiftBar icon → Refresh All.
- The script has a 15-second timeout per API call. On slow networks, it may show stale data from the last successful run.
