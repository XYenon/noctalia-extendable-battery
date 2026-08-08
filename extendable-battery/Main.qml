import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Services.Hardware
import qs.Services.UI

Item {
  id: root

  property var pluginApi: null

  property var cfg: pluginApi?.pluginSettings || ({})
  property var defaults: pluginApi?.manifest?.metadata?.defaultSettings || ({})

  readonly property bool preferBluetooth: cfg.preferBluetooth ?? defaults.preferBluetooth ?? true
  readonly property string deviceNameFilter: (cfg.deviceNameFilter ?? defaults.deviceNameFilter ?? "").trim()

  property bool isRefreshing: false
  property bool hasReading: false
  property int percent: -1
  property bool charging: false
  property bool pluggedIn: false
  property int statusCode: 0
  property string deviceName: ""
  property string deviceKind: ""
  property string protocol: ""
  property string transport: ""
  property string lastError: ""
  property int deviceCount: 0
  property var devices: []
  property var primary: null
  property int refreshNonce: 0

  readonly property bool isCritical: isCriticalBattery(primary)
  readonly property bool isLow: isLowBattery(primary)

  readonly property var deviceModel: {
    const _tick = root.refreshNonce;
    const model = (BatteryService.deviceModel || []).slice();
    for (var i = 0; i < root.devices.length; i++) {
      const device = root.devices[i];
      model.push({
        key: device.deviceKey,
        name: device.name || device.deviceKey
      });
    }
    return model;
  }

  // Registered Battery Providers List
  property var registeredProviders: []
  property var _hasNotified: ({})

  /**
  * Register an external battery provider.
  * Provider schema:
  *   {
  *     id: string,
  *     name: string,
  *     getDevices: function(),
  *     refresh: function() // optional
  *   }
  *
  * Device schema:
  *   id, name, percent, present, ready, charging, pluggedIn,
  *   timeToFull, timeToEmpty, changeRate, healthSupported,
  *   healthPercentage, warningThreshold, criticalThreshold,
  *   notificationsEnabled, kind, protocol, transport, status, error.
  */
  function registerBatteryProvider(provider) {
    if (!provider || !provider.id) {
      Logger.w("BatteryManager", "Invalid provider registration request");
      return false;
    }

    unregisterBatteryProvider(provider.id);
    registeredProviders.push(provider);
    Logger.i("BatteryManager", `Registered battery provider: ${provider.name || provider.id}`);
    aggregateAllDevices();
    return true;
  }

  function unregisterBatteryProvider(providerId) {
    const next = [];
    let removed = false;
    for (var i = 0; i < registeredProviders.length; i++) {
      if (registeredProviders[i].id === providerId) {
        removed = true;
      } else {
        next.push(registeredProviders[i]);
      }
    }
    if (removed) {
      registeredProviders = next;
      Logger.i("BatteryManager", `Unregistered battery provider: ${providerId}`);
      aggregateAllDevices();
    }
    return removed;
  }

  function normalizeProviderDevice(device, provider) {
    if (!device.id) {
      Logger.w("BatteryManager", `Ignoring device without a stable id from provider ${provider.id}`);
      return null;
    }
    const percent = typeof device.percent === "number" ? device.percent : -1;
    const present = device.present !== undefined ? !!device.present : device.connected !== false;
    const ready = device.ready !== undefined ? !!device.ready : present && percent >= 0;
    const id = String(device.id);

    return Object.assign({}, device, {
      _providerDevice: true,
      providerId: provider.id,
      providerName: provider.name || provider.id,
      id: id,
      deviceKey: `provider:${provider.id}:${id}`,
      name: device.name || provider.name || provider.id,
      percent: percent,
      present: present,
      ready: ready,
      charging: !!device.charging,
      pluggedIn: !!device.pluggedIn,
      timeToFull: Number(device.timeToFull || 0),
      timeToEmpty: Number(device.timeToEmpty || 0),
      changeRate: device.changeRate === undefined ? undefined : Number(device.changeRate),
      healthSupported: !!device.healthSupported,
      healthPercentage: Number(device.healthPercentage || 0),
      warningThreshold: Number(device.warningThreshold ?? provider.warningThreshold ?? 20),
      criticalThreshold: Number(device.criticalThreshold ?? provider.criticalThreshold ?? 5),
      notificationsEnabled: device.notificationsEnabled ?? provider.notificationsEnabled ?? true,
      kind: device.kind || "unknown",
      protocol: device.protocol || "",
      transport: device.transport || "",
      status: device.status || 0,
      error: device.error || ""
    });
  }

  // Aggregate and normalize device data from all registered providers.
  function aggregateAllDevices() {
    let all = [];
    for (var i = 0; i < registeredProviders.length; i++) {
      const provider = registeredProviders[i];
      try {
        const providerDevices = typeof provider.getDevices === "function" ? provider.getDevices() : (provider.devices || []);
        if (Array.isArray(providerDevices)) {
          for (var j = 0; j < providerDevices.length; j++) {
            const normalized = normalizeProviderDevice(providerDevices[j], provider);
            if (normalized)
              all.push(normalized);
          }
        }
      } catch (e) {
        Logger.w("BatteryManager", `Error retrieving devices from provider ${provider.id}: ${e}`);
      }
    }

    devices = all;
    deviceCount = all.length;

    const chosen = pickPrimary({
      devices: all
    }) || (all.length > 0 ? all[0] : null);
    primary = chosen;

    if (isDeviceReady(chosen)) {
      hasReading = true;
      percent = getPercentage(chosen);
      charging = isCharging(chosen);
      pluggedIn = isPluggedIn(chosen);
      statusCode = chosen.status || 0;
      deviceName = getDeviceName(chosen);
      deviceKind = chosen.kind || "";
      protocol = chosen.protocol || "";
      transport = chosen.transport || "";
      lastError = chosen.error || "";
    } else {
      hasReading = false;
      percent = -1;
      charging = false;
      pluggedIn = false;
      statusCode = 0;
      deviceName = "";
      deviceKind = "";
      protocol = "";
      transport = "";
      lastError = chosen?.error || (all.length === 0 ? "No battery reading available" : "");
    }

    refreshNonce++;
    for (var k = 0; k < all.length; k++)
      checkProviderDevice(all[k]);
  }

  function refresh() {
    isRefreshing = true;
    for (var i = 0; i < registeredProviders.length; i++) {
      const provider = registeredProviders[i];
      if (typeof provider.refresh === "function") {
        try {
          provider.refresh();
        } catch (e) {
          Logger.w("BatteryManager", `Failed to refresh provider ${provider.id}: ${e}`);
        }
      }
    }
    isRefreshing = false;
  }

  function pickPrimary(snapshot) {
    const list = snapshot?.devices || [];
    const ok = list.filter(function (device) {
      return root.isDeviceReady(device);
    });

    if (ok.length === 0)
      return null;

    let filtered = ok;
    if (deviceNameFilter.length > 0) {
      const query = deviceNameFilter.toLowerCase();
      const matched = ok.filter(function (device) {
        return (device.name || "").toLowerCase().indexOf(query) !== -1;
      });
      if (matched.length > 0)
        filtered = matched;
    }

    if (preferBluetooth) {
      const bluetooth = filtered.filter(function (device) {
        return device.transport === "bluetooth" || device.protocol === "bluez";
      });
      if (bluetooth.length > 0)
        filtered = bluetooth;
    }

    filtered = filtered.slice().sort(function (a, b) {
      if (a.percent !== b.percent)
        return a.percent - b.percent;
      return (a.name || "").localeCompare(b.name || "");
    });

    return filtered[0];
  }

  function isProviderDevice(device) {
    return !!device?._providerDevice;
  }

  // Match native Battery.qml: only return a device when it is present.
  function findDevice(deviceKey) {
    if (!deviceKey || deviceKey === "__default__") {
      const nativeDevice = BatteryService.primaryDevice;
      if (BatteryService.isDevicePresent(nativeDevice))
        return nativeDevice;
      if (primary && isDevicePresent(primary))
        return primary;
      return null;
    }

    if (deviceKey.indexOf("provider:") === 0) {
      for (var i = 0; i < devices.length; i++) {
        if (devices[i].deviceKey === deviceKey)
          return isDevicePresent(devices[i]) ? devices[i] : null;
      }
      return null;
    }

    const device = BatteryService.findDevice(deviceKey);
    return BatteryService.isDevicePresent(device) ? device : null;
  }

  function isDevicePresent(device) {
    return isProviderDevice(device) ? !!device.present : BatteryService.isDevicePresent(device);
  }

  function isDeviceReady(device) {
    return isProviderDevice(device) ? !!device.ready && isDevicePresent(device) : BatteryService.isDeviceReady(device);
  }

  function getPercentage(device) {
    return isProviderDevice(device) ? Math.round(device.percent) : BatteryService.getPercentage(device);
  }

  function isCharging(device) {
    return isProviderDevice(device) ? !!device.charging : BatteryService.isCharging(device);
  }

  function isPluggedIn(device) {
    return isProviderDevice(device) ? !!device.pluggedIn : BatteryService.isPluggedIn(device);
  }

  function isCriticalBattery(device) {
    if (!isProviderDevice(device))
      return device ? BatteryService.isCriticalBattery(device) : false;
    return (!isCharging(device) && !isPluggedIn(device)) && getPercentage(device) <= device.criticalThreshold;
  }

  function isLowBattery(device) {
    if (!isProviderDevice(device))
      return device ? BatteryService.isLowBattery(device) : false;
    return (!isCharging(device) && !isPluggedIn(device)) && getPercentage(device) <= device.warningThreshold && getPercentage(device) > device.criticalThreshold;
  }

  function getDeviceName(device) {
    return isProviderDevice(device) ? (device.name || "") : BatteryService.getDeviceName(device);
  }

  function matchesNativeBluetooth(providerDevice, nativeDevice) {
    if (!isProviderDevice(providerDevice) || !nativeDevice?.address)
      return false;
    const address = String(nativeDevice.address).toLowerCase();
    if (providerDevice.address && String(providerDevice.address).toLowerCase() === address)
      return true;
    const bluezAddress = address.replace(/:/g, "_");
    return String(providerDevice.id || "").toLowerCase().indexOf(`/dev_${bluezAddress}`) !== -1;
  }

  function getRateText(device) {
    if (!isProviderDevice(device))
      return BatteryService.getRateText(device);
    if (!device || device.changeRate === undefined)
      return "";
    const rate = Math.abs(device.changeRate);
    if (device.timeToFull > 0) {
      return I18n.tr("battery.charging-rate", {
        "rate": rate.toFixed(2)
      });
    } else if (device.timeToEmpty > 0) {
      return I18n.tr("battery.discharging-rate", {
        "rate": rate.toFixed(2)
      });
    }
    return "";
  }

  function getTimeRemainingText(device) {
    if (!isProviderDevice(device))
      return BatteryService.getTimeRemainingText(device);
    if (!isDeviceReady(device))
      return I18n.tr("battery.no-battery-detected");
    if (isPluggedIn(device))
      return I18n.tr("battery.plugged-in");
    if (device.timeToFull > 0) {
      return I18n.tr("battery.time-until-full", {
        "time": Time.formatVagueHumanReadableDuration(device.timeToFull)
      });
    } else if (device.timeToEmpty > 0) {
      return I18n.tr("battery.time-left", {
        "time": Time.formatVagueHumanReadableDuration(device.timeToEmpty)
      });
    }
    return I18n.tr("common.idle");
  }

  function checkProviderDevice(device) {
    if (!isProviderDevice(device) || !isDeviceReady(device))
      return;

    const percentage = getPercentage(device);
    const chargingNow = isCharging(device);
    const pluggedInNow = isPluggedIn(device);
    const level = isLowBattery(device) ? "low" : (isCriticalBattery(device) ? "critical" : "");
    const deviceKey = device.deviceKey;

    if (!_hasNotified[deviceKey]) {
      _hasNotified[deviceKey] = {
        low: false,
        critical: false
      };
    }

    if (chargingNow || pluggedInNow) {
      _hasNotified[deviceKey].low = false;
      _hasNotified[deviceKey].critical = false;
    }

    if (percentage > device.warningThreshold) {
      _hasNotified[deviceKey].low = false;
      _hasNotified[deviceKey].critical = false;
    } else if (percentage > device.criticalThreshold) {
      _hasNotified[deviceKey].critical = false;
    }

    if (level && device.notificationsEnabled && !_hasNotified[deviceKey][level]) {
      notifyProviderDevice(device, level);
      _hasNotified[deviceKey][level] = true;
    }
  }

  function notifyProviderDevice(device, level) {
    const titleKey = level === "critical" ? "toast.battery.critical" : "toast.battery.low";
    const descKey = level === "critical" ? "toast.battery.critical-desc" : "toast.battery.low-desc";
    const title = I18n.tr(titleKey) + " " + getDeviceName(device);
    const desc = I18n.tr(descKey, {
      "percent": getPercentage(device)
    });
    const icon = level === "critical" ? "battery-exclamation" : "battery-charging-2";
    ToastService.showNotice(title, desc, icon, 6000);
  }

  function statusLabel() {
    if (!hasReading)
      return pluginApi?.tr("status.unavailable") || "Unavailable";
    if (charging)
      return pluginApi?.tr("status.charging") || "Charging";
    if (pluggedIn)
      return pluginApi?.tr("status.plugged-in") || "Plugged in";
    if (isCritical)
      return pluginApi?.tr("status.critical") || "Critical";
    if (isLow)
      return pluginApi?.tr("status.low") || "Low";
    return pluginApi?.tr("status.discharging") || "Battery";
  }

  IpcHandler {
    target: "plugin:extendable-battery"

    function refresh(): string {
      root.refresh();
      return "ok";
    }

    function get(): string {
      return JSON.stringify({
        ok: root.hasReading,
        percent: root.percent,
        charging: root.charging,
        pluggedIn: root.pluggedIn,
        name: root.deviceName,
        protocol: root.protocol,
        transport: root.transport,
        error: root.lastError,
        devices: root.devices,
        providers: root.registeredProviders.map(provider => provider.id)
      });
    }

    function registerProvider(jsonPayload: string): string {
      try {
        const provider = JSON.parse(jsonPayload);
        if (provider && provider.id) {
          root.registerBatteryProvider({
            id: provider.id,
            name: provider.name || provider.id,
            warningThreshold: provider.warningThreshold,
            criticalThreshold: provider.criticalThreshold,
            notificationsEnabled: provider.notificationsEnabled,
            devices: provider.devices || [],
            getDevices: function () {
              return this.devices;
            }
          });
          return JSON.stringify({
            ok: true,
            id: provider.id
          });
        }
      } catch (e) {
        return JSON.stringify({
          ok: false,
          error: String(e)
        });
      }
      return JSON.stringify({
        ok: false,
        error: "Invalid provider payload"
      });
    }

    function unregisterProvider(providerId: string): string {
      const ok = root.unregisterBatteryProvider(providerId);
      return JSON.stringify({
        ok: ok
      });
    }
  }
}
