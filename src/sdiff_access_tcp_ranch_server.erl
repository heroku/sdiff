%% @doc Demo implementation over a trusted connection.
%%
%% The owner process is a different one, given merklet forces us
%% to take a stateless accessor function. Function calls to recv
%% are forwarded as messages, but any process can 'send' so
%% that one is direct.
-module(sdiff_access_tcp_ranch_server).
%-behaviour(ranch_protocol).
-export([init/3, send/2, recv/2]).
-export([start_link/4, init/4]).
-record(state, {owner :: pid(),
                to :: pid(),
                csocket :: port()}).
%% ranch state
-record(rstate, {ref :: reference(),
                 report_to :: {pid(), reference()},
                 pending = <<>> :: binary()}).

init(ReportTo, MsgRef, {Owner,Sock}) ->
    try link(Owner) catch error:noproc -> exit({shutdown, owner_missing}) end,
    ReportTo =/= self() andalso link(ReportTo), % don't link if local
    Owner ! {report_to, ReportTo, MsgRef},
    #state{owner=Owner, to=ReportTo, csocket=Sock}.

recv(S=#state{owner=Pid}, Timeout) ->
    Ref = erlang:monitor(process, Pid),
    Pid ! {recv, self(), Ref},
    receive
        {ok, Ref, Msg} ->
            lager:debug("srecv ~p", [Msg]),
            erlang:demonitor(Ref, [flush]),
            {ok, Msg, S};
        {error, Ref, Reason} ->
            erlang:demonitor(Ref, [flush]),
            {error, Reason};
        {'DOWN', Ref, process, _, Reason} ->
            {error, Reason}
    after Timeout ->
        {error, timeout}
    end.


send(Msg, S=#state{csocket=Sock}) ->
    lager:debug("ssend ~p", [Msg]),
    _ = gen_tcp:send(Sock, serialize_msg(Msg)),
    {ok, S}.

%%%%%%%%%%%%%%%%%
%%% Ranch API %%%
%%%%%%%%%%%%%%%%%
start_link(Ref, Socket, Transport, Opts) ->
    Pid = spawn_link(?MODULE, init, [Ref, Socket, Transport, Opts]),
    {ok, Pid}.

init(RanchRef, Socket, Transport, _Opts = [Name]) ->
    ok = ranch:accept_ack(RanchRef),
    ok = sdiff_serv:await(Name),
    Ref = sdiff_serv:connect(Name, ?MODULE, {self(), Socket}),
    receive
        {report_to, ReportTo, MsgRef} ->
            link(ReportTo),
            loop(Socket, Transport, #rstate{ref=Ref, report_to={ReportTo,MsgRef}})
    end.

loop(Socket, Transport, State=#rstate{pending=Pending, report_to={RPid, RRef}}) ->
    case sock_recv(Transport, Socket, Pending, 0, 500) of
        {error, timeout} ->
            loop(Socket, Transport, State);
        {error, Other} ->
            exit({shutdown, {error, Other}});
        {ok, sync_req, NewPending} ->
            sdiff_serv_middleman:diff_req(RPid, RRef),
            loop(Socket, Transport, State#rstate{pending=NewPending});
        {ok, Decoded, NewPending} ->
            receive
                {recv, Pid, Ref} ->
                    Pid ! {ok, Ref, Decoded},
                    loop(Socket, Transport, State#rstate{pending=NewPending})
            end
    end.

%%%%%%%%%%%%%%%
%%% PRIVATE %%%
%%%%%%%%%%%%%%%
serialize_msg(Msg) ->
    BinMsg = term_to_binary(Msg),
    MsgSize = byte_size(BinMsg),
    <<"msg:", MsgSize:32, BinMsg/binary>>.

unserialize_msg(Msg) ->
    <<"msg:", MsgSize:32, Rest/binary>> = Msg,
    if byte_size(Rest) >= MsgSize ->
            <<Decoded:MsgSize/binary, Trailing/binary>> = Rest,
            {msg, binary_to_term(Decoded, [safe]), Trailing};
       byte_size(Rest) < MsgSize ->
            {more, Msg, MsgSize - byte_size(Rest)}
    end.


%% to properly handle timeouts, we'd probably need monotonic time diffs
%% and poll intervals, but at this point who cares, let's just do it wrong
%% and have timeouts much longer by polling many times
sock_recv(Transport, Sock, Pending, 0, Timeout) when byte_size(Pending) > 0 ->
    case unserialize_msg(Pending) of
        {msg, Decoded, NewPending} ->
            {ok, Decoded, NewPending};
        {more, NewPending, NextSize} ->
            sock_recv(Transport, Sock, NewPending, NextSize, Timeout)
    end;
sock_recv(Transport, Sock, Pending, Size, Timeout) ->
    case Transport:recv(Sock, Size, Timeout) of
        {ok, Data} ->
            case unserialize_msg(<<Pending/binary, Data/binary>>) of
                {msg, Decoded, NewPending} ->
                    {ok, Decoded, NewPending};
                {more, NewPending, NextSize} ->
                    sock_recv(Transport, Sock, NewPending, NextSize, Timeout)
            end;
        {error, Reason} ->
            {error, Reason}
    end.

