-- RollLogger.lua
-- Logs your /roll results via CHAT_MSG_SYSTEM and stores both structured rows and CSV lines in SavedVariables.

local ADDON_NAME = "RollLogger"
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("CHAT_MSG_SYSTEM")

-- SavedVariables schema:
-- RollLoggerDB = {
--   entries = { { ts=UNIX, player="Name", result=57, min=1, max=100, idx=1 }, ... },
--   csvLines = { "timestamp,player,result,min,max,idx", ... },
--   sessionCount = 0, -- only your own rolls are recorded
--   totalCount   = 0,
--   localeFmt    = RANDOM_ROLL_RESULT at first run, to futureproof parsing
-- }

local function now()
  -- WoW Classic/Turtle doesn’t have time() exposed. Use GetTime() (seconds since UI load) + a session base.
  -- We’ll keep human-readable instead: date("%Y-%m-%d %H:%M:%S")
  return date("%Y-%m-%d %H:%M:%S")
end

local function ensureDB()
  if not RollLoggerDB or type(RollLoggerDB) ~= "table" then
    RollLoggerDB = {}
  end
  RollLoggerDB.entries   = RollLoggerDB.entries   or {}
  RollLoggerDB.csvLines  = RollLoggerDB.csvLines  or {}
  RollLoggerDB.sessionCount = RollLoggerDB.sessionCount or 0
  RollLoggerDB.totalCount   = RollLoggerDB.totalCount   or 0
  if not RollLoggerDB.csvInit then
    -- header
    RollLoggerDB.csvLines[1] = "timestamp,player,result,min,max,idx"
    RollLoggerDB.csvInit = true
  end
  if not RollLoggerDB.localeFmt then
    -- Persist the current roll pattern for reference
    RollLoggerDB.localeFmt = RANDOM_ROLL_RESULT or "%s rolls %d (%d-%d)"
  end
end

-- Robust parser for system "roll" lines across locales.
-- In 1.12, RANDOM_ROLL_RESULT = "%s rolls %d (%d-%d)" (localized).
-- We build a pattern from that format string if available. Fallback to EN.
local rollParser

local function buildRollParser()
  local fmt = RANDOM_ROLL_RESULT or "%s rolls %d (%d-%d)"
  -- Convert the localized format into a Lua pattern:
  -- Replace %s with (.+), %d with (%d+), escape punctuation.
  local patt = fmt
  patt = patt:gsub("%%s", "(.+)")
  patt = patt:gsub("%%d", "(%%d+)")
  -- Escape parentheses and other magic characters not covered by replacements
  -- We already replaced (%d+) for digits; now ensure hyphen is literal
  patt = patt:gsub("%(", "%%("):gsub("%)", "%%)")
  patt = patt:gsub("%-", "%%-")
  -- Example result: "(.+) rolls (%d+) %((%d+)%-((%d+))%)"
  rollParser = patt
end

local function isPlayerMe(name)
  -- Strip realm if any; Turtle/Vanilla typically has no realm in names, but be safe.
  name = name or ""
  local me = UnitName("player")
  return name == me
end

local function appendCSV(ts, player, result, minv, maxv, idx)
  -- Sanitize commas/quotes – player names shouldn’t have commas but we’ll be safe.
  local function q(s)
    s = tostring(s or "")
    if s:find('[",]') then
      s = '"' .. s:gsub('"', '""') .. '"'
    end
    return s
  end
  local line = table.concat({ q(ts), q(player), q(result), q(minv), q(maxv), q(idx) }, ",")
  table.insert(RollLoggerDB.csvLines, line)
end

local function recordRoll(player, result, minv, maxv)
  ensureDB()

  -- Only log YOUR rolls (as requested: "every /roll I do")
  if not isPlayerMe(player) then return end

  RollLoggerDB.sessionCount = (RollLoggerDB.sessionCount or 0) + 1
  RollLoggerDB.totalCount   = (RollLoggerDB.totalCount or 0) + 1

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

-- Slash commands
SLASH_ROLLLOGGER1 = "/rolllog"
SlashCmdList["ROLLLOGGER"] = function(msg)
  ensureDB()
  msg = msg and msg:lower() or ""

  if msg == "stats" or msg == "" then
    local n = #RollLoggerDB.entries
    local gt50 = 0
    for _, r in ipairs(RollLoggerDB.entries) do
      if r.min == 1 and r.max == 100 and r.result and r.result > 50 then
        gt50 = gt50 + 1
      end
    end
    DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00FF7F[RollLogger]|r Recorded rolls: %d  (1-100 and >50: %d)", n, gt50))
    DEFAULT_CHAT_FRAME:AddMessage("|cff00FF7F[RollLogger]|r /rolllog export  - rebuild CSV buffer")
    DEFAULT_CHAT_FRAME:AddMessage("|cff00FF7F[RollLogger]|r /rolllog reset   - clear data (irreversible)")
    return
  elseif msg == "reset" then
    RollLoggerDB.entries   = {}
    RollLoggerDB.csvLines  = { "timestamp,player,result,min,max,idx" }
    RollLoggerDB.sessionCount = 0
    -- keep totalCount so your idx stays monotonic across sessions; reset if you want:
    -- RollLoggerDB.totalCount = 0
    DEFAULT_CHAT_FRAME:AddMessage("|cff00FF7F[RollLogger]|r Data cleared.")
    return
  elseif msg == "export" then
    -- Rebuild CSV buffer from entries just in case.
    RollLoggerDB.csvLines = { "timestamp,player,result,min,max,idx" }
    for _, r in ipairs(RollLoggerDB.entries) do
      appendCSV(r.ts, r.player, r.result, r.min, r.max, r.idx)
    end
    DEFAULT_CHAT_FRAME:AddMessage("|cff00FF7F[RollLogger]|r CSV buffer rebuilt. It will be present in SavedVariables after you /reload or logout.")
    return
  else
    DEFAULT_CHAT_FRAME:AddMessage("|cff00FF7F[RollLogger]|r Commands: /rolllog, /rolllog stats, /rolllog export, /rolllog reset")
    return
  end
end

f:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
    ensureDB()
    buildRollParser()
  elseif event == "PLAYER_LOGIN" then
    ensureDB()
    if not rollParser then buildRollParser() end
  elseif event == "CHAT_MSG_SYSTEM" then
    if not rollParser then buildRollParser() end
    local msg = arg1 or ""
    -- Try localized pattern:
    local p, r, a, b = msg:match(rollParser)
    if p and r and a and b then
      recordRoll(p, r, a, b)
      return
    end
    -- Fallback to English just in case
    local p2, r2, a2, b2 = msg:match("^(.+) rolls (%d+) %((%d+)%-(%d+)%)$")
    if p2 and r2 and a2 and b2 then
      recordRoll(p2, r2, a2, b2)
      return
    end
  end
end)
