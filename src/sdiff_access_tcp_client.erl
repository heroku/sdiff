-module(sdiff_access_tcp_client).
-export([init/2, send/2, recv/2, terminate/2]).
-record(state, {port :: port(),
                pending = <<>>}).

%% init in the owning process
init(Parent, {Address, Port, Options, Timeout}) ->
    Parent = self(), % same proc
    Opts = [{active,false}, binary, {nodelay,true} | Options],
    case gen_tcp:connect(Address, Port, Opts, Timeout) of
        {ok, P} ->
            lager:debug("cconnected ~p", [P]),
            {ok, #state{port=P}};
        {error, Reason} ->
            {error, Reason}
    end.

recv(S=#state{port=Sock, pending=Pending}, TimeOut) ->
    case sock_recv(Sock, Pending, 0, TimeOut) of
        {ok, Decoded, NewPending} ->
            lager:debug("crecv ~p", [Decoded]),
            {ok, Decoded, S#state{pending=NewPending}};
        {error, Reason} ->
            {error, Reason}
    end.


send(Msg, S=#state{port=Sock}) ->
    ok = gen_tcp:send(Sock, serialize_msg(Msg)),
    lager:debug("csend ~p to ~p", [Msg, Sock]),
     {ok, S}.

terminate(_Reason, #state{port=Sock}) ->
    catch gen_tcp:close(Sock).

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
            {msg, binary_to_term(Decoded,[safe]), Trailing};
       byte_size(Rest) < MsgSize ->
            {more, Msg, MsgSize - byte_size(Rest)}
    end.


%% to properly handle timeouts, we'd probably need monotonic time diffs
%% and poll intervals, but at this point who cares, let's just do it wrong
%% and have timeouts much longer by polling many times
sock_recv(Sock, Pending, 0, Timeout) when byte_size(Pending) > 0 ->
    case unserialize_msg(Pending) of
        {msg, Decoded, NewPending} ->
            {ok, Decoded, NewPending};
        {more, NewPending, NextSize} ->
            sock_recv(Sock, NewPending, NextSize, Timeout)
    end;
sock_recv(Sock, Pending, Size, Timeout) ->
    case gen_tcp:recv(Sock, Size, Timeout) of
        {ok, Data} ->
            case unserialize_msg(<<Pending/binary, Data/binary>>) of
                {msg, Decoded, NewPending} ->
                    {ok, Decoded, NewPending};
                {more, NewPending, NextSize} ->
                    sock_recv(Sock, NewPending, NextSize, Timeout)
            end;
        {error, Reason} ->
            {error, Reason}
    end.
