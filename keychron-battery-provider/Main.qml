import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Services.Noctalia

Item {
  id: root

  property var pluginApi: null
  property var cfg: pluginApi?.pluginSettings || ({})
  property var defaults: pluginApi?.manifest?.metadata?.defaultSettings || ({})

  readonly property int refreshIntervalMs: Math.max(5000, cfg.refreshIntervalMs ?? defaults.refreshIntervalMs ?? 60000)
  readonly property bool enableBluetooth: cfg.enableBluetooth ?? defaults.enableBluetooth ?? true
  readonly property string bluetoothNameFilter: (cfg.bluetoothNameFilter ?? defaults.bluetoothNameFilter ?? "keychron").trim()
  readonly property int warningThreshold: cfg.warningThreshold ?? defaults.warningThreshold ?? 20
  readonly property int criticalThreshold: cfg.criticalThreshold ?? defaults.criticalThreshold ?? 5
  readonly property bool notificationsEnabled: cfg.notificationsEnabled ?? defaults.notificationsEnabled ?? true

  property var batteryManager: null
  property string batteryManagerPluginKey: ""
  property var devices: []
  property string lastError: ""
  property bool isRefreshing: false

  readonly property var provider: ({
      id: "keychron",
      name: "Keychron HID & Bluetooth",
      warningThreshold: root.warningThreshold,
      criticalThreshold: root.criticalThreshold,
      notificationsEnabled: root.notificationsEnabled,
      getDevices: function () {
        return root.devices;
      },
      refresh: function () {
        root.refresh();
      }
    })

  function findBatteryManagerEntry() {
    const loadedPlugins = PluginService.loadedPlugins || ({});
    const keys = Object.keys(loadedPlugins);
    for (var i = 0; i < keys.length; i++) {
      const loaded = loadedPlugins[keys[i]];
      if (loaded?.manifest?.id === "extendable-battery" && loaded.mainInstance)
        return {
          key: keys[i],
          manager: loaded.mainInstance
        };
    }
    return null;
  }

  function hasCurrentBatteryManager() {
    if (!batteryManager || !batteryManagerPluginKey)
      return false;
    return PluginService.loadedPlugins?.[batteryManagerPluginKey]?.mainInstance === batteryManager;
  }

  function registerProvider() {
    if (!provider?.id)
      return false;

    const entry = findBatteryManagerEntry();
    if (!entry)
      return false;

    batteryManager = entry.manager;
    batteryManagerPluginKey = entry.key;
    batteryManager.registerBatteryProvider(provider);
    return true;
  }

  function publishDevices() {
    if (!hasCurrentBatteryManager()) {
      batteryManager = null;
      batteryManagerPluginKey = "";
    }
    if (!batteryManager && !registerProvider())
      return;
    batteryManager.aggregateAllDevices();
  }

  function refresh() {
    if (!pluginApi?.pluginDir || scanProcess.running)
      return;

    const command = ["python3", `${pluginApi.pluginDir}/scripts/keychron_battery.py`];
    if (!enableBluetooth)
      command.push("--no-bluez");
    if (bluetoothNameFilter.length > 0)
      command.push("--bluez-filter", bluetoothNameFilter);

    isRefreshing = true;
    scanProcess.command = command;
    scanProcess.running = true;
  }

  function deviceId(device) {
    return String(device.id || "");
  }

  function completeDevice(device) {
    const percent = typeof device.percent === "number" ? device.percent : -1;
    const present = device.present !== undefined ? !!device.present : device.connected !== false;
    return Object.assign({}, device, {
      id: deviceId(device),
      present: present,
      ready: device.ready !== undefined ? !!device.ready : present && percent >= 0,
      percent: percent,
      charging: !!device.charging,
      pluggedIn: !!device.pluggedIn,
      timeToFull: Number(device.timeToFull || 0),
      timeToEmpty: Number(device.timeToEmpty || 0),
      changeRate: Number(device.changeRate || 0),
      healthSupported: !!device.healthSupported,
      healthPercentage: Number(device.healthPercentage || 0),
      kind: device.kind || "unknown",
      protocol: device.protocol || "",
      transport: device.transport || "",
      status: device.status || 0,
      error: device.error || ""
    });
  }

  function applySnapshot(text) {
    try {
      const snapshot = JSON.parse((text || "").trim());
      const nextDevices = snapshot.devices || [];
      const previousById = {};
      for (var i = 0; i < devices.length; i++) {
        if (devices[i].id && devices[i].ready)
          previousById[devices[i].id] = devices[i];
      }
      devices = nextDevices.map(function (device) {
        const next = root.completeDevice(device);
        const previous = previousById[next.id];
        if (!next.ready && next.present && previous)
          return Object.assign({}, next, previous, {
            present: true,
            connected: next.connected,
            error: ""
          });
        return next;
      });
      lastError = devices.some(device => device.ready) ? "" : (snapshot.error || "");
    } catch (e) {
      devices = [];
      lastError = "Failed to parse battery JSON: " + e;
    }
    publishDevices();
  }

  Component.onCompleted: {
    registerProvider();
  }

  Component.onDestruction: {
    if (hasCurrentBatteryManager())
      batteryManager.unregisterBatteryProvider("keychron");
  }

  Process {
    id: scanProcess
    running: false
    stdout: StdioCollector {
      id: scanStdout
    }
    stderr: StdioCollector {
      id: scanStderr
    }

    onExited: function (exitCode, exitStatus) {
      root.isRefreshing = false;
      const stdout = String(scanStdout.text || "");
      if (stdout.trim().length > 0) {
        root.applySnapshot(stdout);
      } else {
        root.devices = [];
        root.lastError = String(scanStderr.text || "").trim() || ("battery script exit " + exitCode);
        root.publishDevices();
      }
    }
  }

  Timer {
    interval: root.refreshIntervalMs
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 1000
    repeat: true
    running: !root.batteryManager
    triggeredOnStart: true
    onTriggered: root.registerProvider()
  }

  Connections {
    target: PluginService

    function onPluginLoaded(pluginId) {
      if (!root.batteryManager)
        root.registerProvider();
    }

    function onPluginUnloaded(pluginId) {
      if (pluginId === root.batteryManagerPluginKey) {
        root.batteryManager = null;
        root.batteryManagerPluginKey = "";
      }
    }
  }

  onPluginApiChanged: {
    if (pluginApi)
      refresh();
  }

  onWarningThresholdChanged: registerProvider()
  onCriticalThresholdChanged: registerProvider()
  onNotificationsEnabledChanged: registerProvider()

  IpcHandler {
    target: "plugin:keychron-battery-provider"

    function refresh(): string {
      root.refresh();
      return "ok";
    }

    function get(): string {
      return JSON.stringify({
        ok: root.devices.some(d => typeof d.percent === "number" && d.percent >= 0),
        devices: root.devices,
        error: root.lastError
      });
    }
  }
}
