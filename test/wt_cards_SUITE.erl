-module(wt_cards_SUITE).
-compile(export_all).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

all() -> [
    card_lifecycle,
    multi_card_delete_all,
    touch_unknown_card,
    duplicate_assign,
    already_punched
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

%% assign → touch in → touch out → list → delete → list empty
card_lifecycle(Config) ->
    RPC = ?config(rpc, Config),

    {ok, #{<<"card_uid">> := <<"AA:BB">>, <<"user_id">> := 1}} =
        rpc(RPC, <<"/card/assign">>, #{<<"user_id">> => 1, <<"card_uid">> => <<"AA:BB">>}),

    {ok, #{<<"direction">> := <<"in">>, <<"user_id">> := 1}} =
        rpc(RPC, <<"/card/touch">>, #{<<"card_uid">> => <<"AA:BB">>}),

    {ok, #{<<"direction">> := <<"out">>, <<"user_id">> := 1}} =
        rpc(RPC, <<"/card/touch">>, #{<<"card_uid">> => <<"AA:BB">>}),

    {ok, #{<<"cards">> := [<<"AA:BB">>]}} =
        rpc(RPC, <<"/card/list_by_user">>, #{<<"user_id">> => 1}),

    {ok, #{<<"card_uid">> := <<"AA:BB">>}} =
        rpc(RPC, <<"/card/delete">>, #{<<"card_uid">> => <<"AA:BB">>}),

    {ok, #{<<"cards">> := []}} =
        rpc(RPC, <<"/card/list_by_user">>, #{<<"user_id">> => 1}).

%% multiple cards for one employee → delete_all clears all
multi_card_delete_all(Config) ->
    RPC = ?config(rpc, Config),

    {ok, _} = rpc(RPC, <<"/card/assign">>,
        #{<<"user_id">> => 2, <<"card_uid">> => <<"C1">>}),
    {ok, _} = rpc(RPC, <<"/card/assign">>,
        #{<<"user_id">> => 2, <<"card_uid">> => <<"C2">>}),
    {ok, _} = rpc(RPC, <<"/card/assign">>,
        #{<<"user_id">> => 2, <<"card_uid">> => <<"C3">>}),

    {ok, #{<<"cards">> := Cards}} =
        rpc(RPC, <<"/card/list_by_user">>, #{<<"user_id">> => 2}),
    ?assertEqual(3, length(Cards)),

    {ok, #{<<"cards">> := Deleted}} =
        rpc(RPC, <<"/card/delete_all_by_user">>, #{<<"user_id">> => 2}),
    ?assertEqual(3, length(Deleted)),

    {ok, #{<<"cards">> := []}} =
        rpc(RPC, <<"/card/list_by_user">>, #{<<"user_id">> => 2}).

%% touch a card that was never assigned
touch_unknown_card(Config) ->
    RPC = ?config(rpc, Config),
    {error, <<"card_not_found">>, _} = rpc(RPC, <<"/card/touch">>, #{<<"card_uid">> => <<"ZZ:ZZ">>}).

%% assigning the same card_uid twice
duplicate_assign(Config) ->
    RPC = ?config(rpc, Config),
    {ok, _} = rpc(RPC, <<"/card/assign">>, #{<<"user_id">> => 3, <<"card_uid">> => <<"DD:EE">>}),
    {error, <<"already_assigned">>, _} =
        rpc(RPC, <<"/card/assign">>, #{<<"user_id">> => 4, <<"card_uid">> => <<"DD:EE">>}).

%% two punches in the same direction on the same day → unique constraint
already_punched(Config) ->
    RPC = ?config(rpc, Config),
    {ok, _} = rpc(RPC, <<"/card/assign">>, #{<<"user_id">> => 5, <<"card_uid">> => <<"FF:FF">>}),
    {ok, #{<<"direction">> := <<"in">>}} = rpc(RPC, <<"/card/touch">>, #{<<"card_uid">> => <<"FF:FF">>}),

    %% insert a second "in" on a past date — doesn't conflict with today's "in"
    wt_test_db:punch_at(<<"FF:FF">>, 5, <<"in">>, {2024, 1, 8}, 11, 0),
    %% last direction is still "in" (today), so next touch → "out", succeeds
    {ok, #{<<"direction">> := <<"out">>}} = rpc(RPC, <<"/card/touch">>, #{<<"card_uid">> => <<"FF:FF">>}),
    %% last direction is now "out", next would be "in", but today already has "in" → conflict
    {error, <<"already_punched">>, _} = rpc(RPC, <<"/card/touch">>, #{<<"card_uid">> => <<"FF:FF">>}).

%%======================================================================================================
%% INTERNAL
%%======================================================================================================

rpc(RPC, Method, Params) -> wt_test_rpc:call(RPC, Method, Params).
