%%%-------------------------------------------------------------------
%%% @doc Cowboy handler for POST /query.
%%%
%%% Reads {"query": "..."} from the request body and returns the
%%% cached embryo list from Redis, or an empty list on miss.
%%% @end
%%%-------------------------------------------------------------------
-module(em_cache_query_handler).

-export([init/2]).

init(Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Response = handle(Body),
    Req2 = cowboy_req:reply(200,
        #{<<"content-type">> => <<"application/json">>},
        Response, Req1),
    {ok, Req2, State}.

handle(Body) ->
    Query = decode_query(Body),
    EmbryoList = case em_cache:get_from_cache(Query) of
        {ok, List} -> List;
        {miss, []} -> []
    end,
    iolist_to_binary(json:encode(#{<<"embryo_list">> => EmbryoList})).

decode_query(Body) ->
    try json:decode(Body) of
        #{<<"query">> := Q} when is_binary(Q) -> Q;
        _                                     -> <<>>
    catch
        _:_ -> <<>>
    end.
