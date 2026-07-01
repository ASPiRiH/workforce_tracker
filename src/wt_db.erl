-module(wt_db).

-export([q/2]).
-export([
    assign_card/2,
    find_active_card/1,
    last_punch_direction/1,
    insert_punch/3,
    deactivate_card/1,
    list_active_cards/1,
    deactivate_all_cards/1,
    upsert_work_profile/4,
    get_work_profile/1,
    insert_override/4,
    list_overrides/1,
    list_overrides_in_range/3,
    punch_history/1,
    punches_in_range/3
]).

-type db_result() :: {ok, [tuple()]} | {error, term()}.
-export_type([db_result/0]).

%%======================================================================================================
%% SQL
%%======================================================================================================

-define(SQL_ASSIGN_CARD,
    "INSERT INTO nfc_cards (card_uid, user_id) VALUES ($1, $2)").

-define(SQL_FIND_ACTIVE_CARD,
    "SELECT user_id FROM nfc_cards WHERE card_uid=$1 AND deleted_at IS NULL").

-define(SQL_LAST_PUNCH_DIRECTION,
    "SELECT direction FROM punch_log WHERE user_id=$1 ORDER BY punched_at DESC LIMIT 1").

-define(SQL_INSERT_PUNCH,
    "INSERT INTO punch_log (card_uid, user_id, direction) VALUES ($1, $2, $3)").

-define(SQL_DEACTIVATE_CARD,
    "UPDATE nfc_cards SET deleted_at=NOW()"
    " WHERE card_uid=$1 AND deleted_at IS NULL"
    " RETURNING user_id, card_uid").

-define(SQL_LIST_ACTIVE_CARDS,
    "SELECT card_uid FROM nfc_cards WHERE user_id=$1 AND deleted_at IS NULL").

-define(SQL_DEACTIVATE_ALL_CARDS,
    "UPDATE nfc_cards SET deleted_at=NOW()"
    " WHERE user_id=$1 AND deleted_at IS NULL"
    " RETURNING card_uid").

-define(SQL_UPSERT_WORK_PROFILE,
    "INSERT INTO work_profiles (user_id, clock_in, clock_out, workdays)"
    " VALUES ($1, $2::text::time, $3::text::time, $4)"
    " ON CONFLICT (user_id) DO UPDATE"
    " SET clock_in=$2::text::time, clock_out=$3::text::time, workdays=$4, updated_at=NOW()").

-define(SQL_GET_WORK_PROFILE,
    "SELECT clock_in, clock_out, workdays FROM work_profiles WHERE user_id=$1").

-define(SQL_INSERT_OVERRIDE,
    "INSERT INTO work_overrides (user_id, kind, starts_at, ends_at)"
    " VALUES ($1, $2, $3::text::timestamptz, $4::text::timestamptz)"
    " RETURNING id, kind, starts_at, ends_at").

-define(SQL_LIST_OVERRIDES,
    "SELECT id, kind, starts_at, ends_at FROM work_overrides"
    " WHERE user_id=$1 ORDER BY starts_at").

-define(SQL_LIST_OVERRIDES_IN_RANGE,
    "SELECT kind, starts_at, ends_at FROM work_overrides"
    " WHERE user_id=$1 AND starts_at::date <= $3 AND ends_at::date >= $2"
    " ORDER BY starts_at").

-define(SQL_PUNCH_HISTORY,
    "SELECT card_uid, direction, punched_at FROM punch_log"
    " WHERE user_id=$1 ORDER BY punched_at").

-define(SQL_PUNCHES_IN_RANGE,
    "SELECT direction, punched_at FROM punch_log"
    " WHERE user_id=$1 AND punched_at::date BETWEEN $2 AND $3"
    " ORDER BY punched_at").

%%======================================================================================================
%% API
%%======================================================================================================

-spec q(string(), list()) -> db_result().
q(Sql, Args) ->
    poolboy:transaction(wt_db_pool, fun(W) ->
        gen_server:call(W, {query, Sql, Args})
    end).

-spec assign_card(binary(), pos_integer()) -> db_result().
assign_card(CardUID, EmpId) ->
    q(?SQL_ASSIGN_CARD, [CardUID, EmpId]).

-spec find_active_card(binary()) -> db_result().
find_active_card(CardUID) ->
    q(?SQL_FIND_ACTIVE_CARD, [CardUID]).

-spec last_punch_direction(pos_integer()) -> binary().
last_punch_direction(EmpId) ->
    case q(?SQL_LAST_PUNCH_DIRECTION, [EmpId]) of
        {ok, [{<<"in">>}]} ->
            <<"out">>;
        _ ->
            <<"in">>
    end.

-spec insert_punch(binary(), pos_integer(), binary()) -> ok | {error, conflict} | {error, term()}.
insert_punch(CardUID, EmpId, Direction) ->
    case q(?SQL_INSERT_PUNCH, [CardUID, EmpId, Direction]) of
        {ok, []} ->
            ok;
        {error, conflict} ->
            {error, conflict};
        {error, _} = E ->
            E
    end.

-spec deactivate_card(binary()) -> db_result().
deactivate_card(CardUID) ->
    q(?SQL_DEACTIVATE_CARD, [CardUID]).

-spec list_active_cards(pos_integer()) -> db_result().
list_active_cards(UserId) ->
    q(?SQL_LIST_ACTIVE_CARDS, [UserId]).

-spec deactivate_all_cards(pos_integer()) -> db_result().
deactivate_all_cards(UserId) ->
    q(?SQL_DEACTIVATE_ALL_CARDS, [UserId]).

-spec upsert_work_profile(pos_integer(), binary(), binary(), list()) -> db_result().
upsert_work_profile(UserId, Start, End, Days) ->
    q(?SQL_UPSERT_WORK_PROFILE, [UserId, Start, End, Days]).

-spec get_work_profile(pos_integer()) -> db_result().
get_work_profile(UserId) ->
    q(?SQL_GET_WORK_PROFILE, [UserId]).

-spec insert_override(pos_integer(), binary(), binary(), binary()) -> db_result().
insert_override(UserId, Kind, Start, End) ->
    q(?SQL_INSERT_OVERRIDE, [UserId, Kind, Start, End]).

-spec list_overrides(pos_integer()) -> db_result().
list_overrides(UserId) ->
    q(?SQL_LIST_OVERRIDES, [UserId]).

-spec list_overrides_in_range(pos_integer(), calendar:date(), calendar:date()) -> db_result().
list_overrides_in_range(UserId, From, To) ->
    q(?SQL_LIST_OVERRIDES_IN_RANGE, [UserId, From, To]).

-spec punch_history(pos_integer()) -> db_result().
punch_history(UserId) ->
    q(?SQL_PUNCH_HISTORY, [UserId]).

-spec punches_in_range(pos_integer(), calendar:date(), calendar:date()) -> db_result().
punches_in_range(UserId, From, To) ->
    q(?SQL_PUNCHES_IN_RANGE, [UserId, From, To]).
