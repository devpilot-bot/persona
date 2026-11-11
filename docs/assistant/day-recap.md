# All-day recording and the daily recap

The Apple Watch records the whole day, the phone transcribes it on device as it arrives, and the hub writes a recap of
the day that reaches the user in the evening. This is not a third recording product: it is the recordings already in
the knowledge base ([recording.md](../apple/recording.md), [recording-rolling.md](../apple/recording-rolling.md)) with
a new kind, `day`, an incremental upload, and a recap made by the minutes pipeline
([meeting-minutes.md](meeting-minutes.md)) with its own prompts. This document is the contract the watch, the phone
and the hub follow (#4741); [protocol.md](../protocol/protocol.md) "Recording sync (#3235)" carries the same fields in
short.

## In one sentence

One tap on the watch in the morning starts it; the audio reaches the phone seconds (at most a few minutes) after it
was said, the phone transcribes it and appends the text to the hub, the hub reads each part of the day once as it
arrives, and in the evening only a small merge is left: the recap is ready before the 21:30 evening routine, which
reads it, and the user gets one push.

## Decided

Decided for the first version (#4741); each changes only with a new decision there.

1. **Transcription stays on the phone**, offline (`SpeechAnalyzer` / `SpeechTranscriber`, as recordings do today).
   The hub receives text only, never audio.
2. **Raw audio lives only on the user's devices** and is deleted 3 days after the day's final recap exists (at most
   7 days after the day in any case, "Retention and privacy").
3. **The transcript follows `recording_days`** (14 days by default); **the recap follows `minutes_days`** (forever by
   default) and survives trimming like minutes do.
4. **The recap joins the 21:30 evening routine** as a facts section, and also gets one push when it is first ready,
   like minutes.
5. **Suggested to-dos need the user's confirmation**, through the minutes' confirmation route.
6. **No standalone all-day recording on the iPhone** in this version: the watch records, the phone relays and
   transcribes.
7. **A new recording kind `day`** (not a policy of rolling recording, "Why a new kind" below), behind the hub feature
   flag `recording_day`; a hub without it is untouched. Meeting detection, calendar matching and attending never apply
   to it.
8. **One recording per local day.** A day that outgrows one recording's limits (20000 segments or 4 MiB of text)
   continues in a next part.
9. **Nothing runs over the whole day in one go.** The watch sends audio as it is recorded (seconds behind, at most a
   few minutes), the phone transcribes and appends as audio arrives, and the hub reads each part of the day once; a
   full `PUT` of the day is only for repairs.
10. **After a call or Siri takes the microphone the user taps once to continue**: watchOS cannot reopen the microphone
    in the background. The watch reminds them (haptic, notification, complication state); nothing works around the
    platform rule.

### Why a new kind

Rolling recording is a retention policy on the watch and phone: nothing is transcribed unless pulled, nothing reaches
the hub on its own. An all-day recording is the opposite on every point the hub cares about: everything is
transcribed and uploaded, the hub writes a recap instead of a summary or minutes, it is never a meeting, it is
appended to instead of replaced, and it is cut per day. A policy flag on a rolling recording would make every hub
code path ask both questions; a kind makes the old ones refuse it (`400` on an older hub, which the flag avoids
anyway). On the devices the mode may well reuse rolling recording's machinery (segment writer, tombstones, erase); only
the wire kind is fixed here.

## End to end

1. **Start.** The user taps **All-Day Recording** on the watch (home list, recording page or complication). The first
   time it explains what is recorded, where it goes and that the text goes to the hub's model for a recap (App Review
   5.1.2(i)). The watch offers it only when the paired phone says it can take it ("Watch and phone capabilities").
2. **Record.** The watch records with the `audio` background mode (wrist down, screen off), in the existing format
   (16 kHz mono AAC, 32 kbps). An interruption closes the open chunk at once and pauses; the watch taps the wrist,
   posts a local notification and shows "Paused" on the complication; one tap continues.
3. **Send to the phone as it records.** Each finished chunk goes to the phone right away while it is reachable, with a
   sequence number; the phone acknowledges each once it is stored, and the watch deletes its copy only then. While the
   phone is out of reach the watch keeps the chunks and sends them oldest first when it is back ("Watch to phone").
4. **Transcribe as it arrives.** The phone transcribes the chunks in sequence order and skips silent ones.
5. **Append to the hub.** Finished sentences are appended to that day's recording on the hub within about a minute
   (`POST /api/v1/recordings/{id}/segments`), with the phone's coverage of the day ("Phone to hub").
6. **Read as it arrives.** The hub reads each part of the day's text once it is complete and keeps notes per part; a
   late sentence makes it read that part again ("How the hub writes the recap").
7. **Recap.** 30 minutes before the evening routine's time (21:00 by default), or once the day's recording is
   complete, the hub merges the notes into the day's recap: a timeline by time of day, every item linked to its
   moment in the transcript, meetings apart from what was said outside them, and suggested to-dos.
8. **Deliver.** One push when the day's recap is first ready; the 21:30 evening routine's facts carry it; the web
   knowledge base shows it on the recording; the phone shows it on the recording's page.
9. **Midnight.** At local midnight the day's recording ends (`ended_at` midnight) and the next chunks open the next
   day's. The finished day becomes `complete` once its last audio is transcribed and appended, and the hub writes its
   final recap (no second push).

## Watch to phone

Rolling recording's transfer (`WatchRecordingTransfer`: finished segment files batched every 3 minutes by
`transferFile`) is not how this mode sends audio while the phone is reachable. The rules:

- **Chunks.** The watch cuts audio into chunks of about 10 seconds while the phone is reachable (the shortest segment
  `RecordingSegmentWriter` writes; one finished audio file of the existing format each; 10 s of 32 kbps AAC is about
  40 KB) and of 60 seconds otherwise. Each chunk has a **sequence number** `seq`: 0, 1, 2, … per day recording, never
  reused, without gaps on the watch (a chunk the user erased keeps its number and is sent as an erased marker without
  audio).
- **Live path.** While `WCSession.isReachable`, each chunk goes out as soon as it is finished with
  `sendMessageData(_:replyHandler:errorHandler:)`: a small JSON header (below) and the audio file in one message. The
  phone stores the chunk durably first, then replies with its acknowledgement. Keep each message under 48 KB; a chunk
  that does not fit goes by the backlog path.
- **Batching is allowed, but bounded.** In Low Power Mode, or while messages fail, the watch may hold chunks and send
  them together, but never more than 5 minutes behind while the phone is reachable. The whole day is never sent at the
  end.
- **Backlog path.** While the phone is not reachable, chunks stay on the watch. When it is reachable again they go
  oldest first: by `sendMessageData` one at a time, or by `transferFile` (one file per chunk, the header in its
  metadata) when more than about 5 minutes are waiting. A chunk finished while the backlog drains goes out at once;
  the phone orders by `seq`.
- **The watch never deletes an unacknowledged chunk by age** (unlike rolling recording's `undeliveredHours`). Under
  150 MB of free space it stops recording, keeps what it has, and says so; the user's erase is the only other way a
  chunk goes before it is acknowledged.
- **Acknowledgements.** The phone acknowledges by `seq` only after the chunk is on disk: in the reply to
  `sendMessageData` (`{"recording", "acks": [[from, to]]}`, inclusive ranges), and with the same object as a message
  (or `transferUserInfo` while not reachable) for chunks that came by `transferFile`. The watch deletes a chunk only
  once acknowledged. No acknowledgement within 30 s, or an error, sends it again with exponential backoff (2 s doubling
  to 5 minutes); becoming reachable retries at once.
- **No loss, no duplicates.** The phone keys chunks by `(recording, seq)`: one it already holds is acknowledged again
  and not stored twice. A gap in `seq` means the watch still holds those chunks: the phone transcribes up to the gap,
  and goes on past it once it has been open for 2 minutes while later chunks keep coming; the missing chunks are
  transcribed whenever they arrive, and their sentences are appended like any others (the hub orders by time).
- **Losses the watch could not avoid** (a crash took a chunk being written, a file it cannot read) are reported in a
  `lost` message (`{"recording", "lost": [[from, to]]}` by `seq`), so the phone stops waiting and reports the time as a
  gap.
- **Header** (JSON before the audio; the same keys in a `transferFile`'s metadata):

  ```jsonc
  {
    "v": 1,                                   // header version
    "recording": "<UUID>",                    // the day recording on the watch; the phone uses the same id for the hub
    "day": "2026-11-11",                      // local date the recording belongs to (the watch's time zone)
    "seq": 1234,
    "started_at": "2026-11-11T09:41:07.250+08:00",  // wall clock of the chunk's first sample (the audio buffer's host time)
    "duration": 10.0,                         // seconds of audio in the chunk (a pause never falls inside one)
    "level": -38.5,                           // mean RMS level in dBFS (the writer's level), for skipping silence
    "erased": false,                          // true: erased by the user; no audio follows
    "end": false                              // true on the last chunk of the day recording (the user stopped, or midnight)
  }
  ```

- **Erase the last 10 minutes** works as in rolling recording: the watch drops the chunks it still holds and sends
  erased markers for their numbers; the phone deletes the audio and the sentences of that range, and repairs the hub
  with a `PUT` ("Phone to hub"). Erasing on the phone does the same to its own copy and the hub.
- **Midnight** cuts a chunk at local midnight; the chunks after it carry the next `day` and a new `recording` id, and
  `seq` starts again at 0.

### Watch and phone capabilities

WatchConnectivity application context keys the phone sets when its session activates and whenever they change (next
to `recordingRolling`), which the watch stores beside `WatchSync.phoneRollingKey`:

| Key | Value | Meaning |
| --- | --- | --- |
| `recordingDay` | `1` (this contract's version) | The phone app takes all-day recordings: chunks with the header above, acknowledgements, transcription as they arrive. A phone from before never sets it, so the watch hides **All-Day Recording**. A higher number than the watch knows still means it can |
| `recordingDayHub` | `true` / `false` | The phone's hub lists `recording_day`, so the text will reach it and a recap will be written. With `false` the watch still records (the phone keeps the text and uploads it once the hub supports it, within `recording_days`) and says the recap needs a hub update |

The phone sets them from what its app supports and from its hub's last `hello.features`; neither goes through the
hub.

## Phone to hub

Only on a hub that lists `recording_day` (WS `hello.features` and trusted `/health`), which it does only while the
default manager (the one recording routes go to) is connected and names it in its `manager.hello` capabilities, as
with `meeting_attendance`. The phone reads it from the last `hello`; an older hub refuses `kind: "day"` with `400`.
Without the flag the phone keeps day recordings on the device, uploads nothing of them and tries again when the hub
lists it.

### The recording

One recording per local day per phone, with the watch's `recording` id. It is created with the ordinary full-state
`PUT /api/v1/recordings/{id}` and then grows by appends:

```jsonc
// PUT /api/v1/recordings/{id}: create (segments: []) or repair (every segment so far)
{
  "revision": 1762826467250,              // as today: > 0, increases per recording
  "kind": "day",
  "day": "2026-11-11",                    // required with kind day: the local date, YYYY-MM-DD
  "part": 1,                              // optional, 1–99, default 1: a later part of the same day ("Parts")
  "started_at": "2026-11-11T08:02:11+08:00",  // when recording began that day (local midnight for a day that carried over)
  "ended_at": "2026-11-12T00:00:00+08:00",    // omitted while the day is still recording
  "duration": 0,                          // seconds of audio received so far
  "language": "zh-CN",
  "device": "watch",
  "title": "",
  "bookmarks": [{"at": 4210.0, "label": ""}],
  "coverage": {"to": 0, "gaps": []},      // below
  "segments": [],
  "complete": false
}
```

- **The clock.** For `kind: day`, `segments[].start` / `end` and `bookmarks[].at` are **wall-clock seconds since
  `started_at`, pauses included**, so `started_at + start` is the moment it was said. (Other kinds keep the pause-free
  recording timeline.) The phone converts each chunk's sentences with the chunk's `started_at`.
- `kind: day` without a valid `day`, or a `part` outside 1–99, is `400`. `calendar`, `attendance`, `attending_session`,
  `room`, `private` and `transcription` are ignored on a day recording (attending asked for comes back as
  `attendance: "off"` with `attendance_problem: "not_meeting"`). A recording is a day recording from its first upload
  and stays one: a `PUT` that would change `kind` to or from `day` is `409 kind_changed`.
- **Full replacement still means full replacement**: a `PUT` replaces every segment, as for any recording, and sets
  the recording's **base** (its revision), which later appends must name. After it the hub's count (`next`) is the
  number of segments it carried, empty ones included. The phone sends one when it creates the day, after
  re-transcribing in another language, after an erase, and when reconciliation shows the hub lost text. The day's
  text so far must fit one `PUT` (the limits below); a part that would not is never repaired past them.
- `coverage` is the phone's view of the day, sent whole every time (it is small):
  - `to`: seconds since `started_at` up to which every chunk the phone holds is transcribed and appended (the end of
    the latest transcribed chunk). The hub reads the day only up to here.
  - `gaps`: `[{"from", "to", "reason"}]` (seconds since `started_at`, sorted, at most 500), time with no text and why:
    `paused` (the user paused), `interrupted` (a call, Siri or another app took the microphone until the user
    continued), `pending` (the watch still holds the audio), `lost` (the watch could not keep it), `erased` (the user
    erased it), `stopped` (recording stopped by itself: battery, storage, a crash). Recorded silence is not a gap. An
    unknown `reason` is kept as is.
- `complete` is `true` only once `ended_at` is set, no gap is `pending`, and every chunk is transcribed and appended.

### Appending

```jsonc
// POST /api/v1/recordings/{id}/segments
{
  "base": 1762826467250,                  // the revision of the last PUT of this recording
  "revision": 1762830067891,              // the phone's state time, > base; the stored revision becomes the larger
  "from": 812,                            // the position of the first segment below
  "segments": [{"start": 6125.2, "end": 6129.8, "text": "…"}],  // at most 500, in the phone's append order
  "duration": 6140.0,                     // optional, as in PUT
  "ended_at": "…",                        // optional, as in PUT
  "bookmarks": [],                        // optional: the whole list, as in PUT
  "coverage": {"to": 6130.0, "gaps": [{"from": 3120.0, "to": 3410.5, "reason": "interrupted"}]},  // optional, whole
  "complete": false                       // optional, as in PUT
}
```

- **Appends by position**, like `…/live`: segments at positions below the hub's count are skipped, so a retry stores
  nothing twice; the rest are stored after them. Positions are the phone's: it keeps the order it appended in (its own
  append log), so a position always names the same sentence on both sides until the next `PUT`. Sentences may be in
  any time order (a backlog arrives late); the hub orders by `start` wherever it reads them. A segment with empty text
  takes its position and is left out of the transcript.
- `200 {"id", "revision", "next", "status"}`: `status` `stored`, or `expired` (the day started before the
  `recording_days` window, or was trimmed; nothing written). `next` is the hub's count after this request; the phone
  sends from there.
- The other fields update the recording as a `PUT` would, without touching its segments; `segments: []` just updates
  them.
- Errors, in this order: `503` (knowledge base off or the manager not connected), `413 too_large` (body over 1 MiB),
  `410 recording_deleted`, `404 recording_not_found` (`PUT` it first; a `404` without that code means the route is
  missing: an older manager), `403 kb_read_only`, `400` (no `base`, `revision` not above it, a bad `from`, over 500
  segments, a non-numeric time, a bad `coverage`), `409 not_day` (the recording's kind is not `day`),
  `409 base_changed` (`{"error", "code", "base", "next"}`: a newer `PUT` replaced the text; append on that base from
  its `next`, or `PUT` again), `409 segments_gap` (`{"error", "code", "next"}`: `from` is above the hub's count; send
  from `next`), `413 day_full` (`{"error", "code", "next"}`: the segments of this request would pass 20000 positions or
  4 MiB of text; none of them was stored: start the next part, "Parts").
- Full credentials only, like `…/live` (not in `extwire.RouteScopes`); `403 forbidden` otherwise.

### Parts

When an append answers `413 day_full`, the phone ends that recording (`ended_at` at the start of the first sentence
that did not fit, `complete` once caught up) and continues the day in a new recording: a new UUID, the same `day`,
`part` one higher, `started_at` = the previous part's `ended_at`. Each part has its own recap; the evening routine and
the clients list a day's parts together, in order. A day this long is rare: 20000 sentences is about 16 hours of
continuous talk.

### Reconciliation

`GET /api/v1/recordings` lists a day recording with `kind: "day"`, `day`, `part`, `next` (the hub's count), `base`
and `recap_state` (when set) besides the usual fields. On the same base the phone appends from `next` when it is below
its own count; on another base, or when the hub lost text, it sends a `PUT`.

## What the hub stores and returns

On `GET /api/v1/kb/recordings/{id}`, `detail.meta` of a day recording adds `kind: "day"`, `day`, `part`, `coverage`,
`next`, `base` and `recap_state`:

| `recap_state` | Meaning |
| --- | --- |
| absent | No recap is due yet (the day is still recording and it is before the recap time) |
| `pending` | A recap is due and not written yet (or being rewritten); the previous one, if any, stays readable |
| `ready` | The newest recap due is written; newer text may have come since (`detail.recap.covers`) |
| `failed` | The model could not write it after the minutes' tries; `POST …/minutes` asks again |

`minutes_state`, `meeting`, `calendar` and the attending fields never appear on a day recording. `detail.segments` is
sorted by `start`. The short summary the hub writes for other recordings is not made for a day recording (it would
read the whole day); `detail.summary` is the recap's `summary` once there is one, so a client that knows only
summaries still shows something useful, and the recording's name is "Day · <date>" in the owner's language unless the
user titled it.

The recap is `detail.recap`, present once one was written:

```jsonc
{
  "version": 3,                       // increases each time the recap is rewritten; sent back when confirming to-dos
  "revision": 1762862400000,          // the recording revision it was made from
  "generated_at": "2026-11-11T13:00:41Z",
  "day": "2026-11-11",
  "covers": {"from": 0, "to": 46800.0},  // seconds since started_at the recap read (coverage.to at the time)
  "final": false,                     // true once made from the complete recording
  "summary": "Mostly the export release: …",   // two or three sentences
  "timeline": [
    {
      "from": 3600.0, "to": 6900.0,   // seconds since started_at
      "kind": "meeting",              // "meeting" or "outside"
      "title": "Design review",
      "meeting": {"kind": "recordings", "id": "<recording UUID>", "name": "Design review"},  // when the hub knows the meeting
      "points": [{"text": "The export path drops entries over 4 MB.", "at": 3912.0, "who": "Ada"}]
    },
    {
      "from": 7200.0, "to": 7800.0,
      "kind": "outside",
      "title": "Lunch with the platform team",
      "points": [{"text": "Bo will look at the flaky upload test.", "at": 7420.5}]
    }
  ],
  "actions": [
    {"id": "a1", "who": "Bo", "what": "Look at the flaky upload test.", "by": "tomorrow", "due_date": "2026-11-12", "at": 7420.5, "todo_id": ""}
  ],
  "gaps": [{"from": 3120.0, "to": 3410.5, "reason": "interrupted"}],   // coverage's gaps inside what it covers
  "partial": false,                   // true when the day was too long and some of it was not read
  "markdown": "# 2026-11-11\n…"        // the same recap as Markdown with clock times: recap.md on disk
}
```

- `at`, `from` and `to` are seconds since `started_at`, the clock of `segments[].start`, so a client jumps straight to
  the transcript. Every point and action carries an `at` that is the start of a line the model read; items citing no
  line are dropped, as in minutes, and an entry left with no point is dropped with them.
- `timeline` is in time order and covers what was said, not every minute: quiet hours have no entry. `kind: meeting`
  marks time inside a meeting the hub knows of: one of the user's meeting recordings overlapping it (`meeting.kind`
  `recordings`; its minutes have the detail), or a `meetings` / `events` item of the knowledge base starting in it.
  An entry the model judged to be a meeting with nothing matching has `kind: meeting` and no `meeting`. Everything else
  is `outside`.
- Clients show the timeline by time of day (morning, afternoon, evening by the clock), meeting entries marked with
  their name, and keep meetings and outside apart where they summarize (the push, the evening facts, the Markdown).
- `actions`, `who`, `by` and `due_date` follow the minutes' rules: no guessing who, `by` as said, `due_date` only when
  it is one date from the day to a year after it. `id` names an action within one `version`; `todo_id` is set once
  confirmed and carried over to later versions.
- Sections with nothing in them are omitted.

### Asking for a recap and confirming its to-dos

The minutes' routes serve a day recording too, so no route is added for them:

- `POST /api/v1/recordings/{id}/minutes` on a day recording (re)writes the recap from what the hub has now:
  `202 {"state": "pending"}`, `409` when it has no text, `409 transcript_expired` when trimmed. It never makes a day
  recording a meeting.
- `POST /api/v1/recordings/{id}/minutes/todos` `{"version", "actions"}` on a day recording confirms the recap's
  actions: `200 {"todos": [Todo], "recap": Recap}`; the version, retry and error rules are the minutes' (`409
  minutes_stale` when `version` is not the recap's current one). The to-do's notes name the day and the item's clock
  time.

## How the hub writes the recap

- **Reading as it arrives.** The knowledge base loop gets a recap lane of its own (beside the minutes lane, so a long
  day never holds back a meeting's minutes). It cuts a day's text (ordered by time, up to `coverage.to`) into chunks of
  the minutes pipeline's size (about 12000 characters) that never cross a full hour of the clock, and has the model
  note each finished chunk once (`kb/day_recap.md`: candidate timeline entries, points and to-dos, each citing its
  line). A chunk is finished when `coverage.to` has passed its hour, or when it is full. Lines are numbered by
  position, so notes stay valid as text arrives; the notes are kept per chunk with a hash of its lines, a late sentence
  changes the hash and that chunk is read again, and a `PUT` (a new base) drops them all. Nothing reads the whole day
  at once.
- **The recap** is one merge call over the notes (`kb/day_recap_merge.md`), with the day's known meetings (meeting
  recordings overlapping it, `meetings` and `events` items of that day, each with its time) as hints; chunks not noted
  yet (the hour in progress) are noted first. A recap is due:
  - at the recap time, 30 minutes before the evening routine's time (21:00 by default, whether or not the routine is
    on), for a day recording of today in the owner's time zone with text newer than its recap;
  - when the recording becomes `complete` (the final recap);
  - 6 hours after its day ended when it never became complete (a final recap of what arrived);
  - on `POST …/minutes`.
  New text after a recap does not rewrite it until one of those.
- The model and limits are the minutes' (`kb.compress`, the call and job timeouts, three unusable answers before
  `failed`, the timeout back-off). A day notes at most 60 chunks; the rest is left out and the recap is `partial`.
- **One push** when a recording's recap is first ready: "Your day recap is ready" with the number of meetings and
  suggested to-dos, a stable id per recording (not per version), a tap opens the main chat; the Lark bot and channels
  with pushes on get the same text with the recording's web link, as minutes do. A later version, the final one
  included, does not push again. A failure does not notify.

## The evening routine

The evening routine's facts (`assistant/routine_facts.md` in [prompts.md](prompts.md), on when the task's `facts` is
on) gain a section for today's day recordings (`day` is today in the owner's time zone), parts in order:

- the coverage (first and last time recorded, the gaps by reason);
- the recap's summary, its timeline in short (time range, meeting or outside, title, up to two points each), and the
  suggested to-dos not yet confirmed;
- or, without a recap yet, its state (being written, failed).

The section is bounded (about 4000 characters; when longer, entries from the middle of the day go first), says when
the recap was made, and is left out when there is no day recording today. The evening routine is off by default; the
push above reaches the user either way.

## Retention and privacy

- **Audio** stays on the watch until the phone acknowledged it, and on the phone until 3 days after the day's final
  recap (at most 7 days after the day). It never reaches the hub. Chunks of a day older than `recording_days` are not
  uploaded.
- **Transcript** (`segments.json`, `transcript.md`, the chunk notes) follows `recording_days`, on the hub and (through
  reconciliation's `days`) on the phone.
- **Recap** (`recap.json`, `recap.md`) is kept like minutes: past `recording_days` the hub trims the recording to
  `meta.json` and the recap, and removes it only past a finite `minutes_days` (forever by default). A trimmed day
  recording keeps its recap readable and searchable and its to-dos confirmable; `POST …/minutes` is
  `409 transcript_expired`. The user's delete removes everything.
- `kb_get` on a day recording prints the recap before the transcript, and `kb_search` matches `recap.md` (with
  `kind=recordings` too).
- **Consent and indication**: off by default; the first start explains it; the watch's microphone indicator, the app's
  state and the complication show it is on; pause and "Erase the last 10 minutes" are one tap away
  ([recording-rolling.md](../apple/recording-rolling.md) "Privacy and consent").

## Compatibility

| Watch | Phone | Hub | What happens |
| --- | --- | --- | --- |
| New | From before | Any | No `recordingDay` key: the watch does not offer all-day recording |
| New | New | Without `recording_day` | The watch records and sends; the phone transcribes and keeps the text; nothing is uploaded until the hub lists the flag (`recordingDayHub: false`) |
| New | New | With `recording_day` | This document |
| Any | New | Rolled back to an older manager | `…/segments` answers `404` without a code and `kind: day` is `400`: the phone keeps the text and waits for the flag again |

Older clients reading a hub with day recordings: the web and Android lists show them as recordings with
`detail.summary`; meeting screens never see them (no `minutes_state`).

## Not in this version

- A standalone all-day mode on the iPhone (Live Activity 8-hour limit).
- Cutting the day into scenes by calendar and silence on the device, and turning a meeting's part of the day into a
  meeting recording with minutes.
- The recap on the watch (the minutes relay can carry a short version later), and a "today" timeline on the phone.
- Hub transcription of the day's audio.
- Searching the knowledge base by date, and project timeline updates from the recap.
