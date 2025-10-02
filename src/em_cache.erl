%%%-------------------------------------------------------------------
%%% @doc
%%% em_cache: HTTP cache API using Wade and Redis.
%%%
%%% Provides /query and /cache endpoints to store and retrieve JSON-encoded
%%% embryo lists. Integrates with Redis for persistence.
%%%
%%% Features:
%%%  - Automatic TCP port discovery (8000–9000)
%%%  - JSON encoding/decoding with jsone
%%%  - Robust request body parsing (binary, map, or x-www-form-urlencoded)
%%%  - Wade HTTP server integration
%%%  - Redis cache persistence
%%%-------------------------------------------------------------------

-module(em_cache).

%% API
-export([start/0, init/0]).

%% Internal functions for Wade routes & testing
-export([
    add_to_cache/2,
    generate_embryo_list/1,
    register_filter/0,
    json_to_embryo_list/1,
    embryo_list_to_json/1,
    register_routes/0,
    query_handler/1,
    cache_handler/1
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
    %% Start required applications
    application:ensure_all_started(eredis),
    application:ensure_all_started(jsone),

    %% Find an available TCP port
    {ok, Port} = find_port(),

    %% Start Wade HTTP server
    {ok, _Pid} = wade:start_link(Port),

    %% Register HTTP routes
    register_routes(),

    io:format("[INFO] em_cache started on port ~p~n", [Port]),

    %% Register with service discovery (stub)
    register_filter(),

    ok.

%%-------------------------------------------------------------------
%%% HTTP route registration
%%%-------------------------------------------------------------------
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
    Body = wade:body(Req, "body", <<>>),
    EmbryoList = generate_embryo_list(Body),
    JsonResponse = jsone:encode(embryo_list_to_json(EmbryoList)),
    {200, JsonResponse, [{"content-type", "application/json"}]}.

%% @doc Handles POST /cache requests
-spec cache_handler(#req{}) -> {integer(), binary(), [{string(), string()}]}.
cache_handler(Req) ->
    Body = wade:body(Req, "body", <<>>),
    Data = decode_body_safe(Body),
    Query = maps:get(<<"query">>, Data, <<>>),
    ResultJson = maps:get(<<"results">>, Data, #{}),

    Result = decode_results_safe(ResultJson),

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
    JsonResults = jsone:encode(embryo_list_to_json(Results)),
    {ok, <<"OK">>} = eredis:q(Redis, ["SET", Query, JsonResults]),
    eredis:stop(Redis),
    ok.

%% @doc Retrieve query results from Redis
-spec generate_embryo_list(binary()) -> #embryo_list{}.
generate_embryo_list(JsonString) ->
    Data = decode_body_safe(JsonString),
    Query = maps:get(<<"query">>, Data, <<>>),
    {ok, Redis} = eredis:start_link(),
    Result = case eredis:q(Redis, ["GET", Query]) of
        {ok, Value} when Value /= undefined ->
            decode_results_safe(Value);
        _ ->
            #embryo_list{embryo_list = []}
    end,
    eredis:stop(Redis),
    Result.

%% @doc Safe decoding of request bodies (binary JSON, map, or fallback)
-spec decode_body_safe(binary() | map() | list()) -> map().
decode_body_safe(Body) when is_binary(Body) ->
    case catch jsone:decode(Body) of
        {'EXIT', _} -> #{}; %% invalid JSON fallback
        Map -> Map
    end;
decode_body_safe(Body) when is_map(Body) ->
    Body;
decode_body_safe(Body) when is_list(Body) ->
    %% Convert list of tuples [{key,value}] to map
    maps:from_list([{to_binary(K), to_binary(V)} || {K,V} <- Body]);
decode_body_safe(_) ->
    #{}.

%% @doc Safe decoding of stored results (binary JSON or map)
-spec decode_results_safe(binary() | map()) -> #embryo_list{}.
decode_results_safe(Bin) when is_binary(Bin) ->
    case catch jsone:decode(Bin) of
        {'EXIT', _} -> #embryo_list{embryo_list = []};
        Map -> json_to_embryo_list(Map)
    end;
decode_results_safe(Map) when is_map(Map) ->
    json_to_embryo_list(Map);
decode_results_safe(_) ->
    #embryo_list{embryo_list = []}.

%% @doc Find available TCP port 8000–9000
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
    case catch jsone:decode(Json) of
        {'EXIT', _} -> #embryo_list{embryo_list = []};
        Map -> json_to_embryo_list(Map)
    end;
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

%%-------------------------------------------------------------------
%% Utility: convert string/list to binary safely
%%-------------------------------------------------------------------
-spec to_binary(binary() | list() | atom() | integer()) -> binary().
to_binary(X) when is_binary(X) -> X;
to_binary(X) when is_list(X) -> list_to_binary(X);
to_binary(X) when is_atom(X) -> list_to_binary(atom_to_list(X));
to_binary(X) when is_integer(X) -> list_to_binary(io_lib:format("~p", [X])).
