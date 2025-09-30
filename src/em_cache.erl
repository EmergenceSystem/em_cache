%%%-------------------------------------------------------------------
%%% em_cache: HTTP cache API with Redis and Wade server.
%%%-------------------------------------------------------------------

-module(em_cache).

%% API
-export([start/0, init/0]).

%% Internal functions exported for testing
-export([
    add_to_cache/2, generate_embryo_list/1, register_filter/0,
    json_to_embryo_list/1, embryo_list_to_json/1,
    register_routes/0
]).

%% Handler functions for Wade
-export([query_handler/1, cache_handler/1]).

-include_lib("wade/include/wade.hrl").

-record(embryo, {properties}).
-record(embryo_list, {embryo_list}).

%%% ====================
%%% API
%%% ====================

%% @doc Start the HTTP server and register Wade routes.
-spec start() -> ok | {error, any()}.
start() -> init().

-spec init() -> ok | {error, any()}.
init() ->
    application:ensure_all_started(eredis),
    application:ensure_all_started(jsx),
    {ok, Port} = find_port(),
    {ok, _Pid} = wade:start_link(Port),
    register_routes(),
    io:format("Started em_cache on port ~p~n", [Port]),
    register_filter(),
    ok.

%% @doc Register HTTP POST routes for /query and /cache.
-spec register_routes() -> ok.
register_routes() ->
    wade:route(post, "/query", fun ?MODULE:query_handler/1, []),
    wade:route(post, "/cache", fun ?MODULE:cache_handler/1, []),
    ok.

%%% =========================
%%% WADE HTTP HANDLERS
%%% =========================

%% @doc Handler for POST /query.
-spec query_handler(#req{}) -> {integer(), binary(), [{string(), string()}]}.
query_handler(Req) ->
    Body = wade:body(Req, "body", <<>>), %% Body as binary
    EmbryoList = generate_embryo_list(Body),
    JsonResponse = jsx:encode(embryo_list_to_json(EmbryoList)),
    {200, JsonResponse, [{"content-type", "application/json"}]}.

%% @doc Handler for POST /cache.
-spec cache_handler(#req{}) -> {integer(), binary(), [{string(), string()}]}.
cache_handler(Req) ->
    Body = wade:body(Req, "body", <<>>),
    Data = jsx:decode(Body, [return_maps]),
    Query = maps:get(<<"query">>, Data),
    ResultJson = maps:get(<<"results">>, Data),

    Result = case is_binary(ResultJson) of
        true  -> json_to_embryo_list(ResultJson);
        false -> json_to_embryo_list(ResultJson)
    end,

    ok = add_to_cache(Query, Result),
    {200, Query, [{"content-type", "text/plain"}]}.

%%% ====================
%%% INTERNALS
%%% ====================

%% @doc Add query/results to Redis as JSON.
-spec add_to_cache(binary(), #embryo_list{}) -> ok.
add_to_cache(Query, Results) ->
    {ok, Redis} = eredis:start_link(),
    JsonResults = jsx:encode(embryo_list_to_json(Results)),
    {ok, <<"OK">>} = eredis:q(Redis, ["SET", Query, JsonResults]),
    eredis:stop(Redis),
    ok.

%% @doc Fetch query result from cache, decode to embryo_list record.
-spec generate_embryo_list(binary()) -> #embryo_list{}.
generate_embryo_list(JsonString) ->
    Data = jsx:decode(JsonString, [return_maps]),
    Query = maps:get(<<"query">>, Data),
    {ok, Redis} = eredis:start_link(),
    Result = case eredis:q(Redis, ["GET", Query]) of
        {ok, Value} when Value /= undefined -> Value;
        _ -> undefined
    end,
    eredis:stop(Redis),
    case Result of
        undefined -> #embryo_list{embryo_list = []};
        _ -> json_to_embryo_list(Result)
    end.

%% @doc Find an available TCP port for Wade.
-spec find_port() -> {ok, integer()} | {error, any()}.
find_port() -> find_port_from(8000).
find_port_from(Port) when Port < 9000 ->
    case gen_tcp:listen(Port, []) of
        {ok, Socket} ->
            gen_tcp:close(Socket),
            {ok, Port};
        {error, _} -> find_port_from(Port + 1)
    end;
find_port_from(_) -> {error, no_available_port}.

%% @doc Dummy stub (implement real integration as needed).
-spec register_filter() -> ok.
register_filter() -> ok.

%%% =========================
%%% JSON/RECORD CONVERSION
%%% =========================

-spec json_to_embryo_list(binary() | map()) -> #embryo_list{}.
json_to_embryo_list(Json) when is_binary(Json) ->
    Data = jsx:decode(Json, [return_maps]),
    json_to_embryo_list(Data);
json_to_embryo_list(#{<<"embryo_list">> := EmbryoList}) ->
    #embryo_list{embryo_list = [json_to_embryo(Embryo) || Embryo <- EmbryoList]};
json_to_embryo_list(#{<<"query">> := _, <<"results">> := Results}) ->
    json_to_embryo_list(Results);
json_to_embryo_list(_) ->
    #embryo_list{embryo_list = []}.

-spec json_to_embryo(map()) -> #embryo{}.
json_to_embryo(#{<<"properties">> := Properties}) ->
    #embryo{properties = Properties}.

-spec embryo_list_to_json(#embryo_list{}) -> map().
embryo_list_to_json(#embryo_list{embryo_list = EmbryoList}) ->
    #{<<"embryo_list">> => [embryo_to_json(Embryo) || Embryo <- EmbryoList]}.

-spec embryo_to_json(#embryo{}) -> map().
embryo_to_json(#embryo{properties = Properties}) ->
    #{<<"properties">> => Properties}.


