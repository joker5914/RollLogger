-- RollLogger.lua (Turtle/Vanilla-safe)

local ADDON_NAME = "RollLogger"

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("CHAT_MSG_SYSTEM")

-- SavedVariables schema:
-- RollLoggerDB = {
--   entries = { { ts="2025-09-22 12:34:56", player="Name", result=57, min=1, max=100, idx=1 }, ... },
--   csvLines = { "timestamp,player,result,min,max,idx", ... },
--   sessionCount = 0,
--   totalCount   = 0,
--   localeFmt    = RANDOM_ROLL_RESULT,
--   csvInit = true
-- }

local function tlen(t) return table.getn(t or {}) end

local function now()
  -- WoW exposes date() in 1.12; fall back if not.
  if type(date) == "function" then
    return date("%Y-%m-%d %H:%M:%S")
  end
  return tostring(GetTime()) -- seconds since UI load
end

local function ensureDB()
  if type(RollLoggerDB) ~= "table" then RollLoggerDB = {} end
  if type(RollLoggerDB.entries) ~= "table" then RollLoggerDB.entries = {} end
  if type(RollLoggerDB.csvLines) ~= "table" then RollLoggerDB.csvLines = {} end
  if not RollLoggerDB.csvInit then
    RollLoggerDB.csvLines[1] = "timestamp,player,result,min,max,idx"
    RollLoggerDB.csvInit = true
  end
  if not RollLoggerDB.sessionCount then RollLoggerDB.sessionCount = 0 end
  if not RollLoggerDB.totalCount   then RollLoggerDB.totalCount   = 0 end
  if not RollLoggerDB.localeFmt    then RollLoggerDB.localeFmt    = RANDOM_ROLL_RESULT or "%s rolls %d (%d-%d)" end
end

-- Build a Lua pattern from RANDOM_ROLL_RESULT safely (escape all magic chars except placeholders).
local rollParser

local function escape_magic(s)
  return (string.gsub(s, "([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

local function buildRollParser()
  local fmt = RANDOM_ROLL_RESULT or "%s rolls %d (%d-%d)"
  local parts = {}
  local i = 1
  while true do
    local j, k, spec = string.find(fmt, "%%([sd])", i)
    if not j then
      table.insert(parts, escape_magic(string.sub(fmt, i)))
      break
    end
    table.insert(parts, escape_magic(string.sub(fmt, i, j - 1)))
    if spec == "s" then
      table.insert(parts, "(.+)")
    else -- 'd'
      table.insert(parts, "(%d+)")
    end
    i = k + 1
  end
  rollParser = table.concat(parts)
end

local function isPlayerMe(name)
  local me = UnitName("player")
  return name == me
end

local function appendCSV(ts, player, result, minv, maxv, idx)
  local function q(s)
    s = tostring(s or "")
    if string.find(s, '[",]') then
      s = '"' .. string.gsub(s, '"', '""') .. '"'
    end
    return s
  end
  local line = table.concat({ q(ts), q(player), q(result), q(minv), q(maxv), q(idx) }, ",")
  table.insert(RollLoggerDB.csvLines, line)
end

local function recordRoll(player, result, minv, maxv)
  ensureDB()
  if not isPlayerMe(player) then return end

  RollLoggerDB.sessionCount = RollLoggerDB.sessionCount + 1
  RollLoggerDB.totalCount   = RollLoggerDB.totalCount + 1

  local row = {
    ts     = now(),
    player = player,
    result = tonumber(result),
    min    = tonumber(minv),
    max    = tonumber(maxv),
    idx    = RollLoggerDB.totalCount
  }
  table.insert(RollLoggerDB.entries, row)
  appendCSV(row.ts, row.player, row.result, row.min, row.max, row.idx)
end

-- Slash command: /rolllog, /rolllog stats, /rolllog export, /rolllog reset
SLASH_ROLLLOGGER1 = "/rolllog"
SlashCmdList["ROLLLOGGER"] = function(msg)
  ensureDB()
  if type(msg) ~= "string" then msg = "" end
  msg = string.lower(msg)

  if msg == "" or msg == "stats" then
    local entries = RollLoggerDB.entries
    local n = tlen(entries)
    local gt50 = 0
    local i
    for i = 1, n do
      local r = entries[i]
      if r and r.min == 1 and r.max == 100 and r.result and r.result > 50 then
        gt50 = gt50 + 1
      end
    end
    DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00FF7F[RollLogger]|r Recorded rolls: %d  (1-100 and >50: %d)", n, gt50))
    DEFAULT_CHAT_FRAME:AddMessage("|cff00FF7F[RollLogger]|r /rolllog export  - rebuild CSV buffer")
    DEFAULT_CHAT_FRAME:AddMessage("|cff00FF7F[RollLogger]|r /rolllog reset   - clear data")
    return

  elseif msg == "reset" then
    RollLoggerDB.entries      = {}
    RollLoggerDB.csvLines     = { "timestamp,player,result,min,max,idx" }
    RollLoggerDB.sessionCount = 0
    DEFAULT_CHAT_FRAME:AddMessage("|cff00FF7F[RollLogger]|r Data cleared.")
    return

  elseif msg == "export" then
    RollLoggerDB.csvLines = { "timestamp,player,result,min,max,idx" }
    local entries = RollLoggerDB.entries
    local n = tlen(entries)
    local i
    for i = 1, n do
      local r = entries[i]
      if r then appendCSV(r.ts, r.player, r.result, r.min, r.max, r.idx) end
    end
    DEFAULT_CHAT_FRAME:AddMessage("|cff00FF7F[RollLogger]|r CSV buffer rebuilt. It will be written on /reload/logout.")
    return
  end

  DEFAULT_CHAT_FRAME:AddMessage("|cff00FF7F[RollLogger]|r Commands: /rolllog, /rolllog stats, /rolllog export, /rolllog reset")
end

-- Event handler (no colon-string methods; use string.find and globals-only arg1 fallback)
f:SetScript("OnEvent", function(_, event, a1)
  if event == "ADDON_LOADED" then
    if a1 == ADDON_NAME then
      ensureDB()
      buildRollParser()
    end
    return
  end

  if event == "PLAYER_LOGIN" then
    ensureDB()
    if not rollParser then buildRollParser() end
    return
  end

  if event == "CHAT_MSG_SYSTEM" then
    if not rollParser then buildRollParser() end
    local msg = a1 or _G.arg1 or ""
    -- Localized pattern first
    local _, _, p, r, mn, mx = string.find(msg, rollParser)
    if p and r and mn and mx then
      recordRoll(p, r, mn, mx)
      return
    end
    -- English fallback
    local _, _, p2, r2, mn2, mx2 = string.find(msg, "^(.+) rolls (%d+) %((%d+)%-(%d+)%)$")
    if p2 and r2 and mn2 and mx2 then
      recordRoll(p2, r2, mn2, mx2)
      return
    end
  end
end)
