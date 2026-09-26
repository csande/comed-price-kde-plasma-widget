// ComEd Hourly Pricing math and formatting for the "ComEd Live Prices"
// Plasma widget. Ported from an existing Android app widget of the same
// underlying logic (ComedApiClient.kt / WidgetUpdateUtil.kt /
// PriceChartRenderer.kt) so the displayed price, its color band, and
// the "unavailable" text match exactly. Network I/O and retry
// orchestration live in ui/main.qml instead of here, since retry
// backoff needs a QML Timer, which a .pragma library file cannot own.
.pragma library

// ---- Feed ------------------------------------------------------------

var FEED_URL = "https://hourlypricing.comed.com/api?type=5minutefeed"

// The widget polls every 5 minutes; see the Timer in main.qml. There is
// no AlarmManager/Doze equivalent on the desktop -- if the machine is
// asleep or the process isn't running, the timer simply doesn't fire,
// and the next poll happens whenever the desktop session resumes.
var POLL_INTERVAL_MILLIS = 5 * 60 * 1000

// ---- Weighted-average price (matches ComedApiClient) ------------------

// A price this many minutes older than the most recent data point
// counts for half as much as the most recent point. See the Android
// ComedApiClient.HALF_LIFE_MINUTES comment for the full rationale
// (10 minutes recovers from a single-tick price spike roughly 3x
// faster than a longer half-life would).
var HALF_LIFE_MINUTES = 10.0

// Points older than this contribute a negligible amount at the half-life
// above and are dropped before summing.
var MAX_AGE_MINUTES = 120.0

// If the feed's own most recent data point is older than this many
// minutes, the feed itself is considered too stale to trust and the
// result is treated as unavailable rather than displaying a possibly
// outdated number.
var FEED_STALENESS_THRESHOLD_MINUTES = 20.0

// ---- Fetch retry (matches ComedApiClient's retry policy) ---------------

var MAX_ATTEMPTS = 3
var BASE_RETRY_DELAY_MILLIS = 1000
var MAX_RETRY_DELAY_MILLIS = 10000
var RETRYABLE_HTTP_CODES = [429, 500, 502, 503, 504]

// ---- Display text and colors (matches strings.xml / colors.xml) -------

var PRICE_UNAVAILABLE_TEXT = "\u26A1 \u2014\u00A2"   // "⚡ —¢"
var TIME_PLACEHOLDER_TEXT = "\u2014:\u2014"          // "—:—"

// Same hex values as the Android widget's background colors. Here they
// color the price text instead of the widget background.
var BAND_COLORS = {
    "GREEN":   "#43BF55",
    "ORANGE":  "#D38240",
    "RED":     "#C50033",
    "UNKNOWN": "#9E9E9E"
}

function colorForBand(band) {
    return BAND_COLORS[band] !== undefined ? BAND_COLORS[band] : BAND_COLORS["UNKNOWN"]
}

// Matches the band legend on ComEd's live-prices page: green under 8,
// orange from 8 to 14 inclusive, red above 14. Named rather than left as
// literals so PriceGraph.qml's exact-crossing-point math (where a line
// segment's color should change) can reference the same values.
var BAND_THRESHOLD_LOW = 8.0
var BAND_THRESHOLD_HIGH = 14.0

function bandForPrice(average) {
    if (average < BAND_THRESHOLD_LOW) return "GREEN"
    if (average <= BAND_THRESHOLD_HIGH) return "ORANGE"
    return "RED"
}

function formatPrice(average) {
    return "\u26A1 " + average.toFixed(1) + "\u00A2"
}

// Uses the system's locale time format (12h/24h per Plasma's Regional
// Settings), the desktop analog of the Android widget reading the
// device's clock-format preference.
//
// Deliberately uses Qt.DefaultLocaleShortDate rather than
// Qt.locale().timeFormat(Locale.ShortFormat): the "Locale" enum object
// is a QML-context global that isn't reliably available inside a
// .pragma library script (as opposed to an ordinary .qml file), and
// referencing it here threw silently, aborting applyResult() partway
// through -- which was also, incidentally, why the graph wasn't
// populating (historyPoints is set later in that same function). The
// "Qt" global used below is explicitly documented as available even
// from pragma library scripts.
function formatTime(millisUtc) {
    return Qt.formatTime(new Date(millisUtc), Qt.DefaultLocaleShortDate)
}

// ---- Parsing and math ---------------------------------------------------

function parsePoints(jsonText) {
    var raw
    try {
        raw = JSON.parse(jsonText)
    } catch (e) {
        return []
    }
    if (!Array.isArray(raw)) return []

    var points = []
    for (var i = 0; i < raw.length; i++) {
        var millis = parseInt(raw[i].millisUTC, 10)
        var price = parseFloat(raw[i].price)
        if (!isNaN(millis) && !isNaN(price)) {
            points.push({ millisUtc: millis, price: price })
        }
    }
    return points
}

function mostRecentMillis(points) {
    return points.reduce(function(max, p) {
        return p.millisUtc > max ? p.millisUtc : max
    }, 0)
}

// Returns the single most recent point (by millisUtc), or null if points
// is empty. Used for the time series chart's own price display -- see
// buildTimeSeriesSlots below and main.qml's applyResult -- as distinct
// from weightedAverage above, which the panel/compact view still uses.
function latestPoint(points) {
    if (!points || points.length === 0) return null
    var best = points[0]
    for (var i = 1; i < points.length; i++) {
        if (points[i].millisUtc > best.millisUtc) best = points[i]
    }
    return best
}

// ComEd's feed publishes on a 5-minute cadence (matches main.qml's own
// 5-minute poll Timer). Used by buildTimeSeriesSlots below to recognize
// when one or more expected points are missing from the feed, rather
// than just connecting or compressing past whatever points happen to
// exist. Ported from WidgetUpdateUtil.kt's EXPECTED_POINT_INTERVAL_MINUTES.
var EXPECTED_POINT_INTERVAL_MINUTES = 5.0

// A gap between two consecutive real points wider than this is treated
// as "at least one point is missing" rather than ordinary jitter in
// when the feed happened to publish or this widget happened to poll.
// 1.5x the expected interval gives comfortable room for a few minutes
// of jitter (see FEED_STALENESS_THRESHOLD_MINUTES above for the kind of
// timing slop this feed exhibits normally) without also firing on every
// ordinary tick. Ported from WidgetUpdateUtil.kt's
// MISSING_POINT_GAP_THRESHOLD_MINUTES.
var MISSING_POINT_GAP_THRESHOLD_MINUTES = EXPECTED_POINT_INTERVAL_MINUTES * 1.5

// Returns the exponentially-weighted average price, or null if points
// is empty (mirrors ComedApiClient.fetchPrice's defensive weightTotal
// check -- can't actually happen for a non-empty list, since the most
// recent point always has age 0 and weight 1).
function weightedAverage(points) {
    if (!points || points.length === 0) return null

    var mostRecent = mostRecentMillis(points)
    var weightedSum = 0.0
    var weightTotal = 0.0

    for (var i = 0; i < points.length; i++) {
        var ageMinutes = (mostRecent - points[i].millisUtc) / 60000.0
        if (ageMinutes > MAX_AGE_MINUTES) continue
        var weight = Math.pow(0.5, ageMinutes / HALF_LIFE_MINUTES)
        weightedSum += weight * points[i].price
        weightTotal += weight
    }

    if (weightTotal === 0.0) return null
    return weightedSum / weightTotal
}

// Returns only the points within `hours` of the most recent point,
// oldest first, for the time series chart. Independent of MAX_AGE_MINUTES,
// which governs the weighted-average calculation above, not the graph.
function filterHistory(points, hours) {
    if (!points || points.length === 0) return []

    var mostRecent = mostRecentMillis(points)
    var cutoff = mostRecent - hours * 60 * 60 * 1000

    return points
        .filter(function(p) { return p.millisUtc >= cutoff })
        .sort(function(a, b) { return a.millisUtc - b.millisUtc })
}

// Builds a full `hours` window of missing-only slots, at the expected
// 5-minute cadence, newest slot anchored to the most recent 5-minute
// mark at or before right now -- e.g. at 11:24, the newest slot is
// 11:20, then 11:15, 11:10, and so on -- rather than to the exact
// current millisecond, which would drift off the times the feed's own
// points would actually land on. Used by buildTimeSeriesSlots below
// when there's no real data to anchor a window on instead.
function buildEmptyWindowSlots(hours) {
    var intervalMillis = EXPECTED_POINT_INTERVAL_MINUTES * 60000
    var totalSlots = Math.round(hours * 60 * 60 * 1000 / intervalMillis)
    var alignedNow = Math.floor(Date.now() / intervalMillis) * intervalMillis
    var slots = []
    for (var e = totalSlots; e >= 0; e--) {
        slots.push({ millisUtc: alignedNow - e * intervalMillis, price: null })
    }
    return slots
}

// Turns the raw feed points into the slot list PriceGraph.qml actually
// draws: every point still where it was, plus a slot with price === null
// inserted for each expected 5-minute point that isn't there, rather
// than silently leaving that gap for the chart to paper over by
// connecting (line style) or compressing past (bar style) straight
// through it. Applies the `hours` window via filterHistory above, same
// as before this existed.
//
// A null-price slot is only ever inserted *between* two real points
// (never before the first or after the last), so the returned list's
// first and last entries always have a real price -- PriceGraph.qml's
// line style relies on that for its X axis's time range. Ported from
// WidgetUpdateUtil.kt's buildTimeSeriesSlots.
function buildTimeSeriesSlots(points, hours) {
    var filtered = filterHistory(points, hours)
    if (filtered.length === 0) {
        // No data at all to anchor a real time window on -- e.g. before
        // the very first successful fetch of a session, or a total feed
        // outage. Rather than returning nothing (which left
        // PriceGraph.qml with no way to draw axes/labels at all -- see
        // its own doc comment), build a full `hours` window of missing
        // slots anchored to now, at the same 5-minute cadence the feed
        // would normally publish at, so the chart still has an X axis
        // time range and a full set of missing-data markers to draw,
        // even with nothing real behind any of them.
        return buildEmptyWindowSlots(hours)
    }

    var intervalMillis = EXPECTED_POINT_INTERVAL_MINUTES * 60000
    var gapThresholdMillis = MISSING_POINT_GAP_THRESHOLD_MINUTES * 60000

    var slots = [{ millisUtc: filtered[0].millisUtc, price: filtered[0].price }]
    for (var i = 1; i < filtered.length; i++) {
        var previous = filtered[i - 1]
        var current = filtered[i]
        var gapMillis = current.millisUtc - previous.millisUtc
        if (gapMillis > gapThresholdMillis) {
            // One or more expected points are missing between these two
            // -- step forward in exact 5-minute increments from the
            // previous real point, inserting a null-price slot for each
            // one that isn't (close enough to) the next real point, so
            // a longer outage yields proportionally more gap slots
            // rather than just one regardless of size.
            var expectedMillis = previous.millisUtc + intervalMillis
            while (current.millisUtc - expectedMillis > intervalMillis / 2) {
                slots.push({ millisUtc: expectedMillis, price: null })
                expectedMillis += intervalMillis
            }
        }
        slots.push({ millisUtc: current.millisUtc, price: current.price })
    }
    return slots
}

// ---- Retry backoff helpers ------------------------------------------

// Parses a Retry-After header given in delay-seconds form (e.g. "2").
// The HTTP-date form isn't handled, matching ComedApiClient -- ComEd's
// feed has no documented use of Retry-After at all; this is a defensive
// best effort, not a relied-upon behavior.
function parseRetryAfter(headerValue) {
    if (!headerValue) return null
    var seconds = parseInt(headerValue, 10)
    if (isNaN(seconds) || seconds < 0) return null
    return seconds * 1000
}

function backoffDelayMillis(attemptNumber, retryAfterMillis) {
    if (retryAfterMillis !== null && retryAfterMillis !== undefined) {
        return Math.min(Math.max(retryAfterMillis, 0), MAX_RETRY_DELAY_MILLIS)
    }
    var exponential = BASE_RETRY_DELAY_MILLIS * Math.pow(2, attemptNumber - 1)
    return Math.min(exponential, MAX_RETRY_DELAY_MILLIS)
}
