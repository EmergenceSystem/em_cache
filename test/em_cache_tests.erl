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

make_multi_embryo_list() ->
    #embryo_list{
        embryo_list = [
            #embryo{
                properties = #{
                    <<"url">> => <<"https://example1.com">>,
                    <<"resume">> => <<"First result">>
                }
            },
            #embryo{
                properties = #{
                    <<"url">> => <<"https://example2.com">>,
                    <<"resume">> => <<"Second result">>
                }
            },
            #embryo{
                properties = #{
                    <<"url">> => <<"https://example3.com">>,
                    <<"resume">> => <<"Third result">>
                }
            }
        ]
    }.

make_json_results(EmbryoList) ->
    jsone:encode(em_cache:embryo_list_to_json(EmbryoList)).

%% -----------------------------
%% Basic Cache Handler Tests
%% -----------------------------
cache_handler_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     fun() ->
        EmptyReq = #req{},
        EmbryoList = make_embryo_list(),
        JsonResults = make_json_results(EmbryoList),

        RequestBody = jsone:encode(#{
            <<"query">> => <<"test">>, 
            <<"results">> => jsone:decode(JsonResults)
        }),
        
        meck:expect(wade, body, fun(_Req, "body", _) -> RequestBody end),
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

cache_handler_empty_query_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     fun() ->
        EmptyReq = #req{},
        EmbryoList = make_embryo_list(),
        JsonResults = make_json_results(EmbryoList),

        RequestBody = jsone:encode(#{
            <<"query">> => <<>>, 
            <<"results">> => jsone:decode(JsonResults)
        }),
        
        meck:expect(wade, body, fun(_Req, "body", _) -> RequestBody end),
        meck:expect(eredis, start_link, fun() -> {ok, mock_connection} end),
        meck:expect(eredis, q, fun(mock_connection, ["SET", Key, _]) when is_binary(Key) ->
            {ok, <<"OK">>}
        end),
        meck:expect(eredis, stop, fun(_) -> ok end),

        {Status, Body, _Headers} = em_cache:cache_handler(EmptyReq),

        ?assertEqual(200, Status),
        ?assertEqual(<<>>, Body)
     end}.

cache_handler_special_chars_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     fun() ->
        EmptyReq = #req{},
        EmbryoList = make_embryo_list(),
        JsonResults = make_json_results(EmbryoList),
        SpecialQuery = <<"test query with spaces & special chars!">>,

        RequestBody = jsone:encode(#{
            <<"query">> => SpecialQuery, 
            <<"results">> => jsone:decode(JsonResults)
        }),
        
        meck:expect(wade, body, fun(_Req, "body", _) -> RequestBody end),
        meck:expect(eredis, start_link, fun() -> {ok, mock_connection} end),
        meck:expect(eredis, q, fun(mock_connection, ["SET", Key, _]) when is_binary(Key) ->
            ?assertEqual(SpecialQuery, Key),
            {ok, <<"OK">>}
        end),
        meck:expect(eredis, stop, fun(_) -> ok end),

        {Status, Body, _Headers} = em_cache:cache_handler(EmptyReq),

        ?assertEqual(200, Status),
        ?assertEqual(SpecialQuery, Body)
     end}.

cache_handler_multiple_embryos_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     fun() ->
        EmptyReq = #req{},
        EmbryoList = make_multi_embryo_list(),
        JsonResults = make_json_results(EmbryoList),

        RequestBody = jsone:encode(#{
            <<"query">> => <<"multi">>, 
            <<"results">> => jsone:decode(JsonResults)
        }),
        
        meck:expect(wade, body, fun(_Req, "body", _) -> RequestBody end),
        meck:expect(eredis, start_link, fun() -> {ok, mock_connection} end),
        meck:expect(eredis, q, fun(mock_connection, ["SET", <<"multi">>, StoredJson]) ->
            Decoded = jsone:decode(StoredJson),
            ?assertMatch(#{<<"embryo_list">> := [_,_,_]}, Decoded),
            {ok, <<"OK">>}
        end),
        meck:expect(eredis, stop, fun(_) -> ok end),

        {Status, Body, _Headers} = em_cache:cache_handler(EmptyReq),

        ?assertEqual(200, Status),
        ?assertEqual(<<"multi">>, Body)
     end}.

cache_handler_invalid_json_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     fun() ->
        EmptyReq = #req{},
        
        meck:expect(wade, body, fun(_Req, "body", _) -> 
            <<"not valid json">> 
        end),
        meck:expect(eredis, start_link, fun() -> {ok, mock_connection} end),
        meck:expect(eredis, q, fun(mock_connection, ["SET", Key, _]) when is_binary(Key) ->
            {ok, <<"OK">>}
        end),
        meck:expect(eredis, stop, fun(_) -> ok end),

        {Status, Body, _Headers} = em_cache:cache_handler(EmptyReq),

        ?assertEqual(200, Status),
        ?assertEqual(<<>>, Body)
     end}.

%% -----------------------------
%% Basic Query Handler Tests
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

query_handler_multiple_results_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     fun() ->
        EmptyReq = #req{},
        EmbryoList = make_multi_embryo_list(),
        JsonResults = make_json_results(EmbryoList),
        QueryString = jsone:encode(#{<<"query">> => <<"multi">>}),

        meck:expect(wade, body, fun(_Req, "body", _) -> QueryString end),
        meck:expect(eredis, start_link, fun() -> {ok, mock_connection} end),
        meck:expect(eredis, q, fun(mock_connection, ["GET", <<"multi">>]) ->
            {ok, JsonResults}
        end),
        meck:expect(eredis, stop, fun(_) -> ok end),

        {Status, BodyBinary, _Headers} = em_cache:query_handler(EmptyReq),
        BodyMap = jsone:decode(BodyBinary),

        ?assertEqual(200, Status),
        ?assertMatch(#{<<"embryo_list">> := [_,_,_]}, BodyMap),
        
        #{<<"embryo_list">> := Embryos} = BodyMap,
        ?assertEqual(3, length(Embryos)),
        
        [First, Second, Third] = Embryos,
        ?assertMatch(#{<<"properties">> := #{<<"url">> := <<"https://example1.com">>}}, First),
        ?assertMatch(#{<<"properties">> := #{<<"url">> := <<"https://example2.com">>}}, Second),
        ?assertMatch(#{<<"properties">> := #{<<"url">> := <<"https://example3.com">>}}, Third)
     end}.

query_handler_special_query_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     fun() ->
        EmptyReq = #req{},
        EmbryoList = make_embryo_list(),
        JsonResults = make_json_results(EmbryoList),
        SpecialQuery = <<"test query with spaces & special chars!">>,
        QueryString = jsone:encode(#{<<"query">> => SpecialQuery}),

        meck:expect(wade, body, fun(_Req, "body", _) -> QueryString end),
        meck:expect(eredis, start_link, fun() -> {ok, mock_connection} end),
        meck:expect(eredis, q, fun(mock_connection, ["GET", Key]) ->
            ?assertEqual(SpecialQuery, Key),
            {ok, JsonResults}
        end),
        meck:expect(eredis, stop, fun(_) -> ok end),

        {Status, BodyBinary, _Headers} = em_cache:query_handler(EmptyReq),
        BodyMap = jsone:decode(BodyBinary),

        ?assertEqual(200, Status),
        ?assertMatch(#{<<"embryo_list">> := [_]}, BodyMap)
     end}.

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

query_handler_invalid_json_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     fun() ->
        EmptyReq = #req{},
        
        meck:expect(wade, body, fun(_Req, "body", _) -> 
            <<"not valid json">> 
        end),
        meck:expect(eredis, start_link, fun() -> {ok, mock_connection} end),
        meck:expect(eredis, q, fun(mock_connection, ["GET", <<>>]) ->
            {ok, undefined}
        end),
        meck:expect(eredis, stop, fun(_) -> ok end),

        {Status, BodyBinary, _Headers} = em_cache:query_handler(EmptyReq),
        BodyMap = jsone:decode(BodyBinary),

        ?assertEqual(200, Status),
        ?assertMatch(#{<<"embryo_list">> := []}, BodyMap)
     end}.

query_handler_corrupted_cache_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     fun() ->
        EmptyReq = #req{},
        QueryString = jsone:encode(#{<<"query">> => <<"corrupted">>}),

        meck:expect(wade, body, fun(_Req, "body", _) -> QueryString end),
        meck:expect(eredis, start_link, fun() -> {ok, mock_connection} end),
        meck:expect(eredis, q, fun(mock_connection, ["GET", <<"corrupted">>]) ->
            {ok, <<"invalid json data">>}
        end),
        meck:expect(eredis, stop, fun(_) -> ok end),

        {Status, BodyBinary, _Headers} = em_cache:query_handler(EmptyReq),
        BodyMap = jsone:decode(BodyBinary),

        ?assertEqual(200, Status),
        ?assertMatch(#{<<"embryo_list">> := []}, BodyMap)
     end}.

%% -----------------------------
%% Cache Integration Tests
%% -----------------------------
cache_then_query_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     fun() ->
        EmptyReq = #req{},
        EmbryoList = make_embryo_list(),
        JsonResults = make_json_results(EmbryoList),
        Query = <<"integration_test">>,

        %% Simulate storing data
        CacheBody = jsone:encode(#{
            <<"query">> => Query, 
            <<"results">> => jsone:decode(JsonResults)
        }),
        
        meck:expect(wade, body, fun(_Req, "body", _) -> CacheBody end),
        
        %% Track what was stored
        meck:expect(eredis, start_link, fun() -> {ok, mock_connection} end),
        meck:expect(eredis, q, fun
            (mock_connection, ["SET", Q, Data]) when Q == Query ->
                meck:expect(eredis, q, fun(mock_connection, ["GET", Q2]) when Q2 == Query ->
                    {ok, Data}
                end),
                {ok, <<"OK">>}
        end),
        meck:expect(eredis, stop, fun(_) -> ok end),

        %% First, cache the data
        {Status1, Body1, _} = em_cache:cache_handler(EmptyReq),
        ?assertEqual(200, Status1),
        ?assertEqual(Query, Body1),

        %% Now retrieve it
        QueryBody = jsone:encode(#{<<"query">> => Query}),
        meck:expect(wade, body, fun(_Req, "body", _) -> QueryBody end),
        
        {Status2, BodyBinary, _} = em_cache:query_handler(EmptyReq),
        BodyMap = jsone:decode(BodyBinary),

        ?assertEqual(200, Status2),
        ?assertMatch(#{<<"embryo_list">> := [_]}, BodyMap)
     end}.

%% -----------------------------
%% Edge Cases
%% -----------------------------
empty_embryo_list_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     fun() ->
        EmptyReq = #req{},
        EmptyList = #embryo_list{embryo_list = []},
        JsonResults = make_json_results(EmptyList),

        RequestBody = jsone:encode(#{
            <<"query">> => <<"empty">>, 
            <<"results">> => jsone:decode(JsonResults)
        }),
        
        meck:expect(wade, body, fun(_Req, "body", _) -> RequestBody end),
        meck:expect(eredis, start_link, fun() -> {ok, mock_connection} end),
        meck:expect(eredis, q, fun(mock_connection, ["SET", <<"empty">>, Stored]) ->
            Decoded = jsone:decode(Stored),
            ?assertMatch(#{<<"embryo_list">> := []}, Decoded),
            {ok, <<"OK">>}
        end),
        meck:expect(eredis, stop, fun(_) -> ok end),

        {Status, Body, _Headers} = em_cache:cache_handler(EmptyReq),

        ?assertEqual(200, Status),
        ?assertEqual(<<"empty">>, Body)
     end}.

unicode_query_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     fun() ->
        EmptyReq = #req{},
        EmbryoList = make_embryo_list(),
        JsonResults = make_json_results(EmbryoList),
        %% Use simpler Unicode that jsone can handle
        UnicodeQuery = <<"search with unicode 你好"/utf8>>,

        RequestBody = jsone:encode(#{
            <<"query">> => UnicodeQuery, 
            <<"results">> => jsone:decode(JsonResults)
        }),
        
        meck:expect(wade, body, fun(_Req, "body", _) -> RequestBody end),
        meck:expect(eredis, start_link, fun() -> {ok, mock_connection} end),
        meck:expect(eredis, q, fun(mock_connection, ["SET", Key, _]) when is_binary(Key) ->
            ?assertEqual(UnicodeQuery, Key),
            {ok, <<"OK">>}
        end),
        meck:expect(eredis, stop, fun(_) -> ok end),

        {Status, Body, _Headers} = em_cache:cache_handler(EmptyReq),

        ?assertEqual(200, Status),
        ?assertEqual(UnicodeQuery, Body)
     end}.

large_embryo_list_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     fun() ->
        EmptyReq = #req{},
        
        %% Create a large list with 100 embryos
        LargeList = #embryo_list{
            embryo_list = [
                #embryo{
                    properties = #{
                        <<"url">> => iolist_to_binary(io_lib:format("https://example~p.com", [N])),
                        <<"resume">> => iolist_to_binary(io_lib:format("Result number ~p", [N]))
                    }
                } || N <- lists:seq(1, 100)
            ]
        },
        JsonResults = make_json_results(LargeList),

        RequestBody = jsone:encode(#{
            <<"query">> => <<"large">>, 
            <<"results">> => jsone:decode(JsonResults)
        }),
        
        meck:expect(wade, body, fun(_Req, "body", _) -> RequestBody end),
        meck:expect(eredis, start_link, fun() -> {ok, mock_connection} end),
        meck:expect(eredis, q, fun(mock_connection, ["SET", <<"large">>, Stored]) ->
            Decoded = jsone:decode(Stored),
            #{<<"embryo_list">> := List} = Decoded,
            ?assertEqual(100, length(List)),
            {ok, <<"OK">>}
        end),
        meck:expect(eredis, stop, fun(_) -> ok end),

        {Status, Body, _Headers} = em_cache:cache_handler(EmptyReq),

        ?assertEqual(200, Status),
        ?assertEqual(<<"large">>, Body)
     end}.

%% -----------------------------
%% JSON Conversion Tests
%% -----------------------------
embryo_list_conversion_test() ->
    EmbryoList = make_embryo_list(),
    Json = em_cache:embryo_list_to_json(EmbryoList),
    Result = em_cache:json_to_embryo_list(Json),

    ?assertMatch(#embryo_list{embryo_list = _}, Result),
    [#embryo{properties = Props}] = Result#embryo_list.embryo_list,
    ?assertEqual(<<"https://www.speedtest.net/">>, maps:get(<<"url">>, Props)),
    ?assertEqual(<<"Speedtest by Ookla is a global broadband speed test.">>, maps:get(<<"resume">>, Props)).

empty_list_conversion_test() ->
    EmptyList = #embryo_list{embryo_list = []},
    Json = em_cache:embryo_list_to_json(EmptyList),
    Result = em_cache:json_to_embryo_list(Json),

    ?assertMatch(#embryo_list{embryo_list = []}, Result).

multi_embryo_conversion_test() ->
    MultiList = make_multi_embryo_list(),
    Json = em_cache:embryo_list_to_json(MultiList),
    Result = em_cache:json_to_embryo_list(Json),

    ?assertMatch(#embryo_list{embryo_list = [_,_,_]}, Result),
    ?assertEqual(3, length(Result#embryo_list.embryo_list)).

binary_json_conversion_test() ->
    EmbryoList = make_embryo_list(),
    Json = em_cache:embryo_list_to_json(EmbryoList),
    JsonBinary = jsone:encode(Json),
    Result = em_cache:json_to_embryo_list(JsonBinary),

    ?assertMatch(#embryo_list{embryo_list = [_]}, Result).

invalid_json_conversion_test() ->
    Result = em_cache:json_to_embryo_list(<<"not valid json">>),
    ?assertMatch(#embryo_list{embryo_list = []}, Result).

