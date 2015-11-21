-module(sdiff_client).
-behaviour(gen_server).
-export([write/3, delete/2,
         ready/1, diff/1, status/1]).
-export([start_link/3, start_link/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3, terminate/2]).

-record(state, {canonical = undefined :: merklet:tree(),
                init_access :: {module(), term()},
                middleman :: undefined | pid(),
                storefun :: fun(({write, _, _} | {delete, _}) -> _)
               }).
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
    process_flag(trap_exit, true),
    {ok, #state{canonical=undefined, storefun=StoreCallback,
                init_access={Access, AccessArgs}}}.

%% Diff management
handle_call(diff, _From, State=#state{middleman=undefined}) ->
    {reply, disconnected, State};
handle_call(diff, _From, State=#state{middleman=Pid, canonical=Tree}) ->
    case sdiff_client_middleman:state(Pid) of
        disconnected ->
            {reply, disconnected, State};
        diff ->
            {reply, already_diffing, State};
        diff_wait ->
            {reply, already_diffing, State};
        relay ->
            %% Actual diffing. For this one we must make a local copy for the current
            %% operation, to make sure we don't have weird mutating trees during a diffing.
            %% We then initiate the access handler as a client.
            %%
            %% Any problem having this local?
            %% Should probably be async, unless it's okay for the client to block
            %% while receiving. It would save memory!
            Pid ! {diff, self(), Tree},
            {reply, async_diff, State}
    end;
handle_call({write, _Key, _Val}=Msg, _From, State) ->
    NewState = update_tree(Msg, State),
    {reply, ok, NewState};
handle_call({delete, _Key}=Msg, _From, State) ->
    NewState = update_tree(Msg, State),
    {reply, ok, NewState};
handle_call(status, _From, State) ->
    Status = case State of
        #state{middleman=undefined} -> disconnected;
        #state{middleman=Pid} -> sdiff_client_middleman:state(Pid)
    end,
    {reply, Status, State};
handle_call(Call, _From, State=#state{}) ->
    lager:warning("unexpected call: ~p", [Call]),
    {noreply, State}.

handle_cast(ready, State=#state{init_access={Access, AccessArgs}, middleman=undefined}) ->
    {ok, Pid} = reconnect(Access, AccessArgs),
    {noreply, State#state{middleman=Pid}};
handle_cast(Cast, State=#state{}) ->
    lager:warning("unexpected cast: ~p", [Cast]),
    {noreply, State}.

handle_info({'EXIT', Pid, normal}, State=#state{middleman=Pid}) ->
    %% Process ended normally.
    {noreply, State=#state{middleman=undefined}};
handle_info({'EXIT', Pid, Error}, State=#state{middleman=Pid}) ->
    %% Process ended abnormally.
    lager:error("connection dropped ~p", [Error]),
    timer:sleep(1000),
    self() ! reconnect,
    {noreply, State#state{middleman=undefined}};
handle_info(reconnect, State=#state{init_access={Access, AccessArgs}, middleman=undefined}) ->
    {ok, Pid} = reconnect(Access, AccessArgs),
    {noreply, State#state{middleman=Pid}};
handle_info({write, _Key, _Val}=Msg, State) ->
    NewState = update(Msg, State),
    {noreply, NewState};
handle_info({delete, _Key}=Msg, State) ->
    NewState = update(Msg, State),
    {noreply, NewState};
handle_info({diff_done,Pid}, State=#state{middleman=Pid}) ->
    {noreply, State};
handle_info(Info, State=#state{}) ->
    lager:warning("unexpected info: ~p", [Info]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_, _State) ->
    ok.

%%%%%%%%%%%%%%%
%%% PRIVATE %%%
%%%%%%%%%%%%%%%

reconnect(Access, AccessArgs) ->
    Self = self(),
    sdiff_client_middleman:start_link(Self, Access, AccessArgs).

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

