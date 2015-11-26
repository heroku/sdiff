sdiff
=====

** PROTOTYPE CODE, NOT PRODUCTION READY **

An OTP application to do merkle tree-based state replication from master to followers,
with a live stream of data for low latency updates.

The library contains both client code and server code.

The merkle tree implementation is in memory, so a dataset at least the size of
`O(n)` where `n = hash(Key) + hash(Value)` will be required, plus a partial copy
of the tree (common binaries should be shared) per client connected.

Basic Server Usage
-----

The server code is expected to be canonical. A user creates a server by calling

    sdiff_serv:start_link(Name, ReadFun)

where `ReadFun` is a function that accepts a key, and returns either `{delete, Key}`
or `{write, Key, Val}`, the two basic operations that can be streamed through `sdiff`.

The server sync process is built using `sdiff_serv:write(Name, Key, Val)` and
`sdiff_serv:delete(Name, Key)`. Once the state table is fully built, call
`sdiff_serv:ready(Name)`, which will signify to whatever standby server (such
as `sdiff_access_tcp_ranch_server`) that it can start subscribing clients to the
server.

The server supports concurrent clients being connected, both for streams and diffs.

Basic Client Usage
-----

The client code has the same ability to build a basic tree in memory before
connecting. The client is started by calling:

    sdiff_client:start_link(WriteFun, AccessMod, AccessArgs)

Where `WriteFun` takes either `{delete, Key}` or `{write, Key, Val}` and lets the
user update data in whatever persistent storage it requires. The operation is
assumed to always succeed, or error out (which kills the client and the tree, sadly)

Once the client state is ready, call `sdiff_client:ready(NameOrPid)`. It will then
connect to the server.

See `demo/demo.erl` for an example of a full client+server setup.


States
------

Now this is where it's fun.

### Server Initialization ###

```
        SERVER              RANCH WORKER
          |                      |
          |<-------await---------|
--ready-->|                      |
          |---------ok---------->|
          |<------connect--------|
       [spawn],                  |
          |   '--MIDDLEMAN       |
          |         |            |
          |         |---self()-->|
          |         |            |
```

The middleman process handles blocking on connections and the client-logic and
translation, whereas the server really handles fanning out the tree structure
and updates to streaming clients. The protocol handling may or may not be in a
different process (RANCH WORKER), but for the sake of composability, the current
code base demo makes it a standalone process.

### Client Initialization ###

```
        CLIENT
          |
--ready-->|
       [spawn],
          |   '--MIDDLEMAN
          |          |
```

As for the server, the middleman holds the connection and blocks. However,
because there's no server involved, each client expects a 1:1 connection
and avoids the need for a third process.

### Streaming Updates ###

Streaming update is a push-based mechanism from whatever on the server
is the auhtoritative system:

```
                     SERVER-SIDE                ||          CLIENT-SIDE
                                                ||
       SERVER    MIDDLEMAN    RANCH WORKER      ||         MIDDLEMAN    CLIENT
          |         |              |            ||             |           |
--write-->|         |              |            ||             |           |
          |--write->|              |            ||             |           |
          |         |------write--------------->||----write--->|           |
          |         |              |            ||             |---write-->|
          |         |              |            ||             |           |
```

As an optimization, the middleman server knows the socket of the worker and
can avoid passing message through it to reach the client directly


### Diffing ###

This is where all the complexity lies.
The protocol is in multiple phases, and is triggered by a client demand,
and requires synchronization with the server so that updates are received
in the right order.

The server middleman will maintain a queue of keys relayed in updates during
the diffing, and will remove them from the diff result (as the diff would
now be outdated regarding these keys).

Because the diffing action enabled by `merklet` is blocking and stateless,
a fourth server process (DIFFER) is introduced:

```
                         SERVER-SIDE                      ||             CLIENT-SIDE
                                                          ||
    SERVER    MIDDLEMAN                RANCH WORKER       ||         MIDDLEMAN    CLIENT
       |         |                          |             ||             |           |
1.     |         |                          |             ||             |           |<--diff--
2.     |         |                          |             ||             |<---Tree---|
3.     |         |                          |<--sync_req--||<--sync_req--|           |
       |         |<----------diff-----------|             ||             |           |
       |         |--------------sync_start--------------->||-sync_start->|           |
       |         |                          |             ||             |           |
       |      [spawn]........DIFFER         |             ||             |           |
       |         |             |            |             ||             |           |
4.     |<---------tree---------|            |             ||             |           |
       |----------Tree-------->|            |             ||             |           |
5.     |         |<-{sync_req}-|            |             ||             |           |
       |         |---------------{sync_req}-------------->||-{sync_req}->|           |
       |         |             |            |<-{sync_res}-||<-{sync_res}-|           |
       |         |--------recv------------->|             ||             |           |
       |         |<--------{sync_res}-------|             ||             |           |
       |         |-{sync_res}->|            |             ||             |           |
       |         |             |            |             ||             |           |
6.     |         |<-{done,Res}-|            |             ||             |           |
       |         |          [close]         |             ||             |           |
       |         |                          |             ||             |           |
       |         |----------------sync_seq--------------->||--sync_seq-->|           |
7.     |         |------------------write---------------->||----write--->|           |
       |         |                          |             ||             |---write-->|
       |         |----------------sync_done-------------->||--sync_done->|           |
       |         |                          |             ||             |           |
```

1. The client is asked to diff
2. The client process sends the tree to its middleman, making a copy of it
3. The synchronous phase begins, letting all in-flight messages prior to the diffing
   drain to the client. This isn't strictly necessary, but opens the door to some
   protocol-specific optimizations.
4. The differ grabs the tree from the SERVER
5. Diffing starts, with the differ on the server asking for data on the merkle
   tree of the client, and the client answering back. This goes on for a while.
   To make sure all writes are in order no matter the scheduling, the DIFFER proxies its
   requests and responses through the server MIDDLEMAN (and this is ugly), which
   forces proper serialization of messages sent to the socket.
6. The diffing is done, a list of result is returned to the MIDDLEMAN, which
   uses the `ReadFun` value to replay results after closing the diff protocol
7. The values in 6. being replayed.

During the entire operations, regular updates can still be streamed to the client
without interruption.

Another subtlety is that while the `diff` is a PUSH operation from RANCH WORKER
to MIDDLEMAN, all other reads from the socket are PULL-only with MIDDLEMAN asking
RANCH WORKER for data (`recv`), allowing implicit control-flow of the whole procedure.

Build
-----

    $ rebar3 compile

Tests
-----

    $ rebar3 do ct, proper, dialyzer

Demo
-----

    $ rebar3 as demo shell
    ...
    1> demo:run(8123).
    Tables populated...
    server state:
            <<"key1">>:<<"val1">>
            <<"key3">>:<<"val3">>
            <<"key2">>:<<"val2">>

    client state:
            <<"key">>:<<"val">>

    Stream sync test, adding key4:val4
    server state:
            <<"key1">>:<<"val1">>
            <<"key3">>:<<"val3">>
            <<"key2">>:<<"val2">>
            <<"key4">>:<<"val4">>

    client state:
            <<"key">>:<<"val">>
            <<"key4">>:<<"val4">>

    Triggering a diff to repair state...
    server state:
            <<"key1">>:<<"val1">>
            <<"key3">>:<<"val3">>
            <<"key2">>:<<"val2">>
            <<"key4">>:<<"val4">>

    client state:
            <<"key1">>:<<"val1">>
            <<"key3">>:<<"val3">>
            <<"key2">>:<<"val2">>
            <<"key4">>:<<"val4">>

Shows both a very quick stream (1 key) and a repair operation between one client
and one server using TCP and the reference TCP access protocol implementation.

Benchmarks
-----

    $ rebar3 as bench shell
    ...
    1> bench:all(PortNumber, Count).

Where `Count` is how many time each benchmark should be run. A value =< 10 is
recommended, as benchmarks themselves can run with ~10,000 internal repetitions each.

TODO
-----

- More Tests
- have deletes delete entries that exist in property-based tests
- tree snapshot functionality (for cheaper success/failure)
- Failure handling in sockets closing too often
- Define the access function behaviour for clients and servers (lets people use
  other stuff than unauthenticated TCP for things)
- use TCP_NODELAY only when diffing / evaluate impact
- conditional updates on the client-side (so that failures are automatically
  retried on the next repair)
- tree + dataset snapshot functionality (to re-sync trees too out of date?
  maybe better as a side-protocol)
- and so on
