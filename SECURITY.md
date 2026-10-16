# Security

## What this tool sends where

Transcription, OCR, keyframes and rendering run on your machine. Two stages can leave it, and
only if you configure them to:

- **Authoring:** the agent you choose with `--agent-cmd` receives `evidence.md` (transcript,
  on-screen text and frame captions; no media).
- **Vision (optional):** the endpoint in `VISION_ENDPOINT` receives the sampled keyframes.

## Secrets

Keys are read from environment variables only. Inline secrets in `--agent-cmd` are masked in
the run banner and kept out of log filenames.

## Untrusted content

Transcripts and on-screen text come from the video and are untrusted. They reach the authoring
model as data. The prompt travels in an environment variable, never through shell parsing. A
deck that references images outside its folder (absolute paths, `file://`, `..`) is not
exported. Set `V2D_ALLOW_ABSOLUTE_IMAGES=1` only for decks you wrote yourself.

## Reporting

Please report vulnerabilities privately through GitHub's "Report a vulnerability" button on this
repository rather than in a public issue.
