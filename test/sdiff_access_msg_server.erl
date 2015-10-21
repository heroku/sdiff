-module(sdiff_access_msg_server).
-export([init/3, send/2, recv/2]).
-export([start_link/1, init/1]).
%-define(DBG(Prefix, Val), io:format(user, Prefix++" ~p~n", [Val])).
-define(DBG(A, B), ok).
-record(state, {owner :: pid(),
                to :: pid(),
                remote :: pid()}).

-record(rstate, {ref :: reference(),
                 report_to :: {pid(), reference()}}).

init(ReportTo, MsgRef, {Owner,Remote}) ->
    link(Owner),
    ReportTo =/= self() andalso link(ReportTo),
    Owner ! {report_to, ReportTo, MsgRef},
    #state{owner=Owner, to=ReportTo, remote=Remote}.

recv(S=#state{owner=Pid}, Timeout) ->
    Ref = erlang:monitor(process, Pid),
    Pid ! {recv, self(), Ref},
    receive
        {ok, Ref, Msg} ->
            erlang:demonitor(Ref, [flush]),
            ?DBG("srecv", Msg),
            {ok, Msg, S};
        {error, Ref, Reason} ->
            erlang:demonitor(Ref, [flush]),
            {error, Reason};
        {'DOWN', Ref, process, _, Reason} ->
            {error, Reason}
    after Timeout ->
        {error, timeout}
    end.

send(Msg, State = #state{owner=ReplyTo, remote=Pid}) ->
    ?DBG("ssend", Msg),
    Pid ! {'$sdiff', ReplyTo, Msg},
    {ok, State}.

%%%%%%%%%%%%%%%%%%%%
%%% External API %%%
%%%%%%%%%%%%%%%%%%%%
start_link(AccessServ) ->
    Pid = spawn_link(?MODULE, init, [AccessServ]),
    {ok, Pid}.

init(Name) ->
    Remote = receive
        {'$sdiff', RemotePid, setup} -> % go signal
            RemotePid ! {'$sdiff', self(), setup_ack},
            RemotePid
    end,
    link(Remote),
    ok = sdiff_serv:await(Name),
    Ref = sdiff_serv:connect(Name, ?MODULE, {self(), Remote}),
    receive
        {report_to, ReportTo, MsgRef} ->
            link(ReportTo),
            loop(Remote, #rstate{ref=Ref, report_to={ReportTo,MsgRef}})
    end.

loop(Remote, State=#rstate{report_to={RPid, RRef}}) ->
    receive
        {'$sdiff', Remote, sync_req} ->
            RPid ! {diff, RRef},
            loop(Remote, State);
        {'$sdiff', Remote, Msg} ->
            receive
                {recv, Pid, Ref} ->
                    Pid ! {ok, Ref, Msg},
                    loop(Remote, State)
            end
    end.

