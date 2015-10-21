-module(sdiff_serv).
-behaviour(gen_server).
-export([write/3, delete/2,
         await/1, ready/1, connect/3,
         client_count/1]).
-export([start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3, terminate/2]).

-record(state, {ready = false :: boolean(),
                awaiting = [] :: list(),
                canonical = undefined :: merklet:tree(),
                clients = #{},
                readfun :: fun((Key::_) -> {write, Key, Val::_} | {delete, Key})
               }).
-record(client, {parent :: pid(),
                 access :: {module(), reference(), term()},
                 readfun :: fun((Key::_) -> Val::_)}).


%%%%%%%%%%%%%%
%%% PUBLIC %%%
%%%%%%%%%%%%%%
start_link(Name, ReadFun) ->
    gen_server:start_link(Name, ?MODULE, [ReadFun], []).

write(Name, Key, Val) ->
    gen_server:call(Name, {write, Key, Val}).

delete(Name, Key) ->
    gen_server:call(Name, {delete, Key}).

%% Wait for a notification from the server once ready
await(Name) ->
    gen_server:call(Name, await, infinity).

%% Let server know all background data is in place and can
%% start to sync
ready(Name) ->
    gen_server:cast(Name, ready).

connect(Name, Access, AccessArgs) ->
    gen_server:call(Name, {connect, Access, AccessArgs}).

%% Debug function to get an idea of how many clients are connected
client_count(Name) ->
    gen_server:call(Name, client_count).

%%%%%%%%%%%%%%%%%%
%%% GEN_SERVER %%%
%%%%%%%%%%%%%%%%%%
init([ReadFun]) ->
    Tree = undefined,
    %% TODO: trap exits of clients
    {ok, #state{canonical=Tree, readfun=ReadFun}}.

%% Awaiting management
handle_call(await, From, State=#state{ready=false, awaiting=List}) ->
    {noreply, State#state{awaiting=[From|List]}};
handle_call(await, _From, State) ->
    {reply, ok, State};
%% Key/Val management for updates
handle_call({write, Key, Val}, _From, State=#state{canonical=Tree, clients=Clients}) ->
    maps:fold(fun(_Ref, Pid, _) -> Pid ! {write, self(), Key, Val} end, ignore, Clients),
    {reply, ok, State#state{canonical=merklet:insert({Key, term_to_binary(Val)}, Tree)}};
handle_call({delete, Key}, _From, State=#state{canonical=Tree, clients=Clients}) ->
    maps:fold(fun(_Ref, Pid, _) -> Pid ! {delete, self(), Key} end, ignore, Clients),
    {reply, ok, State#state{canonical=merklet:delete(Key, Tree)}};
%% Client subscription
handle_call({connect, Access, AccessArgs}, _From,
            State=#state{clients=Clients, readfun=ReadFun}) ->
    Self = self(),
    {Pid, Ref} = spawn_monitor(fun() -> client(Self, ReadFun, Access, AccessArgs) end),
    {reply, Ref, State#state{clients=Clients#{Ref => Pid}}};
%% Diff management
handle_call(tree, _From, State=#state{canonical=Tree}) ->
    %% Actual diffing. For this one we must make a local copy for he current
    %% operation, then make one of the remote tree.
    {reply, Tree, State};
handle_call(client_count, _From, State=#state{clients=Clients}) ->
    {reply, maps:size(Clients), State};
%% Catch-all
handle_call(Call, _From, State=#state{}) ->
    error_logger:warning_report(unexpected_msg, {?MODULE, call, Call}),
    {noreply, State}.

handle_cast(ready, State=#state{ready=true}) ->
    {noreply, State};
handle_cast(ready, State=#state{ready=false, awaiting=Waiters}) ->
    [gen_server:reply(Waiter, ok) || Waiter <- Waiters],
    {noreply, State#state{ready=true, awaiting=[]}};
handle_cast(Cast, State=#state{}) ->
    error_logger:warning_report(unexpected_msg, {?MODULE, cast, Cast}),
    {noreply, State}.

handle_info({'DOWN', Ref, process, _, normal}, State=#state{clients=Clients}) ->
    %% Process ended normally, assume the answer was sent.
    {noreply, State=#state{clients=maps:remove(Ref, Clients)}};
handle_info({'DOWN', Ref, process, Pid, Error}, State=#state{clients=Clients}) ->
    %% Process ended abnormally. Assume answer wasn't sent.
    case Clients of
        #{Ref := Pid} ->
            {noreply, State#state{clients=maps:remove(Ref, Clients)}};
        #{} ->
            error_logger:warning_report(unexpected_monitor, {?MODULE, Pid, Error}),
            {noreply, State}
    end;
handle_info(Info, State=#state{}) ->
    error_logger:warning_report(unexpected_msg, {?MODULE, info, Info}),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate({shutdown, retire}, _State) ->
    {shutdown, retire}.

%%%%%%%%%%%%%%%
%%% PRIVATE %%%
%%%%%%%%%%%%%%%

client(Parent, ReadFun, Access, AccessArgs) ->
    %% Any problem having this local?
    AccessRef = make_ref(),
    AccessState = Access:init(self(), AccessRef, AccessArgs),
    client_loop(#client{parent = Parent,
                        access = {Access, AccessRef, AccessState},
                        readfun = ReadFun}).

%% Info only, being forwarded to the client.
client_loop(S=#client{parent=Parent, access={Access, AccessRef, AccessState}}) ->
    receive
        %% Comes from our local server gen_server
        {write, Parent, Key, Val} ->
            {ok, AS} = Access:send({write, Key, Val}, AccessState),
            client_loop(S#client{access={Access, AccessRef, AS}});
        {delete, Parent, Key} ->
            {ok, AS} = Access:send({delete, Key}, AccessState),
            client_loop(S#client{access={Access, AccessRef, AS}});
        %% this should essentially come from the remote end's access function
        %% telling us to initiate the diff.
        {diff, AccessRef} ->
            client_diff(S)
    end.

client_diff(S=#client{parent=Parent, access={Access, AccessRef, AccessState}}) ->
    %% Remote = InitRemote(),
    %% run the diff somewhere? make the queuing of commands implicit?
    {ok, AS} = Access:send(sync_start, AccessState),
    From = self(),
    spawn_link(fun() ->
        LocalisedRemote = merklet:access_unserialize(
            fun(Command, Path) ->
                R = make_ref(),
                From ! {sync_request, self(), R, Command, Path},
                receive
                    {R, {sync_response, Bin}} ->
                        Bin
                end
        end),
        Tree = gen_server:call(Parent, tree),
        Diff = merklet:dist_diff(Tree, LocalisedRemote),
        From ! {sync_done, Diff}
    end),
    client_diff_loop(S#client{access={Access, AccessRef, AS}}, []).

client_diff_loop(S=#client{parent=Parent, access={Access, AccessRef, AccessState},
                           readfun=Read}, Queued) ->
    receive
        {write, Parent, Key, Val} ->
            client_diff_loop(S, [{write, Key, Val} | Queued]);
        {delete, Parent, Key} ->
            client_diff_loop(S, [{delete, Key} | Queued]);
        %% comes from the differ process
        {sync_done, Diff} ->
            QueuedKeys = [element(2, Q) || Q <- Queued],
            Values = [Read(K) || K <- Diff, not lists:member(K, QueuedKeys)],
            {ok, AS} = lists:foldl(
                fun(Action, {ok,ASTmp}) -> Access:send(Action, ASTmp) end,
                {ok,AccessState},
                [sync_done]++lists:reverse(Queued)++Values
            ),
            client_loop(S#client{access={Access, AccessRef, AS}});
        %% sent from the differ, forward, and send back the response.
        {sync_request, From, Ref, Cmd, Path} ->
            {ok, AS1} = Access:send({sync_request, Cmd, Path}, AccessState),
            {ok, {sync_response, Bin}, AS2} = Access:recv(AS1, timer:seconds(60)),
            From ! {Ref, {sync_response, Bin}},
            client_diff_loop(S#client{access={Access, AccessRef, AS2}}, Queued)
    end.
