-module(wt_test_db).
-export([create_schema/0, truncate/0, punch_at/6]).

create_schema() ->
    Stmts = [
        "CREATE TABLE IF NOT EXISTS nfc_cards ("
        "    card_uid    TEXT        PRIMARY KEY,"
        "    user_id INT         NOT NULL,"
        "    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),"
        "    deleted_at  TIMESTAMPTZ"
        ")",
        "CREATE TABLE IF NOT EXISTS work_profiles ("
        "    user_id INT         PRIMARY KEY,"
        "    clock_in    TIME        NOT NULL,"
        "    clock_out   TIME        NOT NULL,"
        "    workdays    INT[]       NOT NULL,"
        "    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()"
        ")",
        "CREATE TABLE IF NOT EXISTS work_overrides ("
        "    id          SERIAL      PRIMARY KEY,"
        "    user_id INT         NOT NULL,"
        "    kind        TEXT        NOT NULL CHECK (kind IN ('late','early','day_off')),"
        "    starts_at   TIMESTAMPTZ NOT NULL,"
        "    ends_at     TIMESTAMPTZ NOT NULL"
        ")",
        "CREATE TABLE IF NOT EXISTS punch_log ("
        "    id          SERIAL      PRIMARY KEY,"
        "    card_uid    TEXT        NOT NULL,"
        "    user_id INT         NOT NULL,"
        "    direction   TEXT        NOT NULL CHECK (direction IN ('in','out')),"
        "    punched_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),"
        "    punched_date DATE GENERATED ALWAYS AS (CAST(punched_at AT TIME ZONE 'UTC' AS DATE)) STORED,"
        "    UNIQUE (user_id, direction, punched_date)"
        ")"
    ],
    [wt_db:q(S, []) || S <- Stmts],
    ok.

truncate() ->
    wt_db:q("TRUNCATE nfc_cards, work_profiles, work_overrides, punch_log RESTART IDENTITY CASCADE", []).

punch_at(CardUID, EmpId, Dir, {Y, Mo, D}, Hour, Min) ->
    TS = iolist_to_binary(io_lib:format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:00Z", [Y, Mo, D, Hour, Min])),
    {ok, _} = wt_db:q(
        "INSERT INTO punch_log (card_uid, user_id, direction, punched_at)"
        " VALUES ($1, $2, $3, $4::text::timestamptz)",
        [CardUID, EmpId, Dir, TS]).
