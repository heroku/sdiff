-module(demo).
-export([run/1]).

run(Port) ->
    application:ensure_all_started(ranch),
    application:ensure_all_started(sdiff),
    ets:new(client, [named_table, public, set]),
    ets:new(server, [named_table, public, set]),
    sdiff_serv:start_link({local,server},
                          fun(K) ->
                            case ets:lookup(server, K) of
                                [] -> {delete, K};
                                [{_,V}] -> {write, K, V}
                            end
                          end),
    {ok,_} = ranch:start_listener(
        server, 5,
        ranch_tcp,
        [{port, Port},
         {nodelay,true},
         {max_connections, 1000}],
        sdiff_access_tcp_ranch_server,
        [server]),
    sdiff_client:start_link({local,client},
                            fun({write, K, V}) -> ets:insert(client, {K,V})
                            ;  ({delete, K}) -> ets:delete(client, K)
                            end,
                            sdiff_access_tcp_client,
                            {{127,0,0,1}, Port, [], 10000}),
    WriteServ = fun(K,V) ->
            ets:insert(server,{K,V}),
            sdiff_serv:write(server, K, V)
    end,
    DelServ = fun(K) ->
            ets:delete(server, K),
            sdiff_serv:delete(server, K)
    end,
    ets:insert(client, {<<"key">>, <<"val">>}), % pre-populate the client here
    sdiff_client:write(client, <<"key">>, <<"val">>), % communicate to the tree
    sdiff_client:ready(client),
    WriteServ(<<"key1">>, <<"val1">>),
    WriteServ(<<"key2">>, <<"val2">>),
    WriteServ(<<"key3">>, <<"val3">>),
    ok = sdiff_serv:ready(server),
    io:format("Tables populated...~n"),
    show_state(),
    wait_for_connected(),
    io:format("Stream sync test, adding key4:val4~n"),
    WriteServ(<<"key4">>, <<"val4">>),
    timer:sleep(1000),
    show_state(),
    io:format("Triggering a diff to repair state...~n"),
    sdiff_client:diff(client),
    timer:sleep(1000),
    show_state(),
    {client, server, WriteServ, DelServ}.

show_state() ->
    io:format("server state:~n"),
    io:format("~s~n", [["\t"++io_lib:format("~p:~p~n", [K,V]) || {K,V} <- ets:tab2list(server)]]),
    io:format("client state:~n"),
    io:format("~s~n", [["\t"++io_lib:format("~p:~p~n", [K,V]) || {K,V} <- ets:tab2list(client)]]),
    ok.

wait_for_connected() ->
    case sdiff_client:status(client) of
        disconnected -> wait_for_connected();
        _ -> ok
    end.
