%%%-------------------------------------------------------------------
%%% @doc Cowboy handler for GET /health. Returns backend health and
%%% cumulative hit/miss stats as JSON.
%%% @end
%%%-------------------------------------------------------------------
-module(em_cache_health_handler).

-export([init/2]).

init(Req0, State) ->
    Payload = maps:merge(em_cache_store:health(), em_cache_store:stats()),
    Body = iolist_to_binary(json:encode(Payload)),
    Req1 = cowboy_req:reply(200,
        #{<<"content-type">> => <<"application/json">>}, Body, Req0),
    {ok, Req1, State}.
