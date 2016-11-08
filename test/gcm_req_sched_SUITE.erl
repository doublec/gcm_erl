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
start_stop_test(Config) ->
    %% All handled in per testcase init.
    Config.

%%--------------------------------------------------------------------
add_lookup_test(doc) -> ["Test add/4 and get/1"];
add_lookup_test(Config) ->
    Id = 123,
    Now = erlang:monotonic_time(milli_seconds),
    Trigger = Now + 60 * 1000,
    ok = gcm_req_sched:add(Id, {Trigger, milli_seconds}, some_data, self()),
    {ok, {Trigger, some_data}} = gcm_req_sched:get(Id),
    Config.

%%--------------------------------------------------------------------
del_test(doc) -> ["Test del/1"];
del_test(Config) ->
    Id = 123,
    Now = erlang:monotonic_time(milli_seconds),
    Trigger = Now + 60000,
    ok = gcm_req_sched:add(Id, {Trigger, milli_seconds}, some_data, self()),
    {ok, {Trigger, some_data}} = gcm_req_sched:get(Id),
    ok = gcm_req_sched:del(Id),
    notfound = gcm_req_sched:get(Id),
    Config.

%%--------------------------------------------------------------------
trigger_test(doc)   -> ["Test timeouts and trigger callback"];
trigger_test(Config) ->
    Id = 123,
    TriggerAfterSecs = 1,
    TimeoutMs = (TriggerAfterSecs * 1000) + 2000,
    StartMs = erlang:monotonic_time(milli_seconds),
    Trigger = {StartMs + (TriggerAfterSecs * 1000), milli_seconds},
    ok = gcm_req_sched:add(Id, Trigger, some_data, self()),
    receive
        {triggered, {Id, some_data}} ->
            EndMs = erlang:monotonic_time(milli_seconds),
            notfound = gcm_req_sched:get(Id), % Should have deleted it
            ElapsedMs = EndMs - StartMs,
            true = ElapsedMs >= TriggerAfterSecs * 1000,
            %% Allow a 1-second margin. Is this reasonable?
            true = ElapsedMs < (TriggerAfterSecs + 1) * 1000
    after
        TimeoutMs ->
            ct:fail("Trigger timed out")
    end,
    Config.

%%--------------------------------------------------------------------
trigger_many_test(doc)   -> ["Test timeouts and trigger callback"];
trigger_many_test(Config) ->
    Ids = lists:seq(1, 100),
    IdSet = sets:from_list(Ids), % Tracking
    MaxSecs = 10,
    Timeout = (MaxSecs + 3) * 1000, % ms
    Self = self(),
    Now = erlang:monotonic_time(seconds),
    [ok = gcm_req_sched:add(Id, Now + trig(MaxSecs), Id, Self) || Id <- Ids],
    NewSet = gather_responses(IdSet, Timeout),
    0 = sets:size(NewSet),
    flush(),
    Config.

%%--------------------------------------------------------------------
clear_all_test(doc) -> ["Test clear_all/0"];
clear_all_test(Config) ->
    Ids = lists:seq(1, 50),
    Now = erlang:monotonic_time(seconds),
    Trigger = Now + 60,
    [ok = gcm_req_sched:add(Id, Trigger, some_data, self()) || Id <- Ids],
    ok = gcm_req_sched:clear_all(),
    [notfound = gcm_req_sched:get(Id) || Id <- Ids],
    flush(),
    Config.

%%====================================================================
%% Internal helper functions
%%====================================================================
%%--------------------------------------------------------------------
gather_responses(IdSet, Timeout) ->
    TimerRef = erlang:send_after(Timeout, self(), timeout),
    NewIdSet = gather_responses_loop(IdSet),
    erlang:cancel_timer(TimerRef),
    flush(),
    NewIdSet.

%%--------------------------------------------------------------------
gather_responses_loop(IdSet) ->
    receive
        {triggered, {Id, Id}} ->
            ct:pal("Got trigger for id ~p", [Id]),
            notfound = gcm_req_sched:get(Id),
            NewSet = sets:del_element(Id, IdSet),
            1 = sets:size(sets:subtract(IdSet, NewSet)),
            case sets:size(NewSet) of
                0 -> % We are done
                    NewSet;
                _ ->
                    gather_responses_loop(NewSet)
            end;
        timeout ->
            ct:fail("Exceeded timeout, ~B remaining IDs: ~p",
                    [sets:size(IdSet), sets:to_list(IdSet)]);
        Other ->
            ct:fail("Received unexpected message: ~p", [Other])
    end.

%%--------------------------------------------------------------------
trig(Max) ->
    random:uniform(Max).

%%--------------------------------------------------------------------
value(Key, Config) ->
    V = proplists:get_value(Key, Config),
    ?assertMsg(V =/= undefined, "Required key missing: ~p~n", [Key]),
    V.

%%--------------------------------------------------------------------
flush() ->
    receive
        Thing ->
            ct:pal("Still in mailbox: ~p", [Thing]),
            flush()
    after
        0 ->
            ok
    end.

