-module(bench).
-export([all/2]).
-define(ELEMENT_REPS, 10000).

%%% Benchmarks:
%%% 1. time it takes for a server to locally write content
%%% 2. time it takes for a client to locally write content
%%% 3. time to connect/establish a session
%%% 4. capacity of streaming updates
%%% 5. time it takes to diff various levels of content

all(Port, Repeats) ->
    Runs = [
        {"server-local writes",
         fun() -> server_local_write_setup(Port) end,
         fun server_local_write/1,
         fun server_local_teardown/1,
         fun server_local_translate/1},
        {"client-local writes",
         fun() -> client_local_write_setup(Port) end,
         fun client_local_write/1,
         fun client_local_teardown/1,
         fun client_local_translate/1},
        {"establishing connection",
         fun() -> connect_setup(Port) end,
         fun connect/1,
         fun connect_teardown/1,
         fun connect_translate/1},
        {"streaming entries",
         fun() -> stream_setup(Port) end,
         fun stream/1,
         fun stream_teardown/1,
         fun stream_translate/1},
        {"diffing 1% missing entries",
         fun() -> diff_setup(Port, 0.01) end,
         fun diff/1,
         fun diff_teardown/1,
         fun(X) -> diff_translate(X, "1%") end},
        {"diffing 5% missing entries",
         fun() -> diff_setup(Port, 0.05) end,
         fun diff/1,
         fun diff_teardown/1,
         fun(X) -> diff_translate(X, "5%") end},
        {"diffing 10% missing entries",
         fun() -> diff_setup(Port, 0.10) end,
         fun diff/1,
         fun diff_teardown/1,
         fun(X) -> diff_translate(X, "10%") end},
        {"diffing 15% missing entries",
         fun() -> diff_setup(Port, 0.15) end,
         fun diff/1,
         fun diff_teardown/1,
         fun(X) -> diff_translate(X, "15%") end}
    ],
    run(Runs, Repeats).

run(Runs, Repeats) ->
    [begin
        io:format("Running benchmark for ~s~n", [Desc]),
        Translate(run(Setup, Bench, Teardown, Repeats))
     end || {Desc, Setup, Bench, Teardown, Translate} <- Runs].

run(Setup, Bench, Teardown, Repeats) -> run(Setup, Bench, Teardown, 0, Repeats, []).

run(_, _, _, R, R, Acc) -> Acc;
run(Setup, Bench, Teardown, N, R, Acc) ->
    SetupRes = Setup(),
    {Micros,_} = timer:tc(Bench, [SetupRes]),
    Teardown(SetupRes),
    run(Setup, Bench, Teardown, N+1, R, [Micros|Acc]).

%%% Benchmarks
%% Server-local writes
server_local_write_setup(_Port) ->
    {ok, Pid} = sdiff_serv:start_link(
            fun(K) -> {delete, K} end
    ),
    {Pid, ?ELEMENT_REPS}.

server_local_write({_Pid, 0}) -> ok;
server_local_write({Pid, N}) ->
    sdiff_serv:write(Pid, integer_to_binary(N), N),
    server_local_write({Pid, N-1}).

server_local_teardown({Pid, _}) ->
    unlink(Pid),
    exit(Pid, shutdown).

server_local_translate(Micros) ->
    TimePers = [Micro / ?ELEMENT_REPS || Micro <- Micros],
    {"server insertion averages (µs)", bear:get_statistics(TimePers)}.

%% Client-local writes
client_local_write_setup(_Port) ->
    {ok, Pid} = sdiff_client:start_link(
            fun(K) -> {delete, K} end,
            fakemod,
            fakeargs
    ),
    {Pid, ?ELEMENT_REPS}.

client_local_write({_Pid, 0}) -> ok;
client_local_write({Pid, N}) ->
    sdiff_client:write(Pid, integer_to_binary(N), N),
    client_local_write({Pid, N-1}).

client_local_teardown({Pid, _}) ->
    unlink(Pid),
    exit(Pid, shutdown).

client_local_translate(Micros) ->
    TimePers = [Micro / ?ELEMENT_REPS || Micro <- Micros],
    {"client insertion averages (µs)", bear:get_statistics(TimePers)}.

%% Connection establishment
connect_setup(Port) ->
    {ok, Server} = sdiff_serv:start_link(
        fun(K) -> {delete, K} end
    ),
    sdiff_serv:ready(Server),
    {ok,_} = ranch:start_listener(
        server, 5,
        ranch_tcp,
        [{port, Port},
         {nodelay,true},
         {max_connections, 1000}],
        sdiff_access_tcp_ranch_server,
        [Server]),
    {ok, Client} = sdiff_client:start_link(
        fun(K) -> {delete, K} end,
        sdiff_access_tcp_client,
        {{127,0,0,1}, Port, [], 10000}
    ),
    {Server, Client, server}.

connect({_, Client, _}) ->
    sdiff_client:ready(Client),
    wait_connected(Client).

connect_teardown({Server, Client, Ranch}) ->
    unlink(Server),
    unlink(Client),
    ranch:stop_listener(Ranch),
    exit(Server, shutdown),
    exit(Client, shutdown).

connect_translate(Micros) ->
    {"connection establishing (µs)", bear:get_statistics(Micros)}.

%% Streaming entries
stream_setup(Port) ->
    {ok, Server} = sdiff_serv:start_link(
        fun(K) -> {delete, K} end
    ),
    sdiff_serv:ready(Server),
    {ok,_} = ranch:start_listener(
        server, 5,
        ranch_tcp,
        [{port, Port},
         {nodelay,true},
         {max_connections, 1000}],
        sdiff_access_tcp_ranch_server,
        [Server]),
    Parent = self(),
    {ok, Client} = sdiff_client:start_link(
        fun({write, <<"last-write">>, _}) -> Parent ! done
        ;  (_Op) -> ok end,
        sdiff_access_tcp_client,
        {{127,0,0,1}, Port, [], 10000}
    ),
    sdiff_client:ready(Client),
    wait_connected(Client),
    {Server, Client, server, ?ELEMENT_REPS}.

stream({Server, _, _, 0}) ->
    sdiff_serv:write(Server, <<"last-write">>, "last-val"),
    receive
        done -> ok
    end;
stream({Server, Client, Ranch, Reps}) ->
    sdiff_serv:write(Server, integer_to_binary(Reps), "some-val"),
    stream({Server, Client, Ranch, Reps-1}).

stream_teardown({Server, Client, Ranch, _Reps}) ->
    unlink(Server),
    unlink(Client),
    ranch:stop_listener(Ranch),
    exit(Server, shutdown),
    exit(Client, shutdown).

stream_translate(Micros) ->
    MS = [Us / 1000 || Us <- Micros],
    {"time to stream " ++ integer_to_list(?ELEMENT_REPS) ++ " "
     "entries (ms) ", bear:get_statistics(MS)}.

%% Diffing entries
diff_setup(Port, Pct) ->
    {ok, Server} = sdiff_serv:start_link(
        fun(K) -> {write, K, "some-val"} end
    ),
    sdiff_serv:ready(Server),
    {ok,_} = ranch:start_listener(
        server, 5,
        ranch_tcp,
        [{port, Port},
         {nodelay,true},
         {max_connections, 1000}],
        sdiff_access_tcp_ranch_server,
        [Server]),
    {ok, Client} = sdiff_client:start_link(
        fun(_Op) -> ok end,
        sdiff_access_tcp_client,
        {{127,0,0,1}, Port, [], 10000}
    ),
    populate_entries(Server, Client, ?ELEMENT_REPS, Pct),
    sdiff_client:ready(Client),
    wait_connected(Client),
    {Server, Client, server}.

diff({_, Client, _}) ->
    sdiff_client:sync_diff(Client, infinity).

diff_teardown({Server, Client, Ranch}) ->
    unlink(Server),
    unlink(Client),
    ranch:stop_listener(Ranch),
    exit(Server, shutdown),
    exit(Client, shutdown),
    timer:sleep(5000).

diff_translate(Micros, Pct) ->
    MS = [Us / 1000 || Us <- Micros],
    {"time to diff "++Pct++" of " ++ integer_to_list(?ELEMENT_REPS) ++ " "
     "entries (ms) ", bear:get_statistics(MS)}.

%%% Helpers
wait_connected(Client) ->
    case sdiff_client:status(Client) of
        disconnected -> wait_connected(Client);
        _ -> ok
    end.

populate_entries(_, _, 0, _) -> ok;
populate_entries(Server, Client, Count, Pct) ->
    sdiff_serv:write(Server, integer_to_binary(Count), "some-val"),
    case rand:uniform() > Pct of
        true -> sdiff_client:write(Client, integer_to_binary(Count), "some-val");
        false -> skip
    end,
    populate_entries(Server, Client, Count-1, Pct).
