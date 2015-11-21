-module(prop_sync).
-include_lib("proper/include/proper.hrl").
-export([initial_state/0, command/1,
         precondition/2, next_state/3, postcondition/3]).

%%%%%%%%%%%%%
%%% MODEL %%%
%%%%%%%%%%%%%

-define(CLIENT, model_client).
-define(SERVER, model_server).
-define(BOTH, model_join).

%% The system is asynchronous, but our model will check assuming
%% synchronicity.
%%
%% This means the model needs to be checked against a middleman
%% abstraction that makes sure this lockstep process takes place.
%% This should probably be done through timeout or tricked up
%% token values that get filtered in and out, like
%% `<<"$clock">> => <<"strictly-monotonic:N">>' that get inserted
%% in the server and awaited on on the client before a read.

-record(state, {server,
                clients = []}).

val() ->
    binary().

key() ->
    binary().

prop_sync_cmd() ->
    log_utils:level(warning),
    ?FORALL(Cmds, commands(?MODULE),
             begin
                ?BOTH:start_link(disterl),
                {History, State, Result} = run_commands(?MODULE, Cmds),
                ?BOTH:stop(disterl),
                ?WHENFAIL(io:format("History: ~p\nState: ~p\nResult: ~p\n",
                                    [History,State,Result]),
                          aggregate(command_names(Cmds), Result =:= ok))
            end).
prop_sync_tcp() ->
    log_utils:level(warning),
    ?FORALL(Cmds, commands(?MODULE),
             begin
                ?BOTH:start_link(tcp),
                {History, State, Result} = run_commands(?MODULE, Cmds),
                ?BOTH:stop(tcp),
                ?WHENFAIL(io:format("History: ~p\nState: ~p\nResult: ~p\n",
                                    [History,State,Result]),
                          aggregate(command_names(Cmds), Result =:= ok))
            end).

initial_state() ->
    %% server is a named process we've got to run
    %io:format(user,"init~n",[]),
    lager:debug("prop_init", []),
    #state{server={init, #{}}}.

command(#state{clients = []}) ->
    {call, ?CLIENT, start, []};
command(#state{clients = [{disconnected, _}], server = {await,_}}) ->
    {call, ?CLIENT, wait_connected, []};
command(#state{clients = [{ready, _}], server = {await,_}}) ->
    {call, ?SERVER, wait_connected, []};
command(#state{clients = [{init, _}]}) ->
    oneof([{call, ?CLIENT, write, [key(), val()]},
           {call, ?CLIENT, delete, [key()]},
           {call, ?CLIENT, ready, []}]);
command(#state{server = {init, _}}) ->
    oneof([{call, ?SERVER, write, [key(), val()]},
           {call, ?SERVER, delete, [key()]},
           {call, ?SERVER, ready, []}]);
command(#state{clients = [{ready, _}], server = {ready, _}}) ->
    oneof([{call, ?SERVER, write, [key(), val()]},
           {call, ?SERVER, delete, [key()]},
           {call, ?CLIENT, diff, []},
           {call, ?BOTH, join, []}]).

%% State setup
next_state(S=#state{clients=C}, _V, {call, _, start, []}) ->
    S#state{clients=[{init, #{}}|C]};
next_state(S=#state{clients=[{_, C}]}, _V, {call, ?CLIENT, ready, []}) ->
    S#state{clients=[{disconnected, C}]};
next_state(S=#state{clients=[{disconnected, C}]}, _V, {call, ?CLIENT, wait_connected, []}) ->
    S#state{clients=[{ready, C}]};
next_state(S=#state{server={_, M}}, _V, {call, ?SERVER, ready, []}) ->
    S#state{server={await, M}};
next_state(S=#state{clients=[{ready, _}], server={await, M}}, _V, {call, ?SERVER, wait_connected, []}) ->
    S#state{server={ready,M}};
%% Deletes
next_state(S=#state{clients=[{CS, C}]}, _V,
           {call, ?CLIENT, delete, [K]}) ->
    S#state{clients=[{CS, maps:remove(K, C)}]};
next_state(S=#state{clients=Clients, server={SS, M}}, _V,
           {call, ?SERVER, delete, [K]}) ->
    %% A server delete when both are ready are replicated
    case {Clients, SS} of
        {[{ready,C}], ready} ->
            S#state{clients=[{ready, maps:remove(K,C)}],
                    server={SS, maps:remove(K,M)}};
        _ ->
            S#state{server={SS, maps:remove(K,M)}}
    end;
%% Writes
next_state(S=#state{clients=[{CS, C}]}, _V,
           {call, ?CLIENT, write, [K, V]}) ->
    S#state{clients=[{CS, C#{K => V}}]};
next_state(S=#state{clients=Clients, server={SS, M}}, _V,
           {call, ?SERVER, write, [K, V]}) ->
    %% A server write when both are ready are replicated
    case {Clients, SS} of
        {[{ready,C}], ready} ->
            S#state{clients=[{ready, C#{K => V}}], server={SS, M#{K => V}}};
        _ ->
            S#state{server={SS, M#{K => V}}}
    end;
%% Sync & Read
next_state(S=#state{clients=[{CS,_}], server={_,M}}, _V,
           {call, ?CLIENT, diff, []}) ->
    %% gonna need a precond on both being ready
    S#state{clients=[{CS,M}]};
next_state(State, _V, {call, ?BOTH, join, []}) ->
    %% this is a virtual call to just say "wait up!" and let
    %% async postconditions sync up
    State.

precondition(#state{clients=[{disconnected,_}], server={await,_}}, Call) ->
    Call =:= {call, ?CLIENT, wait_connected, []};
precondition(#state{clients=[{ready,_}], server={await,_}}, Call) ->
    Call =:= {call, ?SERVER, wait_connected, []};
precondition(#state{}, {call, _, wait_connected, []}) ->
    %% only valid when the server is awaiting and client disconnected
    %% or when the client is ready and server awaiting
    false;
precondition(#state{clients=List}, {call, ?CLIENT, Action, _}) ->
    if Action =/= start -> List =/= []
     ; Action =:= start -> List =:= []
    end;
precondition(#state{clients=List, server={S,_}}, {call, ?BOTH, join, []}) ->
    List =/= [] andalso S =:= ready andalso element(1,hd(List)) =:= ready;
precondition(_, _) ->
    true.

postcondition(_S, {call, _, start, []}, Result) ->
    case Result of
        {ok, Pid} when is_pid(Pid) -> true;
        _ -> false
    end;
postcondition(_S, {call, _, ready, []}, Result) ->
    Result =:= ok;
postcondition(_S, {call, _, wait_connected, []}, Result) ->
    Result;
postcondition(_S, {call, _, write, [_K,_V]}, Result) ->
    Result =:= ok;
postcondition(_S, {call, _, delete, [_K]}, Result) ->
    Result =:= ok;
postcondition(_S, {call, _, diff, []}, Result) ->
    lists:member(Result, [async_diff, already_diffing]);
postcondition(#state{clients=[{_,C}], server={_,S}}, {call, ?BOTH, join, []},
              {CliRes, SRes}) ->
    Res = C =:= CliRes andalso S =:= SRes,
    Res orelse ct:pal("~p =:= ~p~nandalso~n~p =:= ~p", [C, CliRes, S, SRes]),
    Res.


