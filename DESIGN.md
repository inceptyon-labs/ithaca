---
name: Ithaca for Plex: App Store one-sheets
description: The marketing world of the App Store screenshots and product page header, rendered by docs/app-store/compose.py.
colors:
  poster-black: "#0B0B0D"
  device-black: "#050506"
  frame-rim: "#33363E"
  white: "#FFFFFF"
  billing-white: "rgba(255,255,255,.84)"
  resume-track: "rgba(255,255,255,.16)"
  tint-steel: "#3B4A55"
  tint-sintel-teal: "#2E5E6E"
  tint-dweeb-umber: "#5A4632"
  tint-coffee-plum: "#5B3A5E"
  tint-spring-teal: "#2F5A6B"
  tint-caminandes-blue: "#3E6A8A"
typography:
  display:
    fontFamily: "Anton"
    fontSize: "fitted to title width; max 210px iPhone, 260px iPad, 230px Apple TV"
    fontWeight: 400
    lineHeight: 0.867
    letterSpacing: "0em"
  headline:
    fontFamily: "Anton"
    fontSize: "210px"
    fontWeight: 400
    lineHeight: 0.88
  label:
    fontFamily: "Six Caps"
    fontSize: "56px iPhone, 60px iPad and Apple TV (base, then fitted per line); Apple TV shows only the first two billing lines"
    fontWeight: 400
    lineHeight: 1.02
    letterSpacing: "0.05em"
  label-role:
    fontFamily: "Six Caps"
    fontSize: "0.5em of its billing line"
    fontWeight: 400
    letterSpacing: "0.12em"
  title:
    fontFamily: "Six Caps"
    fontSize: "60px iPhone and Apple TV, 64px iPad"
    fontWeight: 400
    lineHeight: 1
    letterSpacing: "0.34em"
  body:
    fontFamily: "Anton"
    fontSize: "28px iPhone, 32px iPad, 30px Apple TV (shrinks to 90% of slide width)"
    fontWeight: 400
    lineHeight: 1
    letterSpacing: "0.24em"
rounded:
  resume: "3px"
  frame-iphone: "137px"
  frame-ipad: "63px"
  frame-appletv: "30px"
spacing:
  frame-iphone: "22px"
  frame-ipad: "26px"
  frame-appletv: "30px"
  resume-gap: "28px"
  resume-height: "6px"
components:
  title:
    textColor: "{colors.white}"
    typography: "{typography.display}"
  billing-line:
    textColor: "{colors.billing-white}"
    typography: "{typography.label}"
  tagline:
    textColor: "{colors.white}"
    typography: "{typography.title}"
  foot-line:
    textColor: "{colors.white}"
    typography: "{typography.body}"
  resume-line:
    backgroundColor: "{colors.resume-track}"
    rounded: "{rounded.resume}"
    height: "{spacing.resume-height}"
  device-frame-iphone:
    backgroundColor: "{colors.device-black}"
    rounded: "{rounded.frame-iphone}"
    padding: "{spacing.frame-iphone}"
    width: "800px screen"
  device-frame-ipad:
    backgroundColor: "{colors.device-black}"
    rounded: "{rounded.frame-ipad}"
    padding: "{spacing.frame-ipad}"
    width: "1240px screen"
  device-frame-appletv:
    backgroundColor: "{colors.device-black}"
    rounded: "{rounded.frame-appletv}"
    padding: "{spacing.frame-appletv}"
    width: "2360px screen"
---

# Design System: Ithaca for Plex App Store one-sheets

> **Scope.** This file covers only the App Store marketing surface: the screenshot slides and the product page header built by `docs/app-store/compose.py`. The app's own interface is governed by [`STYLE.md`](STYLE.md) ("native vibes, not orange"), which stays the authority for everything inside the app. Nothing here applies to app UI, and nothing here overrides STYLE.md.

## Overview

**Creative North Star: "The One-Sheet"**

Every slide is a theatrical one-sheet poster. The device is the key art, the claim is the title, and a billing block credits what Ithaca plays the way a film poster credits its cast. The film on the device's screen continues past the frame as the poster's art, darkened and pulled toward poster black, so the slide reads as one picture with a device standing in it rather than a phone floating on a gradient.

The world is black, white and the film's own colour. There is no brand colour, no gradient for its own sake, no badge, card or logo. Type is condensed and poster-like: Anton for the claim and the foot line, Six Caps for the tagline and billing. The only lit marks are the screen and a thin resume line under the device.

The set is read as a row in the App Store, so all slides of a device class share one central axis and one shelf line. The product page header carries the same world without a device: a letterboxed 4K film frame with the title in Apple's crop-safe area.

**Key Characteristics:**
- Poster black canvas; white type only.
- The device is drawn (frame and rim are the build's own), centred, standing on a fixed shelf line.
- Key art is the actual picture the app shows on that screen, continuing past the frame.
- Two-line uppercase Anton title, each line fitted to the same width, final punctuation hung.
- Billing block in Six Caps, every line fitted edge to edge, with half-size role labels.
- A resume line under the device as the single progress mark.

## Colors

Poster black with white type; all other colour comes from the film on screen, tinted per slide.

### Primary
- **Film Tint** (one `tint-*` per slide): the key art's own dominant colour, laid over the art with `mix-blend-mode: color` at 72% opacity (50% on the header). It is chosen from the art, never from a brand palette. Slides that share art share a tint (Tears of Steel uses Steel on the slide and the header).

### Neutral
- **Poster Black** (`poster-black`): the canvas of every slide and the header; the art fades into it.
- **Device Black** (`device-black`): the drawn device body, a step darker than the canvas so the frame reads as an object.
- **Frame Rim** (`frame-rim`): the 3px outer rim of the drawn device.
- **White** (`white`): titles, tagline, foot line, the filled part of the resume line.
- **Billing White** (`billing-white`): the billing block, one step down so the title leads.
- **Resume Track** (`resume-track`): the unfilled part of the resume line.

### Named Rules
**The Film's Own Colour Rule.** The only hue on a slide is the hue of the film on its screen. Ithaca's brand accent never appears on the marketing surface; per STYLE.md it lives in the icon only.

**The Darkened Art Rule.** Key art always sits below the type in value: brightness .52 and saturation .75 for the sharp layer, brightness .45 and a 14px blur for the soft layer, 1.5 slide widths wide (a slide may keep a poster recognisable with `cover`: Describe It uses its top pick's poster at one slide width and a 3px blur), brightness .42 on the header, then the film tint.

## Typography

**Display Font:** Anton (SIL OFL, bundled in `docs/app-store/fonts/`)
**Label Font:** Six Caps (SIL OFL, bundled)

**Character:** A wide-shouldered poster sans for the claim against a hairline condensed face for the credits, the same contrast a film one-sheet draws between its title and its billing block.

### Hierarchy
- **Display** (Anton 400, uppercase, line-height .867, second line .14em below): the two-line title. Each line is sized so its text, without hung punctuation, fills the title width (1120 / 1500 / 2300px), capped at the per-device maximum. On Apple TV the two lines join into one.
- **Headline** (Anton 400, 210px, line-height .88): the product page header's title only.
- **Title** (Six Caps, uppercase, tracked .34em): the tagline at top centre, one short line.
- **Label** (Six Caps, tracked .05em, line-height 1.02, at 84% white): billing lines, each fitted to the billing width (920 / 1300 / 2000px), between 70% and 135% of the base size, then shrunk together in 4% steps until the block clears the foot line.
- **Label role** (Six Caps at half the line size, tracked .12em, raised .32em, .3em side margins): the small credit words inside billing lines ("PICTURE IN", "SOUND IN", "ALSO STARRING").
- **Body** (Anton, uppercase, tracked .24em): the foot line at the bottom, shrunk to fit 90% of the slide width when long.

### Named Rules
**The Hung Punctuation Rule.** A title's closing period or question mark sits outside the fitted width (`margin-right: -.236em`), so the letters, not the punctuation, align to the measure. A mid-line mark on the one-line Apple TV title is not hung.

**The Fitted Billing Rule.** Billing lines are set edge to edge like a poster's credit block: each line scaled to the block width, never left ragged, never wrapped.

**The Credit Wording Rule.** Billing reads as credits: role label in small caps, then the claims in full caps, separated by middots. Claims are real features only; no invented reviews, awards or numbers.

## Layout

One central axis per slide. Top to bottom: tagline, device, resume line, title, billing block, foot line.

| Device | Canvas | Screen width | Shelf | Title top | Foot top | Art fade |
| --- | --- | --- | --- | --- | --- | --- |
| iPhone 6.9" | 1320 × 2868 | 800 | 1926 | 2000 | 2770 | 1040 to 1540 |
| iPhone 6.3" | 1206 × 2622 | scaled from 6.9" | | | | |
| iPad 13" | 2064 × 2752 | 1240 | 1880 | 1960 | 2660 | 1100 to 1700 |
| Apple TV | 3840 × 2160 | 2360 | 1600 | 1700 | 2090 | 900 to 1500 |

The device's bottom edge sits on the shelf, and its top is derived from the capture's aspect ratio, so every slide in a class stands on the same baseline. The billing block starts .55 × its base size below the title and must end .6 × its base size above the foot line. The tagline sits 52 / 56 / 44px from the top.

The header is 5244 × 2950. Its art is a 3840 × 1714 Tears of Steel frame letterboxed across the full width at its own aspect ratio. Title and one billing line sit centred in the safe area (1402 × 962 at x 1921, y 660), the only region that survives every crop.

### Named Rules
**The Shelf Rule.** One central axis and one shelf line per device class. A slide never moves the device to make room for copy; copy fits to the slide.

**The Continuing Art Rule.** Where the screen shows a hero picture, the same art is placed sharp at the exact position the app draws it (`place`, measured with `place.py`), so it continues past the frame. It fades out at its own edges (6% sides, 7% top, from 80% down) into a blurred copy of itself, and the whole art layer fades to poster black between the fade stops. Screens with no hero, and Apple TV (whose hero fills the screen), get only the soft layer.

## Elevation & Depth

Depth comes from the drawn device against the darkened art, not from layered surfaces. The device carries one rim and one ambient drop.

### Shadow Vocabulary
- **Device rim** (`0 0 0 3px #33363E, inset 0 0 0 2px rgba(255,255,255,.06)`): the drawn bezel edge.
- **Device drop** (`0 72px 140px rgba(0,0,0,.65)`): a soft fall-off below the device onto the shelf.

### Named Rules
**The Drawn Frame Rule.** The device frame is drawn by the build. Nothing is placed over Apple's device bezels or mockups; Apple's terms allow nothing over their bezels, so the build owns the frame.

## Shapes

The device frame follows the capture's own display corner: the screen is clipped to the device's corner radius scaled to the slide (190px iPhone, 62px iPad and 0 Apple TV in capture pixels), and the frame adds its padding to that radius. The resume line is a 6px bar with 3px rounded ends. Nothing else on the slide has a shape: no cards, pills, badges or boxes.

## Components

### Device
- **Shape:** the drawn frame described in Shapes, in device black, with the rim and drop from Elevation.
- **Content:** a real capture of the app from the simulator, against the "Ithaca Demo" library only. On iPad, the system's window resize grabber is painted out with the colour beside it; it is system chrome, not the app.

### Resume Line
- **Style:** a 6px bar the width of the screen, 28px below the shelf. Filled in white from the left to the slide's `stop` fraction; the rest is the resume track.
- **Role:** the only lit mark besides the screen; reads as playback progress.

### Title
- Two lines (one on Apple TV), Anton, uppercase, centred, fitted per the Hung Punctuation and Fitted rules.

### Billing Block
- Two to four lines of credits in Six Caps, fitted per line, with role labels in half-size. It follows the title and yields to the foot line.

### Tagline and Foot Line
- **Tagline:** one short claim in tracked Six Caps at top centre, the poster's tagline.
- **Foot line:** one sentence in tracked Anton at the bottom, the place a one-sheet puts its release line.

### Product Page Header
- Letterboxed 4K film frame whose top and bottom 9% fade into the bars, Steel tint at 50%, a wide radial scrim of poster black centred on the safe area, then the title and one billing line. No device, since a crop would cut it.

## Do's and Don'ts

### Do:
- **Do** use as key art only the picture the app shows on that captured screen, from Blender Studio open movies or public-domain films, with its source and licence listed in `docs/app-store/keyart/SOURCES.txt`.
- **Do** keep one central axis and one shelf line per device class.
- **Do** fit every billing line edge to edge and every title line to the same width.
- **Do** tint the art toward black with the film's own colour.
- **Do** draw the device frame in the build.
- **Do** embed provenance in every shipped raster (`impeccable embed-prompt`), naming the capture and key art it was composed from.
- **Do** scale the 6.3" iPhone set from the 6.9" renders rather than laying it out separately.

### Don't:
- **Don't** use logos (Plex, Dolby, DTS, Apple or any other), third-party studio art, or any celebrity likeness.
- **Don't** capture with any account other than the demo account; other libraries show other studios' posters.
- **Don't** put anything over Apple's bezels; the frame is drawn.
- **Don't** add decorative gradients, badges, cards, ratings or invented reviews and awards.
- **Don't** use the brand accent or any colour that is not the film's own.
- **Don't** move a device off the shared shelf or axis to make room for copy.
- **Don't** apply anything in this file to the app's UI; STYLE.md governs the app.
