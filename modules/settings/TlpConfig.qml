pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.modules.common
import qs.modules.common.widgets

// Backward-compatible standalone target for old links/search results. The
// navigation no longer exposes this page; the canonical UI is System → Power.
ContentPage {
    settingsPageIndex: 28
    settingsPageName: Translation.tr("Battery")

    TlpPowerSettings {
        Layout.fillWidth: true
    }
}
