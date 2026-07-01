-module(wt_stats_SUITE).
-compile(export_all).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(MON, {2024, 1, 8}).

all() -> [
    stats_full_week,
    stats_no_punches,
    stats_no_profile,
    history_returns_events
].

suite() -> [{timetrap, {minutes, 2}}].

init_per_suite(Config) ->
    application:ensure_all_started(workforce_tracker),
    wt_test_db:create_schema(),
    RPC = wt_test_rpc:connect(),
    wt_test_rpc:wait_ready(RPC),
    [{rpc, RPC} | Config].

end_per_suite(Config) ->
    wt_test_rpc:disconnect(?config(rpc, Config)).

init_per_testcase(_Case, Config) ->
    wt_test_db:truncate(),
    Config.

end_per_testcase(_Case, _Config) -> ok.

%%  Week: Mon–Fri 09:00-18:00
%%  Mon  — arrived 10:00, left 18:00  → late_without_reason
%%  Tue  — arrived 09:00, left 16:00, covered by early override → early_with_reason
%%  Wed  — day_off override            → excluded from expected
%%  Thu  — no punches                  → worked_seconds=0, expected counted
%%  Fri  — perfect day 09:00-18:00     → no flags
stats_full_week(Config) ->
    RPC = ?config(rpc, Config),

    Param =  #{
        <<"user_id">> => 1,
        <<"start_time">>  => <<"09:00">>,
        <<"end_time">>    => <<"18:00">>,
        <<"days">>        => [1, 2, 3, 4, 5]
    },
    {ok, _} = rpc(RPC, <<"/work_time/set">>, Param),

    Tue = next_day(?MON),
    Wed = next_day(Tue),
    Thu = next_day(Wed),
    Fri = next_day(Thu),

%% Mon: late without reason
    wt_test_db:punch_at(<<"A">>, 1, <<"in">>,  ?MON, 10, 0),
    wt_test_db:punch_at(<<"A">>, 1, <<"out">>, ?MON, 18, 0),

%% Tue: early with reason
    Param2 =  #{
        <<"user_id">>    => 1,
        <<"type_exclusion">> => <<"early">>,
        <<"start_datetime">> => ts(Tue, 15, 0),
        <<"end_datetime">>   => ts(Tue, 18, 0)
    },
    {ok, _} = rpc(RPC, <<"/work_time/add_exclusion">>, Param2),
    wt_test_db:punch_at(<<"A">>, 1, <<"in">>,  Tue, 9,  0),
    wt_test_db:punch_at(<<"A">>, 1, <<"out">>, Tue, 16, 0),

%% Wed: day_off
    Param3 = #{
        <<"user_id">>    => 1,
        <<"type_exclusion">> => <<"day_off">>,
        <<"start_datetime">> => ts(Wed, 0,  0),
        <<"end_datetime">>   => ts(Wed, 23, 59)
    },
    {ok, _} = rpc(RPC, <<"/work_time/add_exclusion">>, Param3),

%% Thu: no punches (absent, no override)

%% Fri: perfect
    wt_test_db:punch_at(<<"A">>, 1, <<"in">>,  Fri, 9,  0),
    wt_test_db:punch_at(<<"A">>, 1, <<"out">>, Fri, 18, 0),

    Param4 =  #{
        <<"user_id">> => 1,
        <<"start_date">>  => fmt_date(?MON),
        <<"end_date">>    => fmt_date(Fri)
    },
    {ok, Stats} = rpc(RPC, <<"/work_time/statistics_by_user">>, Param4),

%% 4 workdays × 9h (Wed excluded) = 129600 s expected
%% worked: Mon 8h + Tue 7h + Thu 0h + Fri 9h = 86400 s
    ?assertEqual(4 * 9 * 3600, maps:get(<<"expected_seconds">>, Stats)),
    ?assertEqual(86400,        maps:get(<<"worked_seconds">>,    Stats)),
    ?assertEqual(1, maps:get(<<"late_without_reason">>,  Stats)),
    ?assertEqual(0, maps:get(<<"late_with_reason">>,     Stats)),
    ?assertEqual(0, maps:get(<<"early_without_reason">>, Stats)),
    ?assertEqual(1, maps:get(<<"early_with_reason">>,    Stats)).

%% profile exists, no punches in range → expected > 0, worked = 0
stats_no_punches(Config) ->
    RPC = ?config(rpc, Config),

    Param =  #{
        <<"user_id">> => 2,
        <<"start_time">>  => <<"09:00">>,
        <<"end_time">>    => <<"18:00">>,
        <<"days">>        => [1, 2, 3, 4, 5]
    },
    {ok, _} = rpc(RPC, <<"/work_time/set">>, Param),

    Param2 =  #{
        <<"user_id">> => 2,
        <<"start_date">>  => fmt_date(?MON),
        <<"end_date">>    => fmt_date(?MON)
    },
    {ok, Stats} = rpc(RPC, <<"/work_time/statistics_by_user">>, Param2),

    ?assertEqual(9 * 3600, maps:get(<<"expected_seconds">>, Stats)),
    ?assertEqual(0,        maps:get(<<"worked_seconds">>,   Stats)).

%% statistics for employee with no profile
stats_no_profile(Config) ->
    RPC = ?config(rpc, Config),
    {error, <<"not_found">>, _} = rpc(RPC, <<"/work_time/statistics_by_user">>, #{<<"user_id">> => 99}).

%% history returns all punch events ordered by time
history_returns_events(Config) ->
    RPC = ?config(rpc, Config),

    {ok, _} = rpc(RPC, <<"/card/assign">>, #{<<"user_id">> => 3, <<"card_uid">> => <<"H1">>}),

    wt_test_db:punch_at(<<"H1">>, 3, <<"in">>,  ?MON, 9,  0),
    wt_test_db:punch_at(<<"H1">>, 3, <<"out">>, ?MON, 18, 0),
    wt_test_db:punch_at(<<"H1">>, 3, <<"in">>,  next_day(?MON), 9, 0),

    {ok, #{<<"history">> := Events}} = rpc(RPC, <<"/work_time/history_by_user">>, #{<<"user_id">> => 3}),

    ?assertEqual(3, length(Events)),
    [First | _] = Events,
    ?assertEqual(<<"in">>, maps:get(<<"direction">>, First)).

%%======================================================================================================
%% INTERNAL
%%======================================================================================================

rpc(RPC, Method, Params) -> wt_test_rpc:call(RPC, Method, Params).

next_day(Date) ->
    calendar:gregorian_days_to_date(calendar:date_to_gregorian_days(Date) + 1).

ts({Y, Mo, D}, H, Mi) ->
    iolist_to_binary(io_lib:format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:00Z", [Y, Mo, D, H, Mi])).

fmt_date({Y, Mo, D}) ->
    iolist_to_binary(io_lib:format("~4..0B-~2..0B-~2..0B", [Y, Mo, D])).
