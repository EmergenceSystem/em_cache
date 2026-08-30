%%%-------------------------------------------------------------------
%%% @doc em_cache_store — two-tier query cache backend.
%%%
%%% L1: an in-process ETS table (fast, always present, per-entry TTL).
%%% L2: an optional shared Redis instance (durable / cross-node),
%%%     used only when a connection is available.
%%%
%%% The hot path (`get/1', `put/2,3') never goes through the
%%% gen_server: it reads an ETS table and a Redis connection handle
%%% published in `persistent_term', so lookups are lock-free. The
%%% gen_server only owns the ETS table, manages the Redis connection
%%% lifecycle (connect at boot, reconnect on failure), sweeps expired
%%% L1 entries, and holds the hit/miss counters.
%%%
%%% Redis is entirely optional: with no reachable Redis the cache
%%% degrades to L1-only and never errors.
%%% @end
%%%-------------------------------------------------------------------
-module(em_cache_store).
-behaviour(gen_server).

-export([start_link/0]).
-export([get/1, put/2, put/3, stats/0, health/0, default_ttl/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(TAB, em_cache_ets).
-define(PT, em_cache_pt).
-define(SWEEP_MS, 60000).
%% counter indices
-define(C_L1, 1).
-define(C_MISS, 2).
-define(C_L2, 3).
-define(C_PUT, 4).

%%====================================================================
%% Hot-path API (lock-free: no gen_server round-trip on an L1 hit)
%%====================================================================

%% @doc Look up a (already-hashed) key. Returns `{ok, Bin}' or `miss'.
-spec get(binary()) -> {ok, binary()} | miss.
get(Key) ->
    #{ets := T, ctr := C, redis := R, ttl := Ttl} = persistent_term:get(?PT),
    Now = erlang:monotonic_time(millisecond),
    case ets:lookup(T, Key) of
        [{_, Val, Exp}] when Exp > Now ->
            counters:add(C, ?C_L1, 1),
            {ok, Val};
        _ ->
            l2_get(Key, R, T, C, Ttl, Now)
    end.

l2_get(_Key, undefined, _T, C, _Ttl, _Now) ->
    counters:add(C, ?C_MISS, 1), miss;
l2_get(Key, Conn, T, C, Ttl, Now) ->
    case safe_q(Conn, ["GET", Key]) of
        {ok, undefined} ->
            counters:add(C, ?C_MISS, 1), miss;
        {ok, Val} when is_binary(Val) ->
            ets:insert(T, {Key, Val, Now + Ttl * 1000}),
            counters:add(C, ?C_L2, 1),
            {ok, Val};
        _ ->
            gen_server:cast(?MODULE, redis_down),
            counters:add(C, ?C_MISS, 1), miss
    end.

%% @doc Store `Val' under `Key' with the default TTL.
-spec put(binary(), binary()) -> ok.
put(Key, Val) -> put(Key, Val, default_ttl()).

%% @doc Store `Val' under `Key' with an explicit TTL (seconds).
-spec put(binary(), binary(), pos_integer()) -> ok.
put(Key, Val, TtlSec) when is_integer(TtlSec), TtlSec > 0 ->
    #{ets := T, ctr := C, redis := R} = persistent_term:get(?PT),
    Now = erlang:monotonic_time(millisecond),
    ets:insert(T, {Key, Val, Now + TtlSec * 1000}),
    counters:add(C, ?C_PUT, 1),
    case R of
        undefined -> ok;
        Conn ->
            _ = safe_q(Conn, ["SET", Key, Val, "EX", integer_to_list(TtlSec)]),
            ok
    end.

%% @doc `#{l1_hits, l2_hits, misses, puts}'.
-spec stats() -> map().
stats() ->
    #{ctr := C} = persistent_term:get(?PT),
    #{l1_hits => counters:get(C, ?C_L1),
      l2_hits => counters:get(C, ?C_L2),
      misses  => counters:get(C, ?C_MISS),
      puts    => counters:get(C, ?C_PUT)}.

%% @doc `#{redis, entries, ttl}'.
-spec health() -> map().
health() ->
    #{redis := R, ttl := Ttl} = persistent_term:get(?PT),
    #{redis   => R =/= undefined,
      entries => ets:info(?TAB, size),
      ttl     => Ttl}.

%% @doc Default TTL in seconds from `[env] ttl' (default 3600).
-spec default_ttl() -> pos_integer().
default_ttl() ->
    case application:get_env(em_cache, ttl, 3600) of
        N when is_integer(N), N > 0 -> N;
        _ -> 3600
    end.

%%====================================================================
%% gen_server
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    Tab = ets:new(?TAB, [set, public, named_table,
                         {read_concurrency, true}, {write_concurrency, true}]),
    Ctr = counters:new(4, [write_concurrency]),
    Ttl = default_ttl(),
    Conn = try_connect(),
    publish(Tab, Ctr, Ttl, Conn),
    erlang:send_after(?SWEEP_MS, self(), sweep),
    {ok, #{conn => Conn, ttl => Ttl, tab => Tab, ctr => Ctr}}.

handle_call(_Req, _From, State) ->
    {reply, ok, State}.

handle_cast(redis_down, #{conn := Old} = State) ->
    catch (Old =/= undefined andalso eredis:stop(Old)),
    Conn = try_connect(),
    publish_redis(Conn),
    {noreply, State#{conn => Conn}};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(sweep, #{tab := Tab, conn := Conn} = State) ->
    Now = erlang:monotonic_time(millisecond),
    _ = ets:select_delete(Tab, [{{'_', '_', '$1'}, [{'=<', '$1', Now}], [true]}]),
    State2 = case Conn of
        undefined ->
            case try_connect() of
                undefined -> State;
                New       -> publish_redis(New), State#{conn => New}
            end;
        _ -> State
    end,
    erlang:send_after(?SWEEP_MS, self(), sweep),
    {noreply, State2};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #{conn := Conn}) ->
    catch (Conn =/= undefined andalso eredis:stop(Conn)),
    ok;
terminate(_Reason, _State) ->
    ok.

code_change(_Old, State, _Extra) -> {ok, State}.

%%====================================================================
%% Internal
%%====================================================================

%% @private
publish(Tab, Ctr, Ttl, Conn) ->
    persistent_term:put(?PT, #{ets => Tab, ctr => Ctr, ttl => Ttl, redis => Conn}).

%% @private
publish_redis(Conn) ->
    Map = persistent_term:get(?PT),
    persistent_term:put(?PT, Map#{redis => Conn}).

%% @private Best-effort Redis connection; `undefined' when unavailable.
try_connect() ->
    Host = application:get_env(em_cache, redis_host, "127.0.0.1"),
    Port = application:get_env(em_cache, redis_port, 6379),
    case catch eredis:start_link([{host, Host}, {port, Port}]) of
        {ok, C} ->
            %% eredis returns a pid and retries in the background even
            %% when Redis is down, so a live PING is the real probe.
            case catch eredis:q(C, ["PING"]) of
                {ok, <<"PONG">>} -> C;
                _ -> catch eredis:stop(C), undefined
            end;
        _ -> undefined
    end.

%% @private
safe_q(Conn, Cmd) ->
    try eredis:q(Conn, Cmd)
    catch _:_ -> {error, down} end.
