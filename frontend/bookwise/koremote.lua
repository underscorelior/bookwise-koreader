-- KOReader Remote: file-based command interface for automated testing.
-- Polls /tmp/ko_cmd every second. Writes results to /tmp/ko_result.
-- Commands:
--   dump       — dump UI widget tree with positions and text
--   tap x y    — simulate a touch event at (x, y)
--   menu       — list all top-level menu items with positions

local UIManager = require("ui/uimanager")
local Input = require("device").input
local logger = require("logger")

local KORemote = {}

local CMD_FILE = "/tmp/ko_cmd"
local RESULT_FILE = "/tmp/ko_result"

function KORemote.start()
    local function poll()
        local f = io.open(CMD_FILE, "r")
        if f then
            local cmd = f:read("*a"):gsub("%s+$", "")
            f:close()
            os.remove(CMD_FILE)

            local ok, result = pcall(KORemote.execute, cmd)
            local out = ok and result or ("ERROR: " .. tostring(result))

            local rf = io.open(RESULT_FILE, "w")
            if rf then
                rf:write(out)
                rf:close()
            end
        end
        UIManager:scheduleIn(1, poll)
    end
    UIManager:scheduleIn(2, poll)
end

function KORemote.execute(cmd)
    if cmd == "dump" then
        return KORemote.dumpUI()
    elseif cmd:match("^tap ") then
        local x, y = cmd:match("^tap (%d+) (%d+)")
        if x and y then
            return KORemote.simulateTap(tonumber(x), tonumber(y))
        end
        return "Usage: tap <x> <y>"
    else
        return "Unknown command: " .. cmd .. "\nAvailable: dump, tap <x> <y>"
    end
end

function KORemote.dumpUI()
    local lines = {}
    local stack = UIManager._window_stack
    if not stack then
        return "No window stack found"
    end

    for i = #stack, 1, -1 do
        local win = stack[i]
        local widget = win.widget
        if widget then
            KORemote.walkWidget(widget, 0, lines)
            table.insert(lines, "---")
        end
    end
    return table.concat(lines, "\n")
end

function KORemote.walkWidget(widget, depth, lines)
    if not widget then return end
    local indent = string.rep("  ", depth)
    local name = widget.name or widget.id or tostring(widget):match("table: (.+)") or "?"

    -- Get widget class name
    local class = ""
    if widget.extend then
        -- It's a class instance; try to get its name
        local mt = getmetatable(widget)
        if mt and mt.__index then
            class = mt.__index.name or ""
        end
    end
    if widget.name then class = widget.name end

    -- Get geometry
    local geom = ""
    local d = widget.dimen
    if d then
        geom = string.format(" [%d,%d %dx%d]", d.x or 0, d.y or 0, d.w or 0, d.h or 0)
    end

    -- Get text content if available
    local text = ""
    if widget.text and type(widget.text) == "string" and #widget.text > 0 then
        text = string.format(' text="%s"', widget.text:sub(1, 60))
    elseif widget.title and type(widget.title) == "string" then
        text = string.format(' title="%s"', widget.title:sub(1, 60))
    end
    -- Check for text_func
    if widget.text_func and not widget.text then
        local ok, t = pcall(widget.text_func)
        if ok and t then
            text = string.format(' text_func="%s"', tostring(t):sub(1, 60))
        end
    end

    -- Check if it's a menu item with callback
    local has_callback = widget.callback and " [tappable]" or ""

    local line = indent .. class .. geom .. text .. has_callback
    if #line:gsub("^%s+", "") > 0 then
        table.insert(lines, line)
    end

    -- Walk children: numbered entries and common child containers
    for k, child in ipairs(widget) do
        if type(child) == "table" then
            KORemote.walkWidget(child, depth + 1, lines)
        end
    end

    -- Check item_table for Menu widgets
    if widget.item_table then
        for _, item in ipairs(widget.item_table) do
            if type(item) == "table" then
                local item_text = item.text or ""
                if item.text_func then
                    local ok, t = pcall(item.text_func)
                    if ok and t then item_text = tostring(t) end
                end
                local item_geom = ""
                if item.dimen then
                    item_geom = string.format(" [%d,%d %dx%d]", item.dimen.x or 0, item.dimen.y or 0, item.dimen.w or 0, item.dimen.h or 0)
                end
                table.insert(lines, indent .. "  ITEM: " .. item_text .. item_geom)
            end
        end
    end
end

function KORemote.simulateTap(x, y)
    local Event = require("ui/event")
    local Geom = require("ui/geometry")
    local pos = Geom:new{ x = x, y = y, w = 0, h = 0 }
    local tap_event = Event:new("Gesture", {
        ges = "tap",
        pos = pos,
        time = require("ui/time"):now(),
    })
    UIManager:sendEvent(tap_event)
    return string.format("Tapped at %d, %d", x, y)
end

return KORemote
