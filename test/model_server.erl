-module(model_server).
-export([write/2, ready/0, delete/1, wait_connected/0]).

write(K, V) ->
    ets:insert(server, {K, V}),
    sdiff_serv:write(server, K, V).

ready() ->
    sdiff_serv:ready(server).

delete(K) ->
    ets:delete(server, K),
    sdiff_serv:delete(server, K).

wait_connected() ->
    wait_connected(timer:seconds(3)).

wait_connected(N) when N =< 0 -> false;
wait_connected(N) ->
    case sdiff_serv:client_count(server) of
        0 -> wait_connected(N);
        _ -> true
    end.
