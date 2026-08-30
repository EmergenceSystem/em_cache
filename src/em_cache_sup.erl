%%%-------------------------------------------------------------------
%%% @doc em_cache supervisor. Supervises the cache store (ETS table
%%% owner + Redis connection lifecycle).
%%% @end
%%%-------------------------------------------------------------------
-module(em_cache_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Store = #{id      => em_cache_store,
              start   => {em_cache_store, start_link, []},
              restart => permanent,
              type    => worker},
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, [Store]}}.
