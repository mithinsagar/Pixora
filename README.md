# Pixora

A native macOS app for photographers. Point it at an SD card, a drive or a folder. It finds the faces, groups
them by person and remembers the names you give. You can then pick **two or more people** and get the photos
where they all appear together (or where any of them appears), copy them safely into a folder, hide some in an
encrypted **Private Space**, or play them as a slideshow.

Everything runs on your Mac. No account, and no photo, face or name leaves it. The only part that uses the internet is the optional map in Places, which stays off until you turn it on.

**Made by Mithin Sagar** · [mithinsagarofficial@gmail.com](mailto:mithinsagarofficial@gmail.com)

## Download and install

1. Download the **Pixora .dmg** from the [latest release](../../releases/latest).
2. Open it and drag **Pixora** onto **Applications**.
3. The first time, macOS will say it can’t check Pixora for malicious software, because the app isn’t notarised
   by Apple (that needs a paid developer account). Open **System Settings → Privacy & Security**, scroll down and
   click **Open Anyway** next to the Pixora message, then confirm. You only do this once.

Requirements: macOS 14 Sonoma or later on a Mac with Apple silicon (M1 or later). The face models are included in the
download (about 100 MB), so recognition works straight away.

## Build and run

Requirements: macOS 14 or later, Xcode 16 or later (tested with Xcode 27.2 / Swift 6.4 on macOS 27.0.1, Apple M5),
and Homebrew Python 3.12, used once to make the face model.

```sh
# 1. One-time: build the on-device face models (≈100 MB)
/opt/homebrew/bin/python3.12 -m venv tools/.venv
tools/.venv/bin/pip install torch==2.7.0 torchvision==0.22.0 coremltools==9.0 numpy==2.2.6 scipy==1.18.1 pillow onnx onnx2torch onnxruntime
curl -LO https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_l.zip && unzip buffalo_l.zip -d buffalo_l
tools/.venv/bin/python tools/convert_scrfd.py   buffalo_l/det_10g.onnx      # → Models/SCRFD10G.mlpackage
tools/.venv/bin/python tools/convert_arcface.py buffalo_l/w600k_r50.onnx    # → Models/ArcFaceR50.mlpackage

# 2. Build the app bundle (release build, models compiled in, icon). The first build creates a local
#    self-signed signing identity in .signing/ (see scripts/make_signing_identity.sh) so macOS treats every
#    rebuild as the same app and doesn't keep asking for the keychain password.
./scripts/build_app.sh
open build/Pixora.app

# 3. Optional: package a disk image for others
./scripts/make_dmg.sh            # → build/Pixora-<version>.dmg

# Tests and the accuracy harness
swift test
swift build -c release --product pixora-eval
.build/release/pixora-eval <folder-of-person-folders> --cache /tmp/emb.json   # verification / assignment / grouping
.build/release/pixora-eval --pairs <cplfw/people> <pairs.csv>                  # official pair list
.build/release/pixora-eval --count <photo folder> 30                           # detector face counts per folder
```

The pinned versions matter: coremltools 9.0 fails with torch ≥ 2.8 and with NumPy ≥ 2.3. Without the model, the
app still runs in a clearly labelled **Basic** mode, but Basic mode cannot reliably recognise people (numbers below).

Pixora keeps its library in `~/Library/Application Support/Pixora`. Setting `PIXORA_HOME=/some/folder` points
it at a separate library, which is useful for trying it out without touching your real one.

## How it works

| Step | What happens | Where |
|---|---|---|
| Import | Cards and drives are detected as they mount (`NSWorkspace`), and you can also choose any folder. Hidden files, packages (e.g. `.photoslibrary`) and videos are skipped. RAW+JPEG pairs become **one** photo: the JPEG is analysed and the RAW travels with it on export. | `Scanning.swift` |
| Preview | Photo count, size, formats, RAW pairs, files macOS can't decode, free space, and per-folder checkboxes. Unchanged files that are already scanned are counted and skipped. | `ScanSheet` |
| Scan | ImageIO decodes each photo at ≤2400 px with orientation applied, which also works for the RAW formats macOS supports. SCRFD (plus Apple Vision) finds faces and 5 landmarks, on the whole photo and on overlapping tiles. Each face is aligned and turned into a 512-number template by ArcFace on the Neural Engine. Side-on, blurry or tiny faces get a low quality score. 3 workers; pause, resume and cancel are supported (cancel keeps finished work). | `FacePipeline.swift` |
| Group | New faces are compared with every known person (score = mean of the 3 best similarities). Faces that match nobody are linked into groups. A group that isn't tight around its centre is split again at a stricter threshold. One person never appears twice in one photo. | `Matcher.swift` |
| Review | New groups to name, uncertain matches shown side by side (Y/N/→ keys), and unsorted single faces. Every answer is stored: "Not X" is remembered and never suggested again. | `ReviewView.swift` |
| Find | Pick people from the portrait strip or the search field, then switch between **All selected** and **Any selected**. Certain matches only by default; uncertain ones (dashed "?" ring) are included only if you turn them on, and a banner says how many are hidden. | `LibraryStore.search` |
| Export | Copy to any folder, never overwriting: files are written to a hidden temp file, checksum-verified and then renamed. A file identical to one already there is skipped as a duplicate; a different file with the same name becomes `name 2.jpg`. Presets: Originals, Originals + RAW, JPEG only, Resized for sharing. Folder layout: none, by person, by date, or by event (3 h gap). A summary lists copied files, duplicates and errors. | `Exporter.swift` |

Re-scanning a card never duplicates records. A source is recognised by volume UUID plus relative path, a file by
path, size and modification time, and the same photo imported from two places (same fingerprint) shows up once
in results. Offline sources are reconnected through a bookmark or volume UUID, or with **Locate…**, which checks a
sample of files before re-pointing.

### Face detection and recognition

- **Detection: InsightFace SCRFD-10G, with Apple Vision as a second opinion.** Every photo is scanned whole and
  in 4 overlapping tiles, so small faces in big group shots are found. Faces only Vision finds are added too.
  Dark photos get a brightened copy for analysis only; the original file is never changed.
- **Recognition: InsightFace ArcFace R50** (trained on WebFace600K). Each face is aligned with the standard 5-point
  similarity transform and turned into a 512-number template.
- **Licences:** InsightFace's code is MIT, but the pretrained `buffalo_l` models are released **for non-commercial
  research use only**. That is fine for personal use; check the terms before anything else.
- **Apple Vision can't recognise individuals:** it detects faces and landmarks only
  ([Apple: Vision](https://developer.apple.com/documentation/vision)).
- **Older FaceNet model:** still supported (`tools/convert_facenet.py`) but no longer the default. On real event
  photos it merged different people. Measured below.
- **Safety rules:**
  - Side-on, blurry, tiny or low-confidence faces never become automatic matches; they go to Review.
  - Once you confirm someone, new faces are compared only against faces you confirmed, so one wrong match can't
    snowball.

```sh
# Build the default models (≈100 MB). buffalo_l.zip from https://github.com/deepinsight/insightface/releases (v0.7)
tools/.venv/bin/pip install onnx onnx2torch onnxruntime
tools/.venv/bin/python tools/convert_scrfd.py   <buffalo_l>/det_10g.onnx     # parity: exact (fp32)
tools/.venv/bin/python tools/convert_arcface.py <buffalo_l>/w600k_r50.onnx   # parity: cosine 0.998 (fp16)
```

## Accuracy (measured, not estimated)

`pixora-eval` runs the app's own detection → alignment → recognition → matching code. Thresholds were tuned on
one part of [LFW](http://vis-www.cs.umass.edu/lfw/). All results below come from the **held-out part** (5,724
images, 3,832 people) and from [CPLFW](https://huggingface.co/datasets/marcelohaps/cplfw) (cross-pose).

| Held-out LFW, 72 known people | Old: Vision + FaceNet | **New: SCRFD + ArcFace** |
|---|---|---|
| Known person matched, certain and correct | 89.1% | **99.0%** |
| Known person matched, certain but wrong | 0.0% | **0.0%** |
| Stranger wrongly matched as certain | 0.4% | **0.0%** |
| First-import groups containing only one person | 98.6% | **100%** |
| Grouping pair precision / recall | 93.1% / 90.2% | **100% / 99.7%** |

| Harder conditions (held-out LFW, degraded copies) | Old | **New** |
|---|---|---|
| Low light (≈2.5 stops under + noise): strangers wrongly certain | 11.1% | **0.0%** |
| Low light: groups containing only one person | 83.9% | **100%** |
| Low light: images where no face was found | 48 | 112 |
| Blur: known person, certain and correct | 62.7% | **92.8%** |
| Low resolution (~30 px faces): certain and correct | 67.9% | **97.3%** |

| CPLFW official 6,000 pairs (side-on faces, look-alike negatives) | Old | **New** |
|---|---|---|
| Accuracy (detection failures counted as errors) | 81.3% | **95.4%** |
| Pairs where a face wasn't found | 493 | **110** |
| Different people accepted as "certain" | 0.37% | **0.00%** |
| Same person accepted as "certain" / at least suggested | 30.0% / 64.5% | **57.9% / 89.9%** |

| Detection on a real SD card (30-photo sample per folder; counts only, photos not viewed) | Old | **New** |
|---|---|---|
| 101MSDCF: faces found / most in one photo | 65 / 12 | **146 / 35** |
| 10861008: faces found / most in one photo | 49 / 4 | **76 / 24** |

What this means in practice:
- Side-on faces of someone you've named mostly arrive as **suggestions** for you to confirm, not silent matches.
- In dark photos, about 2% of faces are still not detected.
- Nothing is perfect, so uncertain matches are never counted unless you choose to include them.

Speed (M5): about 0.25–0.5 s per 24 MP photo, including tiled detection.

Current ArcFace thresholds (cosine similarity): certain ≥ 0.45, suggest ≥ 0.25, group ≥ 0.47. A face also needs
quality ≥ 0.35 to be matched automatically.

## Sending photos to people

| Feature | Where | What it does |
|---|---|---|
| **Only them** | Find (mode switch), ⌘K "solo" | Solo photos of one person, or photos of exactly the selected people and nobody else. Faces less than 40% the size of the selected faces (far background) don't count. |
| **Export Everyone** | People → Export Everyone…, or a person → Export All… | A folder per person ("Ana", "Ben") at any location you choose. Options: solo only, include uncertain, leave out shots to check, file format, names in copies, a .zip per person. |
| **Drag out / Share / Send** | Find export bar, hover on a photo | Drag any number of photos straight into Finder, Messages, Mail or WhatsApp. Share opens AirDrop, Messages and Mail. **Send to Ana** pre-addresses Messages or Mail once Ana is linked to a contact. |
| **Names in exported copies** | Export options (on by default) | Writes XMP `Iptc4xmpExt:PersonInImage` plus keywords. JPEG/HEIC/PNG/TIFF get it embedded without re-encoding pixels; RAW files get a `.xmp` sidecar. Originals are never touched. |
| **Contact sheet PDF** | Find export bar, a person's ⋯ menu, ⌘K | A4 proof sheet: 20 frames per page with frame numbers, filenames, dates, people, and an optional watermark. Built from cached thumbnails, so it works with the card ejected. |

**Shots to check are marked, never removed:**
- **Eyes may be closed:** eye height ÷ width from Vision landmarks is below 0.06. Calibrated by inspecting the lowest-scoring LFW faces; 0.06–0.12 is mostly squinting smiles, which are left alone.
- **Soft:** the face is less than 45% as sharp as that person's typical sharpness (variance of the Laplacian).
- **Bursts:** frames from the same source, ≤ 2 s apart and visually alike. Every frame is shown, labelled "Burst 2/4". Stacking behind the best frame is opt-in (View menu in Find, *Stack bursts* on a person's page), and the inspector shows the whole burst as a strip.
- **★ Best:** the top fifth by shot quality (face quality × sharpness × eyes open × face size).
- **How they're shown:** shots where eyes may be closed or focus is soft appear in a separate **Check before sending** section that starts out of the export. One click includes any of them, and *View* can turn the separation off. Burst frames always stay in the main grid.

**Review and organising:**
- **Accept all:** Review → Uncertain → *All at once* groups suggestions by person, with Accept All / Reject All per person, plus Accept All for everything. A person's page has Confirm All.
- **Drag a face onto a name** in the sidebar to assign it.
- **This Is Me:** lets ⌘K understand "me".

**Insights:**
- **Together map:** who appears with whom, with line thickness showing photos together. Click a line to see those photos, or drag nodes to rearrange.
- **Coverage:** photos and solo photos per person, flagging anyone with less than a quarter of the typical count.

**⌘K command bar:** type e.g. "me + asha october solo best copy to desktop". It shows what it understood as chips, and words it didn't understand are flagged, never guessed.

**Card inserted:** a banner offers "Scan new photos" with the count of files not yet in the library.

**Hover:** photos, faces, people and filters lift and glow on hover. Photo tiles reveal who's in them, the date, and Share / Show in Finder / Details. All of this respects Reduce Motion.

## Design and feel

- **Photos at their real shape:** grids use justified rows. Portraits and landscapes keep their proportions and every full row fills the width exactly; ⌘+ / ⌘− change the row height.
- **Zoom into the viewer:** clicking a photo grows it from its tile into the full-window viewer, and closing shrinks it back into place (or fades if you've moved to a photo that's off screen). Tile positions are only measured at open and close, so scrolling isn't slowed.
- **Undo (⌘Z) and redo (⇧⌘Z):**
  - **What it covers:** naming, merging, Forget, Not this person, assign, accept/reject all, ignore, split, cover and contact changes.
  - **How it works:** each step stores a before-image of the people data, including face templates deleted by Forget or Ignore, so undo is exact. A toast after each change offers Undo.
  - **When history clears:** after a scan or a bulk deletion, because the faces underneath have changed.
- **Developing tray:** while scanning, new faces develop like prints, from dark, flat and colourless to full colour under an amber safelight. With Reduce Motion they simply appear.
- **Event recap card:** a 2160×2700 shareable image for a shoot (Find → Recap, or Recap on an import in Cards & Folders). It shows the best shot (most named people, sharp, eyes open), your title, dates, photo and people counts, and the most-photographed faces. Wide group shots are shown whole over a soft blurred backdrop instead of being cropped. Save as PNG, copy, or share via AirDrop/Messages.

## Settings (sidebar, or ⌘,)

| Page | What's there |
|---|---|
| Appearance | 16 themes (each with light and dark), a live preview built from your own photos and faces that follows the pointer across the gallery, a smooth crossfade when applying, System/Light/Dark mode, accent swatches plus a full colour picker, heading font (New York, SF Pro, Rounded, Mono). |
| Photos & Grid | Row height, spacing, photo corners, filename / face / quality badges, hover effects, defaults for stacking bursts, shots to check and uncertain matches, number of people in the sidebar. |
| Library & Storage | **Keep small preview copies** (on by default; off = nothing is copied and photos show only while the card is connected), delete stored previews, delete sharp face crops, card-inserted banner, library location. |
| Scanning & Recognition | Detail (Fast 2400 / Standard 3200 / Detailed 4800 px), tiled small-face detection, photos analysed at once, matching strictness, model install, re-analyse. |
| Export | Defaults for Copy to Folder: file type, resize, folders, verify, names in copies, zip. |
| Privacy & Data | What's stored, backup and restore, clear face data, erase everything, why there's no cloud. |
| Keyboard Shortcuts / About | Reference list; version and model licences. |

## Private Space

A place for photos you want hidden from the regular library, behind **a password you create just for Pixora**.
It isn’t your Mac login, Apple Account or any other password, and there is no account, sign-in or internet involved.

- **Setup:** create and confirm the password (10+ characters, strength meter). The next step offers **Save Password
  File…**: a plain text file containing the password, saved only where you choose in the save panel. Pixora never
  e-mails, uploads or syncs it, and warns clearly that anyone who gets the file can open Private Space. Saving it is
  optional; it is the only copy of the password outside your head.
- **Private photo:** marked from the viewer, the details panel, the context menu or a selection. It leaves the
  library, search, counts, previews, slideshows and export suggestions. *Move to Library* (selection bar, viewer or
  context menu) brings it back.
- **Private person:** marked from their page. Their photos move in. From then on, confident matches from future scans
  go straight into Private Space, and uncertain ones wait in its Review queue (still out of ordinary browsing and
  search) until you confirm or reject them. Making the person public returns photos that were private only because
  of them.
- **Locking:** ⌘L, leaving Private Space, sleep, screen lock, and inactivity (default 5 minutes). Locking drops all
  decrypted content, in-memory images and any private slideshow immediately.
- **Changing the password:** with the current password, from the locked screen, the ⋯ menu inside, or Settings →
  Private Space. Local and offline; it re-wraps the key (photos aren’t re-encrypted) and then offers to save a new
  password file, since the old one stops working.
- **Forgotten password:** it can’t be recovered. Pixora never stored it, and there is no e-mail, OTP or online reset.
  *Forgot password?* explains this and offers to **delete and recreate Private Space only**. Before you confirm, it
  lists what will be deleted (the encrypted photo copies with their previews, faces and details; private people,
  their hidden names and face templates; the review queue; the indexes that keep private photos out of the library;
  the password and keys) and what stays untouched (original photos on cards, drives and folders; the regular library;
  settings). After deletion you create a new password. The old Private Space can’t be recovered. Photos that were
  private come back into the library the next time their folder is scanned.
- **Design:** its own look whatever the app theme: a lens-cap darkness with brass lens markings, a camera iris inside
  a lens ring, and a faint drifting light leak. Unlocking opens the iris over content that is already there, so the
  animation never delays access. Reduce Motion turns off the drift, the iris and the shake; VoiceOver reads every
  control and announces errors.

**Encryption design.**
- **Key pair:** a random X25519 key pair is created at setup.
- **Each private item:** its metadata, faces (templates and crops) and preview are sealed into one file, `Private/items/<uuid>.pxv`, with an ephemeral X25519 key agreement, HKDF-SHA256 and AES-256-GCM to the public key, so scans can add items while locked.
- **The private key:** stored only wrapped with AES-256-GCM under a key derived from your password (PBKDF2-HMAC-SHA256, 600,000 iterations, random salt), in the macOS Keychain with this-device-only access. The password itself is never stored: not in the library, logs or settings. After 5 wrong tries, unlocking is slowed down.
- **Plaintext clean-up:** plaintext library rows are deleted with SQLite `secure_delete` on and the WAL is checkpointed. Preview and face-crop cache files are removed.
- **What a separate device key protects while locked:** a random device key in the Keychain protects (a) keyed hashes of private photos' paths and fingerprints, so rescans skip them and other copies are caught, and (b) private people's face templates, so new matches can be routed. These are protected at rest, but not by the password.
- **Not encrypted:** your **original photo files**. Pixora never modifies originals, so a private photo is still readable on its card or drive.

## Slideshows

**Slideshows for you.** The bottom of **Find Photos** shows up to four rounded cards, one for each of the people you
photograph most. Each card slides through that person's best photos on its own (sharp, eyes open, close-ups first, a
different selection each day when there are plenty), with a slow crossfade and gentle push-in. Nothing to choose:
click a card and it plays full screen. Cycling pauses while the pointer is over a card; with Reduce Motion the cards
only fade.

**Make your own** with **More → Slideshow** in the results bar (after picking people) or inside Private Space:

1. **From:** the people selected above, one person, or photos you choose by hand.
2. **Style:** *Portraits* (close-ups: a big face, at most one other person), *Together* (everyone you picked),
   *Candid* (wider shots and group moments), *Story* (everything in date order), *Favorites* (photos you marked ♥ in
   the viewer (press L) or the context menu), *Event or Trip* (stretches of days Pixora suggests from gaps in the
   dates, or dates you choose). Each card says exactly what its rule is and how many photos fit.
3. **Check the photos:** the preview strip shows the slides in order. Drag to reorder, hover and press × to leave one
   out, *Add back* or *Reset*. Pixora’s eye and focus flags are offered as optional filters, labelled as guesses.
4. **Settings:** seconds per photo, transition (Crossfade, Gentle zoom, Drift, Cut), shuffle, dates and names.
5. **Music:** off by default and never starts on its own. Turn it on to choose *Soft tones* (chords Pixora
   synthesises live, so there is no recording to license) or an audio file of your own; set the volume and press
   *Listen* to try it. It plays only while the slideshow plays.
6. **Play Slideshow** (⌘↩): the window goes full screen. Space plays/pauses, ← → step, Esc exits; the controls fade
   after a few seconds and come back when you move the mouse. With Reduce Motion every transition is a plain fade.

Only photos you can see are used: the regular library never contains private photos. A slideshow made inside Private
Space stays there and closes the moment Private Space locks.

## Privacy and data

- **Stored locally only**, in `~/Library/Application Support/Pixora`:
  - `library.sqlite`: names, face templates (512 floats per face), small face crops (192 px JPEG), file paths,
    photo metadata (date, camera, lens, rating, GPS position) and corrections.
  - `Thumbnails/`: 640 px previews, so you can browse with the card ejected.
- **Nothing is written next to your photos.** Originals are opened read-only. Export only ever creates new files.
- **Encryption:** Pixora does not encrypt the library itself; it is protected by your macOS account and FileVault.
- **Deletion controls:**
  - *People → Forget* deletes one person and all their face templates.
  - *Settings → Clear All Face Data* deletes every template, crop, person and correction.
  - *Erase Everything* deletes the whole library and the thumbnail cache.
  - Removing a source deletes what Pixora learned from it.
- **Backup / Restore:** an online SQLite backup to a `.pixorabackup` file. It contains biometric data, so keep it private.
- **The map is the only network use, and it's off by default.** Places loads its map images from Apple Maps once you press **Turn On Map**, so Apple can see which areas you look at. Your photos, faces and names are never sent. Everything else in Pixora works without any network connection.
- **A photo's location goes with it.** Making a photo private removes its position from the library along with its row.

## Cloud processing: compared, and off in this version

| Provider | Can it recognise individuals? | Notes |
|---|---|---|
| Google Cloud Vision | No: detects faces and attributes only | [docs](https://cloud.google.com/vision/docs/detecting-faces) |
| Microsoft Azure Face | Identification/verification are **Limited Access** (application and approval required) | [Microsoft](https://learn.microsoft.com/legal/cognitive-services/computer-vision/limited-access-identity) |
| Amazon Rekognition | Yes (IndexFaces / SearchFaces with face collections) | US East: $0.001 per image for the first 1M images per month, plus $0.00001 per stored face per month; 12-month free tier of 1,000 images per month ([pricing](https://aws.amazon.com/rekognition/pricing/), checked 2026-11-01) |

**Recommendation: local by default, which is what this build does.** On-device SCRFD + ArcFace already gives 0% certain-wrong
on the held-out test. The only general-purpose provider that recognises individuals without an approval process
(Rekognition) would require uploading photos, storing face vectors in your AWS account, and using AWS IAM
credentials rather than a simple API key. Adding it is planned work (see below), not something this build pretends to do. If it is added,
credentials go in the macOS Keychain only, and a disclosure of exactly what is sent and what it may cost appears before
the first request.

## Design

The palette is a darkroom: warm charcoal in Dark Mode and contact-sheet paper in Light Mode, so the photos carry the
colour. One accent, *safelight amber*, is reserved for selection and the primary action. Headings use New York
(Apple's serif) for an editorial, photo-book feel. Frame numbers and filenames are set in SF Mono, like the edge print
on film (`▸0012 IMG_4821.CR3`).

- **Certainty is never shown by colour alone:** confirmed and automatic matches get a solid ring, uncertain ones a
  dashed ring plus "?".
- **Motion is limited to faces appearing during a scan,** and respects Reduce Motion.
- **Layout:** a three-column `NavigationSplitView` (sidebar · content · inspector) with adaptive grids. The minimum
  window is 1000 × 660; thumbnail size changes with ⌘+ / ⌘−.

## Dragging a photo out

Drag any photo from a grid onto the Desktop, a Finder window, Messages or Mail. To drag several, press **Select**, pick them, and drag any one of them: they all go together. It's always a copy: the originals stay exactly where they are. With the card or drive disconnected, Pixora copies small previews instead, named "preview" so they can't be mistaken for the full photos, and tells you it did.

## Favorites

Mark a photo with ♥ from the heart on its tile, the viewer (**L**), or the right-click menu. To mark several at once, press **Select**, pick them, and press **Favorite**. Favorites show a pink heart on their tile.

**To copy only your favorites:** pick a person in Find Photos, press **Favorites** in the bar at the bottom, then **Copy Photos to Folder**. A favorite hidden in a stacked burst or behind "best shots only" is brought into view first, so it is not left out. The same button is in **Select** mode on a person's page and in All Photos.

## The full photo view

The background takes on the colours of the photo, and the arrows and zoom control fade away when the pointer rests. Turn the glow off in **Settings → Photos & Grid**.

- **Swipe with two fingers, or click and drag,** to move between photos. The next photo follows your fingers, and a quick flick is enough.
- **Swipe up or down** to close. The photo shrinks back into its tile.
- **Holding an arrow key** runs through photos quickly.

## Lifting a subject out of a photo

Press and hold on someone in the full photo view, press firmly on a Force Touch trackpad, or press **C**. Pixora lifts them off the photo, on this Mac, using the same system feature as Photos. Press and hold on one person to lift only them; **C** lifts everyone. Then drag them out to Finder, Messages or Keynote as a transparent PNG, or use **Copy** or **Save PNG**. The original isn't touched, and it isn't available for Private Space photos, because a drag has to write a temporary file.

## Quick Pick

Go through a set of photos one at a time, full screen. Find it in **More** in Find Photos, on a person's page, and in All Photos.

| Key or swipe | Action |
|---|---|
| ← or swipe left | Skip |
| → or swipe right | Keep |
| ↑ or swipe up | Favorite |
| Z or Delete | Undo |
| Esc | Finish |

Pinch or double-click to check focus. At the end you can copy your picks, copy only the favorites, or play them as a slideshow. Skipping only moves on: nothing is removed from your library.

## Through Time

Open a person and press **Through Time**, or find it in **More** in Find Photos. Every photo of them is lined up on the eyes, so dragging along the timeline, or two-finger scrolling, shows one face changing. It picks sharp, open-eyed photos facing the camera and spreads them across the time you have, whether that's ten years or one afternoon. Press **Save Video** to keep it as a movie.

With the card or drive connected, frames are rebuilt from the originals and are much sharper. Nothing here is saved unless you save the video.

## Looking back

Find Photos opens with photos from this day in past years. A library less than a year old shows this time in an earlier month instead. Click to play them as a slideshow. The card doesn't appear when there's nothing to show.

## Places

Photos on a map, from the location saved in each one. Pins group as you zoom out and split as you zoom in; click one to zoom in or open its photos. Locations are read when photos are scanned, or from connected cards for photos scanned earlier. Most cameras only save a location with GPS or a phone link switched on, so many libraries have none. See [Privacy and data](#privacy-and-data) for how the map works.

## Zooming in the viewer

Pinch on the trackpad to zoom towards your fingers, up to 800%. Two-finger scroll or drag moves around the zoomed photo. Double-click or double-tap with two fingers to switch between fit and 250%. With a mouse, hold ⌘ and scroll. The **+**, **−** and **0** keys and the control under the photo do the same. Zooming in loads the full-size original when it is larger than the viewer's normal 3200 px.

**Keyboard shortcuts:**

| Shortcut | Action |
|---|---|
| ⌘1–7 | Switch section |
| ⌘O | Choose folder |
| ⌘E | Export |
| ⌥⌘I | Show/hide inspector |
| ⌘[ | Back |
| Y / N / → | Yes / No / Skip in Review |
| Space | Pause/resume a scan |
| C | Lift the subject (full photo view) |

## What has and hasn't been verified

**Verified on the development Mac (macOS 27, Apple M5):**
- Builds with Xcode 27.2; `swift test` runs 56 tests, all passing. They cover search (All / Any / Only them),
  uncertain matches, merge/forget, exports never overwriting, Private Space encryption at rest, routing of a private
  person's future matches, password change, slideshow style rules, favourites, zoom and swipe behaviour, Quick Pick,
  Through Time frame choice and video, memories, GPS reading and map grouping.
- Swipes, pinches, keys and clicks were replayed through the running app in the testing build, with frame timing
  measured, on a copy of a real 2,058-photo library.
- **Deleting Private Space never touches source photos:** a test writes real files to a pretend memory card, makes
  photos and a person private, deletes Private Space while locked, and checks every file on the card is byte-for-byte
  identical with the same modification date, no file was added, removed or renamed, the regular library and its
  people are unchanged, and the old password no longer opens anything.
- An end-to-end run (`pixora-eval --e2e`) on a test card built from LFW faces (grouping, search, export, rescan).
- Screens checked by screenshot: Find Photos with Slideshow Studio, Private Space setup, locked and unlocked views.

**Not yet verified:**
- A physical SD card or card reader, and real camera RAW files.
- Clicking through every control by hand (screens were driven with launch-time test hooks), including full-screen
  slideshow playback on every display setup.
- Libraries of tens of thousands of photos.
- Gestures by hand on a physical trackpad, the feel of trackpad taps, and dragging a lifted subject into other apps.
- Notarisation: the downloadable app is signed with a self-signed certificate, not notarised by Apple.

## Roadmap

1. Run on a real card from your camera; tune Strictness on your own photos.
2. Light-mode and VoiceOver pass; Quick Look on Space.
3. Optional cloud provider (Rekognition) behind an explicit opt-in, with Keychain storage and a cost and data disclosure.
4. App Sandbox with security-scoped bookmarks, then a Developer ID–signed, notarised build.
5. Incremental grouping for very large libraries.

## Credits and license

Pixora is made by **Mithin Sagar**. Questions, ideas and bug reports to
[mithinsagarofficial@gmail.com](mailto:mithinsagarofficial@gmail.com).

Pixora's source code is released under the [MIT License](LICENSE). The face models bundled in the app are
InsightFace's SCRFD and ArcFace (buffalo_l), which InsightFace releases for **non-commercial research use only**, so
Pixora as distributed is for personal, non-commercial use. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
