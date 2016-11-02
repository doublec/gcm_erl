%%%----------------------------------------------------------------
%%% Purpose: Test suite for the 'gcm_erl' module.
%%%-----------------------------------------------------------------

-module(gcm_erl_SUITE).

-include_lib("common_test/include/ct.hrl").
-include("gcm_erl_test_support.hrl").

-import(gcm_erl_test_support,
        [
         get_sim_config/2,
         multi_store/2,
         req_val/2,
         pv/2,
         pv/3,
         start_gcm_sim/3
        ]).

-compile(export_all).

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
all() ->
    [
        {group, session}
    ].

%%--------------------------------------------------------------------
groups() ->
    [
        {
            session,
            [],
            [{group, clients}]
        },
        {
            clients,
            [],
            [
                send_msg_test,
                send_msg_via_api_test,
                async_send_msg_test,
                async_send_msg_via_api_test
            ]
        }
    ].

%%--------------------------------------------------------------------
suite() -> [
        {timetrap, {seconds, 30}},
        {require, gcm_sim_node},
        {require, gcm_sim_config},
        {require, gcm_erl},
        {require, registration_id}
    ].

%%--------------------------------------------------------------------
init_per_suite(Config) ->
    DataDir = req_val(data_dir, Config), % Standard CT variable
    MnesiaDir = filename:join(DataDir, "db"),
    ok = filelib:ensure_dir(MnesiaDir),
    application:set_env(mnesia, dir, MnesiaDir),

    Cookie = "scpf",
    {GcmSimNode, GcmSimCfg} = get_sim_config(gcm_sim_config, Config),
    ct:log("GCM simulator node: ~p", [GcmSimNode]),
    ct:log("GCM simulator config: ~p", [GcmSimCfg]),

    %% Start GCM simulator
    ct:log("Starting GCM simulator"),
    {ok, GcmSimStartedApps} = start_gcm_sim(GcmSimNode, GcmSimCfg, Cookie),
    ct:log("Stared GCM simulator apps ~p", [GcmSimStartedApps]),

    GCMConfig = ct:get_config(gcm_erl),
    Service = req_val(service, GCMConfig),
    ct:pal("Service: ~p", [Service]),
    Sessions = req_val(sessions, GCMConfig),
    ct:pal("Sessions: ~p", [Sessions]),
    RegId = ct:get_config(registration_id),
    ct:pal("registration_id: ~p", [registration_id]),
    Started = start_per_suite_apps(Config),
    ct:pal("init_per_suite: Started apps=~p", [Started]),
    multi_store(Config, [{gcm_sim_started_apps, GcmSimStartedApps},
                         {suite_started_apps, Started},
                         {gcm_sim_node, GcmSimNode},
                         {gcm_sim_config, GcmSimCfg},
                         {gcm_service, Service},
                         {gcm_sessions, Sessions},
                         {registration_id, RegId}]
               ).

%%--------------------------------------------------------------------
end_per_suite(Config) ->
    % We don't care about sim_started_apps because they are on
    % a slave node that will get shut down.
    Apps = req_val(suite_started_apps, Config),
    [application:stop(App) || App <- Apps],
    ok.

%%--------------------------------------------------------------------
init_per_group(_GroupName, Config) ->
    Config.

%%--------------------------------------------------------------------
end_per_group(_GroupName, _Config) ->
    ok.

%%--------------------------------------------------------------------
init_per_testcase(_Case, Config) ->
    init_per_testcase_common(Config).

%%--------------------------------------------------------------------
end_per_testcase(_Case, Config) ->
    end_per_testcase_common(Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
send_msg_test(doc) ->
    ["gcm_erl_session:send/2 should send a message to GCM"];
send_msg_test(suite) ->
    [];
send_msg_test(Config) ->
    RegId = req_val(registration_id, Config),
    SimHdrs = [{"X-GCMSimulator-StatusCode", "200"},
               {"X-GCMSimulator-Results", "message_id:1000"}],
    [
        begin
                Name = req_val(name, Session),
                GcmOpts = make_opts(RegId, "Hello, world!"),
                Opts = [{http_headers, SimHdrs}],
                ct:pal("Call gcm_erl_session:send(~p, ~p, ~p)",
                       [Name, GcmOpts, Opts]),
                {ok, {UUID, Props}} = gcm_erl_session:send(Name, GcmOpts, Opts),
                ct:pal("Sent notification, uuid = ~s, props = ~p",
                       [UUID, Props])
        end || Session <- req_val(gcm_sessions, Config)
    ],
    ok.

%%--------------------------------------------------------------------
send_msg_via_api_test(doc) ->
    ["gcm_erl:send/2 should send a message to GCM"];
send_msg_via_api_test(suite) ->
    [];
send_msg_via_api_test(Config) ->
    RegId = req_val(registration_id, Config),
    SimHdrs = [{"X-GCMSimulator-StatusCode", "200"},
               {"X-GCMSimulator-Results", "message_id:1000"}],
    [
        begin
                Name = req_val(name, Session),
                GcmOpts = make_opts(RegId, "Hello, world!"),
                Opts = [{http_headers, SimHdrs}],
                ct:pal("Call gcm_erl:send(~p, ~p, ~p)",
                       [Name, GcmOpts, Opts]),
                {ok, {UUID, Props}} = gcm_erl:send(Name, GcmOpts, Opts),
                ct:pal("Sent notification via API, uuid = ~p, props = ~p",
                       [UUID, Props])
        end || Session <- req_val(gcm_sessions, Config)
    ],
    ok.

%%--------------------------------------------------------------------
async_send_msg_test(doc) ->
    ["gcm_erl_session:async_send/3 should send a message to GCM ",
     "asynchronously, and deliver async results to self"];
async_send_msg_test(suite) ->
    [];
async_send_msg_test(Config) ->
    RegId = req_val(registration_id, Config),
    SimHdrs = [{"X-GCMSimulator-StatusCode", "200"},
               {"X-GCMSimulator-Results", "message_id:1000"}],
    [
        begin
            Name = req_val(name, Session),
            GcmOpts = make_opts(RegId, "Hello, world!"),
            Opts = [{http_headers, SimHdrs}],
            {ok, {submitted, UUID}} = gcm_erl_session:async_send(Name, GcmOpts,
                                                                 Opts),
            ct:pal("Submitted async notification, uuid = ~p~n", [UUID]),
            async_receive_loop(UUID)
        end || Session <- req_val(gcm_sessions, Config)
    ],
    ok.

%%--------------------------------------------------------------------
async_send_msg_via_api_test(doc) ->
    ["gcm_erl:async_send/3 should send a message to GCM ",
     "asynchronously, and deliver async results to self"];
async_send_msg_via_api_test(suite) ->
    [];
async_send_msg_via_api_test(Config) ->
    RegId = req_val(registration_id, Config),
    SimHdrs = [{"X-GCMSimulator-StatusCode", "200"},
               {"X-GCMSimulator-Results", "message_id:1000"}],
    [
        begin
            Name = req_val(name, Session),
            GcmOpts = make_opts(RegId, "Hello, world!"),
            Opts = [{http_headers, SimHdrs}],
            {ok, {submitted, UUID}} = gcm_erl:async_send(Name, GcmOpts, Opts),
            ct:pal("Submitted async notification, uuid = ~p~n", [UUID]),
            async_receive_loop(UUID)
        end || Session <- req_val(gcm_sessions, Config)
    ],
    ok.

%%--------------------------------------------------------------------
async_receive_loop(UUID) ->
    receive
        {gcm_response, v1, {UUID, Resp}} ->
            ct:pal("Received response for uuid ~p: ~p", [UUID, Resp]),
            assert_success(Resp)
    after
        1000 ->
            ct:fail({error, sim_timeout})
    end.

%%--------------------------------------------------------------------
assert_success(Resp) ->
    {ok, {success, {UUID, Props}}} = Resp,
    UUID = req_val(id, Props),
    Status = req_val(status, Props),
    Status = <<"200">>.

%%====================================================================
%% Internal helper functions
%%====================================================================
init_per_testcase_common(Config) ->
    (catch end_per_testcase_common(Config)),
    ok = mnesia:create_schema([node()]),
    ok = mnesia:start(),
    Service = req_val(gcm_service, Config),
    Sessions = req_val(gcm_sessions, Config),
    ct:pal("Service: ~p", [Service]),
    ct:pal("Sessions: ~p", [Sessions]),
    ok = application:set_env(gcm_erl, service, Service),
    ok = application:set_env(gcm_erl, sessions, Sessions),
    {ok, AppList} = application:ensure_all_started(gcm_erl),
    ct:pal("Started apps: ~p", [AppList]),
    multi_store(Config, [{started_apps, AppList}]).

%%--------------------------------------------------------------------
end_per_testcase_common(Config) ->
    Apps = lists:reverse(pv(started_apps, Config, [])),
    _ = [ok = application:stop(App) || App <- Apps],
    mnesia:stop(),
    ok = mnesia:delete_schema([node()]),
    lists:keydelete(started_apps, 1, Config).

%%--------------------------------------------------------------------
start_per_suite_apps(Config) ->
    Apps = [lager, ssl],
    set_env(lager, lager_config(Config)),
    Fun = fun(App, Acc) ->
                  {ok, L} = application:ensure_all_started(App),
                  Acc ++ L
          end,
    StartedApps = lists:foldl(Fun, [], Apps),
    lists:usort(StartedApps).

%%--------------------------------------------------------------------
make_opts(RegId, Msg) ->
    [
        {registration_ids, [sc_util:to_bin(RegId)]}, % Required, all others optional
        {data, [{alert, sc_util:to_bin(Msg)}]}
    ].

%%--------------------------------------------------------------------
set_env(App, FromEnv) ->
    [ok = application:set_env(App, K, V) || {K, V} <- FromEnv].

%%====================================================================
%% Lager support
%%====================================================================
%%--------------------------------------------------------------------
lager_config(Config) ->
    PrivDir = req_val(priv_dir, Config), % Standard CT variable
    [
     {handlers,
      [
       {lager_console_backend, debug},
       {lager_file_backend, [{file, filename:join(PrivDir, "log/error.log")},
                             {level, error},
                             {size, 10485760},
                             {date, "$D0"},
                             {count, 5}]},
       {lager_file_backend, [{file, filename:join(PrivDir, "log/console.log")},
                             {level, debug },
                             {size, 10485760},
                             {date, "$D0"},
                             {count, 5}
                            ]
       }
      ]
     },
     %% Whether to write a crash log, and where. Undefined means no crash logger.
     {crash_log, filename:join(PrivDir, "log/crash.log")},
     %% Maximum size in bytes of events in the crash log - defaults to 65536
     {crash_log_msg_size, 65536},
     %% Maximum size of the crash log in bytes, before its rotated, set
     %% to 0 to disable rotation - default is 0
     {crash_log_size, 10485760},
     %% What time to rotate the crash log - default is no time
     %% rotation. See the README for a description of this format.
     {crash_log_date, "$D0"},
     %% Number of rotated crash logs to keep, 0 means keep only the
     %% current one - default is 0
     {crash_log_count, 5},
     %% Whether to redirect error_logger messages into lager - defaults to true
     {error_logger_redirect, true}
    ].

