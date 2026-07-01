# workforce_tracker

Erlang/OTP microservice for employee attendance tracking via NFC cards.  
Uses RabbitMQ as transport (JSON-RPC over AMQP) and PostgreSQL for storage.

## Tech stack

- Erlang/OTP 26 — application, supervisors, gen_server
- RabbitMQ 3.13 — AMQP, request/reply RPC pattern
- PostgreSQL 16 — via `epgsql` + `poolboy` connection pool
- `jsx` — JSON encode/decode
- `liver` — request validation (LIVR spec)
- Common Test — integration tests against real Docker services

## How it works

The service subscribes to a single RabbitMQ queue (`workforce.rpc`), processes
JSON messages in the format `{"method": "...", "params": {...}}`, and sends
the response back to the `reply_to` queue specified by the caller.

There is no HTTP layer — everything goes through the broker.

## Running locally

Start PostgreSQL and RabbitMQ in Docker (waits until both are healthy):

```bash
make docker-up
```

Then compile and run the shell:

```bash
make shell
```

Stop and clean up:

```bash
make docker-down
```

## Running tests

Tests go through the full production path: RabbitMQ → service → PostgreSQL.
Make sure Docker containers are running before launching tests.

```bash
make docker-up   # only needed once, containers stay up between runs

make ct          # all suites
make ct-cards    # single suite
make ct-cards c=card_lifecycle  # single test case
```

Available suites: `cards`, `schedule`, `stats`, `transport`.

CT reports are saved to `logs/ct/`.

## RPC contract

Request:
```json
{ "method": "/card/touch", "params": { "card_uid": "A1:B2:C3" } }
```

Success:
```json
{ "result": { "card_uid": "A1:B2:C3", "user_id": 42, "direction": "in" } }
```

Error:
```json
{ "error": { "code": "card_not_found", "message": "Card not registered" } }
```

## API methods

### Cards

**`/card/assign`** — assign a card to a user  
Params: `user_id` (int), `card_uid` (string)

**`/card/touch`** — register the next punch (in/out auto-detected)  
Params: `card_uid` (string)

**`/card/delete`** — deactivate a card (soft delete, history preserved)  
Params: `card_uid` (string)

**`/card/list_by_user`** — list active cards for a user  
Params: `user_id` (int)

**`/card/delete_all_by_user`** — deactivate all cards for a user  
Params: `user_id` (int)

### Work schedule

**`/work_time/set`** — create or update an employee's work schedule  
Params: `user_id` (int), `start_time` (`HH:MM`), `end_time` (`HH:MM`), `days` (array of 1–7, Mon=1)

**`/work_time/get`** — get the current schedule  
Params: `user_id` (int)

**`/work_time/add_exclusion`** — add a schedule override  
Params: `user_id` (int), `type_exclusion` (`late`/`early`/`day_off`), `start_datetime`, `end_datetime` (ISO 8601)

**`/work_time/get_exclusion`** — list all overrides for a user  
Params: `user_id` (int)

### Statistics

**`/work_time/history_by_user`** — full punch history for a user  
Params: `user_id` (int)

**`/work_time/statistics_by_user`** — attendance stats for a given period  
Params: `user_id` (int), `period` (`week`/`month`/`year`/`all`, default `month`),  
optional `start_date` + `end_date` (`YYYY-MM-DD`) to override period

Statistics response fields:
- `expected_seconds` — total scheduled work time
- `worked_seconds` — total time between first in and last out
- `late_with_reason` / `late_without_reason` — late arrival counts
- `early_with_reason` / `early_without_reason` — early departure counts

A day is counted only if it's in `workdays` and has no `day_off` override.  
Late/early "with reason" means the event falls within an approved override window.

## Environment variables

| Variable      | Default     | Description         |
|---------------|-------------|---------------------|
| `PG_HOST`     | `localhost` | PostgreSQL host     |
| `PG_PASSWORD` | `secret`    | PostgreSQL password |
| `AMQP_HOST`   | `localhost` | RabbitMQ host       |

Used in Docker to replace `localhost` with container service names.

## Building a release

```bash
make release
# output: _build/prod/rel/workforce_tracker/
```

Or build and run the full stack with Docker:

```bash
docker compose up --build
```

The Dockerfile uses a multi-stage build — the final image is based on `alpine:3.19`
and contains only the compiled release (~50 MB).

## Project structure

```
src/
  wt_app.erl          # OTP application entry point
  wt_sup.erl          # Supervisor tree
  wt_mq.erl           # RabbitMQ consumer / RPC server
  wt_router.erl       # Method dispatch
  wt_cards.erl        # Card logic
  wt_schedule.erl     # Schedule and override logic
  wt_stats.erl        # Attendance statistics
  wt_db.erl           # All SQL queries
  wt_db_worker.erl    # Single DB connection (gen_server)
  wt_codec.erl        # JSON helpers
  wt_validator.erl    # Input validation

test/
  wt_test_rpc.erl     # Shared AMQP test client
  wt_test_db.erl      # DB helpers (schema, truncate, fixtures)
  wt_*_SUITE.erl      # Test suites

config/
  sys.config          # DB and AMQP connection params
  vm.args             # Erlang VM flags
```
