// ComEd Hourly Pricing math and formatting for the "ComEd Live Prices"
// Plasma widget. Ported from an existing Android app widget of the same
// underlying logic (ComedApiClient.kt / WidgetUpdateUtil.kt) so the
// displayed price, its color band, and the "unavailable" text match
// exactly. Network I/O and retry orchestration live in ui/main.qml
// instead of here, since retry backoff needs a QML Timer, which a
// .pragma library file cannot own.
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
// oldest first, for the trend chart. Independent of MAX_AGE_MINUTES,
// which governs the weighted-average calculation above, not the graph.
function filterHistory(points, hours) {
    if (!points || points.length === 0) return []

    var mostRecent = mostRecentMillis(points)
    var cutoff = mostRecent - hours * 60 * 60 * 1000

    return points
        .filter(function(p) { return p.millisUtc >= cutoff })
        .sort(function(a, b) { return a.millisUtc - b.millisUtc })
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
