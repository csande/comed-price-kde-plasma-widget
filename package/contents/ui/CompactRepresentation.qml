import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents3
import org.kde.kirigami as Kirigami

Item {
    id: compactRoot

    property string priceText: ""
    property string timeText: ""
    property color priceColor: "#9E9E9E"
    property bool refreshing: false

    // Toggling Plasmoid.expanded from here doesn't work: that attached
    // property type (org.kde.plasma.plasmoid's "Plasmoid") doesn't
    // actually expose "expanded" -- that property belongs to the root
    // PlasmoidItem instance itself (in main.qml), inherited from the
    // underlying C++ AppletQuickItem. So the toggle request is emitted
    // here and handled by main.qml, which does have direct access to it.
    signal togglePopupRequested()

    Layout.minimumWidth: Math.max(contentColumn.implicitWidth, spinner.implicitWidth) + Kirigami.Units.smallSpacing * 2
    Layout.minimumHeight: Math.max(contentColumn.implicitHeight, spinner.implicitHeight) + Kirigami.Units.smallSpacing * 2

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        // Opens the full representation as a popup (more data, plus its
        // own refresh button) rather than refreshing directly from here.
        onClicked: compactRoot.togglePopupRequested()

        ColumnLayout {
            id: contentColumn
            anchors.centerIn: parent
            visible: !compactRoot.refreshing
            spacing: 0

            PlasmaComponents3.Label {
                id: priceLabel
                Layout.alignment: Qt.AlignHCenter
                text: compactRoot.priceText
                color: compactRoot.priceColor
                font.bold: true
            }

            PlasmaComponents3.Label {
                Layout.alignment: Qt.AlignHCenter
                text: compactRoot.timeText
                opacity: 0.7
                font.pixelSize: Kirigami.Units.gridUnit * 0.43
            }
        }

        PlasmaComponents3.BusyIndicator {
            id: spinner
            anchors.centerIn: parent
            visible: compactRoot.refreshing
            running: compactRoot.refreshing
            implicitWidth: Kirigami.Units.iconSizes.small
            implicitHeight: Kirigami.Units.iconSizes.small
        }
    }
}
