-- Only our own prototypes are added here; nothing existing is modified.

data:extend({
  {
    type = "custom-input",
    name = "production-overlay-toggle",
    key_sequence = "CONTROL + ALT + P",
    action = "lua",
  },
  {
    type = "custom-input",
    name = "production-overlay-pin",
    key_sequence = "CONTROL + ALT + O",
    action = "lua",
  },
  {
    type = "shortcut",
    name = "production-overlay-toggle",
    order = "z[production-overlay]",
    action = "lua",
    toggleable = true,
    associated_control_input = "production-overlay-toggle",
    icon = "__production-overlay__/graphics/shortcut-x56.png",
    icon_size = 56,
    small_icon = "__production-overlay__/graphics/shortcut-x24.png",
    small_icon_size = 24,
  },
})

-- Solid-colour tiles for the stock bar, stretched to the bar size in the GUI.
local function bar_sprite(name, file)
  return {
    type = "sprite",
    name = "production-overlay-bar-" .. name,
    filename = "__production-overlay__/graphics/bar/" .. file .. ".png",
    size = 8,
    flags = {"gui"},
  }
end

local bar_sprites = {}
for _, name in pairs({"track", "track-light", "unset", "over"}) do
  bar_sprites[#bar_sprites + 1] = bar_sprite(name, name)
end
for i = 0, 20 do
  bar_sprites[#bar_sprites + 1] = bar_sprite(tostring(i), tostring(i))
end
data:extend(bar_sprites)

-- Chevrons for the row reorder buttons (the game has no "up" chevron sprite).
for _, direction in pairs({"up", "down"}) do
  data:extend({{
    type = "sprite",
    name = "production-overlay-arrow-" .. direction,
    filename = "__production-overlay__/graphics/arrow-" .. direction .. ".png",
    size = 32,
    scale = 0.5,
    flags = {"gui-icon"},
  }})
end
