# App Store listing: Ithaca for Plex

Draft text for App Store Connect, with options where a pick is needed. Limits are App Store Connect's. Name and subtitle are shared by iOS and tvOS; description, promotional text and keywords are set per platform.

## App Information

- **Name** (30): Ithaca for Plex
- **Primary category:** Entertainment. **Secondary:** Photo & Video.
- **Privacy policy URL:** https://inceptyon.io/ithaca/privacy
- **Content rights:** yes, it shows third-party content (artwork and details from Plex's metadata and, through Seerr, TMDB), and yes, the rights are in place: it plays the user's own library through their own servers.
- **Age rating:** 4+ expected, like Infuse, Plex, Dusk, Plezy and Swiftfin.

**Subtitle** (30), pick one:

1. Plex player for Apple TV (24)
2. Watch your Plex library (23)
3. Plays your Plex files direct (28)
4. Movies and TV from your server (30)

## Version 1.0 (iOS: iPhone and iPad)

**Promotional text** (170), pick one:

1. Watch your Plex movies and shows on Apple TV, iPhone and iPad. Ithaca plays the original file, with Dolby Vision, Atmos and every subtitle track. (147)
2. A Plex app with no ads, no tracking and no promoted shows. It plays the original file from your server, with no transcoding unless you ask for it. (148)

**Description** (4000)

> Ithaca is a Plex app for Apple TV, iPhone and iPad. It shows what's on your Plex Media Server and plays the original file, with no transcoding unless you ask for it.
>
> PLAYS THE ORIGINAL FILE
> Ithaca plays your files straight from the server instead of asking Plex to convert them. MKV, HEVC, Dolby Vision, HDR10+, Dolby Atmos, DTS, PGS and SRT subtitles. Dolby Vision profile 7 is converted on the device so your TV shows it as Dolby Vision. When a file can't play directly, Ithaca falls back to Plex on its own, and you can always pick a quality for one session.
>
> REQUEST WHAT YOU DON'T HAVE
> Connect Seerr, Overseerr or Jellyseerr and search shows the movies and shows you don't have yet. Request a movie or a season right from Ithaca, browse what's trending, and on iPhone and iPad get a notice when it lands in Plex.
>
> BUILT FOR APPLE DEVICES
> Written in SwiftUI with Apple's own controls and Liquid Glass. On Apple TV: Top Shelf, the focus engine and the Siri Remote as you know them. On iPhone and iPad: AirPlay, downloads for the plane, and Picture in Picture. Ask Siri to play a movie or the next episode. Watch together over SharePlay.
>
> NO ADS, NO TRACKING
> No ads, no promoted shows, no news, no tracking, no analytics. Watch state, ratings and progress live in your Plex account, so every device picks up where you left off. Several servers? Home merges them into one.
>
> HELP CHOOSING
> Rate what you watch and get rows of similar titles. Can't decide? Pick Something chooses from your library. With Ithaca Pro, type what you're in the mood for, like "a heist movie under two hours," and Ithaca picks from your library, on your device. With Seerr, it suggests new titles to request too.
>
> EVERYTHING ELSE
> Skip intro and credits, continuous play with Up Next, a check-in when you've fallen asleep, Plex Live TV with the guide, Plex Home profiles, audio and subtitle choices that stick.
>
> FREE TO TRY
> Ithaca is free to download. Ithaca Pro is a one-time purchase that covers iPhone, iPad and Apple TV, with a free 7-day trial. No subscription. Family Sharing included.
>
> Ithaca needs a Plex Media Server with your movies and shows. It is an independent app and is not made or endorsed by Plex.
>
> Screenshots show Blender Studio's open movies (Sintel, Tears of Steel, The Daily Dweebs, Coffee Run, Sprite Fright, Wing It!, Spring, Charge, Caminandes), © Blender Foundation, CC BY, and public-domain films.

Open in this draft: the Picture in Picture, Siri and Live TV wording needs checking against the app before this ships.

**Keywords** (100 bytes; "Ithaca", "for" and "Plex" are already in the name, so they aren't repeated)

> media server,player,dolby vision,atmos,hdr,4k,mkv,remux,movies,tv shows,live tv,home theater,seerr

**Support URL:** https://inceptyon.io/ithaca/support

**Copyright:** 2026 Inceptyon Labs LLC

## Version 1.0 (tvOS: Apple TV)

Same description, with the first section led by the living room:

> Ithaca is a native Plex player for Apple TV, iPhone and iPad. Pick something from the couch, press play, and get the picture and sound exactly as the file has them: Dolby Vision, HDR10+, Dolby Atmos and every subtitle, straight from your server.

**Keywords** (tvOS)

> media server,player,dolby vision,atmos,hdr,4k,mkv,remux,movies,tv shows,live tv,home theater,siri

## App Review Information

- **Sign-in:** a Plex account made for review (username and password go in App Store Connect, never here). It sees one server, "Ithaca Demo", with public-domain films and Blender Studio's open movies.
- **Notes** (draft):

> Ithaca is a client for Plex Media Server, which people run at home. Sign in with the Plex account above. On Apple TV, the app shows a code; enter it at plex.tv/link on any device while signed in to the review account. On iPhone and iPad, sign in in the Plex sheet that opens.
>
> The account has one shared server with public-domain and Creative Commons films and series. Things to try: play a film (it plays directly from the server), change subtitles and audio in the player, rate a film, download one on iPhone or iPad.
>
> Ithaca Pro unlocks Describe It: on Home, open Pick Something and tap the field at the top ("Describe what you're in the mood for"), or go to Settings → Ithaca Pro. Start the free 7-day trial there ("7-Day Trial" in-app purchase, free), then try "a short animated movie" or "old silent horror". Describe It runs on the device (Apple's on-device model where Apple Intelligence is on, built-in matching elsewhere); nothing is sent to us. After the trial, Ithaca Pro is a one-time purchase covering iPhone, iPad and Apple TV.
>
> Seerr is an optional companion server the user runs at home; requests appear once it is set up in Settings → Seerr. Athena (github.com/inceptyon-labs/athena) is another, optional one that lets Claude answer Describe It instead of the device; nothing else needs it.

## App Privacy

- **Data collection:** Data Not Collected. No analytics, crash reporting or advertising SDKs. Plex sign-in and library data go only to Plex and the user's servers. Describe It runs on the device. Only if the user has their own Athena server and agrees in the app does it send what they type there, and Athena passes it to Anthropic's Claude; that server is theirs, not ours. Purchases go through Apple; Inceptyon sees none of it.

## Export compliance

Same answers as Argo once the binary is checked (checklist, section 6): VLCKit brings its own TLS library.
