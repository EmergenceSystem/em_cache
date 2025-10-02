%%%-------------------------------------------------------------------
%%% @doc
%%% em_cache: HTTP cache API using Wade and Redis.
%%%
%%% Provides /query and /cache endpoints to store and retrieve JSON-encoded
%%% embryo lists. Integrates with Redis for persistence.
%%%
%%% Features:
%%%  - Automatic port discovery (8000–9000)
%%%  - JSON encoding/decoding with jsx
%%%  - Robust request body parsing
%%%  - Wade HTTP server integration
%%%-------------------------------------------------------------------

-module(em_cache).

%% API
-export([start/0, init/0]).

%% Internal functions for testing and Wade routes
-export([
    add_to_cache/2, generate_embryo_list/1, register_filter/0,
    json_to_embryo_list/1, embryo_list_to_json/1,
    register_routes/0, query_handler/1, cache_handler/1
]).

-include_lib("wade/include/wade.hrl").

%%-------------------------------------------------------------------
%% Records
%%-------------------------------------------------------------------
-record(embryo, {properties}).
-record(embryo_list, {embryo_list}).

%%%-------------------------------------------------------------------
%%% API
%%%-------------------------------------------------------------------

-spec start() -> ok | {error, any()}.
start() ->
    init().

-spec init() -> ok | {error, any()}.
init() ->
    %% Ensure required applications are started
    application:ensure_all_started(eredis),
    application:ensure_all_started(jsx),

    %% Find available TCP port
    {ok, Port} = find_port(),

    %% Start Wade HTTP server
    {ok, _Pid} = wade:start_link(Port),

    %% Register routes
    register_routes(),

    io:format("[INFO] em_cache started on port ~p~n", [Port]),

    %% Register service with discovery (stub)
    register_filter(),

    ok.

%%-------------------------------------------------------------------
%% HTTP route registration
%%-------------------------------------------------------------------
-spec register_routes() -> ok.
register_routes() ->
    wade:route(post, "/query", fun ?MODULE:query_handler/1, []),
    wade:route(post, "/cache", fun ?MODULE:cache_handler/1, []),
    ok.

%%%-------------------------------------------------------------------
%%% WADE HTTP Handlers
%%%-------------------------------------------------------------------

%% @doc Handles POST /query requests
-spec query_handler(#req{}) -> {integer(), binary(), [{string(), string()}]}.
query_handler(Req) ->
    Body = wade:body(Req, "body", <<>>), %% get body as binary
    EmbryoList = generate_embryo_list(Body),
    JsonResponse = jsx:encode(embryo_list_to_json(EmbryoList)),
    {200, JsonResponse, [{"content-type", "application/json"}]}.

%% @doc Handles POST /cache requests
-spec cache_handler(#req{}) -> {integer(), binary(), [{string(), string()}]}.
cache_handler(Req) ->
    Body = wade:body(Req, "body", <<>>),
    Data = jsx:decode(Body, [return_maps]),
    Query = maps:get(<<"query">>, Data),
    ResultJson = maps:get(<<"results">>, Data),

    Result = case is_binary(ResultJson) of
        true -> json_to_embryo_list(ResultJson);
        false -> json_to_embryo_list(ResultJson)
    end,

    %% Store in Redis
    ok = add_to_cache(Query, Result),

    {200, Query, [{"content-type", "text/plain"}]}.

%%%-------------------------------------------------------------------
%%% INTERNAL FUNCTIONS
%%%-------------------------------------------------------------------

%% @doc Add query/results to Redis cache
-spec add_to_cache(binary(), #embryo_list{}) -> ok.
add_to_cache(Query, Results) ->
    {ok, Redis} = eredis:start_link(),
    JsonResults = jsx:encode(embryo_list_to_json(Results)),
    {ok, <<"OK">>} = eredis:q(Redis, ["SET", Query, JsonResults]),
    eredis:stop(Redis),
    ok.

%% @doc Retrieve query results from Redis
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

%% @doc Find available TCP port between 8000–9000
-spec find_port() -> {ok, integer()} | {error, any()}.
find_port() -> find_port_from(8000).

find_port_from(Port) when Port < 9000 ->
    case gen_tcp:listen(Port, []) of
        {ok, Socket} ->
            gen_tcp:close(Socket),
            {ok, Port};
        {error, _} -> find_port_from(Port + 1)
    end;
find_port_from(_) ->
    {error, no_available_port}.

%% @doc Stub for service discovery registration
-spec register_filter() -> ok.
register_filter() -> ok.

%%%-------------------------------------------------------------------
%%% JSON <-> Embryo list conversion
%%%-------------------------------------------------------------------

-spec json_to_embryo_list(binary() | map()) -> #embryo_list{}.
json_to_embryo_list(Json) when is_binary(Json) ->
    Data = jsx:decode(Json, [return_maps]),
    json_to_embryo_list(Data);
json_to_embryo_list(#{<<"embryo_list">> := EmbryoList}) ->
    #embryo_list{embryo_list = [json_to_embryo(E) || E <- EmbryoList]};
json_to_embryo_list(#{<<"query">> := _, <<"results">> := Results}) ->
    json_to_embryo_list(Results);
json_to_embryo_list(_) ->
    #embryo_list{embryo_list = []}.

-spec json_to_embryo(map()) -> #embryo{}.
json_to_embryo(#{<<"properties">> := Properties}) ->
    #embryo{properties = Properties}.

-spec embryo_list_to_json(#embryo_list{}) -> map().
embryo_list_to_json(#embryo_list{embryo_list = List}) ->
    #{<<"embryo_list">> => [embryo_to_json(E) || E <- List]}.

-spec embryo_to_json(#embryo{}) -> map().
embryo_to_json(#embryo{properties = Properties}) ->
    #{<<"properties">> => Properties}.

