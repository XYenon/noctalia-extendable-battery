import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Services.UPower
import qs.Commons
import qs.Services.Hardware
import qs.Services.Networking
import qs.Services.Power
import qs.Services.UI
import qs.Widgets

Item {
  id: root

  property var pluginApi: null

  // SmartPanel sizing (same approach as native BatteryPanel)
  readonly property real contentPreferredWidth: Math.round(440 * Style.uiScaleRatio)
  readonly property real contentPreferredHeight: Math.round(mainLayout.implicitHeight + Style.margin2L)
  readonly property bool allowAttach: true

  readonly property var mainInstance: pluginApi?.mainInstance
  readonly property var cfg: pluginApi?.pluginSettings || ({})
  readonly property var widgetMetadata: pluginApi?.manifest?.metadata?.defaultSettings || ({})
  readonly property var allDevices: mainInstance?.devices || []

  // Resolve power-control flags from the bar widget instance (native BatteryPanel style).
  readonly property string pluginWidgetId: "plugin:" + (pluginApi?.pluginId || "extendable-battery")
  property int widgetLookupNonce: 0
  readonly property var barWidgetInstance: {
    const _tick = widgetLookupNonce;
    return BarService.lookupWidget(pluginWidgetId, pluginApi?.panelOpenScreen?.name || null);
  }
  readonly property var barWidgetSettings: barWidgetInstance ? barWidgetInstance.widgetSettings : null

  readonly property bool powerProfileAvailable: PowerProfileService.available
  readonly property var powerProfiles: [PowerProfile.PowerSaver, PowerProfile.Balanced, PowerProfile.Performance]
  readonly property bool profilesAvailable: PowerProfileService.available
  property int profileIndex: profileToIndex(PowerProfileService.profile)
  readonly property bool showPowerProfiles: resolveWidgetSetting("showPowerProfiles", false)
  readonly property bool showNoctaliaPerformance: resolveWidgetSetting("showNoctaliaPerformance", false)

  function profileToIndex(p) {
    const index = powerProfiles.indexOf(p);
    return index >= 0 ? index : 1;
  }

  function indexToProfile(idx) {
    return powerProfiles[idx] ?? PowerProfile.Balanced;
  }

  function setProfileByIndex(idx) {
    var prof = indexToProfile(idx);
    profileIndex = idx;
    PowerProfileService.setProfile(prof);
  }

  // Prefer bar-instance settings, then the instance's resolved props, then plugin settings/defaults.
  function resolveWidgetSetting(key, defaultValue) {
    if (barWidgetSettings && barWidgetSettings[key] !== undefined)
      return barWidgetSettings[key];
    if (barWidgetInstance && barWidgetInstance[key] !== undefined)
      return barWidgetInstance[key];
    if (cfg && cfg[key] !== undefined)
      return cfg[key];
    if (widgetMetadata && widgetMetadata[key] !== undefined)
      return widgetMetadata[key];
    return defaultValue;
  }

  Connections {
    target: PowerProfileService
    function onProfileChanged() {
      root.profileIndex = root.profileToIndex(PowerProfileService.profile);
    }
  }

  Connections {
    target: BarService
    function onActiveWidgetsChanged() {
      root.widgetLookupNonce++;
    }
  }

  // Filter provider devices; avoid duplicating laptop batteries already handled by UPower
  readonly property var displayDevices: {
    const hasNativeLaptop = BatteryService.laptopBatteries && BatteryService.laptopBatteries.length > 0;
    const ok = [];
    const pending = [];
    for (var i = 0; i < allDevices.length; i++) {
      const d = allDevices[i];
      if (hasNativeLaptop && (d.kind === "system" || d.protocol === "sysfs"))
        continue;
      var duplicateBluetooth = false;
      if (d.transport === "bluetooth" || d.protocol === "bluez") {
        for (var j = 0; j < BatteryService.bluetoothBatteries.length; j++) {
          var nativeBluetooth = BatteryService.bluetoothBatteries[j];
          if (mainInstance?.matchesNativeBluetooth(d, nativeBluetooth)) {
            duplicateBluetooth = true;
            break;
          }
        }
      }
      if (duplicateBluetooth)
        continue;
      if (mainInstance?.isDeviceReady(d))
        ok.push(d);
      else
        pending.push(d);
    }
    return ok.length > 0 ? ok : pending;
  }

  readonly property var primaryDevice: mainInstance?.findDevice(cfg.deviceKey ?? widgetMetadata.deviceKey) || BatteryService.primaryDevice
  readonly property bool headerReady: mainInstance?.isDeviceReady(primaryDevice) ?? false
  readonly property real headerPercent: headerReady ? mainInstance.getPercentage(primaryDevice) : -1
  readonly property bool headerCharging: headerReady ? mainInstance.isCharging(primaryDevice) : false
  readonly property bool headerPluggedIn: headerReady ? mainInstance.isPluggedIn(primaryDevice) : false
  readonly property bool headerCritical: headerReady ? mainInstance.isCriticalBattery(primaryDevice) : false
  readonly property bool headerLow: headerReady ? mainInstance.isLowBattery(primaryDevice) : false
  readonly property string headerIcon: BatteryService.getIcon(headerPercent, headerCharging, headerPluggedIn, headerReady)

  function deviceKind(d) {
    if (d && d.kind && d.kind !== "unknown")
      return d.kind;

    const n = ((d && d.name) || "").toLowerCase();
    const p = ((d && d.protocol) || "").toLowerCase();

    if (n.indexOf("mouse") !== -1)
      return "mouse";
    if (n.indexOf("keyboard") !== -1)
      return "keyboard";
    if (n.indexOf("dongle") !== -1 || n.indexOf("receiver") !== -1) {
      if (p.indexOf("mouse") !== -1 || p.indexOf("rf") !== -1)
        return "mouse";
      return "dongle";
    }
    if (p.indexOf("mouse") !== -1 || p.indexOf("rf") !== -1)
      return "mouse";
    return "unknown";
  }

  function deviceTypeIcon(d) {
    const kind = deviceKind(d);
    if (kind === "system" || kind === "laptop")
      return d.charging ? "plug" : "battery";
    if (kind === "mouse")
      return "mouse-2";
    if (kind === "keyboard")
      return "keyboard";
    if (kind === "dongle")
      return "usb";
    const n = ((d && d.name) || "").toLowerCase();
    if (n.indexOf("headphone") !== -1 || n.indexOf("headset") !== -1)
      return "headphones";
    if (n.indexOf("trackball") !== -1)
      return "mouse-2";
    return "usb";
  }

  function deviceTitle(d) {
    if (d.name && d.name.length)
      return d.name;
    return pluginApi?.tr("panel.unnamed-device") || "Battery Device";
  }

  function deviceStatusText(d) {
    const ready = mainInstance?.isDeviceReady(d) ?? false;
    if (!ready)
      return "";

    const parts = [];
    if (mainInstance.isCharging(d))
      parts.push(pluginApi?.tr("status.charging") || "Charging");
    else if (mainInstance.isPluggedIn(d))
      parts.push(I18n.tr("battery.plugged-in"));
    if (d.timeToFull > 0 || d.timeToEmpty > 0)
      parts.push(mainInstance.getTimeRemainingText(d));
    if (d.transport)
      parts.push(d.transport);
    return parts.join(" · ");
  }

  function closeThisPanel() {
    if (pluginApi && pluginApi.panelOpenScreen)
      pluginApi.closePanel(pluginApi.panelOpenScreen);
    else if (pluginApi)
      pluginApi.withCurrentScreen(function (screen) {
        pluginApi.closePanel(screen);
      });
  }

  ColumnLayout {
    id: mainLayout
    anchors.fill: parent
    anchors.margins: Style.marginL
    spacing: Style.marginM

    // HEADER (Reused from native BatteryPanel.qml)
    NBox {
      Layout.fillWidth: true
      implicitHeight: headerRow.implicitHeight + Style.margin2M

      RowLayout {
        id: headerRow
        anchors.fill: parent
        anchors.margins: Style.marginM
        spacing: Style.marginM

        NIcon {
          pointSize: Style.fontSizeXXL
          color: (root.headerCharging || root.headerPluggedIn) ? Color.mPrimary : (root.headerCritical || root.headerLow) ? Color.mError : Color.mOnSurface
          icon: root.headerIcon
        }

        ColumnLayout {
          spacing: Style.marginXXS
          Layout.fillWidth: true

          NText {
            text: I18n.tr("common.battery")
            pointSize: Style.fontSizeL
            font.weight: Style.fontWeightBold
            color: Color.mOnSurface
            Layout.fillWidth: true
            elide: Text.ElideRight
          }
        }

        NIconButton {
          icon: "refresh"
          tooltipText: pluginApi?.tr("panel.refresh") || "Refresh"
          baseSize: Style.baseWidgetSize * 0.8
          enabled: !(mainInstance?.isRefreshing ?? false)
          onClicked: mainInstance?.refresh()
        }

        NIconButton {
          icon: "close"
          tooltipText: I18n.tr("common.close")
          baseSize: Style.baseWidgetSize * 0.8
          onClicked: root.closeThisPanel()
        }
      }
    }

    // Charge level + health/time
    NBox {
      Layout.fillWidth: true
      implicitHeight: chargeLayout.implicitHeight + Style.margin2L
      visible: BatteryService.laptopBatteries.length > 0 || BatteryService.bluetoothBatteries.length > 0 || displayDevices.length > 0

      ColumnLayout {
        id: chargeLayout
        anchors.fill: parent
        anchors.margins: Style.marginL
        spacing: Style.marginL

        // Direct reuse: Laptop batteries section from native BatteryPanel.qml
        Repeater {
          model: BatteryService.laptopBatteries
          delegate: ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.marginS

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.marginS

              ColumnLayout {
                Layout.fillWidth: true
                spacing: Style.marginS

                RowLayout {
                  Item {
                    id: batteryInfoItem
                    implicitWidth: batteryInfoRow.implicitWidth
                    implicitHeight: batteryInfoRow.implicitHeight

                    RowLayout {
                      id: batteryInfoRow
                      anchors.fill: parent

                      NIcon {
                        icon: BatteryService.getIcon(BatteryService.getPercentage(modelData), BatteryService.isCharging(modelData), BatteryService.isPluggedIn(modelData), BatteryService.isDeviceReady(modelData))
                        color: (BatteryService.isCharging(modelData) || BatteryService.isPluggedIn(modelData)) ? Color.mPrimary : (BatteryService.isCriticalBattery(modelData) || BatteryService.isLowBattery(modelData)) ? Color.mError : Color.mOnSurface
                      }

                      NText {
                        readonly property string dName: BatteryService.getDeviceName(modelData)
                        text: dName ? dName : I18n.tr("common.battery")
                        color: (BatteryService.isCharging(modelData) || BatteryService.isPluggedIn(modelData)) ? Color.mPrimary : (BatteryService.isCriticalBattery(modelData) || BatteryService.isLowBattery(modelData)) ? Color.mError : Color.mOnSurface
                        pointSize: Style.fontSizeS
                      }
                    }

                    MouseArea {
                      anchors.fill: parent
                      hoverEnabled: true
                      onEntered: {
                        if (modelData.healthSupported) {
                          TooltipService.show(batteryInfoItem, `${I18n.tr("battery.battery-health")}: ${Math.round(modelData.healthPercentage)}%`);
                        }
                      }
                      onExited: TooltipService.hide(batteryInfoItem)
                    }
                  }

                  Item {
                    Layout.fillWidth: true
                  }

                  NText {
                    text: BatteryService.getTimeRemainingText(modelData)
                    pointSize: Style.fontSizeS
                    color: Color.mOnSurfaceVariant
                  }
                }

                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.marginS
                  Rectangle {
                    Layout.fillWidth: true
                    height: Math.round(8 * Style.uiScaleRatio)
                    radius: Math.min(Style.radiusL, height / 2)
                    color: Color.mSurface

                    Rectangle {
                      anchors.verticalCenter: parent.verticalCenter
                      height: parent.height
                      radius: parent.radius
                      width: {
                        var p = BatteryService.getPercentage(modelData);
                        var ratio = Math.max(0, Math.min(1, p / 100));
                        return parent.width * ratio;
                      }
                      color: Color.mPrimary
                    }
                  }

                  NText {
                    Layout.preferredWidth: 40 * Style.uiScaleRatio
                    horizontalAlignment: Text.AlignRight
                    text: `${BatteryService.getPercentage(modelData)}%`
                    color: (BatteryService.isCharging(modelData) || BatteryService.isPluggedIn(modelData)) ? Color.mPrimary : (BatteryService.isCriticalBattery(modelData) || BatteryService.isLowBattery(modelData)) ? Color.mError : Color.mOnSurface
                    pointSize: Style.fontSizeS
                    font.weight: Style.fontWeightBold
                  }
                }
              }
            }
          }
        }

        NDivider {
          Layout.fillWidth: true
          visible: BatteryService.laptopBatteries.length > 0 && (BatteryService.bluetoothBatteries.length > 0 || displayDevices.length > 0)
        }

        // Other devices (Bluetooth) section
        Repeater {
          model: BatteryService.bluetoothBatteries
          delegate: ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.marginS
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.marginS

              NIcon {
                icon: BluetoothService.getDeviceIcon(modelData)
                color: (BatteryService.isCharging(modelData) || BatteryService.isPluggedIn(modelData)) ? Color.mPrimary : (BatteryService.isCriticalBattery(modelData) || BatteryService.isLowBattery(modelData)) ? Color.mError : Color.mOnSurface
              }

              NText {
                readonly property string dName: BatteryService.getDeviceName(modelData)
                text: dName ? dName : I18n.tr("common.bluetooth")
                color: (BatteryService.isCharging(modelData) || BatteryService.isPluggedIn(modelData)) ? Color.mPrimary : (BatteryService.isCriticalBattery(modelData) || BatteryService.isLowBattery(modelData)) ? Color.mError : Color.mOnSurface
                pointSize: Style.fontSizeS
              }
            }
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.marginS

              Rectangle {
                Layout.fillWidth: true
                height: Math.round(8 * Style.uiScaleRatio)
                radius: Math.min(Style.radiusL, height / 2)
                color: Color.mSurface

                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  height: parent.height
                  radius: parent.radius
                  width: {
                    var p = BatteryService.getPercentage(modelData);
                    var ratio = Math.max(0, Math.min(1, p / 100));
                    return parent.width * ratio;
                  }
                  color: Color.mPrimary
                }
              }

              NText {
                Layout.preferredWidth: 40 * Style.uiScaleRatio
                horizontalAlignment: Text.AlignRight
                text: `${BatteryService.getPercentage(modelData)}%`
                color: (BatteryService.isCharging(modelData) || BatteryService.isPluggedIn(modelData)) ? Color.mPrimary : (BatteryService.isCriticalBattery(modelData) || BatteryService.isLowBattery(modelData)) ? Color.mError : Color.mOnSurface
                pointSize: Style.fontSizeS
                font.weight: Style.fontWeightBold
              }
            }
          }
        }

        NDivider {
          Layout.fillWidth: true
          visible: BatteryService.bluetoothBatteries.length > 0 && displayDevices.length > 0
        }

        // Provider devices section
        Repeater {
          model: displayDevices

          delegate: ColumnLayout {
            id: deviceRow
            required property var modelData
            Layout.fillWidth: true
            spacing: Style.marginS

            readonly property bool ok: root.mainInstance?.isDeviceReady(modelData) ?? false
            readonly property real pct: ok ? root.mainInstance.getPercentage(modelData) : -1
            readonly property bool charging: ok && root.mainInstance.isCharging(modelData)
            readonly property bool pluggedIn: ok && root.mainInstance.isPluggedIn(modelData)
            readonly property bool isLow: ok && root.mainInstance.isLowBattery(modelData)
            readonly property bool isCritical: ok && root.mainInstance.isCriticalBattery(modelData)
            readonly property color accent: (charging || pluggedIn) ? Color.mPrimary : (isCritical || isLow) ? Color.mError : Color.mOnSurface

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.marginS

              NIcon {
                icon: root.deviceTypeIcon(deviceRow.modelData)
                color: deviceRow.accent
              }

              NText {
                text: root.deviceTitle(deviceRow.modelData)
                color: deviceRow.accent
                pointSize: Style.fontSizeS
                elide: Text.ElideRight
                Layout.fillWidth: true

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  onEntered: {
                    if (deviceRow.modelData.healthSupported) {
                      TooltipService.show(parent, `${I18n.tr("battery.battery-health")}: ${Math.round(deviceRow.modelData.healthPercentage)}%`);
                    }
                  }
                  onExited: TooltipService.hide(parent)
                }
              }

              NText {
                visible: root.deviceStatusText(deviceRow.modelData).length > 0
                text: root.deviceStatusText(deviceRow.modelData)
                pointSize: Style.fontSizeS
                color: Color.mOnSurfaceVariant
              }
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.marginS

              Rectangle {
                Layout.fillWidth: true
                height: Math.round(8 * Style.uiScaleRatio)
                radius: Math.min(Style.radiusL, height / 2)
                color: Color.mSurface

                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  height: parent.height
                  radius: parent.radius
                  width: {
                    if (!deviceRow.ok)
                      return 0;
                    var p = deviceRow.pct;
                    var ratio = Math.max(0, Math.min(1, p / 100));
                    return parent.width * ratio;
                  }
                  color: Color.mPrimary
                }
              }

              NText {
                Layout.preferredWidth: 40 * Style.uiScaleRatio
                horizontalAlignment: Text.AlignRight
                text: deviceRow.ok ? `${deviceRow.pct}%` : "--"
                color: deviceRow.accent
                pointSize: Style.fontSizeS
                font.weight: Style.fontWeightBold
              }
            }

            NText {
              visible: !!(deviceRow.modelData.error) && !deviceRow.ok
              Layout.fillWidth: true
              wrapMode: Text.WordWrap
              text: deviceRow.modelData.error || ""
              pointSize: Style.fontSizeXXS
              color: Color.mError
            }
          }
        }
      }
    }

    NBox {
      Layout.fillWidth: true
      height: controlsLayout.implicitHeight + Style.margin2L
      visible: showPowerProfiles || showNoctaliaPerformance

      ColumnLayout {
        id: controlsLayout
        anchors.fill: parent
        anchors.margins: Style.marginL
        spacing: Style.marginM

        ColumnLayout {
          visible: powerProfileAvailable && showPowerProfiles

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.marginS

            NText {
              text: I18n.tr("battery.power-profile")
              font.weight: Style.fontWeightBold
              color: Color.mOnSurface
              Layout.fillWidth: true
            }

            NText {
              text: PowerProfileService.getName(root.profileIndex)
              color: Color.mOnSurfaceVariant
            }
          }

          NValueSlider {
            Layout.fillWidth: true
            from: 0
            to: 2
            stepSize: 1
            snapAlways: true
            heightRatio: 0.5
            value: root.profileIndex
            enabled: profilesAvailable
            onPressedChanged: (pressed, v) => {
              if (!pressed) {
                root.setProfileByIndex(v);
              }
            }
            onMoved: v => {
              root.profileIndex = v;
            }
          }

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.marginS

            NIcon {
              icon: "powersaver"
              pointSize: Style.fontSizeS
              color: PowerProfileService.getIcon() === "powersaver" ? Color.mPrimary : Color.mOnSurfaceVariant
            }

            NIcon {
              icon: "balanced"
              pointSize: Style.fontSizeS
              color: PowerProfileService.getIcon() === "balanced" ? Color.mPrimary : Color.mOnSurfaceVariant
              Layout.fillWidth: true
            }

            NIcon {
              icon: "performance"
              pointSize: Style.fontSizeS
              color: PowerProfileService.getIcon() === "performance" ? Color.mPrimary : Color.mOnSurfaceVariant
            }
          }
        }

        NDivider {
          Layout.fillWidth: true
          visible: showPowerProfiles && PowerProfileService.available && showNoctaliaPerformance
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.marginS
          visible: showNoctaliaPerformance

          NText {
            text: I18n.tr("toast.noctalia-performance.label")
            pointSize: Style.fontSizeM
            font.weight: Style.fontWeightBold
            color: Color.mOnSurface
            Layout.fillWidth: true
          }

          NIcon {
            icon: PowerProfileService.noctaliaPerformanceMode ? "rocket" : "rocket-off"
            pointSize: Style.fontSizeL
            color: PowerProfileService.noctaliaPerformanceMode ? Color.mPrimary : Color.mOnSurfaceVariant
          }

          NToggle {
            checked: PowerProfileService.noctaliaPerformanceMode
            onToggled: checked => PowerProfileService.noctaliaPerformanceMode = checked
          }
        }
      }
    }
  }
}
