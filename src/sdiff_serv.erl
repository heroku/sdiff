-module(sdiff_serv).
-behaviour(gen_server).
%% user callbacks
-export([start_link/1, start_link/2,
         write/3, delete/2, ready/1]).
%% callbacks from the connection server third party
-export([await/1, connect/3]).
%% internal callbacks
-export([tree/1]).
%% debug/test callbacks
-export([client_count/1]).
%% export/import of tree
-export([export/3, import/3]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3, terminate/2]).

-record(state, {ready = false :: boolean(),
                awaiting = [] :: list(),
                canonical = undefined :: merklet:tree(),
                clients = #{},
                readfun :: fun((Key::_) -> {write, Key, Val::_} | {delete, Key})
               }).

%%%%%%%%%%%%%%
%%% PUBLIC %%%
%%%%%%%%%%%%%%
start_link(ReadFun) ->
    gen_server:start_link(?MODULE, [ReadFun], []).

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

%% Internal call to get state
tree(Name) ->
    gen_server:call(Name, tree).

%% Debug function to get an idea of how many clients are connected
client_count(Name) ->
    gen_server:call(Name, client_count).

%% Tree dump/restore
export(Name, File, Timeout) ->
    gen_server:call(Name, {export, File}, Timeout).

import(Name, File, Timeout) ->
    gen_server:call(Name, {import, File}, Timeout).


%%%%%%%%%%%%%%%%%%
%%% GEN_SERVER %%%
%%%%%%%%%%%%%%%%%%
init([ReadFun]) ->
    Tree = undefined,
    %% TODO: trap exits of clients
    process_flag(trap_exit, true),
    {ok, #state{canonical=Tree, readfun=ReadFun}}.

%% Awaiting management
handle_call(await, From, State=#state{ready=false, awaiting=List}) ->
    {noreply, State#state{awaiting=[From|List]}};
handle_call(await, _From, State) ->
    {reply, ok, State};
%% Key/Val management for updates
handle_call({write, Key, Val}, _From, State=#state{canonical=Tree, clients=Clients}) ->
    maps:fold(
        fun(Pid, _, _) -> sdiff_serv_middleman:write(Pid, Key, Val) end,
        ignore,
        Clients
    ),
    {reply, ok, State#state{canonical=merklet:insert({Key, term_to_binary(Val)}, Tree)}};
handle_call({delete, Key}, _From, State=#state{canonical=Tree, clients=Clients}) ->
    maps:fold(
        fun(Pid, _, _) -> sdiff_serv_middleman:delete(Pid, Key) end,
        ignore,
        Clients
    ),
    {reply, ok, State#state{canonical=merklet:delete(Key, Tree)}};
%% Client subscription
handle_call({connect, Access, AccessArgs}, _From,
            State=#state{clients=Clients, readfun=ReadFun}) ->
    {ok, Pid} = sdiff_serv_middleman:start_link(self(), ReadFun, Access, AccessArgs),
    {reply, Pid, State#state{clients=Clients#{Pid => true}}};
%% Diff management
handle_call(tree, _From, State=#state{canonical=Tree}) ->
    %% Actual diffing. For this one we must make a local copy for he current
    %% operation, then make one of the remote tree.
    {reply, Tree, State};
handle_call(client_count, _From, State=#state{clients=Clients}) ->
    {reply, maps:size(Clients), State};
handle_call({export, FileName}, _From, State=#state{canonical=Tree}) ->
    try
       {ok, File} = file:open(FileName, [write, raw]),
       Res = file:write(File, term_to_binary(Tree, [compressed])),
       {reply, Res, State}
    catch
        T:R ->
            {reply, {error, {T,R}}, State}
    end;
handle_call({import, FileName}, _From, State=#state{}) ->
    try
       {ok,Data} = file:read_file(FileName),
       Tree = binary_to_term(Data),
       {reply, ok, State#state{canonical=Tree}}
    catch
        T:R ->
            {reply, {error, {T,R}}, State}
    end;
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

handle_info({'EXIT', Pid, normal}, State=#state{clients=Clients}) ->
    %% Process ended normally, assume the answer was sent.
    {noreply, State=#state{clients=maps:remove(Pid, Clients)}};
handle_info({'EXIT', Pid, Error}, State=#state{clients=Clients}) ->
    %% Process ended abnormally. Assume answer wasn't sent.
    case Clients of
        #{Pid := _} ->
            {noreply, State#state{clients=maps:remove(Pid, Clients)}};
        #{} ->
            error_logger:error_report(unexpected_monitor, {?MODULE, Pid, Error}),
            {noreply, State}
    end;
handle_info(Info, State=#state{}) ->
    error_logger:warning_report(unexpected_msg, {?MODULE, info, Info}),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_, #state{clients=Clients}) ->
    maps:fold(fun(Pid, _, _Acc) -> exit(Pid, shutdown) end, 0, Clients).

%%%%%%%%%%%%%%%
%%% PRIVATE %%%
%%%%%%%%%%%%%%%

