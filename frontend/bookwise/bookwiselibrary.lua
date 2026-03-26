--[[--
Bookwise Library screen.

Shows the user's Bookwise library as a full-screen list with book titles,
authors, status, and progress. Handles download and opening.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local DataStorage = require("datastorage")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")

local BookwiseApi = require("bookwise/bookwiseapi")

local Screen = Device.screen

local BookwiseLibrary = InputContainer:extend{
    name = "bookwise_library",
    books = nil,
    api = nil,
    settings = nil,
    download_dir = nil,
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

    local item_table = self:_buildItemTable()

    self._menu = Menu:new{
        title = _("Bookwise"),
        item_table = item_table,
        show_parent = self,
        width = self.dimen.w,
        height = self.dimen.h,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function()
            self:_showOptionsMenu()
        end,
        onMenuChoice = function(_menu, item)
            if item.callback then
                item.callback()
            end
        end,
        close_callback = function()
            UIManager:close(self)
        end,
    }

    self[1] = self._menu
end

function BookwiseLibrary:_buildItemTable()
    local items = {}
    for _, book in ipairs(self.books or {}) do
        local title = book.title or "Untitled"
        local author = book.author or ""

        local status_str = ""
        if book.status == "currently_reading" then
            status_str = "[Reading] "
        elseif book.status == "finished" then
            status_str = "[Done] "
        elseif book.status == "want_to_read" then
            status_str = "[TBR] "
        end

        local progress_str = ""
        if book.progress and book.progress > 0 then
            progress_str = string.format("  %d%%", math.floor(book.progress * 100))
        end

        local local_path = self:_getLocalPath(book)
        local downloaded = local_path and lfs.attributes(local_path) ~= nil
        local dl_indicator = downloaded and " *" or ""

        table.insert(items, {
            text = status_str .. title .. dl_indicator,
            mandatory = author .. progress_str,
            book = book,
            callback = function()
                self:_onSelectBook(book)
            end,
        })
    end
    return items
end

function BookwiseLibrary:_onSelectBook(book)
    local local_path = self:_getLocalPath(book)
    if local_path and lfs.attributes(local_path) then
        self:_openBook(local_path)
        return
    end

    if not book.document_id then
        UIManager:show(InfoMessage:new{
            text = _("This book has no downloadable content."),
            timeout = 3,
        })
        return
    end

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
                        self:_openBook(dest_path)
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

function BookwiseLibrary:_openBook(path)
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

return BookwiseLibrary
