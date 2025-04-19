-module(em_cache_tests).
-include_lib("eunit/include/eunit.hrl").

-record(embryo, {properties}).
-record(embryo_list, {embryo_list}).

setup() ->
    meck:new(cowboy_req, [passthrough, non_strict]),
    meck:new(eredis, [non_strict]),
    meck:new(jsx, [passthrough]),
    ok.

teardown(_) ->
    meck:unload(),
    ok.

%% Simple utility record converters for tests
make_embryo_list() ->
    #embryo_list{
        embryo_list = [
            #embryo{
                properties = #{
                    <<"url">> => <<"https://www.speedtest.net/">>,
                    <<"resume">> => <<"Speedtest by Ookla is a global broadband speed test that lets you measure your internet performance on any device.">>
                }
            }
        ]
    }.

%% Test cases
cache_handler_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     fun() ->
        % Pre-create test data
        EmptyReq = #{},
        _EmbryoList = make_embryo_list(),
        JsonString = jsx:encode(#{
            <<"embryo_list">> => [
                #{<<"properties">> => #{
                    <<"url">> => <<"https://www.speedtest.net/">>,
                    <<"resume">> => <<"Speedtest by Ookla is a global broadband speed test that lets you measure your internet performance on any device.">>
                }}
            ]
        }),
        
        % Setup mocks
        meck:expect(cowboy_req, read_body, fun(_) -> 
            {ok, jsx:encode(#{<<"query">> => <<"test">>, <<"results">> => JsonString}), EmptyReq} 
        end),
        
        meck:expect(cowboy_req, reply, fun(200, _, <<"test">>, _) -> {ok, replied} end),
        
        meck:expect(eredis, start_link, fun() -> {ok, mock_connection} end),
        meck:expect(eredis, q, fun(_, ["SET", <<"test">>, _]) -> {ok, <<"OK">>} end),
        meck:expect(eredis, stop, fun(_) -> ok end),
        
        % Run the function under test
        Result = em_cache:cache_handler(EmptyReq, cache),
        
        % Verify
        ?assertEqual({ok, {ok, replied}, cache}, Result),
        ?assert(meck:validate(cowboy_req)),
        ?assert(meck:validate(eredis))
     end}.

query_handler_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     fun() ->
        % Pre-create test data
        EmptyReq = #{},
        QueryString = jsx:encode(#{<<"query">> => <<"test">>}),
        ResultString = jsx:encode(#{
            <<"embryo_list">> => [
                #{<<"properties">> => #{
                    <<"url">> => <<"https://www.speedtest.net/">>,
                    <<"resume">> => <<"Speedtest by Ookla is a global broadband speed test that lets you measure your internet performance on any device.">>
                }}
            ]
        }),
        
        % Setup mocks
        meck:expect(cowboy_req, read_body, fun(_) -> {ok, QueryString, EmptyReq} end),
        meck:expect(cowboy_req, reply, fun(200, _, _, _) -> {ok, replied} end),
        
        meck:expect(eredis, start_link, fun() -> {ok, mock_connection} end),
        meck:expect(eredis, q, fun(_, ["GET", <<"test">>]) -> {ok, ResultString} end),
        meck:expect(eredis, stop, fun(_) -> ok end),
        
        % Run the function under test
        Result = em_cache:query_handler(EmptyReq, query),
        
        % Verify
        ?assertEqual({ok,{ok,replied},query}, Result),
        ?assert(meck:validate(cowboy_req)),
        ?assert(meck:validate(eredis))
     end}.

embryo_list_conversion_test() ->
    % Test json_to_embryo_list and embryo_list_to_json functions
    EmbryoList = #embryo_list{
        embryo_list = [
            #embryo{
                properties = #{
                    <<"url">> => <<"https://www.speedtest.net/">>,
                    <<"resume">> => <<"Speedtest description">>
                }
            }
        ]
    },
    
    Json = em_cache:embryo_list_to_json(EmbryoList),
    Result = em_cache:json_to_embryo_list(Json),
    
    ?assertMatch(#embryo_list{embryo_list = [#embryo{properties = _}]}, Result),
    [#embryo{properties = Props}] = Result#embryo_list.embryo_list,
    ?assertEqual(<<"https://www.speedtest.net/">>, maps:get(<<"url">>, Props)),
    ?assertEqual(<<"Speedtest description">>, maps:get(<<"resume">>, Props)).
