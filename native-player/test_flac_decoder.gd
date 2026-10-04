extends SceneTree
const Decoder=preload("res://flac_decoder.gd")
## PCM WAV bytes of a 440 Hz sine (16- or 24-bit little-endian).
static func wav_bytes(rate:int,channels:int,bits:int,seconds:float)->PackedByteArray:
 var frames:=int(rate*seconds)
 var width:=bits/8
 var data:=PackedByteArray()
 data.resize(frames*channels*width)
 var scale:=float((1<<(bits-1))-1)*0.5
 var o:=0
 for i in frames:
  var v:=int(sin(TAU*440.0*i/rate)*scale)
  for c in channels:
   for b in width:
    data[o]=(v>>(8*b))&0xff
    o+=1
 var out:=PackedByteArray()
 out.append_array("RIFF".to_ascii_buffer()); out.append_array(_u32(36+data.size())); out.append_array("WAVEfmt ".to_ascii_buffer())
 out.append_array(_u32(16)); out.append_array(_u16(1)); out.append_array(_u16(channels)); out.append_array(_u32(rate))
 out.append_array(_u32(rate*channels*width)); out.append_array(_u16(channels*width)); out.append_array(_u16(bits))
 out.append_array("data".to_ascii_buffer()); out.append_array(_u32(data.size())); out.append_array(data)
 return out
static func _u32(v:int)->PackedByteArray: return PackedByteArray([v&0xff,(v>>8)&0xff,(v>>16)&0xff,(v>>24)&0xff])
static func _u16(v:int)->PackedByteArray: return PackedByteArray([v&0xff,(v>>8)&0xff])

## Encode a WAV to FLAC with macOS afconvert; returns the FLAC path.
static func make_flac(dir:String,name:String,wav:PackedByteArray)->String:
 var wav_path:=dir.path_join(name.get_basename()+".wav")
 var f:=FileAccess.open(wav_path,FileAccess.WRITE)
 f.store_buffer(wav)
 f.close()
 var flac_path:=dir.path_join(name)
 assert(OS.execute("/usr/bin/afconvert",PackedStringArray([wav_path,flac_path,"-f","flac","-d","flac"]))==0)
 DirAccess.remove_absolute(wav_path)
 return flac_path

func _initialize():
 # Fixtures are generated here (no files outside the repo): mono 16-bit
 # 44.1 kHz 2 s, and stereo 24-bit 48 kHz with a quoted/non-ASCII name.
 var dir:=ProjectSettings.globalize_path("user://test-fixtures")
 DirAccess.make_dir_recursive_absolute(dir)
 var mono_path:=make_flac(dir,"oozic-mono.flac",wav_bytes(44100,1,16,2.0))
 var stereo_path:=make_flac(dir,"Oozic 24bit test – quoted.FLAC",wav_bytes(48000,2,24,1.0))
 var corrupt_path:=dir.path_join("oozic-corrupt.flac")
 var mono:Dictionary=Decoder.decode(mono_path)
 assert(mono.has("stream"))
 assert(mono.stream.mix_rate==44100 and mono.stream.stereo)
 assert(absf(mono.stream.get_length()-2.0)<0.01)
 var stereo:Dictionary=Decoder.decode(stereo_path)
 assert(stereo.has("stream"))
 assert(stereo.stream.mix_rate==48000 and stereo.stream.stereo)
 var bad=FileAccess.open(corrupt_path,FileAccess.WRITE)
 bad.store_string("fLaCinvalid")
 bad.close()
 assert(Decoder.decode(corrupt_path).has("error"))
 assert(Decoder.decode(dir.path_join("nonexistent.flac")).has("error"))
 # Size guard: afinfo estimate of the 2 s mono fixture as stereo 16-bit PCM.
 var estimate:=Decoder.estimate_decoded_bytes(mono_path)
 assert(estimate==88200*4)
 assert(Decoder.estimate_decoded_bytes(corrupt_path)==-1)
 assert(Decoder.size_error(2*1024*1024*1024).contains("too long"))
 # Stale temp WAVs from a dead process are removed; unrelated files remain.
 var stale=FileAccess.open("user://flac-999999-1.wav",FileAccess.WRITE)
 stale.store_string("x")
 stale=null
 var keep=FileAccess.open("user://flac-notes.txt",FileAccess.WRITE)
 keep.store_string("x")
 keep=null
 assert(Decoder.clean_stale_temp_files()==0 and FileAccess.file_exists("user://flac-999999-1.wav"))
 assert(Decoder.clean_stale_temp_files(0)>=1)
 assert(not FileAccess.file_exists("user://flac-999999-1.wav") and FileAccess.file_exists("user://flac-notes.txt"))
 DirAccess.remove_absolute(ProjectSettings.globalize_path("user://flac-notes.txt"))
 for file in [mono_path,stereo_path,corrupt_path]: DirAccess.remove_absolute(file)
 print("PASS: mono16/44.1k and stereo24/48k FLAC, preserved rates/durations, missing and corrupt inputs, decoded-size estimate guard, stale temp cleanup")
 quit()
