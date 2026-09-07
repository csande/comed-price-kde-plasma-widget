import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents3
import org.kde.kirigami as Kirigami

Item {
    id: fullRoot

    property string priceText: ""
    property string timeText: ""
    property color priceColor: "#9E9E9E"
    property var historyPoints: []
    property bool refreshing: false

    signal refreshRequested()

    Layout.minimumWidth: Kirigami.Units.gridUnit * 10
    Layout.minimumHeight: Kirigami.Units.gridUnit * 10
    Layout.preferredWidth: Kirigami.Units.gridUnit * 14
    Layout.preferredHeight: Kirigami.Units.gridUnit * 12

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.smallSpacing
        spacing: Kirigami.Units.smallSpacing

        RowLayout {
            Layout.fillWidth: true

            PlasmaComponents3.Label {
                text: "ComEd Live Prices"
                font.pixelSize: Kirigami.Units.gridUnit
                elide: Text.ElideRight
            }

            Item {
                Layout.fillWidth: true
            }

            Item {
                implicitWidth: Kirigami.Units.iconSizes.small
                implicitHeight: Kirigami.Units.iconSizes.small

                PlasmaComponents3.ToolButton {
                    anchors.centerIn: parent
                    visible: !fullRoot.refreshing
                    icon.name: "view-refresh"
                    onClicked: fullRoot.refreshRequested()
                    PlasmaComponents3.ToolTip.text: "Refresh now"
                    PlasmaComponents3.ToolTip.visible: hovered
                }

                PlasmaComponents3.BusyIndicator {
                    anchors.centerIn: parent
                    visible: fullRoot.refreshing
                    running: fullRoot.refreshing
                    implicitWidth: Kirigami.Units.iconSizes.small
                    implicitHeight: Kirigami.Units.iconSizes.small
                }
            }

            PlasmaComponents3.Label {
                text: fullRoot.priceText
                color: fullRoot.priceColor
                font.bold: true
                font.pixelSize: Kirigami.Units.gridUnit * 1.6
                elide: Text.ElideRight
                Layout.leftMargin: Kirigami.Units.smallSpacing * 2
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: -Kirigami.Units.smallSpacing

            PlasmaComponents3.Label {
                text: "<a href=\"https://hourlypricing.comed.com/live-prices/\">https://hourlypricing.comed.com/live-prices/</a>"
                textFormat: Text.RichText
                opacity: 0.7
                font.pixelSize: Kirigami.Units.gridUnit * 0.7
                elide: Text.ElideMiddle
                Layout.maximumWidth: Kirigami.Units.gridUnit * 9
                onLinkActivated: Qt.openUrlExternally(link)

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.NoButton
                    cursorShape: Qt.PointingHandCursor
                }
            }

            Item {
                Layout.fillWidth: true
            }

            PlasmaComponents3.Label {
                text: fullRoot.timeText
                opacity: 0.7
                font.pixelSize: Kirigami.Units.gridUnit * 0.7
            }
        }

        PriceGraph {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: Kirigami.Units.gridUnit * 4
            points: fullRoot.historyPoints
            chartStyle: Plasmoid.configuration.chartStyle
        }
    }
}
