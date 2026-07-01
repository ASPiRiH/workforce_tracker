-module(wt_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

-spec start_link() -> {ok, pid()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    Env    = application:get_all_env(workforce_tracker),
    DbConfig = env_override(proplists:get_value(db,   Env, []), db),
    MqConfig = env_override(proplists:get_value(amqp, Env, []), amqp),
    Pool = poolboy:child_spec(wt_db_pool,
        [{name,           {local, wt_db_pool}},
         {worker_module,  wt_db_worker},
         {size,           proplists:get_value(pool_size, DbConfig, 5)},
         {max_overflow,   2}],
        DbConfig),
    Mq = #{
        id     => wt_mq,
       start   => {wt_mq, start_link, [MqConfig]},
       restart => permanent,
       type    => worker},
    {ok, {{one_for_one, 5, 10}, [Pool, Mq]}}.

env_override(Cfg, db) ->
    Cfg1 = maybe_setenv(Cfg, host, "PG_HOST", host),
    Cfg2 = maybe_setenv(Cfg1, password, "PG_PASSWORD", password),
    Cfg2;
env_override(Cfg, amqp) ->
    maybe_setenv(Cfg, host, "AMQP_HOST", host).

maybe_setenv(Cfg, _Key, EnvVar, CfgKey) ->
    case os:getenv(EnvVar) of
        false -> Cfg;
        Val   -> lists:keystore(CfgKey, 1, Cfg, {CfgKey, Val})
    end.
