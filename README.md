# Clapless

An open-source iPhone camera and Mac recorder that make one take without a clap. The iPhone
films you in 4K, the Mac records the screen and your microphone, the camera file comes to the
Mac over an encrypted link on your own network, and the two are matched by sound.

Part of [Reel Studio](https://github.com/KNkoe/reel-studio), which turns the takes into
finished vertical videos.

**State:** early. Camera, screen and microphone takes with verified transfer and sound
matching have worked on one set-up (an M1 Pro Mac and one iPhone). Editing inside the app is
not built yet.

## You need

- An Apple silicon Mac with Xcode, on macOS 26 or later (built on macOS 27.2).
- An iPhone on the same Wi-Fi, and an Apple Account signed in to Xcode (free is enough).
- For sound matching: `uv`, `ffmpeg` and the `panel-reel` skill from Reel Studio, linked with
  its `scripts/setup.sh --link`. Cloning Reel Studio with `--recurse-submodules` gets both.

## Use it

1. `scripts/setup.sh` writes your signing team into `Config/Local.xcconfig` (never committed).
2. `scripts/mac.sh` builds the Mac app into `~/Applications` and opens it.
3. `scripts/phone.sh` builds the iPhone app and installs it. Free signing lasts 7 days; run it
   again after that. The iPhone needs Developer Mode on and your certificate trusted.
4. Open Clapless on the iPhone (unlocked, on the same Wi-Fi). Pair once: both screens show the
   same six digits.
5. The first time, click **Allow** on the screen row, switch Clapless on under Screen Recording,
   then quit and reopen it.
6. Choose a microphone and a screen, then press the red button.

Takes are saved in `~/Movies/Clapless/<date_time>/`: `camera.mov`, `screen.mp4`, `mic.m4a`,
`take.json`. The screen and mic files begin at the same moment; the camera is matched to them
by sound. The iPhone keeps its own copy of every take.

Record only people who have agreed to it, and check what is on your screen before you share
a take.

## Command line

`scripts/clapless status | start | stop | takes | mic NAME | lens back|front | speedtest [MB] | direct on|off | screen on|off | sync [TAKE]`

## Limits

iOS stops the camera when Clapless is in the background or the phone is locked, so open the
app once per session and leave it on screen.

## Tests

`swift test` covers pairing, the encrypted link, segments, checksums, the camera, microphone
and screen files and the pre-take warnings, using made-up pictures and sound.

## Contributing

Issues and pull requests are welcome, especially reports from other Macs and iPhones. Never
commit recordings or signing settings.

## Licence

The code is [MIT](LICENSE). The bundled fonts are under the SIL Open Font License; their
licence texts sit beside them in `Resources/Fonts` and `design/earlier-fonts`.
