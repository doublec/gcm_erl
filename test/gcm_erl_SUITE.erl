%%%----------------------------------------------------------------
%%% Purpose: Test suite for the 'gcm_erl' module.
%%%-----------------------------------------------------------------

-module(gcm_erl_SUITE).

-include_lib("common_test/include/ct.hrl").

-compile(export_all).

-define(assertMsg(Cond, Fmt, Args),
    case (Cond) of
        true ->
            ok;
        false ->
            ct:fail("Assertion failed: ~p~n" ++ Fmt, [??Cond] ++ Args)
    end
).

-define(assert(Cond), ?assertMsg((Cond), "", [])).

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Function: suite() -> Info
%%
%% Info = [tuple()]
%%   List of key/value pairs.
%%
%% Description: Returns list of tuples to set default properties
%%              for the suite.
%%
%% Note: The suite/0 function is only meant to be used to return
%% default data values, not perform any other operations.
%%--------------------------------------------------------------------
suite() -> [
        {timetrap, {seconds, 30}},
        {require, sessions},
        {require, registration_id}
    ].

%%--------------------------------------------------------------------
%% Function: init_per_suite(Config0) ->
%%               Config1 | {skip,Reason} | {skip_and_save,Reason,Config1}
%%
%% Config0 = Config1 = [tuple()]
%%   A list of key/value pairs, holding the test case configuration.
%% Reason = term()
%%   The reason for skipping the suite.
%%
%% Description: Initialization before the suite.
%%
%% Note: This function is free to add any key/value pairs to the Config
%% variable, but should NOT alter/remove any existing entries.
%%--------------------------------------------------------------------
init_per_suite(Config) ->
    % ct:get_config(sessions) -> [Session].
    % Session = {session, [{name, atom()}, {certfile, string()}]}.
    Sessions = ct:get_config(sessions),
    ct:pal("Sessions: ~p~n", [Sessions]),
    RegId = ct:get_config(registration_id),
    ct:pal("registration_id: ~p~n", [registration_id]),
    {ok, _} = application:ensure_all_started(ssl),
    {ok, _} = application:ensure_all_started(inets),

    [{registration_id, RegId}, {sessions, Sessions} | Config].

%%--------------------------------------------------------------------
%% Function: end_per_suite(Config0) -> void() | {save_config,Config1}
%%
%% Config0 = Config1 = [tuple()]
%%   A list of key/value pairs, holding the test case configuration.
%%
%% Description: Cleanup after the suite.
%%--------------------------------------------------------------------
end_per_suite(_Config) ->
    ok.

%%--------------------------------------------------------------------
%% Function: init_per_group(GroupName, Config0) ->
%%               Config1 | {skip,Reason} | {skip_and_save,Reason,Config1}
%%
%% GroupName = atom()
%%   Name of the test case group that is about to run.
%% Config0 = Config1 = [tuple()]
%%   A list of key/value pairs, holding configuration data for the group.
%% Reason = term()
%%   The reason for skipping all test cases and subgroups in the group.
%%
%% Description: Initialization before each test case group.
%%--------------------------------------------------------------------
init_per_group(_GroupName, Config) ->
    Config.

%%--------------------------------------------------------------------
%% Function: end_per_group(GroupName, Config0) ->
%%               void() | {save_config,Config1}
%%
%% GroupName = atom()
%%   Name of the test case group that is finished.
%% Config0 = Config1 = [tuple()]
%%   A list of key/value pairs, holding configuration data for the group.
%%
%% Description: Cleanup after each test case group.
%%--------------------------------------------------------------------
end_per_group(_GroupName, _Config) ->
    ok.

%%--------------------------------------------------------------------
%% Function: init_per_testcase(TestCase, Config0) ->
%%               Config1 | {skip,Reason} | {skip_and_save,Reason,Config1}
%%
%% TestCase = atom()
%%   Name of the test case that is about to run.
%% Config0 = Config1 = [tuple()]
%%   A list of key/value pairs, holding the test case configuration.
%% Reason = term()
%%   The reason for skipping the test case.
%%
%% Description: Initialization before each test case.
%%
%% Note: This function is free to add any key/value pairs to the Config
%% variable, but should NOT alter/remove any existing entries.
%%--------------------------------------------------------------------
init_per_testcase(_Case, Config) ->
    init_per_testcase_common(Config).

%%--------------------------------------------------------------------
%% Function: end_per_testcase(TestCase, Config0) ->
%%               void() | {save_config,Config1} | {fail,Reason}
%%
%% TestCase = atom()
%%   Name of the test case that is finished.
%% Config0 = Config1 = [tuple()]
%%   A list of key/value pairs, holding the test case configuration.
%% Reason = term()
%%   The reason for failing the test case.
%%
%% Description: Cleanup after each test case.
%%--------------------------------------------------------------------
end_per_testcase(_Case, Config) ->
    end_per_testcase_common(Config).

%%--------------------------------------------------------------------
%% Function: groups() -> [Group]
%%
%% Group = {GroupName,Properties,GroupsAndTestCases}
%% GroupName = atom()
%%   The name of the group.
%% Properties = [parallel | sequence | Shuffle | {RepeatType,N}]
%%   Group properties that may be combined.
%% GroupsAndTestCases = [Group | {group,GroupName} | TestCase]
%% TestCase = atom()
%%   The name of a test case.
%% Shuffle = shuffle | {shuffle,Seed}
%%   To get cases executed in random order.
%% Seed = {integer(),integer(),integer()}
%% RepeatType = repeat | repeat_until_all_ok | repeat_until_all_fail |
%%              repeat_until_any_ok | repeat_until_any_fail
%%   To get execution of cases repeated.
%% N = integer() | forever
%%
%% Description: Returns a list of test case group definitions.
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
                subscription_test
            ]
        }
    ].

%%--------------------------------------------------------------------
%% Function: all() -> GroupsAndTestCases | {skip,Reason}
%%
%% GroupsAndTestCases = [{group,GroupName} | TestCase]
%% GroupName = atom()
%%   Name of a test case group.
%% TestCase = atom()
%%   Name of a test case.
%% Reason = term()
%%   The reason for skipping all groups and test cases.
%%
%% Description: Returns the list of groups and test cases that
%%              are to be executed.
%%--------------------------------------------------------------------
all() ->
    [
        {group, session}
    ].

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

% t_1(doc) -> ["t/1 should return 0 on an empty list"];
% t_1(suite) -> [];
% t_1(Config) when is_list(Config)  ->
%     ?line 0 = t:foo([]),
%     ok.

send_msg_test(doc) ->
    ["gcm_erl_session:send/2 should send a message to GCM"];
send_msg_test(suite) ->
    [];
send_msg_test(Config) ->
    RegId = value(registration_id, Config),
    [
        begin
                Name = value(name, Session),
                GcmOpts = make_opts(RegId, "Hello, world!"),
                {ok, ReqId} = gcm_erl_session:send(Name, GcmOpts),
                ct:pal("Sent notification, req id = ~p~n", [ReqId])
        end || Session <- value(sessions, Config)
    ],
    ok.

send_msg_via_api_test(doc) ->
    ["gcm_erl:send/2 should send a message to GCM"];
send_msg_via_api_test(suite) ->
    [];
send_msg_via_api_test(Config) ->
    RegId = value(registration_id, Config),
    [
        begin
                Name = value(name, Session),
                GcmOpts = make_opts(RegId, "Hello, world!"),
                {ok, ReqId} = gcm_erl:send(Name, GcmOpts),
                ct:pal("Sent notification via API, req id = ~p~n", [ReqId])
        end || Session <- value(sessions, Config)
    ],
    ok.

subscription_test(doc) ->
    ["gcm_erl_session:send/3 should send a message to GCM and deliver results to self"];
subscription_test(suite) ->
    [];
subscription_test(Config) ->
    RegId = value(registration_id, Config),
    [
        begin
            Name = value(name, Session),
            GcmOpts = make_opts(RegId, "Hello, world!"),
            Opts = [{callback, {self(), [progress,completion]}}],
            {ok, ReqId} = gcm_erl_session:send(Name, GcmOpts, Opts),
            ct:pal("Sent notification, req id = ~p~n", [ReqId]),
            subs_receive_loop(ReqId)
        end || Session <- value(sessions, Config)
    ],
    ok.

subs_receive_loop(Ref) ->
    receive
        {gcm_erl, completion, Ref, Status} ->
            ct:log("completion: req id ~p -> ~p", [Ref, Status]),
            ok = Status;
        {gcm_erl, progress, Ref, Status} ->
            ct:log("progress: req id ~p -> ~p", [Ref, Status]),
            subs_receive_loop(Ref)
    end.

%%====================================================================
%% Internal helper functions
%%====================================================================
init_per_testcase_common(Config) ->
    %(catch end_per_testcase_common(Config)),
    mnesia:create_schema([node()]),
    ok = application:set_env(gcm_erl, service, ct:get_config(service)),
    ok = application:set_env(gcm_erl, sessions, ct:get_config(sessions)),
    {ok, _} = application:ensure_all_started(gcm_erl),
    Config.

end_per_testcase_common(Config) ->
    ok = application:stop(gcm_erl),
    ok = application:stop(sc_push_lib),
    ok = application:stop(sc_util),
    ok = application:stop(jsx),
    stopped = mnesia:stop(),
    ok = mnesia:delete_schema([node()]),
    Config.

value(Key, Config) ->
    V = proplists:get_value(Key, Config),
    ?assertMsg(V =/= undefined, "Required key missing: ~p~n", [Key]),
    V.

make_opts(RegId, Msg) ->
    [
        {registration_ids, [sc_util:to_bin(RegId)]}, % Required, all others optional
        {data, [{alert, sc_util:to_bin(Msg)}]}
    ].

%%====================================================================
%% Lager support
%%====================================================================
lager_config(Config) ->
    PrivDir = value(priv_dir, Config), % Standard CT variable
    [
        %% What handlers to install with what arguments
        {handlers, [
                {lager_console_backend, info},
                {lager_file_backend, [
                        {filename:join(PrivDir, "error.log"), error, 10485760, "$D0", 5},
                        {filename:join(PrivDir, "console.log"), info, 10485760, "$D0", 5}
                    ]
                }
            ]},
        %% Whether to write a crash log, and where. Undefined means no crash logger.
        {crash_log, filename:join(PrivDir, "crash.log")}
    ].


