-- gallery_view.lua
--
-- Single-file playlist gallery / grid view.
-- Works with local files and URLs.
-- Highlights playing item (cyan) and selection (green, slightly larger).
-- Thumbnails stored in:  <mpv config dir>/thumbnails  (or custom path).
-- Thumbnails are cached by filename/URL across sessions.
-- Type-to-search filter bar at the top (no click; just start typing).
-- DEL removes the selected entry from the playlist (not from disk).
--
-- Commands:
--   script-binding gallery-view-toggle
--   script-message  gallery-view

local mp      = require 'mp'
local utils   = require 'mp.utils'
local msg     = require 'mp.msg'
local assdraw = require 'mp.assdraw'

-- Forward declaration so async callbacks can access the gallery instance
local gallery = nil

--------------------------------------------------------------------------------
-- User options
--------------------------------------------------------------------------------

local opts = {
    thumb_width        = 320,   -- visible image width
    thumb_height       = 180,   -- visible image height
    margin_x           = 40,    -- gallery margin from left/right
    margin_y           = 60,    -- gallery margin from top/bottom
    spacing_x          = 20,    -- horizontal spacing between cells
    spacing_y          = 20,    -- extra vertical spacing between cells
    text_size          = 18,    -- label text size
    max_label_chars    = 30,    -- truncate non-selected labels to this many chars
    thumb_time         = 60,    -- seconds into file for thumbnail (0 = first frame)
    max_thumbnails     = 90,    -- max grid cells displayed at once
    thumbs_dir         = "",    -- custom thumbnails dir; "" => <mpv-config>/thumbnails
}

(require 'mp.options').read_options(opts, "gallery_view")

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function file_exists(path)
    local info = utils.file_info(path)
    return info ~= nil and info.is_file
end

local function ensure_dir(path)
    local st = utils.file_info(path)
    if st and st.is_dir then return true end

    if utils.mkdir then
        local ok = pcall(utils.mkdir, path)
        if ok then
            st = utils.file_info(path)
            return st and st.is_dir
        end
    end

    local sep = package.config:sub(1,1)
    if sep == '\\' then
        utils.subprocess({ args = { "cmd", "/C", "mkdir", path }, cancellable = false })
    else
        utils.subprocess({ args = { "mkdir", "-p", path }, cancellable = false })
    end

    st = utils.file_info(path)
    return st and st.is_dir
end

local function safe_filename(path)
    -- Use full filename / URL, but sanitized so different folders/URLs differ.
    return (path or "item"):gsub("[^%w%-_%.]", "_")
end

local function is_url(path)
    return path and path:match("^https?://")
end

local video_ext = {
    mkv=true, webm=true, mp4=true, avi=true,
    wmv=true, mov=true, flv=true, m4v=true
}

local function is_video(path)
    local ext = path and path:match("%.([^.]+)$")
    if not ext then return false end
    return video_ext[ext:lower()] or false
end

local function shorten(text, max_chars)
    if not text then return "" end
    if #text <= max_chars then return text end
    return text:sub(1, max_chars - 1) .. "…"
end

--------------------------------------------------------------------------------
-- Thumbnail job queue (background, LIFO, async)
--------------------------------------------------------------------------------

local thumb_jobs        = {}   -- stack: newest jobs first
local thumb_jobs_by_out = {}   -- set: output_path -> true
local thumb_failed      = {}   -- set: output_path -> true (won't retry this run)
local active_thumb_job  = nil  -- currently running async job (or nil)

local start_next_thumb  -- forward declaration

local function pop_thumb_job()
    if #thumb_jobs == 0 then return nil end
    local job = table.remove(thumb_jobs, 1)
    thumb_jobs_by_out[job.out] = nil
    return job
end

local function clear_thumb_jobs()
    thumb_jobs        = {}
    thumb_jobs_by_out = {}
    -- keep thumb_failed so we don't retry obviously bad files/URLs
end

local function enqueue_thumb_job(job)
    if not job or not job.out then return end
    if thumb_failed[job.out]      then return end
    if thumb_jobs_by_out[job.out] then return end
    table.insert(thumb_jobs, 1, job)       -- LIFO: newest first
    thumb_jobs_by_out[job.out] = true
    if active_thumb_job == nil then
        start_next_thumb()
    end
end

-- Async ffmpeg via mp.command_native_async({name="subprocess", ...})
local function run_ffmpeg_async(job, ss_time, is_second_try)
    local input_path  = job.input
    local width       = job.w
    local height      = job.h
    local output_path = job.out
    local tmp_out     = output_path .. ".tmp"

    local vf = string.format(
        "scale=iw*min(1\\,min(%d/iw\\,%d/ih)):-2," ..
        "pad=%d:%d:(%d-iw)/2:(%d-ih)/2:color=0x00000000",
        width, height, width, height, width, height
    )

    local args = {
        "ffmpeg",
        "-hide_banner",
        "-loglevel", "fatal",
        "-nostdin",
    }

    if ss_time and ss_time > 0 then
        table.insert(args, "-ss")
        table.insert(args, tostring(ss_time))
    end

    table.insert(args, "-i")
    table.insert(args, input_path)
    table.insert(args, "-vf")
    table.insert(args, vf)
    table.insert(args, "-map")
    table.insert(args, "v:0")
    table.insert(args, "-frames:v")
    table.insert(args, "1")
    table.insert(args, "-f")
    table.insert(args, "rawvideo")
    table.insert(args, "-pix_fmt")
    table.insert(args, "bgra")
    table.insert(args, "-y")
    table.insert(args, tmp_out)

    -- We ignore async callback arguments and instead check the file directly.
    mp.command_native_async({
        name = "subprocess",
        args = args,
        playback_only = false,
    }, function(_, _)
        if not active_thumb_job or active_thumb_job ~= job then
            if file_exists(tmp_out) then os.remove(tmp_out) end
            return
        end

        local ok = false
        if file_exists(tmp_out) then
            local info = utils.file_info(tmp_out)
            ok = info and info.is_file and info.size > 0
        end

        if not ok and not is_second_try and ss_time and ss_time > 0 then
            -- Retry at t=0 once.
            run_ffmpeg_async(job, 0, true)
            return
        end

        if ok then
            os.rename(tmp_out, output_path)
        else
            if file_exists(tmp_out) then os.remove(tmp_out) end
            thumb_failed[output_path] = true
        end

        active_thumb_job = nil

        if not ok or not file_exists(output_path) then
            if gallery and gallery.active then
                start_next_thumb()
            end
            return
        end

        if gallery and gallery.active then
            local gg = gallery.geometry
            for view_index = 1, gg.rows * gg.columns do
                local item_index = gallery.view.first + view_index - 1
                if item_index == job.item_index then
                    gallery:show_overlay(view_index, output_path)
                end
            end
            gallery:ass_refresh(false, false, true, false)
            start_next_thumb()
        end
    end)
end

start_next_thumb = function()
    if active_thumb_job or not gallery or not gallery.active then return end
    local job = pop_thumb_job()
    if not job then return end
    active_thumb_job = job
    local ss_time = 0
    if not is_url(job.input) and is_video(job.input) and job.time and job.time > 0 then
        ss_time = job.time
    end
    run_ffmpeg_async(job, ss_time, false)
end

--------------------------------------------------------------------------------
-- Core gallery implementation (trimmed from gallery.lua)
--------------------------------------------------------------------------------

local gallery_mt = {}
gallery_mt.__index = gallery_mt

local function gallery_new()
    local g = setmetatable({
        items = {},
        item_to_overlay_path     = function(index, item) return "" end,
        item_to_thumbnail_params = function(index, item) return "", 0 end,
        item_to_text             = function(index, item) return "", true end,
        item_to_border           = function(index, item) return 0, "" end,
        ass_show                 = function(ass) end,

        image_w = opts.thumb_width,
        image_h = opts.thumb_height,

        config = {
            background_color        = '333333',
            background_opacity      = '33',
            background_roundness    = 5,
            scrollbar               = true,
            scrollbar_left_side     = false,
            scrollbar_min_size      = 10,
            overlay_range           = 20,
            max_thumbnails          = opts.max_thumbnails,
            show_placeholders       = true,
            placeholder_color       = '222222',
            text_size               = opts.text_size,
        },

        active   = false,
        geometry = {
            ok               = false,
            position         = { 0, 0 },
            size             = { 0, 0 },
            min_spacing      = { 0, 0 },
            thumbnail_size   = { 0, 0 }, -- cell size (image + text)
            rows             = 0,
            columns          = 0,
            effective_spacing = { 0, 0 },
        },
        view = {
            first = 0,
            last  = 0,
        },
        overlays = {
            active  = {},
        },
        selection = nil,
        ass = {
            background   = "",
            selection    = "",
            scrollbar    = "",
            placeholders = "",
            searchbar    = "",
        },

        search_query = "",
    }, gallery_mt)

    for i = 1, g.config.max_thumbnails do
        g.overlays.active[i] = false
    end
    return g
end

function gallery_mt:view_index_position(index_0)
    local gg = self.geometry
    return math.floor(
        gg.position[1] + gg.effective_spacing[1] +
        (gg.effective_spacing[1] + gg.thumbnail_size[1]) * (index_0 % gg.columns)
    ), math.floor(
        gg.position[2] + gg.effective_spacing[2] +
        (gg.effective_spacing[2] + gg.thumbnail_size[2]) * math.floor(index_0 / gg.columns)
    )
end

function gallery_mt:show_overlay(view_index, thumb_path)
    local gg = self.geometry
    self.overlays.active[view_index] = thumb_path
    local index_0 = view_index - 1
    local x, y = self:view_index_position(index_0)

    local iw = self.image_w
    local ih = self.image_h

    if iw <= 0 or ih <= 0 then return end
    if not file_exists(thumb_path) then return end

    mp.commandv("overlay-add",
        tostring(index_0 + self.config.overlay_range),
        tostring(math.floor(x + 0.5)),
        tostring(math.floor(y + 0.5)),
        thumb_path,
        "0",
        "bgra",
        tostring(iw),
        tostring(ih),
        tostring(4 * iw))
end

function gallery_mt:remove_overlays()
    for view_index, _ in pairs(self.overlays.active) do
        mp.commandv("overlay-remove", self.config.overlay_range + view_index - 1)
        self.overlays.active[view_index] = false
    end
end

function gallery_mt:compute_internal_geometry()
    local gg = self.geometry
    gg.rows = math.floor((gg.size[2] - gg.min_spacing[2]) / (gg.thumbnail_size[2] + gg.min_spacing[2]))
    gg.columns = math.floor((gg.size[1] - gg.min_spacing[1]) / (gg.thumbnail_size[1] + gg.min_spacing[1]))

    if gg.rows <= 0 or gg.columns <= 0 then
        gg.rows = 0
        gg.columns = 0
        gg.effective_spacing[1] = gg.size[1]
        gg.effective_spacing[2] = gg.size[2]
        return
    end

    if gg.rows * gg.columns > self.config.max_thumbnails then
        local r = math.sqrt(gg.rows * gg.columns / self.config.max_thumbnails)
        gg.rows    = math.floor(gg.rows / r)
        gg.columns = math.floor(gg.columns / r)
    end

    gg.effective_spacing[1] = (gg.size[1] - gg.columns * gg.thumbnail_size[1]) / (gg.columns + 1)
    gg.effective_spacing[2] = (gg.size[2] - gg.rows * gg.thumbnail_size[2]) / (gg.rows + 1)
end

function gallery_mt:enough_space()
    local gg = self.geometry
    if gg.size[1] < gg.thumbnail_size[1] + 2 * gg.min_spacing[1] then return false end
    if gg.size[2] < gg.thumbnail_size[2] + 2 * gg.min_spacing[2] then return false end
    return true
end

function gallery_mt:index_at(mx, my)
    local gg = self.geometry
    if mx < gg.position[1] or my < gg.position[2] then return nil end
    mx = mx - gg.position[1]
    my = my - gg.position[2]
    if mx > gg.size[1] or my > gg.size[2] then return nil end
    mx = mx - gg.effective_spacing[1]
    my = my - gg.effective_spacing[2]
    local on_column = (mx % (gg.thumbnail_size[1] + gg.effective_spacing[1])) < gg.thumbnail_size[1]
    local on_row    = (my % (gg.thumbnail_size[2] + gg.effective_spacing[2])) < gg.thumbnail_size[2]
    if on_column and on_row then
        local col   = math.floor(mx / (gg.thumbnail_size[1] + gg.effective_spacing[1]))
        local row   = math.floor(my / (gg.thumbnail_size[2] + gg.effective_spacing[2]))
        local index = self.view.first + row * gg.columns + col
        if index > 0 and index <= self.view.last then
            return index
        end
    end
    return nil
end

function gallery_mt:ensure_view_valid()
    local gg = self.geometry
    if #self.items == 0 or gg.rows == 0 or gg.columns == 0 then
        self.view.first = 0
        self.view.last  = 0
        return
    end

    local v = self.view
    local selection_row = math.floor((self.selection - 1) / gg.columns)
    local max_thumbs = gg.rows * gg.columns
    local changed = false

    if v.last >= #self.items then
        v.last = #self.items
        if gg.rows == 1 then
            v.first = math.max(1, v.last - gg.columns + 1)
        else
            local last_row  = math.floor((v.last - 1) / gg.columns)
            local first_row = math.max(0, last_row - gg.rows + 1)
            v.first = 1 + first_row * gg.columns
        end
        changed = true
    elseif v.first == 0 or v.last == 0 or v.last - v.first + 1 ~= max_thumbs then
        local max_row = (#self.items - 1) / gg.columns + 1
        local row_first = selection_row - math.floor((gg.rows - 1) / 2)
        local row_last  = selection_row + math.floor((gg.rows - 1) / 2) + gg.rows % 2
        if row_first < 0 then
            row_first = 0
        elseif row_last > max_row then
            row_first = max_row - gg.rows + 1
        end
        v.first = 1 + row_first * gg.columns
        v.last  = math.min(#self.items, v.first - 1 + max_thumbs)
        return true
    end

    if self.selection < v.first then
        v.first = (gg.rows == 1) and self.selection or selection_row * gg.columns + 1
        v.last  = math.min(#self.items, v.first + max_thumbs - 1)
        changed = true
    elseif self.selection > v.last then
        v.last  = (gg.rows == 1) and self.selection or (selection_row + 1) * gg.columns
        v.first = math.max(1, v.last - max_thumbs + 1)
        v.last  = math.min(#self.items, v.last)
        changed = true
    end

    return changed
end

function gallery_mt:refresh_background()
    local gg = self.geometry
    local a = assdraw.ass_new()
    a:new_event()
    a:append('{\\an7}{\\bord0}{\\shad0}')
    a:append('{\\1c&' .. self.config.background_color .. '}{\\1a&' .. self.config.background_opacity .. '}')
    a:pos(0, 0)
    a:draw_start()
    a:round_rect_cw(
        gg.position[1], gg.position[2],
        gg.position[1] + gg.size[1],
        gg.position[2] + gg.size[2],
        self.config.background_roundness
    )
    a:draw_stop()
    self.ass.background = a.text
end

function gallery_mt:refresh_placeholders()
    if not self.config.show_placeholders then return end
    if self.view.first == 0 then
        self.ass.placeholders = ""
        return
    end
    local a  = assdraw.ass_new()
    local gg = self.geometry
    a:new_event()
    a:append('{\\an7}{\\bord0}{\\shad0}')
    a:append('{\\1c&' .. self.config.placeholder_color .. '}')
    a:pos(0, 0)
    a:draw_start()
    for i = 0, self.view.last - self.view.first do
        if not self.overlays.active[i + 1] then
            local x, y = self:view_index_position(i)
            a:rect_cw(x, y, x + self.image_w, y + self.image_h)
        end
    end
    a:draw_stop()
    self.ass.placeholders = a.text
end

function gallery_mt:refresh_scrollbar()
    if not self.config.scrollbar then return end
    self.ass.scrollbar = ""
    if self.view.first == 0 then return end
    local gg = self.geometry
    local before = (self.view.first - 1) / #self.items
    local after  = (#self.items - self.view.last) / #self.items
    if before + after == 0 then return end

    local panel_top    = gg.position[2] + 45 -- allow space for search bar
    local panel_bottom = gg.position[2] + gg.size[2] - 10
    if panel_bottom <= panel_top then return end

    local height   = panel_bottom - panel_top
    local min_frac = self.config.scrollbar_min_size / 100

    local vis_frac = 1 - before - after
    if vis_frac < min_frac then
        local remain    = 1 - min_frac
        local total_gap = before + after
        if total_gap > 0 then
            before = before / total_gap * remain
            after  = after  / total_gap * remain
        else
            before = (1 - min_frac) / 2
            after  = before
        end
    end

    local y1 = panel_top + before * height
    local y2 = panel_bottom - after * height
    if y2 <= y1 then y2 = y1 + 2 end

    local x1
    if self.config.scrollbar_left_side then
        x1 = gg.position[1] + 6
    else
        x1 = gg.position[1] + gg.size[1] - 10
    end
    local x2 = x1 + 4

    local s = assdraw.ass_new()
    s:new_event()
    s:append('{\\an7}{\\bord0}{\\shad0}{\\1c&AAAAAA&}')
    s:pos(0, 0)
    s:draw_start()
    s:rect_cw(x1, y1, x2, y2)
    s:draw_stop()
    self.ass.scrollbar = s.text
end

function gallery_mt:refresh_selection()
    local v = self.view
    if v.first == 0 then
        self.ass.selection = ""
        return
    end

    local a  = assdraw.ass_new()
    local gg = self.geometry
    local text_h = self.config.text_size * 1.2

    local function draw_frame(index, size, color)
        local x, y = self:view_index_position(index - v.first)
        local pad = 0
        if index == self.selection then
            pad = 3  -- selection appears slightly larger
        end
        a:new_event()
        a:append('{\\an7}')
        a:append('{\\bord' .. size .. '}{\\3c&' .. color .. '&}{\\1a&FF&}')
        a:pos(0, 0)
        a:draw_start()
        a:rect_cw(x - pad, y - pad, x + self.image_w + pad, y + self.image_h + pad)
        a:draw_stop()
    end

    for i = v.first, v.last do
        local size, color = self.item_to_border(i, self.items[i])
        if size > 0 then
            draw_frame(i, size, color)
        end
    end

    -- Labels: selected = full name; others truncated; small gap below image
    for index = v.first, v.last do
        local base_text = self.item_to_text(index, self.items[index])
        local text
        if index == self.selection then
            text = base_text or ""
        else
            text = shorten(base_text or "", opts.max_label_chars)
        end
        if text ~= "" then
            local x, y = self:view_index_position(index - v.first)
            local label_x = x + self.image_w / 2
            local label_y = y + self.image_h + text_h * 1.2  -- small gap

            a:new_event()
            a:append(string.format("{\\fs%d}", self.config.text_size))
            a:append("{\\an2}")
            a:append("{\\bord2}")
            a:append("{\\3c&H000000&}")
            a:append("{\\1c&HFFFFFF&}")
            a:append("{\\shad1}")
            a:pos(label_x, label_y)
            a:append(text)
        end
    end

    self.ass.selection = a.text
end

function gallery_mt:refresh_searchbar()
    local gg = self.geometry
    local ts = self.config.text_size
    local bar_h = ts * 2.2  -- slightly larger
    local x1 = gg.position[1] + 12
    local x2 = gg.position[1] + gg.size[1] - 12
    local y1 = gg.position[2] + 8
    local y2 = y1 + bar_h

    local a = assdraw.ass_new()

    -- Background rectangle
    a:new_event()
    a:append('{\\an7}{\\bord0}{\\shad0}')
    a:append('{\\1c&222222&}{\\1a&66&}')
    a:pos(0, 0)
    a:draw_start()
    a:rect_cw(x1, y1, x2, y2)
    a:draw_stop()

    local q = self.search_query or ""
    local label = (q ~= "" and ("Search: " .. q))
        or "Search: type to filter, BS=erase, ESC=clear/close"

    local tx = x1 + 10
    local ty = y1 + bar_h / 2

    a:new_event()
    a:append(string.format("{\\fs%d}", ts))
    a:append("{\\an8}{\\bord0}{\\shad0}")
    a:append("{\\1c&HFFFFFF&}{\\1a&H00&}")
    a:pos(tx, ty)
    a:append(label)

    self.ass.searchbar = a.text
end

function gallery_mt:ass_refresh(selection, scrollbar, placeholders, background)
    if not self.active then return end
    if selection    then self:refresh_selection()   end
    if scrollbar    then self:refresh_scrollbar()   end
    if placeholders then self:refresh_placeholders() end
    if background   then self:refresh_background()  end
    self:refresh_searchbar()
    self.ass_show(table.concat({
        self.ass.background,
        self.ass.placeholders,
        self.ass.selection,
        self.ass.scrollbar,
        self.ass.searchbar,
    }, "\n"))
end

function gallery_mt:refresh_overlays()
    local gg = self.geometry
    if gg.rows == 0 or gg.columns == 0 then return end

    for view_index = 1, gg.rows * gg.columns do
        local item_index = self.view.first + view_index - 1
        local active     = self.overlays.active[view_index]

        if item_index > 0 and item_index <= #self.items then
            local thumb_path = self.item_to_overlay_path(item_index, self.items[item_index])

            if file_exists(thumb_path) then
                if active ~= thumb_path then
                    self:show_overlay(view_index, thumb_path)
                end
            else
                if active ~= false then
                    self.overlays.active[view_index] = false
                    mp.commandv("overlay-remove", self.config.overlay_range + view_index - 1)
                end
                if not thumb_failed[thumb_path] then
                    local input_path, tpos = self.item_to_thumbnail_params(item_index, self.items[item_index])
                    if input_path and input_path ~= "" then
                        enqueue_thumb_job({
                            input      = input_path,
                            out        = thumb_path,
                            w          = self.image_w,
                            h          = self.image_h,
                            time       = tpos,
                            item_index = item_index,
                        })
                    end
                end
            end
        else
            if active ~= false then
                self.overlays.active[view_index] = false
                mp.commandv("overlay-remove", self.config.overlay_range + view_index - 1)
            end
        end
    end
end

function gallery_mt:set_selection(sel)
    if not sel or sel ~= sel then return end
    local new_sel = math.max(1, math.min(sel, #self.items))
    if self.selection == new_sel then return end
    self.selection = new_sel
    if self.active then
        if self:ensure_view_valid() then
            self:refresh_overlays()
            self:ass_refresh(true, true, true, false)
        else
            self:ass_refresh(true, false, false, false)
        end
    end
end

function gallery_mt:set_geometry(x, y, w, h, sw, sh, cell_w, cell_h)
    if w <= 0 or h <= 0 or cell_w <= 0 or cell_h <= 0 then
        msg.warn("Invalid geometry for gallery")
        return
    end
    local gg = self.geometry
    gg.position       = { x, y }
    gg.size           = { w, h }
    gg.min_spacing    = { sw, sh }
    gg.thumbnail_size = { cell_w, cell_h }
    gg.ok             = true

    if not self.active then return end
    if not self:enough_space() then
        msg.warn("Not enough space to display gallery")
    end

    local old_total = gg.rows * gg.columns
    self:compute_internal_geometry()
    self:ensure_view_valid()
    local new_total = gg.rows * gg.columns

    for view_index = new_total + 1, old_total do
        if self.overlays.active[view_index] then
            mp.commandv("overlay-remove", self.config.overlay_range + view_index - 1)
            self.overlays.active[view_index] = false
        end
    end

    self:refresh_overlays()
    self:ass_refresh(true, true, true, true)
end

function gallery_mt:items_changed(new_sel)
    self.selection = math.max(1, math.min(new_sel, #self.items))
    if not self.active then return end
    self:ensure_view_valid()
    self:refresh_overlays()
    self:ass_refresh(true, true, true, false)
end

function gallery_mt:activate()
    if self.active then return false end
    if not self:enough_space() then
        msg.warn("Not enough space; refusing to start gallery")
        return false
    end
    if not self.geometry.ok then
        msg.warn("Gallery geometry uninitialized")
        return false
    end
    self.active = true
    if not self.selection then
        self:set_selection(1)
    end
    self:compute_internal_geometry()
    self:ensure_view_valid()
    self:refresh_overlays()
    self:ass_refresh(true, true, true, true)
    return true
end

function gallery_mt:deactivate()
    if not self.active then return end
    self.active = false
    self:remove_overlays()
    self.ass_show("")
end

--------------------------------------------------------------------------------
-- Frontend: playlist-based gallery with search
--------------------------------------------------------------------------------

gallery = gallery_new()

local thumbs_dir
local playlist_cache = {}
local search_query = ""

local function ensure_thumbs_dir()
    if thumbs_dir then return end

    if opts.thumbs_dir ~= "" then
        thumbs_dir = mp.command_native({ "expand-path", opts.thumbs_dir })
    else
        local cfgdir = mp.command_native({ "expand-path", "~~/" })
        thumbs_dir = utils.join_path(cfgdir, "thumbnails")
    end

    if not ensure_dir(thumbs_dir) then
        msg.warn("Could not create thumbnails directory: " .. tostring(thumbs_dir))
    end
end

function gallery.ass_show(ass)
    if not gallery.active then return end
    local dims = mp.get_property_native("osd-dimensions") or {}
    local w = dims.w or mp.get_property_number("osd-width", 1280)
    local h = dims.h or mp.get_property_number("osd-height", 720)
    mp.set_osd_ass(w, h, ass or "")
end

function gallery.item_to_overlay_path(index, item)
    ensure_thumbs_dir()
    local fn = item.filename or ("item_" .. tostring(index))
    -- cache key purely by filename/URL, so it is stable across sessions
    local name = safe_filename(fn) .. ".bgra"
    if thumbs_dir then
        return utils.join_path(thumbs_dir, name)
    else
        return name
    end
end

function gallery.item_to_thumbnail_params(index, item)
    local path = item.filename or ""
    if is_url(path) then
        return path, 0  -- first frame for URLs
    else
        return path, opts.thumb_time
    end
end

function gallery.item_to_text(index, item)
    if item.title and item.title ~= "" then
        return item.title
    end
    local _, name = utils.split_path(item.filename or ("Item " .. tostring(index)))
    return name
end

function gallery.item_to_border(index, item)
    if index == gallery.selection then
        return 3, "00FF00" -- selection
    elseif item.current then
        return 3, "00FFFF" -- now playing
    else
        return 0, ""
    end
end

local function refresh_playlist_cache()
    playlist_cache = mp.get_property_native("playlist") or {}
    local cur = mp.get_property_number("playlist-pos", -1) + 1
    for i, it in ipairs(playlist_cache) do
        it.current = (i == cur)
    end
end

-- Search: strict substring filter; only show matches.
local function apply_filter()
    local items = {}
    local q = (search_query or ""):lower()

    for i, plitem in ipairs(playlist_cache) do
        local title = plitem.title or ""
        local fname = plitem.filename or ""
        local hay   = (title .. " " .. fname)
        local hay_l = hay:lower()

        local include = false
        local score   = 0

        if q == "" then
            include = true
        else
            local pos = hay_l:find(q, 1, true)
            if pos then
                include = true
                if pos == 1 then
                    score = 2   -- starts with
                else
                    score = 1   -- contains
                end
            end
        end

        if include then
            local item = {
                filename    = fname,
                title       = title,
                current     = plitem.current,
                _orig_index = i,
                _score      = score,
            }
            table.insert(items, item)
        end
    end

    if q ~= "" then
        table.sort(items, function(a, b)
            if a._score ~= b._score then
                return a._score > b._score
            end
            return a._orig_index < b._orig_index
        end)
    end

    gallery.items        = items
    gallery.search_query = search_query

    if #items == 0 then
        gallery.selection   = nil
        gallery.view.first  = 0
        gallery.view.last   = 0
        gallery:ass_refresh(true, true, true, true)
        return
    end

    local sel_index = 1
    if q == "" then
        local cur_pos = mp.get_property_number("playlist-pos", -1) + 1
        if cur_pos >= 1 then
            for j, it in ipairs(items) do
                if it._orig_index == cur_pos then
                    sel_index = j
                    break
                end
            end
        end
    end

    gallery:items_changed(sel_index)
end

local function update_items()
    refresh_playlist_cache()
    apply_filter()
end

local function apply_geometry()
    local dims = mp.get_property_native("osd-dimensions") or {}
    local w = dims.w or mp.get_property_number("osd-width", 1280)
    local h = dims.h or mp.get_property_number("osd-height", 720)

    local x  = opts.margin_x
    local y  = opts.margin_y
    local gw = math.max(10, w - 2 * opts.margin_x)
    local gh = math.max(10, h - 2 * opts.margin_y)

    local cell_w = gallery.image_w
    local text_h = gallery.config.text_size * 2.4
    local cell_h = gallery.image_h + text_h

    gallery:set_geometry(
        x, y,
        gw, gh,
        opts.spacing_x, opts.spacing_y,
        cell_w, cell_h
    )
end

mp.observe_property("osd-dimensions", "native", function()
    if gallery.active then
        apply_geometry()
    end
end)

mp.observe_property("playlist-pos", "native", function()
    if gallery.active then
        update_items()
    end
end)

mp.observe_property("playlist-count", "native", function()
    if gallery.active then
        update_items()
    end
end)

--------------------------------------------------------------------------------
-- Search input handling
--------------------------------------------------------------------------------

local function search_reset()
    if search_query == "" then return end
    search_query = ""
    apply_filter()
end

local function search_add_char(ch)
    if not ch or ch == "" then return end
    search_query = search_query .. ch
    apply_filter()
end

local function search_backspace()
    if #search_query == 0 then return end
    search_query = search_query:sub(1, -2)
    apply_filter()
end

--------------------------------------------------------------------------------
-- Input & gallery toggling
--------------------------------------------------------------------------------

local keys_bound = false
local search_bindings = {}

local function move_selection(delta)
    if not gallery.selection then return end
    gallery:set_selection(gallery.selection + delta)
end

local function play_selection()
    if not gallery.selection then return end
    local item = gallery.items[gallery.selection]
    if not item or not item._orig_index then return end
    mp.set_property_number("playlist-pos", item._orig_index - 1)
end

local function delete_selection()
    if not gallery.selection then return end
    local item = gallery.items[gallery.selection]
    if not item or not item._orig_index then return end
    local idx0 = item._orig_index - 1
    mp.commandv("playlist-remove", tostring(idx0))
    search_query = search_query or ""
    update_items()
end

local function click_selection()
    if not gallery.active then return end
    local mp_pos = mp.get_property_native("mouse-pos")
    if not mp_pos then return end
    local idx = gallery:index_at(mp_pos.x, mp_pos.y)
    if not idx then return end
    gallery:set_selection(idx)
    play_selection()
end

local function bind_search_keys()
    local chars = {}
    for i = 0, 9 do
        local k = tostring(i)
        table.insert(chars, { key = k, ch = k })
    end
    for c = string.byte('a'), string.byte('z') do
        local ch = string.char(c)
        table.insert(chars, { key = ch, ch = ch })
    end
    table.insert(chars, { key = "SPACE", ch = " " })
    table.insert(chars, { key = "-", ch = "-" })
    table.insert(chars, { key = "_", ch = "_" })
    table.insert(chars, { key = ".", ch = "." })

    for i, ent in ipairs(chars) do
        local id = "gallery-view-search-" .. i
        mp.add_forced_key_binding(ent.key, id, function() search_add_char(ent.ch) end)
        search_bindings[#search_bindings + 1] = id
    end
end

local function unbind_search_keys()
    for _, id in ipairs(search_bindings) do
        mp.remove_key_binding(id)
    end
    search_bindings = {}
end

local function bind_keys()
    if keys_bound then return end
    keys_bound = true

    mp.add_forced_key_binding("LEFT",  "gallery-view-left",
        function() move_selection(-1) end, {repeatable = true})
    mp.add_forced_key_binding("RIGHT", "gallery-view-right",
        function() move_selection(1) end, {repeatable = true})

    mp.add_forced_key_binding("UP", "gallery-view-up", function()
        local cols = gallery.geometry.columns or 1
        move_selection(-math.max(cols, 1))
    end, {repeatable = true})

    mp.add_forced_key_binding("DOWN", "gallery-view-down", function()
        local cols = gallery.geometry.columns or 1
        move_selection(math.max(cols, 1))
    end, {repeatable = true})

    mp.add_forced_key_binding("WHEEL_UP", "gallery-view-wheel-up", function()
        local cols = gallery.geometry.columns or 1
        move_selection(-math.max(cols, 1))
    end)

    mp.add_forced_key_binding("WHEEL_DOWN", "gallery-view-wheel-down", function()
        local cols = gallery.geometry.columns or 1
        move_selection(math.max(cols, 1))
    end)

    mp.add_forced_key_binding("ENTER",     "gallery-view-enter", play_selection)
    mp.add_forced_key_binding("MBTN_LEFT", "gallery-view-click", click_selection)

    -- DEL: remove from playlist (not from disk)
    mp.add_forced_key_binding("DEL", "gallery-view-del", delete_selection)

    -- ESC: first clears search, then closes gallery
    mp.add_forced_key_binding("ESC", "gallery-view-esc", function()
        if search_query ~= "" then
            search_reset()
        else
            mp.commandv("script-binding", "gallery-view-toggle")
        end
    end)

    mp.add_forced_key_binding("BS", "gallery-view-backspace", search_backspace)

    bind_search_keys()
end

local function unbind_keys()
    if not keys_bound then return end
    keys_bound = false
    mp.remove_key_binding("gallery-view-left")
    mp.remove_key_binding("gallery-view-right")
    mp.remove_key_binding("gallery-view-up")
    mp.remove_key_binding("gallery-view-down")
    mp.remove_key_binding("gallery-view-wheel-up")
    mp.remove_key_binding("gallery-view-wheel-down")
    mp.remove_key_binding("gallery-view-enter")
    mp.remove_key_binding("gallery-view-click")
    mp.remove_key_binding("gallery-view-del")
    mp.remove_key_binding("gallery-view-esc")
    mp.remove_key_binding("gallery-view-backspace")
    unbind_search_keys()
end

local function open_gallery()
    if gallery.active then return end
    ensure_thumbs_dir()
    clear_thumb_jobs()
    thumb_failed     = {}
    active_thumb_job = nil
    search_query     = ""
    update_items()
    apply_geometry()
    if not gallery:activate() then return end
    bind_keys()
    start_next_thumb()
end

local function close_gallery()
    if not gallery.active then return end
    unbind_keys()
    gallery:deactivate()
    mp.set_osd_ass(0, 0, "")
end

local function toggle_gallery()
    if gallery.active then
        close_gallery()
    else
        open_gallery()
    end
end

--------------------------------------------------------------------------------
-- Public commands
--------------------------------------------------------------------------------

mp.add_key_binding(nil, "gallery-view-toggle", toggle_gallery)
mp.register_script_message("gallery-view", toggle_gallery)
