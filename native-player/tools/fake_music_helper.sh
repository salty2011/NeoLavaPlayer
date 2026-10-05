#!/bin/sh
# Fake oozic-music-helper for test_music_bridge.gd (same subcommands, exit
# codes and JSON shapes as docs/MUSIC_HELPER.md; never touches Music).
# Environment:
#   FAKE_HELPER_LOG    each invocation's arguments are appended as one line
#   FAKE_LIBRARY_EXIT  exit code for `library` (default 0)
#   FAKE_CONTROL_EXIT  exit code for `control` (default 0)
#   FAKE_TAP_EXIT      `tap` writes its header and an error event, then exits with it
#   FAKE_TAP_PCM       file `tap` copies to stdout (f32le stereo) before idling
#   FAKE_TAP_COUNTER   file counting `tap` starts; start N then uses
#                      FAKE_TAP_PCM_<N> instead of FAKE_TAP_PCM when it is set
#                      (e.g. silence, silence, then sound across retries)
#   FAKE_TAP_EVENTS    file of JSON event lines `tap` writes to stderr after its header
#   FAKE_WATCH_FILE    lines `watch` prints before idling
[ -n "$FAKE_HELPER_LOG" ] && echo "$*" >> "$FAKE_HELPER_LOG"
case "$1" in
library)
	if [ "${FAKE_LIBRARY_EXIT:-0}" != 0 ]; then
		echo "library: access denied (fake)" >&2
		exit "$FAKE_LIBRARY_EXIT"
	fi
	cat <<'JSON'
{"tracks":[{"id":"0000000000000001","title":"Alpha","artist":"Artist One","album":"First Album","album_artist":"","track_number":2,"disc_number":1,"duration_ms":200000,"genre":"Pop","location":null,"playable_file":false,"protected":false,"cloud_only":true,"kind":"Apple Music AAC audio file"},{"id":"0000000000000002","title":"Beta","artist":"Artist One","album":"First Album","album_artist":"","track_number":1,"disc_number":1,"duration_ms":180000,"genre":"Pop","location":null,"playable_file":false,"protected":false,"cloud_only":true,"kind":"Apple Music AAC audio file"},{"id":"0000000000000003","title":"Local Song","artist":"Local Artist","album":"","album_artist":"","track_number":0,"disc_number":0,"duration_ms":95000,"genre":"","location":"/Music/Local Song.mp3","playable_file":true,"protected":false,"cloud_only":false,"kind":"MPEG audio file"},{"id":"0000000000000004","title":"Old Purchase","artist":"Artist Two","album":"Shop","album_artist":"Various","track_number":1,"disc_number":1,"duration_ms":120000,"genre":"","location":"/Music/Old.m4p","playable_file":false,"protected":true,"cloud_only":false,"kind":"Protected AAC audio file"}],
 "playlists":[{"id":"00000000000000AA","name":"Mix","track_ids":["0000000000000002","0000000000000003","FFFFFFFFFFFFFFFF"]}]}
JSON
	;;
permissions)
	echo '{"media_library":"granted","audio_capture":"denied","screen_capture":"not_granted","automation_music":"granted","music_running":true}'
	;;
control)
	code=${FAKE_CONTROL_EXIT:-0}
	if [ "$code" = 0 ]; then
		echo "{\"ok\":true,\"command\":\"$2\"}"
	else
		echo "{\"ok\":false,\"command\":\"$2\",\"error\":\"fake\",\"message\":\"fake failure\"}"
	fi
	exit "$code"
	;;
watch)
	[ -n "$FAKE_WATCH_FILE" ] && cat "$FAKE_WATCH_FILE"
	exec sleep 30
	;;
tap)
	echo '{"rate":44100,"channels":2,"format":"f32le","source":"app","backend":"tap"}' >&2
	if [ -n "$FAKE_TAP_EXIT" ]; then
		echo '{"event":"error","error":"permission_denied","message":"fake"}' >&2
		exit "$FAKE_TAP_EXIT"
	fi
	pcm="$FAKE_TAP_PCM"
	if [ -n "$FAKE_TAP_COUNTER" ]; then
		n=$(( $(cat "$FAKE_TAP_COUNTER" 2>/dev/null || echo 0) + 1 ))
		echo "$n" > "$FAKE_TAP_COUNTER"
		eval "pcm=\${FAKE_TAP_PCM_$n:-}"
	fi
	[ -n "$FAKE_TAP_EVENTS" ] && cat "$FAKE_TAP_EVENTS" >&2
	[ -n "$pcm" ] && cat "$pcm"
	exec sleep 30
	;;
version)
	echo '{"version":"fake"}'
	;;
*)
	echo "usage: fake" >&2
	exit 1
	;;
esac
