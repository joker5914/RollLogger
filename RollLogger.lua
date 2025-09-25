-- RollLogger.lua (Turtle/Vanilla-safe, gambling sim included)

local ADDON_NAME = "RollLogger"

-- helpers / config
local ROLLLOGGER_DEBUG = false
local function trim(s) return (string.gsub(s or "", "^%s*(.-)%s*$", "%1")) end
local function tlen(t) return table.getn(t or {}) end
local function imod(a, b) if math.mod then return math.mod(a, b) else return math.fmod(a, b) end end

-- money parsing/formatting (ASCII only)
local function parseMoneyToCopper(str)
  if type(str) ~= "string" then return nil end
  local s = trim(string.lower(str))
  if s == "" then return nil end
  local total = 0
  local pos = 1
  local any = false
  while true do
    local a, b, num, unit = string.find(s, "(%d+)%s*([gsc])", pos)
    if not a then break end
    num = tonumber(num)
    if unit == "g" then total = total + num * 10000
    elseif unit == "s" then total = total + num * 100
    else total = total + num end
    pos = b + 1
    any = true
  end
  if not any then
    -- bare number -> treat as silver for convenience
    local n = tonumber(s)
    if n then total = n * 100; any = true end
  end
  if any then return total else return nil end
end

local function imod(a, b)
  if math.mod then return math.mod(a, b) end
  return math.fmod(a, b)
end

local function fmtCopper(c)
  local sign = ""
  if c < 0 then sign = "-"; c = -c end
  local g = math.floor(c / 10000)
  local s = math.floor(imod(c, 10000) / 100)
  local k = imod(c, 100)
  local out = {}
  if g > 0 then table.insert(out, tostring(g).."g") end
  if s > 0 then table.insert(out, tostring(s).."s") end
  if k > 0 or (g == 0 and s == 0) then table.insert(out, tostring(k).."c") end
  return sign .. table.concat(out, " ")
end

-- frame & events
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("CHAT_MSG_SYSTEM")
f:RegisterEvent("CHAT_MSG_TEXT_EMOTE")
f:RegisterEvent("CHAT_MSG_EMOTE")

-- SavedVariables schema (for reference)
-- RollLoggerDB = {
--   entries = { { ts="YYYY-mm-dd HH:MM:SS", player="Name", result=57, min=1, max=100, idx=1,
--                 stake_copper=..., won=true/false, delta_copper=..., bankroll_copper_after=... }, ... },
--   csvLines = { "timestamp,player,result,min,max,idx", ... },
--   sessionCount = 0,
--   totalCount   = 0,
--   localeFmt    = RANDOM_ROLL_RESULT,
--   csvInit = true,
--   stats = { total1to100=0, ge50_1to100=0, gt50_1to100=0, lt50_1to100=0, eq50_1to100=0, hist1to100={}, built=false },
--   sim = {
--     enabled=false, stake_copper=100, bankroll_copper=0, total_staked=0, total_profit=0,
--     wins=0, losses=0, eq50=0, current_streak_len=0, current_streak_sign=0,
--     max_win_streak=0, max_loss_streak=0, peak_bankroll=0, max_drawdown=0
--   }
-- }

local function now()
  if type(date) == "function" then
    return date("%Y-%m-%d %H:%M:%S")
  end
  return tostring(GetTime())
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
      total1to100 = 0, ge50_1to100 = 0, gt50_1to100 = 0, lt50_1to100 = 0, eq50_1to100 = 0,
      hist1to100 = {}, built = false
    }
  end
  local i
  for i = 1, 100 do
    if not RollLoggerDB.stats.hist1to100[i] then RollLoggerDB.stats.hist1to100[i] = 0 end
  end

  if type(RollLoggerDB.sim) ~= "table" then
    RollLoggerDB.sim = {
      enabled = false,
      stake_copper = 100,   -- default 1s
      bankroll_copper = 0,
      total_staked = 0,
      total_profit = 0,
      wins = 0, losses = 0, eq50 = 0,
      current_streak_len = 0, current_streak_sign = 0, -- 1 win, -1 loss
      max_win_streak = 0, max_loss_streak = 0,
      peak_bankroll = 0, max_drawdown = 0
    }
  end
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
    if spec == "s" then table.insert(parts, "(.+)")
    else table.insert(parts, "(%d+)") end
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

-- gambling sim updater
local function updateSimForRoll(row)
  local sim = RollLoggerDB.sim
  if not sim.enabled then return end
  if not (row.min == 1 and row.max == 100 and row.result) then return end

  local win = (row.result > 50)
  local stake = sim.stake_copper or 0
  local delta = win and stake or -stake

  sim.total_staked = sim.total_staked + stake
  sim.total_profit = sim.total_profit + delta
  sim.bankroll_copper = (sim.bankroll_copper or 0) + delta

  -- streaks
  if row.result == 50 then
    sim.eq50 = sim.eq50 + 1
    -- treat 50 as loss by rule; keep loss streak logic
  end

  if win then
    sim.wins = sim.wins + 1
    if sim.current_streak_sign == 1 then
      sim.current_streak_len = sim.current_streak_len + 1
    else
      sim.current_streak_sign = 1
      sim.current_streak_len = 1
    end
    if sim.current_streak_len > sim.max_win_streak then sim.max_win_streak = sim.current_streak_len end
  else
    sim.losses = sim.losses + 1
    if sim.current_streak_sign == -1 then
      sim.current_streak_len = sim.current_streak_len + 1
    else
      sim.current_streak_sign = -1
      sim.current_streak_len = 1
    end
    if sim.current_streak_len > sim.max_loss_streak then sim.max_loss_streak = sim.current_streak_len end
  end

  -- drawdown tracking
  if sim.bankroll_copper > (sim.peak_bankroll or 0) then
    sim.peak_bankroll = sim.bankroll_copper
  end
  local dd = (sim.peak_bankroll or 0) - (sim.bankroll_copper or 0)
  if dd > (sim.max_drawdown or 0) then sim.max_drawdown = dd end

  -- enrich row (so CSV/SV mirrors what happened)
  row.stake_copper = stake
  row.won = win
  row.delta_copper = delta
  row.bankroll_copper_after = sim.bankroll_copper
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
    if v >= 1 and v <= 100 then s.hist1to100[v] = (s.hist1to100[v] or 0) + 1 end
  end

  -- gambling sim
  updateSimForRoll(row)

  if ROLLLOGGER_DEBUG then
    DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00FF7F[RollLogger]|r +REC %s %d (%d-%d) idx=%d",
      player, row.result or -1, row.min or -1, row.max or -1, row.idx))
  end
end

-- probability you end up with more wins than losses after N fair bets
local function probUpAfterN(N)
  if N <= 0 then return 0 end
  if (imod(N, 2) ~= 0) then return 0.5 end -- odd N -> exactly 0.5
  -- even N: P(up) = (1 - tie)/2, tie = C(N, N/2) / 2^N
  local half = N / 2
  local sumlog = 0.0
  local k
  for k = 1, half do
    sumlog = sumlog + math.log(half + k) - math.log(k)
  end
  local tie = math.exp(sumlog - N * math.log(2))
  local pup = 0.5 * (1 - tie)
  if pup < 0 then pup = 0 end
  if pup > 1 then pup = 1 end
  return pup
end

-- help text
local function RollLogger_PrintHelp()
  DEFAULT_CHAT_FRAME:AddMessage("|cff00FF7F[RollLogger]|r Commands:")
  DEFAULT_CHAT_FRAME:AddMessage("  /rolllog help                 - show this help")
  DEFAULT_CHAT_FRAME:AddMessage("  /rolllog stats                - totals and >=50/<50 split (+ =50 and >50)")
  DEFAULT_CHAT_FRAME:AddMessage("  /rolllog ord [N]              - ordinal >50 by position in blocks of N (default 10, 2..30)")
  DEFAULT_CHAT_FRAME:AddMessage("  /rolllog bet <amt>            - set stake (e.g. 1g, 75s, 12s50c, 250c)")
  DEFAULT_CHAT_FRAME:AddMessage("  /rolllog bankroll <amt>       - set simulated bankroll")
  DEFAULT_CHAT_FRAME:AddMessage("  /rolllog sim on|off           - toggle simulated betting on your 1-100 rolls")
  DEFAULT_CHAT_FRAME:AddMessage("  /rolllog gamble               - show bankroll, ROI, wins/losses, streaks, drawdown")
  DEFAULT_CHAT_FRAME:AddMessage("  /rolllog probup <N>           - P(up) after N fair bets")
  DEFAULT_CHAT_FRAME:AddMessage("  /rolllog export               - rebuild CSV buffer (write on /reload/logout)")
  DEFAULT_CHAT_FRAME:AddMessage("  /rolllog reset                - clear all data")
  DEFAULT_CHAT_FRAME:AddMessage("  /rolllog debug                - toggle debug messages")
end

-- Slash command handler
SLASH_ROLLLOGGER1 = "/rolllog"
SlashCmdList["ROLLLOGGER"] = function(msg)
  ensureDB()
  if type(msg) ~= "string" then msg = "" end
  msg = trim(string.lower(msg))

  if msg == "" or msg == "help" or msg == "commands" or msg == "?" then
    RollLogger_PrintHelp(); return
  end

  -- stats
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

    local d
    for d = 0, 9 do
      local lo, hi = d * 10 + 1, d * 10 + 10
      local c, i = 0, lo
      for i = lo, hi do c = c + (s.hist1to100[i] or 0) end
      DEFAULT_CHAT_FRAME:AddMessage(string.format("  %2d-%3d: %d", lo, hi, c))
    end
    return
  end

  -- ordinal
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
        local pos = imod(idx - 1, N) + 1
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

  -- bet <amount>
  if string.sub(msg, 1, 3) == "bet" then
    local amt = trim(string.sub(msg, 4))
    local c = parseMoneyToCopper(amt)
    if not c or c <= 0 then
      DEFAULT_CHAT_FRAME:AddMessage("|cff00FF7F[RollLogger]|r Usage: /rolllog bet <amount>   e.g. 1g, 75s, 12s50c, 250c")
      return
    end
    RollLoggerDB.sim.stake_copper = c
    DEFAULT_CHAT_FRAME:AddMessage("|cff00FF7F[RollLogger]|r Stake set to "..fmtCopper(c))
    return
  end

  -- bankroll <amount>
  if string.sub(msg, 1, 8) == "bankroll" then
    local amt = trim(string.sub(msg, 9))
    local c = parseMoneyToCopper(amt)
    if c == nil then
      DEFAULT_CHAT_FRAME:AddMessage("|cff00FF7F[RollLogger]|r Usage: /rolllog bankroll <amount>   e.g. 5g, 75s, 1200c")
      return
    end
    local sim = RollLoggerDB.sim
    sim.bankroll_copper = c
    sim.peak_bankroll = c
    sim.max_drawdown = 0
    DEFAULT_CHAT_FRAME:AddMessage("|cff00FF7F[RollLogger]|r Bankroll set to "..fmtCopper(c))
    return
  end

  -- sim on|off
  if string.sub(msg, 1, 3) == "sim" then
    local arg = trim(string.sub(msg, 4))
    if arg == "on" or arg == "1" or arg == "true" then
      RollLoggerDB.sim.enabled = true
      DEFAULT_CHAT_FRAME:AddMessage("|cff00FF7F[RollLogger]|r Simulated betting: ON")
    elseif arg == "off" or arg == "0" or arg == "false" then
      RollLoggerDB.sim.enabled = false
      DEFAULT_CHAT_FRAME:AddMessage("|cff00FF7F[RollLogger]|r Simulated betting: OFF")
    else
      DEFAULT_CHAT_FRAME:AddMessage("|cff00FF7F[RollLogger]|r Usage: /rolllog sim on|off")
    end
    return
  end

  -- gamble summary
  if msg == "gamble" then
    local sim = RollLoggerDB.sim
    local st = sim.stake_copper or 0
    local nBets = sim.wins + sim.losses
    local roi = 0
    if sim.total_staked > 0 then
      roi = sim.total_profit * 100.0 / sim.total_staked
    end
    DEFAULT_CHAT_FRAME:AddMessage("|cff00FF7F[RollLogger]|r Gambling summary:")
    DEFAULT_CHAT_FRAME:AddMessage("  Sim: "..(sim.enabled and "ON" or "OFF").."   Stake: "..fmtCopper(st).."   Bankroll: "..fmtCopper(sim.bankroll_copper or 0))
    DEFAULT_CHAT_FRAME:AddMessage("  Bets: "..nBets.."   Wins: "..sim.wins.."   Losses: "..sim.losses.."   =50: "..sim.eq50)
    DEFAULT_CHAT_FRAME:AddMessage(string.format("  Staked: %s   Profit: %s   ROI: %0.1f%%", fmtCopper(sim.total_staked), fmtCopper(sim.total_profit), roi))
    DEFAULT_CHAT_FRAME:AddMessage("  Streaks (cur/max): "..(sim.current_streak_sign==1 and "W" or (sim.current_streak_sign==-1 and "L" or "-"))..sim.current_streak_len..
                                  " / W"..sim.max_win_streak.." L"..sim.max_loss_streak)
    DEFAULT_CHAT_FRAME:AddMessage("  Max drawdown: "..fmtCopper(sim.max_drawdown).."   Peak: "..fmtCopper(sim.peak_bankroll or 0))
    return
  end

  -- probup <N>
  if string.sub(msg, 1, 6) == "probup" then
    local rawN = trim(string.sub(msg, 7))
    local N = tonumber(rawN or "")
    if not N or N < 1 then
      DEFAULT_CHAT_FRAME:AddMessage("|cff00FF7F[RollLogger]|r Usage: /rolllog probup <N>")
      return
    end
    local p = probUpAfterN(N) * 100.0
    DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00FF7F[RollLogger]|r P(up after %d fair bets) = %0.2f%%", N, p))
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

  -- reset everything
  if msg == "reset" then
    RollLoggerDB.entries      = {}
    RollLoggerDB.csvLines     = { "timestamp,player,result,min,max,idx" }
    RollLoggerDB.sessionCount = 0
    RollLoggerDB.totalCount   = 0
    RollLoggerDB.stats        = { total1to100 = 0, ge50_1to100 = 0, gt50_1to100 = 0, lt50_1to100 = 0, eq50_1to100 = 0, hist1to100 = {}, built = true }
    local i
    for i = 1, 100 do RollLoggerDB.stats.hist1to100[i] = 0 end
    RollLoggerDB.sim = {
      enabled = false, stake_copper = 100, bankroll_copper = 0, total_staked = 0, total_profit = 0,
      wins = 0, losses = 0, eq50 = 0, current_streak_len = 0, current_streak_sign = 0,
      max_win_streak = 0, max_loss_streak = 0, peak_bankroll = 0, max_drawdown = 0
    }
    DEFAULT_CHAT_FRAME:AddMessage("|cff00FF7F[RollLogger]|r Data cleared.")
    return
  end

  -- toggle debug
  if msg == "debug" then
    ROLLLOGGER_DEBUG = not ROLLLOGGER_DEBUG
    DEFAULT_CHAT_FRAME:AddMessage("|cff00FF7F[RollLogger]|r Debug: "..(ROLLLOGGER_DEBUG and "ON" or "OFF"))
    return
  end

  DEFAULT_CHAT_FRAME:AddMessage("|cff00FF7F[RollLogger]|r Unknown command. Try /rolllog help")
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
    rebuildStats()
    return
  end

  if event == "CHAT_MSG_SYSTEM" or event == "CHAT_MSG_TEXT_EMOTE" or event == "CHAT_MSG_EMOTE" then
    if not rollParser then buildRollParser() end
    local msg = arg1 or ""

    if ROLLLOGGER_DEBUG then
      DEFAULT_CHAT_FRAME:AddMessage("|cff00FF7F[RollLogger]|r EV="..tostring(event).." MSG="..msg)
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
