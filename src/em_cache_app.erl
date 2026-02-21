%%%-------------------------------------------------------------------
%%% @doc em_cache application entry point.
%%%
%%% Starts a Cowboy HTTP server on an available port (8000-9000)
%%% with two endpoints:
%%%   POST /query  — retrieve cached embryo list from Redis
%%%   POST /cache  — store embryo list in Redis
%%% @end
%%%-------------------------------------------------------------------
-module(em_cache_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    {ok, Port} = find_port(8000),
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/query", em_cache_query_handler, []},
            {"/cache", em_cache_store_handler, []}
        ]}
    ]),
    {ok, _} = cowboy:start_clear(em_cache_listener,
        [{port, Port}],
        #{env => #{dispatch => Dispatch}}
    ),
    io:format("[em_cache] started on port ~p~n", [Port]),
    em_cache_sup:start_link().

stop(_State) ->
    cowboy:stop_listener(em_cache_listener).

find_port(Port) when Port >= 9000 -> {error, no_available_port};
find_port(Port) ->
    case gen_tcp:listen(Port, []) of
        {ok, S}   -> gen_tcp:close(S), {ok, Port};
        {error, _} -> find_port(Port + 1)
    end.
