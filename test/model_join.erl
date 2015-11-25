-module(model_join).
-define(MAGIC_KEY, <<"$$ THIS IS SPECIAL $$">>).
-export([start_link/1, stop/1, join/0]).

start_link(disterl) ->
    application:ensure_all_started(sdiff),
    ets:new(client, [named_table, public, set]),
    ets:new(server, [named_table, public, set]),
    {ok, SdiffServ} = sdiff_serv:start_link({local,server},
                          fun(K) ->
                            case ets:lookup(server, K) of
                                [] -> {delete, K};
                                [{_,V}] -> {write, K, V}
                            end
                          end),
    {ok, Middleman} = sdiff_access_msg_server:start_link(SdiffServ),
    register(server_middleman, Middleman),
    application:set_env(sdiff, config, {sdiff_access_msg_client, Middleman});
start_link(tcp) ->
    application:ensure_all_started(ranch),
    application:ensure_all_started(sdiff),
    ets:new(client, [named_table, public, set]),
    ets:new(server, [named_table, public, set]),
    {ok, _} = sdiff_serv:start_link({local,server},
                  fun(K) ->
                    case ets:lookup(server, K) of
                        [] -> {delete, K};
                        [{_,V}] -> {write, K, V}
                    end
                  end),
    Port = 8765,
    {ok,_} = ranch:start_listener(
        server, 5,
        ranch_tcp,
        [{port, Port},
         {nodelay,true},
         {max_connections, 1000}],
        sdiff_access_tcp_ranch_server,
        [server]),
    application:set_env(sdiff, config, {sdiff_access_tcp_client,
                                        {{127,0,0,1}, Port, [], 10000}}).

stop(disterl) ->
    Middleman = whereis(server_middleman),
    Server = whereis(server),
    Client = whereis(client),
    lager:debug("links: ~p", [process_info(self(), links)]),
    lager:debug("shutdown: ~p", [[self(), Client, Middleman, Server]]),
    [unlink(Pid) || Pid <- [Client, Middleman, Server],
                    Pid =/= undefined],
    [begin
        exit(Pid, shutdown), wait_dead(Pid)
     end || Pid <- [Client, Middleman, Server],
            Pid =/= undefined],
    ets:delete(server),
    ets:delete(client);
stop(tcp) ->
    [begin unlink(Pid), exit(Pid, shutdown), wait_dead(Pid) end
     || Pid <- [whereis(client)], Pid =/= undefined],
    ranch:stop_listener(server),
    [begin unlink(Pid), exit(Pid, shutdown), wait_dead(Pid) end
     || Pid <- [whereis(server)], Pid =/= undefined],
    ets:delete(server),
    ets:delete(client).


join() ->
    %% Synchronize here. We do it by inserting a magic key with a unique
    %% value and waiting for it to come to the client, meaning everything in-
    %% between should be there.
    %% This relies on a property by which a stream of updates is in order,
    %% and interrupted by a diff sequence, which is currently an implementation
    %% detail.
    %% The other problem is that the connection process is asynchronous and can
    %% fail if it came too fast right after the first declaration of
    %% readiness. Because of this, we try to re-write the token value
    %% multiple times in the loop.
    Unique = term_to_binary(make_ref()),
    write_wait_for_value(?MAGIC_KEY, Unique, timer:seconds(3)),
    %% We're in sync. Turn the tables to maps
    {tab_to_map(client), tab_to_map(server)}.

write_wait_for_value(Key, Val, N) when N =< 0 ->
    error({join_timeout, {expected, Val, ets:lookup(client, Key)}});
write_wait_for_value(Key, Val, N) ->
    model_server:write(Key, Val),
    case ets:lookup(client, Key) of
        [{Key, Val}] ->
            ok;
        _ -> % oldval
            timer:sleep(10),
            write_wait_for_value(Key, Val, N-10)
    end.

tab_to_map(Tid) ->
    maps:remove(?MAGIC_KEY, maps:from_list(ets:tab2list(Tid))).

wait_dead(Pid) ->
    case is_process_alive(Pid) of
        true -> timer:sleep(1), wait_dead(Pid);
        false -> ok
    end.
