-module(wt_schedule).

-export([
    set_profile/1,
    get_profile/1,
    add_override/1,
    get_overrides/1
]).

-type result() :: {ok, map()} | {error, atom(), binary()}.

%%======================================================================================================
%% API
%%======================================================================================================

-spec set_profile(map()) -> result().
set_profile(Params) ->
    UserId = maps:get(<<"user_id">>, Params),
    Start = maps:get(<<"start_time">>, Params),
    End   = maps:get(<<"end_time">>, Params),
    Days  = maps:get(<<"days">>, Params),
    maybe
        ok      ?= validate_order(Start, End),
        {ok, _} ?= wt_db:upsert_work_profile(UserId, Start, End, Days),
        {ok, #{user_id => UserId, start_time => Start, end_time => End, days => Days}}
    else
        {error, Code, Msg} ->
            {error, Code, Msg};
        {error, Reason} ->
            ErrMessage = wt_codec:fmt(Reason),
            {error, internal, ErrMessage}
    end.

-spec get_profile(map()) -> result().
get_profile(#{<<"user_id">> := UserId}) ->
    maybe
        {ok, [{ClockIn, ClockOut, Days}]} ?= wt_db:get_work_profile(UserId),
        {ok, #{
            user_id   => UserId,
            clock_in  => fmt_time(ClockIn),
            clock_out => fmt_time(ClockOut),
            workdays  => to_list(Days)}
        }
    else
        {ok, []} ->
            {error, not_found, <<"No profile for this employee">>};
        {error, Reason} ->
            ErrMessage = wt_codec:fmt(Reason),
            {error, internal, ErrMessage}
    end.

-spec add_override(map()) -> result().
add_override(Params) ->
    UserId = maps:get(<<"user_id">>,    Params),
    Kind   = maps:get(<<"type_exclusion">>, Params),
    Start  = maps:get(<<"start_datetime">>, Params),
    End    = maps:get(<<"end_datetime">>,   Params),
    maybe
        {ok, [{Id, K, S, E}]} ?= wt_db:insert_override(UserId, Kind, Start, End),
        {ok, #{
            id => Id,
            user_id => UserId,
            kind => K,
            starts_at => fmt_ts(S),
            ends_at => fmt_ts(E)}
        }
    else
        {error, Reason} ->
            ErrMessage = wt_codec:fmt(Reason),
            {error, internal, ErrMessage}
    end.

-spec get_overrides(map()) -> result().
get_overrides(Params) ->
    UserId = maps:get(<<"user_id">>, Params),
    maybe
        {ok, Rows} ?= wt_db:list_overrides(UserId),
        Overrides = [#{id => Id, kind => K,  starts_at => fmt_ts(S), ends_at => fmt_ts(E)} || {Id, K, S, E} <- Rows],
        {ok, #{user_id => UserId, overrides => Overrides}}
    else
        {error, Reason} ->
            ErrMessage = wt_codec:fmt(Reason),
            {error, internal, ErrMessage}
    end.

%%======================================================================================================
%% INTERNAL
%%======================================================================================================

validate_order(Start, End) ->
    case Start < End of
        true  ->
            ok;
        false ->
            {error, invalid_schedule, <<"start_time must be before end_time">>}
    end.

fmt_time({Hour, Minute, Second}) ->
    TruncSecond = trunc(Second),
    iolist_to_binary(io_lib:format("~2..0B:~2..0B:~2..0B", [Hour, Minute, TruncSecond]));
fmt_time(T) when is_binary(T) ->
    T.

fmt_ts({{Y,Mo,D},{H,Mi,S}}) ->
    TruncSecond = trunc(S),
    iolist_to_binary(io_lib:format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ", [Y, Mo, D, H, Mi, TruncSecond]));
fmt_ts(T) when is_binary(T) ->
    T.

to_list({array, L}) ->
    L;
to_list(L) when is_list(L) ->
    L.
