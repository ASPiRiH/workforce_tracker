-module(wt_codec).

-export([
    decode/1,
    ok_reply/1,
    err_reply/2,
    fmt/1
]).

%%======================================================================================================
%% API
%%======================================================================================================

-spec decode(binary()) -> {ok, map()} | {error, bad_json}.
decode(Bin) ->
    try
        {ok, jsx:decode(Bin, [return_maps])}
    catch
        _:_ -> {error, bad_json}
    end.

-spec ok_reply(map() | list() | term()) -> binary().
ok_reply(Data) ->
    jsx:encode(#{<<"result">> => normalise(Data)}).

-spec err_reply(atom() | binary(), binary()) -> binary().
err_reply(Code, Msg) ->
    jsx:encode(#{<<"error">> => #{
        <<"code">>    => to_bin(Code),
        <<"message">> => Msg
    }}).

-spec fmt(term()) -> binary().
fmt(Term) ->
    iolist_to_binary(io_lib:format("~p", [Term])).

%%======================================================================================================
%% INTERNAL
%%======================================================================================================

normalise(M) when is_map(M) ->
    Fun = fun(K, V, A) -> A#{to_bin(K) => normalise(V)} end,
    maps:fold(Fun, #{}, M);
normalise([_ | _] = L) ->
    [normalise(X) || X <- L];
normalise(V) -> V.

to_bin(A) when is_atom(A) ->
    atom_to_binary(A);
to_bin(B) when is_binary(B) ->
    B;
to_bin(I) when is_integer(I) ->
    integer_to_binary(I).
