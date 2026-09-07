import QtQuick
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

Kirigami.FormLayout {
    id: page

    property alias cfg_graphHours: graphHoursSpin.value
    property alias cfg_chartStyle: chartStyleCombo.currentIndex

    QQC2.ComboBox {
        id: chartStyleCombo
        Kirigami.FormData.label: "Trend chart style:"
        // Index must match config/main.xml's chartStyle entry: 0 = Line, 1 = Bar.
        model: ["Line", "Bar"]
    }

    QQC2.SpinBox {
        id: graphHoursSpin
        Kirigami.FormData.label: "Trend chart history:"
        from: 1
        to: 24
        stepSize: 1
        textFromValue: function(value, locale) {
            return value + (value === 1 ? " hour" : " hours")
        }
        valueFromText: function(text, locale) {
            return parseInt(text)
        }
    }
}
