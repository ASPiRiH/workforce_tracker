-module(wt_mq).

-behaviour(gen_server).

-include_lib("amqp_client/include/amqp_client.hrl").

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(RETRY_MS, 3000).

-record(state, {
    cfg  :: proplists:proplist(),
    conn :: pid() | undefined,
    chan :: pid() | undefined
}).

start_link(MqConfig) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, MqConfig, []).

init(MqConfig) ->
    self() ! connect,
    {ok, #state{cfg = MqConfig}}.

handle_call(_Request, _From, State) ->
    {reply, {error, not_implemented}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(connect, State) ->
    UpState = try_connect(State),
    {noreply, UpState};
handle_info(reconnect, S) ->
    Upstate = try_connect(S#state{conn = undefined, chan = undefined}),
    {noreply, Upstate};
handle_info({BasicDelivery, AmqpMsg}, #state{chan = Chan} = State) ->
    #'basic.deliver'{delivery_tag = Tag} = BasicDelivery,
    #amqp_msg{payload = Body, props = Props} = AmqpMsg,
    Response = handle_request(Body),
    reply_to(Chan, Props, Response),
    amqp_channel:cast(Chan, #'basic.ack'{delivery_tag = Tag}),
    {noreply, State};
handle_info({'DOWN', _Ref, process, _Pid, Reason}, State) ->
    logger:warning("wt_mq: broker connection lost (~p), reconnecting in ~pms", [Reason, ?RETRY_MS]),
    erlang:send_after(?RETRY_MS, self(), reconnect),
    {noreply, State#state{conn = undefined, chan = undefined}};
handle_info(_Msg, State) ->
    {noreply, State}.

try_connect(#state{cfg = MqConfig} = State) ->
    Params = #amqp_params_network{
        host     = proplists:get_value(host, MqConfig, "localhost"),
        port     = proplists:get_value(port, MqConfig, 5672),
        username = proplists:get_value(user, MqConfig, <<"guest">>),
        password = proplists:get_value(pass, MqConfig, <<"guest">>)
    },
    Queue = proplists:get_value(queue, MqConfig, <<"workforce.rpc">>),
    maybe
        {ok, Conn} ?= amqp_connection:start(Params),
        {ok, Chan} ?= amqp_connection:open_channel(Conn),
        ok         ?= declare_and_consume(Chan, Queue),
        _MonRef     = erlang:monitor(process, Conn),
        logger:info("wt_mq: connected to broker, consuming ~s", [Queue]),
        State#state{conn = Conn, chan = Chan}
    else
        Reason ->
            logger:warning("wt_mq: connection failed (~p), retrying in ~pms", [Reason, ?RETRY_MS]),
            erlang:send_after(?RETRY_MS, self(), reconnect),
            State
    end.

declare_and_consume(Chan, Queue) ->
    #'queue.declare_ok'{} = amqp_channel:call(Chan, #'queue.declare'{queue = Queue, durable = true}),
    amqp_channel:call(Chan, #'basic.qos'{prefetch_count = 1}),
    #'basic.consume_ok'{} = amqp_channel:subscribe(Chan, #'basic.consume'{queue = Queue}, self()),
    receive
        #'basic.consume_ok'{} -> ok
    after
        5000 -> {error, consume_timeout}
    end.

handle_request(Body) ->
    maybe
        {ok, #{<<"method">> := Method, <<"params">> := Params}} ?= wt_codec:decode(Body),
        {ok, Valid}        ?= validated(Method, Params),
        {ok, Data}         ?= wt_router:dispatch(Method, Valid),
        wt_codec:ok_reply(Data)
    else
        {ok, _} ->
            wt_codec:err_reply(bad_request, <<"Missing 'method' or 'params'">>);
        {error, bad_json} ->
            wt_codec:err_reply(bad_request, <<"Invalid JSON">>);
        {error, Errors} ->
            wt_codec:err_reply(invalid_params, fmt_errors(Errors));
        {error, Code, Msg} ->
            wt_codec:err_reply(Code, Msg)
    end.

validated(Method, Params) ->
    case wt_validator:validate(Method, Params) of
        undefined ->
            {ok, Params};
        Result ->
            Result
    end.

fmt_errors(Errors) when is_map(Errors) ->
    Parts = maps:fold(fun(F, C, Acc) ->
        Fb = if is_binary(F) -> F; true -> wt_codec:fmt(F) end,
        Cb = if is_binary(C) -> C; true -> wt_codec:fmt(C) end,
        [<<Fb/binary, ": ", Cb/binary>> | Acc]
    end, [], Errors),
    iolist_to_binary(lists:join(<<"; ">>, Parts));
fmt_errors(_) ->
    <<"invalid parameters">>.

reply_to(_Chan, #'P_basic'{reply_to = undefined}, _Body) ->
    ok;
reply_to(Chan, #'P_basic'{reply_to = ReplyTo, correlation_id = CorrId}, Body) ->
    Props = #'P_basic'{content_type   = <<"application/json">>, correlation_id = CorrId},
    amqp_channel:cast(Chan, #'basic.publish'{routing_key = ReplyTo}, #amqp_msg{payload = Body, props = Props}).

terminate(_Reason, #state{conn = C}) when C =/= undefined ->
    catch amqp_connection:close(C), ok;
terminate(_Reason, _S) ->
    ok.
