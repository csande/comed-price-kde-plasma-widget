import QtQuick
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

Kirigami.FormLayout {
    id: page

    property alias cfg_graphHours: graphHoursSpin.value
    property alias cfg_chartStyle: chartStyleCombo.currentIndex
    property alias cfg_dataLineWidth: dataLineWidthSpin.value
    property alias cfg_dataLineAlpha: dataLineAlphaSlider.value
    property alias cfg_gridLineWidth: gridLineWidthSpin.value
    property alias cfg_gridLineAlpha: gridLineAlphaSlider.value
    property alias cfg_zeroLineWidth: zeroLineWidthSpin.value
    property alias cfg_zeroLineAlpha: zeroLineAlphaSlider.value

    QQC2.ComboBox {
        id: chartStyleCombo
        Kirigami.FormData.label: "Time series chart style:"
        // Index must match config/main.xml's chartStyle entry: 0 = Line, 1 = Bar.
        model: ["Line", "Bar"]
    }

    QQC2.SpinBox {
        id: graphHoursSpin
        Kirigami.FormData.label: "Time series history:"
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

    Kirigami.Separator {
        Kirigami.FormData.isSection: true
        Kirigami.FormData.label: "Data line (Line style only)"
    }

    QQC2.SpinBox {
        id: dataLineWidthSpin
        Kirigami.FormData.label: "Width:"
        from: 1
        to: 6
        stepSize: 1
        textFromValue: function(value, locale) {
            return value + "px"
        }
        valueFromText: function(text, locale) {
            return parseInt(text)
        }
    }

    QQC2.Slider {
        id: dataLineAlphaSlider
        Kirigami.FormData.label: "Opacity:"
        from: 0.0
        to: 1.0
        stepSize: 0.01
    }

    Kirigami.Separator {
        Kirigami.FormData.isSection: true
        Kirigami.FormData.label: "Horizontal gridlines"
    }

    QQC2.SpinBox {
        id: gridLineWidthSpin
        Kirigami.FormData.label: "Width:"
        from: 1
        to: 6
        stepSize: 1
        textFromValue: function(value, locale) {
            return value + "px"
        }
        valueFromText: function(text, locale) {
            return parseInt(text)
        }
    }

    QQC2.Slider {
        id: gridLineAlphaSlider
        Kirigami.FormData.label: "Opacity:"
        from: 0.0
        to: 1.0
        stepSize: 0.01
    }

    Kirigami.Separator {
        Kirigami.FormData.isSection: true
        Kirigami.FormData.label: "Zero line"
    }

    QQC2.SpinBox {
        id: zeroLineWidthSpin
        Kirigami.FormData.label: "Width:"
        from: 1
        to: 6
        stepSize: 1
        textFromValue: function(value, locale) {
            return value + "px"
        }
        valueFromText: function(text, locale) {
            return parseInt(text)
        }
    }

    QQC2.Slider {
        id: zeroLineAlphaSlider
        Kirigami.FormData.label: "Opacity:"
        from: 0.0
        to: 1.0
        stepSize: 0.01
    }
}
