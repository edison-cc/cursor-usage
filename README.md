# Cursor Usage

A macOS menu bar plugin that shows your Cursor IDE usage at a glance: included requests consumed and on-demand spend.

## Prerequisites

- **macOS** (Catalina 10.15+)
- **Cursor IDE** — must be installed and signed in at least once

## Installation

### Option A: Homebrew

```bash
brew tap edison-cc/tap
brew install cursor-usage
```

SwiftBar is installed automatically as a dependency. After install, launch SwiftBar and point it to `~/swiftbar-plugins`:

```bash
open -a SwiftBar
```

The plugin is already linked and will appear in the menu bar on next refresh.

### Option B: Manual

1. Install [SwiftBar](https://github.com/swiftbar/SwiftBar):

```bash
brew install --cask swiftbar
```

2. Clone this repo and link the plugin:

```bash
git clone https://github.com/edison-cc/cursor-usage.git
cd cursor-usage
mkdir -p ~/swiftbar-plugins
ln -sf "$(pwd)/cursor-usage.5m.sh" ~/swiftbar-plugins/cursor-usage.5m.sh
```

3. Launch SwiftBar and select `~/swiftbar-plugins` as the plugin directory:

```bash
open -a SwiftBar
```

If SwiftBar is already running and you need to change the directory:

```bash
defaults write com.ameba.SwiftBar PluginDirectory "$HOME/swiftbar-plugins"
```

Then restart SwiftBar.

The plugin will run immediately and refresh every **5 minutes** (based on the `5m` in the filename).

<!-- Future: ### Option C: npm
```bash
npm install -g @edison-cc/cursor-usage
``` -->

## Testing

Run the test script to verify API connectivity and auth without SwiftBar:

```bash
bash test-cursor-usage.sh
```

After Homebrew install, the test script is also available at:

```bash
bash "$(brew --prefix)/share/cursor-usage/test-cursor-usage.sh"
```

This calls the same Cursor APIs as the plugin and prints a plain-text summary. If you see your usage data, everything is working correctly.

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

### Menu bar shows "⚡ err"

Click it to see the error in the dropdown. Common causes:

- **"Cursor DB not found"** — Cursor IDE hasn't been opened on this machine, or is installed in a non-standard location.
- **"No access token"** — You're not signed in to Cursor. Open Cursor, sign in, then click Refresh.

### Plugin doesn't appear in menu bar

- Verify SwiftBar is running (check for its icon in the menu bar).
- Confirm the plugin directory is set: `defaults read com.ameba.SwiftBar PluginDirectory`
- Check the plugin is executable: `ls -la ~/swiftbar-plugins/cursor-usage.5m.sh`
- If using a symlink, verify it's not broken: `file ~/swiftbar-plugins/cursor-usage.5m.sh`

### Data looks stale

- Click the plugin in the menu bar and select **Refresh**.
- Or right-click the SwiftBar icon → Refresh All.
- The script has a 15-second timeout per API call. On slow networks, it may show stale data from the last successful run.
