-- CC:Tweaked Jukebox (Hardware Edition)
-- plays DFPWM files from manifest.json
-- Supports Local Files and HTTP Streams

-- CONFIGURATION
local CONFIG = {
    sides = {
        play_pause = "top",  -- Button for Play/Pause
        prev_song  = "left", -- Button for Previous
        next_song  = "right" -- Button for Next
    },
    manifest_file = "manifest.json",
    volume = 1.0
}

-- IMPORTS
local dfpwm = require("cc.audio.dfpwm")
local speaker = peripheral.find("speaker")

-- STATE
local state = {
    playlist = {},
    current_index = 1,
    is_playing = false,
    stopped = true -- differentiates pause vs stop/initial
}

-- UTILITIES
local function loadManifest()
    if not fs.exists(CONFIG.manifest_file) then
        return false, "Manifest not found"
    end
    local f = fs.open(CONFIG.manifest_file, "r")
    local data = textutils.unserializeJSON(f.readAll())
    f.close()
    
    if data and data.songs then
        state.playlist = data.songs
        return true
    end
    return false, "Invalid JSON"
end

local function drawUI(status_msg)
    term.setBackgroundColor(colors.black)
    term.clear()
    
    local w,h = term.getSize()
    
    -- Title
    term.setCursorPos(1,1)
    term.setBackgroundColor(colors.blue)
    term.setTextColor(colors.white)
    term.clearLine()
    term.write("  JUKEBOX OS  ")
    
    -- Song Info
    term.setBackgroundColor(colors.black)
    local song = state.playlist[state.current_index]
    
    term.setCursorPos(1, 3)
    term.setTextColor(colors.gray)
    term.write("Current Track:")
    
    term.setCursorPos(1, 4)
    if song then
        term.setTextColor(colors.yellow)
        term.write(song.title or "Unknown Title")
    else
        term.setTextColor(colors.red)
        term.write("No Songs Loaded")
    end
    
    -- Status
    term.setCursorPos(1, 6)
    term.setTextColor(colors.white)
    local symbol = state.is_playing and "> PLAYING" or "|| PAUSED"
    if state.stopped then symbol = "[] STOPPED" end
    term.write(symbol)
    
    if status_msg then
        term.setCursorPos(1, h)
        term.setTextColor(colors.red)
        term.write(status_msg)
    end

    -- Instruction
    term.setCursorPos(1, h-2)
    term.setTextColor(colors.gray)
    term.write("Controls: " .. CONFIG.sides.prev_song .. "/" .. CONFIG.sides.play_pause .. "/" .. CONFIG.sides.next_song)
end

-- THREADS

-- Playback Thread
local function audioThread()
    local decoder = dfpwm.make_decoder()
    
    while true do
        local song = state.playlist[state.current_index]
        
        if state.is_playing and song then
            state.stopped = false
            
            -- Determine if local or remote
            local handle = nil
            local is_remote = song.file:find("^http")
            
            if is_remote then
                handle = http.get(song.file, nil, true) -- binary mode
            else
                if fs.exists(song.file) then
                    handle = fs.open(song.file, "rb")
                end
            end
            
            if not handle then
                -- Skip bad file or show error
                state.is_playing = false
                os.queueEvent("ui_update", "File not found: " .. song.file)
                while not state.is_playing do os.pullEvent("song_change") end
            else
                -- Play Loop
                while state.is_playing do
                    -- Read Chunk
                    -- Local fs.read returns byte, handle.read(n) not supported in all versions?
                    -- Actually fs.open binary 'rb' supports read(count) in newer CC.
                    -- http handle supports read(count) too.
                    
                    local chunk
                    if handle.read then
                        chunk = handle.read(16 * 1024) -- 16KB chunk
                    end
                    
                    -- Handle End of File
                    if not chunk or #chunk == 0 then
                        handle.close()
                        
                        -- Auto-advance to next song?
                        -- For now, just stop or loop? Let's stop.
                        state.is_playing = false
                        state.stopped = true
                        os.queueEvent("ui_update")
                        break
                    end
                    
                    -- Decode and Play
                    local buffer = decoder(chunk)
                    while not speaker.playAudio(buffer) do
                        os.pullEvent("speaker_audio_empty")
                        
                        -- Check for interrupts during wait
                        if not state.is_playing or state.current_index ~= state.playlist[state.current_index] then
                            -- This check is tricky because current_index is an index, not the object.
                            -- We better rely on flags.
                        end
                    end
                    
                    -- Check interupts after chunk
                    local ev, p1 = os.pullEventRaw() -- Non-blocking check? No, pullEvent waits.
                    -- We consumed 'speaker_audio_empty'.
                    -- We need to check if user paused/skipped *between* chunks.
                    -- We can listen for custom events?
                    if ev == "song_change" or ev == "stop_req" then
                       handle.close()
                       break
                    elseif ev == "terminate" then
                        handle.close()
                        error("Terminated")
                    else
                        -- Re-queue other events so we don't eat them?
                        -- parallel API usually handles this but we are inside the parallel function.
                        if ev ~= "speaker_audio_empty" then
                            os.queueEvent(ev, p1)
                        end
                    end
                end
                
                if handle and handle.close then handle.close() end
            end
        else
            -- Idle
            os.pullEvent("play_req")
        end
    end
end

-- Since the above audio loop is tricky with consuming events, 
-- simpler approach for CC: Read small chunk, play, yield.
-- 'parallel' API distributes events.

local function safeAudioThread()
    local decoder = dfpwm.make_decoder()
    local file_handle = nil
    
    while true do
        if state.is_playing and state.playlist[state.current_index] then
            local song = state.playlist[state.current_index]
            
            -- Open File if not open
            if not file_handle then
                if song.file:find("^http") then
                    print("Opening stream...")
                    file_handle = http.get(song.file, nil, true)
                else
                    if fs.exists(song.file) then
                        file_handle = fs.open(song.file, "rb")
                    else
                        -- Error
                        state.is_playing = false
                        os.queueEvent("ui_update", "Missing file")
                    end
                end
            end
            
            if file_handle then
                -- Read small chunk
                local chunk = file_handle.read(4 * 1024) -- 4KB
                
                if chunk then
                    local buffer = decoder(chunk)
                    while not speaker.playAudio(buffer) do
                        os.pullEvent("speaker_audio_empty")
                    end
                else
                    -- EOF
                    file_handle.close()
                    file_handle = nil
                    state.is_playing = false
                    state.stopped = true
                    os.queueEvent("ui_update")
                    
                    -- Auto next?
                    -- state.current_index = state.current_index % #state.playlist + 1
                    -- state.is_playing = true 
                end
            end
        else
            -- Clean up handle if paused/stopped
            if file_handle then
                file_handle.close()
                file_handle = nil
            end
            os.pullEvent("play_tick") -- Wait for something to wake us up to check state
        end
    end
end

-- The 'safeAudioThread' above still has a blocking os.pullEvent("speaker_audio_empty").
-- If we pause while it is waiting there, it will hang until speaker is empty (which is fast).
-- But if we skip, we want immediate response.
-- Best Loop:
-- 1. Check state.
-- 2. If playing, read chunk, decoder(chunk).
-- 3. playAudio(buffer). 
-- 4. If false, pullEvent("speaker_audio_empty").
-- 5. Loop.

local function properAudioThread()
    local decoder = dfpwm.make_decoder()
    local handle = nil
    local current_song_file = nil
    
    while true do
        local song = state.playlist[state.current_index]
        
        -- Check if song changed or stopped
        if not state.is_playing or (song and song.file ~= current_song_file) then
            if handle then 
                handle.close()
                handle = nil
            end
            current_song_file = nil
        end
        
        if state.is_playing and song then
            state.stopped = false
            current_song_file = song.file
            
            -- Open if needed
            if not handle then
                if song.file:find("^http") then
                    handle = http.get(song.file, nil, true)
                else
                    local path = song.file
                    if not fs.exists(path) and shell then
                        path = shell.resolve(song.file)
                    end
                    
                    if fs.exists(path) then
                        handle = fs.open(path, "rb")
                    end
                end
                
                if not handle then
                   state.is_playing = false
                   os.queueEvent("ui_update", "File Error: " .. song.file)
                end
            end
            
            if handle then
                -- Perform chunk read
                 -- 6kb is ~1 sec of DFPWM (sample rate 48kHz? No, DFPWM is bits. 6000 bytes * 8 = 48000 bits. 1 sec at 48kbps? standard is usually various).
                 -- reading small chunks makes UI more responsive to Pause
                 local chunk = handle.read(2048) 
                 
                 if chunk and #chunk > 0 then
                    local buffer = decoder(chunk)
                    local ok = speaker.playAudio(buffer)
                    
                    if not ok then
                        os.pullEvent("speaker_audio_empty")
                    end
                 else
                     -- EOF
                     handle.close()
                     handle = nil
                     
                     -- Go to next song automatically
                     if state.current_index < #state.playlist then
                         state.current_index = state.current_index + 1
                     else
                         state.current_index = 1 -- Loop to start
                     end
                     os.queueEvent("ui_update")
                 end
            end
        else
            os.pullEvent("ui_update") -- Wait for state change
        end
    end
end


local function inputThread()
    while true do
        local _, p1 = os.pullEvent()
        
        -- KEYBOARD FALLBACK + REDSTONE
        local previous_req = false
        local next_req = false
        local play_pause_req = false
        
        if _ == "key" then
            if p1 == keys.left then previous_req = true end
            if p1 == keys.right then next_req = true end
            if p1 == keys.space then play_pause_req = true end
        elseif _ == "redstone" then
            -- Check edges
            if redstone.getInput(CONFIG.sides.prev_song) then previous_req = true end 
            if redstone.getInput(CONFIG.sides.next_song) then next_req = true end 
            if redstone.getInput(CONFIG.sides.play_pause) then play_pause_req = true end 
            
            -- Debounce/Wait logic would be needed for real redstone to avoid spam
            -- simplified: just react.
            if previous_req or next_req or play_pause_req then
                sleep(0.2) -- Debounce
            end
        end
        
        local update = false
        if previous_req then
             if state.current_index > 1 then
                state.current_index = state.current_index - 1
             else
                state.current_index = #state.playlist
             end
             -- state.is_playing = false -- Stop on change? optional.
             update = true
        end
        
        if next_req then
             if state.current_index < #state.playlist then
                state.current_index = state.current_index + 1
             else
                state.current_index = 1
             end
             -- state.is_playing = false 
             update = true
        end
        
        if play_pause_req then
            state.is_playing = not state.is_playing
            update = true
        end
        
        if update then
            os.queueEvent("ui_update")
        end
    end
end

local function main()
    local ok, err = loadManifest()
    if not ok then
        print("Error: " .. err)
        return
    end
    
    if not speaker then
        print("Error: No Speaker Found")
        return
    end
    
    drawUI()
    
    -- UI Loop
    local function loopUI()
        while true do
            local e, msg = os.pullEvent("ui_update")
            drawUI(msg)
        end
    end
    
    parallel.waitForAny(loopUI, properAudioThread, inputThread)
end

main()
