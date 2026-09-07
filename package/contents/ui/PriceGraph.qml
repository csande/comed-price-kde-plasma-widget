import QtQuick
import org.kde.kirigami as Kirigami
import "../code/comed.js" as Comed

// Hand-rolled chart, drawn with QtQuick's Canvas rather than a charting
// library: this only ever needs a simple price visualization, so a
// dependency like QtCharts (not guaranteed present on every Plasma
// install) isn't worth it.
//
// Supports two styles, chosen via the chartStyle property (0 = Line,
// 1 = Bar; see config/main.xml and ConfigGeneral.qml):
//
//  - Line: each segment between two points is split into sub-segments
//    at the exact point(s) where the interpolated price crosses a band
//    threshold (8c or 14c) -- price varies linearly between two points,
//    and pixel height is linear in price, so solving for the crossing
//    is a direct linear-interpolation calculation. This keeps color and
//    height mathematically tied together everywhere along the line: a
//    green stretch can never be drawn higher than an orange one, since
//    it's only ever drawn where the interpolated price is actually
//    below the green/orange threshold.
//  - Bar: each point is its own bar, coloured by its own price, with a
//    zero baseline (ComEd prices occasionally go negative) so a bar's
//    height and color are both independently derived from that single
//    point -- no interpolation or crossing math needed.
Item {
    id: graphRoot

    readonly property int styleLine: 0
    readonly property int styleBar: 1

    property var points: []          // [{millisUtc, price}], oldest first
    property int chartStyle: styleLine

    // Bound separately (rather than read directly from Kirigami.Theme
    // inside onPaint) so theme changes trigger a repaint via the
    // onXChanged handlers below -- Canvas doesn't automatically redraw
    // just because a value it reads happens to change.
    property color axisTextColor: Kirigami.Theme.textColor
    property color gridColor: Kirigami.Theme.disabledTextColor

    Canvas {
        id: canvas
        anchors.fill: parent
        antialiasing: true

        onPaint: {
            var ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)

            var n = graphRoot.points ? graphRoot.points.length : 0
            if (n < 1) {
                return
            }

            var isBar = graphRoot.chartStyle === graphRoot.styleBar

            var labelFont = Kirigami.Theme.smallFont
            var fontSizePart = labelFont.pointSize > 0
                ? (labelFont.pointSize + "pt")
                : (labelFont.pixelSize + "px")
            ctx.font = fontSizePart + " " + labelFont.family

            // ---- Y axis (price, in cents): rounded to "nice" tick
            // values. Bars get a forced zero baseline to grow from;
            // the line chart stays tight to the actual data range. ----
            var prices = graphRoot.points.map(function(p) { return p.price })
            var rawMinPrice = Math.min.apply(null, prices)
            var rawMaxPrice = Math.max.apply(null, prices)
            if (isBar) {
                rawMinPrice = Math.min(0, rawMinPrice)
                rawMaxPrice = Math.max(0, rawMaxPrice)
            }
            var yAxis = niceAxis(rawMinPrice, rawMaxPrice, 4)

            // Widest tick label sets the left margin, so labels never clip.
            var maxLabelWidth = 0
            for (var t = 0; t < yAxis.ticks.length; t++) {
                var w = ctx.measureText(formatCents(yAxis.ticks[t], yAxis.decimals)).width
                if (w > maxLabelWidth) maxLabelWidth = w
            }

            var marginLeft = maxLabelWidth + 6
            var marginRight = 4
            // The topmost tick's label is vertically centered on the tick
            // mark itself (textBaseline "middle"), so roughly half the
            // label's height extends above plotTop -- without headroom
            // here, that overhang gets clipped by the canvas edge.
            var marginTop = 10
            var marginBottom = 16

            var plotLeft = marginLeft
            var plotRight = width - marginRight
            var plotTop = marginTop
            var plotBottom = height - marginBottom
            var plotWidth = Math.max(1, plotRight - plotLeft)
            var plotHeight = Math.max(1, plotBottom - plotTop)

            function yFor(price) {
                return plotTop + plotHeight - ((price - yAxis.min) / (yAxis.max - yAxis.min)) * plotHeight
            }

            // ---- X axis positioning: bars sit in evenly-sized index
            // slots (so they stay evenly spaced even if a reading is
            // missing from the feed); the line uses time-proportional
            // position (so a gap in readings shows as a longer segment
            // rather than distorting spacing). ----
            var minTime = graphRoot.points[0].millisUtc
            var maxTime = graphRoot.points[n - 1].millisUtc
            var timeSpan = Math.max(1, maxTime - minTime)
            var slotWidth = plotWidth / n
            var barWidth = Math.max(1, slotWidth * 0.6)

            var xFor
            if (isBar) {
                xFor = function(millis, index) {
                    return plotLeft + slotWidth * (index + 0.5)
                }
            } else {
                xFor = function(millis) {
                    return plotLeft + ((millis - minTime) / timeSpan) * plotWidth
                }
            }

            // ---- Y axis tick marks + labels ----
            ctx.strokeStyle = graphRoot.gridColor
            ctx.fillStyle = graphRoot.axisTextColor
            ctx.lineWidth = 1
            ctx.textBaseline = "middle"
            ctx.textAlign = "right"

            var tickMarkLength = 3
            for (var i = 0; i < yAxis.ticks.length; i++) {
                var y = yFor(yAxis.ticks[i])
                ctx.globalAlpha = 0.5
                ctx.beginPath()
                ctx.moveTo(plotLeft - tickMarkLength, y)
                ctx.lineTo(plotLeft, y)
                ctx.stroke()
                ctx.globalAlpha = 1.0
                ctx.fillText(formatCents(yAxis.ticks[i], yAxis.decimals), plotLeft - tickMarkLength - 3, y)
            }

            // ---- X axis: start / middle / end time labels ----
            ctx.textBaseline = "top"
            var xTickAligns = ["left", "center", "right"]
            if (isBar) {
                var xTickIndices = [0, Math.floor((n - 1) / 2), n - 1]
                for (var jb = 0; jb < xTickIndices.length; jb++) {
                    var idx = xTickIndices[jb]
                    var xb = xFor(graphRoot.points[idx].millisUtc, idx)
                    ctx.textAlign = xTickAligns[jb]
                    ctx.fillText(Comed.formatTime(graphRoot.points[idx].millisUtc), xb, plotBottom + 4)
                }
            } else {
                var xTickTimes = [minTime, minTime + timeSpan / 2, maxTime]
                for (var jl = 0; jl < xTickTimes.length; jl++) {
                    var xl = xFor(xTickTimes[jl])
                    ctx.textAlign = xTickAligns[jl]
                    ctx.fillText(Comed.formatTime(xTickTimes[jl]), xl, plotBottom + 4)
                }
            }

            // ---- Zero line, drawn whenever zero falls anywhere within
            // the visible price range -- including right at the bottom
            // edge, which is the common case for the bar chart (its Y
            // axis always includes zero) when every price is
            // non-negative. Without the bottom border, that edge would
            // otherwise have no line at all marking it. ----
            if (yAxis.min <= 0 && yAxis.max >= 0) {
                var zeroY = yFor(0)
                ctx.strokeStyle = graphRoot.gridColor
                ctx.lineWidth = 1
                ctx.globalAlpha = 0.5
                ctx.beginPath()
                ctx.moveTo(plotLeft, zeroY)
                ctx.lineTo(plotRight, zeroY)
                ctx.stroke()
                ctx.globalAlpha = 1.0
            }

            // ---- Axis line: left edge only. No bottom border -- with a
            // zero line already marking zero when it's in view, a bottom
            // border sitting right alongside it (or duplicating it, when
            // all prices are non-negative) added clutter without adding
            // information. ----
            ctx.strokeStyle = graphRoot.gridColor
            ctx.globalAlpha = 0.5
            ctx.beginPath()
            ctx.moveTo(plotLeft, plotTop)
            ctx.lineTo(plotLeft, plotBottom)
            ctx.stroke()
            ctx.globalAlpha = 1.0

            // ---- The data itself ----
            if (isBar) {
                // baselineY is the pixel row for price=0. barTop/barHeight
                // below work for negative prices automatically, with no
                // separate branch needed: pixel-Y increases downward, so
                // a negative price's topY is numerically greater than
                // baselineY, making barTop resolve to baselineY and the
                // bar span downward from the zero line to topY.
                var baselineY = yFor(0)
                for (var k = 0; k < n; k++) {
                    var price = graphRoot.points[k].price
                    var topY = yFor(price)
                    var barTop = Math.min(baselineY, topY)
                    var barHeight = Math.max(1, Math.abs(baselineY - topY))
                    var barLeft = xFor(graphRoot.points[k].millisUtc, k) - barWidth / 2

                    ctx.fillStyle = Comed.colorForBand(Comed.bandForPrice(price))
                    ctx.fillRect(barLeft, barTop, barWidth, barHeight)
                }
            } else {
                ctx.lineWidth = 2
                if (n === 1) {
                    // Nothing to connect -- draw a single dot so a lone
                    // point is still visible.
                    var soloX = xFor(graphRoot.points[0].millisUtc)
                    var soloY = yFor(graphRoot.points[0].price)
                    ctx.fillStyle = Comed.colorForBand(Comed.bandForPrice(graphRoot.points[0].price))
                    ctx.beginPath()
                    ctx.arc(soloX, soloY, 2.2, 0, 2 * Math.PI)
                    ctx.fill()
                } else {
                    for (var seg = 0; seg < n - 1; seg++) {
                        drawSegment(ctx, graphRoot.points[seg], graphRoot.points[seg + 1], xFor, yFor)
                    }
                }
            }
        }

        // Draws one point-to-point line segment, split into
        // sub-segments at any point where the interpolated price
        // crosses a band threshold, each sub-segment stroked in the
        // color for its own (constant, by construction) band.
        function drawSegment(ctx, pointA, pointB, xFor, yFor) {
            var priceA = pointA.price
            var priceB = pointB.price

            // t=0 at pointA, t=1 at pointB; price and time (and therefore
            // both plotted axes) are linear in t, so a threshold crossing
            // is just where the linear interpolation of price equals that
            // threshold.
            var boundaries = [0, 1]
            var thresholds = [Comed.BAND_THRESHOLD_LOW, Comed.BAND_THRESHOLD_HIGH]
            for (var th = 0; th < thresholds.length; th++) {
                var threshold = thresholds[th]
                if (priceA === priceB) continue
                var crossT = (threshold - priceA) / (priceB - priceA)
                if (crossT > 0 && crossT < 1) {
                    boundaries.push(crossT)
                }
            }
            boundaries.sort(function(a, b) { return a - b })

            for (var s = 0; s < boundaries.length - 1; s++) {
                var tStart = boundaries[s]
                var tEnd = boundaries[s + 1]
                if (tEnd - tStart < 0.0001) continue

                var tMid = (tStart + tEnd) / 2
                var midPrice = priceA + tMid * (priceB - priceA)

                var startMillis = pointA.millisUtc + tStart * (pointB.millisUtc - pointA.millisUtc)
                var startPrice = priceA + tStart * (priceB - priceA)
                var endMillis = pointA.millisUtc + tEnd * (pointB.millisUtc - pointA.millisUtc)
                var endPrice = priceA + tEnd * (priceB - priceA)

                ctx.strokeStyle = Comed.colorForBand(Comed.bandForPrice(midPrice))
                ctx.beginPath()
                ctx.moveTo(xFor(startMillis), yFor(startPrice))
                ctx.lineTo(xFor(endMillis), yFor(endPrice))
                ctx.stroke()
            }
        }

        function formatCents(value, decimals) {
            return value.toFixed(decimals) + "\u00A2"
        }

        // Classic "nice numbers for graph labels" approach (Heckbert):
        // picks a tick spacing that's 1, 2, or 5 times a power of ten, so
        // labels land on round values instead of arbitrary fractions.
        function niceNumber(range, round) {
            if (range <= 0) return 1
            var exponent = Math.floor(Math.log(range) / Math.LN10)
            var fraction = range / Math.pow(10, exponent)
            var niceFraction

            if (round) {
                if (fraction < 1.5) niceFraction = 1
                else if (fraction < 3) niceFraction = 2
                else if (fraction < 7) niceFraction = 5
                else niceFraction = 10
            } else {
                if (fraction <= 1) niceFraction = 1
                else if (fraction <= 2) niceFraction = 2
                else if (fraction <= 5) niceFraction = 5
                else niceFraction = 10
            }
            return niceFraction * Math.pow(10, exponent)
        }

        function niceAxis(rawMin, rawMax, maxTicks) {
            if (rawMin === rawMax) {
                rawMin -= 1
                rawMax += 1
            }
            var range = niceNumber(rawMax - rawMin, false)
            var spacing = niceNumber(range / (maxTicks - 1), true)
            var niceMin = Math.floor(rawMin / spacing) * spacing
            var niceMax = Math.ceil(rawMax / spacing) * spacing

            var ticks = []
            for (var v = niceMin; v <= niceMax + spacing * 0.001; v += spacing) {
                ticks.push(v)
            }
            // Sub-cent spacing (e.g. 0.5, 0.2) needs a decimal place, or
            // adjacent ticks round to the same displayed label -- niceFraction
            // only ever lands on 1/2/5 x a power of ten, so one decimal
            // place always suffices whenever spacing is fractional.
            var decimals = spacing < 1 ? 1 : 0
            return { min: niceMin, max: niceMax, ticks: ticks, decimals: decimals }
        }
    }

    onPointsChanged: canvas.requestPaint()
    onChartStyleChanged: canvas.requestPaint()
    onAxisTextColorChanged: canvas.requestPaint()
    onGridColorChanged: canvas.requestPaint()
    onWidthChanged: canvas.requestPaint()
    onHeightChanged: canvas.requestPaint()
}
