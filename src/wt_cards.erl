-module(wt_cards).

-export([
    assign/1,
    touch/1,
    delete/1,
    list/1,
    delete_all/1
]).

-type result() :: {ok, map()} | {error, atom(), binary()}.

%%======================================================================================================
%% API
%%======================================================================================================

-spec assign(map()) -> result().
assign(#{<<"user_id">> := UserId, <<"card_uid">> := CardUID}) ->
    maybe
        {ok, _} ?= wt_db:assign_card(CardUID, UserId),
        {ok, #{card_uid => CardUID, user_id => UserId}}
    else
        {error, conflict} ->
            {error, already_assigned, <<"Card is already assigned">>};
        {error, Reason} ->
            {error, internal, wt_codec:fmt(Reason)}
    end.

-spec touch(map()) -> result().
touch(#{<<"card_uid">> := CardUID}) ->
    maybe
        {ok, [{UserId}]} ?= wt_db:find_active_card(CardUID),
        Direction         = wt_db:last_punch_direction(UserId),
        ok               ?= wt_db:insert_punch(CardUID, UserId, Direction),
        {ok, #{card_uid => CardUID, user_id => UserId, direction => Direction}}
    else
        {ok, []} ->
            {error, card_not_found, <<"Card not registered">>};
        {error, conflict} ->
            {error, already_punched, <<"Already punched today">>};
        {error, Reason} ->
            {error, internal, wt_codec:fmt(Reason)}
    end.

-spec delete(map()) -> result().
delete(#{<<"card_uid">> := CardUID}) ->
    maybe
        {ok, [{UserId, CardUID}]} ?= wt_db:deactivate_card(CardUID),
        {ok, #{card_uid => CardUID, user_id => UserId}}
    else
        {ok, []} ->
            {error, not_found, <<"Card not found">>};
        {error, Reason} ->
            {error, internal, wt_codec:fmt(Reason)}
    end.

-spec list(map()) -> result().
list(#{<<"user_id">> := UserId}) ->
    maybe
        {ok, Rows} ?= wt_db:list_active_cards(UserId),
        Cards = [C || {C} <- Rows],
        {ok, #{user_id => UserId, cards => Cards}}
    else
        {error, Reason} ->
            {error, internal, wt_codec:fmt(Reason)}
    end.

-spec delete_all(map()) -> result().
delete_all(#{<<"user_id">> := UserId}) ->
    maybe
        {ok, Rows} ?= wt_db:deactivate_all_cards(UserId),
        Cards = [C || {C} <- Rows],
        {ok, #{user_id => UserId, cards => Cards}}
    else
        {error, Reason} ->
            {error, internal, wt_codec:fmt(Reason)}
    end.
