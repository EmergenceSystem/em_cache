%%%-------------------------------------------------------------------
%%% @doc Cowboy handler for POST /cache.
%%%
%%% Reads {"query": "...", "results": {"embryo_list": [...]}} and
%%% stores the embryo list in Redis under the query key.
%%% @end
%%%-------------------------------------------------------------------
-module(em_cache_store_handler).

-export([init/2]).

init(Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    {Status, Response} = handle(Body),
    Req2 = cowboy_req:reply(Status,
        #{<<"content-type">> => <<"application/json">>},
        Response, Req1),
    {ok, Req2, State}.

handle(Body) ->
    try json:decode(Body) of
        #{<<"query">> := Query, <<"results">> := Results}
                when is_binary(Query) ->
            EmbryoList = extract_embryo_list(Results),
            case em_cache:put_in_cache(Query, EmbryoList) of
                ok ->
                    {200, iolist_to_binary(
                        json:encode(#{<<"status">> => <<"ok">>,
                                      <<"query">>  => Query}))};
                {error, Reason} ->
                    {500, iolist_to_binary(
                        json:encode(#{<<"error">> => iolist_to_binary(
                            io_lib:format("~p", [Reason]))}))}
            end;
        _ ->
            {400, iolist_to_binary(json:encode(#{<<"error">> => <<"invalid body">>}))}
    catch
        _:_ ->
            {400, iolist_to_binary(json:encode(#{<<"error">> => <<"invalid json">>}))}
    end.

extract_embryo_list(#{<<"embryo_list">> := List}) when is_list(List) -> List;
extract_embryo_list(_) -> [].
