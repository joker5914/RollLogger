-- RollLogger.lua (Turtle/Vanilla-safe, ASCII only)

local ADDON_NAME = "RollLogger"

-- helpers / config
local ROLLLOGGER_DEBUG = false
local function trim(s) return (string.gsub(s or "", "^%s*(.-)%s*$", "%1")) end
local function tlen(t) return table.getn(t or {}) end

-- frame & events
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("CHAT_MSG_SYSTEM")
f:RegisterEvent("CHAT_MSG_TEXT_EMOTE")
f:RegisterEvent("CHAT_MSG_EMOTE")

-- SavedVariables schema (for reference):
-- RollLoggerDB = {
--   entries = { { ts="YYYY-mm-dd HH:MM:SS", player="Name", result=57, min=1, max=100, idx=1 }, ... },
--   csvLines = { "timestamp,player,result,min,max,idx", ... },
--   sessionCount = 0,
--   totalCount   = 0,
--   localeFmt    = RANDOM_ROLL_RESULT,
--   csvInit = true,
--   stats = {
--     total1to100 = 0, ge50_1to100 = 0, gt50_1to100 = 0, lt50_1to100 = 0, eq50_1to100 = 0,
--     hist1to100 = { [1]=0, ... [100]=0 }, built = false
--   }
-- }

local function now()
  if type(date) == "function" then
    return date("%Y-%m-%d %H:%M:%S")
  end
  return tostring(GetTime()) -- fallback: seconds since UI load
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

  if type(RollLoggerDB.stats) ~= "table" then
    RollLoggerDB.stats = {
      total1to100 = 0,
      ge50_1to100 = 0,  -- >=50
      gt50_1to100 = 0,  -- >50
      lt50_1to100 = 0,  -- <50
      eq50_1to100 = 0,  -- ==50
      hist1to100  = {},
      built = false
    }
  end
  local i
  for i = 1, 100 do
    if not RollLoggerDB.stats.hist1to100[i] then
      RollLoggerDB.stats.hist1to100[i] = 0
    end
  end
end

-- pattern builder (from RANDOM_ROLL_RESULT), fully escaped
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
    else
      table.insert(parts, "(%d+)")
    end
    i = k + 1
  end
  rollParser = table.concat(parts)
end

local function isPlayerMe(name)
  name = trim(name)
  local me = UnitName("player")
  return name == me
end

local function appendCSV(ts, player, result, minv, maxv, idx)
  local function q(s)
    s = tostring(s or "")
    if string.find(s, "[\",]") then
      s = "\"" .. string.gsub(s, "\"", "\"\"") .. "\""
    end
    return s
  end
  local line = table.concat({ q(ts), q(player), q(result), q(minv), q(maxv), q(idx) }, ",")
  table.insert(RollLoggerDB.csvLines, line)
end

-- rebuild stats from entries (used on login/reset)
local function rebuildStats()
  ensureDB()
  local s = RollLoggerDB.stats
  s.total1to100, s.ge50_1to100, s.gt50_1to100, s.lt50_1to100, s.eq50_1to100 = 0, 0, 0, 0, 0
  local i
  for i = 1, 100 do s.hist1to100[i] = 0 end

  local entries = RollLoggerDB.entries or {}
  local n = tlen(entries)
  for i = 1, n do
    local r = entries[i]
    if r and r.min == 1 and r.max == 100 and r.result then
      local v = r.result
      s.total1to100 = s.total1to100 + 1
      if v >= 50 then s.ge50_1to100 = s.ge50_1to100 + 1 end
      if v >  50 then s.gt50_1to100 = s.gt50_1to100 + 1 end
      if v <  50 then s.lt50_1to100 = s.lt50_1to100 + 1 end
      if v == 50 then s.eq50_1to100 = s.eq50_1to100 + 1 end
      if v >= 1 and v <= 100 then s.hist1to100[v] = (s.hist1to100[v] or 0) + 1 end
    end
  end
  s.built = true
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

  -- live stats update (1-100 only)
  if row.min == 1 and row.max == 100 and row.result then
    local s = RollLoggerDB.stats
    local v = row.result
    s.total1to100 = s.total1to100 + 1
    if v >= 50 then s.ge50_1to100 = s.ge50_1to100 + 1 end
    if v >  50 then s.gt50_1to100 = s.gt50_1to100 + 1 end
    if v <  50 then s.lt50_1to100 = s.lt50_1to100 + 1 end
    if v == 50 then s.eq50_1to100 = s.eq50_1to100 + 1 end
    if v >= 1 and v <= 100 then
      s.hist1to100[v] = (s.hist1to100[v] or 0) + 1
    end
  end

  if ROLLLOGGER_DEBUG then
    DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00FF7F[RollLogger]|r +REC %s %d (%d-%d) idx=%d",
      player, row.result or -1, row.min or -1, row.max or -1, row.idx))
  end
end

-- Slash command: /rolllog, /rolllog stats, /rolllog ord [N], /rolllog export, /rolllog reset, /rolllog debug
SLASH_ROLLLOGGER1 = "/rolllog"
SlashCmdList["ROLLLOGGER"] = function(msg)
  ensureDB()
  if type(msg) ~= "string" then msg = "" end
  msg = trim(string.lower(msg))

  -- help / default
  if msg == "" or msg == "help" then
    DEFAULT_CHAT_FRAME:AddMessage("|cff00FF7F[RollLogger]|r Commands: /rolllog stats   /rolllog ord [N]   /rolllog export   /rolllog reset   /rolllog debug")
    return
  end

  -- stats: show >=50 vs <50, plus =50 and strict >50; quick histogram buckets
  if msg == "stats" then
    if not RollLoggerDB.stats or not RollLoggerDB.stats.built then rebuildStats() end
    local s   = RollLoggerDB.stats
    local n   = s.total1to100
    local ge  = s.ge50_1to100
    local lt  = s.lt50_1to100
    local eq  = s.eq50_1to100
    local gt  = s.gt50_1to100
    local function pct(x) if n > 0 then return (x * 100.0 / n) else return 0 end end

    DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00FF7F[RollLogger]|r 1-100 rolls: %d", n))
    DEFAULT_CHAT_FRAME:AddMessage(string.format("  >=50: %d (%0.1f%%)   <50: %d (%0.1f%%)", ge, pct(ge), lt, pct(lt)))
    DEFAULT_CHAT_FRAME:AddMessage(string.format("  =50 : %d (%0.1f%%)   >50: %d (%0.1f%%)",  eq, pct(eq), gt, pct(gt)))

    -- deciles (10-wide buckets)
    local d
    for d = 0, 9 do
      local lo, hi = d * 10 + 1, d * 10 + 10
      local c, i = 0, lo
      for i = lo, hi do c = c + (s.hist1to100[i] or 0) end
      DEFAULT_CHAT_FRAME:AddMessage(string.format("  %2d-%3d: %d", lo, hi, c))
    end
    return
  end

  -- ordinal analysis: /rolllog ord [N]  (default N=10, range 2..30)
  if string.sub(msg, 1, 3) == "ord" then
    local rawN = trim(string.sub(msg, 4))
    local N = tonumber(rawN) or 10
    if N < 2 then N = 2 end
    if N > 30 then N = 30 end

    local entries = RollLoggerDB.entries or {}
    local n = tlen(entries)
    local posCounts, posGT = {}, {}
    local i
    for i = 1, N do posCounts[i] = 0; posGT[i] = 0 end

    local idx = 0
    for i = 1, n do
      local r = entries[i]
      if r and r.min == 1 and r.max == 100 and r.result then
        idx = idx + 1
        local pos = ((idx - 1) % N) + 1
        posCounts[pos] = posCounts[pos] + 1
        if r.result > 50 then posGT[pos] = posGT[pos] + 1 end
      end
    end

    DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00FF7F[RollLogger]|r Ordinal >50 rates (block=%d)", N))
    for i = 1, N do
      if posCounts[i] > 0 then
        local p = posGT[i] * 100.0 / posCounts[i]
        DEFAULT_CHAT_FRAME:AddMessage(string.format("  %2d: %d/%d = %0.1f%%", i, posGT[i], posCounts[i], p))
      else
        DEFAULT_CHAT_FRAME:AddMessage(string.format("  %2d: --", i))
      end
    end
    return
  end

  -- export to SavedVariables CSV buffer (flush to disk on /reload/logout)
  if msg == "export" then
    RollLoggerDB.csvLines = { "timestamp,player,result,min,max,idx" }
    local entries = RollLoggerDB.entries or {}
    local i
    for i = 1, tlen(entries) do
      local r = entries[i]
      if r then appendCSV(r.ts, r.player, r.result, r.min, r.max, r.idx) end
    end
    DEFAULT_CHAT_FRAME:AddMessage("|cff00FF7F[RollLogger]|r CSV buffer rebuilt. It will be written on /reload or logout.")
    return
  end

  -- reset data & stats
  if msg == "reset" then
    RollLoggerDB.entries      = {}
    RollLoggerDB.csvLines     = { "timestamp,player,result,min,max,idx" }
    RollLoggerDB.sessionCount = 0
    RollLoggerDB.totalCount   = 0
    RollLoggerDB.stats        = { total1to100 = 0, ge50_1to100 = 0, gt50_1to100 = 0, lt50_1to100 = 0, eq50_1to100 = 0, hist1to100 = {}, built = true }
    local i
    for i = 1, 100 do RollLoggerDB.stats.hist1to100[i] = 0 end
    DEFAULT_CHAT_FRAME:AddMessage("|cff00FF7F[RollLogger]|r Data cleared.")
    return
  end

  -- toggle debug
  if msg == "debug" then
    ROLLLOGGER_DEBUG = not ROLLLOGGER_DEBUG
    DEFAULT_CHAT_FRAME:AddMessage("|cff00FF7F[RollLogger]|r Debug: " .. (ROLLLOGGER_DEBUG and "ON" or "OFF"))
    return
  end

  DEFAULT_CHAT_FRAME:AddMessage("|cff00FF7F[RollLogger]|r Unknown command. Try /rolllog stats or /rolllog ord 10")
end

-- Classic 1.12 handler: use global event/arg1
f:SetScript("OnEvent", function()
  if event == "ADDON_LOADED" then
    if arg1 == ADDON_NAME then
      ensureDB()
      buildRollParser()
    end
    return
  end

  if event == "PLAYER_LOGIN" then
    ensureDB()
    if not rollParser then buildRollParser() end
    rebuildStats() -- build from any prior entries
    return
  end

  if event == "CHAT_MSG_SYSTEM" or event == "CHAT_MSG_TEXT_EMOTE" or event == "CHAT_MSG_EMOTE" then
    if not rollParser then buildRollParser() end
    local msg = arg1 or ""

    if ROLLLOGGER_DEBUG then
      DEFAULT_CHAT_FRAME:AddMessage("|cff00FF7F[RollLogger]|r EV=" .. tostring(event) .. " MSG=" .. msg)
    end

    -- English pattern first: "Name rolls 57 (1-100)"
    local _, _, p2, r2, mn2, mx2 = string.find(msg, "^(.+) rolls (%d+) %((%d+)%-(%d+)%)$")
    if p2 and r2 and mn2 and mx2 then
      recordRoll(trim(p2), r2, mn2, mx2)
      if ROLLLOGGER_DEBUG then
        DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00FF7F[RollLogger]|r parsed EN: %s %s (%s-%s)", p2, r2, mn2, mx2))
      end
      return
    end

    -- Localized fallback built from RANDOM_ROLL_RESULT
    local _, _, p, r, mn, mx = string.find(msg, rollParser or "")
    if p and r and mn and mx then
      recordRoll(trim(p), r, mn, mx)
      if ROLLLOGGER_DEBUG then
        DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00FF7F[RollLogger]|r parsed LOC: %s %s (%s-%s)", p, r, mn, mx))
      end
      return
    end

    if ROLLLOGGER_DEBUG then
      DEFAULT_CHAT_FRAME:AddMessage("|cff00FF7F[RollLogger]|r no match")
    end
  end
end)
