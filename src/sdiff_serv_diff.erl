-module(sdiff_serv_diff).
-behaviour(gen_server).
-export([start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3, terminate/2]).

%%%%%%%%%%%%%%%%%%
%%% PUBLIC API %%%
%%%%%%%%%%%%%%%%%%
start_link(TreeServer, ReportTo) ->
    gen_server:start_link(?MODULE, {TreeServer, ReportTo}, []).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% GEN_SERVER CALLBACKS %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%
init({TreeServer, ReportTo}) ->
    try link(ReportTo) of
        true ->
            self() ! diff,
            {ok, {TreeServer, ReportTo}}
    catch error:noproc ->
        {stop, {missing_middleman, ReportTo}}
    end.

handle_call(_Call, _From, State) ->
    {noreply, State}.

handle_cast(_Cast, State) ->
    {noreply, State}.

handle_info(diff, {TreeServer, ReportTo}) ->
    %% We can't properly do transaction exchanges with the diff, so this process
    %% hides it all away in one spot. It could be a better idea to hide this
    %% behind a supervisor bridge instead.
    LocalisedRemote = merklet:access_unserialize(
        fun(Command, Path) ->
            sdiff_serv_middleman:sync_request(ReportTo, Command, Path)
        end),
    Tree = sdiff_serv:tree(TreeServer),
    Diff = merklet:dist_diff(Tree, LocalisedRemote),
    sdiff_serv_middleman:sync_done(ReportTo, Diff),
    {stop, normal, nostate}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_, _) ->
    ok.

