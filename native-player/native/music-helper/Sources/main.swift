// oozic-music-helper: Music library / playback-control / audio-capture helper
// for OozicPlayer. Contract: native-player/docs/MUSIC_HELPER.md
import Foundation

let helperVersion = "1.0.0"

let usage = """
oozic-music-helper \(helperVersion)
usage:
  oozic-music-helper library [--stats]
  oozic-music-helper tap [--app BUNDLE_ID | --system] [--rate 48000] [--backend auto|tap|sck]
  oozic-music-helper now
  oozic-music-helper watch [--interval 0.5]
  oozic-music-helper control <play|pause|playpause|stop|next|previous|seek SECONDS|volume 0-100|play-id PERSISTENT_ID>
  oozic-music-helper permissions
  oozic-music-helper version
"""

setvbuf(stdout, nil, _IONBF, 0)
let argv = Array(CommandLine.arguments.dropFirst())
guard let sub = argv.first else {
    IO.stderrLine(usage)
    exit(ExitCode.usage)
}
let rest = Array(argv.dropFirst())

let code: Int32
switch sub {
case "library": code = runLibrary(args: rest)
case "tap": code = runTap(args: rest)
case "now": code = runNow()
case "permissions": code = runPermissions()
case "watch": code = runWatch(args: rest)
case "control": code = runControl(args: rest)
case "version", "--version":
    IO.stdoutLine("{\"version\":\"\(helperVersion)\"}")
    code = ExitCode.ok
case "help", "--help", "-h":
    IO.stdoutLine(usage)
    code = ExitCode.ok
default:
    IO.stderrLine(usage)
    code = ExitCode.usage
}
exit(code)
