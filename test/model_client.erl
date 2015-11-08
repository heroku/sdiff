-module(model_client).
-export([start/0, write/2, ready/0, delete/1, diff/0, wait_connected/0]).

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
    sdiff_client:diff(client).

wait_connected() ->
    wait_connected(timer:seconds(3)).

wait_connected(N) when N =< 0 -> false;
wait_connected(N) ->
    case sdiff_client:status(client) of
        disconnected -> wait_connected(N);
        _ -> true
    end.
