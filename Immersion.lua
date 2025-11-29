-- Immersion — targeted fix so buffs don't pop back after fade-out
-- Idea: keep FADE_ONLY during fades, but when finishing a fade-out (alpha=0),
-- call :Hide() *only* on BuffFrame and TemporaryEnchantFrame. On the way back (fade-in),
-- show them at alpha=0 and animate normally.
-- Added: defers BuffFrame/TemporaryEnchantFrame fade-in if a fade-out is mid-flight to avoid flicker.
-- The rest of the logic stays aligned with the stable version + timeouts; we don't touch chat/minimap.
-- safe match helper (handles environments where string.match or strmatch may be nil/overridden)

local function s_match(s, p)
  local sm = (_G and _G.string and _G.string.match) and _G.string.match or _G.strmatch
  if sm then return sm(s, p) end
  return nil
end

local ADDON  = "Immersion"
local prefix = "|cFF66C2FF[Immersion]|r "
local f      = CreateFrame("Frame")

-- Always keep Controllers defined to avoid pairs(nil) before PEW
local Controllers = {}

-- ====== Delay tweaks ======
-- TARGET_GRACE controls the grace window AFTER you lose a LIVING target.
local TARGET_GRACE    = 2.0  -- seconds
-- MOUSEOVER_GRACE controls the grace window AFTER leaving the action bars with the mouse.
local MOUSEOVER_GRACE = 2.0  -- seconds
-- Only close game windows on fade if explicitly enabled
local CLOSE_WINDOWS_ON_FADE = false
local function CloseWindowsIfAllowed()
  if CLOSE_WINDOWS_ON_FADE and CloseAllWindows then
    CloseAllWindows()
  end
end

-- ===================== Config / DB =====================
local function FreshDB()
  return { enabled=true, debug=false, showOnTarget=true, fadeTime=3.0 }
end
local function asBool(v,d)
  if v==nil then return d end
  local t=type(v)
  if t=="boolean" then return v end
  if t=="number"  then return v~=0 end
  if t=="string"  then
    local s=string.lower(v)
    if s=="1" or s=="true" or s=="on" or s=="yes" then return true end
    if s=="0" or s=="false" or s=="off" or s=="no" then return false end
    return d
  end
  return d
end
local function InitDB()
  if type(ImmersionDB)~="table" then ImmersionDB = FreshDB() end
  ImmersionDB.enabled      = asBool(ImmersionDB.enabled, true)
  ImmersionDB.debug        = asBool(ImmersionDB.debug,   false)
  ImmersionDB.showOnTarget = asBool(ImmersionDB.showOnTarget, true)
  ImmersionDB.fadeTime     = tonumber(ImmersionDB.fadeTime or 3.0)
end
local function G(n) if getglobal then return getglobal(n) end if _G then return _G[n] end end
local function dprint(msg) if ImmersionDB and ImmersionDB.debug then DEFAULT_CHAT_FRAME:AddMessage(prefix.."|cFFBBBBBB"..msg.."|r") end end

-- ===================== FIXED LIST OF FRAMES =====================
local FRAME_NAMES = {
  -- Action bars
  "MainMenuBar",
  "MultiBarBottomLeft", "MultiBarBottomRight", "MultiBarLeft", "MultiBarRight",
  "PetActionBarFrame", "ShapeshiftBarFrame","DFRL_ShapeshiftBar",

  -- MicroMenu
  "CharacterMicroButton","SpellbookMicroButton","TalentMicroButton",
  "QuestLogMicroButton","SocialsMicroButton","WorldMapMicroButton",
  "MainMenuMicroButton","HelpMicroButton","DFRLLowLevelTalentsButton",

  -- Bags
  "MainMenuBarBackpackButton","CharacterBag0Slot","CharacterBag1Slot",
  "CharacterBag2Slot","CharacterBag3Slot","KeyRingButton",

  -- Unit frames
  "PlayerFrame","PetFrame","TargetFrameToT",

  -- ChatFrame
  "ChatFrameMenuButton","ChatFrame1UpButton","ChatFrame1DownButton","ChatFrame1BottomButton",

  -- DragonFlight-like UI (compat)
  "DFRL_GryphonContainer","DFRLBagToggleButton","DFRLEBCMicroButton","DFRLLFTMicroButton",
  "DFRLPvPMicroButton","DFRL_MainBar","DFRL_RepBar","DFRL_XPBar","DFRL_NetStatsFrame",
  "DFRL_LatencyIndicator","DFRL_PagingContainer","DFRL_ActionBar",

  -- Quest tracker (Classic/Turtle)
  "QuestWatchFrame",

  -- Cast/Buffs
  -- "CastingBarFrame", -- don't touch player casting bar
  "PetCastingBarFrame",
  "BuffFrame","TemporaryEnchantFrame",
}

-- Frames we must NOT force :Show() on (conditional frames)
local DO_NOT_FORCE_SHOW = {
TargetFrameToT = true,
  PetFrame = true,
  PetCastingBarFrame = true,
  PartyMemberFrame2 = true,
  PartyMemberFrame3 = true,
  PartyMemberFrame4 = true,
  PartyMemberFrame1 = true,
  PartyMemberBackground = true,
}

-- Bars/frames that should only alpha-fade (we do NOT call :Hide() at the end)
-- NOTE: Removed BuffFrame/TemporaryEnchantFrame here, because we explicitly Hide() them on fade-out.
local FADE_ONLY = {
  MainMenuBar = true,
  MultiBarBottomLeft = true, MultiBarBottomRight = true, MultiBarLeft = true, MultiBarRight = true,
  PetActionBarFrame = true, ShapeshiftBarFrame = true,
  PetFrame = true, -- prevents disappearing for good at the end of fade-out
  PartyMemberBackground = true,
  -- BuffFrame = true, TemporaryEnchantFrame = true, -- <- removed on purpose
}

-- ===================== CONTROLLERS (one per frame) =====================

local function NewController(fr)
  local function IsBuffLike(name)
    return name == "BuffFrame" or name == "TemporaryEnchantFrame"
  end

  local c = {}
  c.frame = fr
  c.fadeCtrl = CreateFrame("Frame"); c.fadeCtrl:Hide()
  c.Fade = { active=false, target=nil, start=1, elapsed=0, duration=3.0 }
  c.resume = fr:IsShown()
  c.deferFadeIn = false      -- defers fade-in if a fade-out is in progress (buffs only)
  c.deferReason = nil        -- optional: remember reason
c.deferFadeOut = false
c.deferOutReason = nil

  local function GetAlphaSafe()
    local a = c.frame and c.frame.GetAlpha and c.frame:GetAlpha() or 1
    return a or 1
  end

  local function ClampDuration(x)
    x = tonumber(x or 0) or 0
    if x < 0.05 then x = 0.05 end
    return x
  end

  function c:StartFade(targetAlpha, reason)
    if not self.frame then return end
    local name = self.frame:GetName() or ""
  -- Minimal anti-flicker: if Buff-like is mid fade-IN and fade-OUT is requested, defer the OUT
  if IsBuffLike(name) and targetAlpha == 0 and self.Fade.active and self.Fade.target == 1 then
    self.deferFadeOut  = true
    self.deferOutReason = reason or "deferred_buff_fadeout"
    return
  end
    local dontForce = DO_NOT_FORCE_SHOW[name]
    if targetAlpha == 1 and dontForce and not self.frame:IsShown() then
      dprint("["..name.."] skip force-show (conditional)")
      self.Fade.active = false
      self.Fade.target = nil
      return
    end

    
    if targetAlpha == 1 and self.frame:IsShown() then
      self.resume = true
    end

    -- default duration
    self.Fade.duration = ClampDuration(ImmersionDB.fadeTime or 3.0)

    -- priority fade-ins are shorter
    if targetAlpha == 1 and reason and (
        string.find(reason, "priority:combat", 1, true) or
        string.find(reason, "priority:target", 1, true) or
        string.find(reason, "priority:mouseover", 1, true)
    ) then
      self.Fade.duration = ClampDuration(0.8)
    end

    local name = self.frame:GetName() or ""

    -- If BUFF-like is fading out and a fade-in arrives, defer the fade-in
    if IsBuffLike(name) and self.Fade.active and self.Fade.target == 0 and targetAlpha == 1 then
      self.deferFadeIn = true
      self.deferReason = reason or "deferred_buff_fadein"
      return
    end

    if self.Fade.active and self.Fade.target == targetAlpha then
      dprint("["..(name).."] Fade -> "..targetAlpha.." (skip) ["..(reason or "").."]")
      return
    end

    dprint("["..(name).."] StartFade -> "..targetAlpha.." ["..(reason or "").."]")
    self.Fade.active  = true
    self.Fade.target  = targetAlpha
    self.Fade.elapsed = 0
    self.Fade.start   = GetAlphaSafe()

    if targetAlpha > self.Fade.start then
      if self.frame.Show then self.frame:Show() end
      if self.frame.SetAlpha then self.frame:SetAlpha(self.Fade.start) end
    end

    self.fadeCtrl:Show()
  end

  c.fadeCtrl:SetScript("OnUpdate", function()
    if not (c.Fade.active and c.Fade.target and c.frame) then return end
    local dt = arg1 or 0
    c.Fade.elapsed = c.Fade.elapsed + dt
    local t = c.Fade.elapsed / (c.Fade.duration > 0 and c.Fade.duration or 0.05)

    local name = c.frame:GetName() or ""
    if t >= 1 then
      if c.frame.SetAlpha then c.frame:SetAlpha(c.Fade.target) end
      -- If we just completed a fade-in and a fade-out was deferred, run it now
      if c.Fade.target == 1 and c.deferFadeOut then
        local _r = c.deferOutReason or "deferred_buff_fadeout"
        c.deferFadeOut, c.deferOutReason = false, nil
        c.Fade.active, c.Fade.target = false, nil
        c.Fade.elapsed, c.Fade.start = 0, 1
        c:StartFade(0, _r)
        return
      end

      if c.Fade.target == 0 then
        -- end of fade-out
        if name=="BuffFrame" or name=="TemporaryEnchantFrame" then
          if c.frame.Hide then c.frame:Hide() end
          -- if a fade-in was deferred, trigger it now cleanly
          if c.deferFadeIn then
            c.deferFadeIn = false
            local reason = c.deferReason or "deferred_buff_fadein"
            c.deferReason = nil
            -- prepare: show at 0 and then fade-in
            if c.frame.Show then c.frame:Show() end
            if c.frame.SetAlpha then c.frame:SetAlpha(0) end
            c.Fade.active  = false
            c.Fade.target  = nil
            c.Fade.elapsed = 0
            c.Fade.start   = 0
            c:StartFade(1, reason)
            return
          end
        elseif not FADE_ONLY[name] and c.frame.Hide then
          c.frame:Hide()
        end
      end

      c.Fade.active, c.Fade.target = false, nil
      c.fadeCtrl:Hide()
      return
    end

    local newAlpha = c.Fade.start + (c.Fade.target - c.Fade.start) * t
    if c.frame.SetAlpha then c.frame:SetAlpha(newAlpha) end
  end)

  return c
end

local function ResolveControllers()
  Controllers = {}
  for _,name in ipairs(FRAME_NAMES) do
    local fr = G(name)
    if fr and fr.SetAlpha and fr.Show and fr.Hide then
      Controllers[fr] = NewController(fr)
      dprint("OK: "..name)
    else
      dprint("Skip: "..name.." (missing/not API-compatible)")
    end
  end
  local count=0; for _ in pairs(Controllers) do count=count+1 end
  dprint("Controllers created: "..count)
end

-- ===================== ZoneText guard & failsafes =====================
local function IsFrameAlphaActive(fr)
  if not fr or not fr.IsShown or not fr:IsShown() then return false end
  if fr.GetAlpha then
    local a = fr:GetAlpha() or 1
    if a <= 0.1 then return false end
  end
  return true
end
local function IsZoneTextActive()
  local Z, S = G("ZoneTextFrame"), G("SubZoneTextFrame")
  return IsFrameAlphaActive(Z) or IsFrameAlphaActive(S)
end

-- EXIT (fade-out): wait for ZoneText to clear, with TIMEOUT (3s)
local zoneHideGuard = CreateFrame("Frame"); zoneHideGuard:Hide()
zoneHideGuard.acc, zoneHideGuard.tick = 0, 0.05
zoneHideGuard.waited, zoneHideGuard.maxWait = 0, 3.0
zoneHideGuard.wantHide = false
zoneHideGuard:SetScript("OnUpdate", function()
  local dt = arg1 or 0
  zoneHideGuard.acc    = zoneHideGuard.acc + dt
  zoneHideGuard.waited = zoneHideGuard.waited + dt
  if zoneHideGuard.acc < zoneHideGuard.tick then return end
  zoneHideGuard.acc = 0
  if (not IsZoneTextActive()) or (zoneHideGuard.waited >= zoneHideGuard.maxWait) then
    zoneHideGuard:Hide()
    if zoneHideGuard.wantHide then
      zoneHideGuard.wantHide = false
      CloseWindowsIfAllowed()
      for fr,c in pairs(Controllers) do
        c.resume = fr:IsShown()
        c:StartFade(0, (zoneHideGuard.waited >= zoneHideGuard.maxWait) and "hide_timeout" or "hide_after_zone")
      end
    end
  end
end)

-- ENTER (fade-in): guard + timeout
local zoneShowGuard = CreateFrame("Frame"); zoneShowGuard:Hide()
zoneShowGuard.acc, zoneShowGuard.tick = 0, 0.05
zoneShowGuard.waited, zoneShowGuard.maxWait = 0, 0
zoneShowGuard.wantShow = false
zoneShowGuard:SetScript("OnUpdate", function()
  local dt = arg1 or 0
  zoneShowGuard.acc    = zoneShowGuard.acc + dt
  zoneShowGuard.waited = zoneShowGuard.waited + dt
  if zoneShowGuard.acc < zoneShowGuard.tick then return end
  zoneShowGuard.acc = 0
  if (not IsZoneTextActive()) or (zoneShowGuard.waited >= zoneShowGuard.maxWait) then
    zoneShowGuard:Hide()
    if zoneShowGuard.wantShow then
      zoneShowGuard.wantShow = false
      for _,c in pairs(Controllers) do
        if c.resume ~= false then c:StartFade(1, (zoneShowGuard.waited >= zoneShowGuard.maxWait) and "show_timeout" or "show_after_zone") end
      end
    end
  end
end)

local function ForceFadeInAll(reason)
  for fr,c in pairs(Controllers) do
    local name = fr:GetName() or ""
    local dontForce = DO_NOT_FORCE_SHOW[name]
    if not dontForce and c.resume ~= false then
      c:StartFade(1, reason or "force_fade_in")
    end
  end
end

local function ForceRestoreAllInstant()
  for fr,c in pairs(Controllers) do
    if c.resume ~= false then
      local n = fr:GetName() or ""
    local unit = fr.unit or (s_match(n, "^PartyMemberFrame(%d+)$") and ("party"..s_match(n, "%d+")))
    if unit and UnitExists and UnitExists(unit) then
      c.resume = true
      
      if fr.SetAlpha then fr:SetAlpha(1) end
      if fr.Show then fr:Show() end
    end
      if not DO_NOT_FORCE_SHOW[n] then -- do not force-show conditional frames
        if fr.Show then fr:Show() end
        if fr.SetAlpha then fr:SetAlpha(1) end
      end
    end
  end
end

local restoreFailsafe = CreateFrame("Frame"); restoreFailsafe:Hide()
restoreFailsafe.t, restoreFailsafe.timeout = 0, 4.0
restoreFailsafe:SetScript("OnUpdate", function()
  restoreFailsafe.t = restoreFailsafe.t + (arg1 or 0)
  if restoreFailsafe.t >= restoreFailsafe.timeout then
    restoreFailsafe:Hide()
    dprint("Failsafe: forcing fade-in (respecting resume/conditionals).")
    ForceFadeInAll("failsafe_timer")
  end
end)

-- ===================== Helpers =====================
local function HideAll(reason)
  local any=false; for _ in pairs(Controllers) do any=true; break end
  if not any then return end

  if IsZoneTextActive() then
    dprint("ZoneText visible — delaying fade-out (all)")
    zoneHideGuard.wantHide = true
    zoneHideGuard.waited   = 0
    zoneHideGuard:Show()
    return
  end
  CloseWindowsIfAllowed()
  for fr,c in pairs(Controllers) do
    c.resume = fr:IsShown()
    c:StartFade(0, reason or "hide")
  end
end

local function ShowAll(reason)
  local any=false; for _ in pairs(Controllers) do any=true; break end
  if not any then return end

  if IsZoneTextActive() then
    dprint("ZoneText visible — delaying fade-in (all)")
    zoneShowGuard.wantShow = true
    zoneShowGuard.waited   = 0
    zoneShowGuard:Show()
    restoreFailsafe.t = 0; restoreFailsafe:Show()
    return
  end

  restoreFailsafe:Hide()
  for _,c in pairs(Controllers) do
    local fr = c.frame
    local n  = fr and (fr:GetName() or "") or ""
    
    
    -- Defensive: ensure PartyMemberBackground is shown again when in a group
    local partyCount = (GetNumGroupMembers and GetNumGroupMembers() or (GetNumPartyMembers and GetNumPartyMembers() or 0))
    if n == "PartyMemberBackground" and (partyCount or 0) > 0 then
      if fr and fr.Show then fr:Show() end
      c.resume = true
    end
local idx = s_match(n, "^PartyMemberFrame(%d+)$"); local unit = fr and (fr.unit or (idx and ("party"..idx))) or nil
    if unit and UnitExists and UnitExists(unit) then
      c.resume = true
      if fr and fr.Show then fr:Show() end
    end
    if c.resume ~= false then c:StartFade(1, reason or "show") end
  end
end

-- ===================== Debounced ENTER logic =====================
local ZONE_DEBOUNCE = 0.6
local lastZoneEvent, pendingRestingCheck = 0, false

local scheduler = CreateFrame("Frame"); scheduler:Hide()
scheduler.timeLeft = 0
scheduler:SetScript("OnUpdate", function()
  scheduler.timeLeft = scheduler.timeLeft - (arg1 or 0)
  if scheduler.timeLeft <= 0 then
    scheduler:Hide()
    if pendingRestingCheck then pendingRestingCheck = false; f:Evaluate("zone_debounced") end
  end
end)

local function DebouncedShowForResting()
  local now = GetTime and GetTime() or 0
  if now - lastZoneEvent < ZONE_DEBOUNCE then
    pendingRestingCheck = true
    scheduler.timeLeft  = ZONE_DEBOUNCE - (now - lastZoneEvent)
    if scheduler.timeLeft < 0.05 then scheduler.timeLeft = 0.05 end
    scheduler:Show()
    dprint("Waiting zone debounce: "..string.format("%.2f", scheduler.timeLeft).."s")
    return
  end
  if IsZoneTextActive() then
    zoneShowGuard.wantShow = true
    zoneShowGuard.waited   = 0
    zoneShowGuard:Show()
    restoreFailsafe.t = 0; restoreFailsafe:Show()
  else
    restoreFailsafe:Hide()
    for _,c in pairs(Controllers) do local fr=c.frame; local n=fr and (fr:GetName() or "") or ""; local idx = s_match(n, "^PartyMemberFrame(%d+)$"); local unit = fr and (fr.unit or (idx and ("party"..idx))) or nil; if unit and UnitExists and UnitExists(unit) then c.resume = true; if fr and fr.Show then fr:Show() end end; if c.resume ~= false then c:StartFade(1, "resting") end end
  end
end

-- ===================== Action bars mouseover =====================
local function IsActionBarish(name)
  if not name then return false end
  -- Common buttons
  if string.find(name, "ActionButton",      1, true) then return true end  -- ActionButton1..12
  if string.find(name, "BonusActionButton", 1, true) then return true end
  if string.find(name, "MultiBar",          1, true) then return true end  -- MultiBarBottomLeftButton...
  if string.find(name, "PetActionButton",   1, true) then return true end
  if string.find(name, "ShapeshiftButton",  1, true) then return true end
  -- Common containers
  if name=="MainMenuBar" or name=="PetActionBarFrame" or name=="ShapeshiftBarFrame" then return true end
  -- PlayerFrame hover hotspot
  if name=="Immersion_PlayerHoverFrame" or name=="PlayerFrame" or (s_match and s_match(name, "^PlayerFrame")) then return true end
  -- Compat containers (DragonFlight-like)
  if name=="DFRL_ActionBar" or name=="DFRL_MainBar" then return true end
  return false
end
local immersionPlayerHoverInit = CreateFrame("Frame")
immersionPlayerHoverInit:RegisterEvent("PLAYER_ENTERING_WORLD")
immersionPlayerHoverInit:SetScript("OnEvent", function()
  Immersion_SetupPlayerHover()
end)


local hoverWatch = CreateFrame("Frame"); hoverWatch:Show()
hoverWatch.acc, hoverWatch.tick = 0, 0.05
hoverWatch:SetScript("OnUpdate", function()
  local dt = arg1 or 0
  hoverWatch.acc = hoverWatch.acc + dt
  if hoverWatch.acc < hoverWatch.tick then return end
  hoverWatch.acc = 0

  local mf   = GetMouseFocus and GetMouseFocus() or nil
  local name = mf and mf.GetName and mf:GetName() or nil
  local onBars = IsActionBarish(name)

  if onBars ~= f.mouseOverBars then
    f.mouseOverBars = onBars
    if onBars then
      -- Entered the bars: cancel leave window and show
      f.postMouseoverGraceUntil = 0
      f:Evaluate("mouseover_bars_enter")
    else
      -- Left the bars: keep visible for MOUSEOVER_GRACE
      local now = GetTime and GetTime() or 0
      f.postMouseoverGraceUntil = now + MOUSEOVER_GRACE
      if C_TimerAfter then
        C_TimerAfter(MOUSEOVER_GRACE, function()
          if not f.mouseOverBars and not f.inCombat then
            f.postMouseoverGraceUntil = 0
            f:Evaluate("mouseover_bars_end_delayed")
          end
        end)
      end
      f:Evaluate("mouseover_bars_leave_grace")
    end
  end
end)

-- ===================== Main logic =====================
f.inCombat                = false
f.postCombatGraceUntil    = 0  -- post-combat grace window (GetTime)
f.postTargetGraceUntil    = 0  -- post-target-loss grace window (GetTime)
f.lastTargetAlive         = nil -- last known target alive state
f.mouseOverBars           = false
f.postMouseoverGraceUntil = 0   -- post-mouseover grace window (GetTime)

function f:Evaluate(reason)
  if not ImmersionDB or not ImmersionDB.enabled then dprint("Disabled; no action."); return end

  local now = GetTime and GetTime() or 0

  -- Grace windows: (post-combat, post-target, post-mouseover)
  if (not f.inCombat) and (
      (f.postCombatGraceUntil    or 0) > now or
      (f.postTargetGraceUntil    or 0) > now or
      (f.postMouseoverGraceUntil or 0) > now
  ) then
    restoreFailsafe:Hide()
    ShowAll("grace_window")
    return
  end

  -- Fade-in: combat, living target, or mouseover on bars
  if f.inCombat or (
      ImmersionDB.showOnTarget
      and UnitExists and UnitExists("target")
      and not UnitIsDeadOrGhost("target")
  ) or f.mouseOverBars then
    restoreFailsafe:Hide()
    local why = f.inCombat and "combat" or (f.mouseOverBars and "mouseover" or "target")
    ShowAll("priority:"..why)
    return
  end

  -- Remaining logic
  if IsResting() then
    DebouncedShowForResting()
  else
    restoreFailsafe:Hide()
    HideAll("not_resting")
  end
end

-- ===================== Events =====================
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("PLAYER_UPDATE_RESTING")
f:RegisterEvent("PLAYER_REGEN_DISABLED")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
f:RegisterEvent("PLAYER_TARGET_CHANGED")
f:RegisterEvent("GROUP_ROSTER_UPDATE")
f:RegisterEvent("ZONE_CHANGED")
f:RegisterEvent("ZONE_CHANGED_INDOORS")
f:RegisterEvent("ZONE_CHANGED_NEW_AREA")

f:SetScript("OnEvent", function()
 if event == "PLAYER_ENTERING_WORLD" then
    InitDB()

    C_TimerAfter = function(sec, fn)
        local t = CreateFrame("Frame")
        t.elapsed = 0
        t:SetScript("OnUpdate", function()
            t.elapsed = t.elapsed + (arg1 or 0)
            if t.elapsed >= sec then
                t:SetScript("OnUpdate", nil)
                if type(fn) == "function" then fn() end
            end
        end)
    end

    -- Criar controllers normalmente
    ResolveControllers()
    C_TimerAfter(0.3, ResolveControllers)

    dprint("Loaded. Applying 5-second startup delay.")

    -- Aguarda 5 segundos para ativar o addon
    C_TimerAfter(5, function()
        f:Evaluate("entering_world_delayed")
    end)

    return
end


  if event=="PLAYER_REGEN_DISABLED" then
    f.inCombat = true
    f.postCombatGraceUntil = 0 -- cancel any previous window
    f.postTargetGraceUntil = 0 -- combat has priority
    f.postMouseoverGraceUntil = 0
    f:Evaluate("combat_start")
    return
  end

  if event=="PLAYER_REGEN_ENABLED" then
    -- Leaving combat: apply an Xs window BEFORE starting fade-out
    f.inCombat = false
    local grace = 8.0 -- adjust post-combat delay here
    f.postCombatGraceUntil = (GetTime and GetTime() or 0) + grace
    C_TimerAfter(grace, function()
      if not f.inCombat then
        f.postCombatGraceUntil = 0
        f:Evaluate("combat_end_delayed")
      end
    end)
    return
  end

  if event=="PLAYER_TARGET_CHANGED" then
    local hasTarget = UnitExists and UnitExists("target")

    if hasTarget then
      -- Update: is the current target alive?
      local alive = not UnitIsDeadOrGhost("target")
      f.lastTargetAlive = alive

      -- Aiming a living target cancels the post-target window (avoid delayed fade-out)
      if alive then
        f.postTargetGraceUntil = 0
      end

      f:Evaluate("target_changed")
      return
    else
      -- Now there is no target
      -- If the LAST target was dead, do nothing (no window, no Evaluate)
      if f.lastTargetAlive == false then
        dprint("Target cleared (was dead) — no UI change.")
        f.lastTargetAlive = nil
        return
      end

      -- Last target was living (or unknown): start post-target window
      f.lastTargetAlive = nil
      local now2 = GetTime and GetTime() or 0
      f.postTargetGraceUntil = now2 + TARGET_GRACE
      C_TimerAfter(TARGET_GRACE, function()
        -- Only apply if there is still no target and we didn't re-enter combat
        if not (UnitExists and UnitExists("target")) and not f.inCombat then
          f.postTargetGraceUntil = 0
          f:Evaluate("target_end_delayed")
        end
      end)
      -- Keep UI visible during the window
      f:Evaluate("target_lost_grace")
      return
    end
  end

  if event=="PLAYER_UPDATE_RESTING" then
    if IsResting() then
      DebouncedShowForResting()
      C_TimerAfter(1.0, function() ForceFadeInAll("resting_timer_1s") end)
      C_TimerAfter(3.5, function() ForceFadeInAll("resting_timer_3_5s") end)
      return
    end
  end

  if event=="ZONE_CHANGED" or event=="ZONE_CHANGED_INDOORS" or event=="ZONE_CHANGED_NEW_AREA" then
    lastZoneEvent = GetTime and GetTime() or 0
    dprint("Zone event: "..event)
    if IsResting() then DebouncedShowForResting(); return end
  end
  if event=="GROUP_ROSTER_UPDATE" then
    -- Immediately reveal any PartyMemberFrameN whose unit exists (even while resting)
    for i=1,4 do
      local unit = "party"..i
      if UnitExists and UnitExists(unit) then
        local fr = G("PartyMemberFrame"..i)
        local c  = fr and Controllers and Controllers[fr]
        if fr and c then
          if fr.Show then fr:Show() end
          if fr.SetAlpha then fr:SetAlpha(0) end -- prepare smooth fade-in
          c.resume = true
          c:StartFade(1, "roster_update")
        end
      end
    end
    -- Also ensure the PartyMemberBackground is visible if we have any party members
    local partyCount = (GetNumGroupMembers and GetNumGroupMembers() or (GetNumPartyMembers and GetNumPartyMembers() or 0)) or 0
    if partyCount > 0 then
      local bg = G("PartyMemberBackground")
      local cbg = bg and Controllers and Controllers[bg]
      if bg then if bg.Show then bg:Show() end end
      if cbg then
        cbg.resume = true
        cbg:StartFade(1, "roster_update_bg")
      end
    end
    return
  end


  f:Evaluate(string.lower(event or ""))
end)

-- ===================== No Numbers on PlayerFrame =====================

-- Permanently hides the combat numbers on the player's portrait
if PlayerHitIndicator then
  PlayerHitIndicator:Hide()
  PlayerHitIndicator.Show = function() end
end

-- (optional) Pet portrait
-- if PetHitIndicator then
--   PetHitIndicator:Hide()
--   PetHitIndicator.Show = function() end
-- end

-- (optional) Target portrait (exists on some clients)
-- if TargetFrame and TargetFrame.TargetHitIndicator then
--   local t = TargetFrame.TargetHitIndicator
--   t:Hide()
--   t.Show = function() end
-- end
-- ===================== Hide PlayerFrame Health Bar when Dragonflight UI is loaded =====================

local dfuiPlayerHealthHider = CreateFrame("Frame")
dfuiPlayerHealthHider:RegisterEvent("ADDON_LOADED")
dfuiPlayerHealthHider:RegisterEvent("PLAYER_ENTERING_WORLD")

local dfuiLoaded = false

local function DFUI_IsLoaded()
  if dfuiLoaded then return true end
  if IsAddOnLoaded then
    if IsAddOnLoaded("-DragonflightReloaded") then
      dfuiLoaded = true
      return true
    end
  end
  return false
end

local function DFUI_HidePlayerHealthBar()
  if not DFUI_IsLoaded() then return end
  if not PlayerFrame or not PlayerFrameHealthBar then return end

  PlayerFrameHealthBar:Hide()
  PlayerFrameHealthBar.Show = function() end

  if PlayerFrameHealthBarText then
    PlayerFrameHealthBarText:Hide()
    PlayerFrameHealthBarText.Show = function() end
  end
  if PlayerFrameHealthBarTextLeft then
    PlayerFrameHealthBarTextLeft:Hide()
    PlayerFrameHealthBarTextLeft.Show = function() end
  end
  if PlayerFrameHealthBarTextRight then
    PlayerFrameHealthBarTextRight:Hide()
    PlayerFrameHealthBarTextRight.Show = function() end
  end
end

dfuiPlayerHealthHider:SetScript("OnEvent", function()
  if event == "ADDON_LOADED" then
    if arg1 == "-DragonflightReloaded" then
      dfuiLoaded = true
      DFUI_HidePlayerHealthBar()
    end
  elseif event == "PLAYER_ENTERING_WORLD" then
    DFUI_HidePlayerHealthBar()
  end
end)
