pragma ComponentBehavior: Bound

import QtQuick

// Compatibility target for old direct links. The canonical TLP UI is part of
// GeneralConfig; opening this component therefore lands on System → Power
// instead of recreating a standalone Battery/TLP page.
GeneralConfig {
    activeSection: "power"
}
