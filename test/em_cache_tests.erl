-module(em_cache_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("wade/include/wade.hrl").

-record(embryo, {properties}).
-record(embryo_list, {embryo_list}).

%% -----------------------------
%% Setup / Teardown
%% -----------------------------
setup() ->
    meck:new(wade, [passthrough, non_strict]),
    meck:new(eredis, [non_strict]),
    %% Ne pas mocker jsone, laisser la vraie implémentation
    ok.

teardown(_) ->
    meck:unload(),
    ok.

%% -----------------------------
%% Helpers
%% -----------------------------
make_embryo_list() ->
    #embryo_list{
        embryo_list = [
            #embryo{
                properties = #{
                    <<"url">> => <<"https://www.speedtest.net/">>,
                    <<"resume">> => <<"Speedtest by Ookla is a global broadband speed test.">>
                }
            }
        ]
    }.

make_json_results(EmbryoList) ->
    jsone:encode(em_cache:embryo_list_to_json(EmbryoList)).

%% -----------------------------
%% Cache handler test
%% -----------------------------
cache_handler_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     fun() ->
        EmptyReq = #req{},
        EmbryoList = make_embryo_list(),
        JsonResults = make_json_results(EmbryoList),

        %% Mock Wade body - retourner le JSON comme binaire
        RequestBody = jsone:encode(#{
            <<"query">> => <<"test">>, 
            <<"results">> => jsone:decode(JsonResults)
        }),
        
        meck:expect(wade, body, fun(_Req, "body", _) ->
            RequestBody
        end),

        %% Mock Redis
        meck:expect(eredis, start_link, fun() -> {ok, mock_connection} end),
        meck:expect(eredis, q, fun(mock_connection, ["SET", Key, _JsonResults]) when is_binary(Key) ->
            {ok, <<"OK">>}
        end),
        meck:expect(eredis, stop, fun(_) -> ok end),

        {Status, Body, Headers} = em_cache:cache_handler(EmptyReq),

        ?assertEqual(200, Status),
        ?assertEqual(<<"test">>, Body),
        ?assert(lists:keyfind("content-type", 1, Headers) =/= false),
        ?assert(meck:validate(wade)),
        ?assert(meck:validate(eredis))
     end}.

%% -----------------------------
%% Query handler test
%% -----------------------------
query_handler_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     fun() ->
        EmptyReq = #req{},
        EmbryoList = make_embryo_list(),
        JsonResults = make_json_results(EmbryoList),
        QueryString = jsone:encode(#{<<"query">> => <<"test">>}),

        meck:expect(wade, body, fun(_Req, "body", _) -> QueryString end),
        meck:expect(eredis, start_link, fun() -> {ok, mock_connection} end),
        meck:expect(eredis, q, fun(mock_connection, ["GET", Key]) when is_binary(Key) ->
            {ok, JsonResults}
        end),
        meck:expect(eredis, stop, fun(_) -> ok end),

        {Status, BodyBinary, Headers} = em_cache:query_handler(EmptyReq),
        BodyMap = jsone:decode(BodyBinary),

        ?assertEqual(200, Status),
        ?assert(lists:keyfind("content-type", 1, Headers) =/= false),
        ?assertMatch(#{<<"embryo_list">> := _}, BodyMap),
        ?assert(meck:validate(wade)),
        ?assert(meck:validate(eredis))
     end}.

%% -----------------------------
%% Empty cache test
%% -----------------------------
empty_cache_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     fun() ->
        EmptyReq = #req{},
        QueryString = jsone:encode(#{<<"query">> => <<"missing">>}),

        meck:expect(wade, body, fun(_Req, "body", _) -> QueryString end),
        meck:expect(eredis, start_link, fun() -> {ok, mock_connection} end),
        meck:expect(eredis, q, fun(mock_connection, ["GET", Key]) when is_binary(Key) ->
            {ok, undefined}
        end),
        meck:expect(eredis, stop, fun(_) -> ok end),

        {Status, BodyBinary, _Headers} = em_cache:query_handler(EmptyReq),
        BodyMap = jsone:decode(BodyBinary),

        ?assertEqual(200, Status),
        ?assertMatch(#{<<"embryo_list">> := []}, BodyMap),
        ?assert(meck:validate(wade)),
        ?assert(meck:validate(eredis))
     end}.

%% -----------------------------
%% JSON conversion test
%% -----------------------------
embryo_list_conversion_test() ->
    EmbryoList = make_embryo_list(),
    Json = em_cache:embryo_list_to_json(EmbryoList),
    Result = em_cache:json_to_embryo_list(Json),

    ?assertMatch(#embryo_list{embryo_list = _}, Result),
    [#embryo{properties = Props}] = Result#embryo_list.embryo_list,
    ?assertEqual(<<"https://www.speedtest.net/">>, maps:get(<<"url">>, Props)),
    ?assertEqual(<<"Speedtest by Ookla is a global broadband speed test.">>, maps:get(<<"resume">>, Props)).
