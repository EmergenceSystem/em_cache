-module(em_cache_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    em_cache:start(),
    {ok, self()}.

stop(_State) ->
    ok.
