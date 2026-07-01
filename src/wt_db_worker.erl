-module(wt_db_worker).

-behaviour(gen_server).
-behaviour(poolboy_worker).

-include_lib("epgsql/include/epgsql.hrl").

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    conn :: pid() | undefined,
    cfg :: proplists:proplist()
}).

-spec start_link(proplists:proplist()) -> {ok, pid()}.
start_link(PoolConfig) ->
    gen_server:start_link(?MODULE, PoolConfig, []).

-spec init(proplists:proplist()) -> {ok, #state{}}.
init(PoolConfig) ->
    State = do_connect(#state{cfg = PoolConfig}),
    {ok, State}.

handle_call({query, Sql, Args}, _From, #state{conn = Conn} = State) when Conn =/= undefined ->
    Reply = case epgsql:equery(Conn, Sql, Args) of
        {ok, _Cols, Rows} ->
            {ok, Rows};
        {ok, _Count} ->
            {ok, []};
        {ok, _Count, _Cols, Rows} ->
            {ok, Rows};
        {error, #error{codename = unique_violation}} ->
            {error, conflict};
        {error, #error{codename = not_null_violation}} ->
            {error, constraint};
        {error, #error{codename = foreign_key_violation}} ->
            {error, constraint};
        {error, #error{message = Msg}} ->
            {error, {db, Msg}};
        {error, Other} ->
            {error, Other}
    end,
    {reply, Reply, State};
handle_call({query, _Sql, _Args}, _From, State) ->
    {reply, {error, not_connected}, State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(reconnect, State) ->
    UPState = do_connect(State),
    {noreply, UPState};
handle_info({'EXIT', Conn, _}, #state{conn = Conn} = State) ->
    erlang:send_after(2000, self(), reconnect),
    {noreply, State#state{conn = undefined}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{conn = C}) when C =/= undefined ->
    catch epgsql:close(C), ok;
terminate(_Reason, _S) ->
    ok.

code_change(_Vsn, State, _Extra) ->
    {ok, State}.

do_connect(#state{cfg = Config} = State) ->
    Opts = #{
        host     => proplists:get_value(host, Config, "localhost"),
        port     => proplists:get_value(port, Config, 5432),
        database => proplists:get_value(database, Config, "workforce"),
        username => proplists:get_value(username, Config, "wt"),
        password => proplists:get_value(password, Config, "secret"),
        timeout  => 5000
    },
    case epgsql:connect(Opts) of
        {ok, Conn} ->
            State#state{conn = Conn};
        {error, _} ->
            erlang:send_after(2000, self(), reconnect),
            State#state{conn = undefined}
    end.
