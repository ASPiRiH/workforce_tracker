-module(wt_transport_SUITE).
-compile(export_all).
-include_lib("common_test/include/ct.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(QUEUE,   <<"workforce.rpc">>).
-define(TIMEOUT, 5000).

all() -> [
    validation_missing_fields,
    validation_wrong_format,
    validation_not_allowed_value,
    unknown_method,
    bad_json,
    correlation_id_passthrough,
    no_reply_to_no_crash
].

suite() -> [{timetrap, {minutes, 3}}].

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

%% required fields missing
validation_missing_fields(Config) ->
    RPC = ?config(rpc, Config),
    {error, <<"invalid_params">>, _} = wt_test_rpc:call(RPC, <<"/card/assign">>, #{}),
    {error, <<"invalid_params">>, _} = wt_test_rpc:call(RPC, <<"/card/touch">>, #{}),
    {error, <<"invalid_params">>, _} = wt_test_rpc:call(RPC, <<"/work_time/set">>, #{<<"user_id">> => 1}).

%% fields present but wrong format
validation_wrong_format(Config) ->
    RPC = ?config(rpc, Config),

    Param = #{
        <<"user_id">> => 1,
        <<"start_time">>  => <<"9:0">>,
        <<"end_time">>    => <<"18:00">>,
        <<"days">>        => [1, 2, 3, 4, 5]
    },
    {error, <<"invalid_params">>, _} =
        wt_test_rpc:call(RPC, <<"/work_time/set">>, Param),

    Param2 = #{
        <<"user_id">>    => 1,
        <<"type_exclusion">> => <<"late">>,
        <<"start_datetime">> => <<"not-a-date">>,
        <<"end_datetime">>   => <<"2024-01-08T18:00:00Z">>
    },
    {error, <<"invalid_params">>, _} =
        wt_test_rpc:call(RPC, <<"/work_time/add_exclusion">>, Param2).

%% field value outside allowed set
validation_not_allowed_value(Config) ->
    RPC = ?config(rpc, Config),

    Param = #{
        <<"user_id">> => 1,
        <<"period">>      => <<"quarter">>
    },
    {error, <<"invalid_params">>, _} = wt_test_rpc:call(RPC, <<"/work_time/statistics_by_user">>, Param),

    Param2 =  #{
        <<"user_id">>    => 1,
        <<"type_exclusion">> => <<"vacation">>,
        <<"start_datetime">> => <<"2024-01-08T09:00:00Z">>,
        <<"end_datetime">>   => <<"2024-01-08T18:00:00Z">>
    },
    {error, <<"invalid_params">>, _} = wt_test_rpc:call(RPC, <<"/work_time/add_exclusion">>, Param2).

%% method not in router
unknown_method(Config) ->
    RPC = ?config(rpc, Config),
    {error, <<"not_found">>, _} = wt_test_rpc:call(RPC, <<"/invalid/method">>, #{}).

%% malformed JSON body
bad_json(Config) ->
    {_Conn, Chan} = ?config(rpc, Config),
    CorrId = <<"test-bad-json">>,
    QueueDeclare = #'queue.declare'{exclusive = true, auto_delete = true},
    #'queue.declare_ok'{queue = ReplyTo} = amqp_channel:call(Chan, QueueDeclare),
    amqp_channel:subscribe(Chan, #'basic.consume'{queue = ReplyTo, no_ack = true}, self()),
    receive
        #'basic.consume_ok'{} ->
            ok
    after
        ?TIMEOUT ->
            error(consume_timeout)
    end,

    Props = #'P_basic'{reply_to = ReplyTo, correlation_id = CorrId},
    amqp_channel:cast(Chan, #'basic.publish'{routing_key = ?QUEUE}, #amqp_msg{payload = <<"not json{{">>, props = Props}),

    receive
        {#'basic.deliver'{}, #amqp_msg{payload = Resp}} ->
            #{<<"error">> := #{<<"code">> := <<"bad_request">>}} =
                jsx:decode(Resp, [return_maps])
    after
        ?TIMEOUT -> error(rpc_timeout)
    end.

%% correlation_id must be echoed back unchanged
correlation_id_passthrough(Config) ->
    {_Conn, Chan} = ?config(rpc, Config),
    CorrId = <<"my-unique-corr-42">>,
    QueueDeclare = #'queue.declare'{exclusive = true, auto_delete = true},
    #'queue.declare_ok'{queue = ReplyTo} = amqp_channel:call(Chan, QueueDeclare),
    amqp_channel:subscribe(Chan, #'basic.consume'{queue = ReplyTo, no_ack = true}, self()),
    receive
        #'basic.consume_ok'{} ->
            ok
    after
        ?TIMEOUT ->
            error(consume_timeout)
    end,

    Props = #'P_basic'{reply_to = ReplyTo, correlation_id = CorrId},
    amqp_channel:cast(Chan,
        #'basic.publish'{routing_key = ?QUEUE},
        #amqp_msg{payload = jsx:encode(#{
            <<"method">> => <<"/card/list_by_user">>,
            <<"params">> => #{<<"user_id">> => 0}
        }), props = Props}),

    receive
        {#'basic.deliver'{}, #amqp_msg{props = RProps}} ->
            #'P_basic'{correlation_id = RCorrId} = RProps,
            ?assertEqual(CorrId, RCorrId)
    after
        ?TIMEOUT ->
            error(rpc_timeout)
    end.

%% message without reply_to must not crash the server
no_reply_to_no_crash(Config) ->
    {_Conn, Chan} = ?config(rpc, Config),
    amqp_channel:cast(Chan,
        #'basic.publish'{routing_key = ?QUEUE},
        #amqp_msg{payload = jsx:encode(#{
            <<"method">> => <<"/card/list_by_user">>,
            <<"params">> => #{<<"user_id">> => 1}
        })}),
    timer:sleep(300),
%% server still alive — a subsequent valid call returns a result
    RPC = ?config(rpc, Config),
    {ok, #{<<"cards">> := []}} = wt_test_rpc:call(RPC, <<"/card/list_by_user">>, #{<<"user_id">> => 1}).
