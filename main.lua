-- ============================================================
-- Standard library requires
-- ============================================================
local WidgetContainer = require("ui/widget/container/widgetcontainer") -- base class all KOReader plugins extend
local Screen = require("device").screen                                -- gives us screen width/height
local Blitbuffer = require("ffi/blitbuffer")                           -- low-level pixel-buffer drawing (colors, rects)
local UIManager = require("ui/uimanager")                              -- controls what's shown/refreshed on screen
local SpinWidget = require("ui/widget/spinwidget")                     -- the drag-bar/slider popup for picking a number
local LuaSettings = require("luasettings")                             -- simple key/value settings file on disk
local DataStorage = require("datastorage")                             -- knows where KOReader keeps its settings files
local _ = require("gettext")                                           -- wraps user-facing strings for translation

-- ============================================================
-- Plugin definition
-- WidgetContainer:extend{} creates a new "class" that inherits
-- from WidgetContainer. The table fields below are just default
-- values for a fresh instance — they get overwritten once we
-- load saved settings in onReaderReady().
-- ============================================================
local TwoLines = WidgetContainer:extend{
    name = "twolines",   -- internal id KOReader uses to reference this plugin
    is_doc_only = true,       -- only load this when a document is open (not in the file browser)

    settings_file = DataStorage:getSettingsDir() .. "/bounding_lines.lua", -- where we'll persist settings

    margin_percent = 15,   -- default: lines sit 15% of screen width in from each edge
    line_width = 4,        -- default: line is 4px thick
    line_darkness = 10,    -- default: 1 (light gray) to 10 (solid black) — 10 = fully black
    enabled = true,        -- default: lines are on

    hide_when_sleeping = false, -- default: lines stay visible even while the device is asleep/in standby
}

-- ============================================================
-- onReaderReady fires once a book is open and the reader UI
-- (self.ui) and view (self.view) are fully constructed and
-- ready to use — this is our "setup" entry point.
-- ============================================================
function TwoLines:onReaderReady()
    -- Open (or create, if it doesn't exist yet) our settings file
    self.settings = LuaSettings:open(self.settings_file)

    -- For each setting, check if a saved value exists on disk.
    -- If it does, override the default we set above.
    -- (We check `~= nil` for booleans since `false` is a valid saved value.)
    local saved_margin = self.settings:readSetting("margin_percent")
    if saved_margin then self.margin_percent = saved_margin end

    local saved_width = self.settings:readSetting("line_width")
    if saved_width then self.line_width = saved_width end

    local saved_darkness = self.settings:readSetting("line_darkness")
    if saved_darkness then self.line_darkness = saved_darkness end

    local saved_enabled = self.settings:readSetting("enabled")
    if saved_enabled ~= nil then self.enabled = saved_enabled end

    local saved_hide_when_sleeping = self.settings:readSetting("hide_when_sleeping")
    if saved_hide_when_sleeping ~= nil then self.hide_when_sleeping = saved_hide_when_sleeping end

    -- Runtime-only flag (never persisted): whether the device is currently
    -- asleep/suspended/in standby. Starts false since onReaderReady only
    -- fires while the reader is actively open and on-screen.
    self.sleeping = false

    -- Add our entry to the reader's main menu (Tools/More tools)
    self.ui.menu:registerToMainMenu(self)

    -- THIS is the important line: it tells ReaderView "call my
    -- paintTo() every time you redraw the page." Without this,
    -- our paintTo below would just never get called.
    self.view:registerViewModule("bounding_lines", self)
end

-- ============================================================
-- addToMainMenu builds the menu tree shown under
-- Tools -> Two Lines. Each entry is a table with
-- text (label shown) and a callback (what happens on tap).
-- ============================================================
function TwoLines:addToMainMenu(menu_items)
    menu_items.bounding_lines = {
        text = _("Two Lines"),
        sorting_hint = "more_tools", -- which section of the Tools menu this appears in

        sub_item_table = {
            -- ---- Toggle on/off ----
            {
                text = _("Enable Two Lines"),
                -- checked_func makes this item render as a checkbox that
                -- reflects the LIVE value of self.enabled (re-evaluated
                -- every time the menu opens), not a value frozen at creation time.
                checked_func = function() return self.enabled end,
                callback = function()
                    self.enabled = not self.enabled
                    self:saveSettings()
                    -- Ask KOReader to repaint the reader window ("ui" = light
                    -- refresh, no full-screen flash) so the change shows immediately
                    -- instead of waiting for the next page turn.
                    UIManager:setDirty(self.dialog, "ui")
                end,
            },

            -- ---- Margin slider ----
            {
                text = _("Margin from edge"),
                keep_menu_open = true, -- don't close the Tools menu after tapping this
                callback = function()
                    -- SpinWidget builds a popup with a draggable bar, -/+ buttons,
                    -- and a numeric readout — the same widget used for font size,
                    -- frontlight brightness, etc.
                    UIManager:show(SpinWidget:new{
                        title_text = _("Margin from edge"),
                        info_text = _("Distance of each line from the screen edge, as a % of screen width."),
                        value = self.margin_percent,     -- starting position of the slider
                        value_min = 5,                    -- lower bound
                        value_max = 40,                   -- upper bound
                        value_step = 1,                   -- how much one tap of -/+ changes
                        value_hold_step = 5,               -- how much a long-press-drag jumps by (bigger steps)
                        unit = "%",                        -- cosmetic suffix shown next to the number
                        -- callback runs when the user taps "OK" on the popup;
                        -- `spin` is the SpinWidget instance, spin.value is the chosen number
                        callback = function(spin)
                            self.margin_percent = spin.value
                            self:saveSettings()
                            UIManager:setDirty(self.dialog, "ui")
                        end,
                    })
                end,
            },

            -- ---- Thickness slider ----
            {
                text = _("Line thickness"),
                keep_menu_open = true,
                callback = function()
                    UIManager:show(SpinWidget:new{
                        title_text = _("Line thickness"),
                        info_text = _("Thickness of each line, in pixels."),
                        value = self.line_width,
                        value_min = 1,
                        value_max = 20,
                        value_step = 1,
                        callback = function(spin)
                            self.line_width = spin.value
                            self:saveSettings()
                            UIManager:setDirty(self.dialog, "ui")
                        end,
                    })
                end,
            },

            -- ---- Darkness slider ----
            {
                text = _("Line darkness"),
                keep_menu_open = true,
                callback = function()
                    UIManager:show(SpinWidget:new{
                        title_text = _("Line darkness"),
                        info_text = _("1 = light gray, 10 = solid black."),
                        value = self.line_darkness,
                        value_min = 1,
                        value_max = 10,
                        value_step = 1,
                        callback = function(spin)
                            self.line_darkness = spin.value
                            self:saveSettings()
                            UIManager:setDirty(self.dialog, "ui")
                        end,
                    })
                end,
            },

            -- ---- Hide while sleeping toggle ----
            {
                text = _("Hide while sleeping"),
                checked_func = function() return self.hide_when_sleeping end,
                callback = function()
                    self.hide_when_sleeping = not self.hide_when_sleeping
                    self:saveSettings()
                    -- Repaint immediately so the effect (or lack of it) is
                    -- visible right away if we happen to be asleep/standby
                    -- when this is toggled (shouldn't normally happen, but
                    -- cheap to be safe).
                    UIManager:setDirty(self.dialog, "ui")
                end,
            },
        },
    }
end

-- ============================================================
-- Writes all current values into the LuaSettings object (in
-- memory) and flags that we have unsaved changes. We don't
-- write to disk here directly — see onFlushSettings below.
-- ============================================================
function TwoLines:saveSettings()
    self.settings:saveSetting("margin_percent", self.margin_percent)
    self.settings:saveSetting("line_width", self.line_width)
    self.settings:saveSetting("line_darkness", self.line_darkness)
    self.settings:saveSetting("enabled", self.enabled)
    self.settings:saveSetting("hide_when_sleeping", self.hide_when_sleeping)
    self.updated = true -- mark "dirty" so we know to flush to disk
end

-- ============================================================
-- KOReader fires the "FlushSettings" event at natural save
-- points (closing the book, suspending the device, etc). This
-- is the correct place to actually write to disk, rather than
-- doing a disk write on every single slider tap.
-- ============================================================
function TwoLines:onFlushSettings()
    if self.updated then
        self.settings:flush()  -- actually write settings_file to disk
        self.updated = nil     -- reset the dirty flag
    end
end

-- ============================================================
-- Sleep/wake tracking.
--
-- KOReader broadcasts "Suspend"/"Resume" when the device fully
-- sleeps (screen off) and, on newer versions, "EnterStandby"/
-- "LeaveStandby" for the lighter idle "standby" state. We just
-- flip a flag here; paintTo (below) checks it and skips drawing
-- when hide_when_sleeping is on and we're currently asleep.
--
-- I also force a repaint on each transition. This matters
-- specifically for onSuspend: KOReader's screensaver can capture
-- whatever is currently on screen, so Iwant our lines gone
-- from that buffer *before* the capture happens, not just from
-- future paints. (If your screensaver still shows the lines,
-- your KOReader version may capture the screen before this event
-- fires — the toggle is still there as a best-effort option.)
-- ============================================================
function TwoLines:onSuspend()
    self.sleeping = true
    if self.hide_when_sleeping then
        UIManager:setDirty(self.dialog, "ui")
    end
end

function TwoLines:onResume()
    self.sleeping = false
    if self.hide_when_sleeping then
        UIManager:setDirty(self.dialog, "ui")
    end
end

function TwoLines:onEnterStandby()
    self.sleeping = true
    if self.hide_when_sleeping then
        UIManager:setDirty(self.dialog, "ui")
    end
end

function TwoLines:onLeaveStandby()
    self.sleeping = true
    if self.hide_when_sleeping then
        UIManager:setDirty(self.dialog, "ui")
    end
end

-- ============================================================
-- paintTo is called by ReaderView every time it redraws the
-- page.
-- bb = the pixel buffer we draw into; x, y = our offset within
-- whatever container is painting us (0,0 here, since we draw
-- straight onto the full screen buffer).
-- ============================================================
function TwoLines:paintTo(bb, x, y)
    if not self.enabled then return end -- do nothing if the user turned lines off
    if self.hide_when_sleeping and self.sleeping then return end -- do nothing while asleep/standby, if the user opted in

    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    -- Convert our % setting into an actual pixel offset from the edge
    local offset = math.floor(screen_w * (self.margin_percent / 100))

    -- Blitbuffer.gray() takes 0.0 (white) to 1.0 (black).
    -- We store darkness as 1-10 for a friendlier UI, so divide by 10.
    local color = Blitbuffer.gray(self.line_darkness / 10)

    -- Left line: starts `offset` px in from the left edge
    bb:paintRect(offset, 0, self.line_width, screen_h, color)

    -- Right line: mirrored — starts `offset` px in from the right edge.
    -- We subtract line_width too, so the line's outer edge (not its
    -- start point) lines up with the same margin as the left line.
    bb:paintRect(screen_w - offset - self.line_width, 0, self.line_width, screen_h, color)
end

-- Hand the finished plugin table back to KOReader's plugin loader
return TwoLines