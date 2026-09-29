# wtv.lua — W.tv playlist parser for VLC

A VLC playlist script that opens [W.tv](https://w.tv) live channels and recorded streams (VODs) directly in VLC.

W.tv streams through **Amazon IVS** (Interactive Video Service). The script resolves a W.tv page URL to the IVS HLS playback URL and hands it to VLC's `adaptive` demuxer.

## Features

- Plays live channels and VODs anonymously. No login, cookies or tokens are needed.
- Sends W.tv API requests through the system `curl` with browser-like headers. The API sits behind a WAF that returns `403` to VLC's own HTTP client.
- Fills in VLC metadata: *Title*, *Artist* (channel), *Description*, *Date*, *Now Playing* and artwork (the stream thumbnail).
- Prints clear errors to the VLC log for a missing channel, an offline stream, or an unknown video.
- Starts on the source rendition right away (`adaptive-logic=highest`), so there is no ramp-up from 160p and no demuxer restart after the stream starts.
- Runs on Windows, Linux and macOS.

## Supported URLs

| URL | Result |
|---|---|
| `https://w.tv/<nickname>` | Live stream |
| `https://w.tv/<nickname>/videos/<streamId>` | Recorded stream (VOD) |

Nicknames are case-insensitive.

## Requirements

- VLC 3.0.x.
- `curl` available on `PATH`.

| OS | curl |
|---|---|
| Windows 10 1803+ / 11 | Built in (`C:\Windows\System32\curl.exe`) |
| macOS | Built in (`/usr/bin/curl`) |
| Linux | Usually preinstalled. If missing, run `sudo apt install curl` or the equivalent for your distro |
| Linux (Flatpak / Snap) | VLC uses the curl from its sandbox runtime, which may not include one |

## Installation

Copy `wtv.lua` into your user playlist-scripts directory, creating the directory if needed:

| OS | Path |
|---|---|
| Windows | `%APPDATA%\vlc\lua\playlist\` |
| Linux | `~/.local/share/vlc/lua/playlist/` |
| Linux (Flatpak) | `~/.var/app/org.videolan.VLC/data/vlc/lua/playlist/` |
| Linux (Snap) | `~/snap/vlc/current/.local/share/vlc/lua/playlist/` |
| macOS | `~/Library/Application Support/org.videolan.vlc/lua/playlist/` |

Restart VLC after installing.

## Usage

- **GUI:** open *Media → Open Network Stream* (`Ctrl+N`) and paste a channel or video URL.
- **CLI:**
  ```sh
  vlc https://w.tv/<nickname>
  vlc https://w.tv/<nickname>/videos/<streamId>
  ```

## How it works

```
w.tv/<nick>
  └─ GET profiles-service.w.tv/api/v1/profiles/by-nickname/<nick>        → userId
       ├─ live: GET streams-search-service.w.tv/api/v1/channels/<userId>
       │         → liveStream.playbackUrl
       │           https://<acc>.<region>.playback.live-video.net/api/video/v1/<region>.<acc>.channel.<id>.m3u8
       └─ VOD:  GET streams-search-service.w.tv/api/v1/channels/<userId>/streams
                 → data[streamId].playbackUrl
                   https://streams.w.tv/ivs/v1/<acc>/<channel>/<yyyy>/<m>/<d>/<h>/<min>/<rec>/media/hls/master.m3u8
```

Each API call runs `curl` with a browser `User-Agent`, `Origin: https://w.tv`, `Referer: https://w.tv/` and a random `x-device-id`, the same headers the web client sends. The IVS playlists and segments themselves are fetched by VLC directly.

Live streams play from the IVS edge (`*.playback.live-video.net`). VODs are IVS auto-recordings in S3, served through `streams.w.tv`.

## IVS renditions

This is the master playlist for a typical live channel. The values come from a captured session:

| Rendition | Resolution | Bitrate | Codec |
|---|---|---|---|
| `chunked` (source) | 1920×1080 @ 60 | ~6.9 Mbit/s | H.264 High + AAC |
| `720p60` | 1280×720 @ 60 | ~3.4 Mbit/s | H.264 Main + AAC |
| `480p30` | 852×480 @ 30 | ~1.4 Mbit/s | H.264 Main + AAC |
| `360p30` | 640×360 @ 30 | ~0.6 Mbit/s | H.264 Main + AAC |
| `160p30` | 284×160 @ 30 | ~0.2 Mbit/s | H.264 Main + AAC |

- Segments are 2 s long, and `EXT-X-TARGETDURATION` is 6.
- There is no audio-only rendition.
- The rendition list depends on the streamer's IVS channel type. Channels without transcoding expose the source rendition only.

## Configuration

Playback options are set in the `OPTIONS` table at the top of the script:

```lua
local OPTIONS = {
    ":adaptive-logic=highest",
    ":http-referrer=https://w.tv/",
}
```

### VLC options

| Option | Values | Purpose |
|---|---|---|
| `:adaptive-logic=` | `highest` (default), `nearoptimal`, `predictive`, `rate`, `fixedrate`, `lowest` | Rendition selection strategy |
| `:adaptive-maxheight=` | e.g. `720` | Height cap. Combine it with `highest` to get the best rendition up to that height |
| `:adaptive-maxwidth=` | e.g. `1280` | Width cap |
| `:adaptive-bw=` | kbit/s | Fixed bandwidth for `fixedrate` |
| `:adaptive-livedelay=` | ms (default `15000`) | Distance from the live edge. Do not go below about `12000`: IVS uses `EXT-X-TARGETDURATION:6`, VLC 3 refreshes the live playlist only every 6 s, and a shorter delay drains the buffer, causing freezes and `PCR is called too late`. Has no effect on VODs |
| `:adaptive-maxbuffer=` | ms (default `30000`) | Maximum buffer size |
| `:http-referrer=` | `https://w.tv/` (default) | Sends the same `Referer` as the web player. This matters if the channel has an IVS playback restriction policy |

These options apply only to items this script creates. Global VLC settings are not changed.

### IVS playback URL parameters

The W.tv web player appends these query parameters to `playbackUrl`:

| Parameter | Example | Effect |
|---|---|---|
| `supported_codecs` | `av1,h265,h264` | Lets IVS offer HEVC or AV1 renditions (multi-codec / enhanced broadcasting) |
| `player_backend` | `mediaplayer` | Telemetry |
| `player_version` | `1.53.0` | Telemetry |
| `platform` | `web` | Telemetry |
| `browser_family`, `browser_version` | `chrome`, `153.0` | Telemetry |
| `os_name`, `os_version` | `Windows`, `NT 10.0` | Telemetry |
| `cdm` | `wv` | DRM capability hint (Widevine). Not used for public streams |
| `token` | JWT | IVS playback authorization for private channels. Public W.tv channels do not use it |

The script sends none of these parameters, so playback stays on the widely compatible H.264 renditions. To experiment with HEVC or AV1, append `?supported_codecs=h265,h264` to `stream.playbackUrl` in `make_item()`.

## Troubleshooting

Open *Tools → Messages* in VLC, or run `vlc -vv`, and look for lines starting with `W.tv:`.

| Log message | Meaning / fix |
|---|---|
| `channel not found: <nick>` | The nickname is misspelled, or the profile does not exist |
| `<name> is offline` | The channel is not live right now |
| `video not found: <id>` | The video is not in the channel's recent streams list. See the limitations below |
| `video <id> has no recording` | The stream exists, but no recording is available |
| `curl: (22) The requested URL returned error: 403 [<url>]` | The WAF rejected the request. W.tv may have tightened its bot rules. Please report this and attach the log |
| `curl: not found` / `empty response (is curl installed?)` | `curl` is not on `PATH`. Install it |
| `curl: (28) ...` | Timeout. Check your network |

## Known limitations

- **WAF on the API.** The W.tv API returns `403` to VLC's built-in HTTP client, which is why the script goes through `curl`. If W.tv enables stricter bot detection (for example TLS fingerprinting), `curl` may be blocked as well.
- **Console flash on Windows.** `io.popen` starts `cmd.exe`, so a console window flashes briefly for each API call (two per open).
- **AWS WAF on the page.** The first request to the `w.tv/<nick>` page may return `202` with a WAF challenge. VLC accepts any 2xx response, so this does not affect the script. The API subdomains had no challenge in the captured session.
- **Recent VODs only.** VOD lookup uses the channel's streams list, which covered about one month (29 entries) in the captured session. Links to older recordings may not resolve.
- **No chat.** The script handles video only. W.tv chat runs over IVS Chat WebSocket, which is outside the scope of a playlist script.

## License

GNU General Public License v2.0 or later.