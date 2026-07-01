-module(wt_app).
-behaviour(application).

-export([start/2, stop/1]).

-spec start(application:start_type(), term()) -> {ok, pid()}.
start(_Type, _Args) ->
    ok = wt_validator:init(),
    wt_sup:start_link().

-spec stop(term()) -> ok.
stop(_State) ->
    ok.
