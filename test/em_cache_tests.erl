-module(em_cache_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("wade/include/wade.hrl").

-record(embryo, {properties}).
-record(embryo_list, {embryo_list}).

setup() ->
    meck:new(wade, [passthrough, non_strict]),
    meck:new(eredis, [non_strict]),
    meck:new(jsx, [passthrough]),
    ok.

teardown(_) ->
    meck:unload(),
    ok.

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

cache_handler_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     fun() ->
        EmptyReq = #req{},
        make_embryo_list(),
        JsonString = jsx:encode(#{
            <<"embryo_list">> => [
                #{<<"properties">> => #{
                    <<"url">> => <<"https://www.speedtest.net/">>,
                    <<"resume">> => <<"Speedtest by Ookla is a global broadband speed test that lets you measure your internet performance on any device.">>
                }}
            ]
        }),

        meck:expect(wade, body, fun(_EmptyReqInner, "body", _) ->
            jsx:encode(#{<<"query">> => <<"test">>, <<"results">> => JsonString})
        end),

        meck:expect(eredis, start_link, fun() -> {ok, mock_connection} end),
        meck:expect(eredis, q, fun(_, ["SET", <<"test">>, _]) -> {ok, <<"OK">>} end),
        meck:expect(eredis, stop, fun(_) -> ok end),

        {Status, Body, Headers} = em_cache:cache_handler(EmptyReq),

        ?assertEqual(200, Status),
        ?assertEqual(<<"test">>, Body),
        ?assert(lists:keyfind("content-type", 1, Headers) =/= false),
        ?assert(meck:validate(wade)),
        ?assert(meck:validate(eredis))
     end}.

query_handler_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     fun() ->
        EmptyReq = #req{},
        QueryString = jsx:encode(#{<<"query">> => <<"test">>}),
        ResultString = jsx:encode(#{
            <<"embryo_list">> => [
                #{<<"properties">> => #{
                    <<"url">> => <<"https://www.speedtest.net/">>,
                    <<"resume">> => <<"Speedtest by Ookla is a global broadband speed test that lets you measure your internet performance on any device.">>
                }}
            ]
        }),

        meck:expect(wade, body, fun(_EmptyReqInner, "body", _) -> QueryString end),
        meck:expect(eredis, start_link, fun() -> {ok, mock_connection} end),
        meck:expect(eredis, q, fun(_, ["GET", <<"test">>]) -> {ok, ResultString} end),
        meck:expect(eredis, stop, fun(_) -> ok end),

        {Status, _Body, Headers} = em_cache:query_handler(EmptyReq),

        ?assertEqual(200, Status),
        ?assert(lists:keyfind("content-type", 1, Headers) =/= false),
        ?assert(meck:validate(wade)),
        ?assert(meck:validate(eredis))
     end}.

embryo_list_conversion_test() ->
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

