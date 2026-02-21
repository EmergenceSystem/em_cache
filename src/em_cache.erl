%%%-------------------------------------------------------------------
%%% @doc em_cache: Redis-backed embryo list cache.
%%%
%%% Two Cowboy handlers:
%%%   POST /query  — look up embryo list by query key
%%%   POST /cache  — store embryo list under a query key
%%%
%%% Request body (both endpoints):
%%%   { "query": "...", "results": { "embryo_list": [...] } }
%%%
%%% Redis is opened per-request (eredis keeps a connection pool).
%%% @end
%%%-------------------------------------------------------------------
-module(em_cache).

-export([
    get_from_cache/1,
    put_in_cache/2
]).

%%====================================================================
%% Public API (used by handlers)
%%====================================================================

%% @doc Retrieve a cached embryo list. Returns {ok, List} or {miss, []}.
-spec get_from_cache(binary()) -> {ok, list()} | {miss, []}.
get_from_cache(Query) ->
    case redis_get(Query) of
        {ok, undefined} -> {miss, []};
        {ok, Json}      ->
            try json:decode(Json) of
                #{<<"embryo_list">> := List} when is_list(List) -> {ok, List};
                _                                                -> {miss, []}
            catch
                _:_ -> {miss, []}
            end;
        _ -> {miss, []}
    end.

%% @doc Store an embryo list under a query key.
-spec put_in_cache(binary(), list()) -> ok | {error, any()}.
put_in_cache(Query, EmbryoList) ->
    Json = iolist_to_binary(json:encode(#{<<"embryo_list">> => EmbryoList})),
    case redis_set(Query, Json) of
        {ok, <<"OK">>} -> ok;
        Error          -> Error
    end.

%%====================================================================
%% Redis helpers
%%====================================================================

redis_get(Key) ->
    {ok, Redis} = eredis:start_link(),
    Result = eredis:q(Redis, ["GET", Key]),
    eredis:stop(Redis),
    Result.

redis_set(Key, Value) ->
    {ok, Redis} = eredis:start_link(),
    Result = eredis:q(Redis, ["SET", Key, Value]),
    eredis:stop(Redis),
    Result.
