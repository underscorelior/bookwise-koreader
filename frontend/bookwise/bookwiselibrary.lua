--[[--
Bookwise Library screen.

Two-line items: cover + bold title + author. Uses the same widget lifecycle
pattern as CoverBrowser's ListMenuItem to avoid _bb nil crashes.
]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local UnderlineContainer = require("ui/widget/container/underlinecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local http = require("socket.http")
local https = require("ssl.https")
local lfs = require("libs/libkoreader-lfs")
local ltn12 = require("ltn12")
local logger = require("logger")
local _ = require("gettext")

local BookwiseApi = require("bookwise/bookwiseapi")
local json = require("dkjson")

local Screen = Device.screen

-- Cover cache
local COVER_CACHE_DIR = DataStorage:getDataDir() .. "/bookwise-covers"
lfs.mkdir(COVER_CACHE_DIR)

local function _getCoverPath(book)
    if not book.id then return nil end
    return COVER_CACHE_DIR .. "/" .. tostring(book.id) .. ".jpg"
end

local function _downloadCovers(books, max_count)
    max_count = max_count or 10
    local count = 0
    for _i, book in ipairs(books) do
        if count >= max_count then break end
        if book.cover_url and book.cover_url ~= "" then
            local path = _getCoverPath(book)
            if path and not lfs.attributes(path) then
                pcall(function()
                    local requester = book.cover_url:match("^https") and https or http
                    local file = io.open(path, "wb")
                    if file then
                        local _, code = requester.request{
                            url = book.cover_url,
                            sink = ltn12.sink.file(file),
                        }
                        if code ~= 200 then os.remove(path) end
                    end
                end)
                count = count + 1
            end
        end
    end
end

------------------------------------------------------------
-- BookwiseMenuItem — modeled after CoverBrowser's ListMenuItem
-- Uses _underline_container pattern with explicit free() lifecycle
------------------------------------------------------------
local BookwiseMenuItem = InputContainer:extend{
    entry = nil,
    dimen = nil,
    menu = nil,
}

function BookwiseMenuItem:init()
    self.ges_events = {
        TapSelect = {
            GestureRange:new{ ges = "tap", range = self.dimen },
        },
    }

    local padding = Size.padding.fullscreen
    local item_height = self.dimen.h
    local inner_height = item_height - Size.line.medium * 2

    local title = self.entry.title or self.entry.text or ""
    local author = self.entry.author or ""
    local status = self.entry.status_tag or ""
    local progress = self.entry.progress_str or ""
    local cover_path = self.entry.cover_path
    local is_bold = self.entry.bold

    local title_face = Font:getFace("smallinfofont")
    local author_face = Font:getFace("x_smallinfofont")
    local info_face = Font:getFace("xx_smallinfofont")

    -- Cover thumbnail
    local cover_width = 0
    local cover_widget = nil
    if cover_path and lfs.attributes(cover_path) then
        local cover_h = inner_height - Size.padding.small * 2
        local cover_w = math.floor(cover_h * 0.7)
        cover_width = cover_w + padding
        local ok, img = pcall(ImageWidget.new, ImageWidget, {
            file = cover_path,
            width = cover_w,
            height = cover_h,
            scale_factor = 0,
            scale_for_dpi = false,
        })
        if ok and img then
            cover_widget = CenterContainer:new{
                dimen = Geom:new{ w = cover_width, h = inner_height },
                img,
            }
        else
            cover_width = 0
        end
    end

    local content_width = self.dimen.w - padding * 2 - cover_width
    local right_width = math.floor(content_width * 0.20)
    local left_width = content_width - right_width

    -- Title — TextWidget (no blitbuffer caching, re-renders every paint, crash-proof)
    local wtitle = TextWidget:new{
        text = title,
        face = title_face,
        bold = is_bold,
        max_width = left_width,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }

    -- Author — TextWidget, separate line
    local wauthors = TextWidget:new{
        text = author,
        face = author_face,
        max_width = left_width,
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }

    local text_group = VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = Size.padding.small },
        wtitle,
        VerticalSpan:new{ width = Size.padding.small },
        wauthors,
    }

    local left_group = HorizontalGroup:new{}
    table.insert(left_group, HorizontalSpan:new{ width = padding })
    if cover_widget then
        table.insert(left_group, cover_widget)
    end
    table.insert(left_group, text_group)

    local left_content = LeftContainer:new{
        dimen = Geom:new{ w = self.dimen.w, h = inner_height },
        left_group,
    }

    -- Right side
    local right_items = VerticalGroup:new{ align = "right" }
    if status ~= "" then
        table.insert(right_items, TextWidget:new{
            text = status,
            face = info_face,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        })
    end
    if progress ~= "" then
        table.insert(right_items, TextWidget:new{
            text = progress,
            face = info_face,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        })
    end

    local right_content = RightContainer:new{
        dimen = Geom:new{ w = self.dimen.w, h = inner_height },
        HorizontalGroup:new{
            right_items,
            HorizontalSpan:new{ width = padding },
        },
    }

    local item_content = OverlapGroup:new{
        dimen = Geom:new{ w = self.dimen.w, h = inner_height },
        left_content,
        right_content,
    }

    self[1] = UnderlineContainer:new{
        dimen = Geom:new{ w = self.dimen.w, h = item_height },
        color = Blitbuffer.COLOR_LIGHT_GRAY,
        item_content,
    }
end

function BookwiseMenuItem:onTapSelect()
    if self.menu and self.entry then
        self.menu:onMenuSelect(self.entry)
    end
    return true
end

------------------------------------------------------------
-- BookwiseMenu: subclass that uses BookwiseMenuItem
------------------------------------------------------------
local BookwiseMenu = Menu:extend{
    items_per_page = 8,
}

function BookwiseMenu:updateItems(select_number, no_recalculate_dimen)
    self.layout = {}
    self.item_group:clear()
    self.page_info:resetLayout()
    self.return_button:resetLayout()
    self.content_group:resetLayout()
    self:_recalculateDimen(no_recalculate_dimen)

    local idx_offset = (self.page - 1) * self.perpage
    for idx = 1, self.perpage do
        local index = idx_offset + idx
        local entry = self.item_table[index]
        if entry == nil then break end

        local item_tmp = BookwiseMenuItem:new{
            dimen = self.item_dimen:copy(),
            entry = entry,
            menu = self,
        }
        table.insert(self.item_group, item_tmp)
        table.insert(self.layout, {item_tmp})
    end

    self:updatePageInfo(select_number)
    self:mergeTitleBarIntoLayout()

    UIManager:setDirty(self.show_parent, function()
        return "ui", self.dimen
    end)
end

-- Let the standard widget cleanup handle everything

------------------------------------------------------------
-- BookwiseLibrary
------------------------------------------------------------
local BookwiseLibrary = InputContainer:extend{
    name = "bookwise_library",
    books = nil,
    api = nil,
    settings = nil,
    download_dir = nil,
}

local LIBRARY_CACHE_FILE = DataStorage:getDataDir() .. "/bookwise-library-cache.json"

local function _cacheLibrary(books)
    pcall(function()
        local file = io.open(LIBRARY_CACHE_FILE, "w")
        if file then file:write(json.encode(books)); file:close() end
    end)
end

local function _loadCachedLibrary()
    local ok, result = pcall(function()
        local file = io.open(LIBRARY_CACHE_FILE, "r")
        if file then
            local content = file:read("*a"); file:close()
            local books = json.decode(content)
            if books and type(books) == "table" then return books end
        end
        return nil
    end)
    if ok then return result end
    return nil
end

local function _ensureFileManager()
    local FileManager = require("apps/filemanager/filemanager")
    if not FileManager.instance then
        local home_dir = G_reader_settings:readSetting("home_dir") or Device.home_dir or lfs.currentdir()
        FileManager:showFiles(home_dir)
    end
end

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

    local function _showWidget(books)
        _downloadCovers(books, 10)
        _ensureFileManager()
        UIManager:show(BookwiseLibrary:new{
            books = books, api = api, settings = settings, download_dir = download_dir,
        })
    end

    local cached = _loadCachedLibrary()
    if cached then
        _showWidget(cached)
        if NetworkMgr:isOnline() then
            api:getLibrary(function(ok, books) if ok then _cacheLibrary(books) end end)
        else
            NetworkMgr:runWhenOnline(function()
                api:getLibrary(function(ok, books) if ok then _cacheLibrary(books) end end)
            end)
        end
        return
    end

    _ensureFileManager()
    UIManager:show(InfoMessage:new{ text = _("Loading library..."), timeout = 2 })
    if NetworkMgr:isOnline() then
        api:getLibrary(function(ok, books)
            if ok then _cacheLibrary(books); _showWidget(books)
            else
                UIManager:show(InfoMessage:new{ text = _("Failed: ") .. tostring(books), timeout = 3 })
                if on_cancel then on_cancel() end
            end
        end)
    else
        NetworkMgr:runWhenOnline(function()
            api:getLibrary(function(ok, books)
                if ok then _cacheLibrary(books); _showWidget(books)
                else
                    UIManager:show(InfoMessage:new{ text = _("Failed: ") .. tostring(books), timeout = 3 })
                    if on_cancel then on_cancel() end
                end
            end)
        end)
    end
end

function BookwiseLibrary:init()
    self.dimen = Screen:getSize()

    self._menu = BookwiseMenu:new{
        title = _("Bookwise"),
        subtitle = _("Library"),
        item_table = self:_buildItemTable(),
        show_parent = self,
        width = self.dimen.w,
        height = self.dimen.h,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function() self:_showOptionsMenu() end,
        onMenuChoice = function(_menu, item) if item.callback then item.callback() end end,
        close_callback = function() end,
    }
    self[1] = self._menu

    if Device:isTouchDevice() then
        local DTAP_ZONE_MENU = G_defaults:readSetting("DTAP_ZONE_MENU")
        self:registerTouchZones({
            {
                id = "bookwise_swipe", ges = "swipe",
                screen_zone = { ratio_x = DTAP_ZONE_MENU.x, ratio_y = DTAP_ZONE_MENU.y,
                    ratio_w = DTAP_ZONE_MENU.w, ratio_h = DTAP_ZONE_MENU.h },
                handler = function(ges)
                    if ges.direction == "south" then self:_openSettingsMenu(); return true end
                end,
            },
            {
                id = "bookwise_tap_menu", ges = "tap",
                screen_zone = { ratio_x = DTAP_ZONE_MENU.x, ratio_y = DTAP_ZONE_MENU.y,
                    ratio_w = DTAP_ZONE_MENU.w, ratio_h = DTAP_ZONE_MENU.h },
                handler = function() self:_openSettingsMenu(); return true end,
            },
        })
    end
end

function BookwiseLibrary:_openSettingsMenu()
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance and FileManager.instance.menu then
        FileManager.instance.menu:onShowMenu()
    end
end

function BookwiseLibrary:_buildItemTable()
    local items = {}
    for _i, book in ipairs(self.books or {}) do
        local title = book.title or "Untitled"
        local author = book.author or ""
        local status_tag = ""
        if book.status == "currently_reading" then status_tag = "Reading"
        elseif book.status == "finished" then status_tag = "Done"
        elseif book.status == "want_to_read" then status_tag = "TBR" end

        local progress_str = ""
        if book.progress and book.progress > 0 then
            progress_str = string.format("%d%%", math.floor(book.progress * 100))
        end

        local local_path = self:_getLocalPath(book)
        local downloaded = local_path and lfs.attributes(local_path) ~= nil
        if downloaded then
            status_tag = status_tag ~= "" and (status_tag .. " \xE2\xAC\x87") or "\xE2\xAC\x87"
        end

        local cover_path = _getCoverPath(book)
        if cover_path and not lfs.attributes(cover_path) then cover_path = nil end

        table.insert(items, {
            text = title, title = title, author = author,
            status_tag = status_tag, progress_str = progress_str,
            cover_path = cover_path,
            bold = (book.status == "currently_reading"),
            book = book,
            callback = function() self:_onSelectBook(book) end,
        })
    end
    return items
end

function BookwiseLibrary:_onSelectBook(book)
    local local_path = self:_getLocalPath(book)
    if local_path and lfs.attributes(local_path) then self:_openBook(local_path); return end
    if not book.document_id then
        UIManager:show(InfoMessage:new{ text = _("No downloadable content."), timeout = 3 }); return
    end
    local dialog
    dialog = ButtonDialog:new{
        title = book.title or "Untitled",
        info_text = (book.author or "") .. "\n" .. string.format("%d%% read", math.floor((book.progress or 0) * 100)),
        buttons = {
            {{ text = _("Download & Read"), callback = function() UIManager:close(dialog); self:_downloadBook(book) end }},
            {{ text = _("Cancel"), callback = function() UIManager:close(dialog) end }},
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
            if not ok then UIManager:show(InfoMessage:new{ text = _("Failed: ") .. tostring(doc), timeout = 3 }); return end
            local parsed_doc_id = doc.parsed_doc_id
            if not parsed_doc_id then UIManager:show(InfoMessage:new{ text = _("No content."), timeout = 3 }); return end
            local dest_path = self:_getLocalPath(book)
            self.api:getRawContent(parsed_doc_id, dest_path, function(dl_ok, dl_err)
                if dl_ok then
                    self.settings:saveSetting("book_map_" .. dest_path, {
                        tracked_book_id = book.id, document_id = book.document_id,
                        title = book.title, word_count = book.word_count or 0,
                    })
                    self.settings:flush()
                    UIManager:show(InfoMessage:new{ text = _("Opening..."), timeout = 1 })
                    UIManager:scheduleIn(0.5, function() self:_openBook(dest_path) end)
                else
                    local msg = tostring(dl_err):match("403") and _("DRM-protected.") or _("Failed: ") .. tostring(dl_err)
                    UIManager:show(InfoMessage:new{ text = msg, timeout = 5 })
                end
            end)
        end)
    end)
end

function BookwiseLibrary:_openBook(path)
    UIManager:close(self)
    require("apps/reader/readerui"):showReader(path)
end

function BookwiseLibrary:_showOptionsMenu()
    local d; d = ButtonDialog:new{ buttons = {
        {{ text = _("Refresh Library"), callback = function() UIManager:close(d); self:_refresh() end }},
        {{ text = _("Logout"), callback = function() UIManager:close(d); self:_logout() end }},
        {{ text = _("Cancel"), callback = function() UIManager:close(d) end }},
    }}
    UIManager:show(d)
end

function BookwiseLibrary:_refresh() UIManager:close(self); BookwiseLibrary.showLibrary(self.api, self.settings) end

function BookwiseLibrary:_logout()
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = _("Logout?"), ok_text = _("Logout"),
        ok_callback = function()
            self.api.session_id = nil; self.settings:delSetting("session_id"); self.settings:flush()
            UIManager:close(self)
        end,
    })
end

function BookwiseLibrary:onClose()
    UIManager:close(self)
    return true
end

function BookwiseLibrary:onExit()
    -- Close ourselves and let the Exit event propagate to FileManager
    UIManager:close(self)
end

return BookwiseLibrary
