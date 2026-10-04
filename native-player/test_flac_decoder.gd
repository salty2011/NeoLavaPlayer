extends SceneTree
const Decoder=preload("res://flac_decoder.gd")
func _initialize():
 var mono:Dictionary=Decoder.decode("/tmp/oozic-mono.flac")
 assert(mono.has("stream"))
 assert(mono.stream.mix_rate==44100 and mono.stream.stereo)
 assert(absf(mono.stream.get_length()-2.0)<0.01)
 var stereo:Dictionary=Decoder.decode("/tmp/Oozic 24bit test – quoted.FLAC")
 assert(stereo.has("stream"))
 assert(stereo.stream.mix_rate==48000 and stereo.stream.stereo)
 var bad=FileAccess.open("/tmp/oozic-corrupt.flac",FileAccess.WRITE)
 bad.store_string("fLaCinvalid")
 bad.close()
 assert(Decoder.decode("/tmp/oozic-corrupt.flac").has("error"))
 assert(Decoder.decode("/tmp/nonexistent.flac").has("error"))
 # Size guard: afinfo estimate of the 2 s mono fixture as stereo 16-bit PCM.
 var estimate:=Decoder.estimate_decoded_bytes("/tmp/oozic-mono.flac")
 assert(estimate==88200*4)
 assert(Decoder.estimate_decoded_bytes("/tmp/oozic-corrupt.flac")==-1)
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
 print("PASS: mono16/44.1k and stereo24/48k FLAC, preserved rates/durations, missing and corrupt inputs, decoded-size estimate guard, stale temp cleanup")
 quit()
