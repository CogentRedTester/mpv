--[[
This file is part of mpv.

mpv is free software; you can redistribute it and/or
modify it under the terms of the GNU Lesser General Public
License as published by the Free Software Foundation; either
version 2.1 of the License, or (at your option) any later version.

mpv is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU Lesser General Public License for more details.

You should have received a copy of the GNU Lesser General Public
License along with mpv.  If not, see <http://www.gnu.org/licenses/>.
]]

local mp = require 'mp'
local utils = require 'mp.utils'
local thumbnail = {}

-- A table of thumbnail-id:overlay-id mappings
local overlay_ids = {}
local thumbnailers = {}
local unfreed_thumbnails = {}
local handle_counter = 0
local OVERLAY_ID_MIN = 21
local OVERLAY_ID_MAX = 63
local PLATFORM = mp.get_property("platform")

-- Maintains a sorted list of thumbnailers
mp.observe_property("user-data/mpv/thumbnailers", "native", function(_, thumbs)
    thumbnailers = {}
    if type(thumbs) ~= "table" then
        return
    end

    for client_name, config in pairs(thumbs) do
        config.client_name = client_name
        table.insert(thumbnailers, config)

        for i, path in ipairs(config.paths or {}) do
            -- We need to use a custom pattern format that can work in both Lua and JS
            config.paths[i] = path:lower()
                                  :gsub("\\[\\%-%*%?%[%]]", {       -- escape (our) special chars
                                    ["\\\\"] = "\0a",   ["\\-"] = "\0b",
                                    ["\\*"] = "\0c",    ["\\?"] = "\0d",
                                    ["\\["] = "\0e",    ["\\]"] = "\0f",
                                    ["\\^"] = "\0g",    ["\\$"] = "\0h",
                                    ["\\+"] = "\0i"
                                  })
                                  :gsub("\\", "")                   -- remove backslashes from anywhere else
                                  :gsub("([%(%)%%%.%-])", "%%%1")   -- escape lua special chars

                                  :gsub("%%%-%%%-", "-")
                                  :gsub("%*%?", "-")
                                  :gsub("([+?])%?", "%1%%?")
                                  :gsub("%[^%]", ".")

                                  :gsub("%z%a", {                   -- Re-add our escaped characters
                                    ["\0a"] = "\\",     ["\0b"] = "%-",
                                    ["\0c"] = "%*",     ["\0d"] = "%?",
                                    ["\0e"] = "%[",     ["\0f"] = "%]",
                                    ["\0g"] = "%^",     ["\0h"] = "%$",
                                    ["\0i"] = "%+"
                                  })
        end
    end

    table.sort(thumbnailers, function(a, b)
            return (tonumber(a.priority) or 50) < (tonumber(b.priority) or 50)
        end)
end)

-- We could theoretically implement caching for this later if performance were a concern.
local function matches_patterns(path, patterns)
    if not patterns then return true end
    if PLATFORM == "windows" then
        path = path:gsub("\\", "/")
    end

    for _, pattern in ipairs(patterns) do
        if string.find(path:lower(), pattern) then
            return true
        end
    end

    return false
end

local function matches_ranges(t, ranges)
    if not ranges then return true end

    for _, range in ipairs(ranges) do
        if t >= range[1] and t <= range[2] then
            return true
        end
    end

    return false
end

local function choose_thumbnailer(path, t)
    if not next(thumbnailers) then return nil end

    local current_file = mp.get_property("path")
    path = path or current_file
    if not path then return nil end

    for _, thumbnailer in ipairs(thumbnailers) do
        if (path == current_file or not thumbnailer.current_file_only)
                and matches_patterns(path, thumbnailer.paths)
                and matches_ranges(t, thumbnailer.ranges) then
            return thumbnailer.client_name
        end
    end

    return nil
end

-- Assigns overlay ids in such a way as to minimise the risk of conflicts with
-- other scripts. If the overlay ids were ever made client-specific, this function
-- could be simplified.
local function assign_overlay_id(thumb)
    if overlay_ids[thumb._id] then
        local reservation = mp.get_property_native('user-data/mpv/overlay-ids/'..overlay_ids[thumb._id])
        if reservation == mp.get_script_name() then
            return true
        else
            overlay_ids[thumb._id] = nil
        end
    end

    for i = OVERLAY_ID_MIN, OVERLAY_ID_MAX, 1 do
        local overlay_reservation = 'user-data/mpv/overlay-ids/'..i
        if not mp.get_property(overlay_reservation) then

            -- This is intended to (as far as possible) avoid two scripts from setting the same
            -- overlay id reservation at the same time. Still needs testing to determine if it works.
            mp.commandv('expand-properties', 'set', overlay_reservation,
                        ('${%s:%s}'):format(overlay_reservation, mp.get_script_name()))

            if mp.get_property_native(overlay_reservation) == mp.get_script_name() then
                overlay_ids[thumb._id] = i
                return true
            end
        end
    end

    -- If we reach here then we ran out of available overlay IDs
    return false
end

local function unassign_overlay_id(thumb_id)
    local overlay_reservation = 'user-data/mpv/overlay-ids/'..overlay_ids[thumb_id]
    overlay_ids[thumb_id] = nil

    if mp.get_property_native(overlay_reservation) == mp.get_script_name() then
        mp.del_property(overlay_reservation)
    end
end

local thumbnail_mt = {}
thumbnail_mt.__index = thumbnail_mt

local function clear_thumbnail(thumb_id)
    if not overlay_ids[thumb_id] then return end
    mp.commandv('overlay-remove', overlay_ids[thumb_id])
    unassign_overlay_id(thumb_id)
end

function thumbnail_mt:draw(opts)
    if self._status == 'freed' then
        return false
    end

    if not opts.x and not opts.y then
        clear_thumbnail(self._id)
        return true
    end

    if not assign_overlay_id(self) then
        return false
    end

    mp.command_native({
        name = 'overlay-add',
        id = overlay_ids[self._id],
        x = opts.x,
        y = opts.y,
        file = self._thumbnail,
        offset = 0,
        fmt = 'bgra',
        w = self.w,
        h = self.h,
        stride = 4 * self.w,
        dw = opts.w,
        dh = opts.h,
    })

    return true
end

-- There is no need to clear the thumbnail from
-- the screen as overlay-add creates a copy of the data.
function thumbnail_mt:free()
    if self._status == 'freed' then return end

    -- deletes the thumbnail file
    os.remove(self._thumbnail)
    self._status = 'freed'
    unfreed_thumbnails[self._uid] = nil
end

local function register_response_handler(opts, cb)
    local handler_id = mp.get_script_name().."/"..handle_counter
    handle_counter = handle_counter + 1

    mp.register_script_message(handler_id, function (response, err)
        mp.unregister_script_message(handler_id)
        response = utils.parse_json(response or '')
        if not response then
            return cb(nil, err)
        end

        local thumb = {
            w = response.w,
            h = response.h,
            _thumbnail = response.thumbnail,
            _status = 'available',
            _id = opts.id,
            _uid = handler_id
        }

        unfreed_thumbnails[handler_id] = thumb
        cb(setmetatable(thumb, thumbnail_mt), err)
    end)

    return handler_id
end

function thumbnail.generate(opts, cb)
    opts.id = opts.id or ''

    local thumbnailer = choose_thumbnailer(opts.path, opts.t)
    if not thumbnailer then
        return false
    end

    local response_handler = register_response_handler(opts, cb)
    mp.commandv('script-message-to', thumbnailer, 'generate-thumbnail', utils.format_json({
        t = opts.t, w = opts.w, h = opts.h,
        path = opts.path, id = mp.get_script_name()..'/'..(opts.id or ''),
        client_name = mp.get_script_name(),
        response_handler = response_handler,
    }))

    return true
end

-- If a client clears the thumbnail, we don't want an in-transit thumbnail
-- response to redraw the image.
local blocked_draws = {}

function thumbnail.draw(opts)
    opts.id = opts.id or ''

    if not opts.x and not opts.y then
        clear_thumbnail(opts.id)
        blocked_draws[opts.id] = true
        return
    end
    blocked_draws[opts.id] = false

    return thumbnail.generate(opts, function(thumb)
        if not thumb then return end
        if not blocked_draws[opts.id] then
            thumb:draw(opts)
        end
        thumb:free()
    end)
end

mp.register_event("shutdown", function()
    for _, thumb in pairs(unfreed_thumbnails) do
        thumb:free()
    end
end)

return thumbnail