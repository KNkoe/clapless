# Clapless

An open-source iPhone camera and Mac recorder that make one take without a clap. The iPhone
films you in 4K, the Mac records the screen and your microphone, the camera file comes to the
Mac over an encrypted link on your own network, and the two are matched by sound.

Part of [Reel Studio](https://github.com/KNkoe/reel-studio), which turns the takes into
finished vertical videos.

**State:** early. Camera, screen and microphone takes with verified transfer and sound
matching have worked on one set-up (an M1 Pro Mac and one iPhone). Recording a single app's
window is new: it builds and its sums are tested, but it has not been tried in a real take.
Editing inside the app is not built yet.

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
6. Pick a microphone, or leave it on **Mac default**, which follows System Settings. If the one
   you picked is off, the Mac's default stands in and the window says so; if a microphone drops
   during a take, the sound carries on from the next one. Then press the red button. It asks what to record: a whole screen, one
   app's window, or no screen. The last answer is already picked, so Return starts the take.

Takes are saved in `~/Movies/Clapless/<date_time>/`: `camera.mov`, `screen.mp4`, `mic.m4a`,
`take.json`. The screen and mic files begin at the same moment; the camera is matched to them
by sound. The iPhone keeps its own copy of every take.

Record only people who have agreed to it, and check what is on your screen before you share
a take.

## Command line

`scripts/clapless status | start | stop | takes | mic NAME|default | lens back|front | speedtest [MB] | direct on|off | screen on|off|full|app NAME | apps | sync [TAKE]`

## Heat

Between takes the iPhone's camera runs at 15 frames a second (takes are 30). With a Mac
connected the phone's screen goes black after 20 seconds; tap it to see the picture. After
three minutes with no Mac and no touch the camera switches off and the phone may lock as usual.
Each `take.json` notes how warm the iPhone got.

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
