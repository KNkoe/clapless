# Clapless

An iPhone camera and a Mac app that record one take without a clap.

**State:** camera takes with verified transfer work on real hardware. Screen recording and
sync by sound are built; screen recording has not yet been tried in a real take. Editing
inside the app is not built yet.

## Use it
1. `scripts/mac.sh` builds the Mac app into `~/Applications` and opens it.
2. `scripts/phone.sh` builds the iPhone app and installs it. Free signing lasts 7 days; run it again after that.
3. Open Clapless on the iPhone (unlocked, on the same Wi-Fi). Pair once: both screens show the same six digits.
4. The first time, click **Allow** on the screen row, switch Clapless on under Screen Recording,
   then quit and reopen it.
5. Choose a microphone and a screen, then press the red button.

Takes are saved in `~/Movies/Clapless/<date_time>/`: `camera.mov`, `screen.mp4`, `mic.m4a`,
`take.json`. The screen and mic files begin at the same moment; the camera is matched to them
by sound with the `panel-reel` skill's `sync_camera.py` (needs `uv` and `ffmpeg`).
The iPhone keeps its own copy of every take.

## Command line
`scripts/clapless status | start | stop | takes | mic NAME | lens back|front | speedtest [MB] | direct on|off | screen on|off | sync [TAKE]`

## Limits
iOS stops the camera when Clapless is in the background or the phone is locked,
so open the app once per session and leave it on screen.

## Tests
`swift test` covers pairing, the encrypted link, segments, checksums, the camera, microphone
and screen files and the pre-take warnings, using made-up pictures and sound.
