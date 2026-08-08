import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Widgets

ColumnLayout {
  id: root

  property var pluginApi: null
  property var cfg: pluginApi?.pluginSettings || ({})
  property var defaults: pluginApi?.manifest?.metadata?.defaultSettings || ({})

  property int editRefreshIntervalMs: cfg.refreshIntervalMs ?? defaults.refreshIntervalMs ?? 60000
  property bool editEnableBluetooth: cfg.enableBluetooth ?? defaults.enableBluetooth ?? true
  property string editBluetoothNameFilter: cfg.bluetoothNameFilter ?? defaults.bluetoothNameFilter ?? "keychron"
  property int editWarningThreshold: cfg.warningThreshold ?? defaults.warningThreshold ?? 20
  property int editCriticalThreshold: cfg.criticalThreshold ?? defaults.criticalThreshold ?? 5
  property bool editNotificationsEnabled: cfg.notificationsEnabled ?? defaults.notificationsEnabled ?? true

  spacing: Style.marginM

  NToggle {
    Layout.fillWidth: true
    label: pluginApi?.tr("settings.enable-bluetooth") || "Enable Bluetooth readings"
    description: pluginApi?.tr("settings.enable-bluetooth-desc") || "Read battery information exposed by BlueZ."
    checked: root.editEnableBluetooth
    onToggled: checked => root.editEnableBluetooth = checked
  }

  NTextInput {
    Layout.fillWidth: true
    label: pluginApi?.tr("settings.bluetooth-filter") || "Bluetooth name filter"
    description: pluginApi?.tr("settings.bluetooth-filter-desc") || "Only include Bluetooth devices whose name contains this text."
    text: root.editBluetoothNameFilter
    onTextChanged: root.editBluetoothNameFilter = text
  }

  NDivider {
    Layout.fillWidth: true
  }

  NToggle {
    Layout.fillWidth: true
    label: pluginApi?.tr("settings.notifications-enabled") || "Battery notifications"
    description: pluginApi?.tr("settings.notifications-enabled-desc") || "Show low and critical battery notifications once per discharge cycle."
    checked: root.editNotificationsEnabled
    defaultValue: defaults.notificationsEnabled ?? true
    onToggled: checked => root.editNotificationsEnabled = checked
  }

  NTextInput {
    Layout.fillWidth: true
    label: pluginApi?.tr("settings.warning-threshold") || "Low battery threshold (%)"
    description: pluginApi?.tr("settings.warning-threshold-desc") || "Percentage at which a low-battery notification is shown."
    text: "" + root.editWarningThreshold
    onEditingFinished: {
      const n = parseInt(text, 10);
      if (!isNaN(n) && n >= root.editCriticalThreshold && n <= 100)
        root.editWarningThreshold = n;
    }
  }

  NTextInput {
    Layout.fillWidth: true
    label: pluginApi?.tr("settings.critical-threshold") || "Critical battery threshold (%)"
    description: pluginApi?.tr("settings.critical-threshold-desc") || "Percentage at which a critical-battery notification is shown."
    text: "" + root.editCriticalThreshold
    onEditingFinished: {
      const n = parseInt(text, 10);
      if (!isNaN(n) && n >= 0 && n <= root.editWarningThreshold)
        root.editCriticalThreshold = n;
    }
  }

  NTextInput {
    Layout.fillWidth: true
    label: pluginApi?.tr("settings.refresh-interval") || "Refresh interval (ms)"
    description: pluginApi?.tr("settings.refresh-interval-desc") || "How often to query HID and BlueZ (minimum 5000)."
    text: "" + root.editRefreshIntervalMs
    onEditingFinished: {
      const n = parseInt(text, 10);
      if (!isNaN(n) && n >= 5000)
        root.editRefreshIntervalMs = n;
    }
  }

  function saveSettings() {
    if (!pluginApi) {
      Logger.e("KeychronBatteryProvider", "Cannot save: pluginApi is null");
      return;
    }

    pluginApi.pluginSettings.refreshIntervalMs = root.editRefreshIntervalMs;
    pluginApi.pluginSettings.enableBluetooth = root.editEnableBluetooth;
    pluginApi.pluginSettings.bluetoothNameFilter = root.editBluetoothNameFilter;
    pluginApi.pluginSettings.warningThreshold = root.editWarningThreshold;
    pluginApi.pluginSettings.criticalThreshold = root.editCriticalThreshold;
    pluginApi.pluginSettings.notificationsEnabled = root.editNotificationsEnabled;
    pluginApi.saveSettings();
  }
}
