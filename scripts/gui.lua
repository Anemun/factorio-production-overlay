-- Overlay windows: building, periodic refresh, and handling of their own GUI events.
-- A player can have several independent windows. Any change to a window's list or mode rebuilds that
-- window only; the periodic refresh just updates captions, colours and stock bars. One read cache is
-- shared by all windows and players within an update, so identical reads are done once.

local state = require("scripts.state")
local stats = require("scripts.stats")
local format = require("scripts.format")

local gui = {}

local NAME_PREFIX = "production_overlay_"
local ROOT_PREFIX = NAME_PREFIX .. "root_"
-- In pinned mode the unpin button is a separate top-level element laid over the overlay,
-- so it stays clickable while everything in the root lets clicks through.
local PIN_PREFIX = NAME_PREFIX .. "pin_"
local SHORTCUT = "production-overlay-toggle"
local SLOT_SIZE = 32
local NUMBER_WIDTH = 44
-- Bars are shorter than the icons so bars of neighbouring rows never touch.
local BAR_WIDTH = 6
local BAR_HEIGHT = 24
local PINNED_ICON_SIZE = 24
local PINNED_BAR_WIDTH = 4
local PINNED_BAR_HEIGHT = 18
local PINNED_ROW_SPACING = 2
local PINNED_PADDING = 4
local PIN_BUTTON_SIZE = 16
local DRAG_HANDLE_WIDTH = 20
local PIN_CONTROLS_SPACING = 2
local MOVE_BUTTON_WIDTH = 14
local MOVE_BUTTON_HEIGHT = 16
local SURFACE_DROPDOWN_WIDTH = 150
local NEW_WINDOW_OFFSET = 40
local BAR_STEPS = 20
-- Stock between these fractions of the target counts as "on target" (green); above it is purple.
local ON_TARGET_FROM = 0.9
local ON_TARGET_TO = 1.1

local WHITE = {1, 1, 1}
local GRAY = {0.55, 0.55, 0.55}
local RED = {1, 0.4, 0.35}

local function default_location(player)
  local scale = player.display_scale
  return {x = math.floor(10 * scale), y = math.floor(260 * scale)}
end

local function surface_caption(surface)
  if surface.planet then return surface.planet.prototype.localised_name end
  if surface.platform then return surface.platform.name end
  return surface.localised_name or surface.name
end

local function flying_text(player, text)
  player.create_local_flying_text{text = text, create_at_cursor = true}
end

--- Quality to show as a badge on an icon, or nil.
local function badge_quality(entry)
  if entry.type == "item" and entry.quality ~= "normal" and state.quality_enabled() then
    return entry.quality
  end
  return nil
end

--- Surfaces for the dropdown: planets first, then space platforms, then everything else.
local function sorted_surfaces()
  local list = {}
  for _, surface in pairs(game.surfaces) do
    local kind = surface.planet and 1 or (surface.platform and 2 or 3)
    list[#list + 1] = {surface = surface, kind = kind}
  end
  table.sort(list, function(a, b)
    if a.kind ~= b.kind then return a.kind < b.kind end
    return a.surface.index < b.surface.index
  end)
  return list
end

function gui.sync_shortcut(player, data)
  player.set_shortcut_toggled(SHORTCUT, data.enabled and not data.disabled_by_error)
end

local function destroy_window(player, window)
  for _, prefix in pairs({ROOT_PREFIX, PIN_PREFIX}) do
    local element = player.gui.screen[prefix .. window.id]
    if element and element.valid then
      element.destroy()
    end
  end
  window.gui = {}
end

--- Destroys every element this mod has in the player's screen GUI, including leftovers from older versions.
function gui.destroy_all(player, data)
  for _, child in pairs(player.gui.screen.children) do
    if child.valid and child.name:sub(1, #NAME_PREFIX) == NAME_PREFIX and child.get_mod() == script.mod_name then
      child.destroy()
    end
  end
  for _, window in ipairs(data.windows) do
    window.gui = {}
  end
end

--- Places the unpin button over the reserved top-left cell of the pinned overlay.
local function position_pin(player, window)
  local pin_root = window.gui.pin_root
  if not (pin_root and pin_root.valid and window.location) then return end
  local offset = math.floor(PINNED_PADDING * player.display_scale)
  pin_root.location = {x = window.location.x + offset, y = window.location.y + offset}
end

--- Keeps the window inside the visible screen area and remembers its position.
local function clamp_window(player, window)
  local root = window.gui.root
  if not (root and root.valid) then return end
  local location = root.location or default_location(player)
  local resolution = player.display_resolution
  local keep_visible = math.floor(48 * player.display_scale)
  local x = math.max(0, math.min(location.x, resolution.width - keep_visible))
  local y = math.max(0, math.min(location.y, resolution.height - keep_visible))
  if x ~= location.x or y ~= location.y then
    root.location = {x = x, y = y}
  end
  window.location = {x = x, y = y}
  position_pin(player, window)
end

function gui.clamp(player, data)
  for _, window in ipairs(data.windows) do
    clamp_window(player, window)
  end
end

local function add_number_label(parent, tooltip, ignored)
  local label = parent.add{type = "label", caption = "0", tooltip = tooltip, ignored_by_interaction = ignored}
  label.style.minimal_width = NUMBER_WIDTH
  label.style.horizontal_align = "right"
  return label
end

local function add_columns_table(parent, ignored)
  local columns = parent.add{type = "table", column_count = 4, ignored_by_interaction = ignored}
  columns.style.horizontal_spacing = 12
  columns.style.vertical_spacing = 2
  columns.style.column_alignments[2] = "right"
  columns.style.column_alignments[3] = "right"
  columns.style.column_alignments[4] = "right"
  return columns
end

local function add_header_label(parent, caption, tooltip, ignored)
  local label = parent.add{
    type = "label", style = "caption_label", caption = caption, tooltip = tooltip, ignored_by_interaction = ignored,
  }
  label.style.minimal_width = NUMBER_WIDTH
  label.style.horizontal_align = "right"
end

local function add_slot(parent, tags, tooltip)
  local button = parent.add{type = "choose-elem-button", elem_type = "signal", style = "slot_button", tags = tags, tooltip = tooltip}
  button.style.size = SLOT_SIZE
  return button
end

local function add_title_button(parent, sprite, tooltip, tags)
  return parent.add{type = "sprite-button", style = "frame_action_button", sprite = sprite, tooltip = tooltip, tags = tags}
end

--- First table cell of a row: (reorder buttons,) the icon and the stock bar to its right.
local function add_icon_cell(parent, ignored)
  local cell = parent.add{type = "flow", direction = "horizontal", ignored_by_interaction = ignored}
  cell.style.horizontal_spacing = 2
  cell.style.vertical_align = "center"
  return cell
end

--- Vertical stock bar: a track on top and a coloured fill below it.
--- The pinned overlay uses a lighter track, the dark one blends into its translucent background.
--- Fluids get an empty placeholder so the columns stay aligned; returns nil for them.
local function add_stock_bar(parent, entry, width, height, interactive, tags)
  if entry.type ~= "item" or (not interactive and not entry.target) then
    local placeholder = parent.add{type = "empty-widget", ignored_by_interaction = true}
    placeholder.style.width = width
    placeholder.style.height = height
    return nil
  end
  tags = interactive and tags or nil
  local bar = parent.add{type = "flow", direction = "vertical", tags = tags, ignored_by_interaction = not interactive}
  bar.style.vertical_spacing = 0
  bar.style.width = width
  bar.style.height = height
  local parts = {}
  for _, part in pairs({"track", "fill"}) do
    local sprite = bar.add{
      type = "sprite", sprite = "production-overlay-bar-track", resize_to_sprite = false,
      tags = tags, ignored_by_interaction = not interactive,
    }
    sprite.style.stretch_image_to_widget_size = true
    sprite.style.width = width
    sprite.style.height = 0
    parts[part] = sprite
  end
  local track_sprite = interactive and "production-overlay-bar-track" or "production-overlay-bar-track-light"
  return {track = parts.track, fill = parts.fill, height = height, track_sprite = track_sprite}
end

--- Surface dropdown: "current (name)", "everywhere", then every surface.
local function add_surface_dropdown(parent, player, window)
  local items = {
    {"production-overlay.surface-current", surface_caption(player.surface)},
    {"production-overlay.all-surfaces"},
  }
  local surface_indexes = {}
  local selected = window.surface_mode == "all" and 2 or 1
  for _, item in ipairs(sorted_surfaces()) do
    items[#items + 1] = surface_caption(item.surface)
    surface_indexes[#surface_indexes + 1] = item.surface.index
    if window.surface_mode == "fixed" and window.surface_index == item.surface.index then
      selected = #items
    end
  end
  local dropdown = parent.add{
    type = "drop-down", items = items, selected_index = selected,
    tooltip = {"production-overlay.surface-tooltip"}, tags = {action = "surface", window = window.id},
  }
  dropdown.style.maximal_width = SURFACE_DROPDOWN_WIDTH
  return dropdown, surface_indexes
end

--- Row where the stock target of a chosen item is entered.
local function build_target_editor(parent, window)
  local pending = window.pending
  local row = parent.add{type = "flow", direction = "horizontal"}
  row.style.vertical_align = "center"
  row.style.horizontal_spacing = 6
  row.style.top_margin = 6
  local icon = row.add{
    type = "sprite-button", style = "transparent_slot", sprite = "item/" .. pending.entry.name,
    quality = badge_quality(pending.entry), ignored_by_interaction = true,
  }
  icon.style.size = SLOT_SIZE
  row.add{type = "label", caption = {"production-overlay.stock-target"}, tooltip = {"production-overlay.stock-field-tooltip"}}
  local field = row.add{
    type = "textfield", text = tostring(pending.target), numeric = true, allow_decimal = false, allow_negative = false,
    lose_focus_on_confirm = true, tooltip = {"production-overlay.stock-field-tooltip"},
    tags = {action = "stock-field", window = window.id},
  }
  field.style.width = 80
  row.add{
    type = "sprite-button", style = "item_and_count_select_confirm", sprite = "utility/check_mark",
    tooltip = {"production-overlay.stock-confirm"}, tags = {action = "stock-confirm", window = window.id},
  }
  local cancel = row.add{
    type = "sprite-button", style = "tool_button_red", sprite = "utility/close",
    tooltip = {"production-overlay.stock-cancel"}, tags = {action = "stock-cancel", window = window.id},
  }
  cancel.style.size = 28
  return field
end

--- Full window: title bar with surface selector and buttons, column headers, editable rows.
local function build_full(player, data, window)
  local id = window.id
  local frame = player.gui.screen.add{
    type = "frame", name = ROOT_PREFIX .. id, direction = "vertical", tags = {window = id},
  }
  frame.location = window.location or default_location(player)

  local titlebar = frame.add{type = "flow", direction = "horizontal"}
  titlebar.drag_target = frame
  titlebar.style.horizontal_spacing = 4
  titlebar.style.vertical_align = "center"
  local dropdown, surface_indexes = add_surface_dropdown(titlebar, player, window)
  local dragger = titlebar.add{type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true}
  dragger.style.horizontally_stretchable = true
  dragger.style.height = 24
  dragger.style.minimal_width = 24
  dragger.style.left_margin = 4
  dragger.style.right_margin = 4

  add_title_button(titlebar, "utility/track_button_white", {"production-overlay.pin-tooltip"}, {action = "pin", window = id})
  local network_button = add_title_button(titlebar,
    prototypes.item["roboport"] and "item/roboport" or "item/logistic-robot",
    {window.network_mode == "current" and "production-overlay.network-current-tooltip" or "production-overlay.network-all-tooltip"},
    {action = "network", window = id})
  network_button.toggled = window.network_mode == "current"
  add_title_button(titlebar, "utility/add_white", {"production-overlay.new-window-tooltip"}, {action = "new-window", window = id})
  add_title_button(titlebar, window.collapsed and "utility/expand" or "utility/collapse",
    {window.collapsed and "production-overlay.expand-tooltip" or "production-overlay.collapse-tooltip"},
    {action = "collapse", window = id})
  local close_tooltip = "production-overlay.close-window-tooltip"
  if #data.windows == 1 then
    close_tooltip = "production-overlay.hide-tooltip"
  elseif window.confirm_close then
    close_tooltip = "production-overlay.close-confirm-tooltip"
  end
  local close_button = add_title_button(titlebar, "utility/close", {close_tooltip}, {action = "close", window = id})
  close_button.toggled = window.confirm_close

  local inner = frame.add{type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical"}
  inner.style.horizontally_stretchable = true
  inner.visible = not window.collapsed

  -- The table fills the frame and its first column takes the spare width,
  -- so the number columns stay at the right edge when the title bar is wide.
  local columns = add_columns_table(inner)
  columns.style.horizontally_stretchable = true

  local entries = window.entries
  local rows = {}
  if #entries > 0 then
    local spacer = columns.add{type = "empty-widget"}
    spacer.style.horizontally_stretchable = true
    add_header_label(columns, {"production-overlay.column-produced"}, {"production-overlay.produced-tooltip"})
    add_header_label(columns, {"production-overlay.column-consumed"}, {"production-overlay.consumed-tooltip"})
    add_header_label(columns, {"production-overlay.column-net"}, {"production-overlay.net-tooltip"})
  end
  for index, entry in ipairs(entries) do
    local cell = add_icon_cell(columns)
    local moves = cell.add{type = "flow", direction = "vertical"}
    moves.style.vertical_spacing = 0
    for _, move in pairs({{"up", -1}, {"down", 1}}) do
      local button = moves.add{
        type = "sprite-button", style = "mini_button", sprite = "production-overlay-arrow-" .. move[1],
        tooltip = {"production-overlay.move-" .. move[1]},
        tags = {action = "move", window = id, index = index, delta = move[2]},
      }
      button.style.width = MOVE_BUTTON_WIDTH
      button.style.height = MOVE_BUTTON_HEIGHT
      button.enabled = entries[index + move[2]] ~= nil
    end
    local slot = add_slot(cell, {action = "row", window = id, index = index})
    slot.elem_value = state.signal_from_entry(entry)
    rows[index] = {
      bar = add_stock_bar(cell, entry, BAR_WIDTH, BAR_HEIGHT, true, {action = "stock", window = id, index = index}),
      produced = add_number_label(columns, {"production-overlay.produced-tooltip"}),
      consumed = add_number_label(columns, {"production-overlay.consumed-tooltip"}),
      net = add_number_label(columns, {"production-overlay.net-tooltip"}),
    }
  end
  -- The "+" slot is indented by the reorder buttons so all icons line up.
  local add_cell = add_icon_cell(columns)
  if #entries > 0 then
    local indent = add_cell.add{type = "empty-widget"}
    indent.style.width = MOVE_BUTTON_WIDTH
  end
  add_slot(add_cell, {action = "add", window = id}, {"production-overlay.add-tooltip"})

  local field = nil
  if window.pending then
    field = build_target_editor(inner, window)
  end

  window.gui = {
    root = frame, dropdown = dropdown, surface_indexes = surface_indexes, rows = rows, field = field,
  }
end

--- Pinned overlay: column headers, icons, stock bars and numbers on a translucent background.
--- Every element lets clicks through except the small unpin button.
local function build_pinned(player, window)
  local id = window.id
  local frame = player.gui.screen.add{
    type = "frame", name = ROOT_PREFIX .. id, style = "blurry_frame", direction = "vertical",
    ignored_by_interaction = true, tags = {window = id},
  }
  frame.style.padding = PINNED_PADDING
  frame.location = window.location or default_location(player)

  -- Title row: space for the unpin button and drag handle (laid over it), then the surface name.
  local title_row = frame.add{type = "flow", direction = "horizontal", ignored_by_interaction = true}
  title_row.style.vertical_align = "center"
  title_row.style.horizontal_spacing = 6
  local controls_space = title_row.add{type = "empty-widget", ignored_by_interaction = true}
  controls_space.style.width = PIN_BUTTON_SIZE + PIN_CONTROLS_SPACING + DRAG_HANDLE_WIDTH
  controls_space.style.height = PIN_BUTTON_SIZE
  local title = title_row.add{type = "label", style = "caption_label", ignored_by_interaction = true}

  local columns = add_columns_table(frame, true)
  columns.style.vertical_spacing = PINNED_ROW_SPACING

  columns.add{type = "empty-widget", ignored_by_interaction = true}
  add_header_label(columns, {"production-overlay.column-produced"}, nil, true)
  add_header_label(columns, {"production-overlay.column-consumed"}, nil, true)
  add_header_label(columns, {"production-overlay.column-net"}, nil, true)

  local rows = {}
  for index, entry in ipairs(window.entries) do
    local cell = add_icon_cell(columns, true)
    local icon = cell.add{
      type = "sprite-button", style = "transparent_slot", sprite = entry.type .. "/" .. entry.name,
      quality = badge_quality(entry), ignored_by_interaction = true,
    }
    icon.style.size = PINNED_ICON_SIZE
    rows[index] = {
      bar = add_stock_bar(cell, entry, PINNED_BAR_WIDTH, PINNED_BAR_HEIGHT, false),
      produced = add_number_label(columns, nil, true),
      consumed = add_number_label(columns, nil, true),
      net = add_number_label(columns, nil, true),
    }
  end

  -- Dragging the handle moves this small frame; the overlay follows it in on_location_changed.
  local pin_root = player.gui.screen.add{
    type = "frame", name = PIN_PREFIX .. id, style = "invisible_frame", tags = {window = id},
  }
  local controls = pin_root.add{type = "flow", direction = "horizontal"}
  controls.style.horizontal_spacing = PIN_CONTROLS_SPACING
  local pin_button = controls.add{
    type = "sprite-button", style = "frame_action_button", sprite = "utility/track_button_white",
    tooltip = {"production-overlay.unpin-tooltip"}, tags = {action = "pin", window = id},
  }
  pin_button.style.size = PIN_BUTTON_SIZE
  pin_button.toggled = true
  local handle = controls.add{type = "empty-widget", style = "draggable_space_header"}
  handle.style.width = DRAG_HANDLE_WIDTH
  handle.style.height = PIN_BUTTON_SIZE
  handle.drag_target = pin_root

  window.gui = {root = frame, pin_root = pin_root, title = title, rows = rows}
end

--- (Re)creates one window from its state; nothing is shown while the overlay is off.
function gui.build_window(player, data, window)
  destroy_window(player, window)
  if not data.enabled or data.disabled_by_error then return end
  if window.pinned and #window.entries == 0 then
    window.pinned = false
  end
  if window.pinned then
    window.pending = nil
    build_pinned(player, window)
  else
    build_full(player, data, window)
  end
  clamp_window(player, window)
  gui.update_window(player, data, window, {})

  local field = window.gui.field
  if field and field.valid then
    field.focus()
    field.select_all()
  end
end

--- (Re)creates all windows of the player.
function gui.build(player, data)
  gui.destroy_all(player, data)
  for _, window in ipairs(data.windows) do
    gui.build_window(player, data, window)
  end
end

local function set_number(label, text, color)
  label.caption = text
  label.style.font_color = color
end

--- Fills the bar to `fraction` of its height; nil fraction means "no data" (no target or no network).
local function set_bar(bar, fraction, tooltip)
  if not (bar.track.valid and bar.fill.valid) then return end
  local filled = 0
  if fraction then
    filled = math.floor(math.min(math.max(fraction, 0), 1) * bar.height + 0.5)
    local sprite
    if fraction > ON_TARGET_TO then
      sprite = "over"
    elseif fraction >= ON_TARGET_FROM then
      sprite = tostring(BAR_STEPS)
    else
      -- Red -> yellow -> green is spread over 0..90%, the last (green) step is reserved for "on target".
      local step = math.floor(math.max(fraction, 0) / ON_TARGET_FROM * BAR_STEPS + 0.5)
      sprite = tostring(math.min(step, BAR_STEPS - 1))
    end
    bar.fill.sprite = "production-overlay-bar-" .. sprite
    bar.track.sprite = bar.track_sprite or "production-overlay-bar-track"
  else
    bar.track.sprite = "production-overlay-bar-unset"
  end
  bar.fill.visible = filled > 0
  bar.fill.style.height = filled
  bar.track.visible = filled < bar.height
  bar.track.style.height = bar.height - filled
  if tooltip then
    bar.track.tooltip = tooltip
    bar.fill.tooltip = tooltip
  end
end

--- `network` is the network under the player in "current network" mode (nil if there is none).
local function update_stock(cache, force, window, scope, surface, network, entry, bar)
  local interactive = not window.pinned
  if not entry.target then
    set_bar(bar, nil, interactive and {"production-overlay.stock-unset-tooltip"} or nil)
    return
  end
  local stock
  if window.network_mode == "current" then
    if not network then
      set_bar(bar, nil, interactive and {"production-overlay.stock-no-network-tooltip"} or nil)
      return
    end
    stock = stats.network_stock(cache, network, entry)
  else
    stock = stats.stock(cache, force, scope, surface, entry)
  end
  local fraction = stock / entry.target
  local tooltip = nil
  if interactive then
    tooltip = {
      "production-overlay.stock-tooltip",
      format.number(stock), format.number(entry.target), tostring(math.floor(fraction * 100 + 0.5)),
    }
  end
  set_bar(bar, fraction, tooltip)
end

--- Refreshes one window's numbers and stock bars. Rebuilds it if it went missing.
function gui.update_window(player, data, window, cache)
  if not data.enabled or data.disabled_by_error then return end
  local refs = window.gui
  if not (refs.root and refs.root.valid) then
    gui.build_window(player, data, window)
    return
  end

  local in_cutscene = player.controller_type == defines.controllers.cutscene
  refs.root.visible = not in_cutscene
  if refs.pin_root and refs.pin_root.valid then
    refs.pin_root.visible = not in_cutscene
  end
  if in_cutscene then return end

  local player_surface = player.surface
  -- Keep the "current (name)" dropdown item in sync with where the player is looking.
  if refs.dropdown and refs.dropdown.valid and refs.current_surface ~= player_surface.index then
    refs.dropdown.set_item(1, {"production-overlay.surface-current", surface_caption(player_surface)})
    refs.current_surface = player_surface.index
  end

  if window.collapsed and not window.pinned then return end

  local scope, surface = "one", player_surface
  if window.surface_mode == "all" then
    scope = "all"
  elseif window.surface_mode == "fixed" then
    surface = game.get_surface(window.surface_index) or player_surface
  end

  local title_key = scope == "all" and "all" or surface.index
  if refs.title and refs.title.valid and refs.title_key ~= title_key then
    refs.title.caption = scope == "all" and {"production-overlay.all-surfaces"} or surface_caption(surface)
    refs.title_key = title_key
  end

  local force = player.force
  -- "Current network": on a space platform it is the platform hub, elsewhere the logistic network under
  -- the player. In remote view the player's position is the camera position, so this follows the view.
  local network = nil
  if window.network_mode == "current" then
    local key = "network|" .. force.index .. "|" .. player.index
    network = cache[key]
    if network == nil then
      network = stats.own_platform(player_surface, force)
        or player_surface.find_logistic_network_by_position(player.position, force) or false
      cache[key] = network
    end
    network = network or nil
  end

  for index, entry in ipairs(window.entries) do
    local row = refs.rows[index]
    if row and row.produced.valid and row.consumed.valid and row.net.valid then
      local produced, consumed = stats.get(cache, force, scope, surface, entry)
      local net = produced - consumed
      set_number(row.produced, format.number(produced), produced < format.ZERO and GRAY or WHITE)
      set_number(row.consumed, format.number(consumed), consumed < format.ZERO and GRAY or WHITE)
      local net_color = WHITE
      if net < 0 and -net >= math.max(0.1, 0.02 * consumed) then
        net_color = RED
      elseif math.abs(net) < format.ZERO then
        net_color = GRAY
      end
      set_number(row.net, format.signed(net), net_color)
      if row.bar then
        update_stock(cache, force, window, scope, surface, network, entry, row.bar)
      end
    end
  end
end

--- Periodic refresh of all the player's windows.
function gui.update(player, data, cache)
  for _, window in ipairs(data.windows) do
    gui.update_window(player, data, window, cache)
  end
end

--- Shortcut / hotkey: shows or hides all windows of the player.
function gui.toggle(player, data)
  if data.disabled_by_error then
    data.disabled_by_error = false
    data.error_count = 0
    data.enabled = true
    state.reset_modes(data)
  else
    data.enabled = not data.enabled
  end
  if data.enabled then
    state.validate(data)
  end
  gui.build(player, data)
  gui.sync_shortcut(player, data)
end

--- Pin hotkey: pins every non-empty window if any of them is unpinned, otherwise unpins all.
function gui.toggle_pin_all(player, data)
  if not data.enabled or data.disabled_by_error then return end
  local pin, any_pinned = false, false
  for _, window in ipairs(data.windows) do
    if window.pinned then
      any_pinned = true
    elseif #window.entries > 0 then
      pin = true
    end
  end
  if not pin and not any_pinned then
    flying_text(player, {"production-overlay.nothing-to-pin"})
    return
  end
  for _, window in ipairs(data.windows) do
    window.pinned = pin and #window.entries > 0
  end
  gui.build(player, data)
end

local function toggle_pin(player, data, window)
  if window.pinned then
    window.pinned = false
  elseif #window.entries == 0 then
    flying_text(player, {"production-overlay.nothing-to-pin"})
    return
  else
    window.pinned = true
  end
  gui.build_window(player, data, window)
end

--- Builds every unpinned window except `skip` again (their close button depends on the window count).
local function rebuild_others(player, data, skip)
  for _, other in ipairs(data.windows) do
    if other ~= skip and not other.pinned then
      gui.build_window(player, data, other)
    end
  end
end

local function new_window(player, data, window)
  if #data.windows >= state.MAX_WINDOWS then
    flying_text(player, {"production-overlay.window-limit", state.MAX_WINDOWS})
    return
  end
  local was_single = #data.windows == 1
  local created = state.new_window(data, window)
  local origin = window.location or default_location(player)
  local offset = math.floor(NEW_WINDOW_OFFSET * player.display_scale)
  created.location = {x = origin.x + offset, y = origin.y + offset}
  if was_single then
    rebuild_others(player, data, created)
  end
  gui.build_window(player, data, created)
end

local function close_window(player, data, window)
  if #data.windows == 1 then
    -- The last window is never deleted, closing it just hides the overlay.
    data.enabled = false
    gui.build(player, data)
    gui.sync_shortcut(player, data)
  elseif #window.entries > 0 and not window.confirm_close then
    window.confirm_close = true
    gui.build_window(player, data, window)
  else
    destroy_window(player, window)
    state.remove_window(data, window.id)
    if #data.windows == 1 then
      rebuild_others(player, data, nil)
    end
  end
end

--- Opens the stock target editor for an item being added (index nil) or replacing / editing row `index`.
local function start_target_edit(player, data, window, entry, index, target)
  window.pending = {entry = entry, index = index, target = target or state.default_target(entry.name)}
  gui.build_window(player, data, window)
end

local function confirm_target(player, data, window)
  local pending = window.pending
  window.pending = nil
  if not pending then
    gui.build_window(player, data, window)
    return
  end

  local field = window.gui.field
  local amount = pending.target
  if field and field.valid then
    amount = tonumber(field.text) or 0
  end
  local entry = state.normalize({
    type = "item", name = pending.entry.name, quality = pending.entry.quality, target = amount,
  }, state.quality_enabled())
  if not entry then
    gui.build_window(player, data, window)
    return
  end

  local entries = window.entries
  local existing = state.find(window, entry)
  if pending.index then
    if not entries[pending.index] then
      -- The row disappeared meanwhile; nothing to update.
    elseif existing and existing ~= pending.index then
      flying_text(player, {"production-overlay.already-pinned"})
    else
      entries[pending.index] = entry
    end
  elseif existing then
    flying_text(player, {"production-overlay.already-pinned"})
  elseif #entries >= state.MAX_ENTRIES then
    flying_text(player, {"production-overlay.limit-reached", state.MAX_ENTRIES})
  else
    table.insert(entries, entry)
  end
  gui.build_window(player, data, window)
end

local function on_add(player, data, window, element)
  local value = element.elem_value
  if value == nil then return end
  element.elem_value = nil

  local entry = state.normalize(state.entry_from_signal(value), state.quality_enabled())
  if not entry then
    flying_text(player, {"production-overlay.only-items-fluids"})
  elseif state.find(window, entry) then
    flying_text(player, {"production-overlay.already-pinned"})
  elseif #window.entries >= state.MAX_ENTRIES then
    flying_text(player, {"production-overlay.limit-reached", state.MAX_ENTRIES})
  elseif entry.type == "item" then
    start_target_edit(player, data, window, entry, nil)
  else
    window.pending = nil
    table.insert(window.entries, entry)
    gui.build_window(player, data, window)
  end
end

local function on_row_changed(player, data, window, element, index)
  local current = window.entries[index]
  if not current then
    gui.build_window(player, data, window)
    return
  end

  local value = element.elem_value
  if value == nil then
    window.pending = nil
    table.remove(window.entries, index)
    gui.build_window(player, data, window)
    return
  end

  local entry = state.normalize(state.entry_from_signal(value), state.quality_enabled())
  local existing = entry and state.find(window, entry)
  if not entry or (existing and existing ~= index) then
    element.elem_value = state.signal_from_entry(current)
    flying_text(player, entry and {"production-overlay.already-pinned"} or {"production-overlay.only-items-fluids"})
    return
  end
  if entry.type == "item" then
    -- Same item in another quality keeps its target; a different item starts from its own default.
    local target = current.type == "item" and current.name == entry.name and current.target or nil
    start_target_edit(player, data, window, entry, index, target)
  else
    window.pending = nil
    window.entries[index] = entry
    gui.build_window(player, data, window)
  end
end

--- The window an element belongs to (from its tags), or nil.
local function window_of(data, element)
  local id = element.tags.window
  if type(id) ~= "number" then return nil end
  return state.find_window(data, id)
end

function gui.on_elem_changed(player, data, element)
  local window = window_of(data, element)
  if not window then return end
  window.confirm_close = false
  local tags = element.tags
  if tags.action == "add" then
    on_add(player, data, window, element)
  elseif tags.action == "row" and type(tags.index) == "number" then
    on_row_changed(player, data, window, element, tags.index)
  end
end

function gui.on_click(player, data, element)
  local window = window_of(data, element)
  if not window then return end
  local tags = element.tags
  local action = tags.action
  if action == nil or action == "add" or action == "row" or action == "stock-field" or action == "surface" then
    return
  end
  if action == "close" then
    close_window(player, data, window)
    return
  end

  local had_confirm = window.confirm_close
  window.confirm_close = false
  if action == "pin" then
    toggle_pin(player, data, window)
  elseif action == "network" then
    window.network_mode = window.network_mode == "all" and "current" or "all"
    gui.build_window(player, data, window)
  elseif action == "new-window" then
    if had_confirm then gui.build_window(player, data, window) end
    new_window(player, data, window)
  elseif action == "collapse" then
    window.collapsed = not window.collapsed
    gui.build_window(player, data, window)
  elseif action == "move" and type(tags.index) == "number" and type(tags.delta) == "number" then
    local entries = window.entries
    local from, to = tags.index, tags.index + tags.delta
    if entries[from] and entries[to] then
      entries[from], entries[to] = entries[to], entries[from]
      window.pending = nil
    end
    gui.build_window(player, data, window)
  elseif action == "stock" and type(tags.index) == "number" and not window.pinned then
    local entry = window.entries[tags.index]
    if entry and entry.type == "item" then
      start_target_edit(player, data, window, entry, tags.index, entry.target)
    end
  elseif action == "stock-confirm" then
    confirm_target(player, data, window)
  elseif action == "stock-cancel" then
    window.pending = nil
    gui.build_window(player, data, window)
  elseif had_confirm then
    gui.build_window(player, data, window)
  end
end

function gui.on_confirmed(player, data, element)
  local window = window_of(data, element)
  if window and element.tags.action == "stock-field" then
    confirm_target(player, data, window)
  end
end

function gui.on_selection_changed(player, data, element)
  local window = window_of(data, element)
  if not (window and element.tags.action == "surface") then return end
  local selected = element.selected_index
  if selected == 1 then
    window.surface_mode = "current"
    window.surface_index = nil
  elseif selected == 2 then
    window.surface_mode = "all"
    window.surface_index = nil
  else
    local index = window.gui.surface_indexes and window.gui.surface_indexes[selected - 2]
    if index and game.get_surface(index) then
      window.surface_mode = "fixed"
      window.surface_index = index
    else
      window.surface_mode = "current"
      window.surface_index = nil
    end
  end
  gui.update_window(player, data, window, {})
end

function gui.on_location_changed(player, data, element)
  local window = window_of(data, element)
  if not window then return end
  if element.name == ROOT_PREFIX .. window.id then
    window.location = element.location
  elseif element.name == PIN_PREFIX .. window.id then
    -- The pinned overlay's drag handle was moved: bring the overlay along.
    local root = window.gui.root
    local offset = math.floor(PINNED_PADDING * player.display_scale)
    local location = element.location
    window.location = {x = location.x - offset, y = location.y - offset}
    if root and root.valid then
      root.location = window.location
    end
  end
end

--- Surfaces appeared, disappeared or were renamed: refresh the dropdowns and forget deleted surfaces.
function gui.on_surfaces_changed(player, data)
  state.validate(data)
  for _, window in ipairs(data.windows) do
    if not window.pinned then
      gui.build_window(player, data, window)
    end
  end
end

return gui
