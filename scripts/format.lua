-- Compact number formatting for the overlay: 3.4, 512, 1.2k, 12k, 1.2M.

local format = {}

local function magnitude(a)
  if a < 10 then return string.format("%.1f", a) end
  if a < 1000 then return string.format("%d", math.floor(a + 0.5)) end
  if a < 1e4 then return string.format("%.1fk", a / 1e3) end
  if a < 1e6 then return string.format("%dk", math.floor(a / 1e3 + 0.5)) end
  if a < 1e7 then return string.format("%.1fM", a / 1e6) end
  return string.format("%dM", math.floor(a / 1e6 + 0.5))
end

--- Values this small are shown as "0".
format.ZERO = 0.05

function format.number(value)
  local a = math.abs(value)
  if a < format.ZERO then return "0" end
  return magnitude(a)
end

function format.signed(value)
  local a = math.abs(value)
  if a < format.ZERO then return "0" end
  return (value < 0 and "-" or "+") .. magnitude(a)
end

return format
