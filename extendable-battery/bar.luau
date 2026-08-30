--!nonstrict

local status = { devices = {}, refreshing = false, error = "" }
local hasTooltip = false

local function clearTooltip()
  if hasTooltip then
    barWidget.clearTooltip()
    hasTooltip = false
  end
end

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

local function selectedDevice()
  local systemDevices = {}
  local candidates = {}
  for _, device in ipairs(status.devices or {}) do
    if isReady(device) then
      if isSystem(device) then
        table.insert(systemDevices, device)
      else
        table.insert(candidates, device)
      end
    end
  end

  -- Match the old default-selection contract: the system battery wins whenever
  -- it is present; provider selection only applies when there is no system battery.
  if #systemDevices > 0 then
    table.sort(systemDevices, function(left, right)
      return tostring(left.name or "") < tostring(right.name or "")
    end)
    return systemDevices[1]
  end

  if #candidates == 0 then
    return nil
  end

  local filter = noctalia.getConfig("device_filter")
  if type(filter) == "string" and noctalia.string.trim(filter) ~= "" then
    local query = string.lower(noctalia.string.trim(filter))
    local matches = {}
    for _, device in ipairs(candidates) do
      if string.find(string.lower(tostring(device.name or "")), query, 1, true) ~= nil then
        table.insert(matches, device)
      end
    end
    if #matches > 0 then
      candidates = matches
    end
  end

  if noctalia.getConfig("prefer_bluetooth") == true then
    local bluetooth = {}
    for _, device in ipairs(candidates) do
      if device.transport == "bluetooth" or device.protocol == "bluez" then
        table.insert(bluetooth, device)
      end
    end
    if #bluetooth > 0 then
      candidates = bluetooth
    end
  end

  table.sort(candidates, function(left, right)
    if left.percent ~= right.percent then
      return left.percent < right.percent
    end
    return tostring(left.name or "") < tostring(right.name or "")
  end)
  return candidates[1]
end

local function batteryGlyph(device)
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

local function compactDuration(seconds)
  local minutes = math.floor(seconds / 60)
  local hours = math.floor(minutes / 60)
  minutes = minutes % 60
  if hours > 0 and minutes > 0 then
    return tostring(hours) .. "h " .. tostring(minutes) .. "m"
  elseif hours > 0 then
    return tostring(hours) .. "h"
  elseif minutes > 0 then
    return tostring(minutes) .. "m"
  end
  return "<1m"
end

local function labelText(device)
  local content = noctalia.getConfig("label_content") or "percent"
  if content == "time" then
    local seconds = device.charging == true and device.timeToFull or device.timeToEmpty
    if type(seconds) == "number" and seconds > 0 then
      return compactDuration(seconds)
    end
  elseif content == "rate" and type(device.changeRate) == "number" and device.changeRate > 0 then
    return string.format("%.1f W", math.abs(device.changeRate))
  end
  -- Match the native widget's fallback when the selected time/rate is absent.
  return tostring(math.floor(device.percent + 0.5)) .. "%"
end

local function tooltipRows(selected)
  local rows = {}
  if not isReady(selected) then
    return rows
  end

  local percent = tostring(math.floor(selected.percent + 0.5)) .. "%"
  if not isSystem(selected) then
    table.insert(rows, { key = tostring(selected.name or noctalia.tr("panel.unknown_device")), value = percent })
    return rows
  end

  table.insert(rows, { key = noctalia.tr("tooltip.battery_level"), value = percent })
  if selected.pluggedIn == true then
    table.insert(rows, { key = noctalia.tr("states.plugged_in"), value = "" })
  elseif selected.charging == true and type(selected.timeToFull) == "number" and selected.timeToFull > 0 then
    table.insert(rows, { key = noctalia.tr("tooltip.time_to_full"), value = compactDuration(selected.timeToFull) })
  elseif type(selected.timeToEmpty) == "number" and selected.timeToEmpty > 0 then
    table.insert(rows, { key = noctalia.tr("tooltip.time_left"), value = compactDuration(selected.timeToEmpty) })
  else
    table.insert(rows, {
      key = selected.charging == true and noctalia.tr("states.charging") or noctalia.tr("states.discharging"),
      value = "",
    })
  end
  if selected.pluggedIn ~= true and type(selected.changeRate) == "number" and selected.changeRate ~= 0 then
    table.insert(rows, {
      key = noctalia.tr("tooltip.rate"),
      value = string.format("%.2f W", math.abs(selected.changeRate)),
    })
  end
  if selected.healthSupported == true and type(selected.healthPercentage) == "number" then
    table.insert(rows, {
      key = noctalia.tr("tooltip.battery_health"),
      value = tostring(math.floor(selected.healthPercentage + 0.5)) .. "%",
    })
  end

  local separated = false
  for _, device in ipairs(status.devices or {}) do
    if device ~= selected and not isSystem(device) and isReady(device) then
      if not separated then
        table.insert(rows, { key = "---", value = "---" })
        separated = true
      end
      table.insert(rows, {
        key = tostring(device.name or noctalia.tr("panel.unknown_device")),
        value = tostring(math.floor(device.percent + 0.5)) .. "%",
      })
    end
  end
  return rows
end

local function render()
  local device = selectedDevice()
  local displayMode = noctalia.getConfig("display_mode") or "glyph"
  local showLabel = noctalia.getConfig("show_label") ~= false
  local hasContent = displayMode ~= "none" or showLabel
  local visible = device ~= nil and hasContent

  if device ~= nil then
    local plugged = device.charging == true or device.pluggedIn == true
    local full = math.floor(device.percent + 0.5) >= 100
    visible = visible
      and not (noctalia.getConfig("hide_when_plugged") == true and plugged)
      and not (noctalia.getConfig("hide_when_full") == true and full)
  end
  barWidget.setVisible(visible)
  if not visible then
    clearTooltip()
    return
  end

  local percent = math.floor(device.percent + 0.5)
  local warning = noctalia.getConfig("warning_threshold") or 20
  local isWarning = percent <= warning and device.charging ~= true and device.pluggedIn ~= true
  local color = isWarning and (noctalia.getConfig("warning_color") or "error") or "on_surface"
  local label = labelText(device)
  local vertical = barWidget.isVertical()

  if displayMode == "glyph" then
    local container = vertical and ui.column or ui.row
    local children = { ui.glyph({ name = batteryGlyph(device), color = color }) }
    if showLabel then
      table.insert(children, ui.label({ text = vertical and tostring(percent) or label, color = color }))
    end
    barWidget.render(container({ gap = vertical and 0 or 4, align = "center" }, children))
  elseif displayMode == "graphic" then
    local children = {}
    -- The native C++ battery geometry is not exposed to plugins. ui.progress keeps
    -- the same palette, dimensions, fill semantics, and warning state.
    table.insert(children, ui.progress({
      progress = math.max(0, math.min(1, percent / 100)),
      fill = color,
      track = "on_surface/0.3",
      width = vertical and 14 or 22,
      height = vertical and 14 or 8,
      radius = vertical and 3 or 4,
    }))
    if device.charging == true then
      table.insert(children, ui.glyph({ name = "bolt-filled", size = 12, color = color }))
    elseif device.pluggedIn == true or percent >= 100 then
      table.insert(children, ui.glyph({ name = "plug-filled", size = 12, color = color }))
    end
    if showLabel then
      table.insert(children, ui.label({ text = vertical and tostring(percent) or label, color = color }))
    end
    local container = vertical and ui.column or ui.row
    barWidget.render(container({ gap = vertical and 1 or 4, align = "center" }, children))
  else
    barWidget.render(ui.label({ text = vertical and tostring(percent) or label, color = color }))
  end

  local rows = tooltipRows(device)
  if #rows > 0 then
    barWidget.setTooltip(rows)
    hasTooltip = true
  else
    clearTooltip()
  end
end

local function applyStatus(value)
  if type(value) == "table" then
    status = value
  end
  render()
end

noctalia.state.watch("battery.status", applyStatus)

function update()
  applyStatus(noctalia.state.get("battery.status"))
end
