%%%----------------------------------------------------------------
%%% Purpose: Test suite for the 'gcm_erl' module.
%%%-----------------------------------------------------------------

-module(gcm_erl_SUITE).

-include_lib("common_test/include/ct.hrl").
-include("gcm_erl_test_support.hrl").

-import(gcm_erl_test_support,
        [
         get_sim_config/2,
         is_uuid_str/1,
         make_uuid/0,
         multi_store/2,
         req_val/2,
         pv/2,
         pv/3,
         start_gcm_sim/3,
         stop_gcm_sim/1
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
                get_state_test,
                send_msg_test,
                send_msg_uuid_test,
                send_msg_regids_test,
                send_msg_via_api_test,
                async_send_msg_test,
                async_send_msg_cb_test,
                async_send_msg_via_api_test,
                auth_error_test,
                bad_json_test,
                missing_reg_test,
                invalid_reg_test,
                mismatched_sender_test,
                not_registered_test,
                message_too_big_test,
                invalid_data_key_test,
                invalid_ttl_test,
                unavailable_test,
                internal_server_error_test,
                invalid_package_name_test,
                device_msg_rate_exceeded_test,
                topics_msg_rate_exceeded_test,
                unknown_error_for_reg_id_test,
                canonical_id_test,
                server_500_test,
                server_500_with_retry_after_test,
                unhandled_status_code_test,
                http_error_test
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

    {ok, {GcmSimNode, GcmSimStartedApps, GcmSimCfg}} = start_simulator(Config),

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
get_state_test(doc) -> ["Test gcm_erl_session:get_state/1"];
get_state_test(Config) ->
    [
        begin
                Name = req_val(name, Session),
                ct:pal("Call gcm_erl_session:get_state(~p)", [Name]),
                State = gcm_erl_session:get_state(Name),
                ct:pal("Got state: ~p", [State]),
                true = is_tuple(State)
        end || Session <- req_val(gcm_sessions, Config)
    ],
    ok.

%%--------------------------------------------------------------------
send_msg_test(doc) ->
    ["gcm_erl_session:send/3 should send a message to GCM"];
send_msg_test(Config) ->
    RegId = sc_util:to_bin(req_val(registration_id, Config)),
    Nf = make_nf(RegId, "send_msg_test"),
    do_send_msg_test(Nf, Config),
    ok.

%%--------------------------------------------------------------------
send_msg_uuid_test(doc) ->
    ["gcm_erl_session:send/3 should send a message to GCM"];
send_msg_uuid_test(Config) ->
    RegId = sc_util:to_bin(req_val(registration_id, Config)),
    Nf = [{uuid, make_uuid()} | make_nf(RegId, "send_msg_uuid_test")],
    do_send_msg_test(Nf, Config),
    ok.

%%--------------------------------------------------------------------
send_msg_regids_test(doc) ->
    ["gcm_erl_session:send/3 should send a message to GCM",
     "using 'registration_ids' list"];
send_msg_regids_test(Config) ->
    RegId = sc_util:to_bin(req_val(registration_id, Config)),
    Nf = make_nf([RegId], "send_msg_regids_test"),
    do_send_msg_test(Nf, Config),
    ok.

%%--------------------------------------------------------------------
send_msg_via_api_test(doc) ->
    ["gcm_erl:send/3 should send a message to GCM"];
send_msg_via_api_test(Config) ->
    RegId = sc_util:to_bin(req_val(registration_id, Config)),
    Nf = make_nf(RegId, "send_msg_via_api_test"),
    Opts = make_opts(Nf),
    [
        begin
                Name = req_val(name, Session),
                ct:pal("Call gcm_erl:send(~p, ~p, ~p)", [Name, Nf, Opts]),
                Result = gcm_erl:send(Name, Nf, Opts),
                ct:pal("Got result: ~p", [Result]),
                {ok, {success, {UUID, Props}}} = Result,
                ct:pal("Success, uuid = ~p, props = ~p", [UUID, Props]),
                true = is_uuid_str(UUID)
        end || Session <- req_val(gcm_sessions, Config)
    ],
    ok.

%%--------------------------------------------------------------------
async_send_msg_test(doc) ->
    ["gcm_erl_session:async_send/3 should send a message to GCM ",
     "asynchronously, and deliver async results to self"];
async_send_msg_test(Config) ->
    RegId = sc_util:to_bin(req_val(registration_id, Config)),
    Nf = make_nf(RegId, "async_send_msg_test"),
    Opts = make_opts(Nf),
    [
        begin
            Name = req_val(name, Session),
            ct:pal("Call gcm_erl_session:async_send(~p, ~p, ~p)",
                   [Name, Nf, Opts]),
            Result = gcm_erl_session:async_send(Name, Nf, Opts),
            ct:pal("Got result: ~p", [Result]),
            {ok, {submitted, UUID}} = Result,
            ct:pal("Submitted async notification, uuid = ~p~n", [UUID]),
            true = is_uuid_str(UUID),
            async_receive_loop(UUID)
        end || Session <- req_val(gcm_sessions, Config)
    ],
    ok.

%%--------------------------------------------------------------------
async_send_msg_cb_test(doc) ->
    ["gcm_erl_session:async_send_cb/5 should send a message to GCM ",
     "asynchronously, and deliver async results to self"];
async_send_msg_cb_test(Config) ->
    RegId = sc_util:to_bin(req_val(registration_id, Config)),
    Nf = make_nf(RegId, "async_send_msg_cb_test"),
    Opts = make_opts(Nf),
    Pid = self(),
    Cb = fun(NfPL, Req, Resp) ->
                 ct:pal("Callback: nf=~p, req=~p, resp=~p",
                        [NfPL, Req, Resp]),
                 UUID = req_val(uuid, Req),
                 Pid ! {gcm_response, v1, {UUID, Resp}}
         end,
    [
        begin
            Name = req_val(name, Session),
            ct:pal("Call gcm_erl_session:async_send_cb(~p, ~p, ~p, ~p, _)",
                   [Name, Nf, Opts, Pid]),
            Result = gcm_erl_session:async_send_cb(Name, Nf, Opts, Pid, Cb),
            ct:pal("Got result: ~p", [Result]),
            {ok, {submitted, UUID}} = Result,
            ct:pal("Submitted async cb notification, uuid = ~p~n", [UUID]),
            true = is_uuid_str(UUID),
            async_receive_loop(UUID)
        end || Session <- req_val(gcm_sessions, Config)
    ],
    ok.

%%--------------------------------------------------------------------
async_send_msg_via_api_test(doc) ->
    ["gcm_erl:async_send/3 should send a message to GCM ",
     "asynchronously, and deliver async results to self"];
async_send_msg_via_api_test(Config) ->
    RegId = sc_util:to_bin(req_val(registration_id, Config)),
    Nf = make_nf(RegId, "async_send_msg_via_api_test"),
    Opts = make_opts(Nf),
    [
        begin
            Name = req_val(name, Session),
            ct:pal("Call gcm_erl:async_send(~p, ~p, ~p)", [Name, Nf, Opts]),
            Result = gcm_erl:async_send(Name, Nf, Opts),
            ct:pal("Got result: ~p", [Result]),
            {ok, {submitted, UUID}} = Result,
            ct:pal("Submitted async notification, uuid = ~p~n", [UUID]),
            true = is_uuid_str(UUID),
            async_receive_loop(UUID)
        end || Session <- req_val(gcm_sessions, Config)
    ],
    ok.

%%--------------------------------------------------------------------
old_unavailable_test(doc) ->
    ["Test behavior when GCM returns a timeout (i.e. Unavailable status)"];
old_unavailable_test(Config) ->
    RegId = sc_util:to_bin(req_val(registration_id, Config)),
    ReqUUID = make_uuid(),
    Nf = [{uuid, ReqUUID} | make_nf(RegId, "old_unavailable_test")],
    SimHdrs = [{"X-GCMSimulator-StatusCode", "200"},
               {"X-GCMSimulator-Results", "error:Unavailable"}],
    Opts = [{http_headers, SimHdrs}],
    [
        begin
            Name = req_val(name, Session),
            ct:pal("Call gcm_erl_session:send(~p, ~p, ~p)",
                   [Name, Nf, Opts]),
            Result = gcm_erl_session:send(Name, Nf, Opts),
            ct:pal("Got result: ~p", [Result]),
            {error, {UUID, {failed, PErrors, rescheduled, RegIds}}} = Result,
            ct:pal("Failed: ~p; Rescheduled: ~p", [PErrors, RegIds]),
            [RegId] = RegIds,
            ReqUUID = UUID
        end || Session <- req_val(gcm_sessions, Config)
    ],
    ok.

%%--------------------------------------------------------------------
bad_json_test(doc) ->
    ["Test behavior when GCM returns an HTTP 400"];
bad_json_test(Config) ->
    RegId = sc_util:to_bin(req_val(registration_id, Config)),
    ReqUUID = make_uuid(),
    Nf = [{uuid, ReqUUID} | make_nf(RegId, "bad_json_test")],
    SC = <<"400">>,
    SimHdrs = [{"X-GCMSimulator-StatusCode", binary_to_list(SC)}],
    Opts = [{http_headers, SimHdrs}],
    [
        begin
            Name = req_val(name, Session),
            ct:pal("Call gcm_erl_session:send(~p, ~p, ~p)",
                   [Name, Nf, Opts]),
            Result = gcm_erl_session:send(Name, Nf, Opts),
            ct:pal("Got result: ~p", [Result]),
            {error, {UUID, Props}} = Result,
            ReqUUID = UUID,
            SC = req_val(status, Props),
            <<"BadRequest">> = req_val(reason, Props)
        end || Session <- req_val(gcm_sessions, Config)
    ],
    ok.

%%--------------------------------------------------------------------
auth_error_test(doc) ->
    ["Test behavior when GCM returns an auth error (i.e. HTTP 401)"];
auth_error_test(Config) ->
    RegId = sc_util:to_bin(req_val(registration_id, Config)),
    ReqUUID = make_uuid(),
    Nf = [{uuid, ReqUUID} | make_nf(RegId, "auth_error_test")],
    SC = <<"401">>,
    SimHdrs = [{"X-GCMSimulator-StatusCode", binary_to_list(SC)}],
    Opts = [{http_headers, SimHdrs}],
    [
        begin
            Name = req_val(name, Session),
            ct:pal("Call gcm_erl_session:send(~p, ~p, ~p)",
                   [Name, Nf, Opts]),
            Result = gcm_erl_session:send(Name, Nf, Opts),
            ct:pal("Got result: ~p", [Result]),
            {error, {UUID, Props}} = Result,
            ReqUUID = UUID,
            SC = req_val(status, Props),
            <<"AuthenticationFailure">> = req_val(reason, Props)
        end || Session <- req_val(gcm_sessions, Config)
    ],
    ok.

%%--------------------------------------------------------------------
http_error_test(doc) ->
    ["Test behavior when there is an http client error"];
http_error_test(Config) ->
    RegId = sc_util:to_bin(req_val(registration_id, Config)),
    ReqUUID = make_uuid(),
    Nf = [{uuid, ReqUUID} | make_nf(RegId, "http_error_test")],
    Opts =[],
    %% Force a client error by stopping the GCM simulator
    GcmSimNode = req_val(gcm_sim_node, Config),
    stop_gcm_sim(GcmSimNode),
    [
        begin
            Name = req_val(name, Session),
            ct:pal("Call gcm_erl_session:send(~p, ~p, ~p)",
                   [Name, Nf, Opts]),
            Result = gcm_erl_session:send(Name, Nf, Opts),
            ct:pal("Got result: ~p", [Result]),
            {error, Reason} = Result,
            ct:pal("Error: ~p", [Reason]),
            {failed_connect, _} = Reason
        end || Session <- req_val(gcm_sessions, Config)
    ],
    ct:pal("Restarting simulator"),
    {ok, {GcmSimNode, _, _}} = start_simulator(Config),
    ok.

%%--------------------------------------------------------------------
missing_reg_test(doc) ->
    ["Force missing_reg error"];
missing_reg_test(Config) ->
    do_forced_error_test(missing_reg_test, Config).

%%--------------------------------------------------------------------
invalid_reg_test(doc) ->
    ["Force invalid_reg error"];
invalid_reg_test(Config) ->
    do_forced_error_test(invalid_reg_test, Config).

%%--------------------------------------------------------------------
mismatched_sender_test(doc) ->
    ["Force mismatched_sender error"];
mismatched_sender_test(Config) ->
    do_forced_error_test(mismatched_sender_test, Config).

%%--------------------------------------------------------------------
not_registered_test(doc) ->
    ["Force not_registered error"];
not_registered_test(Config) ->
    do_forced_error_test(not_registered_test, Config).

%%--------------------------------------------------------------------
message_too_big_test(doc) ->
    ["Force message_too_big error"];
message_too_big_test(Config) ->
    do_forced_error_test(message_too_big_test, Config).

%%--------------------------------------------------------------------
invalid_data_key_test(doc) ->
    ["Force invalid_data_key error"];
invalid_data_key_test(Config) ->
    do_forced_error_test(invalid_data_key_test, Config).

%%--------------------------------------------------------------------
invalid_ttl_test(doc) ->
    ["Force invalid_ttl error"];
invalid_ttl_test(Config) ->
    do_forced_error_test(invalid_ttl_test, Config).

%%--------------------------------------------------------------------
unavailable_test(doc) ->
    ["Force unavailable error"];
unavailable_test(Config) ->
    do_forced_error_test(unavailable_test, Config).

%%--------------------------------------------------------------------
internal_server_error_test(doc) ->
    ["Force internal_server_error error"];
internal_server_error_test(Config) ->
    do_forced_error_test(internal_server_error_test, Config).

%%--------------------------------------------------------------------
invalid_package_name_test(doc) ->
    ["Force invalid_package_name error"];
invalid_package_name_test(Config) ->
    do_forced_error_test(invalid_package_name_test, Config).

%%--------------------------------------------------------------------
device_msg_rate_exceeded_test(doc) ->
    ["Force device_msg_rate_exceeded error"];
device_msg_rate_exceeded_test(Config) ->
    do_forced_error_test(device_msg_rate_exceeded_test, Config).

%%--------------------------------------------------------------------
topics_msg_rate_exceeded_test(doc) ->
    ["Force topics_msg_rate_exceeded error"];
topics_msg_rate_exceeded_test(Config) ->
    do_forced_error_test(topics_msg_rate_exceeded_test, Config).

%%--------------------------------------------------------------------
unknown_error_for_reg_id_test(doc) ->
    ["Force unknown_error_for_reg_id error"];
unknown_error_for_reg_id_test(Config) ->
    do_forced_error_test(unknown_error_for_reg_id_test, Config).

%%--------------------------------------------------------------------
canonical_id_test(doc) ->
    ["Force canonical id to be returned by GCM sim"];
canonical_id_test(Config) ->
    RegId = sc_util:to_bin(req_val(registration_id, Config)),
    ReqUUID = make_uuid(),
    Nf = [{uuid, ReqUUID} | make_nf(RegId, "canonical_id_test")],
    SC = <<"200">>,
    SimResults = "message_id:9999,registration_id:XXX_ANewCanonicalId_XXX",
    SimHdrs = [{"X-GCMSimulator-StatusCode", binary_to_list(SC)},
               {"X-GCMSimulator-Results", SimResults}],
    Opts = [{http_headers, SimHdrs}],
    [
        begin
            Name = req_val(name, Session),
            ct:pal("Call gcm_erl_session:send(~p, ~p, ~p)",
                   [Name, Nf, Opts]),
            Result = gcm_erl_session:send(Name, Nf, Opts),
            ct:pal("Got result: ~p", [Result]),
            {ok, {UUID, Props}} = Result,
            ReqUUID = UUID,
            SC = req_val(status, Props)
        end || Session <- req_val(gcm_sessions, Config)
    ],
    ok.

%%--------------------------------------------------------------------
server_500_test(doc) ->
    ["Test behavior when GCM returns an HTTP 500 with no Retry-After header"];
server_500_test(Config) ->
    RegId = sc_util:to_bin(req_val(registration_id, Config)),
    ReqUUID = make_uuid(),
    Nf = [{uuid, ReqUUID} | make_nf(RegId, "server_500_test")],
    SC = <<"500">>,
    SimHdrs = [{"X-GCMSimulator-StatusCode", binary_to_list(SC)}],
    Opts = [{http_headers, SimHdrs}],
    [
        begin
            Name = req_val(name, Session),
            ct:pal("Call gcm_erl_session:send(~p, ~p, ~p)",
                   [Name, Nf, Opts]),
            Result = gcm_erl_session:send(Name, Nf, Opts),
            ct:pal("Got result: ~p", [Result]),
            {error, {UUID, Props}} = Result,
            ReqUUID = UUID,
            SC = req_val(status, Props),
            <<"InternalServerError">> = req_val(reason, Props)
        end || Session <- req_val(gcm_sessions, Config)
    ],
    ok.

%%--------------------------------------------------------------------
server_500_with_retry_after_test(doc) ->
    ["Test behavior when GCM returns an HTTP 500 with a Retry-After header"];
server_500_with_retry_after_test(Config) ->
    RegId = sc_util:to_bin(req_val(registration_id, Config)),
    ReqUUID = make_uuid(),
    Nf = [{uuid, ReqUUID} | make_nf(RegId, "server_500_with_retry_after_test")],
    SC = <<"500">>,
    SimHdrs = [{"X-GCMSimulator-StatusCode", binary_to_list(SC)},
               {"X-GCMSimulator-Retry-After", "1"}],
    Opts = [{http_headers, SimHdrs}],
    [
        begin
            Name = req_val(name, Session),
            ct:pal("Call gcm_erl_session:send(~p, ~p, ~p)",
                   [Name, Nf, Opts]),
            Result = gcm_erl_session:send(Name, Nf, Opts),
            ct:pal("Got result: ~p", [Result]),
            {error, {UUID, Props}} = Result,
            ReqUUID = UUID,
            SC = req_val(status, Props),
            <<"InternalServerError">> = req_val(reason, Props)
        end || Session <- req_val(gcm_sessions, Config)
    ],
    ok.

%%--------------------------------------------------------------------
unhandled_status_code_test(doc) ->
    ["Test behavior when GCM returns an unexpected HTTP status code"];
unhandled_status_code_test(Config) ->
    RegId = sc_util:to_bin(req_val(registration_id, Config)),
    ReqUUID = make_uuid(),
    Nf = [{uuid, ReqUUID} | make_nf(RegId, "unhandled_status_code_test")],
    SC = <<"410">>,
    SimHdrs = [{"X-GCMSimulator-StatusCode", binary_to_list(SC)}],
    Opts = [{http_headers, SimHdrs}],
    [
        begin
            Name = req_val(name, Session),
            ct:pal("Call gcm_erl_session:send(~p, ~p, ~p)",
                   [Name, Nf, Opts]),
            Result = gcm_erl_session:send(Name, Nf, Opts),
            ct:pal("Got result: ~p", [Result]),
            {error, {UUID, Props}} = Result,
            ReqUUID = UUID,
            SC = req_val(status, Props),
            StatusDesc = req_val(status_desc, Props),
            StatusDesc = <<"Unknown status code ", SC/binary>>,
            <<"Unknown">> = req_val(reason, Props)
        end || Session <- req_val(gcm_sessions, Config)
    ],
    ok.

%%====================================================================
%% Internal helper functions
%%====================================================================
init_per_testcase_common(Config) ->
    (catch end_per_testcase_common(Config)),
    ok = mnesia:create_schema([node()]),
    ok = mnesia:start(),
    Service = req_val(gcm_service, Config),
    ct:pal("Service: ~p", [Service]),
    Sessions = req_val(gcm_sessions, Config),
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
start_simulator(Config) ->
    {GcmShortSimNode, GcmSimCfg} = get_sim_config(gcm_sim_config, Config),
    ct:log("GCM simulator short node name: ~p", [GcmShortSimNode]),
    ct:log("GCM simulator config: ~p", [GcmSimCfg]),

    %% Start GCM simulator
    ct:log("Starting GCM simulator"),
    Cookie = "scpf",
    SimStartResult = start_gcm_sim(GcmShortSimNode, GcmSimCfg, Cookie),
    {ok, {GcmSimNode, GcmSimStartedApps}} = SimStartResult,
    ct:log("GCM simulator full node name: ~p", [GcmSimNode]),
    ct:log("Started GCM simulator apps ~p", [GcmSimStartedApps]),
    {ok, {GcmSimNode, GcmSimStartedApps, GcmSimCfg}}.

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
    true = is_uuid_str(UUID),
    Status = req_val(status, Props),
    Status = <<"200">>.

%%--------------------------------------------------------------------
make_nf([<<_/binary>>|_] = RegIds, Msg) ->
    [
        {registration_ids, [sc_util:to_bin(RegId) || RegId <- RegIds]},
        {data, [{alert, sc_util:to_bin(Msg)}]}
    ];
make_nf(<<RegId/binary>>, Msg) ->
    [
        {to, RegId},
        {data, [{alert, sc_util:to_bin(Msg)}]}
    ].

%%--------------------------------------------------------------------
do_send_msg_test(Nf, Config) ->
    Opts = make_opts(Nf),
    [
        begin
                Name = req_val(name, Session),
                ct:pal("Call gcm_erl_session:send(~p, ~p, ~p)",
                       [Name, Nf, Opts]),
                Result = gcm_erl_session:send(Name, Nf, Opts),
                {ok, {success, {UUID, Props}}} = Result,
                ct:pal("Got result, uuid = ~s, props = ~p", [UUID, Props]),
                %% Assert UUID is correct
                UUID = pv(uuid, Nf, UUID),
                true = is_uuid_str(UUID)
        end || Session <- req_val(gcm_sessions, Config)
    ].

%%--------------------------------------------------------------------
do_forced_error_test(TestName, Config) ->
    RegId = sc_util:to_bin(req_val(registration_id, Config)),
    ReqUUID = make_uuid(),
    Nf = [{uuid, ReqUUID} | make_nf(RegId, atom_to_list(TestName))],
    SC = <<"200">>,
    {SimErrorResult, SimReason} = sim_config(TestName),
    SimHdrs = [{"X-GCMSimulator-StatusCode", binary_to_list(SC)},
               {"X-GCMSimulator-Results", SimErrorResult}],
    Opts = [{http_headers, SimHdrs}],
    [
        begin
            Name = req_val(name, Session),
            ct:pal("Call gcm_erl_session:send(~p, ~p, ~p)",
                   [Name, Nf, Opts]),
            Result = gcm_erl_session:send(Name, Nf, Opts),
            ct:pal("Got result: ~p", [Result]),
            case Result of
                {error, {UUID, {failed, [{FailReason, RegId}],
                                rescheduled, [RegId]}}} ->
                    ReqUUID = UUID,
                    FailReason = expected_fail_reason(TestName),
                    ct:pal("~p: Rescheduled reg id ~p", [TestName, RegId]);
                {error, {UUID, Props}} ->
                    ReqUUID = UUID,
                    SC = req_val(status, Props),
                    SimReason = req_val(reason, Props)
            end
        end || Session <- req_val(gcm_sessions, Config)
    ],
    ok.

%%--------------------------------------------------------------------
make_opts(Nf) ->
    Data = pv(data, Nf, []),
    case pv(sim_cfg, Data) of
        undefined ->
            SimHdrs = [{"X-GCMSimulator-StatusCode", "200"},
                       {"X-GCMSimulator-Results", "message_id:1000"}],
            [{http_headers, SimHdrs}];
        _ -> % Got sim_cfg, don't add headers
            []
    end.

%%--------------------------------------------------------------------
sim_config(missing_reg_test) ->
    make_sim_config("MissingRegistration");
sim_config(invalid_reg_test) ->
    make_sim_config("InvalidRegistration");
sim_config(mismatched_sender_test) ->
    make_sim_config("MismatchSenderId");
sim_config(not_registered_test) ->
    make_sim_config("NotRegistered");
sim_config(message_too_big_test) ->
    make_sim_config("MessageTooBig");
sim_config(invalid_data_key_test) ->
    make_sim_config("InvalidDataKey");
sim_config(invalid_ttl_test) ->
    make_sim_config("InvalidTtl");
sim_config(unavailable_test) ->
    make_sim_config("Unavailable");
sim_config(internal_server_error_test) ->
    make_sim_config("InternalServerError");
sim_config(invalid_package_name_test) ->
    make_sim_config("InvalidPackageName");
sim_config(device_msg_rate_exceeded_test) ->
    make_sim_config("DeviceMessageRateExceeded");
sim_config(topics_msg_rate_exceeded_test) ->
    make_sim_config("TopicsMessageRateExceeded");
sim_config(unknown_error_for_reg_id_test) ->
    make_sim_config("SomeUnknownError").

%%--------------------------------------------------------------------
expected_fail_reason(TestName) when is_atom(TestName) -> % guess
    list_to_atom("gcm_" ++ error_name(TestName)).

%%--------------------------------------------------------------------
error_name(TestName) when is_atom(TestName) ->
    error_name(atom_to_list(TestName));
error_name(ErrName) ->
    case lists:reverse(ErrName) of
        "tset_" ++ H ->
            lists:reverse(H);
        _ ->
            ErrName
    end.

%%--------------------------------------------------------------------
make_sim_config(ErrorString) ->
    {"error:" ++ ErrorString, sc_util:to_bin(ErrorString)}.

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

