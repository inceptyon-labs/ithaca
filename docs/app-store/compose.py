#!/usr/bin/env python3
"""Builds the App Store screenshots as theatrical one-sheets: the device is the key art, the claim is the title, and a
billing block credits what Ithaca plays. The film on the device's screen continues past its frame as the poster's
art, darkened and tinted toward poster black. Rendered by headless Chrome.

    python3 compose.py [raw captures dir]       (default: raw/)

Captures come from capture.sh against the "Ithaca Demo" library (Blender Studio open movies and public-domain
films), named <device>-<shot>.png: phone-*.png from the iPhone 18 Pro Max simulator (1320x2868), ipad-*.png from the
iPad Pro 13-inch (2064x2752), tv-*.png from the Apple TV 4K (3840x2160), duo-*.png from the iPhone Duo's inner screen
(2853x2007, unfolded in landscape; DISPLAY_ID=primary-1). Key art is the same picture the app shows behind the hero, at
full size, in keyart/. Slides whose capture is missing are skipped.

Writes screenshots/iphone/*.jpg (1320x2868), screenshots/iphone-6.3/*.jpg (1206x2622, scaled from those),
screenshots/ipad/*.jpg, screenshots/appletv/*.jpg and screenshots/duo/*.jpg. The device frame is drawn, since Apple's terms allow nothing
over their bezels. Fonts are Anton and Six Caps (SIL OFL, fonts/).
"""
import base64, pathlib, subprocess, sys, tempfile

HERE = pathlib.Path(__file__).resolve().parent
RAW = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else HERE / "raw"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
IMPECCABLE = str(pathlib.Path.home() / ".claude/plugins/cache/impeccable/impeccable/4.10.0/skills/impeccable/scripts/impeccable")

# One slide per row. art: the key art file in keyart/. place: where the app draws that art in each device's capture,
# (x, y, width) in capture pixels, found with place.py; the art then continues past the device's frame. A device with
# no place (a screen with no hero picture, and Apple TV, whose hero fills the screen) gets the art as a soft backdrop
# instead. tint: the art's own colour, pulled toward black. stop: the resume line under the device. title: two lines,
# punctuation hung outside them. tag: the short line at the top. bill: the billing block, one entry per line, each line
# fitted to the block's width; <i>..</i> are the small role labels. foot: the line at the bottom.
SLIDES = [
    dict(name="01-home", shot="home", art="sintel.jpg", tint="#2E5E6E", stop=.54,
         art_by=dict(ipad="sintel-art.jpg", tv="sintel-art.jpg", duo="sintel-art.jpg"),
         place=dict(phone=(-888, -432, 2991), ipad=(-952, 0, 3972), duo=(-264, -2, 3131)),
         tag="No ads. Every screen in the house.",
         title=("The Plex app", "you wanted<em>.</em>"),
         bill=["INCEPTYON LABS <i>PRESENTS</i> ITHACA FOR PLEX <i>DIRECT PLAY FROM</i> YOUR OWN SERVER",
               "<i>PICTURE IN</i> DOLBY VISION · HDR10+ · HDR10 <i>SOUND IN</i> DOLBY ATMOS · DTS-HD MA",
               "<i>SUBTITLES IN</i> PGS AND SRT <i>WITH</i> NO ADS · NO TRACKING · NO PROMOTED CONTENT",
               "<i>ALSO STARRING</i> SKIP INTRO · UP NEXT · SHAREPLAY · AIRPLAY · SIRI"],
         foot="Now playing on your Apple TV, iPhone and iPad"),
    dict(name="02-direct", shot="detail", art="tos-art.jpg", tint="#3B4A55", stop=.33,
         place=dict(phone=(-1104, 0, 3530), ipad=(-472, 0, 3011), duo=(-148, 2, 2896)),
         tag="No transcoding unless you ask",
         title=("Your 4K", "stays 4K<em>.</em>"),
         bill=["<i>PICTURE IN</i> 4K · HEVC · DOLBY VISION 7 AND 8 · HDR10+ · HLG",
               "<i>SOUND IN</i> DOLBY ATMOS · DTS-HD MA · FLAC · AC-3 · AAC",
               "<i>SUBTITLES IN</i> PGS · SRT · FORCED <i>FROM</i> MKV · MP4 · MOV",
               "<i>PLAYED BY</i> AVPLAYER AND VLC <i>WITH</i> PLEX AS THE FALLBACK"],
         foot="Dolby Vision, Atmos, and the PGS subtitles other apps burn in"),
    dict(name="03-request", shot="request", art="daily-dweebs.jpg", tint="#5A4632", stop=.12,
         place=dict(phone=(-1104, 0, 3530), ipad=(-468, 0, 3003), duo=(-140, 2, 2890)),
         tag="Works with Seerr",
         title=("Don't have it<em>?</em>", "Request it<em>.</em>"),
         bill=["<i>REQUEST</i> MOVIES AND WHOLE SEASONS <i>SEE</i> YOUR REQUESTS ON HOME",
               "<i>FIND</i> TITLES TO REQUEST IN PICK SOMETHING <i>AND</i> GET A NOTICE",
               "<i>ON</i> IPHONE AND IPAD <i>THE MOMENT</i> IT LANDS ON YOUR SERVER"],
         foot="Ask from the couch. Your iPhone tells you when it's ready."),
    dict(name="04-describe", shot="describe", art="coffee-run-poster.jpg", tint="#5B3A5E", stop=.7,
         place={}, cover=(1.0, 3),
         tag="Pick Something",
         title=("Can't pick<em>?</em>", "Just say it<em>.</em>"),
         bill=["<i>PICKS BY</i> MOOD · LENGTH · GENRE <i>FOR</i> EVERYONE IN THE ROOM",
               "<i>SKIPS</i> WHAT ANYONE HAS SEEN <i>LEARNS FROM</i> WHAT YOU RATE"],
         foot="Type the mood. It picks from your own shelf."),
    dict(name="05-downloads", shot="downloads", art="spring-art.jpg", tint="#2F5A6B", stop=.9,
         place={},
         tag="On iPhone and iPad",
         title=("Downloaded", "before takeoff<em>.</em>"),
         bill=["<i>DOWNLOADS ON</i> IPHONE AND IPAD <i>PROGRESS</i> SYNCS BACK LATER",
               "<i>ALSO</i> AIRPLAY TO ANY TV · PICTURE IN PICTURE · SHAREPLAY"],
         foot="Your progress catches up when you land."),
    dict(name="05-library", shot="library", art="tos-art.jpg", tint="#3B4A55", stop=.9,
         place={},
         tag="No ads. No sponsored rows.",
         title=("Nothing you", "didn't add<em>.</em>"),
         bill=["<i>ONLY</i> WHAT'S ON YOUR SERVERS <i>IN</i> YOUR LIBRARY ORDER",
               "<i>WATCH STATE FROM</i> YOUR PLEX ACCOUNT <i>AND</i> SEVERAL SERVERS IN ONE HOME"],
         foot="Just the movies and shows you put there."),
    dict(name="06-show", shot="show", art="caminandes-art.jpg", tint="#3E6A8A", stop=.97,
         place=dict(phone=(-1108, -2, 3539), ipad=(-476, -2, 3019), duo=(-144, 2, 2890)),
         tag="Skip intro. Skip credits.",
         title=("One more", "episode<em>.</em>"),
         bill=["<i>SKIP</i> INTRO · CREDITS <i>THEN</i> UP NEXT <i>RESUMES</i> ON EVERY DEVICE",
               "<i>ASK</i> SIRI FOR THE NEXT EPISODE <i>AND</i> A CHECK-IN IF YOU NOD OFF"],
         foot="It even asks if you're still awake."),
]

# Canvas and device per kind, in slide pixels. cap: the capture's size and its display corner radius in capture
# pixels. screen: the capture's width on the slide. Every device stands on the same baseline (shelf).
DEVICES = {
    "iphone": dict(raw="phone", w=1320, h=2868, cap=(1320, 2868, 190), screen=800, frame=22, shelf=1926,
                   tag=60, tag_top=52, title_top=2000, title_w=1120, title_max=210, bill_top=2400, bill_w=920, bill=56, date=28,
                   date_top=2770, fade=(1040, 1540)),
    "ipad": dict(raw="ipad", w=2064, h=2752, cap=(2064, 2752, 62), screen=1240, frame=26, shelf=1880,
                 tag=64, tag_top=56, title_top=1960, title_w=1500, title_max=260, bill_top=2330, bill_w=1300, bill=60, date=32,
                 date_top=2660, fade=(1100, 1700)),
    "appletv": dict(raw="tv", bill_lines=2, w=3840, h=2160, cap=(3840, 2160, 0), screen=2360, frame=30, shelf=1600,
                    tag=60, tag_top=44, title_top=1700, title_w=2300, title_max=230, bill_top=1930, bill_w=2000, bill=60, date=30,
                    date_top=2090, fade=(900, 1500), one_line=True),
    "duo": dict(raw="duo", bill_lines=3, w=2853, h=2007, cap=(2853, 2007, 176), screen=1560, frame=24, shelf=1330,
                tag=56, tag_top=44, title_top=1430, title_w=1900, title_max=200, bill_top=1640, bill_w=1700, bill=52, date=28,
                date_top=1920, fade=(780, 1300), one_line=True),
}
BLACK = "#0B0B0D"


def data_uri(path):
    mime = "image/png" if str(path).endswith(".png") else "image/jpeg"
    return f"data:{mime};base64," + base64.b64encode(pathlib.Path(path).read_bytes()).decode()


def font(name, file):
    return f"@font-face{{font-family:'{name}';src:url({data_uri(HERE / 'fonts' / file)}) format('truetype')}}"


FONTS = font("Anton", "Anton-Regular.ttf") + font("Six Caps", "SixCaps.ttf")


def capture_uri(d, shot):
    """The capture as a data URI. iPadOS draws a window resize grabber in the screen's bottom-right corner; it is
    system chrome, not the app, so it is painted out with the colour just beside it."""
    path = RAW / f"{d['raw']}-{shot}.png"
    if d["raw"] != "ipad":
        return data_uri(path)
    with tempfile.TemporaryDirectory() as tmp:
        clean = pathlib.Path(tmp) / "clean.png"
        colour = subprocess.run(["magick", str(path), "-format", "%[pixel:p{1975,2700}]", "info:"],
                                capture_output=True, text=True, check=True).stdout.strip()
        subprocess.run(["magick", str(path), "-fill", colour, "-draw", "rectangle 1985,2676 2063,2751", str(clean)],
                       check=True, capture_output=True)
        return data_uri(clean)


def page(d, s):
    W, H = d["w"], d["h"]
    cw, ch, corner = d["cap"]
    k = d["screen"] / cw
    f = d["frame"]
    sw, sh = d["screen"], ch * k
    left = (W - sw) / 2 - f
    top = d["shelf"] - sh - 2 * f
    sx, sy = left + f, top + f
    # Key art, two layers: the art out of focus across the top of the slide, and, where the screen has a hero, the
    # same art sharp where the app draws it, so the picture continues past the frame. The sharp layer fades out at
    # its own edges, so a picture narrower than the slide meets the soft layer without a seam.
    art = HERE / "keyart" / s.get("art_by", {}).get(d["raw"], s["art"])
    placed = s["place"].get(d["raw"])
    art_uri = data_uri(art)
    # The soft layer: the art across the top of the slide, out of focus. A slide may ask for it closer to sharp
    # (cover: width as a share of the slide, blur), for a poster that should stay recognisable.
    cover_w, cover_blur = s.get("cover", (1.5, 14))
    sharp = ""
    if placed:
        px, py, pw = placed
        ax, ay, a_w = sx + px * k, sy + py * k, pw * k
        sharp = f'<img class="sharp" src="{art_uri}" style="left:{ax:.1f}px;top:{ay:.1f}px;width:{a_w:.1f}px">'
    f0, f1 = d["fade"]
    stop_w = sw
    title = s["title"]
    if d.get("one_line"):
        lines = [f'<span>{title[0].replace("<em>", "<em class=mid>")} {title[1]}</span>']
    else:
        lines = [f'<span>{t}</span>' for t in title]
    css = f"""{FONTS}
* {{ box-sizing: border-box; margin: 0; }}
html, body {{ width: {W}px; height: {H}px; overflow: hidden; }}
body {{ position: relative; background: {BLACK}; color: #fff; -webkit-font-smoothing: antialiased; }}
.art {{ position: absolute; inset: 0; isolation: isolate; -webkit-mask: linear-gradient(#000 {f0}px, transparent {f1}px); }}
.art img {{ position: absolute; filter: brightness(.52) saturate(.75); }}
.art .soft {{ left: {(W - W * cover_w) / 2:.0f}px; top: -40px; width: {W * cover_w:.0f}px; filter: brightness(.45) saturate(.75) blur({cover_blur}px); }}
.art .sharp {{ -webkit-mask-image: linear-gradient(to right, transparent, #000 6%, #000 94%, transparent),
                                    linear-gradient(transparent, #000 7%, #000 80%, transparent);
               -webkit-mask-composite: source-in; mask-composite: intersect; }}
.art:after {{ content: ""; position: absolute; inset: 0; background: {s['tint']}; mix-blend-mode: color; opacity: .72; }}
.tag {{ position: absolute; top: {d['tag_top']}px; left: 0; width: {W}px; padding-left: .34em; text-align: center;
        font: {d['tag']}px/1 "Six Caps"; letter-spacing: .34em; text-transform: uppercase; }}
.dev {{ position: absolute; left: {left:.1f}px; top: {top:.1f}px; padding: {f}px; border-radius: {corner * k + f:.1f}px;
        background: #050506; box-shadow: 0 0 0 3px #33363E, inset 0 0 0 2px rgba(255,255,255,.06), 0 72px 140px rgba(0,0,0,.65); }}
.dev img {{ display: block; width: {sw}px; height: {sh:.1f}px; border-radius: {corner * k:.1f}px; }}
.stop {{ position: absolute; left: {sx:.1f}px; top: {d['shelf'] + 28}px; width: {stop_w}px; height: 6px; border-radius: 3px;
         background: rgba(255,255,255,.16); }}
.stop:before {{ content: ""; position: absolute; inset: 0 auto 0 0; width: {s['stop'] * 100:.0f}%; border-radius: 3px; background: #fff; }}
h1 {{ position: absolute; top: {d['title_top']}px; left: 0; width: {W}px; text-align: center; font-family: Anton;
      font-weight: 400; text-transform: uppercase; white-space: nowrap; }}
h1 span {{ display: block; line-height: .867em; }}
h1 span + span {{ margin-top: .14em; }}
h1 em {{ font-style: normal; margin-right: -.236em; }}
h1 em.mid {{ margin-right: 0; }}
.bill {{ position: absolute; top: {d['bill_top']}px; left: {(W - d['bill_w']) / 2:.0f}px; width: {d['bill_w']}px;
         font: {d['bill']}px/1 "Six Caps"; letter-spacing: .05em; text-align: center; color: rgba(255,255,255,.84); }}
.bill span {{ display: block; width: max-content; margin: 0 auto; white-space: nowrap; line-height: 1.02; }}
.bill i {{ font-style: normal; font-size: .5em; letter-spacing: .12em; vertical-align: .32em; margin: 0 .3em; }}
.date {{ position: absolute; top: {d['date_top']}px; left: 0; width: {W}px; padding-left: .24em; text-align: center; white-space: nowrap;
         font: {d['date']}px/1 Anton; letter-spacing: .24em; text-transform: uppercase; }}
"""
    # Each title line is sized to the same width, the hung punctuation outside it.
    fit = f"""<script>
document.fonts.ready.then(() => {{
  for (const line of document.querySelectorAll('h1 span')) {{
    line.style.fontSize = '100px';
    const em = line.querySelector('em:last-child:not(.mid)');
    const hang = em ? em.getBoundingClientRect().width : 0;
    const range = document.createRange(); range.selectNodeContents(line);
    const textW = range.getBoundingClientRect().width - hang;
    line.style.fontSize = Math.min(100 * {d['title_w']} / textW, {d['title_max']}) + 'px';
  }}
  // The foot line shrinks to fit the slide's width.
  const foot = document.querySelector('.date');
  const room = {W} * .9;
  if (foot.scrollWidth > room) foot.style.fontSize = (parseFloat(getComputedStyle(foot).fontSize) * room / foot.scrollWidth) + 'px';
  // The billing block follows the title; the foot line stays at the bottom.
  const bill = document.querySelector('.bill');
  bill.style.top = (document.querySelector('h1').getBoundingClientRect().bottom + {d['bill'] * .55}) + 'px';
  // Each billing line is fitted edge to edge, within reason, then the block shrinks until it clears the foot line.
  for (const line of bill.querySelectorAll('span')) {{
    const w = line.scrollWidth;
    line.style.fontSize = Math.min(Math.max({d['bill']} * {d['bill_w']} / w, {d['bill'] * .7}), {d['bill'] * 1.35}) + 'px';
  }}
  const limit = foot.getBoundingClientRect().top - {d['bill'] * .6};
  for (let i = 0; i < 30 && bill.getBoundingClientRect().bottom > limit; i++)
    for (const line of bill.querySelectorAll('span'))
      line.style.fontSize = (parseFloat(getComputedStyle(line).fontSize) * .96) + 'px';
  document.body.dataset.ready = '1';
}});
</script>"""
    body = (f'<div class="art"><img class="soft" src="{art_uri}">{sharp}</div>'
            f'<p class="tag">{s["tag"]}</p>'
            f'<div class="dev"><img src="{capture_uri(d, s["shot"])}"></div>'
            f'<div class="stop"></div><h1>{"".join(lines)}</h1>'
            f'<p class="bill">{"".join(f"<span>{line}</span>" for line in s["bill"][:d.get("bill_lines", 9)])}</p><p class="date">{s["foot"]}</p>')
    return f"<!doctype html><html><head><meta charset='utf-8'><style>{css}</style></head><body>{body}{fit}</body></html>"


def header():
    """5244x2950, Apple's universal product page header. Only the art safe area (1402x962 at x 1921, y 660) survives
    every crop, so the title and one billing line sit there. The art is a 4K frame of Tears of Steel (3840x1714),
    letterboxed across the full width as the film is framed; no device, since a crop would cut it."""
    W, H = 5244, 2950
    sx, sy, sw, sh = 1921, 660, 1402, 962
    art = data_uri(HERE / "keyart" / "tos-skyline.jpg")
    band = W * 1714 / 3840
    css = f"""{FONTS}
* {{ box-sizing: border-box; margin: 0; }}
html, body {{ width: {W}px; height: {H}px; overflow: hidden; }}
body {{ position: relative; background: {BLACK}; color: #fff; -webkit-font-smoothing: antialiased; }}
.art {{ position: absolute; left: 0; top: {(H - band) / 2:.0f}px; width: {W}px; height: {band:.0f}px; filter: brightness(.42) saturate(.8) contrast(1.05);
        -webkit-mask-image: linear-gradient(transparent, #000 9%, #000 91%, transparent); }}
.tint {{ position: absolute; left: 0; right: 0; top: {(H - band) / 2:.0f}px; height: {band:.0f}px; background: #3B4A55;
         mix-blend-mode: color; opacity: .5; -webkit-mask-image: linear-gradient(transparent, #000 9%, #000 91%, transparent); }}
.scrim {{ position: absolute; inset: 0; background: radial-gradient(2600px 1500px at {sx + sw / 2}px {sy + sh / 2}px,
          rgba(11,11,13,.45), rgba(11,11,13,.15) 75%, rgba(11,11,13,0)); }}
.safe {{ position: absolute; left: {sx}px; top: {sy}px; width: {sw}px; height: {sh}px; display: flex; flex-direction: column;
         align-items: center; justify-content: center; text-align: center; }}
h1 {{ font: 400 210px/.88 Anton; text-transform: uppercase; }}
h1 em {{ font-style: normal; margin-right: -.236em; }}
.bill {{ margin-top: 48px; font: 64px/1 "Six Caps"; letter-spacing: .06em; color: rgba(255,255,255,.86); }}
"""
    body = (f'<img class="art" src="{art}"><div class="tint"></div><div class="scrim"></div><div class="safe">'
            '<h1>The Plex app<br>you wanted<em>.</em></h1>'
            '<p class="bill">ITHACA FOR PLEX · APPLE TV · IPHONE · IPAD · NO ADS</p></div>')
    return f"<!doctype html><html><head><meta charset='utf-8'><style>{css}</style></head><body>{body}</body></html>"


def render(html_text, w, h, out, quality=92):
    with tempfile.TemporaryDirectory() as tmp:
        src = pathlib.Path(tmp) / "slide.html"
        src.write_text(html_text)
        png = pathlib.Path(tmp) / "slide.png"
        subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
                        f"--user-data-dir={tmp}/profile", "--no-first-run",
                        "--virtual-time-budget=4000", f"--window-size={w},{h}", f"--screenshot={png}", src.as_uri()],
                       check=True, capture_output=True)
        if out.suffix == ".png":
            png.replace(out)
        else:
            subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", str(quality), str(png), "--out", str(out)],
                           check=True, capture_output=True)


for kind, d in DEVICES.items():
    slides = [s for s in SLIDES if (RAW / f"{d['raw']}-{s['shot']}.png").exists()]
    if not slides:
        continue
    out = HERE / "screenshots" / kind
    out.mkdir(parents=True, exist_ok=True)
    for s in slides:
        jpg = out / f"{s['name']}.jpg"
        render(page(d, s), d["w"], d["h"], jpg)
        subprocess.run([IMPECCABLE, "embed-prompt", str(jpg), "--prompt",
                        f"Composed by docs/app-store/compose.py from the capture {d['raw']}-{s['shot']}.png (capture.sh, "
                        f"Ithaca Demo library) and keyart/{s['art']} (see keyart/SOURCES.txt)."],
                       check=False, capture_output=True)
        print(jpg)
        if kind == "iphone":
            small = HERE / "screenshots" / "iphone-6.3" / jpg.name
            small.parent.mkdir(exist_ok=True)
            subprocess.run(["sips", "-z", "2622", "1206", str(jpg), "--out", str(small)], check=True, capture_output=True)
            subprocess.run([IMPECCABLE, "embed-prompt", str(small), "--prompt",
                            f"screenshots/iphone/{jpg.name} scaled to 1206x2622 by docs/app-store/compose.py."],
                           check=False, capture_output=True)
render(header(), 5244, 2950, HERE / "screenshots" / "header.png")
subprocess.run([IMPECCABLE, "embed-prompt", str(HERE / "screenshots" / "header.png"), "--prompt",
                "Composed by docs/app-store/compose.py (header) from keyart/tos-skyline.jpg; type only, no device."],
               check=False, capture_output=True)
print(HERE / "screenshots" / "header.png")
