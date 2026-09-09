# Teleprompter

A macOS teleprompter that stays invisible to screen sharing, follows your
speaking pace, and jumps to the right answer when it hears a question.

Built for video calls — Zoom, Google Meet, Microsoft Teams. Everything runs
on-device; no audio is recorded and nothing is sent anywhere.

## What it does

| | Feature | How |
|---|---|---|
| 1 | **Invisible to screen sharing** | `NSWindow.sharingType = .none` excludes the panel from ScreenCaptureKit, the capture path Zoom, Teams and Chrome all use |
| 2 | **Jumps to the matching answer** | A CoreAudio process tap transcribes the *other* person on-device, then a two-tier matcher picks the section |
| 3 | **Scrolls at your speaking pace** | Your mic is transcribed separately and aligned to the script with a gapped sequence alignment |
| 4 | **Trackpad scroll any time** | Manual input hard-suspends the animation, then re-anchors where you left off |

Capturing the two voices from **separate sources** — the meeting's audio output
versus your microphone — means no speaker diarization is needed anywhere. That
single decision is what makes the rest tractable.

## Requirements

- macOS 26 or later (uses `SpeechAnalyzer`, introduced in macOS 26)
- Apple silicon
- Swift 6.3+ — Command Line Tools are enough, full Xcode is not required

## Build

```sh
./build.sh release
open build/Teleprompter.app
```

The script compiles with SwiftPM, assembles the `.app` bundle by hand, and
ad-hoc signs it with a **fixed identifier**. Pinning the identifier matters:
macOS keys permission grants to bundle identity, so without it every rebuild
re-prompts for microphone and audio access.

There is no Dock icon by design (`LSUIElement`) — look for the text icon in the
menu bar.

## Scripts

Markdown, where each `##` heading is a question and the text beneath is your
answer:

```markdown
## Tell me about yourself
Triggers: walk me through your background, introduce yourself

I'm a product manager with eight years in fintech...
```

`Triggers:` lines add alternate phrasings for the matcher. They are plain text
rather than HTML comments specifically so they survive a Google Docs export.

**Google Docs** — paste a link with ⌘G, or copy it first and the dialog is
skipped entirely. The document must be shared as *Anyone with the link*. It is
exported as **HTML, not plain text**: the txt export flattens headings into
ordinary lines, which would silently destroy the section structure the matcher
depends on.

If a document uses no heading styles at all, short prompt lines are inferred as
sections. Prep documents often carry a "story → questions it answers" table;
those trigger phrases are harvested automatically and attached to the matching
sections.

## Phone or tablet as the prompter

**Show on Phone…** in the menu starts a small local server and shows a QR code.
Scan it with a phone on the same wifi.

This is the strongest form of screen-share invisibility available: a second
device is not part of the screen at all, so no window flag is involved. The Mac
still does every hard part — system-audio capture, on-device transcription,
alignment, question matching — and the phone is a live view of the result. The
script follows your speaking pace and jumps with the answer matcher exactly as
it does on the Mac; touch-scroll any time and it resumes following a few seconds
later.

Works on Android, iPhone or tablet with no app to install. The page is
self-contained — no CDN — so it works on a network with no internet access.

The link carries a key regenerated on every launch, so nobody else on a café or
office network can read your script by guessing the port. No port is open until
you ask for the link, and **Stop Phone Link** closes it.

Transport is HTTP with Server-Sent Events rather than WebSocket: the channel only
ever pushes Mac to phone, which is exactly SSE's shape, and it needs no handshake
or frame codec on either side.

## Shortcuts

| Key | |
|---|---|
| `⌥⌘T` | Show / hide the prompter |
| `⌥⌘P` | Auto-scroll on / off |
| `⌥⌘F` | Follow my voice |
| `⌥⌘A` | Answer questions automatically |
| `⌥⌘Z` | Undo the last automatic jump |
| `⌥⌘C` | Click-through mode |
| `⌥⌘R` | Resync after scrolling by hand |
| `⌥⌘[` `⌥⌘]` | Previous / next section |
| `⌥⌘-` `⌥⌘=` | Text size |
| `⌥⌘M` | Bring back a hidden menu bar icon |

Registered through Carbon `RegisterEventHotKey`, which needs no Accessibility
permission — unlike `NSEvent` global monitors.

## Permissions

| Permission | When | Why |
|---|---|---|
| Microphone | ⌥⌘F | Transcribe your voice to track your position |
| Audio Recording | ⌥⌘A | Tap the meeting audio to hear questions |
| Screen Recording | Automatic text colour only | Measure the luminance behind a transparent panel |

The first two are requested only when you switch those modes on. Screen
Recording is needed solely for automatic text colour; decline it and that
setting falls back to following the system Light/Dark appearance.

## How the pieces work

**Reading tracker.** Aligns the tail of your speech against a forward-biased
window of the script using a gapped local alignment (Needleman–Wunsch style,
free start). Recognizers drop and insert words constantly, so a fixed-offset
comparison desynchronizes after a single dropped word. Measured across
simulated word-error rates:

| WER | avg error | p90 | lost lock |
|---|---|---|---|
| 10% | 0.04 words | 0 | 0.0% |
| 20% | 0.14 | 0 | 0.0% |
| 30% | 0.57 | 1 | 0.3% |
| 40% | 1.93 | 7 | 3.4% |

Past that it degrades to drifting at your measured speaking pace rather than
guessing — a wrong jump mid-sentence is worse than no jump.

**Question matcher.** Two tiers with inverted roles from the obvious design.
Contextual embeddings score 0.81+ on *everything*, including "sorry my camera
is being weird" — they rank the right section reliably but cannot say whether
any section applies. Lexical overlap can: genuine chit-chat scores 0.00. So
**semantic decides which, lexical decides whether**, and a jump needs both plus
a margin over the runner-up.

Coverage is idf-weighted, and terms are stemmed. Both matter: "tell me about a
time you failed" reduces to one content word, and it has to match a trigger
reading "Failure".

## Limitations

- **The invisibility flag is per-window.** Every auxiliary window is explicitly
  excluded too — alerts, the file picker, the status menu — but the menu-bar
  icon itself is drawn by macOS and cannot be hidden from capture. Hide it and
  drive by hotkeys if that matters.
- **Nothing hides you from a camera.** Or from someone filming your screen.
- **Re-verify after Zoom updates.** *Verify Invisibility…* checks the flag with
  the window server; a real screen share is the only end-to-end test.
- **Match thresholds are script-dependent.** Vocabulary and section count both
  shift the scores. *Jump More/Less Readily* tunes it.

## Layout

```
Sources/Teleprompter/
├── Window/     panel, scroll engine, rendering, background sampling
├── Script/     parsing, Google Docs, normalization
├── Audio/      microphone and system-audio capture
├── Speech/     on-device transcription
├── Logic/      reading tracker, question matcher
├── App/        menu bar, hotkeys, delegate
```
