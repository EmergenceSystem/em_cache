-module(em_cache_tests).
-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Setup / Teardown
%%====================================================================

setup() ->
    meck:new(eredis, [non_strict]),
    ok.

teardown(_) ->
    meck:unload(),
    ok.

%%====================================================================
%% Helpers
%%====================================================================

make_embryo_list() ->
    [
        #{<<"properties">> => #{
            <<"url">>    => <<"https://www.speedtest.net/">>,
            <<"resume">> => <<"Speedtest by Ookla is a global broadband speed test.">>
        }}
    ].

make_multi_embryo_list() ->
    [
        #{<<"properties">> => #{<<"url">> => <<"https://example1.com">>, <<"resume">> => <<"First result">>}},
        #{<<"properties">> => #{<<"url">> => <<"https://example2.com">>, <<"resume">> => <<"Second result">>}},
        #{<<"properties">> => #{<<"url">> => <<"https://example3.com">>, <<"resume">> => <<"Third result">>}}
    ].

encode_for_redis(EmbryoList) ->
    iolist_to_binary(json:encode(#{<<"embryo_list">> => EmbryoList})).

mock_redis_get(Key, ReturnValue) ->
    meck:expect(eredis, start_link, fun() -> {ok, mock_conn} end),
    meck:expect(eredis, q, fun(mock_conn, ["GET", K]) when K =:= Key -> {ok, ReturnValue} end),
    meck:expect(eredis, stop, fun(_) -> ok end).

mock_redis_set(ExpectedKey) ->
    meck:expect(eredis, start_link, fun() -> {ok, mock_conn} end),
    meck:expect(eredis, q, fun(mock_conn, ["SET", K, _V]) when K =:= ExpectedKey -> {ok, <<"OK">>} end),
    meck:expect(eredis, stop, fun(_) -> ok end).

%%====================================================================
%% put_in_cache/2 tests
%%====================================================================

put_cache_test_() ->
    {setup, fun setup/0, fun teardown/1, fun() ->
        mock_redis_set(<<"test">>),
        Result = em_cache:put_in_cache(<<"test">>, make_embryo_list()),
        ?assertEqual(ok, Result),
        ?assert(meck:validate(eredis))
    end}.

put_cache_empty_list_test_() ->
    {setup, fun setup/0, fun teardown/1, fun() ->
        mock_redis_set(<<"empty">>),
        Result = em_cache:put_in_cache(<<"empty">>, []),
        ?assertEqual(ok, Result)
    end}.

put_cache_empty_query_test_() ->
    {setup, fun setup/0, fun teardown/1, fun() ->
        mock_redis_set(<<>>),
        Result = em_cache:put_in_cache(<<>>, make_embryo_list()),
        ?assertEqual(ok, Result)
    end}.

put_cache_special_chars_test_() ->
    {setup, fun setup/0, fun teardown/1, fun() ->
        Query = <<"test query with spaces & special chars!">>,
        mock_redis_set(Query),
        Result = em_cache:put_in_cache(Query, make_embryo_list()),
        ?assertEqual(ok, Result)
    end}.

put_cache_unicode_test_() ->
    {setup, fun setup/0, fun teardown/1, fun() ->
        Query = <<"search with unicode 你好"/utf8>>,
        mock_redis_set(Query),
        Result = em_cache:put_in_cache(Query, make_embryo_list()),
        ?assertEqual(ok, Result)
    end}.

put_cache_multi_embryos_test_() ->
    {setup, fun setup/0, fun teardown/1, fun() ->
        meck:expect(eredis, start_link, fun() -> {ok, mock_conn} end),
        meck:expect(eredis, q, fun(mock_conn, ["SET", <<"multi">>, Stored]) ->
            Decoded = json:decode(Stored),
            ?assertMatch(#{<<"embryo_list">> := [_, _, _]}, Decoded),
            {ok, <<"OK">>}
        end),
        meck:expect(eredis, stop, fun(_) -> ok end),
        Result = em_cache:put_in_cache(<<"multi">>, make_multi_embryo_list()),
        ?assertEqual(ok, Result)
    end}.

put_cache_large_list_test_() ->
    {setup, fun setup/0, fun teardown/1, fun() ->
        Large = [#{<<"properties">> => #{
            <<"url">>    => iolist_to_binary(io_lib:format("https://example~p.com", [N])),
            <<"resume">> => iolist_to_binary(io_lib:format("Result number ~p", [N]))
        }} || N <- lists:seq(1, 100)],
        meck:expect(eredis, start_link, fun() -> {ok, mock_conn} end),
        meck:expect(eredis, q, fun(mock_conn, ["SET", <<"large">>, Stored]) ->
            #{<<"embryo_list">> := List} = json:decode(Stored),
            ?assertEqual(100, length(List)),
            {ok, <<"OK">>}
        end),
        meck:expect(eredis, stop, fun(_) -> ok end),
        Result = em_cache:put_in_cache(<<"large">>, Large),
        ?assertEqual(ok, Result)
    end}.

%%====================================================================
%% get_from_cache/1 tests
%%====================================================================

get_cache_hit_test_() ->
    {setup, fun setup/0, fun teardown/1, fun() ->
        List = make_embryo_list(),
        mock_redis_get(<<"test">>, encode_for_redis(List)),
        Result = em_cache:get_from_cache(<<"test">>),
        ?assertMatch({ok, [_]}, Result),
        {ok, Got} = Result,
        [Embryo] = Got,
        ?assertMatch(#{<<"properties">> := #{<<"url">> := <<"https://www.speedtest.net/">>}}, Embryo),
        ?assert(meck:validate(eredis))
    end}.

get_cache_miss_test_() ->
    {setup, fun setup/0, fun teardown/1, fun() ->
        mock_redis_get(<<"missing">>, undefined),
        Result = em_cache:get_from_cache(<<"missing">>),
        ?assertEqual({miss, []}, Result),
        ?assert(meck:validate(eredis))
    end}.

get_cache_multi_test_() ->
    {setup, fun setup/0, fun teardown/1, fun() ->
        List = make_multi_embryo_list(),
        mock_redis_get(<<"multi">>, encode_for_redis(List)),
        {ok, Got} = em_cache:get_from_cache(<<"multi">>),
        ?assertEqual(3, length(Got)),
        [First | _] = Got,
        ?assertMatch(#{<<"properties">> := #{<<"url">> := <<"https://example1.com">>}}, First)
    end}.

get_cache_corrupted_test_() ->
    {setup, fun setup/0, fun teardown/1, fun() ->
        mock_redis_get(<<"corrupted">>, <<"invalid json data">>),
        Result = em_cache:get_from_cache(<<"corrupted">>),
        ?assertEqual({miss, []}, Result)
    end}.

get_cache_special_chars_test_() ->
    {setup, fun setup/0, fun teardown/1, fun() ->
        Query = <<"test query with spaces & special chars!">>,
        List  = make_embryo_list(),
        mock_redis_get(Query, encode_for_redis(List)),
        {ok, Got} = em_cache:get_from_cache(Query),
        ?assertEqual(1, length(Got))
    end}.

%%====================================================================
%% Round-trip tests
%%====================================================================

put_then_get_test_() ->
    {setup, fun setup/0, fun teardown/1, fun() ->
        List  = make_embryo_list(),
        Query = <<"integration_test">>,
        meck:expect(eredis, start_link, fun() -> {ok, mock_conn} end),
        meck:expect(eredis, stop, fun(_) -> ok end),
        %% Capture what was stored, then return it on GET
        meck:expect(eredis, q, fun
            (mock_conn, ["SET", Q, Stored]) when Q =:= Query ->
                meck:expect(eredis, q, fun(mock_conn, ["GET", Q2]) when Q2 =:= Query ->
                    {ok, Stored}
                end),
                {ok, <<"OK">>}
        end),
        ok = em_cache:put_in_cache(Query, List),
        {ok, Got} = em_cache:get_from_cache(Query),
        ?assertEqual(1, length(Got)),
        [Embryo] = Got,
        ?assertMatch(#{<<"properties">> := #{<<"url">> := <<"https://www.speedtest.net/">>}}, Embryo)
    end}.

empty_list_round_trip_test_() ->
    {setup, fun setup/0, fun teardown/1, fun() ->
        meck:expect(eredis, start_link, fun() -> {ok, mock_conn} end),
        meck:expect(eredis, stop, fun(_) -> ok end),
        meck:expect(eredis, q, fun
            (mock_conn, ["SET", <<"empty">>, Stored]) ->
                meck:expect(eredis, q, fun(mock_conn, ["GET", <<"empty">>]) ->
                    {ok, Stored}
                end),
                {ok, <<"OK">>}
        end),
        ok = em_cache:put_in_cache(<<"empty">>, []),
        {ok, Got} = em_cache:get_from_cache(<<"empty">>),
        ?assertEqual([], Got)
    end}.
