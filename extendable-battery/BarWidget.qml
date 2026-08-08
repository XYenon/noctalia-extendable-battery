import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Services.UPower
import qs.Commons
import qs.Modules.Bar.Extras
import qs.Services.Hardware
import qs.Services.Networking
import qs.Services.UI
import qs.Widgets

Item {
  id: root

  property var pluginApi: null
  property ShellScreen screen

  // Widget properties passed from Bar.qml for per-instance settings
  property string widgetId: ""
  property string section: ""
  property int sectionWidgetIndex: -1
  property int sectionWidgetsCount: 0

  property var cfg: pluginApi?.pluginSettings || ({})
  property var widgetMetadata: pluginApi?.manifest?.metadata?.defaultSettings || ({})
  readonly property var mainInstance: pluginApi?.mainInstance

  // Explicit screenName property ensures reactive binding when screen changes
  readonly property string screenName: screen ? screen.name : ""
  property var widgetSettings: {
    if (section && sectionWidgetIndex >= 0 && screenName) {
      var widgets = Settings.getBarWidgetsForScreen(screenName)[section];
      if (widgets && sectionWidgetIndex < widgets.length) {
        return widgets[sectionWidgetIndex];
      }
    }
    return {};
  }

  readonly property string barPosition: Settings.getBarPositionForScreen(screenName)
  readonly property bool isBarVertical: barPosition === "left" || barPosition === "right"
  readonly property real capsuleHeight: Style.getCapsuleHeightForScreen(screenName)

  readonly property string displayMode: widgetSettings.displayMode !== undefined ? widgetSettings.displayMode : (cfg.displayMode ?? widgetMetadata.displayMode)
  readonly property bool useGraphicMode: displayMode === "graphic" || displayMode === "graphic-clean"

  readonly property bool hideIfNotDetected: widgetSettings.hideIfNotDetected !== undefined ? widgetSettings.hideIfNotDetected : (cfg.hideIfNotDetected ?? widgetMetadata.hideIfNotDetected)
  readonly property bool hideIfIdle: widgetSettings.hideIfIdle !== undefined ? widgetSettings.hideIfIdle : (cfg.hideIfIdle ?? widgetMetadata.hideIfIdle)
  // Exposed so Panel can resolve power controls from the bar instance (like native panelID).
  readonly property bool showPowerProfiles: widgetSettings.showPowerProfiles !== undefined ? widgetSettings.showPowerProfiles : (cfg.showPowerProfiles ?? widgetMetadata.showPowerProfiles)
  readonly property bool showNoctaliaPerformance: widgetSettings.showNoctaliaPerformance !== undefined ? widgetSettings.showNoctaliaPerformance : (cfg.showNoctaliaPerformance ?? widgetMetadata.showNoctaliaPerformance)

  readonly property string deviceKey: widgetSettings.deviceKey !== undefined ? widgetSettings.deviceKey : (widgetSettings.deviceNativePath !== undefined ? widgetSettings.deviceNativePath : (cfg.deviceKey ?? widgetMetadata.deviceKey))
  // findDevice already applies the native present gate for UPower and provider devices.
  readonly property var selectedDevice: mainInstance?.findDevice(deviceKey) || null

  // Check if selected device is actually present/connected
  readonly property bool isReady: mainInstance?.isDeviceReady(selectedDevice) ?? false
  readonly property bool isPresent: mainInstance?.isDevicePresent(selectedDevice) ?? false
  readonly property real percent: isReady ? mainInstance.getPercentage(selectedDevice) : -1
  readonly property bool isCharging: isReady ? mainInstance.isCharging(selectedDevice) : false
  readonly property bool isPluggedIn: isReady ? mainInstance.isPluggedIn(selectedDevice) : false
  readonly property bool isLowBattery: isReady ? mainInstance.isLowBattery(selectedDevice) : false
  readonly property bool isCriticalBattery: isReady ? mainInstance.isCriticalBattery(selectedDevice) : false

  // Visibility: show if hideIfNotDetected is false, or if battery is ready
  readonly property bool shouldShow: !hideIfNotDetected || (isReady && (hideIfIdle ? !isPluggedIn : true))
  readonly property bool isProviderDevice: mainInstance?.isProviderDevice(selectedDevice) ?? false
  readonly property bool isInternal: isProviderDevice ? (selectedDevice?.kind === "system" || selectedDevice?.kind === "laptop") : !!selectedDevice?.isLaptopBattery
  readonly property bool isPanelOpen: pluginApi?.panelOpenScreen === root.screen

  readonly property var tooltipContent: {
    const _tick = mainInstance?.refreshNonce ?? 0;
    if (!isReady || !isPresent) {
      return I18n.tr("battery.no-battery-detected");
    }

    let rows = [];
    let timeText = "";
    let rateText = "";
    let healthDevice = null;
    if (isInternal) {
      // Show charge percentage
      rows.push([I18n.tr("battery.battery-level"), `${percent}%`]);

      timeText = mainInstance.getTimeRemainingText(selectedDevice);
      if (timeText) {
        const colonIdx = timeText.indexOf(":");
        if (colonIdx >= 0) {
          rows.push([timeText.substring(0, colonIdx).trim(), timeText.substring(colonIdx + 1).trim()]);
        } else {
          rows.push([timeText, ""]);
        }
      }

      rateText = mainInstance.getRateText(selectedDevice);
      if (!isPluggedIn && rateText) {
        const colonIdx = rateText.indexOf(":");
        if (colonIdx >= 0) {
          rows.push([rateText.substring(0, colonIdx).trim(), rateText.substring(colonIdx + 1).trim()]);
        } else {
          rows.push([rateText, ""]);
        }
      }

      // Show battery health if supported (check actual battery, not DisplayDevice)
      healthDevice = selectedDevice.healthSupported ? selectedDevice : (!isProviderDevice && BatteryService.laptopBatteries.length > 0 ? BatteryService.laptopBatteries[0] : null);
      if (healthDevice && healthDevice.healthSupported) {
        rows.push([I18n.tr("battery.battery-health"), `${Math.round(healthDevice.healthPercentage)}%`]);
      }
    } else if (selectedDevice) {
      // External / Peripheral Device (Phone, Keyboard, Mouse, Gamepad, Headphone etc.)
      let name = mainInstance.getDeviceName(selectedDevice);
      rows.push([name, `${percent}%`]);
    }

    // If we are showing the main laptop battery, append external devices
    // (Bluetooth path matches native Battery.qml; providers append after, deduped.)
    if (isInternal) {
      var external = BatteryService.bluetoothBatteries;
      if (external.length > 0) {
        if (rows.length > 0) {
          rows.push(["---", "---"]); // Separator
        }
        for (var j = 0; j < external.length; j++) {
          var dev = external[j];
          var dName = BatteryService.getDeviceName(dev);
          var dPct = BatteryService.getPercentage(dev);
          rows.push([dName, `${dPct}%`]);
        }
      }

      var providerDevices = mainInstance?.devices || [];
      var providerRows = [];
      for (var k = 0; k < providerDevices.length; k++) {
        var providerDevice = providerDevices[k];
        if (providerDevice.deviceKey === selectedDevice?.deviceKey || !mainInstance.isDeviceReady(providerDevice))
          continue;
        var duplicateNativeDevice = false;
        for (var n = 0; n < external.length; n++) {
          if (mainInstance.matchesNativeBluetooth(providerDevice, external[n])) {
            duplicateNativeDevice = true;
            break;
          }
        }
        if (duplicateNativeDevice)
          continue;
        providerRows.push([mainInstance.getDeviceName(providerDevice), `${mainInstance.getPercentage(providerDevice)}%`]);
      }

      if (providerRows.length > 0) {
        if (external.length === 0 && rows.length > 0) {
          rows.push(["---", "---"]); // Separator when no Bluetooth block above
        }
        for (var p = 0; p < providerRows.length; p++) {
          rows.push(providerRows[p]);
        }
      }
    }

    return rows;
  }

  visible: shouldShow
  opacity: shouldShow ? 1.0 : 0.0

  implicitWidth: useGraphicMode ? capsule.width : pill.width
  implicitHeight: useGraphicMode ? capsule.height : pill.height

  NPopupContextMenu {
    id: contextMenu

    model: [
      {
        "label": pluginApi?.tr("menu.refresh") || "Refresh",
        "action": "refresh",
        "icon": "refresh"
      },
      {
        "label": I18n.tr("actions.widget-settings"),
        "action": "widget-settings",
        "icon": "settings"
      },
    ]

    onTriggered: action => {
      contextMenu.close();
      PanelService.closeContextMenu(screen);

      if (action === "widget-settings") {
        BarService.openPluginSettings(root.screen, pluginApi.manifest);
      } else if (action === "refresh") {
        mainInstance?.refresh();
      }
    }
  }

  // ==================== GRAPHIC MODE ====================

  // Capsule background (graphic mode only)
  Rectangle {
    id: capsule
    visible: root.useGraphicMode
    anchors.centerIn: nBattery
    width: root.isBarVertical ? root.capsuleHeight : nBattery.width + Style.margin2S
    height: root.isBarVertical ? nBattery.height + Style.margin2S : root.capsuleHeight
    radius: Math.min(Style.radiusL, width / 2)
    color: graphicMouseArea.containsMouse ? Color.mHover : Style.capsuleColor
    border.color: Style.capsuleBorderColor
    border.width: Style.capsuleBorderWidth

    Behavior on color {
      enabled: !Color.isTransitioning
      ColorAnimation {
        duration: Style.animationFast
        easing.type: Easing.InOutQuad
      }
    }
  }

  NBattery {
    id: nBattery
    visible: root.useGraphicMode
    anchors.centerIn: parent
    baseSize: (Style.getBarHeightForScreen(root.screenName) / root.capsuleHeight) * Style.fontSizeXXS
    showPercentageText: root.displayMode !== "graphic-clean"
    vertical: root.isBarVertical
    percentage: root.percent
    ready: root.isReady
    charging: root.isCharging
    pluggedIn: root.isPluggedIn
    low: root.isLowBattery
    critical: root.isCriticalBattery
    baseColor: graphicMouseArea.containsMouse ? Color.mOnHover : Color.mOnSurface
    textColor: graphicMouseArea.containsMouse ? Color.mHover : Color.mSurface
  }

  MouseArea {
    id: graphicMouseArea
    visible: root.useGraphicMode
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    cursorShape: Qt.PointingHandCursor
    onEntered: {
      if (!root.isPanelOpen && root.tooltipContent) {
        TooltipService.show(root, root.tooltipContent, BarService.getTooltipDirection(root.screen?.name));
        tooltipRefreshTimer.start();
      }
    }
    onExited: {
      tooltipRefreshTimer.stop();
      TooltipService.hide();
    }
    onClicked: mouse => {
      TooltipService.hide();
      if (mouse.button === Qt.RightButton) {
        PanelService.showContextMenu(contextMenu, nBattery, screen);
      } else {
        pluginApi?.togglePanel(root.screen, root);
      }
    }
  }

  Timer {
    id: tooltipRefreshTimer
    interval: 1000
    repeat: true
    onTriggered: {
      if (graphicMouseArea.containsMouse) {
        TooltipService.updateText(root.tooltipContent);
      }
    }
  }

  // ==================== ICON MODE ====================

  BarPill {
    id: pill
    visible: !root.useGraphicMode
    screen: root.screen
    oppositeDirection: BarService.getPillDirection(root)
    icon: BatteryService.getIcon(root.percent, root.isCharging, root.isPluggedIn, root.isReady)
    text: root.isReady ? root.percent : "-"
    suffix: "%"
    autoHide: false
    forceOpen: root.isReady && root.displayMode === "icon-always"
    forceClose: root.displayMode === "icon-only" || !root.isReady
    customBackgroundColor: root.isCharging ? Color.mPrimary : ((root.isLowBattery || root.isCriticalBattery) ? Color.mError : "transparent")
    customTextIconColor: root.isCharging ? Color.mOnPrimary : ((root.isLowBattery || root.isCriticalBattery) ? Color.mOnError : "transparent")
    tooltipText: !root.isPanelOpen ? root.tooltipContent : ""
    onClicked: pluginApi?.togglePanel(root.screen, root)
    onRightClicked: PanelService.showContextMenu(contextMenu, pill, screen)
  }
}
