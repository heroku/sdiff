-module(sdiff_serv_middleman).
-behaviour(gen_fsm).
-export([start/4, start_link/4, write/3, delete/2]).
-export([sync_request/3, sync_done/2]).
-export([diff_req/2]).
-export([init/1,
         init/2, init/3, relay/2, relay/3, diff/2, diff/3,
         handle_event/3, handle_sync_event/4, handle_info/3,
         code_change/4, terminate/3]).

-record(context, {server :: pid(),
                  access :: {module(), reference(), term()},
                  readfun :: fun((Key::_) -> Val::_),
                  queue=[] :: [{write, Key::_, Val::_} | {delete, Key::_, Val::_}]}).

%%%%%%%%%%%%%%%%%%
%%% Server API %%%
%%%%%%%%%%%%%%%%%%

start(Server, ReadFun, AccessMod, AccessArgs) ->
    gen_fsm:start(?MODULE, {Server, ReadFun, AccessMod, AccessArgs}, []).

start_link(Server, ReadFun, AccessMod, AccessArgs) ->
    gen_fsm:start_link(?MODULE, {Server, ReadFun, AccessMod, AccessArgs}, []).

write(Pid, Key, Val) ->
    gen_fsm:send_event(Pid, {write, Key, Val}).

delete(Pid, Key) ->
    gen_fsm:send_event(Pid, {delete, Key}).

%%%%%%%%%%%%%%%%
%%% DIFF API %%%
%%%%%%%%%%%%%%%%
sync_request(Pid, Command, Path) ->
    gen_fsm:sync_send_event(Pid, {sync_request, Command, Path}).

sync_done(Pid, Diff) ->
    gen_fsm:send_event(Pid, {sync_done, Diff}).

%%%%%%%%%%%%%%%%%%
%%% ACCESS API %%%
%%%%%%%%%%%%%%%%%%
diff_req(Pid, Ref) ->
    gen_fsm:send_event(Pid, {diff, Ref}).

%%%%%%%%%%%%%%%%%%%%%%%%%
%%% GEN_FSM CALLBACKS %%%
%%%%%%%%%%%%%%%%%%%%%%%%%
init({Server, ReadFun, AccessMod, AccessArgs}) ->
    %% async exchange
    gen_fsm:send_event(self(), init),
    AccessRef = make_ref(),
    {ok, init, #context{server = Server,
                         access = {AccessMod, AccessRef, AccessArgs},
                         readfun = ReadFun}}.

init(init, C=#context{access = {Mod, Ref, Args}}) ->
    State = Mod:init(self(), Ref, Args),
    {next_state, relay, C#context{access = {Mod, Ref, State}}}.

init(_Event, _From, Context) ->
    {stop, race_conditions, Context}.

relay({write, Key, Val}, C=#context{access = {Mod, Ref, State}}) ->
    {ok, NewState} = Mod:send({write, Key, Val}, State),
    {next_state, relay, C#context{access = {Mod, Ref, NewState}}};
relay({delete, Key}, C=#context{access = {Mod, Ref, State}}) ->
    {ok, NewState} = Mod:send({delete, Key}, State),
    {next_state, relay, C#context{access = {Mod, Ref, NewState}}};
relay({diff, Ref}, C=#context{access = {Mod, Ref, State}, server = Server}) ->
    {ok, NewState} = Mod:send(sync_start, State),
    %% TODO: move under a supervisor?
    {ok, _Pid} = sdiff_serv_diff:start_link(Server, self()),
    {next_state, diff, C#context{access = {Mod, Ref, NewState}}}.

relay(_Event, _From, Context) ->
    error_logger:warning_msg("unexpected event: ~p~n",[_Event]),
    {next_state, relay, Context}.

diff({write, _Key, _Val}=Event, C=#context{queue=Queue}) ->
    {next_state, diff, C#context{queue=[Event | Queue]}};
diff({delete, _Key}=Event, C=#context{queue=Queue}) ->
    {next_state, diff, C#context{queue=[Event | Queue]}};
diff({sync_done, Diff}, C=#context{queue=Queue, readfun=Read, access={Mod,Ref,State}}) ->
    QueuedKeys = [element(2, Q) || Q <- Queue],
    Values = [Read(K) || K <- Diff, not lists:member(K, QueuedKeys)],
    {ok, NewState} = lists:foldl(
        fun(Action, {ok,TmpState}) -> Mod:send(Action, TmpState) end,
        {ok, State},
        [sync_seq]++lists:reverse(Queue)++Values++[sync_done]
    ),
    {next_state, relay, C#context{queue=[], access={Mod,Ref,NewState}}}.

diff({sync_request, _Command, _Path} = Event, _From, C=#context{access={Mod,Ref,State}}) ->
    {ok, State2} = Mod:send(Event, State),
    {ok, {sync_response, Bin}, State3} = Mod:recv(State2, timer:seconds(60)),
    {reply, Bin, diff, C#context{access={Mod,Ref,State3}}};
diff(_Event, _From, Context) ->
    error_logger:warning_msg("unexpected event: ~p~n",[_Event]),
    {next_state, diff, Context}.

handle_event(_Event, StateName, Context) ->
    error_logger:warning_msg("unexpected event: ~p~n",[_Event]),
    {next_state, StateName, Context}.

handle_sync_event(_Event, _From, StateName, Context) ->
    error_logger:warning_msg("unexpected event: ~p~n",[_Event]),
    {next_state, StateName, Context}.

handle_info(_Info, StateName, Context) ->
    error_logger:warning_msg("unexpected event: ~p~n", [_Info]),
    {next_state, StateName, Context}.

code_change(_OldVsn, StateName, Context, _Extra) ->
    {ok, StateName, Context}.

terminate(_, _, _) ->
    ok.
