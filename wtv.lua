--[[
Resolve W.tv channel and video URLs to the Amazon IVS HLS stream

 Author: mmrry <sl2007 at yandex dot com>

 Channel: https://w.tv/<nickname>
 Video:   https://w.tv/<nickname>/videos/<streamId>

 HTTP strategy (Windows-friendly, avoids flashing console windows):
   1. VLC's own HTTP client  -> no child process at all
   2. a single PowerShell run -> one hidden window for both requests
   3. curl via io.popen       -> last resort (and the normal path on *nix)

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation; either version 2 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program; if not, write to the Free Software
 Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston MA 02110-1301, USA.
--]]

local PROFILE_API = "https://profiles-service.w.tv/api/v1"
local SEARCH_API  = "https://streams-search-service.w.tv/api/v1"
local QUERY       = "?platform=web"
local ORIGIN      = "https://w.tv"
local REFERER     = "https://w.tv/"
local USER_AGENT  = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                 .. "(KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36"
local IS_WIN      = package.config:sub(1, 1) == "\\"

-- Set to false if VLC's built-in HTTP client starts getting blocked again
local USE_NATIVE_HTTP = true

-- Random per-session device id, as the web client does
math.randomseed(os.time())
local DEVICE_ID = ("xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"):gsub("[xy]", function(c)
    local v = c == "x" and math.random(0, 15) or math.random(8, 11)
    return string.format("%x", v)
end)

-- Start on the source rendition instead of ramping up from 160p.
-- Live delay stays at VLC's default 12 s
-- :adaptive-logic=nearoptimal, predictive, rate, fixedrate, lowest
local OPTIONS = {
    ":adaptive-logic=highest",
    ":adaptive-livedelay=10000",
    ":http-referrer=" .. REFERER,
}

function probe()
    return (vlc.access == "http" or vlc.access == "https")
        and vlc.path:match("^w%.tv/[%w_%-%.]+") ~= nil
end

local function fail(msg)
    vlc.msg.err("W.tv: " .. tostring(msg))
    return {}
end

local function decode(body)
    if type(body) ~= "string" or body == "" then
        return nil
    end
    local ok, obj = pcall(require("dkjson").decode, body)
    if not ok or type(obj) ~= "table" then
        return nil
    end
    return obj
end

local function slurp(path)
    local fh = io.open(path, "rb")
    if not fh then
        return nil
    end
    local data = fh:read("*a")
    fh:close()
    return data
end

-- ---------------------------------------------------------------- native ---
-- VLC's own HTTP stack. Spawns nothing, so there is no window to flicker.
-- The browser-ish identity is forced through libvlc variables, which
-- vlc.stream() inherits.

local http_primed, http_ready = false, false

-- Returns true only if the browser identity could really be applied.
-- Playlist scripts run in a restricted Lua scope where vlc.object / vlc.var
-- are usually absent; without them the request would reach the WAF as plain
-- VLC and get challenged, so the native path is skipped entirely.
local function prime_http()
    if http_primed then
        return http_ready
    end
    http_primed = true

    if type(vlc.object) ~= "table" or type(vlc.object.libvlc) ~= "function"
        or type(vlc.var) ~= "table" or type(vlc.var.set) ~= "function" then
        return false
    end

    local ok, libvlc = pcall(vlc.object.libvlc)
    if not ok or not libvlc then
        return false
    end

    local function force(name, value)
        pcall(vlc.var.create, libvlc, name, value)
        return (pcall(vlc.var.set, libvlc, name, value))
    end

    http_ready = force("http-user-agent", USER_AGENT)
    force("http-referrer", REFERER)
    return http_ready
end

local function native_get(url)
    if not prime_http() then
        return nil
    end

    local ok, s = pcall(vlc.stream, url)
    if not ok or not s then
        return nil
    end

    local parts = {}
    while true do
        local got, chunk = pcall(s.read, s, 65536)
        if not got or not chunk or #chunk == 0 then
            break
        end
        parts[#parts + 1] = chunk
    end

    return decode(table.concat(parts))
end

-- ------------------------------------------------------------ powershell ---
-- One process performs both dependent requests, so Windows shows at most
-- one (hidden) console instead of one per HTTP call.

local function ps_quote(str)
    return "'" .. (tostring(str):gsub("'", "''")) .. "'"
end

local function temp_base()
    local dir = os.getenv("TEMP") or os.getenv("TMP") or "."
    return dir .. "\\vlc-wtv-" .. os.time() .. "-" .. math.random(100000, 999999)
end

local function ps_resolve(nick, suffix)
    local base   = temp_base()
    local script = base .. ".ps1"
    local out1   = base .. ".1.json"
    local out2   = base .. ".2.json"

    local body = table.concat({
        "$ErrorActionPreference = 'Stop'",
        "try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}",
        "function New-Client {",
        "  $w = New-Object Net.WebClient",
        "  $w.Encoding = [Text.Encoding]::UTF8",
        "  $w.Headers.Add('User-Agent', " .. ps_quote(USER_AGENT) .. ")",
        "  $w.Headers.Add('Origin', " .. ps_quote(ORIGIN) .. ")",
        "  $w.Headers.Add('Referer', " .. ps_quote(REFERER) .. ")",
        "  $w.Headers.Add('x-device-id', " .. ps_quote(DEVICE_ID) .. ")",
        "  $w",
        "}",
        "$p = (New-Client).DownloadString("
            .. ps_quote(PROFILE_API .. "/profiles/by-nickname/" .. nick .. QUERY) .. ")",
        "[IO.File]::WriteAllText(" .. ps_quote(out1) .. ", $p, [Text.Encoding]::UTF8)",
        "$id = (ConvertFrom-Json $p).profile.userId",
        "if ($id) {",
        "  $u = " .. ps_quote(SEARCH_API .. "/channels/") .. " + $id + " .. ps_quote(suffix .. QUERY),
        "  $c = (New-Client).DownloadString($u)",
        "  [IO.File]::WriteAllText(" .. ps_quote(out2) .. ", $c, [Text.Encoding]::UTF8)",
        "}",
    }, "\r\n")

    local fh = io.open(script, "wb")
    if not fh then
        return nil, nil, "cannot write temp script"
    end
    fh:write(body)
    fh:close()

    local cmd = 'powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass '
             .. '-WindowStyle Hidden -File "' .. script .. '" 2>&1'

    local log = ""
    local pipe = io.popen(cmd)
    if pipe then
        log = pipe:read("*a") or ""
        pipe:close()
    end

    local profile = decode(slurp(out1))
    local data    = decode(slurp(out2))

    os.remove(script)
    os.remove(out1)
    os.remove(out2)

    if not profile then
        return nil, nil, (log:match("^[^\r\n]+") or "PowerShell request failed")
    end
    return profile, data, nil
end

-- ------------------------------------------------------------------ curl ---

local function quote(str)
    if IS_WIN then
        return '"' .. (str:gsub('"', '\\"')) .. '"'
    end
    return "'" .. (str:gsub("'", "'\\''")) .. "'"
end

local function curl_get(url)
    local cmd = table.concat({
        "curl -sS --fail --max-time 10",
        "-A", quote(USER_AGENT),
        "-H", quote("Origin: " .. ORIGIN),
        "-H", quote("Referer: " .. REFERER),
        "-H", quote("x-device-id: " .. DEVICE_ID),
        quote(url),
        "2>&1",
    }, " ")

    local pipe = io.popen(cmd)
    if not pipe then
        return nil, "failed to run curl"
    end
    local body = pipe:read("*a") or ""
    pipe:close()

    local obj = decode(body)
    if not obj then
        local reason = body:match("^[^\r\n]+") or "empty response (is curl installed?)"
        return nil, reason .. " [" .. url .. "]"
    end
    return obj, nil
end

-- --------------------------------------------------------------- resolver ---
-- suffix: "" for the live channel, "/streams" for the VOD list.
-- Returns profile, payload, error.

local function resolve(nick, suffix)
    local prof_url = PROFILE_API .. "/profiles/by-nickname/" .. nick .. QUERY
    local chan_url = function(id) return SEARCH_API .. "/channels/" .. id .. suffix .. QUERY end

    if USE_NATIVE_HTTP then
        local obj = native_get(prof_url)
        if obj and obj.profile and obj.profile.userId then
            local data = native_get(chan_url(obj.profile.userId))
            if data then
                return obj.profile, data, nil
            end
        end
        vlc.msg.dbg("W.tv: built-in HTTP client refused, falling back to an external one")
    end

    if IS_WIN then
        local obj, data, err = ps_resolve(nick, suffix)
        if obj then
            if not (obj.profile and obj.profile.userId) then
                return nil, nil, "channel not found: " .. nick
            end
            if not data then
                return nil, nil, "empty response from the streams service"
            end
            return obj.profile, data, nil
        end
        vlc.msg.dbg("W.tv: PowerShell path failed (" .. tostring(err) .. "), trying curl")
    end

    local obj, err = curl_get(prof_url)
    if not obj then
        return nil, nil, err
    end
    if not (obj.profile and obj.profile.userId) then
        return nil, nil, "channel not found: " .. nick
    end

    local data, err2 = curl_get(chan_url(obj.profile.userId))
    if not data then
        return nil, nil, err2
    end
    return obj.profile, data, nil
end

-- Build a VLC playlist item from a W.tv stream
local function make_item(stream, channel_name)
    return {
        path        = stream.playbackUrl,
        name        = "W.tv: " .. ((stream.title or "") ~= "" and stream.title or channel_name),
        title       = stream.title,
        artist      = channel_name,
        description = stream.description,
        arturl      = stream.thumbnailUrl,
        date        = stream.startedAt and stream.startedAt:sub(1, 10),
        url         = vlc.path,
        options     = OPTIONS,
    }
end

-- Parser for live channels
local function parse_channel(nick)
    vlc.msg.dbg("W.tv: Loading channel " .. nick)

    local profile, obj, err = resolve(nick, "")
    if not profile then
        return fail(err)
    end

    local channel = obj.channel or {}
    local stream  = channel.liveStream
    local name    = channel.name or profile.nickname
    if not (channel.live and stream and stream.playbackUrl) then
        return fail(name .. " is offline")
    end

    local item = make_item(stream, name)
    item.nowplaying = stream.title
    return { item }
end

-- Parser for VODs
local function parse_video(nick, stream_id)
    vlc.msg.dbg("W.tv: Loading video " .. stream_id)

    local profile, obj, err = resolve(nick, "/streams")
    if not profile then
        return fail(err)
    end

    for _, stream in ipairs(obj.data or {}) do
        if stream.streamId == stream_id then
            if not stream.playbackUrl then
                return fail("video " .. stream_id .. " has no recording")
            end
            local name = stream.channel and stream.channel.name or profile.nickname
            return { make_item(stream, name) }
        end
    end

    return fail("video not found: " .. stream_id)
end

function parse()
    local nick, stream_id = vlc.path:match("^w%.tv/([%w_%-%.]+)/videos/([%x%-]+)")
    if stream_id then
        return parse_video(nick:lower(), stream_id)
    end

    nick = vlc.path:match("^w%.tv/([%w_%-%.]+)")
    return parse_channel(nick:lower())
end
