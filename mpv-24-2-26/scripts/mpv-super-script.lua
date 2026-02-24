-- =============================================================================
--  MPV SUPER SCRIPT  (combined)
--  Merges: YouTube Search · YouTube Queue · Quality Switcher · YouTube Download
-- =============================================================================
--
--  KEYBINDINGS SUMMARY
--  -------------------
--  ── Script 1 · YouTube Search ──────────────────────────────────────────────
--    Ctrl+Shift+S   → Search YouTube and append results to queue
--
--  ── Script 2 · YouTube Queue ───────────────────────────────────────────────
--    Ctrl+A         → Add URL from clipboard to queue
--    Ctrl+N         → Play next in queue
--    Ctrl+P         → Play previous in queue
--    Ctrl+Q         → Toggle queue display on OSD
--    Ctrl+J         → Move cursor down in queue
--    Ctrl+K         → Move cursor up in queue
--    Ctrl+ENTER     → Play selected video in queue
--    Ctrl+X         → Remove selected video from queue
--    Ctrl+M         → Mark/move video in queue
--    Ctrl+D         → Download currently-playing video (via yt-dlp)
--    Ctrl+Shift+D   → Download selected (cursor) video  (via yt-dlp)
--    Ctrl+O         → Open current video in browser
--    Ctrl+Shift+O   → Open current channel in browser
--    Ctrl+Shift+P   → Show current video info on OSD
--    Ctrl+S         → Save queue to history backend
--    Ctrl+Shift+S   → Save full queue (alternative method)
--    Ctrl+L         → Load queue from history backend
--
--  ── Script 3 · Quality Switcher ────────────────────────────────────────────
--    Ctrl+F         → Open quality-selection menu
--    UP / DOWN      → Navigate quality menu  (active only while menu is open)
--    ENTER          → Confirm quality and reload stream
--
--  ── Script 4 · YouTube Download (yt-dlp) ───────────────────────────────────
--    Alt+D          → Download video  [was Ctrl+D — changed to avoid conflict]
--    Alt+A          → Download audio  [was Ctrl+A — changed to avoid conflict]
--    Alt+S          → Download subtitle [was Ctrl+S — changed to avoid conflict]
--    Ctrl+I         → Download video with embedded subtitles
--    Ctrl+R         → Select download range (cycle modes)
--
-- =============================================================================
--  NOTE: This file must be placed in your mpv scripts directory:
--        ~/.config/mpv/scripts/mpv-super-script.lua
-- =============================================================================

-- =============================================================================
--  SCRIPT 1 · YouTube Search
-- =============================================================================
do

-- Default keybindings:
--      CTRL+SHIFT+s: search video in youtube.
--
local input = require("mp.input")
local limit = 5

mp.add_key_binding("CTRL+SHIFT+s", "search_youtube", function()
	input.get({
		prompt = "Search Youtube:",
		submit = function(query)
			mp.commandv("loadfile", "ytdl://ytsearch" .. limit .. ":" .. query, "append")
			input.terminate()
		end,
	})
end)

end -- end Script 1

-- =============================================================================
--  SCRIPT 2 · YouTube Queue (mpv-youtube-queue)
-- =============================================================================
do

local mp = require("mp")
mp.options = require("mp.options")
local utils = require("mp.utils")
local assdraw = require("mp.assdraw")
local styleOn = mp.get_property("osd-ass-cc/0")
local styleOff = mp.get_property("osd-ass-cc/1")
local YouTubeQueue = {}
local video_queue = {}
local MSG_DURATION = 1.5
local index = 0
local selected_index = 1
local display_offset = 0
local marked_index = nil
local current_video = nil
local destroyer = nil
local timeout
local debug = false

local options = {
	add_to_queue = "ctrl+a",
	download_current_video = "ctrl+d",
	download_selected_video = "ctrl+D",
	move_cursor_down = "ctrl+j",
	move_cursor_up = "ctrl+k",
	move_video = "ctrl+m",
	play_next_in_queue = "ctrl+n",
	open_video_in_browser = "ctrl+o",
	open_channel_in_browser = "ctrl+O",
	play_previous_in_queue = "ctrl+p",
	print_current_video = "ctrl+P",
	print_queue = "ctrl+q",
	remove_from_queue = "ctrl+x",
	play_selected_video = "ctrl+ENTER",
	browser = "firefox",
	clipboard_command = "xclip -o",
	cursor_icon = "➤",
	display_limit = 10,
	download_directory = "~/videos/YouTube",
	download_quality = "720p",
	downloader = "curl",
	font_name = "JetBrains Mono",
	font_size = 12,
	marked_icon = "⇅",
	menu_timeout = 5,
	show_errors = true,
	ytdlp_file_format = "mp4",
	ytdlp_output_template = "%(uploader)s/%(title)s.%(ext)s",
	use_history_db = false,
	backend_host = "http://localhost",
	backend_port = "42069",
	save_queue = "ctrl+s",
	save_queue_alt = "ctrl+S",
	default_save_method = "unwatched",
	load_queue = "ctrl+l",
}
mp.options.read_options(options, "mpv-youtube-queue")

local function destroy()
	timeout:kill()
	mp.set_osd_ass(0, 0, "")
	destroyer = nil
end

timeout = mp.add_periodic_timer(options.menu_timeout, destroy)

-- STYLE {{{
local colors = {
	error = "676EFF",
	selected = "F993BD",
	hover_selected = "FAA9CA",
	cursor = "FDE98B",
	header = "8CFAF1",
	hover = "F2F8F8",
	text = "BFBFBF",
	marked = "C679FF",
}

local notransparent = "\\alpha&H00&"
local semitransparent = "\\alpha&H40&"
local sortoftransparent = "\\alpha&H59&"

local style = {
	error = "{\\c&" .. colors.error .. "&" .. notransparent .. "}",
	selected = "{\\c&" .. colors.selected .. "&" .. semitransparent .. "}",
	hover_selected = "{\\c&" .. colors.hover_selected .. "&\\alpha&H33&}",
	cursor = "{\\c&" .. colors.cursor .. "&" .. notransparent .. "}",
	marked = "{\\c&" .. colors.marked .. "&" .. notransparent .. "}",
	reset = "{\\c&" .. colors.text .. "&" .. sortoftransparent .. "}",
	header = "{\\fn"
		.. options.font_name
		.. "\\fs"
		.. options.font_size * 1.5
		.. "\\u1\\b1\\c&"
		.. colors.header
		.. "&"
		.. notransparent
		.. "}",
	hover = "{\\c&" .. colors.hover .. "&" .. semitransparent .. "}",
	font = "{\\fn" .. options.font_name .. "\\fs" .. options.font_size .. "{" .. sortoftransparent .. "}",
}
-- }}}

-- HELPERS {{{

--- surround string with single quotes if it does not already have them
--- @param s string - the string to surround with quotes
--- @return string | nil - the string surrounded with quotes
local function surround_with_quotes(s)
	if string.sub(s, 0, 1) == '"' and string.sub(s, -1) == '"' then
		return nil
	else
		return '"' .. s .. '"'
	end
end

--- return true if the input is null, empty, or 0
--- @param s any - the input to check for nullity
--- @return boolean - true if the input is null, false otherwise
local function isnull(s)
	if s == nil then
		return true
	elseif type(s) == "string" and s:match("^%s*$") then
		return true
	elseif type(s) == "number" and s == 0 then
		return true
	elseif type(s) == "table" and next(s) == nil then
		return true
	elseif type(s) == "boolean" and not s then
		return true
	end
	return false
end

-- remove single quotes, newlines, and carriage returns from a string
local function strip(s)
	return string.gsub(s, "['\n\r]", "")
end

-- print a message to the OSD
---@param message string - the message to print
---@param duration number - the duration to display the message
---@param s string - the style to use for the message
local function print_osd_message(message, duration, s)
	if s == style.error and not options.show_errors then
		return
	end
	destroy()
	if s == nil then
		s = style.font .. "{" .. notransparent .. "}"
	end
	if duration == nil then
		duration = MSG_DURATION
	end
	mp.osd_message(styleOn .. s .. message .. style.reset .. styleOff .. "\n", duration)
end

---returns true if the provided path exists and is a file
---@param filepath string - the path to check
---@return boolean - true if the path is a file, false otherwise
local function is_file(filepath)
	local result = utils.file_info(filepath)
	if debug and type(result) == "table" then
		print("IS_FILE() check: " .. tostring(result.is_file))
	end
	if result == nil or type(result) ~= "table" then
		return false
	end
	return true
end

---returns the filename given a path (eg. /home/user/file.txt -> file.txt)
---@param filepath string - the path to extract the filename from
---@return string | nil - the filename
local function split_path(filepath)
	if is_file(filepath) then
		return utils.split_path(filepath)
	end
end

--- returns the expanded path of a file. eg. ~/file.txt -> /home/user/file.txt
--- @param path string - the path to expand
--- @return string - the expanded path
local function expanduser(path)
	-- remove trailing slash if it exists
	if string.sub(path, -1) == "/" then
		path = string.sub(path, 1, -2)
	end
	if path:sub(1, 1) == "~" then
		local home = os.getenv("HOME")
		if home then
			return home .. path:sub(2)
		else
			return path
		end
	else
		return path
	end
end

---Open a URL in the browser
---@param url string
local function open_url_in_browser(url)
	local command = options.browser .. " " .. surround_with_quotes(url)
	os.execute(command)
end

--- Opens the current video in the browser
local function open_video_in_browser()
	if current_video and current_video.video_url then
		open_url_in_browser(current_video.video_url)
	end
end

--- Opens the channel of the current video in the browser
local function open_channel_in_browser()
	if current_video and current_video.channel_url then
		open_url_in_browser(current_video.channel_url)
	end
end

-- Internal function to print the contents of the internal playlist to the console
local function print_internal_playlist()
	local count = mp.get_property_number("playlist-count")
	print("Playlist contents:")
	for i = 0, count - 1 do
		local uri = mp.get_property(string.format("playlist/%d/filename", i))
		print(string.format("%d: %s", i, uri))
	end
end

--- Helper function to build the OSD row for the queue
--- @param prefix string - the prefix to add to the row
--- @param s string - the style to apply to the row
--- @param i number - the index of the row
--- @param video_name string - the title of the video
--- @param channel_name string - the name of the channel
--- @return string - the OSD row
local function build_osd_row(prefix, s, i, video_name, channel_name)
	return prefix .. s .. i .. ". " .. video_name .. " - (" .. channel_name .. ")"
end

--- Helper function to determine display range for queue items
--- @param queue_length number Total number of items in queue
--- @param selected number Currently selected index
--- @param limit number Maximum items to display
--- @return number, number start and end indices
local function get_display_range(queue_length, selected, limit)
	local half_limit = math.floor(limit / 2)
	local start_index = selected <= half_limit and 1 or selected - half_limit
	local end_index = math.min(start_index + limit - 1, queue_length)
	return start_index, end_index
end

--- Helper function to get the style for a queue item
--- @param i number Current item index
--- @param current number Currently playing index
--- @param selected number Selected index
--- @return string Style to apply
local function get_item_style(i, current, selected)
	if i == current and i == selected then
		return style.hover_selected
	elseif i == current then
		return style.selected
	elseif i == selected then
		return style.hover
	end
	return style.reset
end

--- Toggle queue visibility
local function toggle_print()
	if destroyer ~= nil then
		destroyer()
	else
		YouTubeQueue.print_queue()
	end
end

-- Function to remove leading and trailing quotes from the first and last arguments of a command table in-place
local function remove_command_quotes(s)
	-- if the first character of the first argument is a quote, remove it
	if string.sub(s[1], 1, 1) == "'" or string.sub(s[1], 1, 1) == '"' then
		s[1] = string.sub(s[1], 2)
	end
	-- if the last character of the last argument is a quote, remove it
	if string.sub(s[#s], -1) == "'" or string.sub(s[#s], -1) == '"' then
		s[#s] = string.sub(s[#s], 1, -2)
	end
end

--- Function to split the clipboard_command into it's parts and return as a table
--- @param cmd string - the command to split
--- @return table - the split command as a table
local function split_command(cmd)
	local components = {}
	for arg in cmd:gmatch("%S+") do
		table.insert(components, arg)
	end
	remove_command_quotes(components)
	return components
end

--- Converts a key-value pair or a table of key-value pairs into a JSON string.
--- If the key is a table, it iterates over the table to construct a JSON object.
--- If the key is a single value, it constructs a JSON object with the provided key and value.
--- @param key any - A single key or a table of key-value pairs to convert.
--- @param val any - The value associated with the key, used only if the key is not a table.
--- @return string | nil - The resulting JSON string, or nil if the input is invalid.
local function convert_to_json(key, val)
	if type(key) == "table" then
		-- Handle the case where key is a table of key-value pairs
		local json = "{"
		local first = true
		for k, v in pairs(key) do
			if not first then
				json = json .. ", "
			end
			first = false

			local quoted_val = string.format('"%s"', v)
			json = json .. string.format('"%s": %s', k, quoted_val)
		end
		json = json .. "}"
		return json
	else
		if type(val) == "string" then
			return string.format('{"%s": "%s"}', key, val)
		else
			return string.format('{"%s": %s}', key, tostring(val))
		end
	end
end

-- }}}

-- QUEUE GETTERS AND SETTERS {{{

--- Gets the video at the specified index
--- @param idx number - the index of the video to get
--- @return table | nil - the video at the specified index
function YouTubeQueue.get_video_at(idx)
	if idx <= 0 or idx > #video_queue then
		print_osd_message("Invalid video index", MSG_DURATION, style.error)
		return nil
	end
	return video_queue[idx]
end

--- returns the content of the clipboard
--- @return string | nil - the content of the clipboard
function YouTubeQueue.get_clipboard_content()
	local command = split_command(options.clipboard_command)
	local res = mp.command_native({
		name = "subprocess",
		playback_only = false,
		capture_stdout = true,
		args = command,
	})

	if res.status ~= 0 then
		print_osd_message("Failed to get clipboard content", MSG_DURATION, style.error)
		return nil
	end

	local content = res.stdout:match("^%s*(.-)%s*$") -- Trim leading/trailing spaces
	if content:match("^https?://") then
		return content
	elseif content:match("^file://") or utils.file_info(content) then
		return content
	else
		print_osd_message("Clipboard content is not a valid URL or file path", MSG_DURATION, style.error)
		return nil
	end
end

--- Function to get the video info from the URL
--- @param url string - the URL to get the video info from
--- @return table | nil - a table containing the video information
function YouTubeQueue.get_video_info(url)
	print_osd_message("Getting video info...", MSG_DURATION * 2)
	local res = mp.command_native({
		name = "subprocess",
		playback_only = false,
		capture_stdout = true,
		args = {
			"yt-dlp",
			"--dump-single-json",
			"--ignore-config",
			"--no-warnings",
			"--skip-download",
			"--playlist-items",
			"1",
			url,
		},
	})

	if res.status ~= 0 or isnull(res.stdout) then
		print_osd_message("Failed to get video info (yt-dlp error)", MSG_DURATION, style.error)
		print("yt-dlp status: " .. res.status)
		return nil
	end

	local data = utils.parse_json(res.stdout)
	if isnull(data) then
		print_osd_message("Failed to parse JSON from yt-dlp", MSG_DURATION, style.error)
		return nil
	end

	local category = nil
	if data.categories then
		category = data.categories[1]
	else
		category = "Unknown"
	end
	local info = {
		channel_url = data.channel_url or "",
		channel_name = data.uploader or "",
		video_name = data.title or "",
		view_count = data.view_count or "",
		upload_date = data.upload_date or "",
		category = category or "",
		thumbnail_url = data.thumbnail or "",
		subscribers = data.channel_follower_count or 0,
	}

	if isnull(info.channel_url) or isnull(info.channel_name) or isnull(info.video_name) then
		print_osd_message("Missing metadata (channel_url, uploader, video_name) in JSON", MSG_DURATION, style.error)
		return nil
	end

	return info
end

--- Prints the currently playing video to the OSD
function YouTubeQueue.print_current_video()
	destroy()
	local current = current_video
	if current and current.vidro_url ~= "" and is_file(current.video_url) then
		print_osd_message("Playing: " .. current.video_url, 3)
	else
		if current and current.video_url then
			print_osd_message("Playing: " .. current.video_name .. " by " .. current.channel_name, 3)
		end
	end
end

-- }}}

-- QUEUE FUNCTIONS {{{

--- Function to set the next or previous video in the queue as the current video
--- direction can be "NEXT" or "PREV".  If nil, "next" is assumed
--- @param direction string - the direction to move in the queue
--- @return table | nil - the video at the new index
function YouTubeQueue.set_video(direction)
	local amt
	direction = string.upper(direction)
	if direction == "NEXT" or direction == nil then
		amt = 1
	elseif direction == "PREV" or direction == "PREVIOUS" then
		amt = -1
	else
		print_osd_message("Invalid direction: " .. direction, MSG_DURATION, style.error)
		return nil
	end
	if index + amt > #video_queue or index + amt == 0 then
		return nil
	end
	index = index + amt
	selected_index = index
	current_video = video_queue[index]
	return current_video
end

--- Function to check if a video is in the queue
--- @param url string - the URL to check
--- @return boolean - true if the video is in the queue, false otherwise
function YouTubeQueue.is_in_queue(url)
	for _, v in ipairs(video_queue) do
		if v.video_url == url then
			return true
		end
	end
	return false
end

--- Function to find the index of the currently playing video
--- @param update_history boolean - whether to update the history database
--- @return number | nil - the index of the currently playing video
function YouTubeQueue.update_current_index(update_history)
	if debug then
		print("Updating current index")
	end
	if #video_queue == 0 then
		return
	end
	if update_history == nil then
		update_history = false
	end
	local current_url = mp.get_property("path")
	for i, v in ipairs(video_queue) do
		if v.video_url == current_url then
			index = i
			selected_index = index
			---@class table
			current_video = YouTubeQueue.get_video_at(index)
			if update_history then
				YouTubeQueue.add_to_history_db(current_video)
			end
			return
		end
	end
	-- if not found, reset the index
	index = 0
end

--- Function to mark and move a video in the queue
--- If no video is marked, the currently selected video is marked
--- If a video is marked, it is moved to the selected position
function YouTubeQueue.mark_and_move_video()
	if marked_index == nil and selected_index ~= index then
		-- Mark the currently selected video for moving
		marked_index = selected_index
	else
		-- Move the previously marked video to the selected position
		---@diagnostic disable-next-line: param-type-mismatch
		YouTubeQueue.reorder_queue(marked_index, selected_index)
		-- print_osd_message("Video moved to the selected position.", 1.5)
		marked_index = nil -- Reset the marked index
	end
	-- Refresh the queue display
	YouTubeQueue.print_queue()
end

--- Function to reorder the queue
--- @param from_index number - the index to move from
--- @param to_index number - the index to move to
function YouTubeQueue.reorder_queue(from_index, to_index)
	if from_index == to_index or to_index == index then
		print_osd_message("No changes made.", 1.5)
		return
	end
	-- Check if the provided indices are within the bounds of the video_queue
	if from_index > 0 and from_index <= #video_queue and to_index > 0 and to_index <= #video_queue then
		-- move the video from the from_index to to_index in the internal playlist.
		-- playlist-move is 0-indexed
		if from_index < to_index and to_index == #video_queue then
			mp.commandv("playlist-move", from_index - 1, to_index)
			if to_index > index then
				index = index - 1
			end
		elseif from_index < to_index then
			mp.commandv("playlist-move", from_index - 1, to_index)
			if to_index > index then
				index = index - 1
			end
		else
			mp.commandv("playlist-move", from_index - 1, to_index - 1)
		end

		-- Remove from from_index and insert at to_index into YouTubeQueue
		local temp_video = video_queue[from_index]
		table.remove(video_queue, from_index)
		table.insert(video_queue, to_index, temp_video)
	else
		print_osd_message("Invalid indices for reordering. No changes made.", MSG_DURATION, style.error)
	end
end

--- Prints the queue to the OSD
--- @param duration number Optional duration to display the queue
function YouTubeQueue.print_queue(duration)
	-- Reset and prepare OSD
	timeout:kill()
	mp.set_osd_ass(0, 0, "")
	timeout:resume()

	if #video_queue == 0 then
		print_osd_message("No videos in the queue or history.", duration, style.error)
		destroyer = destroy
		return
	end

	local ass = assdraw.ass_new()
	ass:append(style.header .. "MPV-YOUTUBE-QUEUE{\\u0\\b0}" .. style.reset .. style.font .. "\n")

	local start_index, end_index = get_display_range(#video_queue, selected_index, options.display_limit)

	for i = start_index, end_index do
		local video = video_queue[i]
		if not video then
			break
		end
		local prefix = (i == selected_index) and style.cursor .. options.cursor_icon .. "\\h" .. style.reset
			or "\\h\\h\\h"
		local item_style = get_item_style(i, index, selected_index)
		local message = build_osd_row(prefix, item_style, i, video.video_name, video.channel_name) .. style.reset
		if i == marked_index then
			message = message .. " " .. style.marked .. options.marked_icon .. style.reset
		end
		ass:append(style.font .. message .. "\n")
	end
	mp.set_osd_ass(0, 0, ass.text)
	if duration then
		mp.add_timeout(duration, destroy)
	end
	destroyer = destroy
end

--- Function to move the cursor on the OSD by a specified amount.
--- Adjusts the selected index and updates the display offset to ensure
--- the selected item is visible within the display limits
--- @param amt number - the number of steps to move the cursor. Positive values move up, negative values move down.
function YouTubeQueue.move_cursor(amt)
	timeout:kill()
	timeout:resume()
	selected_index = selected_index - amt
	if selected_index < 1 then
		selected_index = 1
	elseif selected_index > #video_queue then
		selected_index = #video_queue
	end
	if amt == 1 and selected_index > 1 and selected_index < display_offset + 1 then
		display_offset = display_offset - math.abs(selected_index - amt)
	elseif amt == -1 and selected_index < #video_queue and selected_index > display_offset + options.display_limit then
		display_offset = display_offset + math.abs(selected_index - amt)
	end
	YouTubeQueue.print_queue()
end

--- play the video at the current index
function YouTubeQueue.play_video_at(idx)
	if idx <= 0 or idx > #video_queue then
		print_osd_message("Invalid video index", MSG_DURATION, style.error)
		return nil
	end
	index = idx
	selected_index = idx
	current_video = video_queue[index]
	mp.set_property_number("playlist-pos", index - 1) -- zero-based index
	YouTubeQueue.print_current_video()
	return current_video
end

--- play the next video in the queue
--- @param direction string - the direction to move in the queue
--- @return table | nil - the video at the new index
function YouTubeQueue.play_video(direction)
	direction = string.upper(direction)
	local video = YouTubeQueue.set_video(direction)
	if video == nil then
		print_osd_message("No video available.", MSG_DURATION, style.error)
		return
	end
	current_video = video
	selected_index = index
	-- if the current video is not the first in the queue, then play the video
	-- else, check if the video is playing and if not play the video with replace
	if direction == "NEXT" and #video_queue > 1 then
		YouTubeQueue.play_video_at(index)
	elseif direction == "NEXT" and #video_queue == 1 then
		local state = mp.get_property("core-idle")
		-- yes if the video is loaded but not currently playing
		if state == "yes" then
			mp.commandv("loadfile", video.video_url, "replace")
		end
	elseif direction == "PREV" or direction == "PREVIOUS" then
		mp.set_property_number("playlist-pos", index - 1)
	end
	YouTubeQueue.print_current_video()
end

--- add the video to the queue from the clipboard or call from script-message
--- updates the internal playlist by default, pass 0 to disable
--- @param url string - the URL to add to the queue
--- @param update_internal_playlist number - whether to update the internal playlist
--- @return table | nil - the video added to the queue
function YouTubeQueue.add_to_queue(url, update_internal_playlist)
	if update_internal_playlist == nil then
		update_internal_playlist = 0
	end
	if isnull(url) then
		--- @class string
		url = YouTubeQueue.get_clipboard_content()
		if url == nil then
			return
		end
	end
	if YouTubeQueue.is_in_queue(url) then
		print_osd_message("Video already in queue.", MSG_DURATION, style.error)
		return
	end

	local video, channel_url, video_name
	url = strip(url)
	if not is_file(url) then
		local info = YouTubeQueue.get_video_info(url)
		if info == nil then
			return nil
		end
		video_name = info.video_name
		video = info
		video["video_url"] = url
	else
		channel_url, video_name = split_path(url)
		if isnull(channel_url) or isnull(video_name) then
			print_osd_message("Error getting video info.", MSG_DURATION, style.error)
			return
		end
		video = {
			video_url = url,
			video_name = video_name,
			channel_url = channel_url,
			channel_name = "Local file",
			thumbnail_url = "",
			view_count = "",
			upload_date = "",
			category = "",
			subscribers = "",
		}
	end

	table.insert(video_queue, video)
	-- if the queue was empty, start playing the video
	-- otherwise, add the video to the playlist
	if not current_video then
		YouTubeQueue.play_video("NEXT")
	elseif update_internal_playlist == 0 then
		mp.commandv("loadfile", url, "append-play")
	end
	print_osd_message("Added " .. video_name .. " to queue.", MSG_DURATION)
end

--- Downloads the video at the specified index
--- @param idx number - the index of the video to download
--- @return boolean - true if the video was downloaded successfully, false otherwise
function YouTubeQueue.download_video_at(idx)
	if idx < 0 or idx > #video_queue then
		return false
	end
	local v = video_queue[idx]
	if is_file(v.video_url) then
		print_osd_message("Current video is a local file... doing nothing.", MSG_DURATION, style.error)
		return false
	end
	local o = options
	local q = o.download_quality:sub(1, -2)
	local dl_dir = expanduser(o.download_directory)

	print_osd_message("Downloading " .. v.video_name .. "...", MSG_DURATION)
	-- Run the download command
	mp.command_native_async({
		name = "subprocess",
		capture_stderr = true,
		detach = true,
		args = {
			"yt-dlp",
			"-f",
			"bestvideo[height<="
				.. q
				.. "][ext="
				.. options.ytdlp_file_format
				.. "]+bestaudio/best[height<="
				.. q
				.. "]/bestvideo[height<="
				.. q
				.. "]+bestaudio/best[height<="
				.. q
				.. "]",
			"-o",
			dl_dir .. "/" .. options.ytdlp_output_template,
			"--downloader",
			o.downloader,
			"--",
			v.video_url,
		},
	}, function(success, _, err)
		if success then
			print_osd_message("Finished downloading " .. v.video_name .. ".", MSG_DURATION)
		else
			print_osd_message("Error downloading " .. v.video_name .. ": " .. err, MSG_DURATION, style.error)
		end
	end)
	return true
end

--- Removes the video at the selected index from the queue
--- @return boolean - true if the video was removed successfully, false otherwise
function YouTubeQueue.remove_from_queue()
	if index == selected_index then
		print_osd_message("Cannot remove current video", MSG_DURATION, style.error)
		return false
	end
	table.remove(video_queue, selected_index)
	mp.commandv("playlist-remove", selected_index - 1)
	if current_video and current_video.video_name then
		print_osd_message("Deleted " .. current_video.video_name .. " from queue.", MSG_DURATION)
	end
	if selected_index > 1 then
		selected_index = selected_index - 1
	end
	index = index - 1
	YouTubeQueue.print_queue()
	return true
end

--- Returns a list of URLs in the queue from start_index to the end
--- @param start_index number - the index to start from
--- @return table | nil - a table of URLs
function YouTubeQueue.get_urls(start_index)
	if start_index < 0 or start_index > #video_queue then
		return nil
	end
	local urls = {}
	for i = start_index + 1, #video_queue do
		table.insert(urls, video_queue[i].video_url)
	end
	return urls
end
-- }}}

-- {{{ HISTORY DB

--- Add a video to the history database
--- @param v table - the video to add to the history database
--- @return boolean - true if the video was added successfully, false otherwise
function YouTubeQueue.add_to_history_db(v)
	if not options.use_history_db then
		return false
	end
	local url = options.backend_host .. ":" .. options.backend_port .. "/add_video"
	local json = convert_to_json(v)
	local command = { "curl", "-X", "POST", url, "-H", "Content-Type: application/json", "-d", json }
	if debug then
		print("Adding video to history")
		print("Command: " .. table.concat(command, " "))
	end
	print_osd_message("Adding video to history...", MSG_DURATION)
	mp.command_native_async({
		name = "subprocess",
		playback_only = false,
		capture_stdout = true,
		args = command,
	}, function(success, _, err)
		if not success then
			print_osd_message("Failed to send video data to backend: " .. err, MSG_DURATION, style.error)
			return false
		end
	end)
	print_osd_message("Video added to history db", MSG_DURATION)
	return true
end

--- Saves the remainder of the videos in the queue
--- (all videos after the currently playing video) to the history database
--- @param idx number - the index to start saving from
--- @return boolean - true if the queue was saved successfully, false otherwise
function YouTubeQueue.save_queue(idx)
	if not options.use_history_db then
		return false
	end
	if idx == nil then
		idx = index
	end
	local url = options.backend_host .. ":" .. options.backend_port .. "/save_queue"
	local data = convert_to_json("urls", YouTubeQueue.get_urls(idx + 1))
	if data == nil or data == '{"urls": []}' then
		print_osd_message("Failed to save queue: No videos remaining in queue", MSG_DURATION, style.error)
		return false
	end
	if debug then
		print("Data: " .. data)
	end
	local command = { "curl", "-X", "POST", url, "-H", "Content-Type: application/json", "-d", data }
	if debug then
		print("Saving queue to history")
		print("Command: " .. table.concat(command, " "))
	end
	mp.command_native_async({
		name = "subprocess",
		playback_only = false,
		capture_stdout = true,
		args = command,
	}, function(success, result, err)
		if not success then
			print_osd_message("Failed to save queue: " .. err, MSG_DURATION, style.error)
			return false
		end
		if debug then
			print("Status: " .. result.status)
		end
		if result.status == 0 then
			if idx > 1 then
				print_osd_message("Queue saved to history from index: " .. idx, MSG_DURATION)
			else
				print_osd_message("Queue saved to history.", MSG_DURATION)
			end
		end
	end)
	return true
end

-- loads the queue from the backend
function YouTubeQueue.load_queue()
	if not options.use_history_db then
		return false
	end
	local url = options.backend_host .. ":" .. options.backend_port .. "/load_queue"
	local command = { "curl", "-X", "GET", url }

	mp.command_native_async({
		name = "subprocess",
		playback_only = false,
		capture_stdout = true,
		args = command,
	}, function(success, result, err)
		if not success then
			print_osd_message("Failed to load queue: " .. err, MSG_DURATION, style.error)
			return false
		else
			if result.status == 0 then
				-- split urls based on commas
				local urls = {}
				-- Remove the brackets from json list
				local l = result.stdout:sub(2, -3)
				local item
				for turl in l:gmatch("[^,]+") do
					item = turl:match("^%s*(.-)%s*$"):gsub('"', "'")
					table.insert(urls, item)
				end
				for _, turl in ipairs(urls) do
					YouTubeQueue.add_to_queue(turl, 0)
				end
				print_osd_message("Loaded queue from history.", MSG_DURATION)
			end
		end
	end)
end

-- }}}

-- LISTENERS {{{
-- Function to be called when the end-file event is triggered
-- This function is called when the current file ends or when moving to the
-- next or previous item in the internal playlist
local function on_end_file(event)
	if debug then
		print("End file event triggered: " .. event.reason)
	end
	if event.reason == "eof" then -- The file ended normally
		YouTubeQueue.update_current_index(true)
	end
end

-- Function to be called when the track-changed event is triggered
local function on_track_changed()
	if debug then
		print("Track changed event triggered.")
	end
	YouTubeQueue.update_current_index()
end

local function on_file_loaded()
	if debug then
		print("Load file event triggered.")
	end
	YouTubeQueue.update_current_index(true)
end

-- Function to be called when the playback-restart event is triggered
local function on_playback_restart()
	if debug then
		print("Playback restart event triggered.")
	end
	if current_video == nil then
		local url = mp.get_property("path")
		YouTubeQueue.add_to_queue(url)
		---@diagnostic disable-next-line: param-type-mismatch
		YouTubeQueue.add_to_history_db(current_video)
	end
end

-- }}}

-- KEY BINDINGS {{{
mp.add_key_binding(options.add_to_queue, "add_to_queue", YouTubeQueue.add_to_queue)
mp.add_key_binding(options.play_next_in_queue, "play_next_in_queue", function()
	YouTubeQueue.play_video("NEXT")
end)
mp.add_key_binding(options.play_previous_in_queue, "play_prev_in_queue", function()
	YouTubeQueue.play_video("PREV")
end)
mp.add_key_binding(options.print_queue, "print_queue", toggle_print)
mp.add_key_binding(options.move_cursor_up, "move_cursor_up", function()
	YouTubeQueue.move_cursor(1)
end, {
	repeatable = true,
})
mp.add_key_binding(options.move_cursor_down, "move_cursor_down", function()
	YouTubeQueue.move_cursor(-1)
end, {
	repeatable = true,
})
mp.add_key_binding(options.play_selected_video, "play_selected_video", function()
	YouTubeQueue.play_video_at(selected_index)
end)
mp.add_key_binding(options.open_video_in_browser, "open_video_in_browser", open_video_in_browser)
mp.add_key_binding(options.print_current_video, "print_current_video", YouTubeQueue.print_current_video)
mp.add_key_binding(options.open_channel_in_browser, "open_channel_in_browser", open_channel_in_browser)
mp.add_key_binding(options.download_current_video, "download_current_video", function()
	YouTubeQueue.download_video_at(index)
end)
mp.add_key_binding(options.download_selected_video, "download_selected_video", function()
	YouTubeQueue.download_video_at(selected_index)
end)
mp.add_key_binding(options.move_video, "move_video", YouTubeQueue.mark_and_move_video)
mp.add_key_binding(options.remove_from_queue, "delete_video", YouTubeQueue.remove_from_queue)
mp.add_key_binding(options.save_queue, "save_queue", function()
	if options.default_save_method == "unwatched" then
		YouTubeQueue.save_queue(index)
	else
		YouTubeQueue.save_queue(0)
	end
end)
mp.add_key_binding(options.save_queue_alt, "save_queue_alt", function()
	if options.default_save_method == "unwatched" then
		YouTubeQueue.save_queue(0)
	else
		YouTubeQueue.save_queue(index)
	end
end)
mp.add_key_binding(options.load_queue, "load_queue", YouTubeQueue.load_queue)

mp.register_event("end-file", on_end_file)
mp.register_event("track-changed", on_track_changed)
mp.register_event("playback-restart", on_playback_restart)
mp.register_event("file-loaded", on_file_loaded)

-- keep for backwards compatibility
mp.register_script_message("add_to_queue", YouTubeQueue.add_to_queue)
mp.register_script_message("print_queue", YouTubeQueue.print_queue)

mp.register_script_message("add_to_youtube_queue", YouTubeQueue.add_to_queue)
mp.register_script_message("toggle_youtube_queue", toggle_print)
mp.register_script_message("print_internal_playlist", print_internal_playlist)
mp.register_script_message("reorder_youtube_queue", YouTubeQueue.reorder_queue)
-- }}}

end -- end Script 2

-- =============================================================================
--  SCRIPT 3 · Quality Switcher (youtube-quality)
-- =============================================================================
do

local mp = require 'mp'
local utils = require 'mp.utils'
local msg = require 'mp.msg'
local assdraw = require 'mp.assdraw'

local opts = {
    --key bindings
    toggle_menu_binding = "ctrl+f",
    up_binding = "UP",
    down_binding = "DOWN",
    select_binding = "ENTER",

    --formatting / cursors
    selected_and_active     = "▶ - ",
    selected_and_inactive   = "● - ",
    unselected_and_active   = "▷ - ",
    unselected_and_inactive = "○ - ",

	--font size scales by window, if false requires larger font and padding sizes
	scale_playlist_by_window=false,

    --playlist ass style overrides inside curly brackets, \keyvalue is one field, extra \ for escape in lua
    --example {\\fnUbuntu\\fs10\\b0\\bord1} equals: font=Ubuntu, size=10, bold=no, border=1
    --read http://docs.aegisub.org/3.2/ASS_Tags/ for reference of tags
    --undeclared tags will use default osd settings
    --these styles will be used for the whole playlist. More specific styling will need to be hacked in
    --
    --(a monospaced font is recommended but not required)
    style_ass_tags = "{\\fnmonospace}",

    --paddings for top left corner
    text_padding_x = 5,
    text_padding_y = 5,

    --other
    menu_timeout = 10,

    --use youtube-dl to fetch a list of available formats (overrides quality_strings)
    fetch_formats = true,

    --default menu entries
    quality_strings=[[
    [
    {"4320p" : "bestvideo[height<=?4320p]+bestaudio/best"},
    {"2160p" : "bestvideo[height<=?2160]+bestaudio/best"},
    {"1440p" : "bestvideo[height<=?1440]+bestaudio/best"},
    {"1080p" : "bestvideo[height<=?1080]+bestaudio/best"},
    {"720p" : "bestvideo[height<=?720]+bestaudio/best"},
    {"480p" : "bestvideo[height<=?480]+bestaudio/best"},
    {"360p" : "bestvideo[height<=?360]+bestaudio/best"},
    {"240p" : "bestvideo[height<=?240]+bestaudio/best"},
    {"144p" : "bestvideo[height<=?144]+bestaudio/best"}
    ]
    ]],
}
(require 'mp.options').read_options(opts, "youtube-quality")
opts.quality_strings = utils.parse_json(opts.quality_strings)

local destroyer = nil


function show_menu()
    local selected = 1
    local active = 0
    local current_ytdl_format = mp.get_property("ytdl-format")
    msg.verbose("current ytdl-format: "..current_ytdl_format)
    local num_options = 0
    local options = {}


    if opts.fetch_formats then
        options, num_options = download_formats()
    end

    if next(options) == nil then
        for i,v in ipairs(opts.quality_strings) do
            num_options = num_options + 1
            for k,v2 in pairs(v) do
                options[i] = {label = k, format=v2}
                if v2 == current_ytdl_format then
                    active = i
                    selected = active
                end
            end
        end
    end

    --set the cursor to the currently format
    for i,v in ipairs(options) do
        if v.format == current_ytdl_format then
            active = i
            selected = active
            break
        end
    end

    function selected_move(amt)
        selected = selected + amt
        if selected < 1 then selected = num_options
        elseif selected > num_options then selected = 1 end
        timeout:kill()
        timeout:resume()
        draw_menu()
    end
    function choose_prefix(i)
        if     i == selected and i == active then return opts.selected_and_active 
        elseif i == selected then return opts.selected_and_inactive end

        if     i ~= selected and i == active then return opts.unselected_and_active
        elseif i ~= selected then return opts.unselected_and_inactive end
        return "> " --shouldn't get here.
    end

    function draw_menu()
        local ass = assdraw.ass_new()

        ass:pos(opts.text_padding_x, opts.text_padding_y)
        ass:append(opts.style_ass_tags)

        for i,v in ipairs(options) do
            ass:append(choose_prefix(i)..v.label.."\\N")
        end

		local w, h = mp.get_osd_size()
		if opts.scale_playlist_by_window then w,h = 0, 0 end
		mp.set_osd_ass(w, h, ass.text)
    end

    function destroy()
        timeout:kill()
        mp.set_osd_ass(0,0,"")
        mp.remove_key_binding("move_up")
        mp.remove_key_binding("move_down")
        mp.remove_key_binding("select")
        mp.remove_key_binding("escape")
        destroyer = nil
    end
    timeout = mp.add_periodic_timer(opts.menu_timeout, destroy)
    destroyer = destroy

    mp.add_forced_key_binding(opts.up_binding,     "move_up",   function() selected_move(-1) end, {repeatable=true})
    mp.add_forced_key_binding(opts.down_binding,   "move_down", function() selected_move(1)  end, {repeatable=true})
    mp.add_forced_key_binding(opts.select_binding, "select",    function()
        destroy()
        mp.set_property("ytdl-format", options[selected].format)
        reload_resume()
    end)
    mp.add_forced_key_binding(opts.toggle_menu_binding, "escape", destroy)

    draw_menu()
    return 
end

local ytdl = {
    path = "youtube-dl",
    searched = false,
    blacklisted = {}
}

format_cache={}
function download_formats()
    local function exec(args)
        local ret = utils.subprocess({args = args})
        return ret.status, ret.stdout, ret
    end

    local function table_size(t)
        s = 0
        for i,v in ipairs(t) do
            s = s+1
        end
        return s
    end

    local url = mp.get_property("path")

    url = string.gsub(url, "ytdl://", "") -- Strip possible ytdl:// prefix.

    -- don't fetch the format list if we already have it
    if format_cache[url] ~= nil then 
        local res = format_cache[url]
        return res, table_size(res)
    end
    mp.osd_message("fetching available formats with youtube-dl...", 60)

    if not (ytdl.searched) then
        local ytdl_mcd = mp.find_config_file("youtube-dl")
        if not (ytdl_mcd == nil) then
            msg.verbose("found youtube-dl at: " .. ytdl_mcd)
            ytdl.path = ytdl_mcd
        end
        ytdl.searched = true
    end

    local command = {ytdl.path, "--no-warnings", "--no-playlist", "-J"}
    table.insert(command, url)
    local es, json, result = exec(command)

    if (es < 0) or (json == nil) or (json == "") then
        mp.osd_message("fetching formats failed...", 1)
        msg.error("failed to get format list: " .. err)
        return {}, 0
    end

    local json, err = utils.parse_json(json)

    if (json == nil) then
        mp.osd_message("fetching formats failed...", 1)
        msg.error("failed to parse JSON data: " .. err)
        return {}, 0
    end

    res = {}
    msg.verbose("youtube-dl succeeded!")
    for i,v in ipairs(json.formats) do
        if v.vcodec ~= "none" then
            local fps = v.fps and v.fps.."fps" or ""
            local resolution = string.format("%sx%s", v.width, v.height)
            local l = string.format("%-9s %-5s (%-4s / %s)", resolution, fps, v.ext, v.vcodec)
            local f = string.format("%s+bestaudio/best", v.format_id)
            table.insert(res, {label=l, format=f, width=v.width })
        end
    end

    table.sort(res, function(a, b) return a.width > b.width end)

    mp.osd_message("", 0)
    format_cache[url] = res
    return res, table_size(res)
end


-- register script message to show menu
mp.register_script_message("toggle-quality-menu", 
function()
    if destroyer ~= nil then
        destroyer()
    else
        show_menu()
    end
end)

-- keybind to launch menu
mp.add_key_binding(opts.toggle_menu_binding, "quality-menu", show_menu)

-- special thanks to reload.lua (https://github.com/4e6/mpv-reload/)
function reload_resume()
    local playlist_pos = mp.get_property_number("playlist-pos")
    local reload_duration = mp.get_property_native("duration")
    local time_pos = mp.get_property("time-pos")

    mp.set_property_number("playlist-pos", playlist_pos)

    -- Tries to determine live stream vs. pre-recordered VOD. VOD has non-zero
    -- duration property. When reloading VOD, to keep the current time position
    -- we should provide offset from the start. Stream doesn't have fixed start.
    -- Decent choice would be to reload stream from it's current 'live' positon.
    -- That's the reason we don't pass the offset when reloading streams.
    if reload_duration and reload_duration > 0 then
        local function seeker()
            mp.commandv("seek", time_pos, "absolute")
            mp.unregister_event(seeker)
        end
        mp.register_event("file-loaded", seeker)
    end
end



end -- end Script 3

-- =============================================================================
--  SCRIPT 4 · YouTube Download (youtube-download)
--  NOTE: Alt+D/A/S used instead of Ctrl+D/A/S to avoid conflicts with Script 2
-- =============================================================================
do

local mp = require 'mp'
local utils = require 'mp.utils'
local msg = require 'mp.msg'

local opts = {
    -- Key bindings
    -- Set to empty string "" to disable
    download_video_binding = "alt+d",
    download_audio_binding = "alt+a",
    download_subtitle_binding = "alt+s",
    download_video_embed_subtitle_binding = "ctrl+i",
    select_range_binding = "ctrl+r",
    download_mpv_playlist = "",

    -- Specify audio format: "best", "aac","flac", "mp3", "m4a", "opus", "vorbis", or "wav"
    audio_format = "mp3",

    -- Specify ffmpeg/avconv audio quality
    -- insert a value between 0 (better) and 9 (worse) for VBR or a specific bitrate like 128K
    audio_quality = "0",

    -- Embed the thumbnail on audio files
    embed_thumbnail = false,

    -- Add metadata to audio files
    audio_add_metadata = false,

    -- Add metadata to video files
    video_add_metadata = false,

    -- Same as youtube-dl --format FORMAT
    -- see https://github.com/ytdl-org/youtube-dl/blob/master/README.md#format-selection
    -- set to "current" to download the same quality that is currently playing
    video_format = "",

    -- Remux the video into another container if necessary: "avi", "flv",
    -- "gif", "mkv", "mov", "mp4", "webm", "aac", "aiff", "alac", "flac",
    -- "m4a", "mka", "mp3", "ogg", "opus", "vorbis", "wav"
    remux_video = "",

    -- Encode the video to another format if necessary: "mp4", "flv", "ogg", "webm", "mkv", "avi"
    recode_video = "",

    -- Restrict filenames to only ASCII characters, and avoid "&" and spaces in filenames
    restrict_filenames = true,

    -- Download the whole Youtube playlist (false) or only one video (true)
    -- Same as youtube-dl --no-playlist
    no_playlist = true,

    -- Download the whole mpv playlist (true) or only the current video (false)
    -- This is the default setting, it can be overwritten with the download_mpv_playlist key binding
    mpv_playlist = false,

    -- Use an archive file, see youtube-dl --download-archive
    -- You have these options:
    --  * Set to empty string "" to not use an archive file
    --  * Set an absolute path to use one archive for all downloads e.g. download_archive="/home/user/archive.txt"
    --  * Set a relative path/only a filename to use one archive per directory e.g. download_archive="archive.txt"
    --  * Use $PLAYLIST to create one archive per playlist e.g. download_archive="/home/user/archives/$PLAYLIST.txt"
    download_archive = "",

    -- Use a cookies file for youtube-dl
    -- Same as youtube-dl --cookies
    -- On Windows you need to use a double blackslash or a single fordwardslash
    -- For example "C:\\Users\\Username\\cookies.txt"
    -- Or "C:/Users/Username/cookies.txt"
    cookies = "",

    -- Set '/:dir%mpvconf%' to use mpv config directory to download
    -- OR change to '/:dir%script%' for placing it in the same directory of script
    -- OR change to '~~/ytdl/download' for sub-path of mpv portable_config directory
    -- OR write any variable using '/:var', such as: '/:var%APPDATA%/mpv/ytdl/download' or '/:var%HOME%/mpv/ytdl/download'
    -- OR specify the absolute path, such as: "C:\\Users\\UserName\\Downloads"
    -- OR leave empty "" to use the current working directory
    download_path = "/:dir%mpvconf%/ytdl/download",

    -- Filename format to download file
    -- see https://github.com/ytdl-org/youtube-dl/blob/master/README.md#output-template
    -- For example: "%(title)s.%(ext)s"
    filename = "%(title)s.%(ext)s",

    -- Subtitle language
    -- Same as youtube-dl --sub-lang en
    sub_lang = "en",

    -- Subtitle format
    -- Same as youtube-dl --sub-format best
    sub_format = "best",

    -- Download auto-generated subtitles
    -- Same as youtube-dl --write-auto-subs / --no-write-auto-subs
    sub_auto_generated = false,

    -- Log file for download errors
    log_file = "",

    -- Executable of youtube-dl to use, e.g. "youtube-dl", "yt-dlp" or
    -- path to the executable file
    -- Set to "" to auto-detect the executable
    youtube_dl_exe = "yt-dlp",

    -- Use a config file, see youtube-dl --config-location, instead of
    -- the usual options for this keyboard shortcut. This way you can
    -- overwrite the predefined behaviour of the keyboard shortcut and
    -- all of the above options with a custom download behaviour defined
    -- in each config file.
    -- Set to "" to retain the predefined behaviour
    download_video_config_file = "",
    download_audio_config_file = "",
    download_subtitle_config_file = "",
    download_video_embed_subtitle_config_file= "",

    -- Open a new terminal window/tab for download
    -- This allows you to monitor the download progress
    -- If mpv_playlist is true and the whole mpv playlist should be
    -- downloaded, then all the downloads are scheduled immediately.
    -- Before each download is started, the script waits the given
    -- timeout in seconds
    open_new_terminal = false,
    open_new_terminal_timeout = 3,
    -- Set the command that opens a new terminal (JSON array)
    -- Use "$cwd" as a placeholder for the working directory
    -- Use "$cmd" as a placeholder for the download command
    -- See .conf file for Windows and xfce examples.
    open_new_terminal_command = [[
        ["wt", "-w", "ytdlp", "new-tab", "-d", "$cwd", "cmd", "/K", "$cmd"]
    ]],

    -- Used to localize uosc-submenu content
    -- Must use json format, example for Chinese: [{"Download": "下载","Audio": "音频"}]
    locale_content = [[
        []
    ]],
}

local function table_size(t)
    local s = 0
    for _, _ in pairs(t) do
        s = s + 1
    end
    return s
end

local function exec(args, capture_stdout, capture_stderr)
    local ret = mp.command_native({
        name = "subprocess",
        playback_only = false,
        capture_stdout = capture_stdout,
        capture_stderr = capture_stderr,
        args = args,
    })
    return ret.status, ret.stdout, ret.stderr, ret
end

local function exec_async(args, capture_stdout, capture_stderr, detach, callback)
    return mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stdout = capture_stdout,
        capture_stderr = capture_stderr,
        args = args,
        detach = detach,
    }, callback)
end

local function trim(str)
    return str:gsub("^%s+", ""):gsub("%s+$", "")
end

local function not_empty(str)
    if str == nil or str == "" then
        return false
    end
    return trim(str) ~= ""
end

local function path_separator()
    return package.config:sub(1,1)
end

local function path_join(...)
    return table.concat({...}, path_separator())
end

local function get_current_format()
    -- get the current youtube-dl format or the default value
    local ytdl_format = mp.get_property("options/ytdl-format")
    if not_empty(ytdl_format) then
        return ytdl_format
    end
    ytdl_format = mp.get_property("ytdl-format")
    if not_empty(ytdl_format) then
        return ytdl_format
    end
    return "bestvideo+bestaudio/best"
end


--Read configuration file
(require 'mp.options').read_options(opts, "youtube-download")

--Read text string
local locale_content = utils.parse_json(opts.locale_content)
local open_new_terminal_command = utils.parse_json(opts.open_new_terminal_command)

local is_windows = package.config:sub(1, 1) == "\\"

local function locale(str)
    if str and locale_content then
        for k, v in ipairs(locale_content) do
            return v[str] or str
        end
    end
    return str
end

--Read command line arguments
local ytdl_raw_options = mp.get_property("ytdl-raw-options")
if ytdl_raw_options ~= nil and ytdl_raw_options:find("cookies=") ~= nil then
    local cookie_file = ytdl_raw_options:match("cookies=([^,]+)")
    if cookie_file ~= nil then
        opts.cookies = cookie_file
    end
end

--Try to detect youtube-dl/yt-dlp executable
local executables = {"yt-dlp", "youtube-dl", "yt-dlp_x86", "yt-dlp_macos", "yt-dlp_min", "yt-dlc"}
local function detect_executable()
    local function detect_executable_callback(success, ret, _)
        if not success or ret.status ~= 0 then
            detect_executable()
        else
            msg.debug("Found working executable " .. opts.youtube_dl_exe)
        end
    end
    opts.youtube_dl_exe = table.remove(executables, 1)
    if opts.youtube_dl_exe ~= nil then
        msg.debug("Trying executable '" .. opts.youtube_dl_exe .. "' ...")
        exec_async({opts.youtube_dl_exe, "--version"}, false, false, false, detect_executable_callback)
    else
        msg.error("No working executable found, using fallback 'youtube-dl'")
        opts.youtube_dl_exe = "youtube-dl"
    end
end

if not not_empty(opts.youtube_dl_exe) then
    msg.debug("Trying to detect executable...")
    detect_executable()
end

if opts.download_path:match('^/:dir%%mpvconf%%') then
    opts.download_path = opts.download_path:gsub('/:dir%%mpvconf%%', mp.find_config_file('.'))
elseif opts.download_path:match('^/:dir%%script%%') then
    opts.download_path = opts.download_path:gsub('/:dir%%script%%', mp.find_config_file('scripts'))
elseif opts.download_path:match('^/:var%%(.*)%%') then
    local os_variable = opts.download_path:match('/:var%%(.*)%%')
    opts.download_path = opts.download_path:gsub('/:var%%(.*)%%', os.getenv(os_variable))
elseif opts.download_path:match('^~') then
    opts.download_path = mp.command_native({ "expand-path", opts.download_path })  -- Expands both ~ and ~~
end

--create opts.download_path if it doesn't exist
if not_empty(opts.download_path) and utils.readdir(opts.download_path) == nil then
    local windows_args = { 'powershell', '-NoProfile', '-Command', 'mkdir', string.format("\"%s\"", opts.download_path) }
    local unix_args = { 'mkdir', '-p', opts.download_path }
    local args = is_windows and windows_args or unix_args
    local res = mp.command_native({name = "subprocess", capture_stdout = true, playback_only = false, args = args})
    if res.status ~= 0 then
        msg.error("Failed to create youtube-download save directory "..opts.download_path..". Error: "..(res.error or "unknown"))
        return
    end
end

local DOWNLOAD = {
    VIDEO=1,
    AUDIO=2,
    SUBTITLE=3,
    VIDEO_EMBED_SUBTITLE=4,
    CONFIG_FILE=5
}
local select_range_mode = 0
local start_time_seconds = nil
local start_time_formated = nil
local end_time_seconds = nil
local end_time_formated = nil

local switches = {
    mpv_playlist_toggle = opts.mpv_playlist,
}
local mpv_playlist_status = nil
local is_downloading = false
local process_id = nil
local should_cancel = false
local was_cancelled = false

local script_name = mp.get_script_name()

local function disable_select_range()
    -- Disable range mode
    select_range_mode = 0
    -- Remove the arrow key key bindings
    mp.remove_key_binding("select-range-set-up")
    mp.remove_key_binding("select-range-set-down")
    mp.remove_key_binding("select-range-set-left")
    mp.remove_key_binding("select-range-set-right")
end

local function download(download_type, config_file, overwrite_opts)
    if switches.mpv_playlist_toggle and mpv_playlist_status == nil then
        -- Start downloading the whole mpv playlist
        local playlist_length = mp.get_property_number('playlist-count', 0)
        if playlist_length == 0 then
            mpv_playlist_status = nil
            mp.osd_message("Download failed: mpv playlist is empty", 5)
            return
        end

        -- Store current playlist
        mpv_playlist_status = {}
        local i = 0
        while i < playlist_length do
          local url = mp.get_property('playlist/'..i..'/filename')
          if url ~= nil and (url:find("ytdl://") == 1 or url:find("https?://") == 1) then
            mpv_playlist_status[url] = false
          end
          i = i + 1
        end
    end

    local video_format = opts.video_format
    if overwrite_opts ~= nil then
        if overwrite_opts.video_format ~= nil  then
            video_format = overwrite_opts.video_format
        end
    end

    local start_time = os.date("%c")
    if is_downloading then
        if process_id ~= nil and should_cancel then
            -- cancel here
            mp.osd_message("Canceling download ...", 3)
            was_cancelled = true
            mp.abort_async_command(process_id)
            should_cancel = false
        elseif process_id ~= nil then
            should_cancel = true
            mp.osd_message("Download in progress. Press again to cancel download", 5)
        end
        return
    end
    is_downloading = true
    should_cancel = false
    was_cancelled = false

    local ass0 = mp.get_property("osd-ass-cc/0")
    local ass1 =  mp.get_property("osd-ass-cc/1")

    local mpv_playlist_i = 0
    local mpv_playlist_n = 0
    local url = nil
    if mpv_playlist_status ~= nil then
        for key, value in pairs(mpv_playlist_status) do
            if not value then
                if url == nil then
                    url = key
                end
            else
                mpv_playlist_i = mpv_playlist_i + 1
            end
            mpv_playlist_n = mpv_playlist_n + 1
        end

        if url == nil then
            local n = table_size(mpv_playlist_status)
            mpv_playlist_status = nil
            mp.osd_message("Finished downloading mpv playlist (".. tostring(n) .. " entries)", 5)
            return
        end
    else
        url = mp.get_property("path")
    end

    if url:find("ytdl://") ~= 1 and url:find("https?://") ~= 1
    then
        mp.osd_message("Not a youtube URL: " .. tostring(url), 10)
        is_downloading = false
        return
    end

    url = string.gsub(url, "ytdl://", "") -- Strip possible ytdl:// prefix.

    local list_match = url:match("list=(%w+)")
    local download_archive = opts.download_archive
    if list_match ~= nil and opts.download_archive ~= nil and opts.download_archive:find("$PLAYLIST", 1, true) then
        download_archive = opts.download_archive:gsub("$PLAYLIST", list_match)
    end

    if download_type == DOWNLOAD.CONFIG_FILE then
        mp.osd_message("Download started\n" .. ass0 .. "{\\fs8}--config-location:\n'" .. config_file .. "'" .. ass1, 2)
    elseif download_type == DOWNLOAD.AUDIO then
        mp.osd_message("Audio download started", 2)
    elseif download_type == DOWNLOAD.SUBTITLE then
        mp.osd_message("Subtitle download started", 2)
    elseif download_type == DOWNLOAD.VIDEO_EMBED_SUBTITLE then
        mp.osd_message("Video w/ subtitle download started", 2)
    else
        mp.osd_message("Video download started", 2)
    end

    local filepath = opts.filename
    if not_empty(opts.download_path) then
        filepath = opts.download_path .. "/" .. filepath
    end

    -- Compose command line arguments
    local command = {}

    local range_mode_file_name = nil
    local range_mode_subtitle_file_name = nil
    local start_time_offset = 0

    if download_type == DOWNLOAD.CONFIG_FILE then
        table.insert(command, opts.youtube_dl_exe)
        table.insert(command, "--config-location")
        table.insert(command, config_file)
        table.insert(command, url)
    elseif select_range_mode == 0 or (select_range_mode > 0 and (download_type == DOWNLOAD.AUDIO or download_type == DOWNLOAD.SUBTITLE)) then
        table.insert(command, opts.youtube_dl_exe)
        table.insert(command, "--no-overwrites")
        if opts.restrict_filenames then
          table.insert(command, "--restrict-filenames")
        end
        if not_empty(filepath) then
            table.insert(command, "-o")
            table.insert(command, filepath)
        end
        if opts.no_playlist then
            table.insert(command, "--no-playlist")
        end
        if not_empty(download_archive) then
            table.insert(command, "--download-archive")
            table.insert(command, download_archive)
        end

        if download_type == DOWNLOAD.SUBTITLE then
            table.insert(command, "--sub-lang")
            table.insert(command, opts.sub_lang)
            table.insert(command, "--write-sub")
            table.insert(command, "--skip-download")
            if not_empty(opts.sub_format) then
                table.insert(command, "--sub-format")
                table.insert(command, opts.sub_format)
            end
            if opts.sub_auto_generated then
                table.insert(command, "--write-auto-subs")
            else
                table.insert(command, "--no-write-auto-subs")
            end
            if select_range_mode > 0 then
                mp.osd_message("Range mode is not available for subtitle-only download", 10)
                is_downloading = false
                return
            end
        elseif download_type == DOWNLOAD.AUDIO then
            table.insert(command, "--extract-audio")
            if not_empty(opts.audio_format) then
              table.insert(command, "--audio-format")
              table.insert(command, opts.audio_format)
            end
            if not_empty(opts.audio_quality) then
              table.insert(command, "--audio-quality")
              table.insert(command, opts.audio_quality)
            end
            if opts.embed_thumbnail then
              table.insert(command, "--embed-thumbnail")
            end
            if opts.audio_add_metadata then
              table.insert(command, "--add-metadata")
            end
            if  select_range_mode > 0 then
                local start_time_str = tostring(start_time_seconds)
                local end_time_str = tostring(end_time_seconds)
                table.insert(command, "--external-downloader")
                table.insert(command, "ffmpeg")
                table.insert(command, "--external-downloader-args")
                table.insert(command, "-loglevel warning -nostats -hide_banner -ss ".. start_time_str .. " -to " .. end_time_str .. " -avoid_negative_ts make_zero")
            end
        else --DOWNLOAD.VIDEO or DOWNLOAD.VIDEO_EMBED_SUBTITLE
            if download_type == DOWNLOAD.VIDEO_EMBED_SUBTITLE then
                table.insert(command, "--embed-subs")
                table.insert(command, "--sub-lang")
                table.insert(command, opts.sub_lang)
                if not_empty(opts.sub_format) then
                    table.insert(command, "--sub-format")
                    table.insert(command, opts.sub_format)
                end
                if opts.sub_auto_generated then
                    table.insert(command, "--write-auto-subs")
                else
                    table.insert(command, "--no-write-auto-subs")
                end
            end
            if not_empty(video_format) then
              table.insert(command, "--format")
              if video_format == "current" then
                table.insert(command, get_current_format())
              else
                table.insert(command, video_format)
              end
            end
            if not_empty(opts.remux_video) then
              table.insert(command, "--remux-video")
              table.insert(command, opts.remux_video)
            end
            if not_empty(opts.recode_video) then
              table.insert(command, "--recode-video")
              table.insert(command, opts.recode_video)
            end
            if opts.video_add_metadata then
              table.insert(command, "--add-metadata")
            end
        end
        if not_empty(opts.cookies) then
            table.insert(command, "--cookies")
            table.insert(command, opts.cookies)
        end
        table.insert(command, url)

    elseif select_range_mode > 0 and
        (download_type == DOWNLOAD.VIDEO or download_type == DOWNLOAD.VIDEO_EMBED_SUBTITLE) then

        -- Show download indicator
        mp.set_osd_ass(0, 0, "{\\an9}{\\fs12}⌛🔗")

        start_time_seconds = math.floor(start_time_seconds)
        end_time_seconds = math.ceil(end_time_seconds)

        local start_time_str = tostring(start_time_seconds)
        local end_time_str = tostring(end_time_seconds)

        -- Add time to the file name of the video
        local filename_format
        -- Insert start time/end time
        if not_empty(filepath) then
            if filepath:find("%%%(start_time%)") ~= nil then
                -- Found "start_time" -> replace it
                filename_format = tostring(filepath:
                    gsub("%%%(start_time%)[^diouxXeEfFgGcrs]*[diouxXeEfFgGcrs]", start_time_str):
                    gsub("%%%(end_time%)[^diouxXeEfFgGcrs]*[diouxXeEfFgGcrs]", end_time_str))
            else
                local ext_pattern = "%(ext)s"
                if filepath:sub(-#ext_pattern) == ext_pattern then
                    -- Insert before ext
                    filename_format = filepath:sub(1, #(filepath) - #ext_pattern) ..
                        start_time_str .. "-" ..
                        end_time_str .. ".%(ext)s"
                else
                    -- append at end
                    filename_format = filepath .. start_time_str .. "-" .. end_time_str
                end
            end
        else
            -- default youtube-dl filename pattern
            filename_format = "%(title)s-%(id)s." .. start_time_str .. "-" .. end_time_str .. ".%(ext)s"
        end

        -- Find a suitable format
        local format = "bestvideo[ext*=mp4]+bestaudio/best[ext*=mp4]/best"
        local requested_format = video_format
        if requested_format == "current" then
            requested_format = get_current_format()
        end
        if requested_format == nil or requested_format == "" then
            format = format
        elseif requested_format == "best" then
            -- "best" works, because its a single file stream
            format = "best"
        elseif requested_format:find("mp4") ~= nil then
            -- probably a mp4 format, so use it
            format = requested_format
        else
            -- custom format, no "mp4" found -> use default
            msg.warn("Select range mode requires a .mp4 format or \"best\", found "  ..
            requested_format .. "\n(" .. video_format .. ")" ..
                    "\nUsing default format instead: " .. format)
        end

        -- Get the download url of the video file
        -- e.g.: youtube-dl -g -f bestvideo[ext*=mp4]+bestaudio/best[ext*=mp4]/best -s --get-filename https://www.youtube.com/watch?v=abcdefg
        command = {opts.youtube_dl_exe}
        if opts.restrict_filenames then
            table.insert(command, "--restrict-filenames")
        end
        if not_empty(opts.cookies) then
            table.insert(command, "--cookies")
            table.insert(command, opts.cookies)
        end
        table.insert(command, "-g")
        table.insert(command, "--no-playlist")
        table.insert(command, "-f")
        table.insert(command, format)
        table.insert(command, "-o")
        table.insert(command, filename_format)
        table.insert(command, "-s")
        table.insert(command, "--get-filename")
        table.insert(command, url)

        msg.debug("info exec: " .. table.concat(command, " "))
        local info_status, info_stdout, info_stderr = exec(command, true, true)
        if info_status ~= 0 then
            mp.set_osd_ass(0, 0, "")
            mp.osd_message("Could not retieve download stream url: status=" .. tostring(info_status) .. "\n" ..
                ass0 .. "{\\fs8} " .. info_stdout:gsub("\r", "") .."\n" .. info_stderr:gsub("\r", "") .. ass1, 20)
            msg.debug("info_stdout:\n" .. info_stdout)
            msg.debug("info_stderr:\n" .. info_stderr)
            mp.set_osd_ass(0, 0, "")
            is_downloading = false
            return
        end

        -- Split result into lines
        local info_lines = {}
        local last_index = 0
        local info_lines_N = 0
        while true do
            local start_i, end_i = info_stdout:find("\n", last_index, true)
            if start_i then
                local line = tostring(trim(info_stdout:sub(last_index, start_i)))
                if line ~= "" then
                    table.insert(info_lines, line)
                    info_lines_N = info_lines_N + 1
                end
            else
                break
            end
            last_index = end_i + 1
        end

        if info_lines_N < 2 then
            mp.set_osd_ass(0, 0, "")
            mp.osd_message("Could not extract download stream urls and filename from output\n" ..
                ass0 .. "{\\fs8} " .. info_stdout:gsub("\r", "") .."\n" .. info_stderr:gsub("\r", "") .. ass1, 20)
            msg.debug("info_stdout:\n" .. info_stdout)
            msg.debug("info_stderr:\n" .. info_stderr)
            mp.set_osd_ass(0, 0, "")
            is_downloading = false
            return
        end
        range_mode_file_name = info_lines[info_lines_N]
        table.remove(info_lines)

        if download_type == DOWNLOAD.VIDEO_EMBED_SUBTITLE then
            -- youtube-dl --write-sub --skip-download  https://www.youtube.com/watch?v=abcdefg -o "temp.%(ext)s"
            command = {opts.youtube_dl_exe, "--write-sub", "--skip-download", "--sub-lang", opts.sub_lang}
            if not_empty(opts.sub_format) then
                table.insert(command, "--sub-format")
                table.insert(command, opts.sub_format)
            end
            if opts.sub_auto_generated then
                table.insert(command, "--write-auto-subs")
            else
                table.insert(command, "--no-write-auto-subs")
            end
            local randomName = "tmp_" .. tostring(math.random())
            table.insert(command, "-o")
            table.insert(command, randomName .. ".%(ext)s")
            table.insert(command, url)

            -- Start subtitle download
            msg.debug("exec: " .. table.concat(command, " "))
            local subtitle_status, subtitle_stdout, subtitle_stderr = exec(command, true, true)
            if subtitle_status == 0 and subtitle_stdout:find(randomName) then
                local i, j = subtitle_stdout:find(randomName .. "[^\n]+")
                range_mode_subtitle_file_name = trim(subtitle_stdout:sub(i, j))
                if range_mode_subtitle_file_name ~= "" then
                    if range_mode_file_name:sub(-4) ~= ".mkv" then
                        -- Only mkv supports all kinds of subtitle formats
                        range_mode_file_name = range_mode_file_name:sub(1,-4) .. "mkv"
                    end
                end
            else
                mp.osd_message("Could not find a suitable subtitle")
                msg.debug("subtitle_stdout:\n" .. subtitle_stdout)
                msg.debug("subtitle_stderr:\n" .. subtitle_stderr)
            end

        end

        -- Download earlier (cut off afterwards)
        start_time_offset = math.min(15, start_time_seconds)
        start_time_seconds = start_time_seconds - start_time_offset

        start_time_str = tostring(start_time_seconds)
        end_time_str = tostring(end_time_seconds)

        command = {"ffmpeg", "-loglevel", "warning", "-nostats", "-hide_banner", "-y"}
        for _, value in ipairs(info_lines) do
            table.insert(command, "-ss")
            table.insert(command, start_time_str)
            table.insert(command, "-to")
            table.insert(command, end_time_str)
            table.insert(command, "-i")
            table.insert(command, value)
        end
        if not_empty(range_mode_subtitle_file_name) then
            table.insert(command, "-ss")
            table.insert(command, start_time_str)
            table.insert(command, "-i")
            table.insert(command, range_mode_subtitle_file_name)
            table.insert(command, "-to") -- To must be after input for subtitle
            table.insert(command, end_time_str)
        end
        table.insert(command, "-c")
        table.insert(command, "copy")
        table.insert(command, range_mode_file_name)

        disable_select_range()
    end

    -- Show download indicator
    if mpv_playlist_n > 0 then
        mp.set_osd_ass(0, 0, "{\\an9}{\\fs12}" .. tostring(mpv_playlist_i) .."/" .. tostring(mpv_playlist_n) .. "⌛💾")
    else
      mp.set_osd_ass(0, 0, "{\\an9}{\\fs12}⌛💾")
    end

    -- Callback
    local function download_ended(success, ret, error)
        if mpv_playlist_status ~= nil then
            mpv_playlist_status[url] = true
        end

        local playlist_finished = -1
        if mpv_playlist_status ~= nil then
            local to_do = false
            for _, value in pairs(mpv_playlist_status) do
                if not value then
                    to_do = true
                    break
                end
            end
            if not to_do then
                playlist_finished = table_size(mpv_playlist_status)
                mpv_playlist_status = nil
            end
        end

        process_id = nil
        if opts.open_new_terminal then
            is_downloading = false
            -- Hide download indicator
            mp.set_osd_ass(0, 0, "")

            -- Start next download if downloading whole mpv playlist
            if playlist_finished ~= -1 then
                mp.osd_message("Started last download of mpv playlist (".. tostring(playlist_finished) .. " entries)", 5)
            elseif mpv_playlist_status ~= nil then
                -- Wait a short time starting the next download
                -- otherwise wt.exe will stop the previous command and not open a new tab
                local n = opts.open_new_terminal_timeout
                if n == nil or n < 1 then
                    n = 1
                end
                exec({"ping", "-n", tostring(n), "localhost"}, false, false)
                download(download_type, config_file, overwrite_opts)
            end
            return
        end

        local stdout = ret.stdout
        local stderr = ret.stderr
        local status = ret.status

        if status == 0 and range_mode_file_name ~= nil then
            mp.set_osd_ass(0, 0, "{\\an9}{\\fs12}⌛🔨")

            -- Cut first few seconds to fix errors
            local start_time_offset_str = tostring(start_time_offset)
            if #start_time_offset_str == 1 then
                start_time_offset_str = "0" .. start_time_offset_str
            end
            local max_length = end_time_seconds - start_time_seconds + start_time_offset + 12
            local tmp_file_name = range_mode_file_name .. ".tmp." .. range_mode_file_name:sub(-3)
            command = {"ffmpeg", "-loglevel", "warning", "-nostats", "-hide_banner", "-y",
                "-i", range_mode_file_name, "-ss", "00:00:" .. start_time_offset_str,
                "-c", "copy", "-avoid_negative_ts", "make_zero", "-t", tostring(max_length), tmp_file_name}
            msg.debug("mux exec: " .. table.concat(command, " "))
            local muxstatus, muxstdout, muxstderr = exec(command, true, true)
            if muxstatus ~= 0 and not_empty(muxstderr) then
                msg.warn("Remux log:" .. tostring(muxstdout))
                msg.warn("Remux errorlog:" .. tostring(muxstderr))
            end
            if muxstatus == 0 then
                os.remove(range_mode_file_name)
                os.rename(tmp_file_name, range_mode_file_name)
                if not_empty(range_mode_subtitle_file_name) then
                    os.remove(range_mode_subtitle_file_name)
                end
            end

        end


        is_downloading = false

        -- Hide download indicator
        mp.set_osd_ass(0, 0, "")

        local wrote_error_log = false
        if stderr ~= nil and not_empty(opts.log_file) and not_empty(stderr) then
            -- Write stderr to log file
            local title = mp.get_property("media-title")
            local file = io.open (opts.log_file , "a+")
            file:write("\n[")
            file:write(start_time)
            file:write("] ")
            file:write(url)
            file:write("\n[\"")
            file:write(title)
            file:write("\"]\n")
            file:write(stderr)
            file:close()
            wrote_error_log = true
        end

        -- Retrieve the file name
        local filename = nil
        if range_mode_file_name == nil and stdout then
            local i, j, last_i, start_index = 0
            while i ~= nil do
                last_i, start_index = i, j
                i, j = stdout:find ("Destination: ",j, true)
            end

            if last_i ~= nil then
              local end_index = stdout:find ("\n", start_index, true)
              if end_index ~= nil and start_index ~= nil then
                filename = trim(stdout:sub(start_index, end_index))
               end
            end
        elseif not_empty(range_mode_file_name) then
            filename = range_mode_file_name
        end

        if (status ~= 0) then
            if was_cancelled then
                mp.osd_message("Download cancelled!", 2)
                if filename ~= nil then
                    os.remove(filename .. '.part')
                end
            elseif download_type == DOWNLOAD.CONFIG_FILE and stderr:find("config") ~= nil then
                local start_index = stderr:find("config")
                local end_index = stderr:find ("\n", start_index, true)
                local osd_text = ass0 .. "{\\fs12} " .. stderr:sub(start_index - 7, end_index) .. ass1
                mp.osd_message("Config file problem:\n" .. osd_text, 10)
            else
                mp.osd_message("download failed:\n" .. tostring(stderr), 10)
            end
            msg.error("URL: " .. tostring(url))
            msg.error("Return status code: " .. tostring(status))
            msg.debug(tostring(stdout))
            msg.warn(tostring(stderr))
            return
        end

        if string.find(stdout, "has already been recorded in archive") ~=nil then
            mp.osd_message("Has already been recorded in archive", 5)
            return
        end

        local osd_text = "Download succeeded\n"
        local osd_time = 5
        -- Find filename or directory
        if filename then
            local filepath_display
            local basepath
            if filename:find("/") == nil and filename:find("\\") == nil then
              basepath = utils.getcwd()
              filepath_display = path_join(utils.getcwd(), filename)
            else
              basepath = ""
              filepath_display = filename
            end

            if filepath_display:len() < 100 then
                osd_text = osd_text .. ass0 .. "{\\fs12} " .. filepath_display .. " {\\fs20}" .. ass1
            elseif basepath == "" then
                osd_text = osd_text .. ass0 .. "{\\fs8} " .. filepath_display .. " {\\fs20}" .. ass1
            else
                osd_text = osd_text .. ass0 .. "{\\fs11} " .. basepath .. "\n" .. filename .. " {\\fs20}" ..  ass1
            end
            if wrote_error_log then
                -- Write filename and end time to log file
                local file = io.open (opts.log_file , "a+")
                file:write("[" .. filepath_display .. "]\n")
                file:write(os.date("[end %c]\n"))
                file:close()
            end
        else
            if wrote_error_log then
                -- Write directory and end time to log file
                local file = io.open (opts.log_file , "a+")
                file:write("[" .. utils.getcwd() .. "]\n")
                file:write(os.date("[end %c]\n"))
                file:close()
            end
            osd_text = osd_text .. utils.getcwd()
        end

        -- Show warnings
        if not_empty(stderr) then
            msg.warn("Errorlog:" .. tostring(stderr))
            if stderr:find("incompatible for merge") == nil then
                local i = stderr:find("Input #")
                if i ~= nil then
                    stderr = stderr:sub(i)
                end
                osd_text = osd_text .. "\n" .. ass0 .. "{\\fs8} " .. stderr:gsub("\r", "") .. ass1
                osd_time = osd_time + 5
            end
        end

        if playlist_finished ~= -1 then
            osd_text = osd_text .. "\nFinished downloading mpv playlist (".. tostring(playlist_finished) .. " entries)"
        elseif mpv_playlist_status ~= nil then
            download(download_type, config_file, overwrite_opts)
        end

        mp.osd_message(osd_text, osd_time)
    end

    -- Start download
    msg.debug("exec (async): " .. table.concat(command, " "))

    if opts.open_new_terminal then
        mp.osd_message(table.concat(command, " "), 3)

        -- Check working directory is writable (in case the filename does not specify a directory)
        local cwd = utils.getcwd()
        local has_cwd = false
        for _, value in pairs(open_new_terminal_command) do
            if value == "$cwd" then
                has_cwd = true
                break
            end
        end
        if has_cwd then
            local win_programs = "C:\\Program Files"
            local win_win = "C:\\Windows"
            if cwd:lower():sub(1, #win_programs) == win_programs:lower() or cwd:lower():sub(1, #win_win) == win_win:lower() then
                msg.debug("The mpv working directory ('" ..cwd .."') is probably not writable. Trying %USERPROFILE%...")
                local user_profile = os.getenv("USERPROFILE")
                if  user_profile ~= nil then
                        cwd = user_profile
                else
                        msg.warn("open_new_terminal is enabled, but %USERPROFILE% is not defined")
                        mp.osd_message("open_new_terminal is enabled, but %USERPROFILE% is not defined", 3)
                end
            end
        end

        -- Escape restricted characters on Windows
        if is_windows then
            local restricted = "&<>|"
            for key, value in ipairs(command) do
                command[key] = value:gsub("["..  restricted .. "]", "^%0")
            end
        end

        -- Prepend command with open_new_terminal_command
        local i = 1
        local inserted_cmd = false
        for _, value in pairs(open_new_terminal_command) do
            if value == "$cwd" then
                table.insert(command, i, cwd)
            elseif value == "$cmd" then
                inserted_cmd = true
            elseif inserted_cmd then
                table.insert(command, value) -- append after command
            else
                table.insert(command, i, value) -- prepend before command
            end
            i = i + 1
        end
        msg.debug("exec (async): " .. table.concat(command, " "))
    end

    process_id = exec_async(
        command,
        not opts.open_new_terminal,
        not opts.open_new_terminal,
        opts.open_new_terminal,
        download_ended
    )

end

local function select_range_show()
    local status
    if select_range_mode > 0 then
        if select_range_mode == 2 then
            status = "Download range: Fine tune\n← → start time\n↓ ↑ end time\n" ..
                tostring(opts.select_range_binding) .. " next mode"
        elseif select_range_mode == 1 then
            status = "Download range: Select interval\n← start here\n→ end here\n↓from beginning\n↑til end\n" ..
                tostring(opts.select_range_binding) .. " next mode"
        end
        mp.osd_message("Start: " .. start_time_formated .. "\nEnd:  " .. end_time_formated .. "\n" .. status, 30)
    else
        status = "Download range: Disabled (download full length)"
        mp.osd_message(status, 3)
    end
end

local function select_range_set_left()
    if select_range_mode == 2 then
        start_time_seconds = math.max(0, start_time_seconds - 1)
        if start_time_seconds < 86400 then
            start_time_formated = os.date("!%H:%M:%S", start_time_seconds)
        else
            start_time_formated = tostring(start_time_seconds) .. "s"
        end
    elseif select_range_mode == 1 then
        start_time_seconds = mp.get_property_number("time-pos")
        start_time_formated = mp.command_native({"expand-text","${time-pos}"})
    end
    select_range_show()
end

local function select_range_set_start()
    if select_range_mode == 2 then
        end_time_seconds = math.max(1, end_time_seconds - 1)
        if end_time_seconds < 86400 then
            end_time_formated = os.date("!%H:%M:%S", end_time_seconds)
        else
            end_time_formated = tostring(end_time_seconds) .. "s"
        end
    elseif select_range_mode == 1 then
        start_time_seconds = 0
        start_time_formated = "00:00:00"
    end
    select_range_show()
end

local function select_range_set_end()
    if select_range_mode == 2 then
        end_time_seconds = math.min(mp.get_property_number("duration"), end_time_seconds + 1)
        if end_time_seconds < 86400 then
            end_time_formated = os.date("!%H:%M:%S", end_time_seconds)
        else
            end_time_formated = tostring(end_time_seconds) .. "s"
        end
    elseif select_range_mode == 1 then
        end_time_seconds = mp.get_property_number("duration")
        end_time_formated =  mp.command_native({"expand-text","${duration}"})
    end
    select_range_show()
end

local function select_range_set_right()
    if select_range_mode == 2 then
        start_time_seconds = math.min(mp.get_property_number("duration") - 1, start_time_seconds + 1)
        if start_time_seconds < 86400 then
            start_time_formated = os.date("!%H:%M:%S", start_time_seconds)
        else
            start_time_formated = tostring(start_time_seconds) .. "s"
        end
    elseif select_range_mode == 1 then
        end_time_seconds = mp.get_property_number("time-pos")
        end_time_formated = mp.command_native({"expand-text","${time-pos}"})
    end
    select_range_show()
end


local function select_range()
    -- Cycle through modes
    if select_range_mode == 2 then
        -- Disable range mode
        disable_select_range()
    elseif select_range_mode == 1 then
        -- Switch to "fine tune" mode
        select_range_mode = 2
    else
        select_range_mode = 1
        -- Add keybinds for arrow keys
        mp.add_forced_key_binding("up", "select-range-set-up", select_range_set_end)
        mp.add_forced_key_binding("down", "select-range-set-down", select_range_set_start)
        mp.add_forced_key_binding("left", "select-range-set-left", select_range_set_left)
        mp.add_forced_key_binding("right", "select-range-set-right", select_range_set_right)

        -- Defaults
        if start_time_seconds == nil then
            start_time_seconds = mp.get_property_number("time-pos")
            start_time_formated = mp.command_native({"expand-text","${time-pos}"})
            end_time_seconds = mp.get_property_number("duration")
            end_time_formated =  mp.command_native({"expand-text","${duration}"})
        end
    end
    select_range_show()
end

local function download_mpv_playlist()
    -- Toggle for downloading the whole mpv-playlist
    switches.mpv_playlist_toggle = not switches.mpv_playlist_toggle
    if switches.mpv_playlist_toggle then
        mp.osd_message("Download whole mpv playlist: Enabled", 3)
    else
        mp.osd_message("Download whole mpv playlist: Disabled", 3)
    end
end

local function menu_command(str)
    return string.format('script-message-to %s %s', script_name, str)
end

local function create_menu_data()
    -- uosc menu

    local current_format = get_current_format()

    local video_format = ""
    if not_empty(opts.video_format) then
      video_format = opts.video_format
    end

    if not_empty(opts.remux_video) then
        video_format = video_format .. "/" .. tostring(opts.remux_video)
    end

    if not_empty(opts.recode_video) then
        video_format = video_format .. "/" .. tostring(opts.recode_video)
    end

    local audio_format = ""
    if not_empty(opts.audio_format) then
      audio_format = opts.audio_format
    end

    local sub_format = ""
    if not_empty(opts.sub_format) then
        sub_format = opts.sub_format
    end
    if not_empty(opts.sub_lang) then
        sub_format = sub_format .. " [" .. opts.sub_lang .. "]"
    end

    local url = mp.get_property("path")
    local not_youtube = url == nil or (url:find("ytdl://") ~= 1 and url:find("https?://") ~= 1)

    local items = {
      {
        title = locale('Audio'),
        hint = tostring(audio_format),
        icon = 'audiotrack',
        value = menu_command('audio_default_quality'),
        keep_open = false
      },
      {
        title = locale('Video (Current quality)'),
        hint = tostring(current_format),
        icon = 'play_circle_filled',
        value = menu_command('video_current_quality'),
        keep_open = false
      },
      {
        title = locale('Video (Default quality)'),
        hint = tostring(video_format),
        icon = 'download',
        value = menu_command('video_default_quality'),
        keep_open = false
      },
      {
        title = locale('Video with subtitles'),
        icon = 'hearing_disabled',
        value = menu_command('embed_subtitle_default_quality'),
        keep_open = false
      },
      {
        title = locale('Subtitles'),
        hint = tostring(sub_format),
        icon = 'subtitles',
        value = menu_command('subtitle'),
        keep_open = false
      },
      {
        title = locale('Select range'),
        icon = 'content_cut',
        value = menu_command('cut'),
        keep_open = false
      },
      {
        title = locale('Download whole mpv playlist'),
        icon = switches.mpv_playlist_toggle and 'check_box' or 'check_box_outline_blank',
        value = menu_command('set-state-bool mpv_playlist_toggle ' .. (switches.mpv_playlist_toggle and 'no' or 'yes'))
      },
    }

    if not_empty(opts.download_video_config_file) then
        table.insert(items, {
            title = locale('Video (Config file)'),
            icon = 'build',
            value = menu_command('video_config_file'),
            keep_open = false
        })
    end
    if not_empty(opts.download_audio_config_file) then
        table.insert(items, {
            title = locale('Audio (Config file)'),
            icon = 'build',
            value = menu_command('audio_config_file'),
            keep_open = false
        })
    end
    if not_empty(opts.download_subtitle_config_file) then
        table.insert(items, {
            title = locale('Subtitle (Config file)'),
            icon = 'build',
            value = menu_command('subtitle_config_file'),
            keep_open = false
        })
    end
    if not_empty(opts.download_video_embed_subtitle_config_file) then
        table.insert(items, {
            title = locale('Video with subtitles (Config file)'),
            icon = 'build',
            value = menu_command('video_embed_subtitle_config_file'),
            keep_open = false
        })
    end
    if not_youtube then
        table.insert(items, 1, {
            title = locale('Current file is not a youtube video'),
            icon = 'warning',
            value = menu_command(''),
            bold = true,
            active = 1,
            keep_open = false,
        })
    end

    return {
      type = 'yt_download_menu',
      title = locale('Download'),
      keep_open = true,
      items = items
    }
end

local function download_video()
    if not_empty(opts.download_video_config_file) then
        return download(DOWNLOAD.CONFIG_FILE, opts.download_video_config_file)
    else
        return download(DOWNLOAD.VIDEO)
    end
end

local function download_audio()
    if not_empty(opts.download_audio_config_file) then
        return download(DOWNLOAD.CONFIG_FILE, opts.download_audio_config_file)
    else
        return download(DOWNLOAD.AUDIO)
    end
end

local function download_subtitle()
    if not_empty(opts.download_subtitle_config_file) then
        return download(DOWNLOAD.CONFIG_FILE, opts.download_subtitle_config_file)
    else
        return download(DOWNLOAD.SUBTITLE)
    end
end

local function download_embed_subtitle()
    if not_empty(opts.download_video_embed_subtitle_config_file) then
        return download(DOWNLOAD.CONFIG_FILE, opts.download_video_embed_subtitle_config_file)
    else
        return download(DOWNLOAD.VIDEO_EMBED_SUBTITLE)
    end
end

-- keybind
if not_empty(opts.download_video_binding) then
    mp.add_key_binding(opts.download_video_binding, "download-video", download_video)
end
if not_empty(opts.download_audio_binding) then
    mp.add_key_binding(opts.download_audio_binding, "download-audio", download_audio)
end
if not_empty(opts.download_subtitle_binding) then
    mp.add_key_binding(opts.download_subtitle_binding, "download-subtitle", download_subtitle)
end
if not_empty(opts.download_video_embed_subtitle_binding) then
    mp.add_key_binding(opts.download_video_embed_subtitle_binding, "download-embed-subtitle", download_embed_subtitle)
end
if not_empty(opts.select_range_binding) then
    mp.add_key_binding(opts.select_range_binding, "select-range-start", select_range)
end
if not_empty(opts.download_mpv_playlist) then
    mp.add_key_binding(opts.download_mpv_playlist, "download-mpv-playlist", download_mpv_playlist)
end


-- Open the uosc menu:

mp.register_script_message('set-state-bool', function(prop, value)
    switches[prop] = value == 'yes'
    -- Update currently opened menu
    local json = utils.format_json(create_menu_data())
    mp.commandv('script-message-to', 'uosc', 'update-menu', json)
  end)

mp.register_script_message('menu', function()
    local json = utils.format_json(create_menu_data())
    mp.commandv('script-message-to', 'uosc', 'open-menu', json)
end)

-- Messages from uosc menu entries:

mp.register_script_message('audio_default_quality', function()
    download(DOWNLOAD.AUDIO)
end)

mp.register_script_message('video_current_quality', function()
  download(DOWNLOAD.VIDEO, nil, {video_format = "current"})
end)

mp.register_script_message('video_default_quality', function()
    download(DOWNLOAD.VIDEO)
end)

mp.register_script_message('embed_subtitle_default_quality', function()
    download(DOWNLOAD.VIDEO_EMBED_SUBTITLE)
end)

mp.register_script_message('subtitle', function()
    download(DOWNLOAD.SUBTITLE)
end)

mp.register_script_message('cut', function()
    select_range()
end)

mp.register_script_message('toggle_download_mpv_playlist', function()
    download_mpv_playlist()
end)

mp.register_script_message('video_config_file', function()
    download(DOWNLOAD.CONFIG_FILE, opts.download_video_config_file)
end)

mp.register_script_message('audio_config_file', function()
    download(DOWNLOAD.CONFIG_FILE, opts.download_audio_config_file)
end)

mp.register_script_message('subtitle_config_file', function()
    download(DOWNLOAD.CONFIG_FILE, opts.download_subtitle_config_file)
end)

mp.register_script_message('video_embed_subtitle_config_file', function()
    download(DOWNLOAD.CONFIG_FILE, opts.download_video_embed_subtitle_config_file)
end)


end -- end Script 4
