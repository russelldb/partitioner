%% -------------------------------------------------------------------
%%
%% Copyright (c) 2016 Basho Technologies, Inc.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @private
-module(partition).

-export([main/1]).
-include_lib("eunit/include/eunit.hrl").
-define(P1, ['dev1@127.0.0.1', 'dev2@127.0.0.1']).
-define(P2, ['dev3@127.0.0.1', 'dev4@127.0.0.1']).

cli_options() ->
    %% Option Name, Short Code, Long Code, Argument Spec, Help Message
    [
     {help,               $h, "help",      undefined,  "Print this usage page. NOTE -p and -j are mutually exclusive"},
     {partition,          $p, "partition", undefined,  "partition the nodes"},
     {heal,               $j, "heal",      undefined,  "join the nodes (heal the partition)"}
    ].

print_help() ->
    getopt:usage(cli_options(),
                 escript:script_name()),
    halt(0).

run_help([]) -> true;
run_help(ParsedArgs) ->
    lists:member(help, ParsedArgs).

main(Args) ->
    case filelib:is_dir("./ebin") of
        true ->
            code:add_patha("./ebin");
        _ ->
            meh
    end,

    register(partitioner, self()),
    ParsedArgs = case getopt:parse(cli_options(), Args) of
               {ok, {Opts, _}} -> Opts;
               _ -> print_help()
           end,

    case run_help(ParsedArgs) of
        true -> print_help();
        _ -> ok
    end,

    Action = validate_args(ParsedArgs),

    ENode = 'partitioner@127.0.0.1',
    Cookie = riak,
    [] = os:cmd("epmd -daemon"),
    net_kernel:start([ENode]),
    erlang:set_cookie(node(), Cookie),

    io:format("node started~n"),

    doit(Action),

    ok.

validate_args([]) ->
    print_help();
validate_args([heal]) ->
    heal;
validate_args([partition]) ->
    partition;
validate_args(_) ->
    print_help().

doit(partition) ->
    partition();
doit(heal) ->
    heal().

partition() ->
    io:format("Partitioning ~n"),
    [true = rpc:call(N, erlang, set_cookie, [N, kair]) || N <- ?P1],
    [[true = rpc:call(N, erlang, disconnect_node, [P2N]) || N <- ?P1] || P2N <- ?P2],
    wait_until_partitioned(?P1, ?P2),
    io:format("partiioned ~p from ~p~n", [?P1, ?P2]).

%% Waits until the cluster actually detects that it is partitioned.
wait_until_partitioned(P1, P2) ->
    lager:info("Waiting until partition acknowledged: ~p ~p", [P1, P2]),
    [ begin
          lager:info("Waiting for ~p to be partitioned from ~p", [Node, P2]),
          wait_until(fun() -> is_partitioned(Node, P2) end)
      end || Node <- P1 ],
    [ begin
          lager:info("Waiting for ~p to be partitioned from ~p", [Node, P1]),
          wait_until(fun() -> is_partitioned(Node, P1) end)
      end || Node <- P2 ].

is_partitioned(Node, Peers) ->
    AvailableNodes = rpc:call(Node, riak_core_node_watcher, nodes, [riak_kv]),
    lists:all(fun(Peer) -> not lists:member(Peer, AvailableNodes) end, Peers).

heal() ->
    io:format("Healing ~n"),
    erlang:set_cookie(node(), kair),
    Cluster = ?P1 ++ ?P2,
    % set OldCookie on P1 Nodes
    [true = rpc:call(N, erlang, set_cookie, [N, riak]) || N <- ?P1],
    erlang:set_cookie(node(), riak),
    timer:sleep(5000),
    wait_until_connected(Cluster),
    {_GN, []} = rpc:sbcast(Cluster, riak_core_node_watcher, broadcast),
    io:format("healed ~p~n", [Cluster]),
    ok.

wait_until_connected(Nodes) ->
    lager:info("Wait until connected ~p", [Nodes]),
    NodeSet = sets:from_list(Nodes),
    F = fun(Node) ->
                Connected = rpc:call(Node, erlang, nodes, []),
                sets:is_subset(NodeSet, sets:from_list(([Node] ++ Connected) -- [node()]))
        end,
    [?assertEqual(ok, wait_until(Node, F)) || Node <- Nodes],
    ok.

%% @doc Utility function used to construct test predicates. Retries the
%%      function `Fun' until it returns `true', or until the maximum
%%      number of retries is reached. The retry limit is based on the
%%      provided `rt_max_wait_time' and `rt_retry_delay' parameters in
%%      specified `riak_test' config file.
wait_until(Fun) when is_function(Fun) ->
    MaxTime = 10000,
    Delay = 1000,
    Retry = MaxTime div Delay,
    wait_until(Fun, Retry, Delay).

%% @doc Convenience wrapper for wait_until for the myriad functions that
%% take a node as single argument.
wait_until(Node, Fun) when is_atom(Node), is_function(Fun) ->
    wait_until(fun() -> Fun(Node) end);

%% @doc Wrapper to verify `F' against multiple nodes. The function `F' is passed
%%      one of the `Nodes' as argument and must return a `boolean()' declaring
%%      whether the success condition has been met or not.
wait_until(Nodes, Fun) when is_list(Nodes), is_function(Fun) ->
    [?assertEqual(ok, wait_until(Node, Fun)) || Node <- Nodes],
    ok.

%% @doc Retry `Fun' until it returns `Retry' times, waiting `Delay'
%% milliseconds between retries. This is our eventual consistency bread
%% and butter
wait_until(Fun, Retry, Delay) when Retry > 0 ->
    Res = Fun(),
    case Res of
        true ->
            ok;
        _ when Retry == 1 ->
            {fail, Res};
        _ ->
            timer:sleep(Delay),
            wait_until(Fun, Retry-1, Delay)
    end.
