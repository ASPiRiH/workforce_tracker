-module(wt_router).

-export([dispatch/2]).

-spec dispatch(binary(), map()) -> {ok, map()} | {error, atom(), binary()}.
dispatch(<<"/card/assign">>, P) ->
    wt_cards:assign(P);
dispatch(<<"/card/touch">>, P) ->
    wt_cards:touch(P);
dispatch(<<"/card/delete">>, P) ->
    wt_cards:delete(P);
dispatch(<<"/card/list_by_user">>, P) ->
    wt_cards:list(P);
dispatch(<<"/card/delete_all_by_user">>, P) ->
    wt_cards:delete_all(P);
dispatch(<<"/work_time/set">>, P) ->
    wt_schedule:set_profile(P);
dispatch(<<"/work_time/get">>, P) ->
    wt_schedule:get_profile(P);
dispatch(<<"/work_time/add_exclusion">>, P) ->
    wt_schedule:add_override(P);
dispatch(<<"/work_time/get_exclusion">>, P) ->
    wt_schedule:get_overrides(P);
dispatch(<<"/work_time/history_by_user">>, P) ->
    wt_stats:history(P);
dispatch(<<"/work_time/statistics_by_user">>, P) ->
    wt_stats:statistics(P);
dispatch(Method, _P) ->
    {error, not_found, <<"Unknown method: ", Method/binary>>}.
