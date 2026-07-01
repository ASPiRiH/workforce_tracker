-module(wt_schedule_SUITE).
-compile(export_all).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

all() -> [
    profile_set_get_update,
    profile_invalid_order,
    profile_not_found,
    overrides_add_and_list
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

%% set → get → update → verify new value
profile_set_get_update(Config) ->
    RPC = ?config(rpc, Config),

    {ok, #{<<"user_id">> := 1}} =
        rpc(RPC, <<"/work_time/set">>, #{
            <<"user_id">> => 1,
            <<"start_time">>  => <<"09:00">>,
            <<"end_time">>    => <<"18:00">>,
            <<"days">>        => [1,2,3,4,5]
        }),

    {ok, #{<<"clock_in">> := <<"09:00:00">>, <<"workdays">> := [1,2,3,4,5]}} =
        rpc(RPC, <<"/work_time/get">>, #{<<"user_id">> => 1}),

    {ok, _} = rpc(RPC, <<"/work_time/set">>, #{
        <<"user_id">> => 1,
        <<"start_time">>  => <<"08:00">>,
        <<"end_time">>    => <<"17:00">>,
        <<"days">>        => [1,2,3,4,5]
    }),

    {ok, #{<<"clock_in">> := <<"08:00:00">>, <<"clock_out">> := <<"17:00:00">>}} =
        rpc(RPC, <<"/work_time/get">>, #{<<"user_id">> => 1}).

%% end_time before start_time
profile_invalid_order(Config) ->
    RPC = ?config(rpc, Config),
    Param = #{
        <<"user_id">> => 1,
        <<"start_time">>  => <<"18:00">>,
        <<"end_time">>    => <<"09:00">>,
        <<"days">>        => [1,2,3,4,5]
    },
    {error, <<"invalid_schedule">>, _} = rpc(RPC, <<"/work_time/set">>, Param).

%% get profile for employee that has none
profile_not_found(Config) ->
    RPC = ?config(rpc, Config),
    {error, <<"not_found">>, _} = rpc(RPC, <<"/work_time/get">>, #{<<"user_id">> => 99}).

%% add late + early + day_off overrides and list them
overrides_add_and_list(Config) ->
    RPC = ?config(rpc, Config),

    Param =  #{
        <<"user_id">> => 1,
        <<"start_time">>  => <<"09:00">>,
        <<"end_time">>    => <<"18:00">>,
        <<"days">>        => [1,2,3,4,5]
    },
    {ok, _} = rpc(RPC, <<"/work_time/set">>, Param),

    Param2 = #{
        <<"user_id">>    => 1,
        <<"type_exclusion">> => <<"late">>,
        <<"start_datetime">> => <<"2024-01-08T09:00:00Z">>,
        <<"end_datetime">>   => <<"2024-01-08T11:00:00Z">>
    },
    {ok, #{<<"kind">> := <<"late">>}} = rpc(RPC, <<"/work_time/add_exclusion">>, Param2),

    Param3 =  #{
        <<"user_id">>    => 1,
        <<"type_exclusion">> => <<"early">>,
        <<"start_datetime">> => <<"2024-01-08T16:00:00Z">>,
        <<"end_datetime">>   => <<"2024-01-08T18:00:00Z">>
    },
    {ok, #{<<"kind">> := <<"early">>}} = rpc(RPC, <<"/work_time/add_exclusion">>, Param3),

    Param4 = #{
        <<"user_id">>    => 1,
        <<"type_exclusion">> => <<"day_off">>,
        <<"start_datetime">> => <<"2024-01-09T00:00:00Z">>,
        <<"end_datetime">>   => <<"2024-01-09T23:59:59Z">>
    },
    {ok, #{<<"kind">> := <<"day_off">>}} =
        rpc(RPC, <<"/work_time/add_exclusion">>, Param4),

    {ok, #{<<"overrides">> := Ovs}} = rpc(RPC, <<"/work_time/get_exclusion">>, #{<<"user_id">> => 1}),
    ?assertEqual(3, length(Ovs)),

    Kinds = [maps:get(<<"kind">>, O) || O <- Ovs],
    ?assertEqual([<<"late">>, <<"early">>, <<"day_off">>], Kinds).

%%======================================================================================================
%% INTERNAL
%%======================================================================================================

rpc(RPC, Method, Params) -> wt_test_rpc:call(RPC, Method, Params).
