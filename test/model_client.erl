-module(model_client).
-define(MAGIC_KEY, <<"$$ THIS IS SPECIAL $$">>).
-export([start/0, write/2, ready/0, delete/1, diff/0, sync_diff/0,
         wait_connected/0]).

start() ->
    {ok, {Mod, Config}} = application:get_env(sdiff, config),
    sdiff_client:start_link({local,client},
                            fun({write, K, V}) -> ets:insert(client, {K,V})
                            ;  ({delete, K}) -> ets:delete(client, K)
                            end,
                            Mod,
                            Config).

write(K,V) ->
    ets:insert(client, {K, V}), % manual insert
    sdiff_client:write(client, K, V).

ready() ->
    sdiff_client:ready(client).

delete(K) ->
    ets:delete(client, K), % manual delete
    sdiff_client:delete(client, K).

diff() ->
    case sdiff_client:diff(client) of
        async_diff -> async_diff;
        already_diffing -> diff()
    end.

sync_diff() ->
    case sdiff_client:sync_diff(client) of
        done ->
            {done, tab_to_map(client)};
        already_diffing ->
            %% To make model checking easier, we work with the assumption that
            %% sync_diff forces a state convergence. Otherwise it is very
            %% difficult to know when prior operations will have finished when
            %% the model is synchronous but the system asynchronous (except for
            %% this and model_join:join/0)
            sync_diff()
    end.

wait_connected() ->
    wait_connected(timer:seconds(3)).

wait_connected(N) when N =< 0 -> false;
wait_connected(N) ->
    case sdiff_client:status(client) of
        disconnected -> wait_connected(N);
        _ -> true
    end.

tab_to_map(Tid) ->
    maps:remove(?MAGIC_KEY, maps:from_list(ets:tab2list(Tid))).
