--[[--
Bookwise Library screen.

Shows the user's Bookwise library as a card grid with book titles,
authors, status, and progress bars. Handles download and opening.
]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local OverlapGroup = require("ui/widget/overlapgroup")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")

local BookwiseApi = require("bookwise/bookwiseapi")

local Screen = Device.screen

local BookwiseLibrary = InputContainer:extend{
    name = "bookwise_library",
    books = nil,
    api = nil,
    settings = nil,
    download_dir = nil,
    -- Layout
    _page = 1,
    _cols = 2,
    _rows = 3,
    _cards_per_page = 6,
}

function BookwiseLibrary.showLibrary(api, settings, on_cancel)
    local settings_file = DataStorage:getSettingsDir() .. "/bookwise.lua"
    settings = settings or LuaSettings:open(settings_file)
    api = api or BookwiseApi:new{
        session_id = settings:readSetting("session_id"),
        server_url = settings:readSetting("server_url", "https://readwise.io"),
        debug = settings:readSetting("debug_mode") and true or false,
    }
    local download_dir = DataStorage:getDataDir() .. "/bookwise-books"
    lfs.mkdir(download_dir)

    UIManager:show(InfoMessage:new{ text = _("Loading library..."), timeout = 1 })

    NetworkMgr:runWhenOnline(function()
        api:getLibrary(function(ok, books)
            if ok then
                local lib = BookwiseLibrary:new{
                    books = books,
                    api = api,
                    settings = settings,
                    download_dir = download_dir,
                }
                UIManager:show(lib)
            else
                UIManager:show(InfoMessage:new{
                    text = _("Failed to load library: ") .. tostring(books),
                    timeout = 3,
                })
                if on_cancel then on_cancel() end
            end
        end)
    end)
end

function BookwiseLibrary:init()
    self.dimen = Screen:getSize()
    self._page = 1
    self._total_pages = math.max(1, math.ceil(#(self.books or {}) / self._cards_per_page))

    if Device:isTouchDevice() then
        self.ges_events.Swipe = {
            GestureRange:new{ ges = "swipe", range = self.dimen }
        }
        self.ges_events.Tap = {
            GestureRange:new{ ges = "tap", range = self.dimen }
        }
    end

    self:_buildUI()
end

function BookwiseLibrary:_buildUI()
    local margin = Size.margin.default
    local padding = Size.padding.large
    local card_margin = Size.margin.small
    local available_w = self.dimen.w - margin * 2
    local card_w = math.floor((available_w - card_margin * (self._cols - 1)) / self._cols)

    -- Title bar
    local title_bar = TitleBar:new{
        title = _("Bookwise"),
        fullscreen = true,
        width = self.dimen.w,
        with_bottom_line = true,
        left_icon = "appbar.menu",
        left_icon_tap_callback = function()
            self:_showOptionsMenu()
        end,
    }
    local title_h = title_bar:getHeight()

    -- Page indicator
    local page_text = TextWidget:new{
        text = string.format("%d / %d", self._page, self._total_pages),
        face = Font:getFace("x_smallinfofont"),
    }
    local page_indicator = CenterContainer:new{
        dimen = Geom:new{ w = self.dimen.w, h = page_text:getSize().h + Size.padding.small * 2 },
        page_text,
    }
    local page_h = page_indicator:getSize().h

    -- Available height for cards
    local cards_h = self.dimen.h - title_h - page_h - margin * 2
    local card_h = math.floor((cards_h - card_margin * (self._rows - 1)) / self._rows)

    -- Build card grid for current page
    local start_idx = (self._page - 1) * self._cards_per_page + 1
    local card_grid = VerticalGroup:new{ align = "center" }

    for row = 1, self._rows do
        local row_group = HorizontalGroup:new{}
        for col = 1, self._cols do
            local idx = start_idx + (row - 1) * self._cols + (col - 1)
            local book = self.books and self.books[idx]

            if col > 1 then
                table.insert(row_group, HorizontalSpan:new{ width = card_margin })
            end

            if book then
                table.insert(row_group, self:_buildCard(book, card_w, card_h))
            else
                -- Empty placeholder
                table.insert(row_group, WidgetContainer:new{
                    dimen = Geom:new{ w = card_w, h = card_h },
                })
            end
        end
        if row > 1 then
            table.insert(card_grid, VerticalSpan:new{ width = card_margin })
        end
        table.insert(card_grid, CenterContainer:new{
            dimen = Geom:new{ w = self.dimen.w, h = card_h },
            row_group,
        })
    end

    -- Assemble full layout
    self[1] = FrameContainer:new{
        width = self.dimen.w,
        height = self.dimen.h,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        VerticalGroup:new{
            align = "center",
            title_bar,
            VerticalSpan:new{ width = margin },
            card_grid,
            VerticalSpan:new{ width = margin },
            page_indicator,
        },
    }

    -- Store card positions for tap detection
    self._card_positions = {}
    local y_offset = title_h + margin
    for row = 1, self._rows do
        for col = 1, self._cols do
            local idx = start_idx + (row - 1) * self._cols + (col - 1)
            local x = margin + (col - 1) * (card_w + card_margin)
            local y = y_offset + (row - 1) * (card_h + card_margin)
            if self.books and self.books[idx] then
                table.insert(self._card_positions, {
                    x = x, y = y, w = card_w, h = card_h,
                    book = self.books[idx],
                })
            end
        end
    end
end

function BookwiseLibrary:_buildCard(book, w, h)
    local title = book.title or "Untitled"
    local author = book.author or ""
    local progress = book.progress or 0
    local status = book.status or ""
    local inner_padding = Size.padding.default
    local text_w = w - inner_padding * 2 - Size.border.default * 2

    -- Check if downloaded
    local local_path = self:_getLocalPath(book)
    local downloaded = local_path and lfs.attributes(local_path) ~= nil

    -- Status label
    local status_text = ""
    if status == "currently_reading" then
        status_text = "Reading"
    elseif status == "finished" then
        status_text = "Finished"
    elseif status == "want_to_read" then
        status_text = "To Read"
    end

    local small_face = Font:getFace("xx_smallinfofont")
    local title_face = Font:getFace("smallinfofont")
    local progress_h = Screen:scaleBySize(6)
    -- Reserve ~40% of card height for title, rest for status/author/progress/padding
    local title_h = math.floor(h * 0.45)

    local status_widget = TextWidget:new{
        text = status_text .. (downloaded and "  [saved]" or ""),
        face = small_face,
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }

    -- Title (multi-line, takes up most space)
    local title_widget = TextBoxWidget:new{
        text = title,
        face = title_face,
        width = text_w,
        height = title_h,
        alignment = "left",
        bold = (status == "currently_reading"),
    }

    -- Author
    local author_widget = TextWidget:new{
        text = author,
        face = small_face,
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        max_width = text_w,
    }

    -- Progress bar
    local progress_bar = ProgressWidget:new{
        width = text_w,
        height = progress_h,
        percentage = progress,
        ticks = nil,
        last = nil,
    }

    local card_content = VerticalGroup:new{
        align = "left",
        status_widget,
        VerticalSpan:new{ width = Size.padding.small },
        title_widget,
        VerticalSpan:new{ width = Size.padding.small },
        author_widget,
        VerticalSpan:new{ width = Size.padding.small },
        progress_bar,
    }

    return FrameContainer:new{
        width = w,
        height = h,
        padding = inner_padding,
        margin = 0,
        bordersize = Size.border.default,
        radius = Size.radius.window,
        background = Blitbuffer.COLOR_WHITE,
        card_content,
    }
end

function BookwiseLibrary:onSwipe(_, ges)
    if ges.direction == "west" then
        -- Next page
        if self._page < self._total_pages then
            self._page = self._page + 1
            self:_rebuild()
        end
        return true
    elseif ges.direction == "east" then
        -- Previous page
        if self._page > 1 then
            self._page = self._page - 1
            self:_rebuild()
        end
        return true
    end
end

function BookwiseLibrary:onTap(_, ges)
    if not ges or not ges.pos then return end
    local x, y = ges.pos.x, ges.pos.y
    for _, card in ipairs(self._card_positions or {}) do
        if x >= card.x and x <= card.x + card.w and
           y >= card.y and y <= card.y + card.h then
            self:_onSelectBook(card.book)
            return true
        end
    end
end

function BookwiseLibrary:_rebuild()
    self:_buildUI()
    UIManager:setDirty(self, "ui")
end

function BookwiseLibrary:_onSelectBook(book)
    local local_path = self:_getLocalPath(book)
    if local_path and lfs.attributes(local_path) then
        self:_openBook(local_path, book)
        return
    end

    if not book.document_id then
        UIManager:show(InfoMessage:new{
            text = _("This book has no downloadable content."),
            timeout = 3,
        })
        return
    end

    -- Confirm download
    local dialog
    dialog = ButtonDialog:new{
        title = book.title or "Untitled",
        info_text = (book.author or "") .. "\n" .. string.format("%d%% read", math.floor((book.progress or 0) * 100)),
        buttons = {
            {
                {
                    text = _("Download & Read"),
                    callback = function()
                        UIManager:close(dialog)
                        self:_downloadBook(book)
                    end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function BookwiseLibrary:_getLocalPath(book)
    if not book.document_id then return nil end
    local safe_title = (book.title or "book"):gsub("[^%w%s%-_]", ""):gsub("%s+", "_"):sub(1, 50)
    return self.download_dir .. "/" .. book.document_id .. "_" .. safe_title .. ".epub"
end

function BookwiseLibrary:_downloadBook(book)
    UIManager:show(InfoMessage:new{ text = _("Downloading..."), timeout = 1 })

    NetworkMgr:runWhenOnline(function()
        self.api:getDocument(book.document_id, function(ok, doc)
            if not ok then
                UIManager:show(InfoMessage:new{
                    text = _("Failed: ") .. tostring(doc),
                    timeout = 3,
                })
                return
            end

            local parsed_doc_id = doc.parsed_doc_id
            if not parsed_doc_id then
                UIManager:show(InfoMessage:new{
                    text = _("No downloadable content available."),
                    timeout = 3,
                })
                return
            end

            local dest_path = self:_getLocalPath(book)
            self.api:getRawContent(parsed_doc_id, dest_path, function(dl_ok, dl_err)
                if dl_ok then
                    self.settings:saveSetting("book_map_" .. dest_path, {
                        tracked_book_id = book.id,
                        document_id = book.document_id,
                        title = book.title,
                        word_count = book.word_count or 0,
                    })
                    self.settings:flush()

                    UIManager:show(InfoMessage:new{ text = _("Opening..."), timeout = 1 })
                    UIManager:scheduleIn(0.5, function()
                        self:_openBook(dest_path, book)
                    end)
                else
                    local err_str = tostring(dl_err)
                    local msg = err_str:match("403")
                        and _("DRM-protected, cannot download.")
                        or _("Download failed: ") .. err_str
                    UIManager:show(InfoMessage:new{ text = msg, timeout = 5 })
                end
            end)
        end)
    end)
end

function BookwiseLibrary:_openBook(path, book)
    local ReaderUI = require("apps/reader/readerui")
    UIManager:close(self)
    ReaderUI:showReader(path)
end

function BookwiseLibrary:_showOptionsMenu()
    local dialog
    dialog = ButtonDialog:new{
        buttons = {
            {
                {
                    text = _("Local Files"),
                    callback = function()
                        UIManager:close(dialog)
                        self:_switchToFileManager()
                    end,
                },
            },
            {
                {
                    text = _("Refresh"),
                    callback = function()
                        UIManager:close(dialog)
                        self:_refresh()
                    end,
                },
            },
            {
                {
                    text = _("Logout"),
                    callback = function()
                        UIManager:close(dialog)
                        self:_logout()
                    end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function BookwiseLibrary:_switchToFileManager()
    UIManager:close(self)
    local FileManager = require("apps/filemanager/filemanager")
    local home_dir = G_reader_settings:readSetting("home_dir") or Device.home_dir or lfs.currentdir()
    FileManager:showFiles(home_dir)
end

function BookwiseLibrary:_refresh()
    UIManager:close(self)
    BookwiseLibrary.showLibrary(self.api, self.settings)
end

function BookwiseLibrary:_logout()
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = _("Logout from Bookwise?"),
        ok_text = _("Logout"),
        ok_callback = function()
            self.api.session_id = nil
            self.settings:delSetting("session_id")
            self.settings:flush()
            UIManager:close(self)
            self:_switchToFileManager()
        end,
    })
end

function BookwiseLibrary:onClose()
    UIManager:close(self)
    return true
end

function BookwiseLibrary:paintTo(bb, x, y)
    -- Standard paint
    if self[1] and self[1].paintTo then
        self[1]:paintTo(bb, x, y)
    end
end

function BookwiseLibrary:getSize()
    return self.dimen
end

return BookwiseLibrary
