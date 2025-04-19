-module(em_cache).

-export([start/0, init/0]).

-include_lib("kernel/include/logger.hrl").

%% API exports for handlers
-export([query_handler/2, cache_handler/2]).

%% Internal functions exported for testing
-export([add_to_cache/2, generate_embryo_list/1, register_filter/0, 
         json_to_embryo_list/1, embryo_list_to_json/1]).

%% Records
-record(embryo, {properties}).
-record(embryo_list, {embryo_list}).

%%====================================================================
%% API functions
%%====================================================================

%% @doc Start the HTTP server
start() ->
    init().

%% @doc Initialize the application
init() ->
    application:ensure_all_started(cowboy),
    application:ensure_all_started(eredis),
    application:ensure_all_started(jsx),
    
    case find_port() of
        {ok, Port} ->
            FilterUrl = io_lib:format("http://localhost:~B/query", [Port]),
            io:format("Filter registered: ~s~n", [FilterUrl]),
            register_filter(),
            
            Dispatch = cowboy_router:compile([
                {'_', [
                    {"/query", em_cache, query},
                    {"/cache", em_cache, cache}
                ]}
            ]),
            
            {ok, _} = cowboy:start_clear(
                em_cache_http_listener,
                [{port, Port}],
                #{env => #{dispatch => Dispatch}}
            ),
            
            {ok, Port};
        {error, Reason} ->
            io:format("Can't start: ~p~n", [Reason]),
            {error, Reason}
    end.

%%====================================================================
%% Cowboy Handler Callbacks
%%====================================================================

%% @doc Query handler - looks in cache for query and returns results
query_handler(Req, query) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req),
    EmbryoList = generate_embryo_list(Body),
    
    JsonResponse = jsx:encode(embryo_list_to_json(EmbryoList)),
    
    Req2 = cowboy_req:reply(200, 
                           #{<<"content-type">> => <<"application/json">>}, 
                           JsonResponse, 
                           Req1),
    {ok, Req2, query}.

%% @doc Cache handler - stores query+result in cache and returns query key
cache_handler(Req, cache) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req),
    Data = jsx:decode(Body, [return_maps]),
    
    Query = maps:get(<<"query">>, Data),
    ResultJson = maps:get(<<"results">>, Data),
    
    % Convert ResultJson to embryo_list
    Result = case is_binary(ResultJson) of
        true -> 
            % It's already a binary/JSON string
            json_to_embryo_list(ResultJson);
        false -> 
            % It's already a map/object
            json_to_embryo_list(ResultJson)
    end,
    
    ok = add_to_cache(Query, Result),
    
    Req2 = cowboy_req:reply(200, 
                           #{<<"content-type">> => <<"text/plain">>}, 
                           Query, 
                           Req1),
    {ok, Req2, cache}.

%%====================================================================
%% Internal functions
%%====================================================================

%% @doc Add query and results to Redis cache
add_to_cache(Query, Results) ->
    {ok, Redis} = eredis:start_link(),
    JsonResults = jsx:encode(embryo_list_to_json(Results)),
    {ok, <<"OK">>} = eredis:q(Redis, ["SET", Query, JsonResults]),
    eredis:stop(Redis),
    ok.

%% @doc Generate embryo list from query in cache
generate_embryo_list(JsonString) ->
    Data = jsx:decode(JsonString, [return_maps]),
    Query = maps:get(<<"query">>, Data),
    
    {ok, Redis} = eredis:start_link(),
    case eredis:q(Redis, ["GET", Query]) of
        {ok, Result} when Result /= undefined ->
            eredis:stop(Redis),
            json_to_embryo_list(Result);
        _ ->
            eredis:stop(Redis),
            #embryo_list{embryo_list = []}
    end.

%% @doc Find an available port
find_port() ->
    % Start with port 8000 and try sequentially if occupied
    find_port_from(8000).

find_port_from(Port) when Port < 9000 ->
    case gen_tcp:listen(Port, []) of
        {ok, Socket} ->
            gen_tcp:close(Socket),
            {ok, Port};
        {error, _} ->
            find_port_from(Port + 1)
    end;
find_port_from(_) ->
    {error, no_available_port}.

%% @doc Register this filter with the main service
register_filter() ->
    % This is a placeholder - would need to be implemented based on em_filter module
    % from the original code
    ok.

%%====================================================================
%% Conversion Helper Functions
%%====================================================================

%% @doc Convert from JSON to embryo_list record
json_to_embryo_list(Json) when is_binary(Json) ->
    Data = jsx:decode(Json, [return_maps]),
    json_to_embryo_list(Data);
json_to_embryo_list(#{<<"embryo_list">> := EmbryoList}) ->
    #embryo_list{
        embryo_list = [json_to_embryo(Embryo) || Embryo <- EmbryoList]
    };
%% Handle the case when we receive a map with query and results
json_to_embryo_list(#{<<"query">> := _, <<"results">> := Results}) ->
    % Extract results and process them as a string
    json_to_embryo_list(Results);
%% Fallback case
json_to_embryo_list(_) ->
    % Return an empty embryo list if we can't parse
    #embryo_list{embryo_list = []}.

%% @doc Convert from JSON to embryo record
json_to_embryo(#{<<"properties">> := Properties}) ->
    #embryo{properties = Properties}.

%% @doc Convert from embryo_list record to JSON
embryo_list_to_json(#embryo_list{embryo_list = EmbryoList}) ->
    #{
        <<"embryo_list">> => [embryo_to_json(Embryo) || Embryo <- EmbryoList]
    }.

%% @doc Convert from embryo record to JSON
embryo_to_json(#embryo{properties = Properties}) ->
    #{
        <<"properties">> => Properties
    }.
