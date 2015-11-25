%%% @doc test handler that ignores protocols and just sends messages across
%%% processes.
%%%
%%% This access module still uses middlemen processes to avoid interacting with
%%% the regular messages that are used between components, especially when
%%% dealing with the middleman FSM.
-module(sdiff_access_msg_client).
-export([init/2, send/2, recv/2, terminate/2]).
%-define(DBG(Prefix, Val), io:format(user, Prefix++" ~p~n", [Val])).
-define(DBG(A, B), ok).
-record(state, {parent :: pid(), remote :: pid()}).

init(Parent, Pid) ->
    %% If the parent is the same proc, don't use messages to avoid interactions
    %% with the FSM.
    Parent = self(), % same proc
    try link(Pid) of
        true ->
            HandlerPid = spawn_link(fun() -> init_loop(Parent, Pid) end),
            receive
                {HandlerPid, ack, Remote} ->
                    {ok, {HandlerPid, Remote}}
            end
    catch
        error:noproc ->
            {error, {noproc, Pid}}
    end.

recv(S={Handler,_}, Timeout) ->
    Ref = erlang:monitor(process, Handler),
    Handler ! {recv, self(), Ref, Timeout},
    receive
        {ok, Ref, Msg} ->
            erlang:demonitor(Ref, [flush]),
            ?DBG("crecv", Msg),
            {ok, Msg, S};
        {error, Ref, Reason} ->
            erlang:demonitor(Ref, [flush]),
            {error, Reason};
        {'DOWN', Ref, process, _, Reason} ->
            {error, Reason}
    end.

send(Msg, S={Handler,Remote}) ->
    Remote ! {'$sdiff', Handler, Msg},
    {ok, S}.

terminate(_, {Handler,_}) ->
    unlink(Handler),
    Handler ! {self(), terminate}.

%% Intermediary
init_loop(Parent, Remote) ->
    Remote ! {'$sdiff', self(), setup},
    receive
        {'$sdiff', Remote, setup_ack} -> ok
    end,
    Parent ! {self(), ack, Remote},
    ?DBG("acked", []),
    loop(#state{parent = Parent, remote = Remote}).

loop(S=#state{parent=Parent, remote = Remote}) ->
    ?DBG("loop", self()),
    receive
        {recv, Parent, Ref, Timeout} ->
            receive
                {'$sdiff', Remote, Msg} ->
                    Parent ! {ok, Ref, Msg};
                {error, Msg} ->
                    Parent ! {error, Ref, Msg}
            after Timeout ->
                ?DBG("timeout", []),
                Parent ! {error, Ref, timeout}
            end,
            loop(S);
        {Parent, terminate} ->
            unlink(Remote)
    end.
