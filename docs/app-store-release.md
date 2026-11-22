# Getting Ithaca on the App Store

Checklist for the first App Store release of "Ithaca for Plex" (`com.inceptyon.ithaca`): one universal-purchase record with an iOS app (iPhone and iPad) and a tvOS app. Steps marked **Claude** are done from the repo or the App Store Connect API key; **You** steps need the web UI, a device, or an account.

Already in place: the Inceptyon Labs developer account, an Apple Distribution certificate (from Argo), the App Store Connect API key (Argo's `.asc.local`), bundle IDs `com.inceptyon.ithaca` and `com.inceptyon.ithaca.topshelf` (Xcode-managed), `PrivacyInfo.xcprivacy`, `ITSAppUsesNonExemptEncryption` false in both Info.plists, and pages at `inceptyon.io/ithaca/privacy` and `inceptyon.io/ithaca/support` (the support page was the site's catch-all home page until it was added on 2026-11-21: check a page's title, not its status). No app record exists yet.

## 0. Decisions

- [x] Name: **Ithaca for Plex**. Plex's trademark guidelines ask for "for Plex" after a unique name and no name starting with "Plex"; no Plex logo, and the description says it's unofficial.
- [x] Pitch: plays everything direct; native Apple feel; just your library; smart picks (`PRODUCT.md` → Positioning).
- [x] Demo content for screenshots and App Review: public-domain films and Blender Studio's open movies with their real art. Never titles from the Uranus library.
- [x] Price: free download with a 7-day trial and a one-time **Ithaca Pro** unlock for the smart features (Argo's model). Price to set; the market's lifetime band is $9.99–$14.99 per platform (SenPlayer, VidHub) or $99.99 (Infuse, Zuno), and Plezy is $5.99 upfront.
- [x] App Review signs in with a demo Plex account that sees only an "Ithaca Demo" library on Uranus.
- [x] Pro unlocks **Describe It**, with its To Request suggestions (2026-11-21). It runs on the device with nothing to set up, so App Review can try it: Apple's on-device model reads the request on iOS 26 and later with Apple Intelligence on, and a fixed phrase list reads it everywhere else, Apple TV included (tvOS has no Foundation Models). Ithaca ranks the library itself. Athena (called Mentor until 2026-11-21) stays an option for a house that runs one, asked about before its first request. Random Pick Something, Because You Liked and everything else stay free.
- [x] TrueHD decoder in the App Store build: **Ithaca's TrueHD VLCKit** (2026-11-21, reversing the 2026-11-20 stock choice; build 2 went out with stock). TrueHD decodes on the device, the licensing risk in `docs/playback.md` → "Dolby TrueHD decoding" stands, and the modified VLCKit's source has to be offered under the LGPL (open item in section 2).
- [x] Version: `MARKETING_VERSION` 1.0 (was 1.8.0, inherited from Dusk).

## 1. Developer portal

- [ ] **Claude:** check the capabilities on both app IDs: Group Activities and App Group `group.com.inceptyon.ithaca` on `com.inceptyon.ithaca`, the App Group on `com.inceptyon.ithaca.topshelf`. The API lists none on the Xcode-managed IDs today.
- [ ] **Claude:** distribution signing for both platforms: automatic signing with the API key (`-allowProvisioningUpdates`), or App Store profiles like Argo's if that fails.

## 2. Repo

- [x] **Claude:** `.asc.local` (gitignored) with the API key flags, copied from Argo.
- [x] **Claude:** version per the decision above; `scripts/deploy.sh` raises `CURRENT_PROJECT_VERSION` by one on every upload.
- [x] **Claude:** Describe It without Athena: `DescribeItAppleModel` (Foundation Models, on-device), `DescribeItPhrases` and `DescribeItRanker` (`docs/ui-features.md`). Checked in the simulator against the demo library.
- [x] **Claude:** Seerr artwork with image caching off: images come from `image.tmdb.org` unless Seerr's public settings say caching is on. Was: Ithaca loads every Seerr image through `/imageproxy/tmdb/…`, which Seerr answers with 404 "Image caching is disabled." unless Settings → General → Enable Image Caching is on (off by default). Fall back to `image.tmdb.org` when Seerr's public settings say caching is off, and add TMDB's image server to the privacy policy. Failed images also stay cached until the app is reinstalled. Found 2026-11-21 while capturing; Uranus's Seerr now has caching on.
- [x] **Claude:** StoreKit 2 trial and Pro unlock on iOS, iPadOS and tvOS (`IthacaStore`, `ProView`; Settings → Ithaca Pro, and the locked Describe It field opens it), adapted from Argo's `Store.swift` and `PaywallView.swift`: start the trial, buy, restore; Settings shows the state. One purchase covers every platform (universal purchase). Products: `com.inceptyon.ithaca.trial` (Non-Consumable, Free, "7-Day Trial", Family Sharing off) and `com.inceptyon.ithaca.pro` (Non-Consumable, "Ithaca Pro", Family Sharing on).
- [x] **Claude:** Describe It consent. Guideline 5.1.2(i) requires disclosing, and getting explicit permission, before personal data goes to a third-party AI. Only Athena sends anything off the device: before its first request an alert says the text and library titles go to Athena and from there to Anthropic's Claude (Use Athena / Use This Device), and Settings → Athena can turn it off.
- [x] **Claude:** privacy policy and support page (`inceptyon-website`, `public/ithaca/`, published 2026-11-21): on-device Describe It, Athena only with consent, in-app purchases through Apple, Seerr artwork from TMDB when Seerr doesn't cache images; support covers sign-in, Restore Purchase, Describe It and Seerr.
- [x] **Claude:** `scripts/deploy.sh` and `scripts/asc.mjs` from Argo, archiving and uploading both `Ithaca` and `Ithaca-tvOS`, with TestFlight "What to Test" from git-cliff (`docs/development-workflow.md` → App Store Release).
- [x] **Claude:** release preflight (`scripts/deploy.sh --preflight`) refuses to archive unless VLCKit is Ithaca's TrueHD build (`3.7.4-ithaca2`, not VideoLAN's stock UUIDs).
- [x] **Claude:** LGPL source offer for the modified VLCKit: the patches, build script and license are public at `github.com/inceptyon-labs/ithaca-vlckit` (2026-11-21), and `ThirdPartyNotices.txt` points there. Keep it in step with `ci_scripts/` (`docs/development-workflow.md`).

## 3. Demo library and review account

- [x] **You:** free Plex account for App Review. Its sign-in and password are in 1Password, never in the repo.
- [x] **Claude:** demo libraries on Uranus, named "Films" (section 28) and "Series" (section 27): Movies (Blender open movies, public-domain features) and TV (public-domain serials and cartoon series, Caminandes). Plex folder naming; original-release posters where TMDB's are modern designs.
- [x] **Claude:** shared only those libraries with the review account (downloads allowed), seeded its watch history and ratings, and added it to Seerr as request-only (permission 32, no auto-approve).
- [ ] **You:** check Plex Remote Access is on, and that the review account plays from a phone on cellular. Remote streaming needs your Plex Pass as server owner.
- [ ] **Claude:** review notes: sign-in (plex.tv/link code on Apple TV, the Plex sign-in sheet on iPhone/iPad), what to try, the trial, and that Athena and Seerr are optional self-hosted companions.

## 4. Copy

- [ ] **Claude:** drafts in `docs/app-store/listing.md`: subtitle options, promotional text, description, keywords, review notes. **You** pick.
- Name and subtitle are shared across platforms; description, promotional text, keywords and screenshots are set per platform (iOS and tvOS each).

## 5. Screenshots

Sizes (Apple's screenshot specifications page, read 2026-11-20). Up to 10 per size, PNG or JPEG, no alpha.

- iPhone, required: 1206 × 2622 (Dynamic Island, medium display). Optional: 1320 × 2868 (large display).
- iPad 13-inch, required for an app that runs on iPad: 2064 × 2752.
- Apple TV, required: 3840 × 2160 (or 1920 × 1080).
- iPhone Duo (2853 × 2007 inner, landscape): optional now, required from April 2027 for apps built with the iOS 27.1 SDK or later. Uploaded as `APP_IPHONE_DUO`, which also earns the "made for iPhone Duo" badge.
- Product page header: 3840 × 1646 (21:9), art safe area 1646 × 661 at x 1097, y 493; or the universal asset, 5244 × 2950, safe area 1402 × 962 at x 1921, y 660 (what Argo used).

- [x] **Claude:** direction options through Impeccable on its decision page (two hands). **You** picked **The One-Sheet**: each slide is a movie poster, the device as key art, the claim as the title, a billing block crediting the features (`.impeccable/surfaces/docs-app-store-compose-py.md`).
- [x] **Claude:** `docs/app-store/capture.sh` (simulators signed in to the review account through DEBUG screenshot mode, `docs/screenshots.md`) and `compose.py` (slides, header). `place.py` measures where the app draws each key art so the poster art lines up with the screen.
- [x] **Claude:** six slides each for iPhone 6.9-inch and 6.3-inch, iPad 13-inch and Apple TV, plus the header (`docs/app-store/screenshots/`). iPhone and iPad: Home, 4K remux (detail), Seerr request, Describe It, Downloads, Up Next. Apple TV swaps Downloads for the library. Slide 6 is the Caminandes show page. Impeccable's finish review ran twice: the second verdict scored 6 of 8 fixes resolved, with 2 partial and 2 regressions; all were addressed afterwards except a clipped "Pick Again" pill at the bottom of Apple TV slide 4, and that last batch has not been re-scored. The design record is `DESIGN.md` (App Store art only; `STYLE.md` still governs the app).
- [x] **Claude:** six iPhone Duo slides (`screenshots/duo/`, 2026-11-21), the same shots as iPhone, from the inner screen of the "Ithaca Duo" simulator. Not yet re-scored by Impeccable's finish review.
- The look must be clearly Ithaca's own. Dusk's listing uses a dark ground, a centred headline and the device below it.

## 6. App Store Connect

- [x] **You:** Apps → + → New App: platforms iOS and tvOS, name "Ithaca for Plex", English (U.S.), bundle ID `com.inceptyon.ithaca`, SKU `ithaca`, full access. App ID 6837716351 (2026-11-21).
- [x] **Claude (API):** category Entertainment, secondary Photo & Video (Infuse, Plex and Dusk all use this pair); privacy URL `https://inceptyon.io/ithaca/privacy`; copyright "2026 Inceptyon Labs LLC"; subtitle "Plays your Plex files direct" (option 3 in `listing.md`, changeable until submission).
- [ ] **You:** age rating questionnaire. Infuse, Plex, Dusk, Plezy and Swiftfin are all 4+.
- [ ] **You:** App Privacy: Data Not Collected (no analytics; Describe It runs on the device, and Athena is the user's own server). Content Rights: yes, it shows third-party content, and yes, the rights are in place.
- [x] **Claude (API):** price Free; availability in 174 of 175 storefronts (all but France, see export compliance). Both in-app purchases created with localizations, availability and the Pro page as review screenshot (`-IthacaScreenshotScreen pro -IthacaPaywall YES`): the trial is Free and Ready to Submit.
- [x] **You:** Ithaca Pro's price: $4.99 (2026-11-21), Ready to Submit.
- [x] **Claude (API):** the Apple TV Privacy Policy (App Information, free text, because Apple TV can't open a URL): the web policy as plain text (`privacyPolicyText`). Change it whenever `inceptyon-website/public/ithaca/privacy.html` changes.
- [x] **Claude:** export compliance. VLCKit carries libgcrypt (HLS AES and SRTP) beside Apple's Secure Transport: standard encryption, as with Argo's WebRTC, so France is left out of availability and `ITSAppUsesNonExemptEncryption` stays false.
- [x] **Claude (API):** iOS and tvOS version pages: 30 screenshots (iPhone 6.9 and 6.3, iPad 13, iPhone Duo, Apple TV; all processed), description (with a Seerr requests section), keywords, promotional text option 1, support URL `https://inceptyon.io/ithaca/support`.
- [x] **Claude (API):** the product page header (`docs/app-store/screenshots/header.png`, 5244 × 2950) on both versions, through the asset library (`appAssetLibraryImages`, placement `PRODUCT_PAGE_HEADER_ASSET`).
- [x] **Claude (API):** App Review information on both versions: the demo account, notes from `listing.md`, contact copied from Argo.

## 7. Build, TestFlight, submit

- [x] **Claude:** Release archives of both apps upload and process: 1.0 (build 2), 2026-11-21, with stock VLCKit and automatic signing. `./scripts/deploy.sh` (prod) attaches the build to both versions; for 1.0 it stops there.
- [x] **Claude:** TestFlight internal group "Inceptyon" gets every build, with Argo's internal tester added.
- [ ] **You:** on the Apple TV, iPhone and iPad: sign in, direct play (Dolby Vision, Atmos, TrueHD, PGS), downloads, SharePlay, Top Shelf, the trial and purchase in the sandbox.
- [ ] **You:** submit both platforms with the in-app purchases from the version page (the first purchases go with the version).

## Rejection risks, most likely first

- 2.3.1, a feature in the screenshots the reviewer can't reach: slide 3 shows Seerr requests. Handled 2026-11-21: the review notes give the public Seerr (`seer.jplex.us`, through Cloudflare), where the review account signs in with Plex as a request-only user.
- 2.1, reviewer can't sign in or the library is empty: the demo account and a library that answers from outside the house.
- 2.1 / 3.1.1, Pro features the reviewer can't reach: see the open decision in section 0.
- 4.1 / 4.3, resemblance to Dusk for Plex, which Ithaca descends from (MIT, credited in `ThirdPartyNotices.txt`): own name, icon, screenshots and copy.
- 5.1.2(i), Describe It sending text to a third-party AI: the consent prompt and the privacy policy.
- 5.2, Plex trademark: "for Plex", no logo, unofficial stated. Slide 1 and the header said "The Plex app you wanted" until 2026-11-21, which read as Plex's own app; they now say "The player your Plex deserves."
- 5.2.1, third-party artwork in screenshots: avoided with the public-domain and Blender library.

## Sources

- [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications)
- [Creative assets specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/creative-assets-specifications/)
- [Add platforms (universal purchase)](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-platforms/)
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Upcoming requirements (Xcode 26 since 2026-04-28)](https://developer.apple.com/news/upcoming-requirements/)
- [Plex trademarks and guidelines](https://www.plex.tv/about/privacy-legal/plex-trademarks-and-guidelines/)
