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
local json = require("dkjson")
local logger = require("logger")
local _ = require("gettext")

local QUEUE_FILE = DataStorage:getSettingsDir() .. "/bookwise-events-queue.json"

local function _readQueue()
    local file = io.open(QUEUE_FILE, "r")
    if not file then return {} end
    local content = file:read("*a"); file:close()
    if not content or content == "" then return {} end
    local ok, result = pcall(json.decode, content)
    if ok and type(result) == "table" then return result end
    return {}
end

local function _writeQueue(queue)
    local file = io.open(QUEUE_FILE, "w")
    if not file then return false end
    local ok, encoded = pcall(json.encode, queue)
    if ok then file:write(encoded) end
    file:close()
    return ok
end

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
    _xp_notif = nil,
    _event_queue = nil,              -- in-memory queue, mirrored to QUEUE_FILE
    _book_state_key = nil,           -- "book_state_<document_id>" — local position cache
    _draining = false,               -- guard against re-entrant drains
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
    self._book_state_key = "book_state_" .. tostring(self._document_id)

    self._api = BookwiseApi:new{
        session_id = session_id,
        server_url = self._settings:readSetting("server_url", "https://readwise.io"),
        debug = self._settings:readSetting("debug_mode") and true or false,
    }

    -- Load any pending events from a previous offline session.
    self._event_queue = _readQueue()

    -- Seed the baseline from the locally cached position so we can sync
    -- correctly even if the kindle opens this book offline. The server-side
    -- value (from getLibrary in onReaderReady) overwrites this when available.
    local cached = self._settings:readSetting(self._book_state_key)
    if cached and cached.scroll_depth then
        self._previous_scroll_depth = cached.scroll_depth
        self._max_progress_reached = cached.scroll_depth
        logger.info("BookwiseSync: loaded cached baseline=",
            string.format("%.4f", cached.scroll_depth),
            "queue_size=", #self._event_queue)
    else
        logger.info("BookwiseSync: no cached baseline, queue_size=", #self._event_queue)
    end

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
            else
                logger.warn("BookwiseSync: getExperience FAILED — XP tracking will retry on first sync")
            end
        end)

        self._api:getLibrary(function(ok, books)
            if not ok then return end
            for _i, book in ipairs(books) do
                if book.id == self._tracked_book_id then
                    local target_progress = book.progress or 0
                    logger.info("BookwiseSync: server progress=", target_progress)
                    -- The server is the source of truth for the chain
                    -- baseline. Don't regress max_progress though, otherwise
                    -- the user could re-earn XP for already-read pages when
                    -- queued offline events haven't drained yet.
                    self._previous_scroll_depth = target_progress
                    self._max_progress_reached = math.max(
                        self._max_progress_reached or 0, target_progress)

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
                -- Only jump if the server is *ahead* of where the kindle is —
                -- e.g. user kept reading on their phone. If the kindle is
                -- ahead (queued offline events haven't drained yet), don't
                -- yank them back to a stale position.
                if target_progress > current_depth + 0.01 then
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
end

-- Persist the latest known position locally so the next session has a baseline
-- even if it opens offline. Updated whenever we queue an event.
function BookwiseSync:_saveBookState(scroll_depth)
    if not self._book_state_key then return end
    self._settings:saveSetting(self._book_state_key, {
        scroll_depth = scroll_depth,
        updated_at = os.time(),
    })
    self._settings:flush()
end

-- Append the new position/XP events to the queue, persist, and try to send.
function BookwiseSync:_doSync()
    if not self.ui.document then return end
    if not self._document_id then return end

    local progress = self:_getScrollDepth()
    if not progress then return end

    local pos_changed = math.abs(progress - self._last_synced_progress) >= 0.005
    if pos_changed then
        if self._previous_scroll_depth == nil then
            -- First-ever sync for this book and we never got a server baseline
            -- (no cache, getLibrary failed). Try one more time before queuing —
            -- otherwise the queued event would have an empty reversePatch and
            -- the backend would record the session as starting from 0%.
            if NetworkMgr:isOnline() then
                logger.info("BookwiseSync: baseline missing — fetching before queueing")
                self._api:getLibrary(function(ok, books)
                    if ok and books then
                        for _i, book in ipairs(books) do
                            if book.id == self._tracked_book_id then
                                self._previous_scroll_depth = book.progress or 0
                                self._max_progress_reached = math.max(
                                    self._max_progress_reached, self._previous_scroll_depth)
                                logger.info("BookwiseSync: recovered baseline=",
                                    self._previous_scroll_depth)
                                break
                            end
                        end
                    end
                    if self._previous_scroll_depth ~= nil then
                        self:_doSync()
                    else
                        logger.warn("BookwiseSync: could not recover baseline, deferring")
                    end
                end)
                return
            else
                -- Offline with no cached baseline — there's nothing safe to
                -- queue. Skip and try again next tick (cache may exist by then,
                -- or wifi may come back).
                logger.warn("BookwiseSync: offline + no baseline, skipping sync")
                return
            end
        end

        -- One-shot retry for XP if the initial getExperience failed.
        if self._session_xp > 0 and not self._xp_total and NetworkMgr:isOnline() then
            logger.info("BookwiseSync: refetching XP before queueing event")
            self._api:getExperience(function(ok, xp)
                if ok then
                    self._xp_total = math.floor(xp) + self._session_xp
                    self._xp_at_last_sync = math.floor(xp)
                    logger.info("BookwiseSync: recovered XP from server:",
                        math.floor(xp), "total now:", self._xp_total)
                end
                self:_doSync()
            end)
            return
        end

        local pos_event = self._api:buildPositionEvent(
            self._document_id, progress, self._previous_scroll_depth)
        table.insert(self._event_queue, pos_event)

        if self._xp_total and self._xp_total > (self._xp_at_last_sync or 0) then
            local xp_event = self._api:buildXpEvent(self._xp_total, self._xp_at_last_sync or 0)
            table.insert(self._event_queue, xp_event)
            self._xp_at_last_sync = self._xp_total
        end

        self._previous_scroll_depth = progress
        self._last_synced_progress = progress

        _writeQueue(self._event_queue)
        self:_saveBookState(progress)

        logger.info("BookwiseSync: queued progress=", string.format("%.4f", progress),
            "queue_size=", #self._event_queue)
    end

    if #self._event_queue > 0 and NetworkMgr:isOnline() then
        self:_drainQueue()
    end
end

-- Send queued events to the server. On success, remove sent events from the
-- queue. Multiple events from a session arrive with their original timestamps,
-- so the backend reconstructs the session correctly.
function BookwiseSync:_drainQueue()
    if self._draining then return end
    if #self._event_queue == 0 then return end
    if not NetworkMgr:isOnline() then return end

    self._draining = true
    local snapshot = {}
    for _, e in ipairs(self._event_queue) do table.insert(snapshot, e) end
    local sent_count = #snapshot

    self._api:postEvents(snapshot, function(ok, result)
        self._draining = false
        if ok then
            -- Drop the prefix we just sent.
            local remaining = {}
            for i = sent_count + 1, #self._event_queue do
                table.insert(remaining, self._event_queue[i])
            end
            self._event_queue = remaining
            _writeQueue(self._event_queue)
            logger.info("BookwiseSync: drained", sent_count, "events; queue=",
                #self._event_queue)
        else
            logger.warn("BookwiseSync: drain failed:", result, "queue=",
                #self._event_queue)
        end
    end)
end

function BookwiseSync:_startPeriodicSync()
    local function periodicSync()
        if not self._active then return end
        if not self.ui.document then return end
        self:_doSync()
        UIManager:scheduleIn(30, periodicSync)
    end
    self._periodic_sync_func = periodicSync
    UIManager:scheduleIn(15, periodicSync)
end

function BookwiseSync:onEndOfBook()
    if not self._active then return end
    if not self._tracked_book_id then return end

    local ButtonDialog = require("ui/widget/buttondialog")
    local InputDialog = require("ui/widget/inputdialog")

    -- Build rating buttons: 1 to 5 stars
    local rating_buttons = {}
    for stars = 1, 5 do
        local label = string.rep("*", stars) .. string.rep(" ", 5 - stars) .. " " .. stars
        table.insert(rating_buttons, {
            {
                text = label,
                callback = function()
                    UIManager:close(self._review_dialog)
                    self:_showReviewText(stars)
                end,
            },
        })
    end
    table.insert(rating_buttons, {
        {
            text = _("Skip"),
            callback = function()
                UIManager:close(self._review_dialog)
                -- Mark as finished without review
                self._api:updateBookStatus(self._tracked_book_id, "finished", function() end)
            end,
        },
    })

    self._review_dialog = ButtonDialog:new{
        title = _("You finished the book!"),
        info_text = _("How would you rate it?"),
        buttons = rating_buttons,
    }
    UIManager:show(self._review_dialog)
end

function BookwiseSync:_showReviewText(rating)
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Write a review (optional)"),
        input_hint = _("What did you think of this book?"),
        input_type = "text",
        buttons = {
            {
                {
                    text = _("Skip"),
                    callback = function()
                        UIManager:close(input_dialog)
                        self:_submitReview(rating, nil)
                    end,
                },
                {
                    text = _("Submit"),
                    is_enter_default = true,
                    callback = function()
                        local review_text = input_dialog:getInputText()
                        UIManager:close(input_dialog)
                        if review_text == "" then review_text = nil end
                        self:_submitReview(rating, review_text)
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function BookwiseSync:_submitReview(rating, description)
    UIManager:show(InfoMessage:new{ text = _("Submitting review..."), timeout = 1 })

    -- Mark book as finished
    self._api:updateBookStatus(self._tracked_book_id, "finished", function() end)

    -- Submit review
    NetworkMgr:runWhenOnline(function()
        self._api:submitReview(self._tracked_book_id, rating, description,
            function(ok, result)
                if ok then
                    UIManager:show(Notification:new{
                        text = _("Review submitted!"),
                        timeout = 2,
                    })
                else
                    logger.warn("BookwiseSync: review failed:", result)
                    UIManager:show(InfoMessage:new{
                        text = _("Failed to submit review."),
                        timeout = 2,
                    })
                end
            end)
    end)
end

function BookwiseSync:onCloseDocument()
    if not self._active then return end
    logger.info("BookwiseSync: final sync on close, queue_size=", #self._event_queue)

    -- Capture the very last position into the queue while the document is
    -- still available (after this method returns the document is torn down).
    self:_doSync()

    self._active = false -- prevent periodic timer from re-firing

    -- If we couldn't drain right now, schedule a one-shot drain when wifi is
    -- back. The queue is also persisted to disk, so even a kindle reboot
    -- won't lose events — the next book open will pick them up.
    if #self._event_queue > 0 then
        local api = self._api
        local queue_snapshot = self._event_queue
        NetworkMgr:runWhenOnline(function()
            api:postEvents(queue_snapshot, function(ok)
                if ok then
                    logger.info("BookwiseSync: deferred drain succeeded for",
                        #queue_snapshot, "events")
                    -- Remove the events we sent from the on-disk queue.
                    local current = _readQueue()
                    local sent = #queue_snapshot
                    local remaining = {}
                    for i = sent + 1, #current do
                        table.insert(remaining, current[i])
                    end
                    _writeQueue(remaining)
                else
                    logger.warn("BookwiseSync: deferred drain failed; events stay queued")
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
