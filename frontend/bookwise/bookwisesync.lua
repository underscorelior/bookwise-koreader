--[[--
Bookwise reading sync module for ReaderUI.

Handles position restore, XP tracking, and periodic progress sync
for books downloaded from Bookwise.

Registered as a ReaderUI module — becomes a no-op for non-Bookwise books.
]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
local Device = require("device")
local Event = require("ui/event")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local RectSpan = require("ui/widget/rectspan")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local logger = require("logger")
local _ = require("gettext")

local Screen = Device.screen
local BookwiseApi = require("bookwise/bookwiseapi")

local BookwiseSync = InputContainer:extend{
    name = "bookwise_sync",
    ui = nil,
    document = nil,
    -- Internal state
    _active = false,
    _api = nil,
    _settings = nil,
    _book_info = nil,
    _tracked_book_id = nil,
    _document_id = nil,
    _word_count = 0,
    _last_synced_progress = -1,
    _previous_scroll_depth = nil,
    _xp_total = nil,
    _xp_at_last_sync = nil,
    _session_xp = 0,
    _last_page_progress = nil,
    _max_progress_reached = 0,  -- highest progress seen, for anti-gaming
    _restored = false,
    _sync_timer = nil,
    _pending_sync = false,  -- true if we have unsynced data
}

function BookwiseSync:init()
    local settings_file = DataStorage:getSettingsDir() .. "/bookwise.lua"
    self._settings = LuaSettings:open(settings_file)

    local session_id = self._settings:readSetting("session_id")
    if not session_id then return end

    -- Check if current document is a Bookwise book
    local doc_path = self.ui.document and self.ui.document.file
    if not doc_path then return end

    local book_info = self._settings:readSetting("book_map_" .. doc_path)
    if not book_info then
        local rel_path = doc_path:match(".-(bookwise%-books/.+)$")
        if rel_path then
            book_info = self._settings:readSetting("book_map_./" .. rel_path)
        end
    end
    if not book_info then return end

    -- This is a Bookwise book — activate sync
    self._active = true
    self._book_info = book_info
    self._tracked_book_id = book_info.tracked_book_id
    self._document_id = book_info.document_id
    self._word_count = book_info.word_count or 0

    self._api = BookwiseApi:new{
        session_id = session_id,
        server_url = self._settings:readSetting("server_url", "https://readwise.io"),
        debug = self._settings:readSetting("debug_mode") and true or false,
    }

    logger.info("BookwiseSync: active for", doc_path, "tracked_id=", self._tracked_book_id)
end

-- Show a small notification at the bottom of the screen (doesn't cover reading text)
function BookwiseSync:_showBottomNotification(text, timeout)
    timeout = timeout or 2
    local face = Font:getFace("x_smallinfofont")
    local margin = Size.margin.default
    local padding = Size.padding.default

    local text_w = TextWidget:new{ text = text, face = face }
    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        radius = 0,
        margin = margin,
        padding = padding,
        CenterContainer:new{
            dimen = Geom:new{ w = text_w:getSize().w, h = text_w:getSize().h },
            text_w,
        },
    }
    local notif_h = frame:getSize().h

    local widget = InputContainer:extend{}
    local instance = widget:new{
        dimen = Screen:getSize(),
        toast = true,
    }
    instance[1] = VerticalGroup:new{
        align = "center",
        RectSpan:new{
            width = Screen:getWidth(),
            height = Screen:getHeight() - notif_h - margin,
        },
        frame,
    }

    function instance:getSize()
        return self.dimen
    end
    function instance:paintTo(bb, x, y)
        if self[1] and self[1].paintTo then
            self[1]:paintTo(bb, x, y)
        end
    end

    UIManager:show(instance, "ui")
    UIManager:scheduleIn(timeout, function()
        UIManager:close(instance)
    end)
end

function BookwiseSync:onReaderReady()
    if not self._active then return end
    self:_fetchAndRestore()
    self:_startPeriodicSync()
end

function BookwiseSync:_fetchAndRestore()
    if not self._api.session_id then return end

    NetworkMgr:runWhenOnline(function()
        -- Fetch XP
        self._api:getExperience(function(ok, xp)
            if ok then
                self._xp_total = math.floor(xp)
                self._xp_at_last_sync = self._xp_total
                logger.info("BookwiseSync: XP=", self._xp_total)
            end
        end)

        -- Fetch library for position restore
        self._api:getLibrary(function(ok, books)
            if not ok then return end
            for _i, book in ipairs(books) do
                if book.id == self._tracked_book_id then
                    local target_progress = book.progress or 0
                    logger.info("BookwiseSync: server progress=", target_progress)
                    self._previous_scroll_depth = target_progress
                    self._last_page_progress = target_progress
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
                        logger.info("BookwiseSync: updated word_count=", self._word_count)
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
            local total = self.ui.document:getPageCount()
            if not total or total <= 0 then return end
            local target_page = math.max(1, math.min(total, math.floor(target_progress * total + 0.5)))
            local current = self.ui.document:getCurrentPage()
            if current then
                self._restored = true
                if math.abs(current - target_page) > 1 then
                    logger.info("BookwiseSync: restoring to page", target_page, "/", total)
                    self.ui:handleEvent(Event:new("GotoPage", target_page))
                    UIManager:show(Notification:new{
                        text = _("Bookwise: restored to ") .. string.format("%d%%", math.floor(target_progress * 100)),
                        timeout = 3,
                    })
                end
            end
        end)
    end
end

function BookwiseSync:onPageUpdate()
    if not self._active then return end
    if not self.ui.document then return end
    if not self._document_id then return end

    local current = self.ui.document:getCurrentPage()
    local total = self.ui.document:getPageCount()
    if not current or not total or total <= 0 then return end

    local progress = current / total

    if not self._last_page_progress then
        self._last_page_progress = progress
        self._max_progress_reached = math.max(self._max_progress_reached, progress)
        return
    end

    -- Only award XP for NEW pages (beyond the furthest point reached)
    -- Going back and re-reading pages does not give XP
    if progress > self._max_progress_reached then
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
                string.format("+%d xp (%d this session)", words_this_page, self._session_xp), 2)
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

    local current = self.ui.document:getCurrentPage()
    local total = self.ui.document:getPageCount()
    if not current or not total or total <= 0 then return end

    local progress = current / total
    if math.abs(progress - self._last_synced_progress) < 0.005 then return end

    self._last_synced_progress = progress

    local xp_previous_for_event = self._xp_at_last_sync
    local xp_total_for_event = nil
    if self._xp_total and self._xp_total > (self._xp_at_last_sync or 0) then
        xp_total_for_event = self._xp_total
    end

    logger.info("BookwiseSync: syncing", string.format("%.4f", progress),
        "total_xp=" .. (self._xp_total or 0), "session=" .. self._session_xp)

    -- Try to sync; if offline, queue for later
    if NetworkMgr:isOnline() then
        self._api:syncReadingProgress(self._document_id, progress, self._previous_scroll_depth,
            xp_total_for_event, xp_previous_for_event,
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
        logger.info("BookwiseSync: offline, will sync when back online")
        self._pending_sync = true
    end
end

function BookwiseSync:_startPeriodicSync()
    local function periodicSync()
        if not self._active then return end
        if not self.ui.document then return end

        -- If we have pending data and are now online, sync
        if self._pending_sync then
            self:_doSync()
        end

        self._sync_timer = UIManager:scheduleIn(30, periodicSync)
    end
    self._sync_timer = UIManager:scheduleIn(15, periodicSync)
end

function BookwiseSync:onCloseDocument()
    if not self._active then return end
    logger.info("BookwiseSync: final sync on close")

    -- Try immediate sync
    self:_doSync()

    -- If still pending (offline), schedule a retry when online
    if self._pending_sync then
        local api = self._api
        local document_id = self._document_id
        local progress = self._last_synced_progress
        local prev = self._previous_scroll_depth
        local xp_total = self._xp_total
        local xp_prev = self._xp_at_last_sync
        NetworkMgr:runWhenOnline(function()
            api:syncReadingProgress(document_id, progress, prev, xp_total, xp_prev,
                function(ok, result)
                    if ok then
                        logger.info("BookwiseSync: deferred sync succeeded")
                    else
                        logger.warn("BookwiseSync: deferred sync failed:", result)
                    end
                end)
        end)
    end

    if self._sync_timer then
        UIManager:unschedule(self._sync_timer)
    end
end

-- Menu integration: "Bookwise Library" in reader menu
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
