-- Reads production statistics (average over the last minute, per minute).
-- `cache` lives for a single update pass, so players of one force share the reads.

local state = require("scripts.state")

local stats = {}

local ONE_MINUTE = defines.flow_precision_index.one_minute

local function flow_for(cache, force, surface, entry_type)
  local key = "flow|" .. force.index .. "|" .. surface.index .. "|" .. entry_type
  local flow = cache[key]
  if not flow then
    if entry_type == "fluid" then
      flow = force.get_fluid_production_statistics(surface)
    else
      flow = force.get_item_production_statistics(surface)
    end
    cache[key] = flow
  end
  return flow
end

local function read_surface(cache, force, surface, entry)
  local flow = flow_for(cache, force, surface, entry.type)
  local id = entry.name
  if entry.type == "item" then
    id = {name = entry.name, quality = entry.quality or "normal"}
  end
  local produced = flow.get_flow_count{name = id, category = "input", precision_index = ONE_MINUTE}
  local consumed = flow.get_flow_count{name = id, category = "output", precision_index = ONE_MINUTE}
  return produced, consumed
end

--- Returns produced, consumed per minute for the entry.
--- surface_mode "all" sums over every surface, otherwise only `surface` is read.
function stats.get(cache, force, surface_mode, surface, entry)
  local scope = surface_mode == "all" and "all" or surface.index
  local key = "value|" .. force.index .. "|" .. scope .. "|" .. state.key(entry)
  local cached = cache[key]
  if cached then
    return cached[1], cached[2]
  end

  local produced, consumed = 0, 0
  if surface_mode == "all" then
    for _, s in pairs(game.surfaces) do
      local p, c = read_surface(cache, force, s, entry)
      produced = produced + p
      consumed = consumed + c
    end
  else
    produced, consumed = read_surface(cache, force, surface, entry)
  end

  cache[key] = {produced, consumed}
  return produced, consumed
end

--- Item count in a space platform hub (its main inventory, cargo bays included); 0 if there is no hub.
local function hub_count(platform, id)
  if not (platform and platform.valid) then return 0 end
  local hub = platform.hub
  if not (hub and hub.valid) then return 0 end
  local inventory = hub.get_inventory(defines.inventory.hub_main)
  return inventory and inventory.get_item_count(id) or 0
end

--- The surface's space platform if it belongs to `force`, otherwise nil.
function stats.own_platform(surface, force)
  local platform = surface.platform
  if platform and platform.valid and platform.force.index == force.index then
    return platform
  end
  return nil
end

--- Item count stored in the force's logistic networks (storage + providers) and space platform hubs,
--- on the surface or everywhere.
function stats.stock(cache, force, surface_mode, surface, entry)
  local scope = surface_mode == "all" and "all" or surface.index
  local key = "stock|" .. force.index .. "|" .. scope .. "|" .. state.key(entry)
  local cached = cache[key]
  if cached then
    return cached
  end

  -- Grouped by surface name; reading it builds a fresh table, so do it once per force per update.
  local networks_key = "networks|" .. force.index
  local by_surface = cache[networks_key]
  if not by_surface then
    by_surface = force.logistic_networks
    cache[networks_key] = by_surface
  end

  local id = {name = entry.name, quality = entry.quality or "normal"}
  local total = 0
  local function count(networks)
    for _, network in pairs(networks) do
      if network.valid then
        total = total + network.get_item_count(id)
      end
    end
  end
  if surface_mode == "all" then
    for _, networks in pairs(by_surface) do
      count(networks)
    end
    local platforms_key = "platforms|" .. force.index
    local platforms = cache[platforms_key]
    if not platforms then
      platforms = force.platforms
      cache[platforms_key] = platforms
    end
    for _, platform in pairs(platforms) do
      total = total + hub_count(platform, id)
    end
  else
    if by_surface[surface.name] then
      count(by_surface[surface.name])
    end
    total = total + hub_count(stats.own_platform(surface, force), id)
  end

  cache[key] = total
  return total
end

--- Item count in a single storage: a logistic network or a space platform (its hub).
function stats.network_stock(cache, network, entry)
  local is_platform = network.object_name == "LuaSpacePlatform"
  local source = is_platform and ("platform" .. network.index) or ("network" .. network.network_id)
  local key = "netstock|" .. source .. "|" .. state.key(entry)
  local cached = cache[key]
  if cached then
    return cached
  end
  local id = {name = entry.name, quality = entry.quality or "normal"}
  local total = is_platform and hub_count(network, id) or network.get_item_count(id)
  cache[key] = total
  return total
end

return stats
