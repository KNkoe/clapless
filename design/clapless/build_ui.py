"""Builds clapless-ui.html, the approved Clapless design (look 2) with the Mac audio input."""
import pathlib, re
here = pathlib.Path(__file__).parent
src = (here.parent / "build_board.py").read_text()
ns = {"__file__": str(here.parent / "build_board.py")}
exec(src.split("amber = person")[0], ns)                       # logo(), person(), room() from the concept board
person, room, logo = ns["person"], ns["room"], ns["logo"]
cine = person("#111113", "#6e4231", "#dcd8cf", "#ff6a3d")
board_css = (here.parent / "board.css").read_text()

def meter(level, peak):
    cells = []
    for i in range(28):
        kind = "hot" if i >= 25 else "warm" if i >= 21 else "ok"
        cells.append(f'<i class="{kind}{" on" if i < level else ""}{" peak" if i == peak else ""}"></i>')
    return f'<div class="meter">{"".join(cells)}</div>'

def audio(state):
    name, tag, level, peak, note = {
        "ok": ("Wireless Mic RX", "CONNECTED", 18, 22, "-14 dB"),
        "quiet": ("Wireless Mic RX", "NO SOUND", 0, -1, "check the mic is on"),
        "gone": ("Choose a microphone", "NOT CONNECTED", 0, -1, "Start is off"),
    }[state]
    return (f'<div class="audio {state}"><div class="ahead"><label>AUDIO IN</label><div class="pick">{name}<s></s></div></div>'
            f'{meter(level, peak)}<div class="afoot"><b><u></u>{tag}</b><span>{note}</span></div></div>')

phone = f'''<div class="phone"><div class="screen">{room("cine", cine)}<div class="island"></div>
<div class="p2-guides"><i></i><i></i><i></i><i></i></div><div class="p2-ready">READY</div>
<div class="p2-dock"><span>4K<br>30</span><div class="rec"><i></i></div><span>MAC<br>LINKED</span></div></div></div>'''

ready = f'''<div class="mac"><div class="m2 ready"><div class="bar"><i></i><i></i><i></i><span>CLAPLESS</span></div>
<div class="deck"><div class="mon quietmon">{room("cine", cine)}</div><div class="panel">
<div class="tc">00:00:00<small>READY</small></div>
<div class="src"><label>CAMERA</label><b>iPhone 14 · 4K 30</b><em>LINKED</em></div>
<div class="src"><label>SCREEN</label><b>Built-in display</b><em>READY</em></div>
{audio("ok")}
<div class="stop"><i></i>Start take</div></div></div></div></div>'''

recording = f'''<div class="mac solo-mac"><div class="m2"><div class="bar"><i></i><i></i><i></i><span>CLAPLESS</span></div>
<div class="deck"><div class="mon">{room("cine", cine)}</div><div class="panel">
<div class="tc">00:04:12<small>RECORDING</small></div>
<div class="tracks"><div><label>FACE</label><svg viewBox="0 0 200 30" preserveAspectRatio="none"><path d="M0 15 L8 15 L12 4 L16 26 L20 9 L26 21 L32 15 L52 15 L56 6 L61 24 L66 2 L72 28 L78 11 L84 15 L104 15 L110 8 L115 22 L121 15 L140 15 L146 3 L151 27 L157 10 L162 20 L170 15 L200 15"/></svg></div>
<div><label>SCREEN</label><svg viewBox="0 0 200 30" preserveAspectRatio="none"><path d="M0 15 L8 15 L12 6 L16 24 L20 10 L26 20 L32 15 L52 15 L56 8 L61 22 L66 5 L72 25 L78 12 L84 15 L104 15 L110 10 L115 20 L121 15 L140 15 L146 6 L151 24 L157 11 L162 19 L170 15 L200 15"/></svg></div></div>
{audio("ok")}
<div class="stop"><i></i>Stop take</div></div></div>
<div class="takes"><div><b>A003</b><span>Recording · sending to Mac</span><em class="live">LIVE</em></div></div></div></div>'''

extra = '''
.wrap{display:flex;flex-direction:column;gap:18px;container-type:inline-size}
.wrap h3{font-size:13px;font-weight:600;color:var(--muted-foreground,#999)}
.wrap .screen,.wrap .mac,.states{font-family:'IBM Plex Mono',monospace}
.p2-ready{position:absolute;top:15cqw;left:50%;translate:-50%;border:.7cqw solid #efece4;padding:1cqw 3cqw;font-size:6.4cqw;font-weight:600;letter-spacing:.14em;color:#efece4}
.wrap .p2-dock .rec{border-color:#efece4}
.m2.ready{height:66cqw}.m2.ready .deck{height:58.4cqw}.quietmon{border-color:#ffffff2e!important}
.m2.ready .tc{font-size:8cqw}.m2.ready .tc small{color:#a9a69e}
.m2.ready .panel{gap:1.5cqw}
.audio.ok{color:#efece4;font-weight:500}
.m2.ready .stop i{border-radius:50%}
.src{display:flex;align-items:center;gap:1.4cqw;border-top:1px solid #ffffff1c;padding-top:1.3cqw;font-size:2cqw}
.src label,.audio label{color:#a9a69e;font-size:1.75cqw;width:10.5cqw;flex:none}
.src b{flex:1;font-weight:500}.src em{font-style:normal;font-size:1.6cqw;letter-spacing:.18em;color:#7ce38b}
.audio{border:1px solid #ffffff2e;padding:1.3cqw 1.4cqw;display:flex;flex-direction:column;gap:1.2cqw}
.ahead{display:flex;align-items:center;gap:1.4cqw}.ahead label{width:9cqw}
.pick{flex:1;display:flex;justify-content:space-between;align-items:center;background:#ffffff12;padding:1cqw 1.4cqw;font-size:2.1cqw;white-space:nowrap}
.pick s{width:1.1cqw;height:1.1cqw;border:solid #efece4;border-width:0 .3cqw .3cqw 0;rotate:45deg;translate:0 -.3cqw}
.meter{display:grid;grid-template-columns:repeat(28,1fr);gap:.3cqw;height:2.6cqw}
.meter i{background:#ffffff17}.meter i.on.ok{background:#7ce38b}.meter i.on.warm{background:#ffc24a}.meter i.on.hot{background:#ff4a22}.meter i.peak{background:#efece4}
.afoot{display:flex;justify-content:space-between;font-size:1.65cqw;color:#a9a69e}
.afoot b{display:flex;align-items:center;gap:.9cqw;letter-spacing:.18em;color:#7ce38b}.afoot u{width:1.2cqw;height:1.2cqw;border-radius:50%;background:currentColor}
.audio.quiet{border-color:#ffc24a88}.audio.quiet .afoot b{color:#ffc24a}
.audio.gone{border-color:#ff4a2288}.audio.gone .afoot b{color:#ff4a22}
.m2.ready .stop{height:7.6cqw}
.solo-mac{width:100%}.solo-mac .m2{height:66cqw}.solo-mac .deck{height:55cqw}.solo-mac .panel{gap:1.8cqw}.solo-mac .tc{font-size:8.6cqw}.solo-mac .tracks div{height:6cqw}.solo-mac .stop{height:7.4cqw}.solo-mac .takes{bottom:.8cqw}
.states{display:grid;grid-template-columns:1fr 1fr;gap:10px;color:#efece4}
.states>div{container-type:inline-size;background:#0c0c0e;border-radius:6px;padding:8px}
.states .audio{padding:3cqw;gap:3cqw}.states .ahead label{width:auto;font-size:3.8cqw}.states .pick{font-size:4.4cqw;padding:2.2cqw 3cqw}.states .pick s{width:2.2cqw;height:2.2cqw;border-width:0 .6cqw .6cqw 0}.states .meter{height:5.4cqw}.states .afoot{font-size:3.6cqw}.states .afoot u{width:2.4cqw;height:2.4cqw}.states .ahead{gap:3cqw}
.rows{display:flex;gap:2.2cqw}
.rows .mac{flex:1}
@media (max-width:520px){.rows{flex-direction:column;align-items:center}.rows .mac{width:100%;flex:none}.states{grid-template-columns:1fr}}
'''
page = f'''<!doctype html><html><head><meta charset="utf-8">
<link href="https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wght@12..96,500;12..96,800&family=IBM+Plex+Mono:wght@500;600&display=swap" rel="stylesheet">
<style>{board_css}{extra}</style></head><body><div class="wrap c2">
<h3>Before a take: pick the microphone and watch it move</h3>
<div class="rows">{phone}{ready}</div>
<h3>While recording: the level stays visible</h3>
{recording}
<h3>If something is wrong</h3>
<div class="states"><div>{audio("quiet")}</div><div>{audio("gone")}</div></div>
</div></body></html>'''
(here / "clapless-ui.html").write_text(page)
print("written")
