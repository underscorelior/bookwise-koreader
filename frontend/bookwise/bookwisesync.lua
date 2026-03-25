--[[--
Bookwise reading sync module for ReaderUI.

Handles position restore, XP tracking, and periodic progress sync
for books downloaded from Bookwise.

Registered as a ReaderUI module — becomes a no-op for non-Bookwise books.
]]

local DataStorage = require("datastorage")
local Event = require("ui/event")
local InputContainer = require("ui/widget/container/inputcontainer")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local BookwiseApi = require("bookwise/bookwiseapi")

local BookwiseSync = InputContainer:extend{
    name = "bookwise_sync",
    -- Set by ReaderUI on registration
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
    _restored = false,
    _sync_timer = nil,
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
            for _, book in ipairs(books) do
                if book.id == self._tracked_book_id then
                    local target_progress = book.progress or 0
                    logger.info("BookwiseSync: server progress=", target_progress)
                    self._previous_scroll_depth = target_progress
                    self._last_page_progress = target_progress

                    if (not self._word_count or self._word_count == 0) and book.word_count then
                        self._word_count = book.word_count
                        -- Persist word_count back to settings so future opens have it
                        local doc_path = self.ui.document and self.ui.document.file
                        if doc_path then
                            local book_info = self._settings:readSetting("book_map_" .. doc_path)
                            if book_info then
                                book_info.word_count = book.word_count
                                self._settings:saveSetting("book_map_" .. doc_path, book_info)
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
    for _, delay in ipairs(delays) do
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
        return
    end

    -- Count actual words on the current page using KOReader's built-in method
    local delta = progress - self._last_page_progress
    if delta > 0 then
        local words_this_page = 0
        if self.view and self.view.getCurrentPageLineWordCounts then
            local _, word_count = self.view:getCurrentPageLineWordCounts()
            words_this_page = word_count or 0
        end
        -- Fallback to estimate if page text extraction failed
        if words_this_page == 0 and self._word_count > 0 then
            words_this_page = math.floor(delta * self._word_count)
        end
        if words_this_page > 0 then
            self._session_xp = self._session_xp + words_this_page
            if self._xp_total then
                self._xp_total = self._xp_total + words_this_page
            end
            UIManager:show(Notification:new{
                text = string.format("+%d xp (%d this session)", words_this_page, self._session_xp),
                timeout = 2,
            })
            end
        end
    end
    self._last_page_progress = progress
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

    self._api:syncReadingProgress(self._document_id, progress, self._previous_scroll_depth,
        xp_total_for_event, xp_previous_for_event,
        function(ok, result)
            if ok then
                logger.info("BookwiseSync: sync succeeded")
                self._previous_scroll_depth = progress
                self._xp_at_last_sync = self._xp_total
            else
                logger.warn("BookwiseSync: sync failed:", result)
            end
        end)
end

function BookwiseSync:_startPeriodicSync()
    local function periodicSync()
        if not self._active then return end
        if not self.ui.document then return end
        self:_doSync()
        self._sync_timer = UIManager:scheduleIn(30, periodicSync)
    end
    self._sync_timer = UIManager:scheduleIn(15, periodicSync)
end

function BookwiseSync:onCloseDocument()
    if not self._active then return end
    logger.info("BookwiseSync: final sync on close")
    self:_doSync()
    if self._sync_timer then
        UIManager:unschedule(self._sync_timer)
    end
end

return BookwiseSync
