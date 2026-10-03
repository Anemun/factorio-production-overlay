-- Persistent per-player state in `storage` and validation of tracked entries.
-- Everything is created lazily with defaults, so a missing or partial storage never breaks anything.
--
-- storage.players[player_index] = {
--   enabled, disabled_by_error, error_count,   -- player-wide: overlay on/off and the safety net
--   next_window_id,
--   windows = {window, ...},                   -- independent overlay windows, at least one
-- }
-- window = {
--   id, entries, location, collapsed, pinned,
--   surface_mode = "current" | "all" | "fixed", surface_index (for "fixed"),
--   network_mode = "all" | "current",
--   pending,        -- stock target editor: {entry, index (nil when adding), target}
--   confirm_close,  -- the close button was clicked once on a non-empty window
--   gui,            -- references to this window's GUI elements; always checked with .valid
-- }

local state = {}

state.SCHEMA_VERSION = 2
state.MAX_ENTRIES = 50
state.MAX_WINDOWS = 10
-- Logistic network counts are int32.
state.MAX_TARGET = 2147483647

local function root()
  if type(storage.players) ~= "table" then
    storage.players = {}
  end
  storage.version = state.SCHEMA_VERSION
  return storage.players
end

--- Fills missing or broken window fields with defaults.
local function repair_window(window)
  if type(window.entries) ~= "table" then window.entries = {} end
  if type(window.location) ~= "table" then window.location = nil end
  if type(window.collapsed) ~= "boolean" then window.collapsed = false end
  if type(window.pinned) ~= "boolean" then window.pinned = false end
  local mode = window.surface_mode
  if mode ~= "current" and mode ~= "all" and mode ~= "fixed" then window.surface_mode = "current" end
  if window.surface_mode == "fixed" and type(window.surface_index) ~= "number" then window.surface_mode = "current" end
  if window.network_mode ~= "current" and window.network_mode ~= "all" then window.network_mode = "all" end
  if window.pending ~= nil and type(window.pending) ~= "table" then window.pending = nil end
  if type(window.confirm_close) ~= "boolean" then window.confirm_close = false end
  if type(window.gui) ~= "table" then window.gui = {} end
end

function state.new_window(data, template)
  local window = {
    id = data.next_window_id,
    entries = {},
    surface_mode = template and template.surface_mode,
    surface_index = template and template.surface_index,
    network_mode = template and template.network_mode,
  }
  data.next_window_id = data.next_window_id + 1
  repair_window(window)
  table.insert(data.windows, window)
  return window
end

--- Schema 1 kept a single window's fields directly on the player; move them into the first window.
local function migrate_single_window(data)
  if type(data.windows) == "table" or type(data.entries) ~= "table" then return end
  data.windows = {{
    id = 1,
    entries = data.entries,
    location = data.location,
    collapsed = data.collapsed,
    pinned = data.pinned,
    surface_mode = data.surface_mode,
    network_mode = data.network_mode,
  }}
  data.next_window_id = 2
  for _, key in pairs({"entries", "location", "collapsed", "pinned", "surface_mode", "network_mode", "pending", "gui"}) do
    data[key] = nil
  end
end

--- Returns the state table of a player, creating or repairing it as needed.
function state.get(player_index)
  local players = root()
  local data = players[player_index]
  if type(data) ~= "table" then
    data = {}
    players[player_index] = data
  end
  migrate_single_window(data)
  if type(data.enabled) ~= "boolean" then data.enabled = true end
  if type(data.disabled_by_error) ~= "boolean" then data.disabled_by_error = false end
  if type(data.error_count) ~= "number" then data.error_count = 0 end
  if type(data.next_window_id) ~= "number" then data.next_window_id = 1 end
  if type(data.windows) ~= "table" then data.windows = {} end

  local windows = {}
  for _, window in pairs(data.windows) do
    if type(window) == "table" and type(window.id) == "number" then
      if window.id >= data.next_window_id then data.next_window_id = window.id + 1 end
      repair_window(window)
      windows[#windows + 1] = window
    end
  end
  data.windows = windows
  if #windows == 0 then
    state.new_window(data)
  end
  return data
end

function state.find_window(data, id)
  for position, window in ipairs(data.windows) do
    if window.id == id then
      return window, position
    end
  end
  return nil
end

function state.remove_window(data, id)
  local _, position = state.find_window(data, id)
  if position and #data.windows > 1 then
    table.remove(data.windows, position)
  end
end

--- Default stock target: ten stacks.
function state.default_target(item_name)
  local prototype = prototypes.item[item_name]
  return prototype and prototype.stack_size * 10 or 100
end

--- A positive whole stock target, or nil for "not tracked".
function state.normalize_target(value)
  value = tonumber(value)
  if not value or value ~= value or value < 1 then return nil end
  return math.min(math.floor(value), state.MAX_TARGET)
end

function state.remove(player_index)
  root()[player_index] = nil
end

--- Drops state of players that no longer exist.
function state.prune()
  local players = root()
  for index in pairs(players) do
    if not game.get_player(index) then
      players[index] = nil
    end
  end
end

--- Quality counts as enabled when any visible quality other than "normal" exists
--- (works for the official quality mod and third-party ones alike).
function state.quality_enabled()
  for name, quality in pairs(prototypes.quality) do
    if name ~= "normal" and not quality.hidden then
      return true
    end
  end
  return false
end

--- Returns a valid copy of the entry, or nil if it can't be tracked in the current game.
function state.normalize(entry, quality_on)
  if type(entry) ~= "table" or type(entry.name) ~= "string" then return nil end
  if entry.type == "fluid" then
    if not prototypes.fluid[entry.name] then return nil end
    return {type = "fluid", name = entry.name}
  elseif entry.type == "item" then
    if not prototypes.item[entry.name] then return nil end
    local quality = entry.quality
    if not quality_on or type(quality) ~= "string" or not prototypes.quality[quality] then
      quality = "normal"
    end
    return {type = "item", name = entry.name, quality = quality, target = state.normalize_target(entry.target)}
  end
  return nil
end

function state.key(entry)
  return entry.type .. "/" .. entry.name .. "/" .. (entry.quality or "")
end

--- Converts a choose-elem-button "signal" value into an entry; nil for non item/fluid signals.
function state.entry_from_signal(signal)
  if type(signal) ~= "table" or not signal.name then return nil end
  if signal.type == nil or signal.type == "item" then
    return {type = "item", name = signal.name, quality = signal.quality}
  elseif signal.type == "fluid" then
    return {type = "fluid", name = signal.name}
  end
  return nil
end

function state.signal_from_entry(entry)
  if entry.type == "fluid" then
    return {type = "fluid", name = entry.name}
  end
  return {type = "item", name = entry.name, quality = entry.quality}
end

--- Index of an entry with the same key in the window, or nil.
function state.find(window, entry)
  local key = state.key(entry)
  for i, existing in ipairs(window.entries) do
    if state.key(existing) == key then
      return i
    end
  end
  return nil
end

--- Removes invalid entries, fixes quality, drops duplicates and enforces the limit;
--- also forgets a fixed surface that no longer exists.
function state.validate_window(window)
  local quality_on = state.quality_enabled()
  local result, seen = {}, {}
  for _, entry in pairs(window.entries) do
    local normalized = state.normalize(entry, quality_on)
    if normalized and #result < state.MAX_ENTRIES then
      local key = state.key(normalized)
      if not seen[key] then
        seen[key] = true
        result[#result + 1] = normalized
      end
    end
  end
  window.entries = result
  if window.surface_mode == "fixed" and not game.get_surface(window.surface_index) then
    window.surface_mode = "current"
    window.surface_index = nil
  end
end

--- Puts every window into its simplest state (not pinned, no open editor). Used after an error,
--- so a mode that fails to build every time can't keep the overlay broken.
function state.reset_modes(data)
  for _, window in ipairs(data.windows) do
    window.pinned = false
    window.pending = nil
    window.confirm_close = false
  end
end

function state.validate(data)
  for _, window in ipairs(data.windows) do
    state.validate_window(window)
  end
end

return state
