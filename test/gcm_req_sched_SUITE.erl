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
suite() -> [
        {timetrap, {seconds, 30}}
    ].

%%--------------------------------------------------------------------
init_per_suite(Config) ->
    Config.

%%--------------------------------------------------------------------
end_per_suite(Config) ->
    Config.

%%--------------------------------------------------------------------
init_per_group(_GroupName, Config) ->
    Config.

%%--------------------------------------------------------------------
end_per_group(_GroupName, _Config) ->
    ok.

%%--------------------------------------------------------------------
init_per_testcase(_Case, Config) ->
    {ok, Pid} = gcm_req_sched:start(),
    ct:pal("Started gcm_req_sched, pid ~p~n", [Pid]),
    Config.

%%--------------------------------------------------------------------
end_per_testcase(_Case, Config) ->
    ok = gcm_req_sched:stop(),
    ct:pal("Stopped gcm_req_sched~n", []),
    Config.

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
all() ->
    [
     {group, main}
    ].

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
start_stop_test(doc) ->
    ["start_link/0 and shutdown test"];
start_stop_test(suite) ->
    [];
start_stop_test(Config) ->
    %% All handled in per testcase init.
    Config.

%%--------------------------------------------------------------------
add_lookup_test(doc) -> ["Test add/4 and get/1"];
add_lookup_test(suite) -> [];
add_lookup_test(Config) ->
    Id = 123,
    Trigger = sc_util:posix_time() + 60,
    ok = gcm_req_sched:add(Id, Trigger, some_data, self()),
    {ok, {Trigger, some_data}} = gcm_req_sched:get(Id),
    Config.

%%--------------------------------------------------------------------
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

%%--------------------------------------------------------------------
trigger_test(doc)   -> ["Test timeouts and trigger callback"];
trigger_test(suite) -> [];
trigger_test(Config) ->
    Id = 123,
    TriggerAfterSecs = 3,
    TimeoutMs = (TriggerAfterSecs * 1000) + 1000,
    Trigger = sc_util:posix_time() + TriggerAfterSecs,
    ok = gcm_req_sched:add(Id, Trigger, some_data, self()),
    receive
        {triggered, {Id, some_data}} ->
            notfound = gcm_req_sched:get(Id) % Should have deleted it
    after
        TimeoutMs ->
            ct:fail("Trigger timed out")
    end,
    Config.

%%--------------------------------------------------------------------
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

%%--------------------------------------------------------------------
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
%%--------------------------------------------------------------------
gather_responses(IdSet, Timeout) ->
    TimerRef = erlang:send_after(Timeout, self(), timeout),
    NewIdSet = gather_responses_loop(IdSet),
    erlang:cancel_timer(TimerRef),
    NewIdSet.

%%--------------------------------------------------------------------
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

%%--------------------------------------------------------------------
trig(Max) ->
    random:uniform(Max).

%%--------------------------------------------------------------------
value(Key, Config) ->
    V = proplists:get_value(Key, Config),
    ?assertMsg(V =/= undefined, "Required key missing: ~p~n", [Key]),
    V.

