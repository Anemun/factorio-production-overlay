# Production Overlay — Specification

A mod for Factorio 2.0. Shows compact overlay windows on the main screen:
production and consumption of selected items and fluids over the last minute,
and item stock levels in logistic networks and space platform hubs. This is
"at a glance" statistics to quickly spot what's lagging.

- Internal name: `production-overlay`
- Title: Production Overlay
- Current version: **0.5.0** (history in `changelog.txt`)
- Target game version: Factorio **2.0** (`"factorio_version": "2.0"`); tested on
  2.0.77, with and without Space Age
- Dependencies: `base` only. No flib, no other libraries. Space Age and
  quality are optional, detected at runtime.

---

## 1. Principles (mandatory requirements)

The mod is **UI only** and must never become a point of failure.

**P1. Read-only.** The mod does not change game state: it does not create
entities, and does not touch surfaces, forces, recipes, inventories, or
other mods' prototypes. It only changes its own GUI and its own `storage`
table.

**P2. Minimal data stage.** The mod adds only its own prototypes: a
shortcut, two hotkeys, sprites (stock bar, arrows), and one map setting
(see section 5). Other mods' `data.raw` is never modified, and there are no
startup settings.

**P3. Fault tolerance.** Every event handler is wrapped in `xpcall`, and
per-player work runs in its own `xpcall`, so an error for one player does
not affect the others. On error:
1. Full details with a stack trace are written to `factorio-current.log` via
   `log()` (lines starting with `[production-overlay] error ...`).
2. All of the player's windows are reset to a plain state (unpinned, no open
   target editor) and rebuilt. This way a mode that crashes on every build
   cannot hide the overlay forever.
3. After 3 errors, the player's overlay is disabled (`disabled_by_error`),
   and the player gets a one-time chat message. It can be re-enabled via the
   shortcut button or hotkey (also starting from a plain state), or
   automatically on `on_configuration_changed`.

`control.lua` has a `DEBUG = false` constant. When set to `true`, errors are
re-raised instead of being caught, to make them visible during development.

**P4. Everything is validated.** Before use, the mod validates the player,
GUI elements (`.valid`), prototypes (`prototypes.item/fluid/quality[...]`),
surfaces, and platforms. The `storage` structure is lazily filled with
default values on each access; corrupted data is replaced with defaults.

**P5. Can be added or removed at any time.**
- Adding to an existing save: `on_init` creates state and windows for all
  existing players.
- Removing from a save: Factorio itself removes the mod's GUI, storage, and
  shortcut — nothing is left behind.
- Updating the mod or changing the mod set: `on_configuration_changed`
  migrates and validates data and rebuilds all windows.

**P6. Multiplayer safety.** Logic relies only on `storage` and the game API.
No local caches across ticks (a cache lives for a single update only), no
writes in `on_load`, no `game.player`.

**P7. Performance.** Only `on_nth_tick(60)`, no `on_tick`. Only visible,
non-collapsed windows of connected players are updated. Repeated reads
within a single update are cached across all windows and players.

**P8. Portability to 2.1.** APIs removed in 2.1 are not used. That way,
porting reduces to changing `factorio_version` in `info.json` and running
the test plan. A single zip cannot support both 2.0 and 2.1 — that's a game
limitation.

**P9. Text.** All text goes through locales only, and must exist in both
`en` and `ru`. Tooltips: minimal text, maximum usefulness.

---

## 2. Functionality

### 2.1. Overlay window

- The window is a `frame` in `player.gui.screen`. A player can have several
  independent windows (see 2.10), each with its own list, surface, network
  mode, position, collapsed state, and pinned state.
- The window is dragged by its title bar (`drag_target`). Position is saved
  per window. Default position is `x = 10, y = 260` (accounting for UI
  scale). If a window ends up off-screen (after a resolution or UI scale
  change), it's moved back into the visible area.
- Title bar, left to right:
  - surface dropdown (see 2.5);
  - drag area;
  - "Pin" pushpin (see 2.8);
  - logistic network switch, roboport icon (see 2.9);
  - "+" — new window (see 2.10);
  - collapse/expand: in collapsed state only the title bar remains;
  - "×" — close (see 2.10).
- Below the title bar is a 4-column table: icon cell, `+/min`, `-/min`,
  `total`. Number columns are right-aligned: extra width goes to the icon
  column.
- Only the game's built-in styles are used; sizes and margins are set via
  `element.style` at runtime. There is no custom `gui-style`.
- The window never becomes `player.opened`: it does not capture E/Esc and is
  not closed by them.

### 2.2. Resource rows

Icon cell: ↑↓ arrows (regular window only), resource icon
(`choose-elem-button` with quality), stock bar on the right (items only,
see 2.9).

| Icon + bar | `+/min` | `-/min` | `total` |
|---|---|---|---|
| ↑↓ [plate] ▮ | `12.3k` | `11.0k` | `+1.3k` |

- Unit is **per minute**, values are the average over the last minute, same
  as the "1 min" graph in the game's statistics window.
- Production and consumption are unsigned; total (production − consumption)
  is signed.
- Colors:
  - total is red if it's `< 0` and `|total| ≥ max(0.1, 2% of consumption)`;
  - values below 0.05 are shown as `0` and in gray;
  - everything else is white.
- Number format: `< 10` → `3.4`; `< 1000` → `512`; beyond that `1.2k`, `12k`,
  `1.2M`, `12M`.
- Tooltips on column headers and numbers: "Production per minute",
  "Consumption per minute", "Balance per minute". The icon's tooltip is the
  game's standard one.

### 2.3. Adding, replacing, removing, reordering

Uses the game's standard element picker (`choose-elem-button`,
`elem_type = "signal"`): one window with item and fluid tabs and a quality
picker.

- **Add:** there is always an empty slot at the end of the list. A fluid is
  added immediately; for an item, the stock target editor opens first (see
  2.9).
- **Replace:** left-click on a row's icon opens the same picker. A fluid is
  replaced immediately; for an item, the target editor opens again.
- **Remove:** right-click on a row's icon (standard `choose-elem-button`
  clear).
- **Reorder:** two small chevron buttons ↑↓ to the left of the icon
  (14×16 px, custom sprites `production-overlay-arrow-up/down`) swap the
  row with its neighbor. The first row's ↑ and the last row's ↓ are
  disabled. The add slot is shifted by the button width so icons line up.
- Only items and fluids are accepted. Other signals (virtual, entities,
  recipes, etc.) are rejected: the slot reverts to its previous state and
  the cursor shows "Items and fluids only".
- Duplicates (same type, name, and quality) are not added: "Already in the
  list".
- A window holds at most 50 rows: "No more than 50 rows".
- **Decision:** the engine's built-in logistic request picker (item +
  amount + quality, researched items only) is not accessible to mods. The
  signal picker plus a custom target editor is used instead; extra entries
  in the signal picker (enemies, signs, recipes) are acceptable.

### 2.4. Quality

- Tracks a **specific selected quality**. There is no "any quality" mode.
- Quality is optional. Whether it's enabled is determined by prototypes,
  not by mod name: at least one non-hidden quality other than `normal`
  exists. This also works with third-party quality mods.
- If quality is disabled, everything is stored and queried as `normal`, and
  the quality icon is not shown.
- If a saved quality disappears (the quality mod was removed), the row
  falls back to `normal`; resulting duplicates are merged.
- Fluids have no quality.

### 2.5. Surfaces

A dropdown at the start of the title bar, independent per window (tooltip
"Surface"):

- **"Current: <name>"** (default) — `player.surface`, i.e. the surface the
  player is currently looking at, including remote view. The name in the
  item updates live.
- **"Everywhere"** — sum across all surfaces: planets and space platforms.
- **A specific surface** — all surfaces in the game: planets first, then
  space platforms, then the rest (e.g. Factorissimo floors). The surface
  index is stored; if it's removed, the window falls back to "Current".

Surface name: for a planet, the planet's localised name; for a platform, its
name; otherwise `localised_name` or `name`. The list is rebuilt on
`on_surface_created/deleted/renamed/imported`. List width is up to 150 px.

### 2.6. Show and hide

- The shortcut on the quick access bar (bar chart icon) and the
  `CONTROL + ALT + P` hotkey show and hide all of a player's windows at
  once. Shortcut state is kept in sync (`set_shortcut_toggled`). Window
  modes (pinned, collapsed) are preserved.
- During cutscenes, windows are hidden automatically
  (`controller_type == defines.controllers.cutscene`).
- The first time the mod appears for a player, there is one empty window
  and the overlay is enabled.

### 2.7. Data retrieval

Every N seconds (map setting, default 1, see section 5), visible windows
have only their labels, colors, and bars updated; the GUI itself is not
rebuilt. Collapsed windows are skipped (only the current surface name in
the dropdown is updated).

- Items:
  `force.get_item_production_statistics(surface).get_flow_count{name = {name = N, quality = Q}, category = "input"|"output", precision_index = defines.flow_precision_index.one_minute}`
- Fluids: `get_fluid_production_statistics(surface)`, `name = N`.
- `input` is production, `output` is consumption.
- In "Everywhere" mode, values are summed across `game.surfaces`.
- A single per-update cache is shared across all windows and players:
  statistics objects, values keyed by
  `(force, surface/"everywhere", type, name, quality)`, lists of a force's
  logistic networks and platforms, and the player's resolved "current
  network".

### 2.8. Pinned mode

An unobtrusive overlay with nothing extra.

- Enabled via the pushpin in the window's title bar (that window only) or
  the `CONTROL + ALT + O` hotkey (all windows, see 2.10). An empty window
  can't be pinned: the cursor shows "List is empty"; if a window becomes
  empty, it unpins itself on the next rebuild.
- Layout, top to bottom:
  - top row: a small (16 px) pressed pushpin, a drag "handle" next to it
    (20×16, `draggable_space_header` style), then the surface name (name,
    "Everywhere", or the selected surface);
  - column header row: `+/min`, `-/min`, `total`;
  - rows: 24 px icon (with quality), stock bar (only if a target is set),
    production, consumption, total; 2 px between rows.
- No title bar buttons, dropdown, arrows, or add slot.
- Background: a semi-transparent blurred backdrop (`blurry_frame` style),
  4 px padding.
- Clicks pass through everything except the pushpin and handle:
  `ignored_by_interaction` is set on every overlay element. The pushpin and
  handle live in a separate small top-level frame (`invisible_frame` with a
  horizontal flow inside), overlaid on top of the reserved space in the top
  row. This keeps them clickable regardless of how the game propagates
  `ignored_by_interaction` to children.
- Dragging: the handle's `drag_target` is that small frame. When it moves
  (`on_gui_location_changed`), the overlay follows and the window position
  is saved.
- Clicking the pushpin unpins the window.
- Collapsed state is ignored in pinned mode: rows are always visible.

### 2.9. Stock levels

For items (not fluids), a target stock level can be set, and a small
vertical bar next to the icon shows how much of the item is stored relative
to that target.

- **Target editor.** After selecting an item (adding or replacing), a row
  appears below the table: icon, "Target:", a number field, and "Save"
  (green) and "Cancel" (red) buttons. The field is pre-filled with the
  default value (10 stacks, `stack_size × 10`), focused, text selected.
  Enter also saves. "Cancel" does not add or change the item. Field
  tooltip: "Target = 100% of the bar / 0 — no bar".
- Replacing with the same item at a different quality keeps the target;
  replacing with a different item resets it to that item's default.
- **Changing the target:** clicking the bar in the regular window opens the
  same editor.
- **0 means "don't track".** The bar is pale and empty, tooltip "No target
  set / Click to set one". In pinned mode its place is left empty.
- **Bar:** 6×24 px next to a 32 px icon (4×18 px in pinned mode), centered
  in the row so bars in adjacent rows don't blend together. Backing on top,
  fill from the bottom; fill height = stock / target (capped at 100% full).
  Fill color:
  - 0–90% — a smooth gradient from red (0%) through yellow (~45%) to
    near-green, in ~4.5% steps;
  - 90–110% — green ("on target");
  - above 110% — purple.
- The backing is dark in the regular window and light gray in pinned mode,
  so the unfilled part stays visible against the dark semi-transparent
  background.
- **Bar tooltip** (regular window only): "Stock: X / Y (Z%)".
- **Storage sources:**
  - logistic networks — `LuaLogisticNetwork.get_item_count({name, quality})`,
    storage and provider chests, specific quality (a planet's landing pad
    is part of the network);
  - space platform hubs (Space Age) — the `hub_main` inventory, together
    with cargo bays; only platforms of the player's own force. The hub's
    trash slot is not counted.
- **Network switch** in the title bar (roboport icon, pressed in "current"
  mode):
  - **"All logistic networks"** (default) — all of the force's networks
    (`force.logistic_networks`) on the window's surface or everywhere; plus
    the hub, if the surface is a platform; in "Everywhere" mode, all of the
    force's platform hubs;
  - **"Current logistic network"** — on a space platform, its hub;
    otherwise the network the player is physically in
    (`find_logistic_network_by_position(player.position, force)` on the
    player's surface; in remote view, the camera position). Outside any
    network, the bar is pale and empty, tooltip "Outside a logistic
    network".
- The bar is built from two custom solid-color sprites (there's no vertical
  progress bar in the API): backing and fill, with heights changing on
  each update.

### 2.10. Multiple windows

For keeping different item sets separate (science in one window, smelting
in another) or different surfaces in different windows.

- **New window** — "+" in the title bar. The window starts empty, appears
  offset 40 px from the original, and inherits its surface and network
  mode. Limited to 10 windows per player ("No more than 10 windows").
- **Close** — "×":
  - the last window is never deleted, only hidden along with the overlay
    (tooltip "Hide"; bring it back via the shortcut or hotkey);
  - an empty window is deleted immediately (tooltip "Close window");
  - a window with items asks for confirmation first: the button becomes
    pressed, tooltip "Click again to delete this window". Any other action
    in the window cancels the confirmation.
- The `CONTROL + ALT + O` pin hotkey affects all windows: if at least one
  non-empty window is unpinned, it pins all non-empty windows; otherwise it
  unpins all of them.
- **Performance:** changes in a window rebuild only that window; updates run
  across all windows with a shared cache (see 2.7).
- Element names: `production_overlay_root_<id>` (window) and
  `production_overlay_pin_<id>` (pinned window's pushpin+handle); every tag
  includes `window = <id>`.

---

## 3. State (`storage`)

```lua
storage = {
  version = 2,                     -- storage schema version
  players = {
    [player_index] = {
      enabled = true,              -- overlay (all windows) enabled
      disabled_by_error = false,   -- P3: emergency shutoff
      error_count = 0,
      next_window_id = 2,
      windows = {                  -- at least one window
        {
          id = 1,
          entries = {              -- order = row order
            {type = "item",  name = "iron-plate", quality = "normal", target = 1000},  -- target: stock target or nil
            {type = "fluid", name = "water"},
          },
          location = {x = 10, y = 260},
          collapsed = false,
          pinned = false,          -- pinned mode (2.8)
          surface_mode = "current",-- "current" | "all" | "fixed"
          surface_index = nil,     -- for "fixed"
          network_mode = "all",    -- stock sources: "all" | "current"
          pending = nil,           -- target editor: {entry, index (nil = adding), target}
          confirm_close = false,   -- waiting for a second "close" click
          gui = { ... },           -- GUI element references; always checked via .valid
        },
      },
    },
  },
}
```

- Key is `player.index`, not the player's name.
- The stock target is an integer from 1 to 2,147,483,647 (`int32`, same as
  network counters); 0 or empty means "don't track" (`nil`).
- Schema 1 (versions before 0.4.0: single window, fields directly on the
  player) is automatically migrated into window 1 on load.

---

## 4. Lifecycle and events

| Event | Action |
|---|---|
| `on_init` | Create `storage`, build windows for all players |
| `on_configuration_changed` | Remove state for players that no longer exist, migrate and validate data (missing prototypes, quality, removed surfaces), clear `disabled_by_error`, close editors and confirmations, rebuild all windows |
| `on_player_created` | Create state and windows for the player |
| `on_player_removed` | Remove the player's state |
| `on_player_display_resolution_changed`, `on_player_display_scale_changed` | Move windows back into the visible area |
| `on_gui_elem_changed` | Add, replace, remove rows |
| `on_gui_click` | Title bar buttons, arrows, bar click, target editor buttons, pinned window's pushpin |
| `on_gui_confirmed` | Enter in the stock target field |
| `on_gui_selection_state_changed` | Surface selection in the dropdown |
| `on_gui_location_changed` | Save window position; when dragging a pinned window's handle, move the overlay |
| `on_surface_created/deleted/renamed/imported` | Rebuild dropdowns, forget removed surfaces |
| `on_lua_shortcut`, `custom-input` `production-overlay-toggle` | Show / hide all windows |
| `custom-input` `production-overlay-pin` | Pin / unpin all windows |
| `on_nth_tick(60)` | Update numbers and bars (respecting the setting's interval) |

There is no `on_load` handler. The mod's own elements are identified via
`element.get_mod()` and `tags` (`{action = ..., window = <id>, index = ...}`),
not by parsing names.

---

## 5. Prototypes and settings

- `shortcut` `production-overlay-toggle`: `action = "lua"`,
  `toggleable = true`, linked to the hotkey. Icon: a custom bar chart
  (`graphics/shortcut-x56.png`, `shortcut-x24.png`).
- `custom-input` `production-overlay-toggle`: default `CONTROL + ALT + P`.
- `custom-input` `production-overlay-pin`: default `CONTROL + ALT + O`.
- Both hotkeys can be remapped by the player in the controls settings.
- `sprite` `production-overlay-bar-*` — solid-color 8×8 tiles for the stock
  bar (`graphics/bar/*.png`): `track`, `track-light`, `unset`, `over`,
  `0` … `20`.
- `sprite` `production-overlay-arrow-up/down` — white 32×32 chevrons,
  scale 0.5 (`graphics/arrow-*.png`).
- Map setting (runtime-global) `production-overlay-update-interval`: update
  interval in seconds, 1–60, default 1. The handler always runs on
  `on_nth_tick(60)` and skips extra seconds, so changing the setting doesn't
  require re-registering events.

All graphics are generated by scripts (simple solid-color shapes); there
are no third-party assets.

---

## 6. File structure

```
production-overlay/
  info.json
  changelog.txt
  SPEC.md                -- this file
  settings.lua           -- update interval setting
  data.lua               -- shortcut, hotkeys, sprites
  control.lua            -- event wiring, protective wrapper (P3)
  scripts/
    state.lua            -- storage: schema, defaults, migration, validation
    stats.lua            -- production statistics, network/hub stock, cache
    gui.lua               -- windows: build, update, handle own events
    format.lua            -- number formatting
  graphics/
    shortcut-x56.png, shortcut-x24.png
    arrow-up.png, arrow-down.png
    bar/*.png
  locale/
    en/production-overlay.cfg
    ru/production-overlay.cfg
```

---

## 7. Backlog

- A thumbnail for the mod portal.
- Picking items without "clutter": `item-with-quality` with filters (no
  hidden items, parameters, planners) plus a separate fluid slot. Currently
  decided against (see 2.3).
- Showing only researched items, like the logistic request window — only
  approximately possible, with a custom list.
- A setting for units (per second vs. per minute) and highlight thresholds.
- Multiple row columns for long lists.
- Port to 2.1: change `factorio_version` and run the test plan.

---

## 8. Test plan (manual)

Basics:
1. New game without Space Age: add, replace, remove an item and a fluid;
   numbers match the statistics window ("1 min" tab).
2. Existing save: enable the mod → load → window is there, no errors.
   Disable the mod → load → no leftover traces or errors.
3. A save from an older version (before 0.4.0) → the list moved into
   window 1.
4. Resolution and UI scale changes → windows aren't lost off-screen.
5. A cutscene (Space Age intro) → windows hide, then reappear.
6. The shortcut and `CONTROL + ALT + P` toggle the overlay in sync; window
   modes are preserved.

Rows and stock:
7. ↑↓ arrows reorder rows; the outer arrows are disabled at the ends.
8. Adding an item opens the target editor; Enter and "Save" save it,
   "Cancel" doesn't; 0 removes the bar; clicking the bar opens the editor.
9. Bar colors: < 90% — red to green, 90–110% — green, > 110% — purple.
10. Networks: "All" and "Current"; outside a network the bar is pale.
11. Space Age: a platform hub is counted (on the platform, in
    "Everywhere", in "Current" on the platform).

Surfaces and windows:
12. Dropdown: "Current" follows remote view; "Everywhere"; a specific
    surface; a removed surface falls back to "Current".
13. New window, 10-window limit, closing an empty window, confirmation for
    a non-empty one, the last window only hides.
14. Pinned mode: clicks pass through, the pushpin unpins, the handle drags,
    the surface name is shown; `CONTROL + ALT + O` pins and unpins all
    windows.

Quality and robustness:
15. Pin an item of a rare quality → disable the quality mod (or Space Age)
    → load → the row becomes `normal`, no errors.
16. Pin an item from a third-party mod → remove that mod → the row
    disappears, no errors.
17. Multiplayer, if possible: host and a second client, each with their own
    windows, no desyncs.

---

## 9. Development notes

- API docs matching the targeted game version ship inside the game's
  installation folder as `doc-html/runtime-api.json` and
  `prototype-api.json`.
- After editing Lua code, reloading the save is enough; after changing
  graphics, prototypes, settings, or locale files, the game needs to be
  restarted.
- Checks without launching the game: Lua syntax (`luaparse`), and
  loading/logic checks in an isolated game instance (its own `config.ini`
  with a separate data folder, `--create` / `--benchmark`) with a test mod
  that calls into the mod's functions. These headless runs don't catch UI
  issues — the interface is verified manually in-game.
- When something misbehaves in-game, check the `[production-overlay] error`
  lines in `factorio-current.log` first.
