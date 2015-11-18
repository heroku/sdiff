-module(sdiff_client_middleman).
-behaviour(gen_fsm).
-export([start/3, start_link/3]).
-export([init/1, init/2, init/3,
         relay/2, relay/3, diff/2, diff/3,
         handle_event/3, handle_sync_event/4, handle_info/3,
         code_change/4, terminate/3]).

-record(context, {client :: pid(),
                  access :: {module(), term()},
                  tree = undefined}).

%%%%%%%%%%%%%%%%%%
%%% CLIENT API %%%
%%%%%%%%%%%%%%%%%%
start(Client, AccessMod, AccessArgs) ->
    gen_fsm:start(?MODULE, {Client, AccessMod, AccessArgs}, []).

start_link(Client, AccessMod, AccessArgs) ->
    gen_fsm:start_link(?MODULE, {Client, AccessMod, AccessArgs}, []).

%%%%%%%%%%%%%%%%%%%%%%%%%
%%% GEN_FSM CALLBACKS %%%
%%%%%%%%%%%%%%%%%%%%%%%%%
init({Client, Mod, Args}) ->
    % async startup
    gen_fsm:send_event(self(), init),
    {ok, init, #context{client=Client, access={Mod, Args}}}.

init(init, C=#context{access={Mod, Args}}) ->
    case Mod:init(self(), Args) of
        {ok, State} ->
            put(connected, true),
            to_state(relay, C#context{access={Mod, State}});
        Other ->
            {stop, {shutdown, Other}, C}
    end.

init(_Event, _From, Context) ->
    {stop, race_conditions, Context}.

relay({write, _Key, _Val} = Event, C=#context{client=Client}) ->
    Client ! Event,
    to_state(relay, C);
relay({delete, _Key} = Event, C=#context{client=Client}) ->
    Client ! Event,
    to_state(relay, C);
relay({diff, Pid, Tree}, C=#context{client=Pid, access={Mod, State}}) ->
    {ok, NewState} = Mod:send(sync_req, State),
    to_state(relay, C#context{access={Mod, NewState}, tree=Tree});
relay(sync_start, C=#context{tree=Tree}) ->
    SerializedTree = merklet:access_serialize(Tree),
    to_state(diff, C#context{tree=SerializedTree}).

relay(_Event, _From, Context) ->
    error_logger:warning_msg("unexpected event on ln ~p: ~p~n",[?LINE, _Event]),
    {next_state, relay, Context}.

diff({sync_request, Cmd, Path}, C=#context{access={Mod, State}, tree=T}) ->
    Bin = T(Cmd, Path),
    {ok, NewState} = Mod:send({sync_response, Bin}, State),
    to_state(diff, C#context{access={Mod, NewState}});
diff(sync_done, C=#context{client=Client}) ->
    Client ! {diff_done, self()},
    to_state(relay, C#context{tree=undefined}).

diff(_Event, _From, Context) ->
    error_logger:warning_msg("unexpected event on ln ~p: ~p~n",[?LINE, _Event]),
    {next_state, relay, Context}.

handle_event(_Event, StateName, Context) ->
    error_logger:warning_msg("unexpected event on ln ~p: ~p~n",[?LINE, _Event]),
    {next_state, StateName, Context}.

handle_sync_event(_Event, _From, StateName, Context) ->
    error_logger:warning_msg("unexpected event on ln ~p: ~p~n",[?LINE, _Event]),
    {next_state, StateName, Context}.

handle_info(Info={diff,_,_}, relay, Context) ->
    %% redirect content
    relay(Info, Context);
handle_info(_Info, StateName, Context) ->
    error_logger:warning_msg("unexpected event on ln ~p: ~p~n", [?LINE, _Info]),
    {next_state, StateName, Context}.

code_change(_OldVsn, StateName, Context, _Extra) ->
    {ok, StateName, Context}.

terminate(_, _, _) ->
    ok.

%%%%%%%%%%%%%%%
%%% HELPERS %%%
%%%%%%%%%%%%%%%
to_state(StateName, C=#context{client=Pid, access={Mod, State}}) ->
    case receive_or_recv(Pid, Mod, State) of
        {ok, Msg, NewState} ->
            ?MODULE:StateName(Msg, C#context{access={Mod, NewState}});
        {error, Reason} ->
            {stop, {shutdown, {error, Reason}}, C}
    end.

receive_or_recv(Parent, Access, AccessState) ->
    %% To allow total non-blockiness, don't go through official OTP channels
    receive
        {diff, Parent, Tree} -> {ok, {diff, Parent, Tree}, AccessState}
    after 0 ->
        case Access:recv(AccessState, 500) of
            {error, timeout} -> receive_or_recv(Parent, Access, AccessState);
            {error, Reason} -> {error, Reason};
            Val -> Val
        end
    end.
