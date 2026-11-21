# Ithaca audit, 2026-11-04

Audited at commit `b019603` (88.6K lines of Swift, Objective-C and Rust). Read-only: nothing in the app was changed.

Status, later the same day: B1 to B5 and M1 to M10 are fixed in `cf78e4e` (downloads, offline sync) and `1ca09ac` (playback). Feature 1 is in `14658b2`: lossless audio in the HDR remux and PGS subtitles drawn over it. P1 (memory budgets) is fixed in `4df300e`. The codec items for 4:2:2 and 4:4:4 video and for 4K AV1 and VP9 are fixed in `e7c72b4`; interlaced video turned out to need no change, because libvlc already deinterlaces automatically. None of it has run on a device yet.

Status, 2026-11-05 (uncommitted at the time of writing): R1 has a privacy manifest in both apps, and a policy page is written for `inceptyon.io/ithaca/privacy.html`. S2 is fixed. S1 now shows "not encrypted" beside a server connected over plain HTTP; the switch was not added, because a server set to require secure connections already forces HTTPS. P2 and P3 are fixed. P4 needs no change: this toolchain's `@Observable` skips equal-value writes. P5 is left alone, because a longer limit also lengthens the wait when the network is down. Of the three suspected bugs: the transcode-session leak is not real (a declined decision starts nothing on the server), the download reconciliation gained one guard, and the VLCKit hang is real and fixed by releasing the player off the main thread. Still open: R2, R3, R4, S3, and features 2 and 3.

## Summary

- **Security:** no critical or important issue. Three low-severity notes.
- **Bugs:** five worth fixing soon and ten minor. The picture freeze from 2026-11-02 has no detection anywhere in the code (B3), and its cause was never confirmed, so removing the upscaler may not have fixed it.
- **Performance:** five items. The largest is fixed-size memory budgets on older Apple TVs.
- **Release:** an App Store upload is blocked today by a missing privacy manifest, and the TrueHD-enabled VLCKit build must not ship.
- **Codecs:** every file opens. The gap is that HDR is lost when the audio is DTS or the subtitle is PGS or ASS.
- **Features:** full-quality playback with no trade-off, Jellyfin and Emby servers, and Describe It without a server to set up.
- **Market:** real, but crowded with free rivals, including the project Ithaca derives from. $7.99 to $9.99 one-time as it stands, about $14.99 a year once the first two features exist. Expect side income.

Suggested fix order: R1 (privacy manifest), B4 (re-download fails), B3 (freeze watchdog), B1 and B2 (network change), B5 (pause while loading), P1 (memory budgets).

## Scope

Audited, with what a failure there costs:

| Domain | Cost of a failure |
|---|---|
| Auth and secrets (Plex tokens, Seerr session, Mentor) | Account takeover of a Plex server |
| Network transport and inbound surfaces (ATS, plain HTTP, loopback proxy, deep links) | Token leak on the network, or another app driving playback |
| Playback session lifecycle and the two engines | Wrong watch state, frozen or black picture, leaked players |
| Downloads and offline watch-state sync | Lost downloads, lost or overwritten watch progress |
| Native code and build supply chain (Rust FFI, Objective-C frame tap, install scripts) | Memory corruption from a crafted file, or a tampered binary in the build |
| Performance-sensitive paths (images, decoding, timers, fan-out) | Dropped frames and memory kills on Apple TV |

Skipped: the SwiftUI view layer (layout, focus, styling), Seerr and Live TV feature logic beyond their network boundary, Siri title matching, the Top Shelf extension's content, the VLCKit and libdovi sources themselves, and the Mentor server (separate repo). No tests were run and nothing was exercised on a device.

How it was done: six cheap scouts mapped each domain, three deep reviewers traced the playback, engine and download code against specific hypotheses, and I re-read the code for every finding marked "me" below. Findings marked "reviewer" were traced by a deep reviewer and not re-read by me.

## Security

No critical or important security issue found. The boundaries that matter are enforced in code:

- Tokens live in the Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (`KeychainHelper.swift:8`). Server metadata in UserDefaults carries no token.
- App Transport Security allows local networking only. There is no `NSAllowsArbitraryLoads`, no exception domain and no custom certificate handling, so TLS validation is the system default.
- Plain HTTP to a Plex server is offered only for a local, non-relay, private-network address while the device shares the server's public IP and the server does not require HTTPS (`PlexServer.swift:79-85`). The token is withheld until `/identity` answers with the expected machine identifier (`ServerProbe.swift:279-303`).
- The Dolby Vision 7 proxy binds `127.0.0.1` on an OS-chosen port and requires a 16-byte random path token per session (`DolbyVision7HLSProxy.swift:291`, `:353-358`).
- The `ithaca://` deep link accepts only numeric rating keys and expires after 30 seconds (`TopShelfLink.swift:40`, `:20`).
- libvlc log lines are passed through a token redactor before they reach the unified log (`VLCKitEngine.swift:76`, `:88-94`). Playback URLs are logged hashed or redacted (`PlexService+Playback.swift:249`, `:860`).
- Every downloaded build input is pinned and SHA-256 verified before use: stock VLCKit archives (`install_vlckit.sh:27-36`), rustup-init (`install_ithaca_dovi.sh:47-75`), the Rust toolchain and the `dolby_vision` crate (exact pin, `Cargo.lock` tracked). The earlier healthcheck finding about piping rustup into a shell is fixed.
- The Rust FFI wraps both exports in `catch_unwind`, null-checks pointers and checks output capacity before copying (`Native/IthacaDovi/src/lib.rs:138-235`). The fMP4 rewriter bounds-checks sample counts, sizes and offsets against the box it read them from (`FMP4FragmentRewriter.swift:150-232`).

Notes (low severity):

| # | Finding | Where | Fix sketch |
|---|---|---|---|
| S1 | In plain-HTTP LAN mode the server token crosses the network unencrypted. The `/identity` check proves a server with that identifier answered, not that it is the real one, because the machine identifier is not secret. An attacker already able to intercept LAN traffic gets the token. This is the same trade-off Plex's own apps make. | `PlexServer.swift:79-85`, `ServerProbe.swift:279-303` | Show in server settings when a server is connected over plain HTTP, and offer a "secure connections only" switch. |
| S2 | Mentor accepts any `http://` host, while the Seerr client rejects non-local plain HTTP. A Mentor address typed as a public IP would send library titles, ratings and watch history unencrypted. No credential is involved. | `PickSomethingMentor.swift:14-31` vs `SeerrService.swift:829-836` | Apply `LocalNetwork.isLocalHost` to plain-HTTP Mentor addresses. |
| S3 | The custom VLCKit build is verified only against a checksum file written by the same local build. | `install_vlckit.sh:118-125` | Acceptable while the build is local-only. Do not publish that archive. |

## Bugs

File names are shortened: `+Session.swift` is `PlaybackCoordinator+Session.swift`, `+Timeline.swift` is `PlaybackCoordinator+Timeline.swift`.

### Worth fixing soon

**B1. The resume position can be reset to 0 after a network change (plain-HTTP server, AVPlayer session).** Checked by me.
- `plainHTTPSessionsSuspended` stops the engine but leaves it attached (`+Session.swift:1783`). `AVPlayerEngine.stop()` zeroes `currentTime` (`AVPlayerEngine.swift:313`), and `currentPlaybackPosition` returns the engine's clock for a stopped engine that had started (`+Timeline.swift:66-69`).
- If the reconnect gives up after 60 seconds and the network then comes back, backing out of the player sends the final "stopped" report with time 0 and Plex loses the resume point. While the server is unreachable that report is dropped, which hides the bug most of the time.
- VLCKit sessions are not affected, because its `stop()` keeps the clock.
- Fix: before stopping, put the captured position where the fallback rule will use it.

**B2. The player is left black with no error when that reconnect fails.** Checked by me.
- The failure path shows a 4-second toast and returns (`+Session.swift:1799-1802`). The engine is stopped with no error set, and the error overlay only reads `viewModel.playbackError` (`PlayerView.swift:1087-1090`).
- The same pattern applies when the next part of a stacked item fails to start (`+Session.swift:2179-2180`, `:2317`): a toast, then the player sits on the finished part.
- Fix: set a persistent load error in both places.

**B3. Nothing detects a frozen picture on VLCKit.** This matches the 2026-11-02 incident on the Living Room TV. App side checked by me, libvlc side by the reviewer.
- Stall recovery needs `isBuffering` and a clock that stopped (`PlayerViewModel+PlaybackControls.swift:582-627`). In a video-only freeze the clock keeps advancing, so nothing fires.
- The engine already samples libvlc's `displayedPictures` once a second and uses it only for the Playback Info row (`VLCKitEngine.swift:2109-2116`).
- The reviewer found two ways libvlc's tvOS video output stops drawing while playback continues, in the vendored source under `.build/vlckit/`. It skips every draw while the app is inactive. After a failed buffer reset it skips every frame until the view lays out again, and nothing on tvOS forces that layout. Replacement attempts and Live TV also load the engine during an HDMI mode switch without waiting (`+Session.swift:1538-1545`). None of these is proven to be the cause.
- Fix: when `displayedPictures` stays flat for a few seconds while time advances, log it at error level and call `recoverFromStall()`. The next freeze then leaves a log line and recovers.

**B4. Re-downloading a title whose file was replaced on the server fails permanently.** Checked by me.
- Preparing a download uses cached metadata when it exists (`DownloadManager.swift:1275-1281`). Deleting one download removes the video and resume data but not that metadata (`:2380-2384`). Only Delete All clears it.
- Trigger: download a film, delete it, Radarr or Sonarr upgrades the file, download it again. The old part key returns 404, and Retry reuses the same cache (`:587-605`).
- Fix: fetch fresh details when connected and use the cache only when offline, or delete the item's cached metadata with its record.

**B5. A pause issued while the item is still loading is ignored.** AVPlayer side checked by me, VLCKit side by the reviewer.
- `AVPlayerEngine.pause()` sets `.paused` (`:283-286`), then `player.play()` runs when the item becomes ready unless the source was opened with `shouldAutoPlay == false` (`:760-765`). VLCKit starts from `source.shouldAutoPlay` the same way (`VLCKitEngine.swift:601`).
- Trigger: AirPods removed, or a remote pause, during the load. Playback then starts anyway, possibly on the speaker.
- Fix: record the pause and honour it when the engine becomes ready.

### Minor

| # | Finding | Where | Checked by |
|---|---|---|---|
| M1 | VLCKit probably seeks twice on every network resume. The check at the first `.playing` compares against VLCKit's cached time, which is still 0, so the fallback seek always fires. The comment above it calls a seek at that moment the most fragile point of audio start-up. Confirm with two "VLCKit seek to" lines per resume in a device log. | `VLCKitEngine.swift:1372-1383` | reviewer, needs a device log |
| M2 | VLCKit's `isBuffering` probably stays true after the first buffer fill, because libvlc keeps sending buffering events with no playing event after them. Seeks that libvlc ignores are then never retried. | `VLCKitEngine.swift:1355-1367`, `:1737` | reviewer, needs a device log |
| M3 | Offline watch-state actions that can never succeed (item deleted, 401) are retried every 15 minutes forever, and the "Pending Watch Sync" row cannot be cleared. | `OfflinePlaybackSyncManager.swift:414-447` | me |
| M4 | Offline: watching past 90% and then rewinding below it before stopping drops the watched mark, because each progress write recomputes it from the current offset. | `OfflinePlaybackSyncManager.swift:62`, `:359` | me |
| M5 | The plain-HTTP reconnect task is not cancelled when a session is finalized. Starting the next episode during the wait leaves a recovering spinner over it for up to 60 seconds. | `+Session.swift:2322-2334`, cancelled only at `:2436` | me |
| M6 | Smart Downloads checks "player is showing" through `showPlayer`, which is false during Picture in Picture, so it can remove the episode being watched. | `IthacaApp.swift:266`, `PlaybackCoordinator.swift:1021-1023`, `SmartDownloads.swift:196` | me |
| M7 | An undecodable `downloads.json` or `playback-sync.json` is treated as empty and overwritten by the next save. The video files stay on disk with no record, and Delete All is disabled when there are no records. There is no schema version or backup. The trigger is narrow today: an older build reading a file written by a newer one. | `DownloadFileStore.swift:50-53`, `OfflinePlaybackSyncStore.swift:11-17` | reviewer |
| M8 | AVPlayer: a seek made before the item is ready is overwritten by the resume seek. | `AVPlayerEngine.swift:730-740` | me |
| M9 | Switching quality reads the position before awaiting the transcode URL, so the new stream starts a second or two back. | `+Session.swift:840`, `:931`, `:997` | me |
| M10 | iOS: the Picture in Picture output can be released on libvlc's video thread instead of the main thread. | `VLCKitEngine.swift:161`, `:194`, `:749` | reviewer |

Suspected but not confirmed: a Plex transcode session left running when a server-stream decision is declined or the AirPlay URL request throws (`+Session.swift:2033-2037`, `:374`), launch reconciliation resetting a download that finished in the background (`DownloadManager.swift:2151-2167`), and a main-thread hang if the VLCKit engine is released right after it starts.

Checked and found sound:
- Results from superseded playback attempts are rejected after every await in release builds.
- `AVPlayerEngine`'s KVO observers capture `self` weakly, so players are not leaked.
- The raw video output's buffer sizes and lifetimes, time units, and end-of-item firing once.
- The fallback ladder cannot loop, and Live TV never scrobbles.
- Offline replay does not overwrite newer server state, because it compares Plex's `lastViewedAt` first.
- Smart Downloads never touches another profile's downloads.

## Performance

| # | Finding | Where | Fix sketch |
|---|---|---|---|
| P1 | Memory budgets ignore device RAM. The decoded-image cache allows 192 MiB and VLC reads 128 MiB ahead on every LAN source, on top of 4K decode surfaces. tvOS 26 still runs on the 2 GB Apple TV HD and the 3 GB first-generation 4K. | `IthacaAsyncImage.swift:104-108`, `PlaybackEngine.swift:55-60` | Scale both by `ProcessInfo.physicalMemory`, for example 64 MiB each below 3 GB. |
| P2 | Home's recommendation shelves load genres and playback history one library at a time, each awaited before the next starts. Latency grows with the number of libraries and with each remote server's round trip. | `HomeRecommendationEngine.swift:127-137`, `:149-160`, `:234`, `:323` | Run the per-library requests in a task group. |
| P3 | Some Plex responses are still decoded on the main actor: Live TV providers and channel lists, playback metadata, download metadata. A large channel lineup is decoded and sorted on the main thread when Live TV opens. | `PlexService+Networking.swift:48-53`, callers at `PlexService+LiveTV.swift:15,24`, `PlexService+Playback.swift:552,596`, `DownloadManager.swift:1541,1582` | Route them through the existing `decodeJSONInBackground`. |
| P4 | The player view model's 4 Hz tick assigns `duration`, `seekableRange`, `isBuffering` and `playbackError` on every pass whether or not they changed, then runs nine update passes. If Observation notifies on equal-value writes in your toolchain, every view that reads those properties re-evaluates four times a second for the whole film. Unmeasured. | `PlayerViewModel+PlaybackControls.swift:42-90` | Assign only when the value differs, then confirm with the on-device profile. |
| P5 | Every API request has a 30-second whole-response limit. Fine on a LAN, tight for large unpaged responses from a slow remote server. | `PlexService.swift:171-197` | Raise `timeoutIntervalForResource` for the API session, or page the large listings. |

Already in good shape: image decoding and downsampling happen off the main thread with in-flight de-duplication and cancellation, images are requested at display size through Plex's photo transcoder, long collections use lazy stacks and grids, and library paging uses `X-Plex-Container-Size`.

## Release readiness

| # | Finding | Fix |
|---|---|---|
| R1 | There is no privacy manifest (`PrivacyInfo.xcprivacy`) anywhere in the repo. The app uses two required-reason APIs: `UserDefaults` (17 files) and free disk space (`DownloadFileStore.swift:213-221`). App Store Connect rejects uploads that use these without declared reasons. | Add a manifest to both app targets and the Top Shelf extension, declaring `CA92.1` for UserDefaults and `E174.1` for disk space, and state that no data is collected. |
| R2 | The framework installed in this checkout is `3.7.4-ithaca2`, the local build that re-enables the TrueHD decoder. `docs/playback.md` records that Ithaca holds no Dolby license and that VideoLAN removed this decoder from its App Store builds for that reason. | Ship stock VLCKit 3.7.3 in any public build. The code already falls back to Plex converting TrueHD. |
| R3 | No CI configuration in the repo runs the 28 test files, and the agent workflow is compile-only. Xcode Cloud workflows are stored outside the repo, so I could not see whether tests run there. | Add a test action to the Xcode Cloud workflow for the pure-logic suites. |
| R4 | The three largest files hold the riskiest logic: `VLCKitEngine.swift` (2,910 lines), `PlaybackCoordinator+Session.swift` (2,514) and `DownloadManager.swift` (2,512). The October healthcheck measured cyclomatic complexity 37 in `startPlaybackSession()`. | Extract the delivery ladder (direct play, remux, server stream, transcode) into a pure state machine with tests before adding more formats. |

## Codecs and formats

I read "codexes" as codecs. Everything VLC 3 can demux already plays, because `StreamResolver` sends anything outside the AVPlayer set to VLCKit. The gaps are about quality, not about files refusing to open.

| Format | Today | Gap |
|---|---|---|
| HDR10, HDR10+, HLG, Dolby Vision 5 / 7 / 8.1 / 8.4 in MKV | Real HDR through a lossless Plex remux into AVPlayer. DV7 is converted to 8.1 on device. | Only when the audio is E-AC-3, AC-3 or AAC and the subtitle is text. Otherwise the file plays on VLCKit, which renders SDR. |
| HDR with DTS, DTS-HD, FLAC or PCM audio | VLCKit, lossless audio, SDR picture | The typical UHD Blu-ray remux (HEVC HDR, DTS-HD MA, PGS) gets the worst picture. No setting lets the viewer choose HDR over lossless audio. |
| HDR with PGS, VobSub or ASS subtitles | VLCKit, SDR picture | Turning on an image subtitle turns off HDR. |
| AV1 | AVPlayer only with a hardware decoder, otherwise dav1d in software | Apple TV 4K models through the third generation (A15) have no AV1 hardware decoder. 4K AV1 is software-decoded with no fallback to a Plex transcode, and AV1 HDR never qualifies for the remux (`hdrVideoRemuxBlocker` requires HEVC). |
| VP9 | VLCKit software decode | Same as AV1 for 4K and HDR. |
| Interlaced MPEG-2, VC-1, H.264 (DVD rips, 1080i broadcasts, OTA Live TV) | VLCKit | No deinterlace option is set anywhere in the source, so behavior is libvlc's default. I did not verify what that default is on tvOS. Test with a 1080i sample. |
| HEVC or H.264 4:2:2 and 4:4:4 in MP4 (camera footage) | Sent to AVPlayer | The resolver checks only bit depth for H.264 and nothing for HEVC (`StreamResolver.swift:601-622`). These profiles fail on Apple's hardware decoders, and the fallback is a server stream, not VLCKit. |
| Dolby TrueHD | Stock VLCKit: Plex converts. Local build: decoded to 7.1 PCM. | Licensing, see R2. No App Store player can pass TrueHD or DTS:X objects to a receiver, so Atmos from TrueHD is out of reach for everyone. |
| DTS, DTS-HD MA | VLCKit decodes to PCM | Fine, apart from the HDR trade-off above. |
| Styled ASS subtitles inside a remux | Not allowed; routes to VLCKit | Covered by the subtitle renderer in feature 1. |
| VVC (H.266) | Not supported by VLC 3 | Rare. Ignore for now. |
| Music and photo libraries | Filtered out | Out of scope by design. |

Cheapest wins, in order:

1. A "prefer HDR picture" choice when the audio cannot be copied. The remux path already converts audio for DV7 with TrueHD; extend that to DTS and PCM.
2. Test whether Plex will convert DTS-HD and TrueHD to FLAC inside the fMP4 remux. If AVPlayer accepts it, HDR picture and lossless audio stop being a trade-off. Untested idea, needs a one-day spike.
3. Start AV1 and VP9 above 1080p on the server-transcode rung when the device has no hardware decoder.
4. Route 4:2:2 and 4:4:4 video to VLCKit in `StreamResolver.videoDecision`.
5. Set libvlc's deinterlace option explicitly for interlaced streams.

## Three features worth building

**1. Full-quality playback with no trade-off.** HDR and Dolby Vision stay on whatever subtitle or audio track is selected. This is what people pay Infuse for. Ithaca is most of the way there for E-AC-3 files and falls back to SDR for the rest. The work is a subtitle renderer for the AVPlayer path (PGS and VobSub bitmaps, ASS through libass, drawn in a layer above the video and synced to the player clock) plus the audio choices listed under codecs. Effort: several weeks for subtitles, days for the audio options. The longer route is one pipeline that replaces both engines (FFmpeg demux, VideoToolbox decode, sample-buffer display and audio renderers), which is how Infuse-class players are built and is months of work.

**2. Jellyfin and Emby servers.** Every paid competitor lists them and the upstream project only plans them. It widens the audience to the people leaving Plex over the 2025 and 2026 price and remote-streaming changes, and it is the only real protection if Plex restricts third-party clients. The multi-server pool, `PlexItemID` and `PlexContentKey` are a workable base, since a Jellyfin server could be one more entry in the pool. The cost is high: models, auth, playback decisions, watch state and images are Plex-specific by design, and `docs/product-and-scope.md` lists this as a non-goal today.

**3. Describe It for everyone.** Natural-language picks and search across the library with no server to set up. The feature exists (Pick Something, Mentor, taste ratings, who is watching, Seerr suggestions) but needs a self-hosted Mentor and an API key. A hosted relay turns it into a product feature that no competitor's listing mentions, and because each request costs money it is the natural thing to charge a subscription for. Keep self-hosted Mentor as the free and private option, make the hosted one opt-in, and extend it from picking to search ("the heist film with the spinning top"). Effort: small on the app side, plus running a small metered service.

Smaller ideas that came up: Trakt sync, mapping tvOS user profiles to Plex Home users so the app opens as whoever holds the remote, DVR scheduling, and native Mac and Vision Pro targets.

## Market and pricing

**Is there a market?** Yes, but it filled up in the last twelve months.

Demand side:
- Plex raised the Lifetime Plex Pass from $249.99 to $749.99 on 2026-07-01, with monthly at $6.99 and yearly at $69.99.
- Remote streaming now needs a Plex Pass or Remote Watch Pass, and since late September 2026 that applies to third-party clients too (Firecore notice, 2026-09-21). Local playback is unaffected.
- Plex has acknowledged repeated criticism of its redesigned TV apps and restored the sidebar on Apple TV (ifun.de, 2026-08-20).
- Infuse, the paid leader, has 29K US ratings at 4.7.

Supply side, App Store prices fetched 2026-11-04:

| App | Servers | Price |
|---|---|---|
| Infuse | Plex, Jellyfin, Emby, NAS, cloud | $1.99 monthly, $16.99 yearly, $99.99 lifetime |
| VidHub | Plex, Jellyfin, Emby, NAS, cloud | about $9.99 yearly, lifetime $14.99 to $39.99 (listings conflict) |
| SenPlayer | Plex, Jellyfin, Emby | lifetime $9.99 per platform, $12.99 for all |
| Plezy | Plex, Jellyfin, Emby | $5.99 once |
| Strimr | Plex, Jellyfin | free |
| Dusk for Plex | Plex | free, optional tips |
| Jellyfin-only clients | Jellyfin | free to $9.99, lifetime up to $39.99 |

Dusk matters most. It is the project Ithaca derives from, it is on the App Store for free, and its README lists most of the same playback features. Its repository is MIT today (I checked), so Ithaca's derivation and a closed commercial release are both permitted. I did not diff Ithaca against current Dusk, so I cannot say exactly what Ithaca adds beyond what this repo shows: Pick Something and Describe It, taste recommendations from ratings, the cross-server merge, Top Shelf and the Siri intents.

**What could you charge?**

- As it stands, Plex-only with free direct rivals: free to download with a one-time unlock of $7.99 to $9.99 covering iPhone, iPad and Apple TV. Plezy at $5.99 and SenPlayer at $9.99 to $12.99 set the range. A subscription would not hold against Dusk and Strimr at zero.
- With feature 1 and feature 2 shipped: $1.99 monthly, $14.99 yearly, $49.99 to $59.99 lifetime, priced just under Infuse.
- Hosted Describe It has to be a subscription whatever else you do, because it has a per-request cost.

Apple takes 15% under the Small Business Program, so a $9.99 sale nets about $8.49.

**How much is that?** Nobody publishes sales for these apps, so this is a rough estimate. Plezy has 124 US ratings about a year after launch. If 1% to 3% of buyers leave a rating, which is an assumption, that is roughly 4,000 to 12,000 US sales, or $20K to $60K after Apple's cut at $5.99. Dusk and Strimr have 6 and 7 ratings. A realistic first year for Ithaca at $9.99 is somewhere between a few hundred and a few thousand sales. That is side income. It becomes more than that only if Ithaca is visibly better than Infuse at something people can see in a screenshot or a first play.

**Risks specific to selling it:**

- Plex has no public client API and no published policy protecting third-party clients. I found no case of Plex taking down a client app, but the remote-streaming rule shows it will change terms for them. Plex's trademark page bars app names that start with "Plex"; "Ithaca" is fine. I could not read the page first-hand (it returned 403).
- Dolby and DTS: ship stock VLCKit (R2), and use "Dolby Vision" and "Dolby Atmos" as plain format names without logos. Infuse lists Dolby and DTS as separate free in-app purchases, which users take to be for license counting; Firecore has not confirmed why.
- VLCKit is LGPL. Dynamic linking is already done. A release also needs the license notice in the app and a way for users to obtain the VLCKit source and build you shipped.
- A playback app brings a long tail of "this file will not play" support, and you would be the only one answering.

## Remaining risk

What this audit could not rule out:

- Anything that only shows on a device: the VLCKit picture freeze from 2026-11-02 was not reproduced, and no log from it exists.
- Behavior inside VLCKit and libdovi. A crafted media file that exploits ffmpeg or libvlc is outside what this repo controls, other than by staying on current VLCKit releases.
- The SwiftUI layer, Seerr feature logic and Siri matching were not reviewed.
- Legal questions (Dolby, DTS, HEVC pools, Plex's terms) are flagged from public sources, not legal advice.

## Sources

Checked by me on 2026-11-04:
- Infuse App Store listing: https://apps.apple.com/us/app/infuse/id1136220934
- Firecore, changes to Plex remote streaming, 2026-09-21: https://community.firecore.com/t/changes-to-plex-remote-streaming-requirements/60825
- Plex, new Lifetime Plex Pass pricing: https://www.plex.tv/blog/new-lifetime-plex-pass-pricing/
- 9to5Mac on the lifetime price, 2026-05-19: https://9to5mac.com/2026/05/19/plex-increasing-lifetime-plex-pass-cost-to-whopping-750/
- Dusk repository and license: https://github.com/marvinvr/dusk-player

Collected by the research agent, not re-checked by me:
- Dusk App Store listing: https://apps.apple.com/us/app/id6760492635
- Plezy: https://apps.apple.com/us/app/id6754315964
- Strimr: https://apps.apple.com/app/id6757491271
- SenPlayer: https://apps.apple.com/us/app/senplayer-hdr-media-player/id6443975850
- VidHub: https://apps.apple.com/us/app/id1659622164
- tvOS client price list, 2026-07-09: https://perfectmediaserver.com/jellyfinjune/clients/tvos/
- Plex forum, remote streaming changes, 2025-11-19: https://forums.plex.tv/t/changes-coming-to-remote-streaming-on-roku/933671
- ifun.de on the sidebar returning, 2026-08-20: https://www.ifun.de/plex-navigation-per-seitenleiste-kehrt-auf-apple-tv-zurueck-286187/
- Plex forum, Apple TV app issues, 2026-09-24: https://forums.plex.tv/t/multiple-user-experience-issues-with-new-apple-tv-app/943306
- Apple Small Business Program: https://developer.apple.com/app-store/small-business-program/
