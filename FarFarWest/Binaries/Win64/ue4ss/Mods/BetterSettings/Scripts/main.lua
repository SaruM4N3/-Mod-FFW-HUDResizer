print("BetterSettings: Loading...\n")

local UEHelpers = require("UEHelpers")

local CONFIG_FILE = "ue4ss\\Mods\\BetterSettings\\config.ini"
local Config = { HUDScale = 1.0 }

local function LoadConfig()
    local f = io.open(CONFIG_FILE, "r")
    if not f then return end
    for line in f:lines() do
        local k, v = line:match("^([%w_]+)%s*=%s*(.-)%s*$")
        if k == "HUDScale" then Config.HUDScale = tonumber(v) or 1.0 end
    end
    f:close()
    print("BetterSettings: HUDScale=" .. Config.HUDScale .. "\n")
end

local function SaveConfig()
    local f = io.open(CONFIG_FILE, "w")
    if not f then print("BetterSettings: ERROR - could not write config\n"); return end
    f:write("HUDScale=" .. string.format("%.2f", Config.HUDScale) .. "\n")
    f:close()
end

-- autoPivot=true  : pivot computed from widget content centre (fullscreen overlay widgets only)
-- pivot = {X,Y}   : explicit render-transform pivot; X=0 keeps left edge fixed
-- UI_Player_C native children are handled by ScalePlayerHUDNative below
-- UI_PlayerLifebar_C is excluded — game resets its scale
local HUD_CLASSES = {
    -- LEFT SIDE
    { cls = "UI_Chat_C",             autoPivot = true        },
    { cls = "UI_SpellCooldown_C",    pivot = {X=0.0, Y=0.5} },
    -- CENTER
    { cls = "UI_Timer_C",            autoPivot = true        },
    { cls = "UI_Interact_C"                                   },
    { cls = "UI_LowAmmo_C",          autoPivot = true        },
    { cls = "UI_Contract_C"                                   },
    { cls = "UI_InGameModifiers_C"                            },
    { cls = "UI_JokerCard_InGame_C"                           },
    { cls = "UI_PlayerInfos_C"                                },
    { cls = "UI_Guide_C"                                      },
    -- WORLD-SPACE
    { cls = "UI_Lifebar_C"                                    },
}

local CachedVP = nil

local function GetViewportSize()
    if CachedVP then return CachedVP.w, CachedVP.h end
    local w, h = 1920, 1080

    pcall(function()
        local KSL = UEHelpers.GetKismetSystemLibrary()
        local WC  = UEHelpers.GetWorldContextObject()
        local x, y = KSL:GetViewportSize(WC)
        if type(x) == "number" and x > 100 then w, h = x, y end
    end)

    if w == 1920 then
        pcall(function()
            local KSL = UEHelpers.GetKismetSystemLibrary()
            local PC  = UEHelpers.GetPlayerController()
            if not (PC and PC:IsValid()) then return end
            local x, y = KSL:GetViewportSize(PC)
            if type(x) == "number" and x > 100 then w, h = x, y end
        end)
    end

    if w == 1920 then
        pcall(function()
            local c = FindFirstOf("UI_Chat_C")
            if not (c and c:IsValid()) then return end
            local geom = c:GetCachedGeometry()
            if not geom then return end
            local sz
            pcall(function() sz = geom:GetLocalSize() end)
            if not (sz and sz.X > 100) then pcall(function() sz = geom.LocalSize end) end
            if not (sz and sz.X > 100) then pcall(function() sz = geom:GetAbsoluteSize() end) end
            if sz and sz.X > 100 then w, h = math.floor(sz.X), math.floor(sz.Y) end
        end)
    end

    CachedVP = { w = w, h = h }
    return w, h
end

local PivotCache = {}

local function ComputePivot(widget, vpW, vpH)
    local path = widget:GetFullName()
    if PivotCache[path] then return PivotCache[path] end

    local result
    pcall(function()
        local tree = widget.WidgetTree
        if not (tree and tree:IsValid()) then return end
        local root = tree.RootWidget
        if not (root and root:IsValid()) then return end
        local cnt = 0
        pcall(function() cnt = root:GetChildrenCount() end)

        for i = 0, cnt - 1 do
            local c; pcall(function() c = root:GetChildAt(i) end)
            if not (c and c:IsValid()) then goto nc end
            pcall(function()
                local s = c.Slot
                if not (s and s:IsValid()) then return end
                local ok1, sz  = pcall(function() return s:GetSize() end)
                local ok2, off = pcall(function() return s:GetOffsets() end)
                local ok3, anc = pcall(function() return s:GetAnchors() end)
                if not (ok1 and sz and sz.X > 0) then return end
                if not (ok2 and off) then return end
                if not (ok3 and anc) then return end
                local cx = anc.Minimum.X * vpW + off.Left + sz.X * 0.5
                local cy = anc.Minimum.Y * vpH + off.Top  + sz.Y * 0.5
                result = {
                    X = math.max(0, math.min(1, cx / vpW)),
                    Y = math.max(0, math.min(1, cy / vpH)),
                }
            end)
            if result then break end
            ::nc::
        end
    end)

    if result then PivotCache[path] = result end
    return result
end

-- UI_Player_C is the fullscreen master HUD container. Its right-side resource panel
-- (gold/souls/tickets/level/XP) and center elements are native UE widgets with no
-- separate _C class, so FindAllOf cannot reach them. Widget tree path:
--   RootWidget (InvalidationBox) → CanvasPanel[0] → RetainerBox[4] → CanvasPanel[0]
-- Each inner child is scaled by anchor position:
--   ancX <= 0.25 → left-side, skip (Blueprint child classes handle these)
--   ancX >= 0.75 → right-side, pivot X=1 (right edge stays fixed)
--   otherwise    → center, pivot X=0.5
--   stretch anchors (min≠max) → skip
local function ScalePlayerHUDNative(scale)
    local player = FindFirstOf("UI_Player_C")
    if not (player and player:IsValid()) then return end
    local ok, err = pcall(function()
        local tree = player.WidgetTree
        if not (tree and tree:IsValid()) then return end
        local root = tree.RootWidget
        if not (root and root:IsValid()) then return end
        local outerCanvas; pcall(function() outerCanvas = root:GetChildAt(0) end)
        if not (outerCanvas and outerCanvas:IsValid()) then return end
        local retainer; pcall(function() retainer = outerCanvas:GetChildAt(4) end)
        if not (retainer and retainer:IsValid()) then return end
        local innerCanvas; pcall(function() innerCanvas = retainer:GetChildAt(0) end)
        if not (innerCanvas and innerCanvas:IsValid()) then return end

        local cnt = 0
        pcall(function() cnt = innerCanvas:GetChildrenCount() end)
        for i = 0, cnt - 1 do
            local c; pcall(function() c = innerCanvas:GetChildAt(i) end)
            if not (c and c:IsValid()) then goto nc end
            pcall(function()
                local s = c.Slot
                if not (s and s:IsValid()) then return end
                local okA, anc = pcall(function() return s:GetAnchors() end)
                if not okA or not anc then return end
                if anc.Minimum.X ~= anc.Maximum.X or anc.Minimum.Y ~= anc.Maximum.Y then return end
                if anc.Minimum.X <= 0.25 then return end
                local pivX = anc.Minimum.X >= 0.75 and 1.0 or 0.5
                local pivY = anc.Minimum.Y >= 0.75 and 1.0 or (anc.Minimum.Y <= 0.25 and 0.0 or 0.5)
                c:SetRenderTransformPivot({X=pivX, Y=pivY})
                c:SetRenderScale({X=scale, Y=scale})
            end)
            ::nc::
        end
    end)
    if not ok then
        print("BetterSettings: ScalePlayerHUDNative err: " .. tostring(err) .. "\n")
    end
end

local ApplyHUDScale

local function ApplyPivot(w, entry, vpW, vpH)
    if entry.autoPivot then
        local piv = ComputePivot(w, vpW, vpH)
        if piv then w:SetRenderTransformPivot(piv) end
    elseif entry.pivot then
        w:SetRenderTransformPivot(entry.pivot)
    end
end

ApplyHUDScale = function()
    local scale = Config.HUDScale
    local vpW, vpH = GetViewportSize()

    for _, entry in ipairs(HUD_CLASSES) do
        local widgets = FindAllOf(entry.cls)
        if widgets then
            for _, w in ipairs(widgets) do
                if w and w:IsValid() then
                    pcall(function()
                        ApplyPivot(w, entry, vpW, vpH)
                        w:SetRenderScale({ X = scale, Y = scale })
                    end)
                end
            end
        end
    end

    ScalePlayerHUDNative(scale)
    print("BetterSettings: scale=" .. string.format("%.2f", scale) .. "\n")
end

LoadConfig()

local function TryScale(dir)
    if dir < 0 then
        Config.HUDScale = math.max(math.floor((Config.HUDScale - 0.05) * 100 + 0.5) / 100, 0.5)
    else
        Config.HUDScale = math.min(math.floor((Config.HUDScale + 0.05) * 100 + 0.5) / 100, 1.25)
    end
    ApplyHUDScale()
    SaveConfig()
end

RegisterKeyBindAsync(Key.DOWN_ARROW, {ModifierKey.CONTROL}, function()
    ExecuteInGameThread(function() TryScale(-1) end)
end)
RegisterKeyBindAsync(Key.UP_ARROW, {ModifierKey.CONTROL}, function()
    ExecuteInGameThread(function() TryScale(1) end)
end)

NotifyOnNewObject("/Script/Engine.HUD", function()
    ExecuteInGameThread(function() ApplyHUDScale() end)
end)

NotifyOnNewObject("/Script/UMG.UserWidget", function(NewWidget)
    ExecuteInGameThread(function()
        if not NewWidget or not NewWidget:IsValid() then return end
        local name = NewWidget:GetFullName()

        if name:find("UI_Player_C", 1, true) then
            ScalePlayerHUDNative(Config.HUDScale)
        end

        for _, entry in ipairs(HUD_CLASSES) do
            if name:find(entry.cls, 1, true) then
                PivotCache[name] = nil
                local vpW, vpH = GetViewportSize()
                pcall(function()
                    ApplyPivot(NewWidget, entry, vpW, vpH)
                    NewWidget:SetRenderScale({ X = Config.HUDScale, Y = Config.HUDScale })
                end)
                break
            end
        end
    end)
end)

print("BetterSettings: Ready  (Ctrl+Down = scale-  |  Ctrl+Up = scale+)\n")
