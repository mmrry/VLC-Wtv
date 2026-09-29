--[[
Resolve W.tv channel and video URLs to the Amazon IVS HLS stream

 Author: mmrry <sl2007 at yandex dot com>

 Channel: https://w.tv/<nickname>
 Video:   https://w.tv/<nickname>/videos/<streamId>

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
local USER_AGENT  = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                 .. "(KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36"
local IS_WIN      = package.config:sub(1, 1) == "\\"

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
    ":adaptive-livedelay=12000",
    ":http-referrer=https://w.tv/",
}

function probe()
    return (vlc.access == "http" or vlc.access == "https")
        and vlc.path:match("^w%.tv/[%w_%-%.]+") ~= nil
end

local function fail(msg)
    vlc.msg.err("W.tv: " .. msg)
    return {}
end

-- Quote a single shell argument (cmd.exe on Windows, sh elsewhere)
local function quote(str)
    if IS_WIN then
        return '"' .. str:gsub('"', '\\"') .. '"'
    end
    return "'" .. str:gsub("'", "'\\''") .. "'"
end

-- W.tv API is behind a WAF that rejects VLC's own HTTP client (403),
-- so requests go through the system curl with browser-like headers
local function get_json(url)
    local cmd = table.concat({
        "curl -sS --fail --max-time 10",
        "-A", quote(USER_AGENT),
        "-H", quote("Origin: https://w.tv"),
        "-H", quote("Referer: https://w.tv/"),
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

    local obj = require("dkjson").decode(body)
    if type(obj) ~= "table" then
        local reason = body:match("^[^\r\n]+") or "empty response (is curl installed?)"
        return nil, reason .. " [" .. url .. "]"
    end
    return obj, nil
end

-- Resolve nickname -> { userId, nickname }
local function get_profile(nick)
    local obj, err = get_json(PROFILE_API .. "/profiles/by-nickname/" .. nick .. QUERY)
    if not obj then
        return nil, err
    end
    if not (obj.profile and obj.profile.userId) then
        return nil, "channel not found: " .. nick
    end
    return obj.profile, nil
end

-- Build a VLC playlist item from a W.tv
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

    local profile, err = get_profile(nick)
    if not profile then
        return fail(err)
    end

    local obj
    obj, err = get_json(SEARCH_API .. "/channels/" .. profile.userId .. QUERY)
    if not obj then
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

    local profile, err = get_profile(nick)
    if not profile then
        return fail(err)
    end

    local obj
    obj, err = get_json(SEARCH_API .. "/channels/" .. profile.userId .. "/streams" .. QUERY)
    if not obj then
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