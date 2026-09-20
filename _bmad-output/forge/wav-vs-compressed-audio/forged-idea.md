# WAV vs compressed audio

## Locked
- MVP keeps 16 kHz mono PCM16 WAV (architecture.md Decision 1.4). Size is not an MVP concern: retention defaults to delete-sooner (NFR-Pr6) and `auricle keep` is v1.1.
- "WAV is outdated" is not a reason to change. Only size or playback outside auricle could justify it.

## Rejected
- mp3/m4a for the MVP working copy. No MVP problem it solves; adds an encode step to the recovery copy.

## Corrections for downstream docs
- Decision 1.4 rejects AAC/m4a as "non-byte-sliceable". That is inaccurate: `AVAudioFile` reads frame ranges from AAC. WAV stands on Whisper-native input, universal readers, and no encode loss.

## Open (post-MVP)
- At `keep` time, transcode kept audio to mono AAC m4a at about 64 kbps (about 29 MB/hr vs 115 MB/hr). Undecided: whether kept audio is for listening only (lossy is fine) or re-processing with future models (lossless needed).
- Audio is never auto-deleted before verification, so unverified meetings grow unbounded at about 115 MB/hr. Tolerable at MVP volume.
