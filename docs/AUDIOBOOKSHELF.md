# Audiobookshelf Integration Guide

This guide explains how to connect the Audiobook Read-Along plugin to an [Audiobookshelf](https://www.audiobookshelf.org/) (ABS) server. Once connected, you can browse your ABS libraries, download audiobooks to your e-reader, and sync playback progress across devices.

**What this integration gives you**

- Browse your ABS libraries directly on your e-reader
- Download audiobooks for offline playback
- Resume on your e-reader exactly where you left off on your phone (and vice versa)
- Automatic background progress sync every 60 seconds while connected

**What stays the same**

- Playback uses the same engine, UI, and Bluetooth path as local audio files
- Sleep timer, chapter navigation, speed control, and scrubber seek all work unchanged
- TTS read-along is completely unaffected

---

## Table of Contents

- [Requirements](#requirements)
- [Audiobookshelf Server Setup](#audiobookshelf-server-setup)
- [Plugin Setup](#plugin-setup)
- [Using the Integration](#using-the-integration)
- [How Progress Sync Works](#how-progress-sync-works)
- [Cache Management](#cache-management)
- [Troubleshooting](#troubleshooting)

---

## Requirements

### On the server side

- An Audiobookshelf server (v2.0 or later) reachable from your e-reader's network
- At least one library with audiobook items
- A user account with access to that library

### On the e-reader side

- The Audiobook Read-Along plugin (v0.1.10.0 or later)
- WiFi connection during browse, download, and sync operations
- Sufficient free storage

### Network requirements

Your e-reader must be able to reach the ABS server over HTTP or HTTPS. This usually means:

- Both devices on the same local network (home WiFi), **or**
- The ABS server exposed through a reverse proxy with a public domain, **or**
- A VPN running on the e-reader that puts it on the same network as the server

> **Note:** KOReader does not handle self-signed HTTPS certificates gracefully. If your ABS server uses HTTPS with a self-signed cert, consider using HTTP on the local network instead, or ensure the certificate is trusted by the system CA store.

---

## Audiobookshelf Server Setup

You only need to do this once. If you already have an ABS server running, skip to [Plugin Setup](#plugin-setup).

### 1. Install Audiobookshelf

Follow the [official installation guide](https://www.audiobookshelf.org/docs/). The Docker method is the most common:

```bash
docker run -d \
  -p 13378:80 \
  -v /path/to/audiobooks:/audiobooks \
  -v /path/to/config:/config \
  -v /path/to/metadata:/metadata \
  --name audiobookshelf \
  ghcr.io/advplyr/audiobookshelf
```

### 2. Create a library and scan your collection

1. Open the ABS web UI (e.g. `http://your-server:13378`)
2. Create a library and point it at your audiobook folder
3. Run a library scan so ABS extracts metadata, chapters, and cover art

### 3. Create a user account for your e-reader

1. Go to **Settings > Users**
2. Create a user (or use the existing admin account)
3. Grant the user access to your audiobook library

### 4. Note your server URL

Your e-reader needs the full URL to reach the ABS server. Examples:

| Scenario | URL |
|----------|-----|
| Same local network | `http://192.168.1.100:13378` |
| Reverse proxy (local) | `http://abs.local` |
| Reverse proxy (public) | `https://abs.yourdomain.com` |

> **Important:** Include the port if ABS is not running on the standard HTTP (80) or HTTPS (443) ports. The plugin does not guess ports.
>
> **Do not use `localhost` or `127.0.0.1`**. These always refer to the e-reader itself, not your laptop or server. Use the server's actual LAN IP address (e.g. `192.168.1.32`).

---

## Plugin Setup

All configuration is done through the KOReader menu. No file editing required.

### 1. Open the Audiobookshelf menu

**Tools > Audiobook Read-Along > Audiobookshelf**

### 2. Configure the server URL

Tap **Server: not configured** and enter your ABS server URL.

```
http://192.168.1.100:13378
```

Tap **Save**. The menu will update to show the URL.

### 3. Log in

Tap **Log in...** and enter the username and password for the ABS account you created earlier.

If login succeeds, the menu updates to show **(connected)** next to the server URL, and new options appear:

- **Browse libraries...**
- **Downloaded items**
- **Continue listening**
- **Sync progress now**

If login fails, check:
- The server URL is correct and includes the port
- The ABS server is running and reachable
- The username and password are correct
- Your e-reader is connected to WiFi

---

## Using the Integration

### Browse and download

1. Tap **Browse libraries...**
2. Select a library
3. Tap an item to open its detail page
4. Tap **Download** to download the audiobook

The download dialog shows progress. Files are saved to:

```
plugins/audiobook.koplugin/abs_cache/{item_id}/audio/
```

After download completes, the item appears in **Downloaded items** and shows a checkmark in the library list.

> **Note:** Download requires WiFi. On e-readers with slow WiFi, a multi-file audiobook may take several minutes. The download runs in the background; you can use KOReader normally while it progresses.

### Play a downloaded audiobook

There are three ways to start playback:

| Method | Path |
|--------|------|
| From the library list | Browse libraries > tap item > **Play** |
| From downloaded items | **Downloaded items** > tap item |
| Quick resume | **Continue listening** (resumes the most recently played ABS item) |

Playback uses the same full-screen player as local audio files, with scrubber seek, chapter navigation, speed control, and sleep timer.

### Resume from another device

When you start playback, the plugin checks both your local saved position and the ABS server. If the server has a newer position (from your phone, for example), it offers to resume from that point.

```
Resume from 2:34:15?

Last played: 2026-06-01 14:32
[Resume] [From start]
```

### Playback controls during ABS playback

All existing playback controls work identically:

| Control | Action |
|---------|--------|
| Scrubber drag | Seek to any position |
| 30s skip back/forward | Jump relative to current position |
| Chapter buttons | Previous / next chapter |
| Speed button | Cycle through 0.8x, 1.0x, 1.25x, 1.5x, 2.0x |
| Minimize | Collapse to a bottom bar; keep reading while listening |

### Chapters

If the audiobook file contains chapter metadata, the plugin extracts it automatically. If not, it falls back to the chapter list from ABS. Tap the chapter list button (top-left of the player) to jump to any chapter.

---

## How Progress Sync Works

Progress sync is automatic and bi-directional.

### What gets synced

- Current playback position (in seconds)
- Total duration
- Finished status

### When sync happens

| Event | Action |
|-------|--------|
| Every 60 seconds during playback | Record position locally, flush to ABS if connected |
| Pause or stop | Record position locally, flush to ABS immediately |
| Before resume | Fetch remote position, compare with local, use whichever is newer |
| Manual tap on **Sync progress now** | Full two-way sync of all downloaded items |

### The sync journal

The plugin maintains a local sync journal at:

```
plugins/audiobook.koplugin/abs_sync_journal.json
```

This ensures progress is never lost, even if:
- The ABS server is temporarily unreachable
- WiFi drops during playback
- The device crashes or loses power

When the server becomes reachable again, all pending updates are sent in a single batch request.

### Conflict resolution

If both local and remote positions exist, the plugin compares timestamps and uses whichever is newer. This means:

- If you listen on your phone and then open the e-reader, you resume from the phone's position
- If you listen on the e-reader offline and then reconnect, the e-reader's position is pushed to the server

---

## Cache Management

### Storage location

Downloaded audiobooks are stored in:

```
plugins/audiobook.koplugin/abs_cache/
```

Each item gets its own folder:

```
abs_cache/
  index.json              # Cache index (metadata, file paths)
  {item_id}/
    audio/
      01.mp3
      02.mp3
      ...
    cover.jpg
```

### Cache size

The plugin shows the current cache size in the Audiobookshelf menu. To free space:

1. Browse to the item in **Downloaded items**
2. Tap the item
3. Tap **Delete from device**

This removes the audio files, cover art, and index entry.

### Cache eviction (automatic)

The cache manager includes an `evictToSize()` method that removes oldest items first to stay under a limit. This is not enabled by default; future releases may add a user-configurable cache size limit.

---

## Troubleshooting

### "No route to host"

You entered `localhost` or `127.0.0.1` as the server URL. These addresses always refer to the e-reader itself, not your laptop. You must use the server's actual LAN IP address.

**To find the correct IP:**

On the machine running ABS:

- **Linux/macOS:** run `ip addr` or `ifconfig` and look for your WiFi interface (e.g. `wlp0s20f3` or `wlan0`)
- **Windows:** run `ipconfig` and look for "Wireless LAN adapter"

The IP will look like `192.168.1.32` or `10.0.0.15`. Enter `http://<that-ip>:13378` in the plugin.

### "No Audiobookshelf server configured"

Enter the server URL in **Tools > Audiobook Read-Along > Audiobookshelf > Server settings**.

### "Authentication failed. Please log in again."

The stored token expired or was invalidated. Tap **Log out**, then **Log in...** again.

### "Failed to load libraries"

Common causes:

| Cause | Fix |
|-------|-----|
| Wrong URL or port | Double-check the server URL includes the port (e.g. `:13378`) |
| Server not reachable | Ensure both devices are on the same network or VPN |
| HTTPS certificate issue | Try HTTP instead, or use a trusted certificate |
| Firewall blocking port | Open the port on your server/router |

### "Download failed"

- Check that WiFi is stable
- For large audiobooks, ensure the e-reader has enough free space
- The download will retry automatically if the network recovers

### Progress not syncing

- Verify WiFi is on and the server is reachable
- Tap **Sync progress now** to force a manual sync
- Check the ABS web UI to see if progress appears there
- If the e-reader was offline for a long session, the sync journal may have many entries; the flush may take a moment

### "Audiobookshelf modules not available"

This means `absbrowse.lua` failed to load. Check that:
- The plugin was installed correctly (all `.lua` files are present)
- KOReader was restarted after installation

### Resume position is wrong

This can happen if:
- Two devices played the same book simultaneously (last-write-wins)
- The local position was saved but not yet synced when you switched devices

To fix: manually seek to the correct position. The next sync cycle will push the corrected position.

### Cover art not showing

- ABS may not have extracted a cover for this item. Check the ABS web UI.
- The cover download may have failed. Re-download the item.

---

## Technical Notes

### API compatibility

The plugin uses the following ABS API endpoints:

| Endpoint | Purpose |
|----------|---------|
| `POST /login` | Authentication |
| `GET /api/libraries` | List libraries |
| `GET /api/libraries/{id}/items` | List items in a library |
| `GET /api/items/{id}` | Item details (chapters, audio files, cover) |
| `GET /api/items/{id}/cover` | Cover image |
| `GET /api/me/progress/{id}` | Fetch remote progress |
| `POST /api/me/progress` | Update progress |
| `POST /api/me/progress/batch` | Batch update progress |

### Settings stored by the plugin

All ABS settings are stored in KOReader's settings under the `audiobook_settings` key:

| Setting | Description |
|---------|-------------|
| `abs_server_url` | ABS server URL |
| `abs_api_token` | Authentication token |
| `abs_user_id` | ABS user ID |
| `abs_last_item_id` | Most recently played ABS item |
| `abs_last_library_id` | Last browsed library |

These can be cleared by going to **KOReader settings > Plugins > Audiobook Read-Along > Delete plugin settings**.

### Offline behavior

Once an audiobook is downloaded, it plays entirely offline. The plugin only needs network access for:
- Browsing libraries
- Downloading new items
- Syncing progress

If WiFi is off during playback, progress is recorded locally and synced the next time WiFi is available.
