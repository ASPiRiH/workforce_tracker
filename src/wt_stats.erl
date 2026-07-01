-module(wt_stats).

-export([history/1, statistics/1]).

-type result() :: {ok, map()} | {error, atom(), binary()}.

%%======================================================================================================
%% API
%%======================================================================================================

-spec history(map()) -> result().
history(#{<<"user_id">> := UserId}) ->
    maybe
        {ok, Rows} ?= wt_db:punch_history(UserId),
        Events = [#{card_uid   => C, direction  => D, punched_at => fmt_ts(T)} || {C, D, T} <- Rows],
        {ok, #{user_id => UserId, history => Events}}
    else
        {error, Reason} ->
            ErrMessage = wt_codec:fmt(Reason),
            {error, internal, ErrMessage}
    end.

-spec statistics(map()) -> result().
statistics(#{<<"user_id">> := UserId, <<"period">> := Period} = Params) ->
    StartOpt = maps:get(<<"start_date">>, Params, undefined),
    EndOpt   = maps:get(<<"end_date">>,   Params, undefined),
    maybe
        ok          ?= validate_date_range(StartOpt, EndOpt),
        {From, To}   = resolve_range(Period, StartOpt, EndOpt),
        {ok, Profile}      ?= fetch_profile(UserId),
        {ok, RawOverrides} ?= fetch_overrides(UserId, From, To),
        Overrides = [#{kind => K, starts_at => S, ends_at => E} || {K, S, E} <- RawOverrides],
        {ok, Punches}      ?= fetch_punches(UserId, From, To),
        Stats = compute(Profile, Overrides, Punches, From, To),
        {ok, Stats#{user_id => UserId, period => Period}}
    else
        {error, bad_request, Msg}  ->
            {error, bad_request, Msg};
        {error, no_profile, _} ->
            {error, not_found, <<"No work profile for this employee">>};
        {error, Reason} ->
            ErrMessage =  wt_codec:fmt(Reason),
            {error, internal, ErrMessage}
    end.

%%======================================================================================================
%% INTERNAL
%%======================================================================================================

compute(Profile, Overrides, Punches, From, To) ->
    #{clock_in := CIn, clock_out := COut, workdays := Workdays} = Profile,
    InSecs   = time_to_secs(CIn),
    OutSecs  = time_to_secs(COut),
    OvIdx    = index_by_date(Overrides, fun ov_date/1),
    PunchIdx = index_by_date(Punches, fun punch_date/1),
    Days     = date_seq(From, To),
    lists:foldl(
        fun(Day, Acc) ->
            case score_day(Day, Workdays, InSecs, OutSecs, OvIdx, PunchIdx) of
                skip        -> Acc;
                {ok, DaySt} -> merge(Acc, DaySt)
            end
        end,
        zero(), Days).

score_day(Day, Workdays, InSecs, OutSecs, OvIdx, PunchIdx) ->
    Overrides = maps:get(Day, OvIdx, []),
    Punches   = maps:get(Day, PunchIdx, []),
    maybe
        true  ?= lists:member(calendar:day_of_the_week(Day), Workdays),
        false ?= is_day_off(Overrides),
        {ok, score_punches(Day, InSecs, OutSecs, Overrides, Punches)}
    else
        _ ->
            skip
    end.

score_punches(Day, InSecs, OutSecs, Overrides, Punches) ->
    FirstIn = first_punch(<<"in">>,  Punches),
    LastOut = last_punch(<<"out">>, Punches),
    ExpectedSeconds = OutSecs - InSecs,
    WorkedSeconds = worked_seconds(FirstIn, LastOut),
    Base    = #{
        expected_seconds => ExpectedSeconds,
        worked_seconds   => WorkedSeconds
    },
    Base1   = late_status(Base, FirstIn, day_secs(Day, InSecs),  Overrides),
    early_status(Base1, LastOut, day_secs(Day, OutSecs), Overrides).

worked_seconds(undefined, _) ->
    0;
worked_seconds(_, undefined) ->
    0;
worked_seconds(In, Out) ->
    max(0, Out - In).

late_status(Base, undefined, _DayIn, _Ovs) ->
    Base;
late_status(Base, In, DayIn, _Ovs) when In =< DayIn ->
    Base;
late_status(Base, In, _DayIn, Ovs) ->
    inc(late_flag(In, find_override(<<"late">>, Ovs)), Base).

late_flag(In, #{ends_at := EndsAt}) ->
    case In =< gregsec(EndsAt) of
        true  ->
            late_with_reason;
        false ->
            late_without_reason
    end;
late_flag(_, _) ->
    late_without_reason.

early_status(Base, undefined, _DayOut, _Ovs) ->
    Base;
early_status(Base, Out, DayOut, _Ovs) when Out >= DayOut ->
    Base;
early_status(Base, Out, _DayOut, Ovs) ->
    inc(early_flag(Out, find_override(<<"early">>, Ovs)), Base).

early_flag(Out, #{starts_at := StartsAt}) ->
    case Out >= gregsec(StartsAt) of
        true  ->
            early_with_reason;
        false ->
            early_without_reason
    end;
early_flag(_, _) ->
    early_without_reason.

%% ---- DB helpers ----

fetch_profile(UserId) ->
    case wt_db:get_work_profile(UserId) of
        {ok, [{CIn, COut, Days}]} ->
            {ok, #{
                clock_in  => CIn,
               clock_out => COut,
               workdays  => to_list(Days)
            }};
        {ok, []} ->
            {error, no_profile, <<>>};
        {error, _} = Err ->
            Err
    end.

fetch_overrides(UserId, From, To) ->
    wt_db:list_overrides_in_range(UserId, From, To).

fetch_punches(UserId, From, To) ->
    wt_db:punches_in_range(UserId, From, To).

%% ---- period helpers ----

validate_date_range(undefined, undefined) ->
    ok;
validate_date_range(_, undefined) ->
    {error, bad_request, <<"start_date requires end_date">>};
validate_date_range(undefined, _) ->
    {error, bad_request, <<"end_date requires start_date">>};
validate_date_range(_, _) ->
    ok.

resolve_range(_Period, Start, End) when Start =/= undefined, End =/= undefined ->
    NewStart = parse_date(Start),
    NewEnd = parse_date(End),
    {NewStart, NewEnd};
resolve_range(Period, _, _) ->
    period_range(Period).

period_range(<<"week">>) ->
    Today = today(),
    Dow   = calendar:day_of_the_week(Today),
    Base  = calendar:date_to_gregorian_days(Today),
    Mon   = calendar:gregorian_days_to_date(Base - (Dow - 1)),
    Sun   = calendar:gregorian_days_to_date(Base + (7 - Dow)),
    {Mon, Sun};
period_range(<<"month">>) ->
    {Y, M, _} = today(),
    {{Y, M, 1}, {Y, M, calendar:last_day_of_the_month(Y, M)}};
period_range(<<"year">>) ->
    {Y, _, _} = today(),
    {{Y, 1, 1}, {Y, 12, 31}};
period_range(<<"all">>) ->
    {{2000, 1, 1}, today()}.

today() ->
    element(1, calendar:local_time()).

parse_date(<<Y:4/binary, "-", Mo:2/binary, "-", D:2/binary>>) ->
    {binary_to_integer(Y), binary_to_integer(Mo), binary_to_integer(D)}.

%% ---- date/time utilities ----

time_to_secs({H, M, S}) ->
    H * 3600 + M * 60 + trunc(S);
time_to_secs(T) when is_binary(T) ->
    [H, M] = binary:split(T, <<":">>),
    binary_to_integer(H) * 3600 + binary_to_integer(M) * 60.

gregsec({{Y,Mo,D},{H,Mi,S}}) ->
    calendar:datetime_to_gregorian_seconds({{Y,Mo,D},{H,Mi,trunc(S)}});
gregsec(B) when is_binary(B) ->
    gregsec(parse_iso8601(B)).

parse_iso8601(<<Y:4/binary, "-", Mo:2/binary, "-", D:2/binary, "T",
        H:2/binary, ":", Mi:2/binary, ":", S:2/binary, _/binary>>) ->
    {{binary_to_integer(Y), binary_to_integer(Mo), binary_to_integer(D)},
        {binary_to_integer(H), binary_to_integer(Mi), binary_to_integer(S)}}.

day_secs(Date, TimeSecs) ->
    calendar:datetime_to_gregorian_seconds({Date, {0,0,0}}) + TimeSecs.

date_seq(From, To) ->
    FromG = calendar:date_to_gregorian_days(From),
    ToG   = calendar:date_to_gregorian_days(To),
    [calendar:gregorian_days_to_date(N) || N <- lists:seq(FromG, ToG)].

first_punch(Dir, Punches) ->
    Secs = [gregsec(T) || {D, T} <- Punches, D =:= Dir],
    case Secs of
        [] ->
            undefined;
        _ ->
            lists:min(Secs)
    end.

last_punch(Dir, Punches) ->
    Secs = [gregsec(T) || {D, T} <- Punches, D =:= Dir],
    case Secs of
        [] ->
            undefined;
        _ ->
            lists:max(Secs)
    end.

ov_date(#{starts_at := T}) ->
    ts_to_date(T).
punch_date({_, T}) ->
    ts_to_date(T).

%% datetime from epgsql: {{Y,Mo,D},{H,Mi,S}} — second clause extracts the date part
ts_to_date({D, _}) ->
    D;
ts_to_date(B) when is_binary(B) ->
    <<Y:4/binary, "-", Mo:2/binary, "-", D:2/binary, _/binary>> = B,
    {binary_to_integer(Y), binary_to_integer(Mo), binary_to_integer(D)}.

index_by_date(Items, DateFun) ->
    Fun = fun(Item, Acc) ->
        K = DateFun(Item),
        maps:update_with(K, fun(L) -> [Item | L] end, [Item], Acc)
    end,
    lists:foldl(Fun, #{}, Items).

is_day_off(Overrides) ->
    lists:any(fun(#{kind := Kind}) -> Kind =:= <<"day_off">> end, Overrides).

find_override(Kind, Overrides) ->
    case [O || #{kind := K} = O <- Overrides, K =:= Kind] of
        [O | _] -> O;
        []      -> undefined
    end.

zero() ->
    #{
        expected_seconds     => 0,
        worked_seconds       => 0,
        late_with_reason     => 0,
        late_without_reason  => 0,
        early_with_reason    => 0,
        early_without_reason => 0
    }.

merge(Acc, Day) ->
    maps:fold(fun(K, V, A) ->
        maps:update_with(K, fun(X) -> X + V end, V, A)
    end, Acc, Day).

inc(Key, Map) ->
    maps:update_with(Key, fun(V) -> V + 1 end, 1, Map).

fmt_ts({{Y,Mo,D},{H,Mi,S}}) ->
    TruncSecond = trunc(S),
    iolist_to_binary(io_lib:format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ", [Y, Mo, D, H, Mi, TruncSecond]));
fmt_ts(T) when is_binary(T) ->
    T.

to_list({array, L}) ->
    L;
to_list(L) when is_list(L) ->
    L.
