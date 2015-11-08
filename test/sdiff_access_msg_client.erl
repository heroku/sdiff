-module(sdiff_access_msg_client).
-export([init/2, send/2, recv/2, terminate/2]).
-record(state, {remote :: pid()}).

init(Parent, Pid) ->
    Parent = self(), % same proc
    try link(Pid) of
        true ->
            Pid ! {'$sdiff', self(), setup},
            receive
                {'$sdiff', Pid, setup_ack} -> ok
            end,
            {ok, #state{remote=Pid}}
    catch
        error:noproc ->
            {error, {noproc, Pid}}
    end.

recv(S=#state{remote=Pid}, Timeout) ->
    receive
        {'$sdiff', Pid, Msg} -> {ok, Msg, S};
        {error, Reason} -> {error, Reason}
    after Timeout ->
        {error, timeout}
    end.

send(Msg, S=#state{remote=Pid}) ->
    Pid ! {'$sdiff', self(), Msg},
    {ok, S}.

terminate(_, #state{remote=Pid}) ->
    unlink(Pid).
