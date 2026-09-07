# ComEd Live Prices — Plasma widget

A KDE Plasma 6 desktop widget showing the current ComEd Hourly Pricing
rate, colored by price band, plus a short-term trend chart.

## Directory structure

```
comed-price-kde-plasma-widget/
├── README.md
└── package/
    ├── metadata.json
    └── contents/
        ├── ui/
        │   ├── main.qml               # root plasmoid: state, poll timer, fetch/retry
        │   ├── CompactRepresentation.qml   # panel form: price text, click to refresh
        │   ├── FullRepresentation.qml      # desktop form: title, price, time, graph, refresh button
        │   ├── PriceGraph.qml              # Canvas-based trend line
        │   └── ConfigGeneral.qml           # "graph history hours" setting page
        ├── config/
        │   ├── main.xml               # KConfigXT schema (graphHours + persisted last-good state)
        │   └── config.qml             # registers the config page above
        └── code/
            └── comed.js               # pure logic: price math, formatting, band/color, parsing
```

`package/` is the plasmoid itself — that's the directory KDE's tools
expect. `metadata.json`'s `KPlugin.Id` is `com.example.comedliveprices`;
change it (and the `Authors`/`License` fields) before publishing this
anywhere beyond your own machine, since the Id is meant to be
reverse-DNS-unique.

## Building / installing

Requires Plasma 6 (targets the `org.kde.plasma.plasmoid` QML API and
`kpackagetool6`; Fedora KDE Plasma spins currently ship Plasma 6).

Run these from the repo root (`comed-price-kde-plasma-widget/`, the directory that
*contains* `package/` — not from inside `package/` itself; `--install
package` looks for a subdirectory named `package` relative to wherever
the command runs, so running it from inside `package/` fails with "No
such file"):

```sh
kpackagetool6 --type Plasma/Applet --install package
```

(If already inside `package/`, use `--install .` instead.)

To pick up changes after editing, use `--upgrade` instead of
`--install`, then restart Plasma's shell so it reloads the QML:

```sh
kpackagetool6 --type Plasma/Applet --upgrade package
systemctl --user restart plasma-plasmashell.service
```

(`kstart`, not `kstart6` — that tool isn't versioned in either Plasma 5
or 6. `kquitapp6 plasmashell && kstart plasmashell` works too if the
`systemctl` unit isn't available.)

If `--upgrade` refuses with something like `KPackageStructure ... does
not match requested format`, the installed copy predates a metadata fix
and `kpackagetool6` won't touch it automatically. Remove it directly and
reinstall:

```sh
rm -rf ~/.local/share/plasma/plasmoids/com.example.comedliveprices
kpackagetool6 --type Plasma/Applet --install package
```

### If "Add Widgets" says this was written for an older version of Plasma

That message is Plasma's generic fallback whenever the QML fails to
load for *any* reason (a bad import, a syntax error, a wrong root item
type) and the package doesn't declare
`X-Plasma-API-Minimum-Version` — this package does declare it, but if
the message still appears after installing the current files, something
else in the QML is failing to load and getting misreported as a version
problem.

`plasmoidviewer` prints the real underlying error directly to the
terminal, instead of the generic message the desktop shows:

```sh
plasmoidviewer -a package
```

Run that from the repo root and share whatever it prints — that's the
actual cause, not the version mismatch text.

Once installed, add it like any other widget: right-click the desktop
or a panel → **Add Widgets…** → search "ComEd Live Prices".

For faster iteration while developing, `plasmoidviewer` renders a
plasmoid standalone without restarting the whole shell:

```sh
plasmoidviewer -a package
```

## Uninstalling

First remove any placed instances of the widget: right-click it →
**Remove this Widget** (or drag it off the panel/desktop). Then remove
the installed package itself, using the `Id` from `metadata.json` —
not the directory name:

```sh
kpackagetool6 --type Plasma/Applet --remove com.example.comedliveprices
```

This deletes the plasmoid's files but leaves behind the small amount of
persisted state described in "Fetch reliability" below (the last
known-good price and the graph-history setting), stored under Plasma's
own per-applet config rather than anywhere inside the package. It's
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

- **Background**: right-click the widget (when placed on the desktop)
  for a background-type option (Standard / Transparent / None) — the
  same mechanism the Weather widget uses. No setting inside this
  widget's own config page controls this; it's a built-in Plasma
  capability enabled via the widget's `backgroundHints`.
- **Trend chart history**: right-click the widget → **Configure ComEd
  Live Prices…** → a single "hours of history" spinbox, default 2.
  Adjust freely; the underlying feed already returns the last 24 hours
  in one response, so widening this doesn't cost any extra requests.

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

The graph reuses the same fetch: no separate request is made for
history. It's simply filtered down to the last N hours (the "Trend
graph history" setting above) and drawn oldest-to-newest.

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

If every attempt in a cycle fails *without ever receiving an HTTP
response* (suggesting no network was reachable at all, as opposed to
reaching ComEd and getting an error), the widget redisplays the last
successfully fetched price rather than showing "unavailable" — that
last-known-good price and its timestamp persist across Plasma restarts
via the widget's own config storage. A fetch that *does* reach the
server but fails, or one that succeeds but returns stale data, shows
the explicit unavailable state instead, since those aren't connectivity
problems.

There's no fixed connect/read timeout on individual attempts — this
relies on Qt's own network stack timeout, which is generous but not a
hard-coded value.

## Display

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
- **Loading state**: a small busy indicator appears next to the title
  and the refresh button disables itself while a fetch is in progress;
  the last price, time, and graph stay visible underneath rather than
  being replaced.
- **Background**: transparent or opaque, configurable per the
  "Configuring" section above.

## Polling

A plain 5-minute QML timer drives refreshes. There's no wake-lock,
alarm, or catch-up scheduling behind it — if the machine is asleep or
the process isn't running, the timer simply doesn't fire, and the next
poll happens whenever the session resumes. A manual refresh (clicking
the compact-form price text, or the refresh button in the full form)
runs the same fetch-and-retry logic on demand.
