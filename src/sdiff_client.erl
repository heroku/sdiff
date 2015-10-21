-module(sdiff_client).
-behaviour(gen_server).
-export([write/3, delete/2,
         ready/1, diff/1, status/1]).
-export([start_link/3, start_link/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3, terminate/2]).

-record(state, {canonical = undefined :: merklet:tree(),
                init_access :: {module(), term()},
                diff = {undefined,undefined,undefined} :: {pid() | undefined, reference() | undefined, diff | undefined},
                storefun :: fun(({write, _, _} | {delete, _}) -> _)
               }).

-record(server, {parent :: pid(),
                 tree :: undefined,
                 access :: {module(), term()}}).
%%%%%%%%%%%%%%
%%% PUBLIC %%%
%%%%%%%%%%%%%%
start_link(StoreCallback, Access, AccessArgs) ->
    gen_server:start_link(?MODULE, [StoreCallback, Access, AccessArgs], []).

start_link(Name, StoreCallback, Access, AccessArgs) ->
    gen_server:start_link(Name, ?MODULE, [StoreCallback, Access, AccessArgs], []).

%% Tree-rebuilding function to be used when reinitializing the client,
%% until a dump of the tree can be provided
write(Name, Key, Val) ->
    gen_server:call(Name, {write, Key, Val}).

delete(Name, Key) ->
    gen_server:call(Name, {delete, Key}).

ready(Name) ->
    gen_server:cast(Name, ready).

%% Debug function to introspect running state. Intended for tests and
%% operators.
status(Name) ->
    gen_server:call(Name, status).

%% Trigger a diff
diff(Name) ->
    gen_server:call(Name, diff).

%%%%%%%%%%%%%%%%%%
%%% GEN_SERVER %%%
%%%%%%%%%%%%%%%%%%
init([StoreCallback, Access, AccessArgs]) ->
    {ok, #state{canonical=undefined, storefun=StoreCallback,
                init_access={Access, AccessArgs}}}.

%% Diff management
handle_call(diff, _From, State=#state{diff={undefined, undefined, undefined}}) ->
    {reply, disconnected, State};
handle_call(diff, _From, State=#state{diff={_, _, diff}}) ->
    {reply, already_diffing, State};
handle_call(diff, _From, State=#state{diff={Pid, Ref, undefined}, canonical=Tree}) ->
    %% Actual diffing. For this one we must make a local copy for the current
    %% operation, to make sure we don't have weird mutating trees during a diffing.
    %% We then initiate the access handler as a client.
    %%
    %% Any problem having this local?
    %% SHould probably be async, unless it's okay for the client to block
    %% while receiving. It would save memory!
    Pid ! {diff, self(), Tree},
    {reply, async_diff, State#state{diff={Pid, Ref, diff}}};
handle_call({write, _Key, _Val}=Msg, _From, State) ->
    NewState = update_tree(Msg, State),
    {reply, ok, NewState};
handle_call({delete, _Key}=Msg, _From, State) ->
    NewState = update_tree(Msg, State),
    {reply, ok, NewState};
handle_call(status, _From, State) ->
    Status = case State of
        #state{diff={undefined, undefined, undefined}} -> disconnected;
        #state{diff={_,_,diff}} -> diff;
        #state{diff={Pid, _, undefined}} ->
            case process_info(Pid, dictionary) of
                undefined -> disconnected;
                {dictionary, Dict} -> lists:member({connected,true}, Dict)
            end
    end,
    {reply, Status, State};
handle_call(Call, _From, State=#state{}) ->
    error_logger:warning_report(unexpected_msg, {?MODULE, call, Call}),
    {noreply, State}.

handle_cast(ready, State=#state{init_access={Access, AccessArgs}, diff={undefined, undefined, undefined}}) ->
    {Pid, Ref} = reconnect(Access, AccessArgs),
    {noreply, State#state{diff={Pid, Ref, undefined}}};
handle_cast(Cast, State=#state{}) ->
    error_logger:warning_report(unexpected_msg, {?MODULE, cast, Cast}),
    {noreply, State}.

handle_info({'DOWN', Ref, process, Pid, normal}, State=#state{diff={Pid,Ref,_}}) ->
    %% Process ended normally.
    {noreply, State=#state{diff={undefined, undefined, undefined}}};
handle_info({'DOWN', Ref, process, Pid, Error}, State=#state{diff={Pid,Ref,_}}) ->
    %% Process ended abnormally.
    error_logger:error_report(connection_dropped, Error),
    timer:sleep(1000),
    self() ! reconnect,
    {noreply, State#state{diff={undefined, undefined, undefined}}};
handle_info(reconnect, State=#state{init_access={Access, AccessArgs}, diff={undefined, undefined, undefined}}) ->
    {Pid, Ref} = reconnect(Access, AccessArgs),
    {noreply, State#state{diff={Pid, Ref, undefined}}};
handle_info({write, _Key, _Val}=Msg, State) ->
    NewState = update(Msg, State),
    {noreply, NewState};
handle_info({delete, _Key}=Msg, State) ->
    NewState = update(Msg, State),
    {noreply, NewState};
handle_info({diff_done,Pid}, State=#state{diff={Pid, Ref, diff}}) ->
    {noreply, State#state{diff={Pid, Ref, undefined}}};
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

reconnect(Access, AccessArgs) ->
    Self = self(),
    spawn_monitor(fun() -> server(Self, Access, AccessArgs) end).

update_tree({write, Key, Val}, S=#state{canonical=Tree}) ->
    NewTree = merklet:insert({Key, term_to_binary(Val)}, Tree),
    S#state{canonical=NewTree};
update_tree({delete, Key}, S=#state{canonical=Tree}) ->
    NewTree = merklet:delete(Key, Tree),
    S#state{canonical=NewTree}.

update({write, Key, Val}, S=#state{canonical=Tree, storefun=StoreFun}) ->
    NewTree = merklet:insert({Key, term_to_binary(Val)}, Tree),
    StoreFun({write, Key, Val}),
    S#state{canonical=NewTree};
update({delete, Key}, S=#state{canonical=Tree, storefun=StoreFun}) ->
    NewTree = merklet:delete(Key, Tree),
    StoreFun({delete, Key}),
    S#state{canonical=NewTree}.

server(Self, Access, AccessArgs) ->
    AccessState = Access:init(self(), AccessArgs),
    put(connected, true),
    server_loop(#server{parent=Self, access={Access, AccessState}}).

server_loop(S=#server{parent=Pid, access={Access, AccessState}}) ->
    {ok, Msg, AS1} = receive_or_recv(Pid, Access, AccessState),
    case Msg of
        {write, Key, Val} ->
            Pid ! {write, Key, Val},
            server_loop(S#server{access={Access, AS1}});
        {delete, Key} ->
            Pid ! {delete, Key},
            server_loop(S#server{access={Access, AS1}});
        {diff, Pid, Tree} ->
            %% we loop on ourselves until sync_start is ready,
            %% indicating the server is in place for the diff
            %% protocol to take over
            {ok, AS2} = Access:send(sync_req, AS1),
            server_loop(S#server{access={Access, AS2}, tree=Tree});
        sync_start ->
            %% clear the tree from the state, make it explicit
            %% so we don't track it in memory more than is needed.
            server_diff(S#server{access={Access, AS1}, tree=undefined}, S#server.tree)
    end.

server_diff(State, Tree) ->
    SerializedTree = merklet:access_serialize(Tree),
    server_diff_loop(State, SerializedTree).

server_diff_loop(S=#server{parent=Pid, access={Access, AccessState}}, STree) ->
    {ok, Msg, AS1} = receive_or_recv(Pid, Access, AccessState),
    case Msg of
        {sync_request, Cmd, Path} ->
            Bin = STree(Cmd, Path),
            {ok, AS2} = Access:send({sync_response, Bin}, AS1),
            server_diff_loop(S#server{access={Access, AS2}}, STree);
        sync_done ->
            Pid ! {diff_done, self()},
            server_loop(S#server{access={Access, AS1}})
    end.

receive_or_recv(Parent, Access, AccessState) ->
    receive
        {diff, Parent, Tree} -> {ok, {diff, Parent, Tree}, AccessState}
    after 0 ->
        case Access:recv(AccessState, 500) of
            {error, timeout} -> receive_or_recv(Parent, Access, AccessState);
            Val -> Val
        end
    end.
