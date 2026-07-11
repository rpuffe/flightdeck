# App spec: todo

A small JSON REST API for managing todo items. This spec plus CONVENTIONS.md
is everything the builder gets — it deliberately says nothing about
infrastructure, deployment, or language.

## Behavior

- `GET /todos` — list all todos as a JSON array.
- `POST /todos` — create a todo from `{"title": "..."}`; returns the created
  item with an `id` and `done: false`. 400 on missing/empty title.
- `PATCH /todos/{id}` — update `title` and/or `done`. 404 on unknown id.
- `DELETE /todos/{id}` — remove the todo. 404 on unknown id.
- Items are `{"id": <string or int>, "title": <string>, "done": <bool>}`.
- Storage: in-memory is fine (data loss on restart is accepted).
- A configurable greeting: `GET /` returns `{"message": <GREETING>}` where
  GREETING comes from configuration, defaulting to "todo api".

## Quality bar

- Handles malformed JSON bodies with a 400, not a crash.
- Returns correct Content-Type (application/json).
- Includes at least a smoke test that exercises create → list → complete.
