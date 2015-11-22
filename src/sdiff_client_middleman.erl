%%% @doc Middleman for sdiff's client. This module is a gen_fsm, but it is
%%% deceptively so. A lot of the event handling is done manually with the
%%% `to_state/2' function, which reads from a socket or relevant events in
%%% the mailbox, and manually calls one of the state functions as required.
%%%
%%% This is because sdiff assumes passive/blocking sockets or transport
%%% layers for the client. An active conneection could be extended by
%%% letting the `recv' callback of the access module return a `skip' value
%%% however.
-module(sdiff_client_middleman).
-behaviour(gen_fsm).
-export([start/3, start/4, start_link/3, start_link/4, state/1, state/2]).
-export([init/1, disconnected/2, disconnected/3, relay/2, relay/3,
         diff/2, diff/3, pre_diff/2, pre_diff/3, post_diff/2, post_diff/3,
         handle_event/3, handle_sync_event/4, handle_info/3,
         code_change/4, terminate/3]).

-record(context, {client :: pid(),
                  init_access :: {module(), term()},
                  access :: {module(), term()},
                  tree = undefined,
                  backoff :: backoff:backoff()}).

%%%%%%%%%%%%%%%%%%
%%% CLIENT API %%%
%%%%%%%%%%%%%%%%%%
start(Client, AccessMod, AccessArgs) ->
    start(Client, [], AccessMod, AccessArgs).

start(Client, Opts, AccessMod, AccessArgs) ->
    gen_fsm:start(?MODULE, {Client, Opts, AccessMod, AccessArgs}, []).

start_link(Client, AccessMod, AccessArgs) ->
    start_link(Client, [], AccessMod, AccessArgs).

start_link(Client, Opts, AccessMod, AccessArgs) ->
    gen_fsm:start_link(?MODULE, {Client, Opts, AccessMod, AccessArgs}, []).

state(Pid) ->
    state(Pid, 5000).

state(Pid, Timeout) ->
    Ref = erlang:monitor(process, Pid),
    Pid ! {state, self(), Ref},
    receive
        {Ref, Reply} ->
            erlang:demonitor(Ref, [flush]),
            case Reply of
                disconnected -> Reply;
                relay -> Reply;
                diff -> Reply;
                pre_diff -> diff;
                post_diff -> diff
            end;
        {'DOWN', Ref, process, Pid, Reason} ->
            error(Reason)
    after Timeout ->
        erlang:demonitor(Ref, [flush]),
        error({timeout, [Pid, Timeout]})
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%
%%% GEN_FSM CALLBACKS %%%
%%%%%%%%%%%%%%%%%%%%%%%%%
init({Client, Opts, Mod, Args}) ->
    lager:debug("up"),
    % async startup
    BackoffStart = proplists:get_value(backoff_start, Opts, 1),
    BackoffMax = proplists:get_value(backoff_max, Opts, infinity),
    BackoffType = proplists:get_value(backoff_type, Opts, jitter),
    Backoff = backoff:type(
            backoff:init(BackoffStart, BackoffMax, self(), reconnect),
            BackoffType
    ),
    gen_fsm:send_event(self(), reconnect),
    {ok, disconnected, #context{client=Client,
                                init_access = {Mod, Args},
                                backoff=Backoff}}.

disconnected(reconnect, C=#context{init_access={Mod, Args}, backoff=Backoff}) ->
    case Mod:init(self(), Args) of
        {ok, State} ->
            {_, NewBackoff} = backoff:succeed(Backoff),
            to_state(relay, C#context{access={Mod, State}, backoff=NewBackoff});
        Other ->
            lager:info("failed to reconnect for reason ~p~n", [Other]),
            {_, NewBackoff} = backoff:fail(Backoff),
            backoff:fire(NewBackoff),
            {next_state, disconnected, C#context{backoff=NewBackoff}}
            %{stop, {shutdown, Other}, C}
    end;
disconnected(Event, C=#context{}) ->
    lager:warning("sdiff_client_middleman unexpected event in state ~p: ~p~n",
                  [disconnected, Event]),
    {next_state, disconnected, C}.


disconnected(_Event, _From, Context) ->
    {stop, race_conditions, Context}.

relay({write, _Key, _Val} = Event, C=#context{client=Client}) ->
    Client ! Event,
    to_state(relay, C);
relay({delete, _Key} = Event, C=#context{client=Client}) ->
    Client ! Event,
    to_state(relay, C);
relay({diff, Pid, Tree}, C=#context{client=Pid, access={Mod, State}}) ->
    {ok, NewState} = Mod:send(sync_req, State),
    to_state(pre_diff, C#context{access={Mod, NewState}, tree=Tree}).

relay(Event, _From, Context) ->
    lager:warning("sdiff_client_middleman unexpected event in state ~p: ~p~n",
                  [relay, Event]),
    {next_state, relay, Context}.

%% Events in-flight get purged
pre_diff({write, _Key, _Val} = Event, C=#context{client=Client}) ->
    Client ! Event,
    to_state(pre_diff, C);
pre_diff({delete, _Key} = Event, C=#context{client=Client}) ->
    Client ! Event,
    to_state(pre_diff, C);
%% Time to start -- stuff is purged
pre_diff(sync_start, C=#context{tree=Tree}) ->
    SerializedTree = merklet:access_serialize(Tree),
    to_state(diff, C#context{tree=SerializedTree}).

pre_diff(Event, _From, Context) ->
    lager:warning("sdiff_client_middleman unexpected event in state ~p: ~p~n",
                  [pre_diff, Event]),
    {next_state, pre_diff, Context}.

diff({sync_request, Cmd, Path}, C=#context{access={Mod, State}, tree=T}) ->
    Bin = T(Cmd, Path),
    {ok, NewState} = Mod:send({sync_response, Bin}, State),
    to_state(diff, C#context{access={Mod, NewState}});
diff(sync_seq, C=#context{client=Client}) ->
    to_state(post_diff, C#context{tree=undefined}).

diff(Event, _From, Context) ->
    lager:warning("sdiff_client_middleman unexpected event in state ~p: ~p~n",
                  [diff, Event]),
    {next_state, relay, Context}.

%% Sync up diffed elements
post_diff({write, _Key, _Val} = Event, C=#context{client=Client}) ->
    Client ! Event,
    to_state(post_diff, C);
post_diff({delete, _Key} = Event, C=#context{client=Client}) ->
    Client ! Event,
    to_state(post_diff, C);
%% Time to go back to relay -- everything is up to date
post_diff(sync_done, C=#context{client=Client}) ->
    Client ! {diff_done, self()},
    to_state(relay, C).

post_diff(Event, _From, Context) ->
    lager:warning("sdiff_client_middleman unexpected event in state ~p: ~p~n",
                  [post_diff, Event]),
    {next_state, post_diff, Context}.

handle_event(Event, StateName, Context) ->
    lager:warning("sdiff_client_middleman unexpected all-state event in state ~p: ~p~n",
                  [StateName, Event]),
    {next_state, StateName, Context}.

handle_sync_event(Event, _From, StateName, Context) ->
    lager:warning("sdiff_client_middleman unexpected all-state sync event in state ~p: ~p~n",
                  [StateName, Event]),
    {next_state, StateName, Context}.

%handle_info(Info={diff,_,_}, relay, Context) ->
%    %% redirect content
%    relay(Info, Context);
handle_info({timeout, _, reconnect}, disconnected, Context) ->
    disconnected(reconnect, Context);
handle_info({diff, Parent, _}, disconnected, C=#context{}) ->
    Parent ! {diff_aborted, self()},
    {next_state, disconnected, C};
handle_info(Info, StateName, Context) ->
    lager:warning("sdiff_client_middleman unexpected info in state ~p: ~p~n",
                  [StateName, Info]),
    {next_state, StateName, Context}.

code_change(_OldVsn, StateName, Context, _Extra) ->
    {ok, StateName, Context}.

terminate(_, _, _) ->
    lager:debug("down"),
    ok.

%%%%%%%%%%%%%%%
%%% HELPERS %%%
%%%%%%%%%%%%%%%
to_state(StateName, C=#context{client=Pid, access={Mod, State}}) ->
    case receive_or_recv(StateName, Pid, Mod, State) of
        {ok, Msg, NewState} ->
            ?MODULE:StateName(Msg, C#context{access={Mod, NewState}});
        {error, Reason} ->
            lager:info("disconnecting from state ~p", [StateName]),
            disconnect(Reason, C)
%            {stop, {shutdown, {error, Reason}}, C}
    end.

disconnect(Reason, C=#context{tree=T, client=Client}) when T =/= undefined ->
    Client ! {diff_aborted, self()},
    disconnect(Reason, C#context{tree=undefined});
disconnect(Reason, C=#context{access={Mod, Args}, backoff=Backoff}) ->
    _ = Mod:terminate(Reason, Args),
    lager:info("disconnected for reason ~p~n", [Reason]),
    {_, NewBackoff} = backoff:fail(Backoff),
    backoff:fire(NewBackoff),
    {next_state, disconnected, C#context{backoff=NewBackoff, access=undefined}}.

receive_or_recv(ToState, Parent, Access, AccessState) ->
    %% To allow total non-blockiness, don't go through official OTP channels
    receive
        {state, Caller, Ref} ->
            Caller ! {Ref, ToState},
            receive_or_recv(ToState, Parent, Access, AccessState);
        {diff, Parent, Tree} ->
            {ok, {diff, Parent, Tree}, AccessState}
    after 0 ->
        case Access:recv(AccessState, 10) of
            {error, timeout} ->
                receive_or_recv(ToState, Parent, Access, AccessState);
            {error, Reason} ->
                {error, Reason};
            Val ->
                Val
        end
    end.
