-module(em_cache_tests).
-include_lib("eunit/include/eunit.hrl").

%% The store degrades to L1 (ETS) when no Redis is reachable, so these
%% tests exercise the real backend with no Redis and no mocks.

setup() ->
    %% ensure a clean singleton (eunit may have booted the app)
    catch application:stop(em_cache),
    catch gen_server:stop(em_cache_store),
    catch persistent_term:erase(em_cache_pt),
    %% no reachable redis in CI -> L1-only
    application:set_env(em_cache, redis_host, "127.0.0.1"),
    application:set_env(em_cache, redis_port, 63999),
    application:set_env(em_cache, ttl, 3600),
    {ok, Pid} = em_cache_store:start_link(),
    Pid.

teardown(Pid) ->
    gen_server:stop(Pid),
    catch persistent_term:erase(em_cache_pt),
    ok.

with_store(TestFun) when is_function(TestFun, 0) ->
    {setup, fun setup/0, fun teardown/1, fun(_) -> TestFun end}.

embryos() ->
    [#{<<"properties">> => #{<<"url">> => <<"https://a.example">>,
                             <<"resume">> => <<"one">>}}].

roundtrip_test_() ->
    with_store(fun() ->
        ok = em_cache:put_in_cache(<<"hello world">>, embryos()),
        ?assertMatch({ok, [_]}, em_cache:get_from_cache(<<"hello world">>))
    end).

miss_test_() ->
    with_store(fun() ->
        ?assertEqual({miss, []}, em_cache:get_from_cache(<<"never stored">>))
    end).

normalization_test_() ->
    with_store(fun() ->
        ok = em_cache:put_in_cache(<<"  Cat   Photo ">>, embryos()),
        %% different case/spacing must hit the same entry
        ?assertMatch({ok, [_]}, em_cache:get_from_cache(<<"cat photo">>)),
        ?assertMatch({ok, [_]}, em_cache:get_from_cache(<<"CAT   photo">>))
    end).

key_stability_test() ->
    ?assertEqual(em_cache:key(<<"Foo Bar">>), em_cache:key(<<" foo   bar ">>)),
    ?assertNotEqual(em_cache:key(<<"foo">>), em_cache:key(<<"bar">>)),
    ?assertMatch(<<"emq:q:v1:", _/binary>>, em_cache:key(<<"x">>)).

ttl_expiry_test_() ->
    {timeout, 10, with_store(fun() ->
        ok = em_cache:put_in_cache(<<"short">>, embryos(), 1),
        ?assertMatch({ok, [_]}, em_cache:get_from_cache(<<"short">>)),
        timer:sleep(1200),
        ?assertEqual({miss, []}, em_cache:get_from_cache(<<"short">>))
    end)}.

empty_list_test_() ->
    with_store(fun() ->
        ok = em_cache:put_in_cache(<<"empty">>, []),
        ?assertEqual({ok, []}, em_cache:get_from_cache(<<"empty">>))
    end).

stats_test_() ->
    with_store(fun() ->
        _ = em_cache:get_from_cache(<<"absent">>),
        ok = em_cache:put_in_cache(<<"present">>, embryos()),
        _ = em_cache:get_from_cache(<<"present">>),
        S = em_cache_store:stats(),
        ?assert(maps:get(misses, S) >= 1),
        ?assert(maps:get(l1_hits, S) >= 1),
        ?assert(maps:get(puts, S) >= 1)
    end).
