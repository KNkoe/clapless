import pathlib
here = pathlib.Path(__file__).parent
def logo(name, uid):
    s = (here / name).read_text()
    for i in ("m-bg", "m-hot", "b-bg"):
        s = s.replace(f'id="{i}"', f'id="{i}-{uid}"').replace(f"url(#{i})", f"url(#{i}-{uid})")
    return s.replace('<svg xmlns="http://www.w3.org/2000/svg"', '<svg')

def person(shirt, skin, cap, rim):
    return f'''<svg class="person" viewBox="0 0 200 250" preserveAspectRatio="xMidYMax meet">
<path d="M8 250 C12 196 52 178 78 172 L122 172 C148 178 188 196 192 250 Z" fill="{shirt}"/>
<path d="M82 135 h36 v44 c-8 12 -28 12 -36 0 Z" fill="{skin}"/>
<ellipse cx="100" cy="108" rx="39" ry="48" fill="{skin}"/>
<path d="M60 88 C60 52 78 40 101 40 C126 40 141 54 141 88 Z" fill="{cap}"/>
<path d="M58 84 C84 78 126 78 154 90 C132 97 82 96 58 92 Z" fill="{cap}"/>
<path d="M141 106 C140 134 128 152 110 158" fill="none" stroke="{rim}" stroke-width="2.5" opacity=".7"/>
</svg>'''

def room(kind, who):
    return f'<div class="room {kind}"><i class="win"></i><i class="table"></i><i class="lamp"></i>{who}</div>'

amber = person("#1c1512", "#7a4630", "#e9dcc8", "#ffb066")
cine = person("#111113", "#6e4231", "#dcd8cf", "#ff6a3d")
day = person("#27313f", "#8a553c", "#f4efe4", "#ffffff")

mmoho = f'''
<section class="concept c1">
 <header><b>1</b><h2>Mmoho</h2><p>Sesotho for “together”. Warm, like your video studio.</p></header>
 <div class="brand">
  <div class="icon xl">{logo("logo-1-mmoho.svg","a")}</div>
  <div class="word w1">mmoho</div>
  <div class="small"><span class="icon s">{logo("logo-1-mmoho.svg","b")}</span><span class="icon xs">{logo("logo-1-mmoho.svg","c")}</span></div>
 </div>
 <div class="stage">
  <div class="phone"><div class="screen">
   {room("amber", amber)}
   <div class="island"></div>
   <div class="p1-top"><em></em>Mac connected</div>
   <div class="p1-dock"><div class="meta"><span>4K · 30</span><span>134 min left</span></div><div class="rec"><i></i></div><div class="hint">Framing looks good</div></div>
  </div></div>
  <div class="mac"><div class="m1">
   <div class="bar"><i></i><i></i><i></i><span>mmoho</span></div>
   <div class="duo">
    <figure><div class="tile tall">{room("amber", amber)}</div><figcaption><b>Your face</b>iPhone · 4K</figcaption></figure>
    <figure><div class="tile wide"><div class="ui"><u></u><u></u><u class="btn"></u><u></u></div></div><figcaption><b>Your screen</b>This Mac · wireless mic</figcaption></figure>
    <div class="join"><div class="rec"><i></i></div></div>
   </div>
   <div class="strip"><span>Take 3 · 04:12</span><div class="prog"><i style="width:100%"></i></div><span class="ok">On your Mac, matched</span></div>
  </div></div>
 </div>
</section>'''

clapless = f'''
<section class="concept c2">
 <header><b>2</b><h2>Clapless</h2><p>No clap needed. Bold, cinematic, built like a film tool.</p></header>
 <div class="brand">
  <div class="icon xl">{logo("logo-2-clapless.svg","a")}</div>
  <div class="word w2">clapless<i>.</i></div>
  <div class="small"><span class="icon s">{logo("logo-2-clapless.svg","b")}</span><span class="icon xs">{logo("logo-2-clapless.svg","c")}</span></div>
 </div>
 <div class="stage">
  <div class="phone"><div class="screen tally">
   {room("cine", cine)}
   <div class="island"></div>
   <div class="p2-guides"><i></i><i></i><i></i><i></i></div>
   <div class="p2-time">00:04:12</div>
   <div class="p2-dock"><span>4K<br>30</span><div class="rec sq"><i></i></div><span>TO MAC<br>LIVE</span></div>
  </div></div>
  <div class="mac"><div class="m2">
   <div class="bar"><i></i><i></i><i></i><span>CLAPLESS</span></div>
   <div class="deck">
    <div class="mon">{room("cine", cine)}</div>
    <div class="panel">
     <div class="tc">00:04:12<small>RECORDING</small></div>
     <div class="tracks">
      <div><label>FACE</label><svg viewBox="0 0 200 30" preserveAspectRatio="none"><path d="M0 15 L8 15 L12 4 L16 26 L20 9 L26 21 L32 15 L52 15 L56 6 L61 24 L66 2 L72 28 L78 11 L84 15 L104 15 L110 8 L115 22 L121 15 L140 15 L146 3 L151 27 L157 10 L162 20 L170 15 L200 15"/></svg></div>
      <div><label>SCREEN</label><svg viewBox="0 0 200 30" preserveAspectRatio="none"><path d="M0 15 L8 15 L12 6 L16 24 L20 10 L26 20 L32 15 L52 15 L56 8 L61 22 L66 5 L72 25 L78 12 L84 15 L104 15 L110 10 L115 20 L121 15 L140 15 L146 6 L151 24 L157 11 L162 19 L170 15 L200 15"/></svg></div>
      <i class="head"></i>
     </div>
     <div class="stop"><i></i>Stop take</div>
    </div>
   </div>
   <div class="takes"><div><b>A003</b><span>Recording · sending to Mac</span><em class="live">LIVE</em></div><div><b>A002</b><span>06:48 · matched</span><em>READY</em></div></div>
  </div></div>
 </div>
</section>'''

bona = f'''
<section class="concept c3">
 <header><b>3</b><h2>Bona</h2><p>Sesotho for “see”. Light, calm, and it coaches your framing.</p></header>
 <div class="brand">
  <div class="icon xl">{logo("logo-3-bona.svg","a")}</div>
  <div class="word w3">bona</div>
  <div class="small"><span class="icon s">{logo("logo-3-bona.svg","b")}</span><span class="icon xs">{logo("logo-3-bona.svg","c")}</span></div>
 </div>
 <div class="stage">
  <div class="phone"><div class="screen light">
   <div class="p3-view">{room("day", day)}<div class="oval"></div></div>
   <div class="island"></div>
   <div class="p3-tip">Move back a little</div>
   <div class="p3-dock"><span>4K · 30</span><div class="rec"><i></i></div><span>Mac ✓</span></div>
  </div></div>
  <div class="mac"><div class="m3">
   <div class="bar"><i></i><i></i><i></i></div>
   <aside><div class="mark">{logo("logo-3-bona.svg","d")}<b>bona</b></div><h4>Today</h4>
    <div class="take on"><b>Take 3</b><span>Ready to record</span></div><div class="take"><b>Take 2</b><span>6 min · saved</span></div><div class="take"><b>Take 1</b><span>2 min · saved</span></div></aside>
   <main>
    <div class="view">{room("day", day)}<div class="coach">Move back until your shoulders fit</div></div>
    <div class="row"><div class="chip"><b>iPhone</b>Connected</div><div class="chip"><b>Screen</b>This Mac</div><div class="chip"><b>Mic</b>Wireless</div><div class="go">Start recording</div></div>
   </main>
  </div></div>
 </div>
</section>'''

css = (here / "board.css").read_text()
page = f'''<!doctype html><html><head><meta charset="utf-8">
<link href="https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wght@12..96,500;12..96,800&family=DM+Sans:opsz,wght@9..40,400;9..40,600&family=Figtree:wght@400;600&family=Fraunces:opsz,wght@9..144,500;9..144,600&family=Gabarito:wght@600;800&family=IBM+Plex+Mono:wght@500;600&display=swap" rel="stylesheet">
<style>{css}</style></head><body><div class="board">{mmoho}{clapless}{bona}</div></body></html>'''
(here / "concepts.html").write_text(page)
print("written", len(page))
