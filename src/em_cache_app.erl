%%%-------------------------------------------------------------------
%%% @doc em_cache application entry point.
%%%
%%% Starts the supervisor (which owns the ETS cache + Redis lifecycle)
%%% then a Cowboy server on the configured port (`[env] port',
%%% default 8300) with:
%%%   POST /query  — retrieve a cached embryo list
%%%   POST /cache  — store an embryo list (optional `ttl' field)
%%%   GET  /health — backend health + hit/miss stats
%%% @end
%%%-------------------------------------------------------------------
-module(em_cache_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    {ok, Sup} = em_cache_sup:start_link(),
    Port = application:get_env(em_cache, port, 8300),
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/query",  em_cache_query_handler, []},
            {"/cache",  em_cache_store_handler, []},
            {"/health", em_cache_health_handler, []}
        ]}
    ]),
    {ok, _} = cowboy:start_clear(em_cache_listener,
        [{port, Port}],
        #{env => #{dispatch => Dispatch}}),
    io:format("[em_cache] started on port ~p~n", [Port]),
    {ok, Sup}.

stop(_State) ->
    catch cowboy:stop_listener(em_cache_listener),
    ok.
