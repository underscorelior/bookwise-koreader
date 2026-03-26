local json = require("dkjson")
local logger = require("logger")
local socketutil = require("socketutil")
local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")

local BookwiseApi = {}

function BookwiseApi:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function BookwiseApi:_request(method, path, body, callback)
    local url = self.server_url .. path

    if self.debug then
        local UIManager = require("ui/uimanager")
        local InfoMessage = require("ui/widget/infomessage")
        local debug_text = method .. " " .. path
        if body then
            debug_text = debug_text .. "\n\n" .. json.encode(body, { indent = true }):sub(1, 800)
        end
        UIManager:show(InfoMessage:new{
            text = "API Request:\n" .. debug_text,
            timeout = 8,
        })
    end

    local request_body
    local headers = {
        ["Content-Type"] = "application/json",
        ["Accept"] = "application/json",
    }

    if self.session_id then
        headers["MOBILESESSION"] = self.session_id
    end

    if body then
        request_body = json.encode(body)
        headers["Content-Length"] = tostring(#request_body)
    end

    local response_body = {}
    local request_params = {
        url = url,
        method = method,
        headers = headers,
        sink = socketutil.table_sink(response_body),
    }

    if request_body then
        request_params.source = ltn12.source.string(request_body)
    end

    local requester = url:match("^https") and https or http

    socketutil:set_timeout(10, 30)
    local code
    local ok, err = pcall(function()
        _, code = requester.request(request_params)
    end)
    socketutil:reset_timeout()

    local response_str = table.concat(response_body)

    if self.debug then
        local UIManager = require("ui/uimanager")
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{
            text = string.format("API Response:\n%s %s\nHTTP %s\n\n%s",
                method, path, tostring(code), response_str:sub(1, 500)),
            timeout = 8,
        })
    end

    if not ok then
        logger.warn("Bookwise API error:", err)
        callback(false, tostring(err))
        return
    end

    if code == 200 or code == 201 then
        local result, _, json_err = json.decode(response_str)
        if json_err then
            logger.warn("Bookwise JSON parse error:", json_err)
            callback(false, "JSON parse error")
        else
            callback(true, result)
        end
    else
        logger.warn("Bookwise API HTTP error:", code, response_str)
        callback(false, "HTTP " .. tostring(code) .. ": " .. response_str:sub(1, 200))
    end
end

function BookwiseApi:login(email, password, callback)
    self:_request("POST", "/bookwise/api/login/", {
        email = email,
        password = password,
    }, callback)
end

function BookwiseApi:getLibrary(callback)
    self:_request("GET", "/bookwise/api/tracked_books/pull/?updated_at=1&batch_size=200&id=0", nil, function(ok, result)
        if not ok then
            callback(false, result)
            return
        end
        if not result or not result.documents then
            callback(false, "Unexpected response format")
            return
        end

        local books = {}
        for _, book in ipairs(result.documents) do
            if book.status ~= "deleted" then
                table.insert(books, book)
            end
        end

        table.sort(books, function(a, b)
            local a_reading = a.status == "currently_reading" and 1 or 0
            local b_reading = b.status == "currently_reading" and 1 or 0
            if a_reading ~= b_reading then
                return a_reading > b_reading
            end
            return (a.last_read_at or 0) > (b.last_read_at or 0)
        end)

        callback(true, books)
    end)
end

function BookwiseApi:getDocument(document_id, callback)
    self:_request("GET", "/reader/api/get_document/?id=" .. document_id, nil, function(ok, result)
        if ok and result and result.document then
            callback(true, result.document)
        elseif ok then
            callback(false, "Document not found")
        else
            callback(false, result)
        end
    end)
end

function BookwiseApi:downloadFile(url, dest_path, callback)
    local file = io.open(dest_path, "wb")
    if not file then
        callback(false, "Cannot create file: " .. dest_path)
        return
    end

    local requester = url:match("^https") and https or http

    socketutil:set_timeout(10, 120)
    local ok, err = pcall(function()
        local _, code = requester.request{
            url = url,
            method = "GET",
            headers = {
                ["MOBILESESSION"] = self.session_id or "",
            },
            sink = socketutil.file_sink(file),
        }
        if code ~= 200 then
            error("HTTP " .. tostring(code))
        end
    end)
    socketutil:reset_timeout()

    if ok then
        callback(true)
    else
        os.remove(dest_path)
        logger.warn("Bookwise download error:", err)
        callback(false, tostring(err))
    end
end

function BookwiseApi:getRawContent(parsed_doc_id, dest_path, callback)
    local url = self.server_url .. "/reader/document_raw_content/" .. tostring(parsed_doc_id) .. "/"
    self:downloadFile(url, dest_path, callback)
end

local DEVICE_ENV = {
    agent = { category = "bookwise-koreader", version = "1.0" },
    device = { type = "E-Reader", model = "Kindle Paperwhite", vendor = "Amazon" },
    channel = "koreader",
}

local function make_event_id(timestamp)
    return string.format("%014d%012x", timestamp, math.random(0, 0xffffffffffff))
end

function BookwiseApi:getExperience(callback)
    self:_request("GET", "/reader/api/state/", nil, function(ok, result)
        if ok and result then
            callback(true, result.experience or 0)
        else
            callback(false, result)
        end
    end)
end

function BookwiseApi:syncReadingProgress(document_id, scroll_depth, previous_scroll_depth, xp_total, xp_previous, callback)
    local timestamp = math.floor(os.time() * 1000)
    local pos_event_id = make_event_id(timestamp)
    local doc_path = "/documents/" .. document_id .. "/readingPosition/scrollDepth"

    local pos_reverse_patch = {}
    if previous_scroll_depth then
        pos_reverse_patch = {
            { op = "replace", path = doc_path, value = previous_scroll_depth },
        }
    end

    local events = {
        {
            correlationId = "0." .. pos_event_id,
            dataUpdates = {
                forwardPatch = {
                    { op = "replace", path = doc_path, value = scroll_depth },
                },
                reversePatch = pos_reverse_patch,
                itemsUpdated = {
                    { id = document_id, type = "documents" },
                },
            },
            id = pos_event_id,
            name = "reading-position-updated",
            timestamp = timestamp,
            environment = DEVICE_ENV,
        },
    }

    if xp_total and xp_previous then
        local xp_event_id = make_event_id(timestamp + 1)
        table.insert(events, {
            correlationId = "0." .. xp_event_id,
            dataUpdates = {
                forwardPatch = {
                    { op = "replace", path = "/experience", value = xp_total },
                },
                reversePatch = {
                    { op = "replace", path = "/experience", value = xp_previous },
                },
                itemsUpdated = {},
            },
            id = xp_event_id,
            name = "add-experience-points",
            timestamp = timestamp + 1,
            userInteraction = "null",
            environment = DEVICE_ENV,
        })
    end

    self:_request("POST", "/reader/api/state/update/", {
        events = events,
        schemaVersion = 5,
    }, callback)
end

return BookwiseApi
