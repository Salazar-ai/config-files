-- ============================================
-- MPV Download Script (Video/Audio)
-- Manual download with quality selection
-- ============================================

local mp = require 'mp'
local utils = require 'mp.utils'
local msg = require 'mp.msg'

-- Configuration
local download_dir = os.getenv("HOME") .. "/Videos/MPV-Downloads"
local audio_download_dir = os.getenv("HOME") .. "/Music/MPV-Downloads"

-- Ensure download directories exist
os.execute("mkdir -p " .. download_dir)
os.execute("mkdir -p " .. audio_download_dir)

-- Download video (best quality)
local function download_video()
    local url = mp.get_property("path")
    
    if not url then
        mp.osd_message("No video URL found", 2)
        return
    end
    
    mp.osd_message("Starting video download (best quality)...", 3)
    
    local cmd = string.format(
        'yt-dlp -f "bestvideo+bestaudio/best" --merge-output-format mkv -o "%s/%%(title)s.%%(ext)s" "%s"',
        download_dir, url
    )
    
    -- Run in background
    os.execute(cmd .. " &")
    mp.osd_message("Download started! Check: " .. download_dir, 5)
end

-- Download audio only (best quality)
local function download_audio()
    local url = mp.get_property("path")
    
    if not url then
        mp.osd_message("No audio URL found", 2)
        return
    end
    
    mp.osd_message("Starting audio download (best quality)...", 3)
    
    local cmd = string.format(
        'yt-dlp -f "bestaudio/best" -x --audio-format mp3 --audio-quality 0 -o "%s/%%(title)s.%%(ext)s" "%s"',
        audio_download_dir, url
    )
    
    -- Run in background
    os.execute(cmd .. " &")
    mp.osd_message("Audio download started! Check: " .. audio_download_dir, 5)
end

-- Download current quality
local function download_current_quality()
    local url = mp.get_property("path")
    local format_id = mp.get_property("ytdl-format")
    
    if not url then
        mp.osd_message("No video URL found", 2)
        return
    end
    
    mp.osd_message("Downloading current quality...", 3)
    
    local cmd
    if format_id then
        cmd = string.format(
            'yt-dlp -f "%s" -o "%s/%%(title)s.%%(ext)s" "%s"',
            format_id, download_dir, url
        )
    else
        cmd = string.format(
            'yt-dlp -o "%s/%%(title)s.%%(ext)s" "%s"',
            download_dir, url
        )
    end
    
    os.execute(cmd .. " &")
    mp.osd_message("Download started! Check: " .. download_dir, 5)
end

-- Register keybindings (can be changed in input.conf)
mp.add_key_binding("Ctrl+d", "download-video", download_video)
mp.add_key_binding("Ctrl+Shift+d", "download-audio", download_audio)
mp.add_key_binding("Ctrl+Alt+d", "download-current", download_current_quality)

-- Register menu items for UOSC integration
mp.commandv("script-message-to", "uosc", "set-button", "download_video", 
    "Download Video (Best)", "script-binding download-video")
mp.commandv("script-message-to", "uosc", "set-button", "download_audio",
    "Download Audio (Best)", "script-binding download-audio")

msg.info("Download script loaded. Ctrl+d=Video, Ctrl+Shift+d=Audio")
