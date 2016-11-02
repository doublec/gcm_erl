-module(gcm_erl_test_support).

-export([
         get_sim_config/2,
         multi_store/2,
         req_val/2,
         pv/2,
         pv/3,
         start_gcm_sim/3
        ]).

-include("gcm_erl_test_support.hrl").

%%%====================================================================
%%% API
%%%====================================================================

%%--------------------------------------------------------------------
get_sim_config(gcm_sim_config=Name, _Config) ->
    SimName = ct:get_config(gcm_sim_node),
    SimCfg = ct:get_config(Name),
    {SimName, SimCfg}.

%%--------------------------------------------------------------------
multi_store(Props, PropsToStore) ->
    lists:ukeysort(1, lists:keymerge(1, lists:keysort(1, PropsToStore),
                                     lists:keysort(1, Props))).

%%--------------------------------------------------------------------
start_gcm_sim(Name, SimConfig, Cookie) ->
    %% Get important code paths
    CodePaths = [Path || Path <- code:get_path(),
                         string:rstr(Path, "_build/") > 0],
    ct:pal("Starting sim node named ~p", [Name]),
    {ok, Node} = start_slave(Name, ["-setcookie " ++ Cookie]),
    ct:pal("Sim node name: ~p", [Node]),
    ct:pal("Setting simulator configuration"),
    ct:pal("~p", [SimConfig]),
    _ = [ok = rpc:call(Node, application, set_env,
                       [gcm_sim, K, V], 1000) || {K, V} <- SimConfig],

    SimEnv = rpc:call(Node, application, get_all_env, [gcm_erl], 1000),
    ct:pal("gcm_sim's environment: ~p", [SimEnv]),
    ct:pal("Adding code paths to node ~p", [Node]),
    ct:pal("~p", [CodePaths]),
    ok = rpc:call(Node, code, add_pathsz, [CodePaths], 1000),

    ct:pal("Starting gcm_sim application on ~p", [Node]),
    {ok, L} = rpc:call(Node, application, ensure_all_started, [gcm_sim], 5000),

    ct:pal("Simulator on ~p: Started ~p", [Node, L]),
    ct:pal("Waiting for simulator ~p to accept connections", [Node]),
    TcpOptions = req_val(wm_config, SimConfig),
    ok = wait_for_sim(TcpOptions, 5000),
    {ok, L}.

%%--------------------------------------------------------------------
wait_for_sim(TcpOptions, Timeout) ->
    Ref = erlang:send_after(Timeout, self(), {sim_timeout, self()}),
    Addr = req_val(ip, TcpOptions),
    Port = req_val(port, TcpOptions),
    wait_sim_loop(Addr, Port),
    (catch erlang:cancel_timer(Ref)),
    ok.

%%--------------------------------------------------------------------
wait_sim_loop(Addr, Port) ->
    Self = self(),
    ct:pal("wait_sim_loop: connecting to {~p, ~p}", [Addr, Port]),
    case gen_tcp:connect(Addr, Port, [], 100) of
        {ok, Socket} ->
            ct:pal("wait_sim_loop: Success opening socket to {~p, ~p}",
                   [Addr, Port]),
            ok = gen_tcp:close(Socket);
        {error, Reason} ->
            ct:pal("wait_sim_loop: failed connecting to {~p, ~p}: ~p",
                   [Addr, Port, inet:format_error(Reason)]),
            receive
                {sim_timeout, Self} ->
                    ct:pal("wait_sim_loop: timed out connecting to "
                           "{~p, ~p}", [Addr, Port]),
                    throw(sim_ping_timeout)
            after
                1000 ->
                    wait_sim_loop(Addr, Port)
            end
    end.

%%--------------------------------------------------------------------
req_val(Key, Config) when is_list(Config) ->
    V = pv(Key, Config),
    ?assertMsg(V =/= undefined, "Required key missing: ~p", [Key]),
    V.

%%--------------------------------------------------------------------
pv(Key, PL) ->
    pv(Key, PL, undefined).

%%--------------------------------------------------------------------
pv(Key, PL, DefVal) ->
    case lists:keyfind(Key, 1, PL) of
        false -> DefVal;
        {_, V} -> V
    end.

%%====================================================================
%% Slave node support
%%====================================================================
%%--------------------------------------------------------------------
start_slave(Name, Args) ->
    {ok, Host} = inet:gethostname(),
    slave:start(Host, Name, Args).

%%--------------------------------------------------------------------
session_info(SessCfg, StartedSessions) ->
    Name = req_val(name, SessCfg),
    {Pid, Ref} = req_val(Name, StartedSessions),
    {Name, Pid, Ref}.

