%%%-------------------------------------------------------------------
%%% @doc em_cache — query result cache (public API).
%%%
%%% Wraps `em_cache_store' (L1 ETS + optional L2 Redis) with query-key
%%% normalisation: the raw query is lower-cased, whitespace-collapsed
%%% and SHA-256 hashed into a namespaced key, so `"Cat"', `"cat "' and
%%% `"cat"' share one entry and arbitrary/unicode queries make safe
%%% keys.
%%%
%%% Backwards-compatible with the original API: `get_from_cache/1'
%%% returns `{ok, List}' or `{miss, []}'; `put_in_cache/2' stores an
%%% embryo list. `put_in_cache/3' takes an explicit TTL.
%%% @end
%%%-------------------------------------------------------------------
-module(em_cache).

-export([get_from_cache/1, put_in_cache/2, put_in_cache/3, key/1]).

%% @doc Retrieve a cached embryo list, or `{miss, []}'.
-spec get_from_cache(binary()) -> {ok, list()} | {miss, []}.
get_from_cache(Query) ->
    case em_cache_store:get(key(Query)) of
        {ok, Json} -> decode(Json);
        miss       -> {miss, []}
    end.

%% @doc Store an embryo list under a query key (default TTL).
-spec put_in_cache(binary(), list()) -> ok.
put_in_cache(Query, EmbryoList) ->
    put_in_cache(Query, EmbryoList, em_cache_store:default_ttl()).

%% @doc Store an embryo list with an explicit TTL (seconds).
-spec put_in_cache(binary(), list(), pos_integer()) -> ok.
put_in_cache(Query, EmbryoList, TtlSec) ->
    Json = iolist_to_binary(json:encode(#{<<"embryo_list">> => EmbryoList})),
    em_cache_store:put(key(Query), Json, TtlSec).

%% @doc Namespaced, normalised, hashed cache key for a raw query.
-spec key(binary()) -> binary().
key(Query) ->
    Norm = normalize(Query),
    Hex  = binary:encode_hex(crypto:hash(sha256, Norm), lowercase),
    <<"emq:q:v1:", Hex/binary>>.

%%====================================================================
%% Internal
%%====================================================================

%% @private
decode(Json) ->
    try json:decode(Json) of
        #{<<"embryo_list">> := List} when is_list(List) -> {ok, List};
        _ -> {miss, []}
    catch _:_ -> {miss, []} end.

%% @private lower-case, trim, collapse internal whitespace.
normalize(Query) when is_binary(Query) ->
    Lower = string:lowercase(Query),
    Trim  = string:trim(Lower),
    re:replace(Trim, <<"\\s+">>, <<" ">>,
               [global, unicode, {return, binary}]);
normalize(_) -> <<>>.
