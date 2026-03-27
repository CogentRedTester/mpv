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
local unfreed_thumbnails = {}
local handle_counter = 0
local OVERLAY_ID_MIN = 21
local OVERLAY_ID_MAX = 63

-- This will choose which thumbnailer to send requests to.
-- The selection logic is currently unimplemented, instead it sends it to
-- the first thumbnailer in the table.
local function choose_thumbnailer(path)
    local thumbnailers = mp.get_property_native('user-data/mpv/thumbnailers')

    -- temporary
    return next(thumbnailers)
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

    local thumbnailer = choose_thumbnailer(opts.path)
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