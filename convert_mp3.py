import os
import sys
import subprocess
import wave
import struct
import json

# Try to import the existing encoder
try:
    import encode_song
except ImportError:
    print("Error: encode_song.py not found in current directory.")
    sys.exit(1)

def convert_mp3_to_wav(mp3_path):
    wav_path = mp3_path.rsplit('.', 1)[0] + ".temp.wav"
    # ffmpeg -y -i input.mp3 -ac 1 -ar 48000 -sample_fmt s16 output.wav
    # We use 48kHz as target rate
    cmd = [
        "ffmpeg", "-y", 
        "-i", mp3_path, 
        "-ac", "1", 
        "-ar", "48000", 
        "-sample_fmt", "s16", 
        wav_path
    ]
    
    try:
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return wav_path
    except FileNotFoundError:
        print("CRITICAL: ffmpeg not found.")
        print("Please install it by running: winget install Gyan.FFmpeg")
        print("After installing, you may need to restart your terminal.")
        return None
    except subprocess.CalledProcessError:
        print("Error: ffmpeg failed to convert the file.")
        return None

def process_file(mp3_filename):
    if not os.path.exists(mp3_filename):
        print(f"File not found: {mp3_filename}")
        return

    print(f"Processing {mp3_filename}...")
    
    # 1. Convert to WAV
    wav_path = convert_mp3_to_wav(mp3_filename)
    if not wav_path:
        return
        
    # 2. Read WAV and Prepare Samples
    try:
        w = wave.open(wav_path, 'rb')
        params = w.getparams()
        frames = w.readframes(params.nframes)
        w.close()
        os.remove(wav_path) # Cleanup temp file
    except Exception as e:
        print(f"Error reading WAV data: {e}")
        if os.path.exists(wav_path): os.remove(wav_path)
        return

    # Convert 16-bit PCM to 8-bit signed samples
    # We requested s16 from ffmpeg, so it should be consistent.
    samples = []
    total_samples = len(frames) // 2
    for i in range(total_samples):
        val = struct.unpack_from('<h', frames, i*2)[0]
        # Downscale to -128..127
        samples.append(val // 256)
        
    print(f"Encoding {len(samples)} samples to DFPWM...")
    
    # 3. Encode
    dfpwm_data = encode_song.encode_dfpwm(samples)
    
    # 4. Save DFPWM
    dfpwm_filename = mp3_filename.rsplit('.', 1)[0] + ".dfpwm"
    with open(dfpwm_filename, 'wb') as f:
        f.write(dfpwm_data)
        
    print(f"Saved: {dfpwm_filename}")
    
    # 5. Update Manifest
    update_manifest(mp3_filename, dfpwm_filename)

def update_manifest(input_title_path, output_path):
    manifest_path = "manifest.json"
    
    # Derive a nice title
    base_name = os.path.basename(input_title_path)
    title = base_name.rsplit('.', 1)[0]
    
    # Normalize path for JSON (forward slashes)
    file_entry = output_path.replace("\\", "/")
    
    if os.path.exists(manifest_path):
        with open(manifest_path, 'r') as f:
            try:
                data = json.load(f)
            except:
                data = {"songs": []}
    else:
        data = {"songs": []}
        
    if "songs" not in data:
        data["songs"] = []
        
    # Check for duplicate
    exists = False
    for song in data["songs"]:
        if song.get("file") == file_entry:
            exists = True
            break
            
    if not exists:
        data["songs"].append({
            "title": title,
            "file": file_entry
        })
        
        with open(manifest_path, 'w') as f:
            json.dump(data, f, indent=4)
        print("Updated manifest.json")
    else:
        print("Song already in manifest.")

if __name__ == "__main__":
    if len(sys.argv) > 1:
        target = sys.argv[1]
    else:
        # Default for the current request
        target = r"songs\Neon Nights and Velvet Dreams.mp3"
        
    process_file(target)
