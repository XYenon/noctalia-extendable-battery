--!nonstrict

local scannerDevices = {}
local devices = {}
local providers = {}
local providerOrder = {}
local refreshing = false
local lastError = ""
local notified = {}

local function configNumber(key, fallback)
  local value = noctalia.getConfig(key)
  return type(value) == "number" and value or fallback
end

local function configBoolean(key, fallback)
  local value = noctalia.getConfig(key)
  return type(value) == "boolean" and value or fallback
end

local function publish()
  noctalia.state.set("battery.status", {
    devices = devices,
    refreshing = refreshing,
    error = lastError,
    updatedAt = os.time(),
  })
end

local function ready(device)
  return type(device) == "table"
    and device.present ~= false
    and device.ready == true
    and type(device.percent) == "number"
    and device.percent >= 0
end

local function notifyLevels()
  local warning = configNumber("warning_threshold", 20)
  local critical = math.min(configNumber("critical_threshold", 5), warning)
  local enabled = configBoolean("notifications_enabled", true)

  for _, device in ipairs(devices) do
    local systemDevice = device.kind == "system" or device.kind == "laptop" or device.protocol == "sysfs"
    -- Noctalia owns system-battery notifications. Only notify for provider devices.
    if ready(device) and not systemDevice then
      local id = tostring(device.id or device.name or "unknown")
      local flags = notified[id] or { low = false, critical = false }
      local deviceWarning = type(device.warningThreshold) == "number" and device.warningThreshold or warning
      local deviceCritical = type(device.criticalThreshold) == "number"
          and math.min(device.criticalThreshold, deviceWarning)
        or critical
      local notificationsEnabled = enabled
      if device.providerId ~= nil then
        notificationsEnabled = device.notificationsEnabled ~= false
      end
      local plugged = device.charging == true or device.pluggedIn == true
      local percent = math.floor(device.percent + 0.5)

      if plugged or percent > deviceWarning then
        flags.low = false
        flags.critical = false
      elseif percent > deviceCritical then
        flags.critical = false
      end

      if notificationsEnabled and not plugged and percent <= deviceCritical and not flags.critical then
        noctalia.notifyError(
          noctalia.tr("notifications.critical.title"),
          noctalia.tr("notifications.critical.body", { device = device.name or id, percent = percent })
        )
        flags.critical = true
        flags.low = true
      elseif notificationsEnabled and not plugged and percent <= deviceWarning and not flags.low then
        noctalia.notify(
          noctalia.tr("notifications.low.title"),
          noctalia.tr("notifications.low.body", { device = device.name or id, percent = percent })
        )
        flags.low = true
      end

      notified[id] = flags
    end
  end
end

local function normalizeSnapshot(snapshot, provider)
  local nextDevices = type(snapshot.devices) == "table" and snapshot.devices or {}
  local previousById = {}
  for _, device in ipairs(devices) do
    if device.id ~= nil and ready(device) then
      previousById[tostring(device.id)] = device
    end
  end

  local normalized = {}
  for _, source in ipairs(nextDevices) do
    if type(source) == "table" then
      local device = table.clone(source)
      local rawId = tostring(device.id or "")
      if provider ~= nil and rawId == "" then
        continue
      end
      if rawId ~= "" and provider ~= nil then
        device.id = "provider:" .. tostring(provider.id) .. ":" .. rawId
      else
        device.id = rawId
      end
      device.name = tostring(device.name or (provider ~= nil and provider.name) or noctalia.tr("panel.unknown_device"))
      local suppliedReady = device.ready
      device.percent = type(device.percent) == "number" and device.percent or -1
      device.present = device.present ~= false and device.connected ~= false
      device.ready = type(suppliedReady) == "boolean" and suppliedReady or (device.present and device.percent >= 0)
      device.charging = device.charging == true
      device.pluggedIn = device.pluggedIn == true
      device.timeToFull = tonumber(device.timeToFull) or 0
      device.timeToEmpty = tonumber(device.timeToEmpty) or 0
      device.changeRate = device.changeRate ~= nil and tonumber(device.changeRate) or nil
      device.healthSupported = device.healthSupported == true
      device.healthPercentage = tonumber(device.healthPercentage) or 0
      device.kind = tostring(device.kind or "unknown")
      device.transport = tostring(device.transport or "")
      device.protocol = tostring(device.protocol or "")
      device.status = tonumber(device.status) or 0
      device.error = tostring(device.error or "")
      if provider ~= nil then
        device.providerId = tostring(provider.id)
        device.warningThreshold = tonumber(device.warningThreshold or provider.warningThreshold) or 20
        device.criticalThreshold = tonumber(device.criticalThreshold or provider.criticalThreshold) or 5
        if device.notificationsEnabled == nil then
          device.notificationsEnabled = provider.notificationsEnabled
        end
      end

      local previous = previousById[device.id]
      if not device.ready and device.present and previous ~= nil then
        local connected = device.connected
        device = table.clone(previous)
        device.present = true
        device.connected = connected
        device.error = ""
      end
      table.insert(normalized, device)
    end
  end
  return normalized
end

local function rebuildDevices()
  local combined = {}
  for _, device in ipairs(scannerDevices) do
    table.insert(combined, device)
  end
  for _, providerId in ipairs(providerOrder) do
    local provider = providers[providerId]
    if provider ~= nil then
      for _, device in ipairs(normalizeSnapshot({ devices = provider.devices }, provider)) do
        table.insert(combined, device)
      end
    end
  end
  devices = combined
  notifyLevels()
  publish()
end

local function applyResult(result)
  refreshing = false
  local raw = type(result.stdout) == "string" and noctalia.string.trim(result.stdout) or ""
  local snapshot, decodeError = noctalia.json.decode(raw)

  if type(snapshot) == "table" then
    scannerDevices = normalizeSnapshot(snapshot)
    local hasReading = false
    for _, device in ipairs(scannerDevices) do
      if ready(device) then
        hasReading = true
        break
      end
    end
    lastError = hasReading and "" or tostring(snapshot.error or "")
  else
    scannerDevices = {}
    local stderr = type(result.stderr) == "string" and noctalia.string.trim(result.stderr) or ""
    lastError = stderr ~= "" and stderr or tostring(decodeError or noctalia.tr("service.invalid_output"))
  end

  rebuildDevices()
end

local function refresh()
  if refreshing then
    return
  end

  local pluginDir = noctalia.pluginDir()
  if type(pluginDir) ~= "string" or pluginDir == "" then
    lastError = noctalia.tr("service.plugin_dir_error")
    publish()
    return
  end

  local command = { "python3", pluginDir .. "/scripts/keychron_battery.py", "--include-system" }
  if not configBoolean("enable_bluetooth", true) then
    table.insert(command, "--no-bluez")
  end
  local filter = noctalia.getConfig("bluetooth_filter")
  if type(filter) == "string" and noctalia.string.trim(filter) ~= "" then
    table.insert(command, "--bluez-filter")
    table.insert(command, noctalia.string.trim(filter))
  end

  refreshing = true
  publish()
  if not noctalia.runAsync(command, applyResult, 60000) then
    refreshing = false
    lastError = noctalia.tr("service.launch_error")
    publish()
  end
end

local function configureTimer()
  local seconds = math.max(5, configNumber("refresh_interval", 60))
  noctalia.setUpdateInterval(seconds * 1000)
end

noctalia.state.watch("battery.command", function(command)
  if command == "refresh" or (type(command) == "table" and command.action == "refresh") then
    noctalia.state.set("battery.command", nil)
    refresh()
  end
end)

function update()
  refresh()
end

function onConfigChanged()
  configureTimer()
  refresh()
end

function onIpc(event, payload)
  if event == "refresh" then
    refresh()
    return
  end

  if event == "unregisterProvider" then
    local providerId = type(payload) == "string" and noctalia.string.trim(payload) or ""
    if providerId ~= "" then
      providers[providerId] = nil
      for index, id in ipairs(providerOrder) do
        if id == providerId then
          table.remove(providerOrder, index)
          break
        end
      end
      rebuildDevices()
    end
    return
  end

  if event ~= "registerProvider" or type(payload) ~= "string" then
    return
  end
  local provider = noctalia.json.decode(payload)
  if type(provider) ~= "table" or type(provider.id) ~= "string" or provider.id == "" then
    noctalia.log("Extendable Battery ignored an invalid provider registration")
    return
  end
  provider.name = tostring(provider.name or provider.id)
  provider.devices = type(provider.devices) == "table" and provider.devices or {}
  for index, id in ipairs(providerOrder) do
    if id == provider.id then
      table.remove(providerOrder, index)
      break
    end
  end
  providers[provider.id] = provider
  table.insert(providerOrder, provider.id)
  rebuildDevices()
end

configureTimer()
publish()
refresh()
