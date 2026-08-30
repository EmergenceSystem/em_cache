%%%-------------------------------------------------------------------
%%% @doc Cowboy handler for POST /cache. Body
%%% `{"query": "...", "results": {"embryo_list": [...]}, "ttl": N?}'.
%%% `ttl' (seconds) is optional; the store default is used when absent.
%%% @end
%%%-------------------------------------------------------------------
-module(em_cache_store_handler).

-export([init/2]).

init(Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    {Status, Response} = handle(Body),
    Req2 = cowboy_req:reply(Status,
        #{<<"content-type">> => <<"application/json">>}, Response, Req1),
    {ok, Req2, State}.

handle(Body) ->
    try json:decode(Body) of
        #{<<"query">> := Query, <<"results">> := Results}
                when is_binary(Query) ->
            EmbryoList = extract_embryo_list(Results),
            ok = put(Query, EmbryoList, Body),
            {200, iolist_to_binary(json:encode(
                #{<<"status">> => <<"ok">>, <<"query">> => Query}))};
        _ ->
            {400, iolist_to_binary(json:encode(#{<<"error">> => <<"invalid body">>}))}
    catch _:_ ->
        {400, iolist_to_binary(json:encode(#{<<"error">> => <<"invalid json">>}))}
    end.

put(Query, List, Body) ->
    case ttl(Body) of
        undefined -> em_cache:put_in_cache(Query, List);
        Ttl       -> em_cache:put_in_cache(Query, List, Ttl)
    end.

ttl(Body) ->
    case catch json:decode(Body) of
        #{<<"ttl">> := N} when is_integer(N), N > 0 -> N;
        _ -> undefined
    end.

extract_embryo_list(#{<<"embryo_list">> := List}) when is_list(List) -> List;
extract_embryo_list(_) -> [].
