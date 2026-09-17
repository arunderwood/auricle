# auricle

**Be in the meeting. Not in your notes.**

auricle captures meeting transcriptions locally — one tool, independent from the tedious configuration and behavior quirks of Zoom, Meet, Teams, or whatever platform your next meeting is on. Transcription and speaker labeling happen on your machine; you confirm who said what in a quick pass; the result lands as a single note in your Obsidian vault. The recording is deleted once you've confirmed the note is good.

**What's different:**

- **Your audio stays put.** Recording, transcription, and speaker labeling all run on-device. Only the finished transcript is sent out, and only for summarization (Claude).
- **Vault-native.** The note is a markdown file written straight into your vault — not something you go copy out of a web app afterward.
- **Built for one person on one Mac.** No accounts, no teams, no sharing model.

## How it works

```
capture  →  transcribe  →  diarize  →  attribute  →  summarize  →  persist
 audio        words        speakers   you confirm     notes        vault
```

Each stage runs on its own and can be re-run on its own, from the app or the command line. Speakers and attendees are written as `[[wikilinks]]`, and every action item or decision has to quote the transcript verbatim — anything that can't is dropped rather than guessed at.

## Status

Early development — not yet usable end to end. Current progress lives in [`_bmad-output/planning-artifacts/epics.md`](_bmad-output/planning-artifacts/epics.md) and each story's own spec file under [`_bmad-output/implementation-artifacts/`](_bmad-output/implementation-artifacts/).
