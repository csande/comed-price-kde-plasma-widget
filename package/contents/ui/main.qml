import QtQuick
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import "../code/comed.js" as Comed

PlasmoidItem {
    id: root

    // Lets the user choose Standard/Translucent/None for the widget's
    // background via right-click, the same mechanism the Weather widget
    // uses. No custom code beyond this hint is needed.
    Plasmoid.backgroundHints: PlasmaCore.Types.DefaultBackground | PlasmaCore.Types.ConfigurableBackground

    // ---- Shared state, read by both representations ----
    property real currentPrice: NaN            // cents/kWh; NaN when unavailable
    property string currentBand: "UNKNOWN"      // GREEN / ORANGE / RED / UNKNOWN
    property string priceText: Comed.PRICE_UNAVAILABLE_TEXT
    property string timeText: Comed.TIME_PLACEHOLDER_TEXT
    property color priceColor: Comed.colorForBand("UNKNOWN")
    property bool refreshing: false
    property var rawFeedPoints: []               // [{millisUtc, price}], oldest first, full feed as of the last successful fetch (unfiltered)

    // A live binding, not a plain assigned property: re-evaluates
    // automatically whenever either rawFeedPoints or the graphHours
    // config setting changes, so adjusting the "Trend chart history"
    // setting updates the graph immediately -- no new fetch required.
    property var historyPoints: Comed.filterHistory(rawFeedPoints, Plasmoid.configuration.graphHours)

    compactRepresentation: CompactRepresentation {
        priceText: root.priceText
        timeText: root.timeText
        priceColor: root.priceColor
        refreshing: root.refreshing
        onTogglePopupRequested: root.expanded = !root.expanded
    }

    fullRepresentation: FullRepresentation {
        priceText: root.priceText
        timeText: root.timeText
        priceColor: root.priceColor
        historyPoints: root.historyPoints
        refreshing: root.refreshing
        onRefreshRequested: root.refresh()
    }

    Component.onCompleted: {
        restoreLastGoodState()
        refresh()
    }

    // 5-minute poll cadence. If the machine is asleep or the process
    // isn't running, this simply doesn't fire -- there's no wake-lock or
    // alarm-based catch-up on the desktop, matching the "that's fine"
    // guidance for this port.
    Timer {
        interval: Comed.POLL_INTERVAL_MILLIS
        repeat: true
        running: true
        triggeredOnStart: false
        onTriggered: root.refresh()
    }

    // Single-shot backoff timer reused across retry attempts within one
    // refresh() call. Distinct from the poll Timer above.
    Timer {
        id: retryTimer
        repeat: false
        property int nextAttempt: 1
        property var callback: null
        onTriggered: root.doAttempt(nextAttempt, callback)
    }

    // ---- Startup / stale-state restoration ----

    // Restores the last successfully fetched price (and its color band)
    // from persisted config, so the widget shows something meaningful
    // immediately after Plasma restarts, before the first refresh
    // completes.
    function restoreLastGoodState() {
        var band = Plasmoid.configuration.lastBand || "UNKNOWN"
        currentBand = band
        priceColor = Comed.colorForBand(band)

        var lastText = Plasmoid.configuration.lastGoodPriceText
        if (lastText && lastText.length > 0) {
            priceText = lastText
        }

        var lastTs = Plasmoid.configuration.lastGoodFeedTimestampMillis
        if (lastTs && lastTs > 0) {
            timeText = Comed.formatTime(lastTs)
        }
    }

    // ---- Refresh entry point (poll timer, manual refresh button, or click) ----

    function refresh() {
        if (refreshing) return
        refreshing = true
        doAttempt(1, applyResult)
    }

    // ---- Fetch + retry state machine ----
    //
    // Simplifications vs. the Android ComedApiClient/WidgetUpdateUtil this
    // was ported from:
    //  - No upfront network-availability check (QML has no simple built-in
    //    connectivity API).
    //  - No Doze-idle analog. The Android client redisplays the last
    //    known-good price, rather than showing "unavailable", for a
    //    connectivity failure specifically combined with the device being
    //    in Doze idle mode -- reasoning that in that combination, the OS
    //    itself likely blocked the request rather than a real outage.
    //    Desktop has no equivalent condition to key off of, so rather than
    //    approximate it, any failure to obtain a fresh, non-stale price --
    //    no response, a bad response, retries exhausted, or a stale feed --
    //    uniformly shows the explicit "price unavailable" state instead.
    //  - No explicit connect/read timeout is enforced; this relies on Qt's
    //    own network stack timeout, which is generous but not a fixed
    //    10 seconds like the Android client's.

    function doAttempt(attemptNumber, callback) {
        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return

            var status = xhr.status

            if (status === 200) {
                var points = Comed.parsePoints(xhr.responseText)
                if (points.length > 0) {
                    finishWithPoints(points, callback)
                } else {
                    // Succeeded but returned nothing usable -- worth a
                    // retry rather than treating this like a populated
                    // response.
                    retryOrGiveUp(attemptNumber, callback, 0)
                }
                return
            }

            if (Comed.RETRYABLE_HTTP_CODES.indexOf(status) !== -1) {
                var retryAfter = Comed.parseRetryAfter(xhr.getResponseHeader("Retry-After"))
                retryOrGiveUp(attemptNumber, callback, retryAfter)
                return
            }

            if (status === 0) {
                // No HTTP response at all -- connection-level failure.
                retryOrGiveUp(attemptNumber, callback, null)
                return
            }

            // Any other HTTP status indicates a problem with the request
            // itself, not a transient condition -- fail now rather than
            // retrying.
            refreshing = false
            callback({ status: "unavailable" })
        }
        xhr.open("GET", Comed.FEED_URL)
        xhr.setRequestHeader("Accept", "application/json")
        xhr.send()
    }

    function retryOrGiveUp(attemptNumber, callback, retryAfterMillis) {
        if (attemptNumber >= Comed.MAX_ATTEMPTS) {
            refreshing = false
            callback({ status: "unavailable" })
            return
        }
        retryTimer.nextAttempt = attemptNumber + 1
        retryTimer.callback = callback
        retryTimer.interval = Comed.backoffDelayMillis(attemptNumber, retryAfterMillis)
        retryTimer.start()
    }

    function finishWithPoints(points, callback) {
        refreshing = false

        var mostRecentMillis = Comed.mostRecentMillis(points)
        var feedAgeMinutes = (Date.now() - mostRecentMillis) / 60000.0
        if (feedAgeMinutes > Comed.FEED_STALENESS_THRESHOLD_MINUTES) {
            callback({ status: "feedStale" })
            return
        }

        var average = Comed.weightedAverage(points)
        if (average === null) {
            callback({ status: "unavailable" })
            return
        }

        callback({
            status: "available",
            average: average,
            feedTimestampMillis: mostRecentMillis,
            points: points
        })
    }

    // ---- Applying a fetch result to the shared state ----

    function applyResult(result) {
        if (result.status === "available") {
            currentPrice = result.average
            currentBand = Comed.bandForPrice(result.average)
            priceColor = Comed.colorForBand(currentBand)
            priceText = Comed.formatPrice(result.average)
            timeText = Comed.formatTime(result.feedTimestampMillis)
            // historyPoints was assigned directly here before -- now it's
            // a live binding (declared above) derived from rawFeedPoints,
            // so just store the raw fetch result.
            rawFeedPoints = result.points

            Plasmoid.configuration.lastBand = currentBand
            Plasmoid.configuration.lastGoodPriceText = priceText
            Plasmoid.configuration.lastGoodFeedTimestampMillis = result.feedTimestampMillis
        } else {
            // feedStale or unavailable -- both mean there's no usable
            // price right now, so both show the explicit unavailable
            // state rather than a stale or stand-in figure.
            currentPrice = NaN
            currentBand = "UNKNOWN"
            priceColor = Comed.colorForBand("UNKNOWN")
            priceText = Comed.PRICE_UNAVAILABLE_TEXT
            timeText = Comed.TIME_PLACEHOLDER_TEXT
            Plasmoid.configuration.lastBand = currentBand
        }
    }
}
