# SpotiTinder

Swipe through a Spotify playlist Tinder-style:

- **Right:** keep
- **Left:** remove
- **Up:** add or move to another playlist

Nothing changes on Spotify until you tap **Apply** on the Review screen.

## Install on your iPhone (free Apple ID)
1. Open `SpotiTinder.xcodeproj` in Xcode. The Spotify SDK package resolves automatically.
2. Select the **SpotiTinder** target and open **Signing & Capabilities**.
   - Set **Team** to your Personal Team. Add your Apple ID under Xcode ▸ Settings ▸ Accounts if it's not listed.
   - If Xcode says the bundle ID is taken, change it, for example to `com.dustin.SpotiTinder2`. Then update the iOS bundle ID in the Spotify dashboard to match.
3. Plug in your iPhone, select it as the run destination, and press ⌘R.
   - The first time, enable **Developer Mode** on the phone: Settings ▸ Privacy & Security.
   - Trust your developer certificate: Settings ▸ General ▸ VPN & Device Management.
4. With a free account the app stops launching after 7 days. Press ⌘R again to reinstall. Your swipes are kept as long as you don't delete the app.

## Install with AltStore (auto-refresh)
You need AltStore Classic 2.3 or newer, which requires iOS 17.4+. Since 2.3, its **Remote AltServer** installs and refreshes apps over any Wi-Fi, so your Mac no longer has to be running.

1. Install **AltStore Classic** on your iPhone, following the guide at altstore.io. The first install may still need AltServer on your Mac, once.
2. In AltStore, open Settings and tap **Set up Remote AltServer**. From then on, refreshing works without a computer.
3. Build the app file: `scripts/build-ipa.sh`. This creates `dist/SpotiTinder.ipa`.
4. Move the `.ipa` to your iPhone, for example with AirDrop to Files. In AltStore, go to **My Apps ▸ +** and pick it.

AltStore renews the 7-day signature for you. To update the app, run the script again and install the new `.ipa` the same way.

Apple's limits for free Apple IDs still apply:
- 3 sideloaded apps at once, and AltStore counts as one.
- 10 new app IDs per week.

## Spotify dashboard
- Redirect URI: `spotitinder://callback`
- iOS bundle ID: `com.dustin.SpotiTinder`
- APIs: Web API and iOS SDK
- Your account must be listed under **User Management** (development mode).

The app uses PKCE, so only the client ID is in the code (`SpotiTinder/Config.swift`). `token.json` with the client secret is not used and is git-ignored.

## How it works
**Loading**
- The playlist is downloaded once, about 14 requests of 100 songs, and cached on the phone (SwiftData).
- It's only downloaded again when Spotify's `snapshot_id` changes.
- Pull to refresh forces a reload.

**Playback**
1. Songs always play through the Spotify app on your phone (App Remote).
2. If Spotify isn't running, the app briefly switches to Spotify to start it, then comes back. This happens once per session.
3. Only without the Spotify app installed (for example in the simulator) does it fall back to the Web API on whichever device is active.

Songs start at 30% by default; you can change this in Options. Playback requires Premium.

**Review & Apply**
1. Adds and moves go to their target playlists first.
2. Then removals happen in the source playlist.
3. Everything runs in batches of 100. Each finished batch is saved, so if a run fails partway, tapping Apply again continues where it stopped.

**Liked Songs**
- Liked Songs appears at the top of the playlist list.
- Removing a song from it un-likes the song on Spotify.

**Duplicates** (playlist screen ▸ Duplicates)
- **Same song, different release:** single vs. album version, remasters, deluxe editions, "feat." credits, soundtrack versions. Songs are matched by artist + title with version info ignored. Live, acoustic, remix and demo versions count as different songs.
  - Each group lists every version with album, year, date added and length, plus a play button.
  - The oldest added version is picked by default; tap another to keep that one instead. **Remove the other** marks the rest for removal, and they're applied in Review like left swipes.
  - **Not duplicates** hides a group (⋯ ▸ Show hidden groups brings it back). **Keep the oldest of all** handles every group at once.
- **Exact copies** (the identical Spotify track added twice, playlists only): **Remove extra copies** keeps each song once at its first position and changes Spotify right away. Spotify then shows today as the song's "date added", but the app keeps the original date. If it's interrupted, **Finish removing extra copies** puts every song back.
- In the deck, exact copies show a "Duplicate ×N" badge. Removing one there deletes every copy (Spotify removes by URI).

**Artist groups**
- When the current card's artist has more songs left, a bar shows "Artist · N songs left" with **Decide all**: keep, remove, or add/move all of them at once. One undo reverts the whole batch.
- Options ▸ Order ▸ **Grouped by artist** sorts the deck so artists with the most songs come first.

**Starting over**
- **Start over…** (playlist screen ⋯ menu, deck Options menu, or "Start a new round" when the deck is done) brings every song back into the deck for a new round.
- Unapplied changes are discarded. Songs already removed on Spotify stay removed.

**Backup**
- On the Review screen you can export a JSON file of the track list.
- You can also copy the whole playlist to a private backup playlist.

## Suggested first run
Duplicate a small playlist of about 30 songs in Spotify. Swipe it and apply, then check the result in Spotify. After that, do the same with the big one.
