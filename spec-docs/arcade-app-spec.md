# App spec: arcade

A small playable browser game with a persistent high-score table. This is
the first app whose data must survive restarts and redeploys.

## The game (served at /)

- One simple, genuinely playable game — implementer's choice (snake,
  breakout, reaction-timer, or similar). Keyboard or mouse/touch input.
- Single page, no frameworks required; readable and intentional-looking.
- When a run ends, the player sees their score and, if it makes the top 10,
  is prompted for a name to submit it.
- The page shows the current top-10 high scores (name, score), refreshed
  after each submission.

## API

- `GET /api/highscores` — top 10 as JSON, highest first:
  `[{"name": ..., "score": ..., "at": <ISO 8601>}]`
- `POST /api/scores` — `{"name": "...", "score": <int>}`. 400 on: missing
  or empty name, name over 12 characters, missing score, non-integer or
  negative score, malformed JSON.

## Persistence (the point of this app)

- High scores MUST survive container restarts and redeploys.
- The manifest requests platform storage (`storage: s3`); the app receives
  the bucket name in the `STORAGE_BUCKET` env var and uses the AWS SDK's
  default credential chain. A single JSON object holding the table is a
  fine storage layout; last-write-wins concurrency is accepted.
- Graceful degradation is part of the contract: with no storage reachable
  (e.g. a local run outside AWS), the app must still boot and pass its
  healthcheck; scores may fall back to memory. The healthcheck must never
  depend on S3.

## Quality bar

- Player names are untrusted: rendered inert on the page (no injection).
- Malformed JSON → 400, not a crash.
- JSON responses carry Content-Type: application/json.
- A smoke test covering submit → top-10 ordering → the 400 cases.
