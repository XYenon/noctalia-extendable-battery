import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Services.Hardware
import qs.Widgets

ColumnLayout {
  id: root
  spacing: Style.marginM

  property var pluginApi: null
  property var cfg: pluginApi?.pluginSettings || ({})
  property var widgetMetadata: pluginApi?.manifest?.metadata?.defaultSettings || ({})
  readonly property var mainInstance: pluginApi?.mainInstance

  // Local state
  property string valueDisplayMode: cfg.displayMode ?? widgetMetadata.displayMode
  property string valueDeviceKey: cfg.deviceKey ?? widgetMetadata.deviceKey
  property bool valueShowPowerProfiles: cfg.showPowerProfiles ?? widgetMetadata.showPowerProfiles
  property bool valueShowNoctaliaPerformance: cfg.showNoctaliaPerformance ?? widgetMetadata.showNoctaliaPerformance
  property bool valueHideIfNotDetected: cfg.hideIfNotDetected ?? widgetMetadata.hideIfNotDetected
  property bool valueHideIfIdle: cfg.hideIfIdle ?? widgetMetadata.hideIfIdle
  property bool valuePreferBluetooth: cfg.preferBluetooth ?? widgetMetadata.preferBluetooth
  property string valueDeviceNameFilter: cfg.deviceNameFilter ?? widgetMetadata.deviceNameFilter

  NComboBox {
    id: deviceComboBox
    Layout.fillWidth: true
    label: I18n.tr("bar.battery.device-label")
    description: I18n.tr("bar.battery.device-description")
    minimumWidth: 240
    model: root.mainInstance?.deviceModel || BatteryService.deviceModel
    currentKey: root.valueDeviceKey
    onSelected: key => root.valueDeviceKey = key
    defaultValue: widgetMetadata.deviceKey
  }

  NComboBox {
    Layout.fillWidth: true
    label: I18n.tr("common.display-mode")
    description: I18n.tr("bar.battery.display-mode-description")
    minimumWidth: 240
    model: [
      {
        "key": "graphic",
        "name": I18n.tr("bar.battery.display-mode-graphic")
      },
      {
        "key": "graphic-clean",
        "name": I18n.tr("bar.battery.display-mode-graphic-clean")
      },
      {
        "key": "icon-hover",
        "name": I18n.tr("bar.battery.display-mode-icon-hover")
      },
      {
        "key": "icon-always",
        "name": I18n.tr("bar.battery.display-mode-icon-always")
      },
      {
        "key": "icon-only",
        "name": I18n.tr("bar.battery.display-mode-icon-only")
      }
    ]
    currentKey: root.valueDisplayMode
    onSelected: key => root.valueDisplayMode = key
    defaultValue: widgetMetadata.displayMode
  }

  NToggle {
    label: I18n.tr("bar.battery.hide-if-not-detected-label")
    description: I18n.tr("bar.battery.hide-if-not-detected-description")
    checked: valueHideIfNotDetected
    onToggled: checked => valueHideIfNotDetected = checked
    defaultValue: widgetMetadata.hideIfNotDetected
  }

  NToggle {
    label: I18n.tr("bar.battery.hide-if-idle-label")
    description: I18n.tr("bar.battery.hide-if-idle-description")
    checked: valueHideIfIdle
    onToggled: checked => valueHideIfIdle = checked
    defaultValue: widgetMetadata.hideIfIdle
  }

  NDivider {
    Layout.fillWidth: true
  }

  NToggle {
    label: I18n.tr("bar.battery.show-power-profile-label")
    description: I18n.tr("bar.battery.show-power-profile-description")
    checked: valueShowPowerProfiles
    onToggled: checked => valueShowPowerProfiles = checked
    defaultValue: widgetMetadata.showPowerProfiles
  }

  NToggle {
    label: I18n.tr("bar.battery.show-noctalia-performance-label")
    description: I18n.tr("bar.battery.show-noctalia-performance-description")
    checked: valueShowNoctaliaPerformance
    onToggled: checked => valueShowNoctaliaPerformance = checked
    defaultValue: widgetMetadata.showNoctaliaPerformance
  }

  NDivider {
    Layout.fillWidth: true
  }

  NToggle {
    Layout.fillWidth: true
    label: pluginApi?.tr("settings.prefer-bluetooth") || "Prefer Bluetooth readings"
    description: pluginApi?.tr("settings.prefer-bluetooth-desc") || "Prefer Bluetooth when a provider reports multiple readings."
    checked: root.valuePreferBluetooth
    onToggled: checked => root.valuePreferBluetooth = checked
    defaultValue: widgetMetadata.preferBluetooth
  }

  NTextInput {
    Layout.fillWidth: true
    label: pluginApi?.tr("settings.device-filter") || "Device name filter"
    description: pluginApi?.tr("settings.device-filter-desc") || "Optional substring used to prefer a specific provider device."
    text: root.valueDeviceNameFilter
    onTextChanged: root.valueDeviceNameFilter = text
  }

  function saveSettings() {
    if (!pluginApi) {
      Logger.e("ExtendableBattery", "Cannot save: pluginApi is null");
      return;
    }

    pluginApi.pluginSettings.displayMode = root.valueDisplayMode;
    pluginApi.pluginSettings.deviceKey = root.valueDeviceKey;
    pluginApi.pluginSettings.showPowerProfiles = root.valueShowPowerProfiles;
    pluginApi.pluginSettings.showNoctaliaPerformance = root.valueShowNoctaliaPerformance;
    pluginApi.pluginSettings.hideIfNotDetected = root.valueHideIfNotDetected;
    pluginApi.pluginSettings.hideIfIdle = root.valueHideIfIdle;
    pluginApi.pluginSettings.preferBluetooth = root.valuePreferBluetooth;
    pluginApi.pluginSettings.deviceNameFilter = root.valueDeviceNameFilter;

    pluginApi.saveSettings();
    Logger.i("ExtendableBattery", "Settings saved");
  }
}
