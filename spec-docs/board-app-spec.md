# App spec: board

A tiny public message board — a web page where visitors read and post short
messages — backed by a JSON API. One deployable unit: the same service serves
the page and the API.

## Frontend (served at /)

- A single HTML page listing all messages, newest first, each showing the
  message text and a relative timestamp ("2 minutes ago" is fine, exact time
  is fine too).
- A form with one text input and a post button; posting adds the message and
  updates the list without a full page reload.
- The page's heading comes from configuration: BOARD_TITLE, defaulting to
  "message board".
- No frameworks required; keep it small and dependency-free. It should look
  intentional (readable typography, sensible spacing) without being fancy.

## API

- `GET /api/messages` — all messages, newest first:
  `[{"id": ..., "text": ..., "created_at": <ISO 8601>}]`
- `POST /api/messages` — create from `{"text": "..."}`. 400 on missing/empty
  text or text over 280 characters. Returns 201 with the created message.
- Storage: in-memory (loss on restart accepted). Cap the list at the most
  recent 100 messages.

## Quality bar

- Message text is untrusted input: it must be rendered inert on the page
  (no HTML/script injection via a posted message).
- Malformed JSON gets a 400, not a crash.
- JSON responses carry Content-Type: application/json.
- A smoke test covering post → list → the 400 cases.
