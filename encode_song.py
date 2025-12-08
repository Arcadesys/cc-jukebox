import wave
import sys
import struct
import base64
import os

# usage: python encode_song.py input.wav output.lua [sample_rate]

def encode_dfpwm(pcm_samples):
    """
    Encodes 8-bit signed PCM samples (-128 to 127) into DFPWM.
    This is an approximation of the standard DFPWM1a algorithm.
    """
    charge = 0
    strength = 0
    previous_bit = False
    
    out_bytes = bytearray()
    current_byte = 0
    bit_idx = 0
    
    for sample in pcm_samples:
        # Predict
        bit = (sample > charge)
        
        # Update Strength
        if bit == previous_bit:
            strength += 1
        else:
            strength -= 1
        
        if strength < 0: strength = 0
        if strength > 63: strength = 63
        
        # Update Charge
        # Uses a heuristic response curve similar to standard DFPWM
        step = (strength << 2) + (1 if strength < 50 else 0) 
        # Tuning: (strength << 2) + 2 is rough but works.
        change = (strength << 2) + 2
        
        # Apply change
        if bit:
            charge += change
        else:
            charge -= change
            
        # Clamp charge
        if charge > 127: charge = 127
        if charge < -128: charge = -128
        
        previous_bit = bit
        
        # Pack (LSB first convention often used, but CC handles bits effectively as stream)
        # We'll pack LSB first (1st sample = bit 0)
        if bit:
            current_byte |= (1 << bit_idx)
        
        bit_idx += 1
        if bit_idx == 8:
            out_bytes.append(current_byte)
            current_byte = 0
            bit_idx = 0
            
    if bit_idx > 0:
        out_bytes.append(current_byte)
        
    return out_bytes

def main():
    if len(sys.argv) < 2:
        print("Usage: python encode_song.py <input.wav> [output.lua] [sample_rate]")
        print("Example: python encode_song.py song.wav install_song.lua 16000")
        return
        
    input_file = sys.argv[1]
    output_file = sys.argv[2] if len(sys.argv) > 2 else "install_song.lua"
    
    target_rate = 48000
    if len(sys.argv) > 3:
        target_rate = int(sys.argv[3])
    
    # 1. Read WAV
    try:
        w = wave.open(input_file, 'rb')
    except Exception as e:
        print(f"Error opening wav: {e}")
        return
        
    params = w.getparams()
    nchannels, sampwidth, framerate, nframes = params[:4]
    
    print(f"Input: {framerate}Hz, {nchannels}ch, {sampwidth*8}bit, {nframes} frames")
    
    # Read all frames
    frames = w.readframes(nframes)
    w.close()
    
    # 2. Convert to Mono 8-bit Signed
    samples = []
    
    # helper: bytes to int
    def get_sample(idx):
        if sampwidth == 1:
            # 8-bit unsigned 0..255 -> -128..127
            return frames[idx] - 128
        elif sampwidth == 2:
            # 16-bit signed -32768..32767 -> -128..127
            # unpack_from requires a buffer, frames is bytes
            val = struct.unpack_from('<h', frames, idx)[0]
            # reduce to 8-bit
            return val // 256
        return 0

    step = sampwidth * nchannels
    for i in range(0, len(frames), step):
        # Average channels if stereo
        val = get_sample(i)
        if nchannels > 1:
            for ch in range(1, nchannels):
                val += get_sample(i + ch * sampwidth)
            val //= nchannels
        samples.append(val)
        
    # 3. Resample / Downsample
    # We use simple nearest-neighbor/skip for simplicity
    
    if target_rate != framerate:
        print(f"Resampling from {framerate} to {target_rate}...")
        ratio = framerate / target_rate
        new_samples = []
        idx = 0.0
        while idx < len(samples):
            new_samples.append(samples[int(idx)])
            idx += ratio
        samples = new_samples
    
    print(f"Encoding {len(samples)} samples...")
    
    # 4. Encode
    dfpwm_data = encode_dfpwm(samples)
    
    print(f"Encoded size: {len(dfpwm_data)} bytes")
    
    # 5. Generate Lua
    # Use Hex encoding for safety in transport (drag and drop)
    hex_data = ''.join(f'{b:02X}' for b in dfpwm_data)
    
    # Chunking
    chunks = [hex_data[i:i+80] for i in range(0, len(hex_data), 80)]
    
    song_name = os.path.splitext(os.path.basename(input_file))[0]
    final_name = song_name + ".dfpwm"
    
    lua_content = "local h = table.concat({\n"
    for c in chunks:
        lua_content += f'"{c}",\n'
    lua_content += '})\n\n'
    
    lua_content += f"""
print("Installing {final_name}...")
local f = fs.open("{final_name}", "wb")
if not f then error("Cannot open file") end
for i=1, #h, 2 do
    local b = tonumber(h:sub(i, i+1), 16)
    f.write(b)
end
f.close()
print("Saved {final_name} ({len(dfpwm_data)} bytes)")

-- Update manifest.json
local manifest_path = "manifest.json"
if fs.exists(manifest_path) then
    print("Updating manifest...")
    local f = fs.open(manifest_path, "r")
    local content = f.readAll()
    f.close()
    
    local data = textutils.unserializeJSON(content)
    if not data then data = {{songs={{}}}} end
    if not data.songs then data.songs = {{}} end
    
    -- Check if exists
    local exists = false
    for _, s in ipairs(data.songs) do
        if s.file == "{final_name}" then exists = true end
    end
    
    if not exists then
        table.insert(data.songs, {{
            title = "{song_name}",
            file = "{final_name}"
        }})
        
        local f = fs.open(manifest_path, "w")
        f.write(textutils.serializeJSON(data))
        f.close()
        print("Added to manifest.")
    else
        print("Song already in manifest.")
    end
else
    -- Create new manifest
    local data = {{
        songs = {{
            {{ title = "{song_name}", file = "{final_name}" }}
        }}
    }}
    local f = fs.open(manifest_path, "w")
    f.write(textutils.serializeJSON(data))
    f.close()
    print("Created manifest.json")
end
"""
    
    with open(output_file, 'w') as f:
        f.write(lua_content)
        
    print(f"Created {output_file}")
    print("1. Drag and drop this file into your ComputerCraft terminal.")
    print(f"2. Run output file (e.g. type 'install_song').")
    print("3. The song will be installed and added to your playlist.")

if __name__ == '__main__':
    main()
