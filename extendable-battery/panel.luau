--!nonstrict

local status = { devices = {}, refreshing = false, error = "" }
local panelOpen = false

local function isReady(device)
  return type(device) == "table"
    and device.present ~= false
    and device.ready == true
    and type(device.percent) == "number"
    and device.percent >= 0
end

local function isSystem(device)
  return device.kind == "system" or device.kind == "laptop" or device.protocol == "sysfs"
end

local function deviceKind(device)
  local kind = tostring(device.kind or "")
  if kind ~= "" and kind ~= "unknown" then
    return kind
  end
  local name = string.lower(tostring(device.name or ""))
  local protocol = string.lower(tostring(device.protocol or ""))
  if string.find(name, "mouse", 1, true) or string.find(name, "trackball", 1, true) then
    return "mouse"
  elseif string.find(name, "keyboard", 1, true) then
    return "keyboard"
  elseif string.find(name, "dongle", 1, true) or string.find(name, "receiver", 1, true) then
    if string.find(protocol, "mouse", 1, true) or string.find(protocol, "rf", 1, true) then
      return "mouse"
    end
    return "dongle"
  elseif string.find(protocol, "mouse", 1, true) or string.find(protocol, "rf", 1, true) then
    return "mouse"
  end
  return "unknown"
end

local function glyphForDevice(device)
  local kind = deviceKind(device)
  if kind == "system" or kind == "laptop" then
    return device.charging == true and "plug" or "battery"
  elseif kind == "mouse" or kind == "trackball" then
    return "mouse-2"
  elseif kind == "keyboard" then
    return "keyboard"
  elseif kind == "phone" then
    return "device-mobile"
  elseif kind == "dongle" then
    return "usb"
  end
  local name = string.lower(tostring(device.name or ""))
  if string.find(name, "headphone", 1, true) or string.find(name, "headset", 1, true) then
    return "headphones"
  end
  return "usb"
end

local function compactDuration(seconds)
  local minutes = math.floor(seconds / 60)
  local hours = math.floor(minutes / 60)
  minutes %= 60
  if hours > 0 and minutes > 0 then
    return tostring(hours) .. "h " .. tostring(minutes) .. "m"
  elseif hours > 0 then
    return tostring(hours) .. "h"
  elseif minutes > 0 then
    return tostring(minutes) .. "m"
  end
  return ""
end

local function deviceStatusText(device)
  if not isReady(device) then
    return ""
  end
  local parts = {}
  if device.charging == true then
    table.insert(parts, noctalia.tr("states.charging"))
  elseif device.pluggedIn == true then
    table.insert(parts, noctalia.tr("states.plugged_in"))
  end
  local seconds = device.charging == true and device.timeToFull or device.timeToEmpty
  if type(seconds) == "number" and seconds > 0 then
    table.insert(parts, compactDuration(seconds))
  end
  if type(device.transport) == "string" and device.transport ~= "" and not isSystem(device) then
    table.insert(parts, device.transport)
  end
  if #parts == 0 and isSystem(device) then
    table.insert(parts, noctalia.tr("states.discharging"))
  end
  return table.concat(parts, " · ")
end

local function visibleDevices()
  local systems = {}
  local readyProviders = {}
  local pendingProviders = {}
  for _, device in ipairs(status.devices or {}) do
    if type(device) == "table" then
      if isSystem(device) then
        if device.present ~= false then
          table.insert(systems, device)
        end
      elseif isReady(device) then
        table.insert(readyProviders, device)
      else
        table.insert(pendingProviders, device)
      end
    end
  end

  local result = {}
  for _, device in ipairs(systems) do
    table.insert(result, device)
  end
  local providers = #readyProviders > 0 and readyProviders or pendingProviders
  for _, device in ipairs(providers) do
    table.insert(result, device)
  end
  return result, #systems
end

local function lowBattery(device)
  if not isReady(device) or device.charging == true or device.pluggedIn == true then
    return false
  end
  local warning = type(device.warningThreshold) == "number"
      and device.warningThreshold
    or (noctalia.getConfig("warning_threshold") or 20)
  return device.percent <= warning
end

local function batteryGlyph(device)
  if not isReady(device) then
    return "battery-exclamation"
  end
  local percent = math.floor(device.percent + 0.5)
  if device.charging == true then
    return "battery-charging"
  elseif device.pluggedIn == true or percent >= 100 then
    return "battery-plugged"
  elseif percent >= 85 then
    return "battery-4"
  elseif percent >= 55 then
    return "battery-3"
  elseif percent >= 30 then
    return "battery-2"
  elseif percent >= 10 then
    return "battery-1"
  end
  return "battery-0"
end

local function deviceRow(device)
  local ready = isReady(device)
  local percent = ready and math.floor(device.percent + 0.5) or -1
  local powered = ready and (device.charging == true or device.pluggedIn == true)
  local low = lowBattery(device)
  local color = powered and "primary" or (low and "error" or "on_surface")
  local statusText = deviceStatusText(device)
  local children = {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = glyphForDevice(device), size = 17, color = color }),
      ui.label({
        text = tostring(device.name or noctalia.tr("panel.unknown_device")),
        color = color,
        fontSize = 12,
        maxLines = 1,
        flexGrow = 1,
      }),
      ui.label({ text = statusText, color = "on_surface_variant", fontSize = 11, maxLines = 1 }),
    }),
    ui.row({ gap = 8, align = "center" }, {
      ui.progress({
        progress = ready and math.max(0, math.min(1, percent / 100)) or 0,
        fill = "primary",
        track = "surface",
        height = 8,
        radius = 4,
        flexGrow = 1,
      }),
      ui.label({
        text = ready and (tostring(percent) .. "%") or "--",
        color = color,
        fontSize = 12,
        fontWeight = "bold",
        width = 42,
        textAlign = "right",
      }),
    }),
  }
  if not ready and type(device.error) == "string" and device.error ~= "" then
    table.insert(children, ui.label({ text = device.error, color = "error", fontSize = 10, wrap = true }))
  end
  return ui.column({ gap = 6 }, children)
end

local function batteryCard(devices, systemCount)
  local rows = {}
  for index, device in ipairs(devices) do
    if index == systemCount + 1 and systemCount > 0 then
      table.insert(rows, ui.separator({}))
    end
    table.insert(rows, deviceRow(device))
  end
  return ui.column({ gap = 12, padding = 12, radius = 10, fill = "surface_variant/0.35" }, rows)
end

local function render()
  if not panelOpen then
    return
  end
  local devices, systemCount = visibleDevices()
  local primary = devices[1]
  local headerPowered = primary ~= nil and (primary.charging == true or primary.pluggedIn == true)
  local headerColor = headerPowered and "primary" or (primary ~= nil and lowBattery(primary) and "error" or "on_surface")
  local children = {
    ui.column({ gap = 8, padding = 10, radius = 10, fill = "surface_variant/0.35" }, {
      ui.row({ align = "center", gap = 8 }, {
        ui.glyph({ name = batteryGlyph(primary), size = 22, color = headerColor }),
        ui.label({ text = noctalia.tr("panel.battery"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
        ui.button({
          glyph = "refresh",
          variant = "ghost",
          tooltip = noctalia.tr("panel.refresh"),
          enabled = status.refreshing ~= true,
          onClick = "onRefresh",
        }),
        ui.button({ glyph = "close", variant = "ghost", tooltip = noctalia.tr("panel.close"), onClick = "onClosePanel" }),
      }),
    }),
  }

  if #devices > 0 then
    table.insert(children, ui.scroll({ flexGrow = 1, gap = 12 }, {
      batteryCard(devices, systemCount),
    }))
  else
    table.insert(children, ui.spacer({ flexGrow = 1 }))
  end

  if noctalia.getConfig("show_power_profiles") == true then
    table.insert(children, ui.button({
      text = noctalia.tr("panel.system_power"),
      glyph = "settings",
      variant = "outline",
      onClick = "onSystemPower",
    }))
  end
  panel.render(ui.column({ flexGrow = 1, gap = 12, padding = 10 }, children))
end

noctalia.state.watch("battery.status", function(value)
  if type(value) == "table" then
    status = value
  end
  render()
end)

function onOpen()
  panelOpen = true
  local current = noctalia.state.get("battery.status")
  if type(current) == "table" then
    status = current
  end
  render()
end

function onClose()
  panelOpen = false
end

function onRefresh()
  noctalia.state.set("battery.command", "refresh")
end

function onSystemPower()
  panel.close()
  noctalia.runAsync({ "noctalia", "msg", "panel-toggle", "control-center", "power" })
end

function onClosePanel()
  panel.close()
end
