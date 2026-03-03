-- ═══════════════════════════════════════════════════════════════════════════════
--  yt.lua — Production-grade MPV YouTube utility
-- ═══════════════════════════════════════════════════════════════════════════════
--  Requirements: mpv ≥ 0.37, yt-dlp, ffmpeg
--  Optional:     aria2c (faster downloads when enabled)
--  Config:       ~/.config/mpv/script-opts/yt.conf
--
--  Architecture:
--    • Single-file design with logical component separation
--    • Session-based search (unlimited reuse)
--    • TTL-based format cache with LRU eviction
--    • Binary detection at startup
--    • Centralized lifecycle management
--    • Non-blocking async operations only
--    • Proper error categorization
-- ═══════════════════════════════════════════════════════════════════════════════

local mp      = require "mp"
local utils   = require "mp.utils"
local msg     = require "mp.msg"
local assdraw = require "mp.assdraw"

-- ═══════════════════════════════════════════════════════════════════════════════
--  SECTION 1: CONFIGURATION & VALIDATION
-- ═══════════════════════════════════════════════════════════════════════════════

local cfg = {
    -- Binaries
    ytdlp_bin            = "yt-dlp",
    ffmpeg_bin           = "ffmpeg",
    aria2c_bin           = "aria2c",
    browser_bin          = "firefox",
    clipboard_cmd        = "wl-paste",
    
    -- Paths
    download_directory   = "~/Downloads",
    
    -- Defaults
    default_quality      = "bestvideo+bestaudio/best",
    default_video_quality = "1080",
    default_audio_format = "mp3",
    search_count         = 5,
    
    -- Download settings
    enable_aria2c        = false,
    enable_quality_prompt = true,
    downloader_parallelism = 1,
    
    -- UI settings
    font                 = "JetBrains Mono",
    font_size            = 12,
    osd_duration         = 8,
    
    -- Cache settings
    format_cache_ttl     = 300,  -- 5 minutes
}

-- Load user configuration
require("mp.options").read_options(cfg, "yt")

-- Expand paths
local function expand_path(path)
    if not path then return nil end
    local home
    if IS_WINDOWS then
        home = os.getenv("USERPROFILE") or os.getenv("HOMEPATH") or ""
    else
        home = os.getenv("HOME") or ""
    end
    path = path:gsub("^~", home)
    -- Normalize Windows backslashes to forward slashes for yt-dlp compatibility
    if IS_WINDOWS then
        path = path:gsub("\\", "/")
    end
    return path
end

cfg.download_directory = expand_path(cfg.download_directory)

-- Validate configuration
local function validate_config()
    local warnings = {}
    
    if not cfg.download_directory or cfg.download_directory == "" then
        if IS_WINDOWS then
            local userprofile = os.getenv("USERPROFILE") or "C:/Users/user"
            cfg.download_directory = userprofile .. "/Downloads"
        else
            cfg.download_directory = (os.getenv("HOME") or "") .. "/Downloads"
        end
        table.insert(warnings, "download_directory empty, using: " .. cfg.download_directory)
    end
    
    if cfg.format_cache_ttl < 60 then
        cfg.format_cache_ttl = 60
        table.insert(warnings, "format_cache_ttl too low, using: 60s")
    end
    
    if cfg.downloader_parallelism < 1 then
        cfg.downloader_parallelism = 1
    end
    
    for _, w in ipairs(warnings) do
        msg.warn("Config: " .. w)
    end
end

validate_config()

-- ═══════════════════════════════════════════════════════════════════════════════
--  SECTION 2: OS DETECTION & BINARY DETECTION
-- ═══════════════════════════════════════════════════════════════════════════════

-- Detect OS: package.config uses '\' as separator on Windows
local IS_WINDOWS = package.config:sub(1,1) == "\\"

local function os_name()
    return IS_WINDOWS and "windows" or "unix"
end

msg.info("Platform: " .. os_name())

local BINARIES = {
    ytdlp  = { path = nil, available = false },
    ffmpeg = { path = nil, available = false },
    aria2c = { path = nil, available = false },
}

local function detect_binary(name, cmd)
    -- Use 'where' on Windows, 'which' on Unix
    local which_cmd = IS_WINDOWS and "where" or "which"
    local result = mp.command_native({
        name           = "subprocess",
        playback_only  = false,
        capture_stdout = true,
        capture_stderr = true,
        args           = { which_cmd, cmd },
    })
    
    if result and result.status == 0 and result.stdout then
        local path = result.stdout:match("^%s*(.-)%s*$")
        if path and path ~= "" then
            BINARIES[name].path = path
            BINARIES[name].available = true
            msg.info(string.format("✓ %s: %s", name, path))
            return true
        end
    end
    
    BINARIES[name].available = false
    msg.warn(string.format("✗ %s not found: %s", name, cmd))
    return false
end

local function detect_binaries()
    msg.info("Detecting binaries...")
    
    detect_binary("ytdlp",  cfg.ytdlp_bin)
    detect_binary("ffmpeg", cfg.ffmpeg_bin)
    detect_binary("aria2c", cfg.aria2c_bin)
    
    -- Critical checks
    if not BINARIES.ytdlp.available then
        msg.error("FATAL: yt-dlp not found. Script disabled.")
        mp.osd_message("yt.lua: yt-dlp not found!", 5)
        return false
    end
    
    if not BINARIES.ffmpeg.available then
        msg.warn("ffmpeg not found - video+audio merging may fail")
    end
    
    if cfg.enable_aria2c and not BINARIES.aria2c.available then
        msg.warn("aria2c enabled but not found - disabling")
        cfg.enable_aria2c = false
    end
    
    return true
end

-- ═══════════════════════════════════════════════════════════════════════════════
--  SECTION 3: UTILITY FUNCTIONS
-- ═══════════════════════════════════════════════════════════════════════════════

local function notify(text, duration)
    mp.osd_message(text, duration or 2)
end

local function current_url()
    local path = mp.get_property("path") or ""
    return path:gsub("^ytdl://", "")
end

local function is_url(s)
    return type(s) == "string" and s:match("^https?://") ~= nil
end

local function is_youtube_url(url)
    return url:match("youtu%.be/") or url:match("youtube%.com/")
end

local function is_playlist_url(s)
    return type(s) == "string" and s:match("[?&]list=[A-Za-z0-9_%-]+") ~= nil
end

local function trunc(s, n)
    return #s > n and s:sub(1, n - 1) .. "…" or s
end

local function url_encode(s)
    return s:gsub("([^%w%-%.%_%~ ])", function(c)
        return string.format("%%%02X", c:byte())
    end):gsub(" ", "+")
end

local function get_clipboard_async(cb)
    local clipboard_args
    if IS_WINDOWS then
        -- PowerShell clipboard on Windows
        clipboard_args = { "powershell", "-NoProfile", "-Command",
                           "Get-Clipboard | Write-Output" }
    else
        -- Use configured clipboard_cmd (wl-paste for Wayland, xclip for X11)
        clipboard_args = { cfg.clipboard_cmd }
    end
    
    mp.command_native_async({
        name           = "subprocess",
        playback_only  = false,
        capture_stdout = true,
        args           = clipboard_args,
    }, function(success, result)
        if success and result.status == 0 and result.stdout then
            local text = result.stdout:match("^%s*(.-)%s*$")
            cb(text)
        else
            cb(nil)
        end
    end)
end

-- ═══════════════════════════════════════════════════════════════════════════════
--  SECTION 4: SUBPROCESS EXECUTION WRAPPER
-- ═══════════════════════════════════════════════════════════════════════════════

local ERROR_TYPE = {
    FATAL     = "fatal",      -- Script error, should not happen
    TRANSIENT = "transient",  -- Network, temporary failure
    USER      = "user",       -- Invalid input, user error
}

local function categorize_error(stderr)
    if not stderr then return ERROR_TYPE.FATAL end
    
    local lower = stderr:lower()
    
    -- Network issues
    if lower:match("network") or lower:match("timeout") or 
       lower:match("connection") or lower:match("dns") then
        return ERROR_TYPE.TRANSIENT
    end
    
    -- User errors
    if lower:match("not available") or lower:match("private video") or
       lower:match("video unavailable") or lower:match("unsupported url") then
        return ERROR_TYPE.USER
    end
    
    return ERROR_TYPE.FATAL
end

local function run_subprocess(args, cb, timeout)
    local timer = nil
    local completed = false
    
    local function finish(success, result)
        if completed then return end
        completed = true
        if timer then timer:kill() end
        cb(success, result)
    end
    
    msg.verbose("Subprocess: " .. table.concat(args, " "))
    
    mp.command_native_async({
        name           = "subprocess",
        playback_only  = false,
        capture_stdout = true,
        capture_stderr = true,
        args           = args,
    }, function(success, result)
        finish(success, result)
    end)
    
    if timeout then
        timer = mp.add_timeout(timeout, function()
            if not completed then
                msg.warn("Subprocess timeout: " .. table.concat(args, " "))
                finish(false, { status = -1, stderr = "Timeout" })
            end
        end)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════════
--  SECTION 5: CACHE MANAGEMENT (TTL-based with LRU eviction)
-- ═══════════════════════════════════════════════════════════════════════════════

local FormatCache = {}

function FormatCache:new()
    local obj = {
        data = {},
        max_size = 50,
    }
    setmetatable(obj, { __index = self })
    return obj
end

function FormatCache:get(key)
    local entry = self.data[key]
    if not entry then return nil end
    
    local now = os.time()
    if now - entry.timestamp > cfg.format_cache_ttl then
        self.data[key] = nil
        return nil
    end
    
    entry.last_access = now
    return entry.value
end

function FormatCache:set(key, value)
    self.data[key] = {
        value = value,
        timestamp = os.time(),
        last_access = os.time(),
    }
    
    self:evict_if_needed()
end

function FormatCache:evict_if_needed()
    local count = 0
    for _ in pairs(self.data) do count = count + 1 end
    
    if count <= self.max_size then return end
    
    -- LRU eviction
    local oldest_key = nil
    local oldest_time = math.huge
    
    for key, entry in pairs(self.data) do
        if entry.last_access < oldest_time then
            oldest_time = entry.last_access
            oldest_key = key
        end
    end
    
    if oldest_key then
        self.data[oldest_key] = nil
        msg.info("Cache evicted: " .. oldest_key)
    end
end

function FormatCache:clear()
    self.data = {}
end

function FormatCache:invalidate(key)
    self.data[key] = nil
end

local format_cache = FormatCache:new()

-- Only invalidate cache when navigating to a DIFFERENT URL (not on quality reload)
local _last_cache_url = nil
mp.register_event("start-file", function()
    local url = current_url()
    if url and url ~= "" and url ~= _last_cache_url then
        if _last_cache_url then
            format_cache:invalidate(_last_cache_url)
        end
        _last_cache_url = url
    end
end)

-- ═══════════════════════════════════════════════════════════════════════════════
--  SECTION 6: FORMAT PARSING & QUALITY LOGIC
-- ═══════════════════════════════════════════════════════════════════════════════

local function normalize_format(f)
    local has_video = f.vcodec and f.vcodec ~= "none"
    local has_audio = f.acodec and f.acodec ~= "none"
    
    local codec_family = "unknown"
    if has_video and f.vcodec then
        if f.vcodec:match("^av01") then
            codec_family = "av1"
        elseif f.vcodec:match("^vp09") or f.vcodec:match("^vp9") then
            codec_family = "vp9"
        elseif f.vcodec:match("^vp08") or f.vcodec:match("^vp8") then
            codec_family = "vp8"
        elseif f.vcodec:match("^avc") or f.vcodec:match("^h264") then
            codec_family = "h264"
        end
    end
    
    return {
        id         = f.format_id,
        has_audio  = has_audio,
        has_video  = has_video,
        codec      = codec_family,
        container  = f.ext or "unknown",
        width      = f.width or 0,
        height     = f.height or 0,
        fps        = f.fps or 0,
        bitrate    = f.tbr or f.vbr or 0,
        filesize   = f.filesize or 0,
        progressive = has_video and has_audio,
    }
end

local function deduplicate_formats(formats)
    local seen = {}
    local result = {}
    
    for _, fmt in ipairs(formats) do
        if fmt.has_video and fmt.height > 0 then
            -- Key: height + fps + codec family
            local fps_bucket = fmt.fps > 0 and math.floor(fmt.fps / 10) * 10 or 0
            local key = string.format("%d_%d_%s", fmt.height, fps_bucket, fmt.codec)
            
            if not seen[key] then
                seen[key] = true
                table.insert(result, fmt)
            end
        end
    end
    
    return result
end

local function group_formats(formats)
    local progressive = {}
    local video_only = {}
    local audio_only = {}
    
    for _, fmt in ipairs(formats) do
        if fmt.progressive then
            table.insert(progressive, fmt)
        elseif fmt.has_video then
            table.insert(video_only, fmt)
        elseif fmt.has_audio then
            table.insert(audio_only, fmt)
        end
    end
    
    return {
        progressive = progressive,
        video_only = video_only,
        audio_only = audio_only,
    }
end

local function parse_formats(json_data)
    if not json_data or not json_data.formats then
        return nil
    end
    
    local normalized = {}
    for _, f in ipairs(json_data.formats) do
        table.insert(normalized, normalize_format(f))
    end
    
    local video_formats = {}
    for _, f in ipairs(normalized) do
        if f.has_video then
            table.insert(video_formats, f)
        end
    end
    
    local deduplicated = deduplicate_formats(video_formats)
    local grouped = group_formats(normalized)
    
    -- Sort by height descending
    table.sort(deduplicated, function(a, b)
        if a.height ~= b.height then
            return a.height > b.height
        end
        return a.fps > b.fps
    end)
    
    return deduplicated, grouped
end

local function build_quality_menu_items(formats, grouped)
    local items = {}
    
    -- Add "Best" option
    table.insert(items, {
        label = "Best (auto)",
        value = "bestvideo+bestaudio/best",
        type = "auto"
    })
    
    -- Add video formats
    for _, fmt in ipairs(formats) do
        local fps_text = fmt.fps > 30 and string.format(" %dfps", fmt.fps) or ""
        local codec_text = fmt.codec ~= "unknown" and (" " .. fmt.codec) or ""
        local label = string.format("%dp%s%s", fmt.height, fps_text, codec_text)
        
        table.insert(items, {
            label = label,
            value = fmt.id .. "+bestaudio/best",
            type = "video"
        })
    end
    
    -- Add audio-only option
    table.insert(items, {
        label = "Audio only",
        value = "bestaudio/best",
        type = "audio"
    })
    
    return items
end

-- ═══════════════════════════════════════════════════════════════════════════════
--  SECTION 7: MENU/UI SYSTEM
-- ═══════════════════════════════════════════════════════════════════════════════

local Menu = {
    active_menu = nil,
    colors = {
        header = "8CFAF1",
        cursor = "FDE98B",
        text   = "BFBFBF",
    }
}

function Menu:new(title, items, on_select)
    if Menu.active_menu then
        Menu.active_menu:close()
    end
    
    if #items == 0 then
        notify("No items", 2)
        return nil
    end
    
    local obj = {
        title     = title,
        items     = items,
        cursor    = 1,
        timer     = nil,
        closed    = false,
        on_select = on_select,
    }
    
    setmetatable(obj, { __index = self })
    Menu.active_menu = obj
    
    obj:setup_bindings()
    obj:render()
    obj:arm_timer()
    
    return obj
end

function Menu:setup_bindings()
    local self = self
    
    mp.add_forced_key_binding("UP", "yt-menu-up", function()
        self.cursor = self.cursor > 1 and self.cursor - 1 or #self.items
        self:render()
        self:arm_timer()
    end, { repeatable = true })
    
    mp.add_forced_key_binding("DOWN", "yt-menu-down", function()
        self.cursor = self.cursor < #self.items and self.cursor + 1 or 1
        self:render()
        self:arm_timer()
    end, { repeatable = true })
    
    mp.add_forced_key_binding("ENTER", "yt-menu-enter", function()
        local item = self.items[self.cursor]
        self:close()
        if self.on_select then
            self.on_select(item)
        end
    end)
    
    mp.add_forced_key_binding("ESC", "yt-menu-esc", function()
        self:close()
    end)
end

function Menu:render()
    local ass = assdraw.ass_new()
    
    ass:append(string.format(
        "{\\an7\\fn%s\\fs%d\\b1\\c&H%s&}%s{\\b0\\c&HFFFFFF&}\\N",
        cfg.font, cfg.font_size + 2, self.colors.header, self.title))
    
    for i, item in ipairs(self.items) do
        local is_cursor = (i == self.cursor)
        local color = is_cursor and self.colors.cursor or self.colors.text
        local prefix = is_cursor and "▶ " or "  "
        
        ass:append(string.format(
            "{\\c&H%s&\\fn%s\\fs%d}%s%s\\N",
            color, cfg.font, cfg.font_size, prefix, item.label))
    end
    
    ass:append(string.format(
        "{\\c&H%s&\\fn%s\\fs%d}  ↑↓=navigate  Enter=select  ESC=close\\N",
        self.colors.text, cfg.font, cfg.font_size - 1))
    
    mp.set_osd_ass(0, 0, ass.text)
end

function Menu:arm_timer()
    if self.timer then self.timer:kill() end
    self.timer = mp.add_timeout(cfg.osd_duration, function()
        self:close()
    end)
end

function Menu:close()
    if self.closed then return end
    self.closed = true
    
    if self.timer then
        self.timer:kill()
        self.timer = nil
    end
    
    mp.set_osd_ass(0, 0, "")
    
    for _, key in ipairs({"yt-menu-up", "yt-menu-down", "yt-menu-enter", "yt-menu-esc"}) do
        pcall(function() mp.remove_key_binding(key) end)
    end
    
    if Menu.active_menu == self then
        Menu.active_menu = nil
    end
end

-- ═══════════════════════════════════════════════════════════════════════════════
--  SECTION 8: SEARCH SESSION MANAGER
-- ═══════════════════════════════════════════════════════════════════════════════

local SearchSession = {}

function SearchSession:new()
    local obj = {
        active = false,
        timer = nil,
        input_handle = nil,
    }
    setmetatable(obj, { __index = self })
    return obj
end

function SearchSession:start()
    if self.active then
        notify("Search already active", 2)
        return false
    end
    
    local ok, input = pcall(require, "mp.input")
    if not ok or type(input) ~= "table" then
        notify("mp.input unavailable (mpv < 0.37)", 3)
        return false
    end
    
    self.active = true
    self.input_handle = input
    
    local self_ref = self
    
    input.get({
        prompt = "YouTube ❯ ",
        submit = function(query)
            self_ref:submit(query)
        end,
    })
    
    -- Safety timeout
    self.timer = mp.add_timeout(60, function()
        if self_ref.active then
            msg.warn("Search session timeout")
            self_ref:cleanup()
        end
    end)
    
    return true
end

function SearchSession:submit(query)
    -- Capture handle before cleanup nils it
    local input_h = self.input_handle
    self:cleanup()
    
    query = query:match("^%s*(.-)%s*$")
    if query == "" then
        return
    end
    
    -- Terminate input box (cleanup may have done it, pcall for safety)
    if input_h then
        pcall(function() input_h.terminate() end)
    end
    
    local encoded = url_encode(query)
    mp.commandv("loadfile",
        "ytdl://ytsearch" .. cfg.search_count .. ":" .. encoded,
        "append-play")
    
    notify("🔍 " .. query, 3)
    msg.info("Search: " .. query)
end

function SearchSession:cleanup()
    if self.timer then
        self.timer:kill()
        self.timer = nil
    end
    -- Terminate any active input box
    if self.active and self.input_handle then
        pcall(function() self.input_handle.terminate() end)
    end
    self.input_handle = nil
    self.active = false
end

local search_session = SearchSession:new()

-- ═══════════════════════════════════════════════════════════════════════════════
--  SECTION 9: DOWNLOAD QUEUE MANAGER
-- ═══════════════════════════════════════════════════════════════════════════════

local DownloadQueue = {
    queue = {},
    active = false,
}

function DownloadQueue:build_args(url, format_spec, mode)
    local out_tmpl = cfg.download_directory .. "/%(uploader)s - %(title)s.%(ext)s"
    local args = { BINARIES.ytdlp.path }
    
    table.insert(args, "--no-playlist")
    
    if mode == "audio" then
        table.insert(args, "-x")
        table.insert(args, "--audio-format")
        table.insert(args, cfg.default_audio_format)
        table.insert(args, "--audio-quality")
        table.insert(args, "0")
    else
        table.insert(args, "-f")
        table.insert(args, format_spec or "bestvideo+bestaudio/best")
        table.insert(args, "--merge-output-format")
        table.insert(args, "mp4")
    end
    
    -- Add aria2c if enabled
    if cfg.enable_aria2c and BINARIES.aria2c.available then
        table.insert(args, "--downloader")
        table.insert(args, BINARIES.aria2c.path)
        -- Combine all aria2c args into a single --downloader-args value
        table.insert(args, "--downloader-args")
        table.insert(args, "aria2c:--min-split-size=1M --max-connection-per-server=8 --file-allocation=none")
    end
    
    table.insert(args, "-o")
    table.insert(args, out_tmpl)
    table.insert(args, url)
    
    return args
end

function DownloadQueue:enqueue(url, format_spec, mode, label)
    -- Ensure download directory exists
    local dir = cfg.download_directory
    local stat = utils.file_info(dir)
    if not stat or not stat.is_dir then
        -- Try to create it
        local mkdir_cmd = IS_WINDOWS and {"cmd", "/c", "mkdir", dir:gsub("/", "\\")}
                                      or {"mkdir", "-p", dir}
        mp.command_native({ name = "subprocess", playback_only = false,
                            capture_stdout = false, capture_stderr = false,
                            args = mkdir_cmd })
        stat = utils.file_info(dir)
        if not stat or not stat.is_dir then
            notify(string.format("✗ Download dir missing:\n%s", dir), 6)
            msg.error("Download directory not accessible: " .. dir)
            return
        end
    end
    
    local args = self:build_args(url, format_spec, mode)
    
    table.insert(self.queue, {
        args = args,
        label = label or (mode == "audio" and "audio" or "video"),
        url = url,
    })
    
    if self.active then
        notify(string.format("+ Queued: %s (%d in queue)", label, #self.queue), 3)
    else
        self:process_next()
    end
end

function DownloadQueue:process_next()
    if self.active or #self.queue == 0 then return end
    
    local job = table.remove(self.queue, 1)
    self.active = true
    
    local queue_text = #self.queue > 0 and string.format(" (%d more)", #self.queue) or ""
    notify(string.format("⬇ %s...%s\n%s", job.label, queue_text, cfg.download_directory), 4)
    msg.info("Download start: " .. job.label .. " → " .. job.url)
    
    mp.command_native_async({
        name           = "subprocess",
        playback_only  = false,
        capture_stdout = false,
        capture_stderr = true,
        args           = job.args,
    }, function(success, result)
        self.active = false
        
        if success and result.status == 0 then
            notify(string.format("✓ Done: %s\n→ %s", job.label, cfg.download_directory), 5)
            msg.info("Download complete: " .. job.label)
        else
            local stderr = result.stderr or ""
            local err_type = categorize_error(stderr)
            local err_msg = stderr:match("ERROR[^\n]*") or 
                            (stderr ~= "" and stderr:sub(1, 100)) or
                            string.format("exit %d", result.status)
            
            notify(string.format("✗ Failed: %s\n%s", job.label, err_msg), 7)
            msg.error(string.format("Download failed [%s]: %s\n%s", err_type, job.label, stderr))
        end
        
        self:process_next()
    end)
end

local download_queue = DownloadQueue

-- ═══════════════════════════════════════════════════════════════════════════════
--  SECTION 10: LIFECYCLE & CLEANUP MANAGER
-- ═══════════════════════════════════════════════════════════════════════════════

local Lifecycle = {
    initialized = false,
    cleanup_handlers = {},
}

function Lifecycle:init()
    if self.initialized then return true end  -- Already done, not an error
    self.initialized = true
    
    msg.info("Initializing yt.lua...")
    
    if not detect_binaries() then
        msg.error("Binary detection failed - script disabled")
        return false
    end
    
    -- Apply default quality on file start
    mp.register_event("start-file", function()
        local cur = mp.get_property("ytdl-format") or ""
        if cur == "" then
            mp.set_property("ytdl-format", cfg.default_quality)
        end
    end)
    
    msg.info("yt.lua initialized successfully")
    return true
end

function Lifecycle:register_cleanup(handler)
    table.insert(self.cleanup_handlers, handler)
end

function Lifecycle:shutdown()
    msg.info("Shutting down yt.lua...")
    
    -- Close active menu
    if Menu.active_menu then
        Menu.active_menu:close()
    end
    
    -- Cleanup search session
    if search_session then
        search_session:cleanup()
    end
    
    -- Clear cache
    if format_cache then
        format_cache:clear()
    end
    
    -- Run registered cleanup handlers
    for _, handler in ipairs(self.cleanup_handlers) do
        pcall(handler)
    end
    
    msg.info("yt.lua shutdown complete")
end

-- Register script shutdown handler
mp.register_event("shutdown", function()
    Lifecycle:shutdown()
end)

-- ═══════════════════════════════════════════════════════════════════════════════
--  SECTION 11: USER-FACING FEATURES
-- ═══════════════════════════════════════════════════════════════════════════════

-- ─── Quality Picker ──────────────────────────────────────────────────────────

local function reload_with_quality()
    local duration = mp.get_property_native("duration")
    local time_pos = mp.get_property("time-pos")
    
    mp.commandv("playlist-play-index", "current")
    
    if duration and duration > 0 and time_pos then
        local handler
        handler = function()
            mp.unregister_event(handler)
            mp.commandv("seek", time_pos, "absolute+exact")
        end
        mp.register_event("file-loaded", handler)
    end
end

local function fetch_formats_async(url, cb)
    -- Check cache first
    local cached = format_cache:get(url)
    if cached then
        cb(cached)
        return
    end
    
    notify("Fetching formats…", 30)
    
    run_subprocess(
        { BINARIES.ytdlp.path, "--no-warnings", "--no-playlist", "-J", url },
        function(success, result)
            mp.osd_message("", 0)
            
            if not success or result.status ~= 0 then
                local err_type = categorize_error(result.stderr)
                notify(string.format("Failed to fetch formats [%s]", err_type), 3)
                msg.error("Format fetch failed: " .. (result.stderr or "unknown"))
                cb(nil)
                return
            end
            
            local json = utils.parse_json(result.stdout)
            if not json then
                notify("Could not parse formats", 2)
                cb(nil)
                return
            end
            
            local formats, grouped = parse_formats(json)
            if not formats or #formats == 0 then
                notify("No formats available", 2)
                cb(nil)
                return
            end
            
            local items = build_quality_menu_items(formats, grouped)
            format_cache:set(url, items)
            cb(items)
        end,
        30  -- 30s timeout
    )
end

local function open_quality_menu()
    local url = current_url()
    if not is_url(url) then
        notify("Quality picker: valid URL required", 2)
        return
    end
    
    fetch_formats_async(url, function(items)
        if not items or #items == 0 then return end
        
        Menu:new("⚙ Quality", items, function(item)
            mp.set_property("ytdl-format", item.value)
            notify("Quality → " .. item.label, 2)
            msg.info("Quality changed: " .. item.value)
            reload_with_quality()
        end)
    end)
end

-- ─── Download ────────────────────────────────────────────────────────────────

local function download_with_quality(url, format_spec, mode)
    local label = mode == "audio" and ("audio→" .. cfg.default_audio_format) or
                                      ("video " .. (format_spec or "best"))
    download_queue:enqueue(url, format_spec, mode, label)
end

local function trigger_download(mode)
    local url = current_url()
    if not is_url(url) then
        notify("Not a downloadable URL", 2)
        return
    end
    
    if not cfg.enable_quality_prompt then
        local format_spec
        if mode == "audio" then
            format_spec = "bestaudio/best"
        else
            format_spec = string.format("bestvideo[height<=%s]+bestaudio/best", 
                                       cfg.default_video_quality)
        end
        download_with_quality(url, format_spec, mode)
        return
    end
    
    -- Prompt for quality
    fetch_formats_async(url, function(items)
        if not items or #items == 0 then
            notify("Could not fetch formats, using best quality", 3)
            download_with_quality(url, nil, mode)
            return
        end
        
        -- Filter by mode
        local filtered = {}
        if mode == "audio" then
            for _, item in ipairs(items) do
                if item.type == "audio" or item.label:match("Audio") then
                    table.insert(filtered, item)
                end
            end
        else
            for _, item in ipairs(items) do
                if item.type ~= "audio" then
                    table.insert(filtered, item)
                end
            end
        end
        
        if #filtered == 0 then filtered = items end
        
        Menu:new("⬇ Select Quality", filtered, function(item)
            download_with_quality(url, item.value, mode)
        end)
    end)
end

-- ─── Search ──────────────────────────────────────────────────────────────────

local function yt_search()
    search_session:start()
end

-- ─── Queue Display ───────────────────────────────────────────────────────────

local Queue = {
    visible = false,
    cursor = 0,
    timer = nil,
}

local function queue_count()   return mp.get_property_number("playlist-count") or 0 end
local function queue_current() return mp.get_property_number("playlist-pos")   or 0 end

local function queue_title(i)
    local t = mp.get_property(string.format("playlist/%d/title", i)) or
              mp.get_property(string.format("playlist/%d/filename", i)) or
              "(unknown)"
    t = t:gsub("^ytdl://", ""):gsub("^ytsearch%d*:", "")
    return trunc(t, 58)
end

local function queue_unbind()
    for _, k in ipairs({"yt-q-up", "yt-q-down", "yt-q-enter", "yt-q-remove"}) do
        pcall(function() mp.remove_key_binding(k) end)
    end
end

local function queue_render()
    local n = queue_count()
    if n == 0 then
        mp.set_osd_ass(0, 0, "")
        notify("Queue empty", 2)
        return
    end
    
    Queue.cursor = math.max(0, math.min(Queue.cursor, n - 1))
    
    local cur = queue_current()
    local ass = assdraw.ass_new()
    
    ass:append(string.format(
        "{\\an7\\fn%s\\fs%d\\b1\\c&H%s&}QUEUE (%d)  [x=remove  Enter=play]{\\b0\\c&HFFFFFF&}\\N",
        cfg.font, cfg.font_size + 2, Menu.colors.header, n))
    
    local half = 6
    local start = math.max(0, Queue.cursor - half)
    local stop = math.min(n - 1, start + half * 2)
    
    for i = start, stop do
        local title = queue_title(i)
        local color, prefix
        
        if i == Queue.cursor and i == cur then
            color = "FA9BD0"
            prefix = "▶● "
        elseif i == Queue.cursor then
            color = Menu.colors.cursor
            prefix = "●  "
        elseif i == cur then
            color = Menu.colors.header
            prefix = "▶  "
        else
            color = Menu.colors.text
            prefix = "   "
        end
        
        ass:append(string.format(
            "{\\c&H%s&\\fn%s\\fs%d}%s%s\\N",
            color, cfg.font, cfg.font_size, prefix, title))
    end
    
    mp.set_osd_ass(0, 0, ass.text)
    
    if Queue.timer then Queue.timer:kill() end
    Queue.timer = mp.add_timeout(cfg.osd_duration, function()
        Queue.visible = false
        mp.set_osd_ass(0, 0, "")
        queue_unbind()
    end)
end

local function queue_close()
    Queue.visible = false
    if Queue.timer then
        Queue.timer:kill()
        Queue.timer = nil
    end
    mp.set_osd_ass(0, 0, "")
    queue_unbind()
end

local function queue_open()
    if Queue.visible then queue_close() end
    
    Queue.visible = true
    Queue.cursor = queue_current()
    
    mp.add_forced_key_binding("UP", "yt-q-up", function()
        local n = queue_count()
        if n == 0 then return end
        Queue.cursor = Queue.cursor > 0 and Queue.cursor - 1 or n - 1
        queue_render()
    end, { repeatable = true })
    
    mp.add_forced_key_binding("DOWN", "yt-q-down", function()
        local n = queue_count()
        if n == 0 then return end
        Queue.cursor = Queue.cursor < n - 1 and Queue.cursor + 1 or 0
        queue_render()
    end, { repeatable = true })
    
    mp.add_forced_key_binding("ENTER", "yt-q-enter", function()
        mp.set_property_number("playlist-pos", Queue.cursor)
        queue_render()
    end)
    
    mp.add_forced_key_binding("x", "yt-q-remove", function()
        local n = queue_count()
        if n == 0 then return end
        mp.commandv("playlist-remove", Queue.cursor)
        local new_n = queue_count()
        if new_n == 0 then
            queue_close()
            return
        end
        Queue.cursor = math.min(Queue.cursor, new_n - 1)
        queue_render()
    end)
    
    queue_render()
end

local function queue_toggle()
    if Queue.visible then queue_close() else queue_open() end
end

-- ─── Clipboard ───────────────────────────────────────────────────────────────

local function add_from_clipboard()
    get_clipboard_async(function(text)
        if not text or not is_url(text) then
            notify("Clipboard: not a URL", 2)
            return
        end
        
        if is_playlist_url(text) then
            local pl_url = text:gsub("[?&]v=[^&#]*", "")
            mp.commandv("loadfile", pl_url, "append-play")
            notify("+ Playlist: " .. trunc(text, 60), 4)
        else
            mp.commandv("loadfile", text, "append-play")
            notify("+ " .. trunc(text, 60), 3)
        end
        
        msg.info("Added from clipboard: " .. text)
    end)
end

-- ─── Browser ─────────────────────────────────────────────────────────────────

local function open_in_browser()
    local url = current_url()
    if not is_url(url) then
        notify("No web URL", 2)
        return
    end
    
    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        args = { cfg.browser_bin, url },
    }, function() end)
    
    notify("Opening in " .. cfg.browser_bin, 2)
    msg.info("Opening URL: " .. url)
end

-- ═══════════════════════════════════════════════════════════════════════════════
--  SECTION 12: KEYBINDINGS & INITIALIZATION
-- ═══════════════════════════════════════════════════════════════════════════════

-- Initialize lifecycle
if not Lifecycle:init() then
    msg.error("Failed to initialize yt.lua")
    return
end

-- Register keybindings
mp.add_key_binding("CTRL+SHIFT+s", "yt-search",   yt_search)
mp.add_key_binding("ctrl+f",       "yt-quality",  open_quality_menu)
mp.add_key_binding("ctrl+a",       "yt-clip-add", add_from_clipboard)
mp.add_key_binding("ctrl+n",       "yt-next",     function() mp.commandv("playlist-next") end)
mp.add_key_binding("ctrl+p",       "yt-prev",     function() mp.commandv("playlist-prev") end)
mp.add_key_binding("ctrl+q",       "yt-queue",    queue_toggle)
mp.add_key_binding("alt+d",        "yt-dl-video", function() trigger_download("video") end)
mp.add_key_binding("alt+a",        "yt-dl-audio", function() trigger_download("audio") end)
mp.add_key_binding("ctrl+o",       "yt-browser",  open_in_browser)

-- Script messages (uosc integration)
mp.register_script_message("yt-search",   yt_search)
mp.register_script_message("yt-quality",  open_quality_menu)
mp.register_script_message("yt-dl-video", function() trigger_download("video") end)
mp.register_script_message("yt-dl-audio", function() trigger_download("audio") end)
mp.register_script_message("yt-browser",  open_in_browser)

msg.info("yt.lua loaded — Ctrl+Shift+S search · Ctrl+F quality · Ctrl+Q queue · Alt+D/A download")
