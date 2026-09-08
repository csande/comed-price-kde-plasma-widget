# ComEd Live Prices — Plasma widget

A KDE Plasma 6 desktop widget showing the current ComEd Hourly Pricing
rate, colored by price band, plus a short-term trend chart (switchable
between a line and a bar style).

## Directory structure

```
comed-price-kde-plasma-widget/
├── README.md
├── mock_comed_server.py       # local test server -- see "Testing without live data"
└── package/
    ├── metadata.json
    └── contents/
        ├── ui/
        │   ├── main.qml                    # root plasmoid: state, poll timer, fetch/retry
        │   ├── CompactRepresentation.qml    # panel form: price + time, click opens the popup
        │   ├── FullRepresentation.qml       # desktop form: title, price, refresh button, link, time, chart
        │   ├── PriceGraph.qml               # Canvas-based chart (line or bar style)
        │   └── ConfigGeneral.qml            # config page: chart style + chart history hours
        ├── config/
        │   ├── main.xml                # KConfigXT schema (chartStyle, graphHours, persisted last-good state)
        │   └── config.qml              # registers the config page above
        └── code/
            └── comed.js                # pure logic: price math, formatting, band/color, parsing
```

`package/` is the plasmoid itself — that's the directory KDE's tools
expect. `metadata.json`'s `KPlugin.Id` is
`com.github.csande.comed-price-kde-plasma-widget`;
change it (and the `Authors`/`License` fields) before publishing this
anywhere beyond your own machine, since the Id is meant to be
reverse-DNS-unique.

## Requirements

Plasma 6 (targets the `org.kde.plasma.plasmoid` QML API and
`kpackagetool6`; Fedora KDE Plasma spins currently ship Plasma 6).

## Installing

Run these from the repo root (`comed-price-kde-plasma-widget/`, the
directory that *contains* `package/` — not from inside `package/`
itself; `--install package` looks for a subdirectory named `package`
relative to wherever the command runs, so running it from inside
`package/` fails with "No such file"):

```sh
kpackagetool6 --type Plasma/Applet --install package
```

(If already inside `package/`, use `--install .` instead.)

Once installed, add it like any other widget: right-click the desktop
or a panel → **Add Widgets…** → search "ComEd Live Prices".

## Upgrading (after editing files)

```sh
kpackagetool6 --type Plasma/Applet --upgrade package
kquitapp6 plasmashell
sleep 2
kstart plasmashell
```

The `kquitapp6` / `sleep` / `kstart` sequence fully restarts Plasma's
shell so it reloads the QML — this is the standard loop used throughout
development, since QML changes generally aren't picked up by an
already-running `plasmashell`. `sleep 2` gives the old process time to
fully exit before starting a new one; without it, `kstart` can
occasionally race the shutdown. `systemctl --user restart
plasma-plasmashell.service` is a shorter equivalent when that systemd
unit is available, but the three-command sequence above is the more
universally reliable one and doesn't depend on that unit existing.

(`kstart`, not `kstart6` — that tool isn't versioned in either Plasma 5
or 6.)

If `--upgrade` refuses with something like `KPackageStructure ... does
not match requested format`, the installed copy predates a metadata fix
and `kpackagetool6` won't touch it automatically. Remove it directly and
reinstall instead:

```sh
rm -rf ~/.local/share/plasma/plasmoids/com.github.csande.comed-price-kde-plasma-widget
kpackagetool6 --type Plasma/Applet --install package
```

### If "Add Widgets" says this was written for an older version of Plasma

That message is Plasma's generic fallback whenever the QML fails to
load for *any* reason (a bad import, a syntax error, a wrong root item
type) and the package doesn't declare `X-Plasma-API-Minimum-Version` —
this package does declare it, but if the message still appears after
installing the current files, something else in the QML is failing to
load and getting misreported as a version problem.

`plasmoidviewer` prints the real underlying error directly to the
terminal, instead of the generic message the desktop shows:

```sh
plasmoidviewer -a package
```

Run that from the repo root and share whatever it prints — that's the
actual cause, not the version-mismatch text. It also doubles as a
faster development loop: it renders the plasmoid standalone in its own
window, without needing a full shell restart for every change.

## Uninstalling

First remove any placed instances of the widget: right-click it →
**Remove this Widget** (or drag it off the panel/desktop). Then remove
the installed package itself, using the `Id` from `metadata.json` —
not the directory name:

```sh
kpackagetool6 --type Plasma/Applet --remove com.github.csande.comed-price-kde-plasma-widget
```

This deletes the plasmoid's files but leaves behind the small amount of
persisted state described in "Fetch reliability" below (the last
known-good price and the config settings), stored under Plasma's own
per-applet config rather than anywhere inside the package. It's
harmless to leave in place — it'll simply be unused — but to clear it
too, remove the corresponding group from Plasma's applet config, e.g.:

```sh
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc \
  --group "Containments" --group "<containment-id>" \
  --group "Applets" --group "<applet-id>" --group "Configuration" \
  --group "General" --delete-group
```

`<containment-id>` and `<applet-id>` are specific to where the widget
was placed; if this level of cleanup matters, it's usually simpler to
just search `~/.config/plasma-org.kde.plasma.desktop-appletsrc` for the
`[General]` group containing `graphHours` and delete that section
directly in a text editor while `plasmashell` isn't running.

## Configuring

Right-click the widget → **Configure ComEd Live Prices…**:

- **Trend chart style**: Line or Bar (default Line). Line splits each
  segment's color exactly at the point where the interpolated price
  crosses a band threshold, so a green stretch is never plotted higher
  than an orange one. Bar draws one bar per data point, colored by that
  point's own price, with a zero baseline so a negative price extends
  the bar downward instead of clamping it.
- **Trend chart history**: 1–24 hours, default 2. Adjusts immediately —
  it's a live binding over already-fetched data, not something that
  waits for the next poll. The underlying feed already returns the last
  24 hours in one response regardless of this setting, so widening it
  doesn't cost any extra requests.

Also available, but not on this config page since it's a built-in
Plasma mechanism rather than something this widget implements:

- **Background**: right-click the widget (when placed on the desktop)
  for a background-type option (Standard / Transparent / None) — the
  same mechanism the Weather widget uses, enabled via the widget's
  `backgroundHints`.

## How the price is calculated

Every 5 minutes, the widget fetches ComEd's 5-minute pricing feed
(`https://hourlypricing.comed.com/api?type=5minutefeed`), which returns
the last 24 hours of 5-minute price points in one response. The
displayed price is not simply the single most recent point — it's an
exponentially-weighted average across recent points, most heavily
weighted toward the latest one:

- **10-minute half-life**: a price 10 minutes older than the most
  recent point counts for half as much; 20 minutes old counts for a
  quarter; and so on. This keeps the display responsive to real price
  changes while smoothing out single-tick noise or brief spikes in the
  feed. A shorter half-life recovers to an accurate reading faster after
  a spike resolves, which matters more for a number that's checked
  before running an appliance than protecting against the rare case of
  checking at the exact instant of a spike (which is both uncommon and
  self-correcting via the manual refresh).
- **120-minute cutoff**: points older than 2 hours are dropped before
  the weighted sum, since their contribution at the half-life above is
  already well under 0.1%.
- **20-minute staleness threshold**: if the feed's own most recent data
  point is more than 20 minutes old, the feed itself is treated as too
  stale to trust, and the price is shown as unavailable rather than
  displaying a possibly outdated number. This threshold accounts for two
  compounding, ordinary sources of lag — ComEd's own publish delay
  (typically a few minutes) plus the widget's poll cadence not being
  synchronized to ComEd's publish schedule — while still catching a
  genuine feed outage within a few polling cycles.

The trend chart reuses the same fetch: no separate request is made for
history. It's simply filtered down to the last N hours (the "Trend
chart history" setting above) and drawn oldest-to-newest. Negative
prices (ComEd's real-time rate occasionally goes negative) are handled
correctly by both chart styles — the Y axis extends below zero as
needed, and a zero line is drawn across the chart whenever zero falls
within the visible price range, including right at the bottom edge.

## Fetch reliability

A single poll attempts up to 3 fetches before giving up for that cycle
(the next poll follows in 5 minutes regardless):

- **Retry conditions**: a connection-level failure (no response
  received at all), an HTTP 429 or 5xx response, or an HTTP 200 with a
  body that parses to no usable price points.
- **Backoff**: 1 second after the first failed attempt, doubling on each
  subsequent one, capped at 10 seconds — or the delay from a
  `Retry-After` header, if the response included one.
- **Non-retryable failures** (any other HTTP error status) fail
  immediately rather than retrying, since those indicate a problem with
  the request itself rather than a transient condition.

If every attempt in a cycle fails — whether the request never reached
the server at all, reached it but got an error, or succeeded but
returned only stale or unusable data — the widget shows the explicit
unavailable state uniformly. The one exception is at startup: the last
successfully fetched price and its timestamp persist across Plasma
restarts via the widget's own config storage, so the widget has
something meaningful to show immediately before its first fetch of a
new session completes.

There's no fixed connect/read timeout on individual attempts — this
relies on Qt's own network stack timeout, which is generous but not a
hard-coded value.

## Display

### Desktop (full) view

- **Row 1**: title ("ComEd Live Prices", left) → spacer → refresh
  button → price (colored by band, bold, rightmost). The refresh button
  swaps in place for a busy spinner while a fetch is in progress, rather
  than a spinner appearing elsewhere alongside it.
- **Row 2**: a clickable link to ComEd's live prices page (left,
  truncates with an ellipsis if the widget is narrow) → spacer → the
  feed's own reported time (right).
- **Chart**: the line or bar chart, per the "Trend chart style" setting,
  filling the rest of the widget.
- **Sizing**: preferred size is 24×18 grid units, with a minimum width
  of 24 (not smaller) — the minimum width was raised specifically
  because the clickable link and the time text would otherwise collide
  at narrower widths.

### Panel (compact) view

- Price and time are stacked vertically (price on top, bold; time below
  in a much smaller font), centered in the panel cell.
- Clicking anywhere on the panel cell opens the desktop view as a popup
  (`Plasmoid.expanded`), rather than triggering a refresh directly — the
  popup has more room for the chart and its own refresh button.
- While a fetch is in progress, the price/time content is replaced by a
  spinner sized to match, so the panel cell's size doesn't jitter
  between the two states.

### Both views

- **Price text**: `⚡ 12.3¢` format, or `⚡ —¢` when unavailable.
- **Time text**: the feed's own timestamp for its most recent data
  point (not "when this widget happened to poll"), formatted using the
  system's locale time format (12h/24h per Plasma's Regional Settings).
  Shown as `—:—` when unavailable.
- **Price color** follows ComEd's own band legend for the live-prices
  page: green under 8¢, orange from 8¢ to 14¢ inclusive, red above 14¢,
  and gray when unavailable.
  - Green `#43BF55`
  - Orange `#D38240`
  - Red `#C50033`
  - Unknown/unavailable `#9E9E9E`

## Polling

A plain 5-minute QML timer drives refreshes. There's no wake-lock,
alarm, or catch-up scheduling behind it — if the machine is asleep or
the process isn't running, the timer simply doesn't fire, and the next
poll happens whenever the session resumes. A manual refresh (the
refresh button in the desktop/popup view) runs the same fetch-and-retry
logic on demand; clicking the panel widget itself opens that view
rather than refreshing directly (see "Panel (compact) view" above).

## Testing without live data

`mock_comed_server.py` (repo root, no dependencies beyond the Python
standard library) serves synthetic price data in the same JSON shape as
ComEd's real feed, for testing the widget when real prices aren't doing
anything interesting:

```sh
python3 mock_comed_server.py           # realistic: low plateau -> sudden jump -> high plateau -> sudden drop -> low plateau
python3 mock_comed_server.py --demo    # fixed dataset for checking the line chart's threshold-crossing color math
```

Both regenerate their series relative to the current time on every
request, so the most recent point never trips the 20-minute
feed-staleness check no matter how long the server's been running.

To point the widget at it, temporarily change `FEED_URL` near the top
of `contents/code/comed.js`:

```js
var FEED_URL = "http://127.0.0.1:8000/api?type=5minutefeed"
```

**Remember to change it back** to the real endpoint
(`https://hourlypricing.comed.com/api?type=5minutefeed`) before actual
use — it's easy to forget after a testing session.
