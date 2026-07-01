-module(wt_test_rpc).
-export([connect/0, disconnect/1, call/3, wait_ready/1]).

-include_lib("amqp_client/include/amqp_client.hrl").

-define(QUEUE,        <<"workforce.rpc">>).
-define(TIMEOUT,      5000).
-define(READY_TRIES,  20).
-define(READY_SLEEP,  150).

connect() ->
    {ok, Conn} = amqp_connection:start(#amqp_params_network{}),
    {ok, Chan} = amqp_connection:open_channel(Conn),
    {Conn, Chan}.

disconnect({Conn, Chan}) ->
    amqp_channel:close(Chan),
    amqp_connection:close(Conn).

%% Block until wt_mq is up and consuming — fails if not ready after ~3 seconds
wait_ready(RPC) ->
    wait_ready(RPC, ?READY_TRIES).

wait_ready(_, 0) ->
    error(broker_not_ready);
wait_ready(RPC, N) ->
    try call(RPC, <<"/card/list_by_user">>, #{<<"user_id">> => 0}) of
        _ -> ok
    catch error:rpc_timeout ->
        timer:sleep(?READY_SLEEP),
        wait_ready(RPC, N - 1)
    end.

call({_Conn, Chan}, Method, Params) ->
    CorrId = base64:encode(crypto:strong_rand_bytes(6)),
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

    Body  = jsx:encode(#{<<"method">> => Method, <<"params">> => Params}),
    Props = #'P_basic'{reply_to = ReplyTo, correlation_id = CorrId, content_type = <<"application/json">>},
    amqp_channel:cast(Chan, #'basic.publish'{routing_key = ?QUEUE}, #amqp_msg{payload = Body, props = Props}),

    receive
        {#'basic.deliver'{}, #amqp_msg{payload = Resp, props = RProps}} ->
            #'P_basic'{correlation_id = RCorrId} = RProps,
            CorrId = RCorrId,
            parse(jsx:decode(Resp, [return_maps]))
    after
        ?TIMEOUT ->
            error(rpc_timeout)
    end.

parse(#{<<"error">>  := #{<<"code">> := C, <<"message">> := M}}) ->
    {error, C, M};
parse(#{<<"result">> := R}) ->
    {ok, R}.
