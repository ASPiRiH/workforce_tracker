-module(wt_validator).

-export([init/0, validate/2]).
-export([time_str/3, datetime_str/3, date_str/3, override_kind/3, workdays_list/3]).

-define(OPTS, #{return => map}).

-spec init() -> ok.
init() ->
    ok = liver:add_rule(time_str,      wt_validator),
    ok = liver:add_rule(datetime_str,  wt_validator),
    ok = liver:add_rule(date_str,      wt_validator),
    ok = liver:add_rule(override_kind, wt_validator),
    ok = liver:add_rule(workdays_list, wt_validator).

%% Custom rules

-spec time_str(term(), term(), term()) -> {ok, binary()} | {error, wrong_format}.
time_str(_Args, Val, _Opts) when is_binary(Val) ->
    case re:run(Val, <<"^([01]\\d|2[0-3]):[0-5]\\d$">>) of
        {match, _} ->
            {ok, Val};
        nomatch ->
            {error, wrong_format}
    end;
time_str(_Args, _Val, _Opts) ->
    {error, wrong_format}.

-spec datetime_str(term(), term(), term()) -> {ok, binary()} | {error, wrong_format}.
datetime_str(_Args, Val, _Opts) when is_binary(Val) ->
    case re:run(Val, <<"^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}">>) of
        {match, _} ->
            {ok, Val};
        nomatch ->
            {error, wrong_format}
    end;
datetime_str(_Args, _Val, _Opts) ->
    {error, wrong_format}.

-spec date_str(term(), term(), term()) -> {ok, binary()} | {error, wrong_format}.
date_str(_Args, Val, _Opts) when is_binary(Val) ->
    case re:run(Val, <<"^\\d{4}-\\d{2}-\\d{2}$">>) of
        {match, _} ->
            {ok, Val};
        nomatch ->
            {error, wrong_format}
    end;
date_str(_Args, _Val, _Opts) ->
    {error, wrong_format}.

-spec override_kind(term(), term(), term()) -> {ok, binary()} | {error, not_allowed_value}.
override_kind(_Args, <<"late">>, _Opts) ->
    {ok, <<"late">>};
override_kind(_Args, <<"early">>, _Opts) ->
    {ok, <<"early">>};
override_kind(_Args, <<"day_off">>, _Opts) ->
    {ok, <<"day_off">>};
override_kind(_Args, _Val, _Opts) ->
    {error, not_allowed_value}.

-spec workdays_list(term(), term(), term()) -> {ok, [1..7]} | {error, wrong_format}.
workdays_list(_Args, Val, _Opts) when is_list(Val), Val =/= [] ->
    case lists:all(fun(D) -> is_integer(D) andalso D >= 1 andalso D =< 7 end, Val) of
        true ->
            {ok, Val};
        false ->
            {error, wrong_format}
    end;
workdays_list(_Args, _Val, _Opts) ->
    {error, wrong_format}.

%% Validation schemas per method

-spec validate(binary(), map()) -> {ok, map()} | {error, map()} | undefined.
validate(<<"/card/assign">>, Params) ->
    Schema = #{
        <<"user_id">> => [required, positive_integer],
        <<"card_uid">>    => [required, not_empty]
    },
    liver:validate(Schema, Params, ?OPTS);

validate(<<"/card/touch">>, Params) ->
    Schema = #{
        <<"card_uid">> => [required, not_empty]
    },
    liver:validate(Schema, Params, ?OPTS);

validate(<<"/card/delete">>, Params) ->
    Schema = #{
        <<"card_uid">> => [required, not_empty]
    },
    liver:validate(Schema, Params, ?OPTS);

validate(<<"/card/list_by_user">>, Params) ->
    Schema = #{
        <<"user_id">> => [required, positive_integer]
    },
    liver:validate(Schema, Params, ?OPTS);

validate(<<"/card/delete_all_by_user">>, Params) ->
    Schema = #{
        <<"user_id">> => [required, positive_integer]
    },
    liver:validate(Schema, Params, ?OPTS);

validate(<<"/work_time/set">>, Params) ->
    Schema = #{
        <<"user_id">> => [required, positive_integer],
        <<"start_time">>  => [required, time_str],
        <<"end_time">>    => [required, time_str],
        <<"days">>        => [required, workdays_list]
    },
    liver:validate(Schema, Params, ?OPTS);

validate(<<"/work_time/get">>, Params) ->
    Schema = #{
        <<"user_id">> => [required, positive_integer]
    },
    liver:validate(Schema, Params, ?OPTS);

validate(<<"/work_time/add_exclusion">>, Params) ->
    Schema = #{
        <<"user_id">>    => [required, positive_integer],
        <<"type_exclusion">> => [required, override_kind],
        <<"start_datetime">> => [required, datetime_str],
        <<"end_datetime">>   => [required, datetime_str]
    },
    liver:validate(Schema, Params, ?OPTS);

validate(<<"/work_time/get_exclusion">>, Params) ->
    Schema = #{
        <<"user_id">> => [required, positive_integer]
    },
    liver:validate(Schema, Params, ?OPTS);

validate(<<"/work_time/history_by_user">>, Params) ->
    Schema = #{
        <<"user_id">> => [required, positive_integer]
    },
    liver:validate(Schema, Params, ?OPTS);

validate(<<"/work_time/statistics_by_user">>, Params) ->
    Schema = #{
        <<"user_id">> => [required, positive_integer],
        <<"period">>      => [{default, <<"month">>}, {one_of, [<<"week">>, <<"month">>, <<"year">>, <<"all">>]}],
        <<"start_date">>  => [date_str],
        <<"end_date">>    => [date_str]
    },
    liver:validate(Schema, Params, ?OPTS);

validate(_, _) ->
    undefined.
