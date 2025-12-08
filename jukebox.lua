-- CC:Tweaked Streaming DFPWM Jukebox
-- Designed with <3 by Antigravity

-- CONFIGURATION
local REPO_URL = "https://raw.githubusercontent.com/Example/MusicRepo/main/" -- CHANGE THIS
local MANIFEST_FILE = "manifest.json"

-- IMPORTS
local dfpwm = require("cc.audio.dfpwm")
local completion = require("cc.shell.completion")

-- PERIPHERALS
local speaker = peripheral.find("speaker")
if not speaker then
    error("Error: No speaker attached. Please attach a speaker to use the Jukebox.", 0)
end

-- STATE
local songs = {}
local selected_index = 1
local is_playing = false
local current_stream_url = nil
local stop_signal = false
local marquee_offset = 0

-- UI COLORS
local BG_COLOR = colors.black
local TEXT_COLOR = colors.white
local ACCENT_COLOR = colors.cyan
local HIGHLIGHT_COLOR = colors.yellow
local ERROR_COLOR = colors.red
local HEADER_COLOR = colors.blue

-- SCREEN SETUP
local w, h = term.getSize()
local main_window = window.create(term.current(), 1, 1, w, h)

-- HELPER: Center Text
local function center_text(y, text, color, bg_color)
    local x = math.floor((w - #text) / 2) + 1
    main_window.setCursorPos(x, y)
    if color then main_window.setTextColor(color) end
    if bg_color then main_window.setBackgroundColor(bg_color) end
    main_window.write(text)
end

-- HELPER: Fetch Manifest
local function fetch_manifest()
    main_window.setBackgroundColor(BG_COLOR)
    main_window.clear()
    center_text(h/2, "Fetching playlist...", ACCENT_COLOR)
    
    local response = http.get(REPO_URL .. MANIFEST_FILE)
    if not response then
        return false, "Could not connect to repository."
    end
    
    local content = response.readAll()
    response.close()
    
    local decoded = textutils.unserializeJSON(content)
    if not decoded or not decoded.songs then
        return false, "Invalid manifest format."
    end
    
    songs = decoded.songs
    return true, "Success"
end

-- PLAYER LOGIC (Runs in parallel)
local function play_song_thread()
    while true do
        if current_stream_url then
            is_playing = true
            stop_signal = false
            
            -- Prepare decoder
            local decoder = dfpwm.make_decoder()
            
            -- Start Stream
            local response = http.get(current_stream_url, nil, true)
            if not response then
                -- Handle error (could signal UI)
                current_stream_url = nil
                is_playing = false
            else
                -- Streaming Loop
                while not stop_signal do
                    local chunk = response.read(4 * 1024) -- 4KB chunks
                    if not chunk then break end -- EOF
                    
                    local buffer = decoder(chunk)
                    
                    while not speaker.playAudio(buffer) do
                        os.pullEvent("speaker_audio_empty")
                        if stop_signal then break end
                    end
                end
                
                response.close()
                current_stream_url = nil
                is_playing = false
            end
        else
            os.pullEvent("play_song_req") -- Wait for request
        end
    end
end

-- UI RENDERER
local function draw_ui()
    main_window.setBackgroundColor(BG_COLOR)
    main_window.clear()
    
    -- Header
    main_window.setCursorPos(1, 1)
    main_window.setBackgroundColor(HEADER_COLOR)
    main_window.clearLine()
    center_text(1, " JUKEBOX NETWORK ", colors.white, HEADER_COLOR)
    
    -- Song List
    local start_y = 3
    local max_display = h - 4
    local scroll_start = 1
    
    if selected_index > max_display then
        scroll_start = selected_index - max_display + 1
    end
    
    for i = 0, max_display - 1 do
        local song_idx = scroll_start + i
        local song = songs[song_idx]
        local y = start_y + i
        
        if song then
            main_window.setCursorPos(2, y)
            if song_idx == selected_index then
                main_window.setTextColor(HIGHLIGHT_COLOR)
                main_window.write("> " .. (song.title or song.name))
            else
                main_window.setTextColor(TEXT_COLOR)
                main_window.write("  " .. (song.title or song.name))
            end
        end
    end
    
    -- Footer / Status
    main_window.setCursorPos(1, h)
    main_window.setBackgroundColor(colors.gray)
    main_window.clearLine()
    main_window.setTextColor(colors.white)
    
    if is_playing then
        local song_name = songs[selected_index] and (songs[selected_index].title or songs[selected_index].name) or "Music"
        main_window.write(" Playing: " .. song_name)
    else
        main_window.write(" [Enter] Play  [Space] Stop  [Q] Quit")
    end
end

-- INPUT/CONTROL THREAD
local function controller_thread()
    -- Initial Load
    local ok, err = fetch_manifest()
    if not ok then
        main_window.setBackgroundColor(BG_COLOR)
        main_window.clear()
        center_text(h/2, "Error: " .. err, ERROR_COLOR)
        center_text(h/2 + 1, "Check URL in file.", ERROR_COLOR)
        os.pullEvent("key") 
        return
    end
    
    while true do
        draw_ui()
        
        local timer = os.startTimer(0.5) -- For refreshing UI if needed
        local event, p1 = os.pullEvent()
        
        if event == "key" then
            if p1 == keys.q then
                stop_signal = true
                current_stream_url = nil
                break
            elseif p1 == keys.up then
                if selected_index > 1 then selected_index = selected_index - 1 end
            elseif p1 == keys.down then
                if selected_index < #songs then selected_index = selected_index + 1 end
            elseif p1 == keys.enter then
                -- Stop current
                stop_signal = true
                sleep(0.1) -- small yield to let player stop
                
                -- Start new
                if songs[selected_index] then
                    current_stream_url = REPO_URL .. songs[selected_index].file
                    os.queueEvent("play_song_req")
                end
            elseif p1 == keys.space then
                stop_signal = true
                current_stream_url = nil
            end
        elseif event == "speaker_audio_empty" then
            -- Consumed by player thread usually, but good to ignore here
        end
    end
end

-- STARTUP
term.clear()
parallel.waitForAll(play_song_thread, controller_thread)
term.clear()
term.setCursorPos(1,1)
