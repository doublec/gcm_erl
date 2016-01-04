%%%----------------------------------------------------------------
%%% Purpose: Test suite for the 'gcm_req_sched' module.
%%%-----------------------------------------------------------------
-module(gcm_req_sched_SUITE).

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
        {timetrap, {seconds, 30}}
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
    Config.

%%--------------------------------------------------------------------
%% Function: end_per_suite(Config0) -> void() | {save_config,Config1}
%%
%% Config0 = Config1 = [tuple()]
%%   A list of key/value pairs, holding the test case configuration.
%%
%% Description: Cleanup after the suite.
%%--------------------------------------------------------------------
end_per_suite(Config) ->
    Config.

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
    {ok, Pid} = gcm_req_sched:start(),
    ct:pal("Started gcm_req_sched, pid ~p~n", [Pid]),
    Config.

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
    ok = gcm_req_sched:stop(),
    ct:pal("Stopped gcm_req_sched~n", []),
    Config.

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
            main, [], [
                start_stop_test,
                add_lookup_test,
                del_test,
                trigger_test,
                trigger_many_test,
                clear_all_test
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
        {group, main}
    ].

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

% t_1(doc) -> ["t/1 should return 0 on an empty list"];
% t_1(suite) -> [];
% t_1(Config) when is_list(Config)  ->
%     ?line 0 = t:foo([]),
%     ok.

start_stop_test(doc) ->
    ["start_link/0 and shutdown test"];
start_stop_test(suite) ->
    [];
start_stop_test(Config) ->
    %% All handled in per testcase init.
    Config.

add_lookup_test(doc) -> ["Test add/4 and get/1"];
add_lookup_test(suite) -> [];
add_lookup_test(Config) ->
    Id = 123,
    Trigger = sc_util:posix_time() + 60,
    ok = gcm_req_sched:add(Id, Trigger, some_data, self()),
    {ok, {Trigger, some_data}} = gcm_req_sched:get(Id),
    Config.

del_test(doc) -> ["Test del/1"];
del_test(suite) -> [];
del_test(Config) ->
    Id = 123,
    Trigger = sc_util:posix_time() + 60,
    ok = gcm_req_sched:add(Id, Trigger, some_data, self()),
    {ok, {Trigger, some_data}} = gcm_req_sched:get(Id),
    ok = gcm_req_sched:del(Id),
    notfound = gcm_req_sched:get(Id),
    Config.

trigger_test(doc)   -> ["Test timeouts and trigger callback"];
trigger_test(suite) -> [];
trigger_test(Config) ->
    Id = 123,
    Trigger = sc_util:posix_time() + 3,
    ok = gcm_req_sched:add(Id, Trigger, some_data, self()),
    receive
        {triggered, {Id, some_data}} ->
            notfound = gcm_req_sched:get(Id) % Should have deleted it
    after
        4000 ->
            ct:fail("Trigger timed out")
    end,
    Config.

trigger_many_test(doc)   -> ["Test timeouts and trigger callback"];
trigger_many_test(suite) -> [];
trigger_many_test(Config) ->
    Ids = lists:seq(1, 100),
    IdSet = sets:from_list(Ids), % Tracking
    MaxSecs = 10,
    Timeout = (MaxSecs + 3) * 1000, % ms

    [ok = gcm_req_sched:add(Id, trig(MaxSecs), Id, self()) || Id <- Ids],
    NewSet = gather_responses(IdSet, Timeout),
    0 = sets:size(NewSet),
    Config.

clear_all_test(doc) -> ["Test clear_all/0"];
clear_all_test(suite) -> [];
clear_all_test(Config) ->
    Ids = lists:seq(1, 50),
    Trigger = sc_util:posix_time() + 60,
    [ok = gcm_req_sched:add(Id, Trigger, some_data, self()) || Id <- Ids],
    ok = gcm_req_sched:clear_all(),
    [notfound = gcm_req_sched:get(Id) || Id <- Ids],
    Config.

%%====================================================================
%% Internal helper functions
%%====================================================================
gather_responses(IdSet, Timeout) ->
    TimerRef = erlang:send_after(Timeout, self(), timeout),
    NewIdSet = gather_responses_loop(IdSet),
    erlang:cancel_timer(TimerRef),
    NewIdSet.

gather_responses_loop(IdSet) ->
    receive
        {triggered, {Id, Id}} ->
            notfound = gcm_req_sched:get(Id),
            NewSet = sets:del_element(Id, IdSet),
            case sets:size(NewSet) of
                0 -> % We are done
                    NewSet;
                _ ->
                    gather_responses_loop(NewSet)
            end;
        timeout ->
            ct:fail("Exceeded timeout, remaining IDs: ~p~n",
                    [sets:to_list(IdSet)])
    end.

trig(Max) ->
    random:uniform(Max).

value(Key, Config) ->
    V = proplists:get_value(Key, Config),
    ?assertMsg(V =/= undefined, "Required key missing: ~p~n", [Key]),
    V.

