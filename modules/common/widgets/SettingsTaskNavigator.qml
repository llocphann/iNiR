pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.modules.common

ColumnLayout {
    id: root

    property string icon: "tune"
    property string title: ""
    property string description: ""
    property string summary: ""
    property string currentValue: ""
    property var options: []

    signal selected(string value)

    Layout.fillWidth: true
    spacing: 12

    Rectangle {
        Layout.fillWidth: true
        implicitHeight: introColumn.implicitHeight + 24
        radius: Appearance.rounding.normal
        color: Appearance.colors.colPrimaryContainer

        ColumnLayout {
            id: introColumn
            anchors.fill: parent
            anchors.margins: 12
            spacing: 9

            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                MaterialCookie {
                    implicitSize: 40
                    sides: 9
                    color: Appearance.colors.colPrimary
                    MaterialSymbol {
                        anchors.centerIn: parent
                        text: root.icon
                        iconSize: 19
                        color: Appearance.colors.colOnPrimary
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 1
                    StyledText {
                        Layout.fillWidth: true
                        text: root.title
                        font.pixelSize: Appearance.font.pixelSize.normal
                        font.weight: Font.DemiBold
                        color: Appearance.colors.colOnPrimaryContainer
                        wrapMode: Text.WordWrap
                    }
                    StyledText {
                        Layout.fillWidth: true
                        visible: root.description.length > 0
                        text: root.description
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colOnPrimaryContainer
                        opacity: 0.82
                        wrapMode: Text.WordWrap
                    }
                }
            }

            StyledText {
                Layout.fillWidth: true
                visible: root.summary.length > 0
                text: root.summary
                font.pixelSize: Appearance.font.pixelSize.smallest
                font.weight: Font.Medium
                color: Appearance.colors.colOnPrimaryContainer
                opacity: 0.76
                wrapMode: Text.WordWrap
            }
        }
    }

    ConfigSelectionArray {
        Layout.fillWidth: true
        currentValue: root.currentValue
        options: root.options
        onSelected: value => root.selected(value)
    }
}
