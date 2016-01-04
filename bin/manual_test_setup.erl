-module(manual_test_setup).
-compile(export_all).

test_props() ->
    {ok, PL} = file:consult("etc/manual_test.cfg"),
    PL.

start_session(PL) ->
    Opts = proplists:get_value(session_opts, PL),
    {ok, Pid} = gcm_erl:start_session(my_push_tester, Opts),
    Pid.

send_msg(PL) ->
    SimpleOpts = proplists:get_value(simple_opts, PL),
    gcm_erl:send(my_push_tester, SimpleOpts).

