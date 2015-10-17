-module(client_SUITE).
-compile(export_all).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

all() -> [no_self_rewrite].

%%%%%%%%%%%%%%%%%%%%%%
%%% Setup/Teardown %%%
%%%%%%%%%%%%%%%%%%%%%%
init_per_testcase(_, Config) ->
    %% setup a sdiff server
    ets:new(server, [named_table, public, set]),
    {ok, SdiffServ} = sdiff_serv:start_link(
        {local, whocares},
        fun(K) ->
                case ets:lookup(server, K) of
                    [] -> {delete, K};
                    [{_,V}] -> {write, K, V}
                end
        end),
    Write = fun({write, K, V}) ->
                ets:insert(server, {K, V}),
                sdiff_serv:write(SdiffServ, K, V)
            ;  ({delete, K}) ->
                ets:delete(server, K),
                sdiff_serv:delete(SdiffServ, K)
            end,
    %% setup a server middleman
    {ok, Middleman} = sdiff_access_msg_server:start_link(SdiffServ),
    [{server_middleman, Middleman},
     {server_write, Write},
     {server_sdiff, SdiffServ} | Config].

end_per_testcase(_, Config) ->
    Middleman = ?config(server_middleman, Config),
    SdiffServ = ?config(server_sdiff, Config),
    kill(Middleman),
    kill(SdiffServ),
    ets:delete(server),
    ok.

%%%%%%%%%%%%%%%%%%
%%% Test Cases %%%
%%%%%%%%%%%%%%%%%%

%% A client setting itself up by writing to itself does not end up rewriting its
%% data with its own callbacks.
no_self_rewrite(Config) ->
    %% this call is assumed to be from the local end to set up initial state. The
    %% callback above shouldn't get called. The call is also synchronous, which gives
    %% us a decent chance (as long as callbacks are synchronous) that as soon as
    %% we return, we know if side effects have happened.
    Self = self(),
    Callback = fun(_) -> kill(Self, failed) end,
    {ok, Client} = sdiff_client:start_link(
        Callback,
        sdiff_access_msg_client,
        ?config(server_middleman, Config)
    ),
    ?assertEqual(ok, catch sdiff_client:write(Client, <<"key">>, <<"val">>)),
    %% We passed by staying alive.
    kill(Client),
    ok.

%%%%%%%%%%%%%%%
%%% Helpers %%%
%%%%%%%%%%%%%%%
kill(Pid) -> kill(Pid, kill).

kill(Pid, Reason) ->
    unlink(Pid),
    exit(Pid, Reason),
    Ref = erlang:monitor(process, Pid),
    receive
        {'DOWN', Ref, process, Pid, _} ->
            ok
    after 5000 ->
        error(shutdown_timeout)
    end.
