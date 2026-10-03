-- Production Overlay: event wiring and the safety net.
-- Every handler is guarded: an error is logged, the player's overlay is rebuilt,
-- and after repeated failures the overlay is turned off for that player. The game itself is never interrupted.

local state = require("scripts.state")
local gui = require("scripts.gui")

-- Set to true while developing to see errors instead of swallowing them.
local DEBUG = false
local MAX_ERRORS = 3
local TOGGLE = "production-overlay-toggle"
local PIN = "production-overlay-pin"
local INTERVAL_SETTING = "production-overlay-update-interval"

local function log_error(context, err)
  log("[production-overlay] error in " .. context .. ": " .. tostring(err))
end

--- Wraps an event handler so an error never escapes to the game.
local function safe(context, handler)
  if DEBUG then return handler end
  return function(event)
    local ok, err = xpcall(handler, debug.traceback, event)
    if not ok then log_error(context, err) end
  end
end

local function recover(player, err)
  log_error("player " .. player.index, err)
  local ok, recover_err = xpcall(function()
    local data = state.get(player.index)
    data.error_count = data.error_count + 1
    if data.error_count >= MAX_ERRORS then
      data.disabled_by_error = true
      gui.destroy_all(player, data)
      gui.sync_shortcut(player, data)
      player.print({"production-overlay.disabled-by-error"})
    else
      -- Rebuild in the simplest state: rebuilding the same (e.g. pinned) state could fail again and again.
      state.reset_modes(data)
      state.validate(data)
      gui.build(player, data)
    end
  end, debug.traceback)
  if not ok then
    log_error("recovery for player " .. player.index, recover_err)
    pcall(function()
      local data = state.get(player.index)
      data.disabled_by_error = true
      gui.destroy_all(player, data)
    end)
  end
end

--- Runs fn(player, data, ...) for one player; failures only affect this player's overlay.
local function guarded(player, fn, ...)
  local args = table.pack(...)
  local function run()
    return fn(player, state.get(player.index), table.unpack(args, 1, args.n))
  end
  if DEBUG then return run() end
  local ok, err = xpcall(run, debug.traceback)
  if not ok then recover(player, err) end
end

local function event_player(event)
  local player = game.get_player(event.player_index)
  if player and player.valid then return player end
  return nil
end

local function init_player(player, data)
  state.validate(data)
  gui.build(player, data)
  gui.sync_shortcut(player, data)
end

script.on_init(safe("on_init", function()
  for _, player in pairs(game.players) do
    guarded(player, init_player)
  end
end))

script.on_configuration_changed(safe("on_configuration_changed", function()
  state.prune()
  for _, player in pairs(game.players) do
    guarded(player, function(p, data)
      data.disabled_by_error = false
      data.error_count = 0
      for _, window in ipairs(data.windows) do
        window.pending = nil
        window.confirm_close = false
      end
      init_player(p, data)
    end)
  end
end))

script.on_event(defines.events.on_player_created, safe("on_player_created", function(event)
  local player = event_player(event)
  if player then guarded(player, init_player) end
end))

script.on_event(defines.events.on_player_removed, safe("on_player_removed", function(event)
  state.remove(event.player_index)
end))

local function on_toggle(event)
  local player = event_player(event)
  if player then guarded(player, gui.toggle) end
end

script.on_event(defines.events.on_lua_shortcut, safe("on_lua_shortcut", function(event)
  if event.prototype_name == TOGGLE then on_toggle(event) end
end))

script.on_event(TOGGLE, safe("toggle hotkey", on_toggle))

script.on_event(PIN, safe("pin hotkey", function(event)
  local player = event_player(event)
  if player then guarded(player, gui.toggle_pin_all) end
end))

--- Dispatches a GUI event to `handler` only for elements created by this mod.
local function own_gui_event(context, handler)
  return safe(context, function(event)
    local element = event.element
    if not (element and element.valid) or element.get_mod() ~= script.mod_name then return end
    local player = event_player(event)
    if player then guarded(player, handler, element) end
  end)
end

script.on_event(defines.events.on_gui_elem_changed, own_gui_event("on_gui_elem_changed", gui.on_elem_changed))
script.on_event(defines.events.on_gui_click, own_gui_event("on_gui_click", gui.on_click))
script.on_event(defines.events.on_gui_confirmed, own_gui_event("on_gui_confirmed", gui.on_confirmed))
script.on_event(defines.events.on_gui_selection_state_changed,
  own_gui_event("on_gui_selection_state_changed", gui.on_selection_changed))
script.on_event(defines.events.on_gui_location_changed, own_gui_event("on_gui_location_changed", gui.on_location_changed))

script.on_event({
  defines.events.on_player_display_resolution_changed,
  defines.events.on_player_display_scale_changed,
}, safe("display changed", function(event)
  local player = event_player(event)
  if player then guarded(player, gui.clamp) end
end))

-- Surface dropdowns list every surface, so they are rebuilt when the set of surfaces changes.
script.on_event({
  defines.events.on_surface_created,
  defines.events.on_surface_deleted,
  defines.events.on_surface_renamed,
  defines.events.on_surface_imported,
}, safe("surfaces changed", function()
  local players = storage.players
  if type(players) ~= "table" then return end
  for _, player in pairs(game.players) do
    local data = players[player.index]
    if data and data.enabled and not data.disabled_by_error then
      guarded(player, gui.on_surfaces_changed)
    end
  end
end))

--- Refresh period in seconds from the map setting (1 by default).
local function update_interval()
  local setting = settings.global[INTERVAL_SETTING]
  local seconds = setting and tonumber(setting.value) or 1
  return math.max(1, math.floor(seconds))
end

-- Runs every second and skips the seconds that don't match the configured interval,
-- so changing the setting never needs re-registering the handler.
script.on_nth_tick(60, safe("update", function(event)
  if math.floor(event.tick / 60) % update_interval() ~= 0 then return end
  local players = storage.players
  if type(players) ~= "table" then return end
  local cache = {}
  for _, player in pairs(game.connected_players) do
    local data = players[player.index]
    if data and data.enabled and not data.disabled_by_error then
      guarded(player, gui.update, cache)
    end
  end
end))
