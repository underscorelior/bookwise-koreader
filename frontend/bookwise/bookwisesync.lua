--[[--
Bookwise reading sync module for ReaderUI.

Handles position restore, XP tracking, and periodic progress sync
for books downloaded from Bookwise.

Registered as a ReaderUI module — becomes a no-op for non-Bookwise books.
]]

local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local DataStorage = require("datastorage")
local Device = require("device")
local Event = require("ui/event")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local Screen = Device.screen
local BookwiseApi = require("bookwise/bookwiseapi")

local BookwiseSync = InputContainer:extend{
    name = "bookwise_sync",
    ui = nil,
    document = nil,
    _active = false,
    _api = nil,
    _settings = nil,
    _tracked_book_id = nil,
    _document_id = nil,
    _word_count = 0,
    _last_synced_progress = -1,
    _previous_scroll_depth = nil,    -- server's last known position, for reversePatch
    _xp_total = nil,
    _xp_at_last_sync = nil,
    _session_xp = 0,
    _max_progress_reached = 0,       -- highest scroll depth seen (anti-gaming)
    _last_page_progress = nil,
    _restored = false,
    _periodic_sync_func = nil,       -- function ref for timer cleanup
    _pending_sync = false,
    _xp_notif = nil,
}

function BookwiseSync:init()
    local settings_file = DataStorage:getSettingsDir() .. "/bookwise.lua"
    self._settings = LuaSettings:open(settings_file)

    local session_id = self._settings:readSetting("session_id")
    if not session_id then return end

    local doc_path = self.ui.document and self.ui.document.file
    if not doc_path then return end

    -- Look up book metadata (try absolute path, then relative)
    local book_info = self._settings:readSetting("book_map_" .. doc_path)
    if not book_info then
        local rel_path = doc_path:match(".-(bookwise%-books/.+)$")
        if rel_path then
            book_info = self._settings:readSetting("book_map_./" .. rel_path)
        end
    end
    if not book_info then return end

    self._active = true
    self._tracked_book_id = book_info.tracked_book_id
    self._document_id = book_info.document_id
    self._word_count = book_info.word_count or 0

    self._api = BookwiseApi:new{
        session_id = session_id,
        server_url = self._settings:readSetting("server_url", "https://readwise.io"),
        debug = self._settings:readSetting("debug_mode") and true or false,
    }

    logger.info("BookwiseSync: active for", doc_path, "tracked_id=", self._tracked_book_id)

    if self.ui.menu and self.ui.menu.registerToMainMenu then
        self.ui.menu:registerToMainMenu(self)
    end
end

function BookwiseSync:_showBottomNotification(text, timeout)
    timeout = timeout or 2
    local text_w = TextWidget:new{
        text = text,
        face = Font:getFace("x_smallinfofont"),
    }
    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.default,
        radius = 0,
        margin = Size.margin.default,
        padding = Size.padding.default,
        text_w,
    }
    local bottom = BottomContainer:new{
        dimen = Screen:getSize(),
        frame,
    }

    if self._xp_notif then
        UIManager:close(self._xp_notif)
    end

    self._xp_notif = bottom
    UIManager:show(bottom, "ui")
    UIManager:scheduleIn(timeout, function()
        if self._xp_notif == bottom then
            UIManager:close(bottom, "ui")
            self._xp_notif = nil
        end
    end)
end

-- Scroll depth (0-1) matching the Bookwise phone app.
-- EPUBs: content position / full height. PDFs: page / total pages.
function BookwiseSync:_getScrollDepth()
    if not self.ui.document then return nil end
    if self.ui.rolling then
        local doc_height = self.ui.document.info and self.ui.document.info.doc_height
        if doc_height and doc_height > 0 then
            local pos = self.ui.document:getCurrentPos()
            if pos then
                return math.min(1.0, math.max(0, pos / doc_height))
            end
        end
    end
    local current = self.ui.document:getCurrentPage()
    local total = self.ui.document:getPageCount()
    if current and total and total > 0 then
        return current / total
    end
    return nil
end

function BookwiseSync:_gotoScrollDepth(target)
    if not self.ui.document then return end
    if self.ui.rolling then
        self.ui:handleEvent(Event:new("GotoPercent", target * 100))
    else
        local total = self.ui.document:getPageCount()
        if total and total > 0 then
            local page = math.max(1, math.min(total, math.floor(target * total + 0.5)))
            self.ui:handleEvent(Event:new("GotoPage", page))
        end
    end
end

function BookwiseSync:onReaderReady()
    if not self._active then return end
    self:_fetchAndRestore()
    self:_startPeriodicSync()
end

function BookwiseSync:_fetchAndRestore()
    if not self._api.session_id then return end

    NetworkMgr:runWhenOnline(function()
        self._api:getExperience(function(ok, xp)
            if ok then
                self._xp_total = math.floor(xp)
                self._xp_at_last_sync = self._xp_total
                logger.info("BookwiseSync: XP=", self._xp_total)
            end
        end)

        self._api:getLibrary(function(ok, books)
            if not ok then return end
            for _i, book in ipairs(books) do
                if book.id == self._tracked_book_id then
                    local target_progress = book.progress or 0
                    logger.info("BookwiseSync: server progress=", target_progress)
                    self._previous_scroll_depth = target_progress
                    self._max_progress_reached = target_progress

                    if (not self._word_count or self._word_count == 0) and book.word_count then
                        self._word_count = book.word_count
                        local doc_path = self.ui.document and self.ui.document.file
                        if doc_path then
                            local binfo = self._settings:readSetting("book_map_" .. doc_path)
                            if binfo then
                                binfo.word_count = book.word_count
                                self._settings:saveSetting("book_map_" .. doc_path, binfo)
                                self._settings:flush()
                            end
                        end
                    end

                    if target_progress > 0.01 then
                        self:_restorePosition(target_progress)
                    end
                    break
                end
            end
        end)
    end)
end

function BookwiseSync:_restorePosition(target_progress)
    local delays = {0.5, 1.5, 3.0}
    for _i, delay in ipairs(delays) do
        UIManager:scheduleIn(delay, function()
            if self._restored then return end
            if not self.ui.document then return end
            local current_depth = self:_getScrollDepth()
            if current_depth then
                self._restored = true
                if math.abs(current_depth - target_progress) > 0.01 then
                    logger.info("BookwiseSync: restoring to", string.format("%.1f%%", target_progress * 100),
                        "from", string.format("%.1f%%", current_depth * 100))
                    self:_gotoScrollDepth(target_progress)
                end
                -- Sync max_progress from actual rendered position after restore
                UIManager:scheduleIn(0.5, function()
                    local actual = self:_getScrollDepth()
                    if actual then
                        self._max_progress_reached = actual
                        self._last_page_progress = actual
                    end
                end)
            end
        end)
    end
end

function BookwiseSync:onPageUpdate()
    if not self._active then return end
    if not self.ui.document then return end
    if not self._document_id then return end

    local progress = self:_getScrollDepth()
    if not progress then return end

    if not self._last_page_progress then
        self._last_page_progress = progress
        self._max_progress_reached = math.max(self._max_progress_reached, progress)
        return
    end

    -- Only award XP for pages beyond the furthest point reached (no gaming by flipping back)
    -- 0.001 tolerance for floating point after position restore
    if progress > self._max_progress_reached + 0.001 then
        -- Count actual words on the current page
        local words_this_page = 0
        if self.view and self.view.getCurrentPageLineWordCounts then
            local _lines, word_count = self.view:getCurrentPageLineWordCounts()
            words_this_page = word_count or 0
        end
        -- Fallback to estimate if page text extraction failed
        if words_this_page == 0 and self._word_count > 0 then
            local delta = progress - self._max_progress_reached
            words_this_page = math.floor(delta * self._word_count)
        end
        if words_this_page > 0 then
            self._session_xp = self._session_xp + words_this_page
            if self._xp_total then
                self._xp_total = self._xp_total + words_this_page
            end
            self:_showBottomNotification(
                string.format("+%d xp (%d this session)", words_this_page, self._session_xp), 1.5)
        end
        self._max_progress_reached = progress
    end

    self._last_page_progress = progress
    self._pending_sync = true
end

function BookwiseSync:_doSync()
    if not self._active then return end
    if not self.ui.document then return end
    if not self._document_id then return end

    local progress = self:_getScrollDepth()
    if not progress then return end
    if math.abs(progress - self._last_synced_progress) < 0.005 then return end

    self._last_synced_progress = progress

    local xp_total_for_event
    if self._xp_total and self._xp_total > (self._xp_at_last_sync or 0) then
        xp_total_for_event = self._xp_total
    end

    logger.info("BookwiseSync: syncing", string.format("%.4f", progress),
        "total_xp=" .. (self._xp_total or 0), "session=" .. self._session_xp)

    if NetworkMgr:isOnline() then
        self._api:syncReadingProgress(self._document_id, progress, self._previous_scroll_depth,
            xp_total_for_event, self._xp_at_last_sync,
            function(ok, result)
                if ok then
                    logger.info("BookwiseSync: sync succeeded")
                    self._previous_scroll_depth = progress
                    self._xp_at_last_sync = self._xp_total
                    self._pending_sync = false
                else
                    logger.warn("BookwiseSync: sync failed:", result)
                    self._pending_sync = true
                end
            end)
    else
        self._pending_sync = true
    end
end

function BookwiseSync:_startPeriodicSync()
    local function periodicSync()
        if not self._active then return end
        if not self.ui.document then return end
        if self._pending_sync then
            self:_doSync()
        end
        UIManager:scheduleIn(30, periodicSync)
    end
    self._periodic_sync_func = periodicSync
    UIManager:scheduleIn(15, periodicSync)
end

function BookwiseSync:onCloseDocument()
    if not self._active then return end
    logger.info("BookwiseSync: final sync on close")

    self._active = false -- prevent periodic timer from re-firing

    self:_doSync()

    -- If still offline, retry when connectivity returns
    if self._pending_sync then
        local api = self._api
        local document_id = self._document_id
        local progress = self._last_synced_progress
        local prev = self._previous_scroll_depth
        local xp_total = self._xp_total
        local xp_prev = self._xp_at_last_sync
        NetworkMgr:runWhenOnline(function()
            api:syncReadingProgress(document_id, progress, prev, xp_total, xp_prev,
                function(ok)
                    if ok then
                        logger.info("BookwiseSync: deferred sync succeeded")
                    end
                end)
        end)
    end

    if self._periodic_sync_func then
        UIManager:unschedule(self._periodic_sync_func)
    end
end

function BookwiseSync:addToMainMenu(menu_items)
    if not self._active then return end
    menu_items.bookwise_library = {
        text = _("Bookwise Library"),
        callback = function()
            local BookwiseLibrary = require("bookwise/bookwiselibrary")
            self.ui:handleEvent(Event:new("Close"))
            BookwiseLibrary.showLibrary()
        end,
    }
end

return BookwiseSync
