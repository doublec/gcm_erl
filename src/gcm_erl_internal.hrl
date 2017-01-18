-ifndef(__GCM_ERL_INTERNAL_HRL).
-define(__GCM_ERL_INTERNAL_HRL, true).

-define(assert(Cond),
    case (Cond) of
        true ->
            true;
        false ->
            throw({assertion_failed, ??Cond})
    end).

-define(assertList(Term),
        begin ?assert(is_list(Term)), Term end).
-define(assertInt(Term),
        begin ?assert(is_integer(Term)), Term end).
-define(assertPosInt(Term),
        begin ?assert(is_integer(Term) andalso Term > 0), Term end).
-define(assertNonNegInt(Term),
        begin ?assert(is_integer(Term) andalso Term >= 0), Term end).
-define(assertBinary(Term),
        begin ?assert(is_binary(Term)), Term end).
-define(assertReadFile(Filename),
        ((fun(Fname) ->
                 case file:read_file(Fname) of
                     {ok, B} ->
                         B;
                     {error, Reason} ->
                         throw({file_read_error,
                                {Reason, file:format_error(Reason), Fname}})
                 end
         end)(Filename))).

-define(LOG_GENERAL(Sink, Level, Fmt, Args), Sink:Level(Fmt, Args)).

-define(LOG_DEBUG(Fmt, Args),     ?LOG_GENERAL(lager, debug, Fmt, Args)).
-define(LOG_INFO(Fmt, Args),      ?LOG_GENERAL(lager, info, Fmt, Args)).
-define(LOG_NOTICE(Fmt, Args),    ?LOG_GENERAL(lager, notice, Fmt, Args)).
-define(LOG_WARNING(Fmt, Args),   ?LOG_GENERAL(lager, warning, Fmt, Args)).
-define(LOG_ERROR(Fmt, Args),     ?LOG_GENERAL(lager, error, Fmt, Args)).
-define(LOG_CRITICAL(Fmt, Args),  ?LOG_GENERAL(lager, critical, Fmt, Args)).
-define(LOG_ALERT(Fmt, Args),     ?LOG_GENERAL(lager, alert, Fmt, Args)).
-define(LOG_EMERGENCY(Fmt, Args), ?LOG_GENERAL(lager, emergency, Fmt, Args)).

% Note this requires {extra_sinks, [{sentry_lager_event, [{handlers, ...}]}]}
% in lager's sys.config stanza. It also needs {lager_extra_sinks, [sentry]} in
% rebar.config.
-define(SENTRY_DEBUG(Fmt, Args),     ?LOG_GENERAL(sentry, debug, Fmt, Args)).
-define(SENTRY_INFO(Fmt, Args),      ?LOG_GENERAL(sentry, info, Fmt, Args)).
-define(SENTRY_NOTICE(Fmt, Args),    ?LOG_GENERAL(sentry, notice, Fmt, Args)).
-define(SENTRY_WARNING(Fmt, Args),   ?LOG_GENERAL(sentry, warning, Fmt, Args)).
-define(SENTRY_ERROR(Fmt, Args),     ?LOG_GENERAL(sentry, error, Fmt, Args)).
-define(SENTRY_CRITICAL(Fmt, Args),  ?LOG_GENERAL(sentry, critical, Fmt, Args)).
-define(SENTRY_ALERT(Fmt, Args),     ?LOG_GENERAL(sentry, alert, Fmt, Args)).
-define(SENTRY_EMERGENCY(Fmt, Args), ?LOG_GENERAL(sentry, emergency, Fmt, Args)).

-define(STACKTRACE(Class, Reason),
        lager:pr_stacktrace(erlang:get_stacktrace(), {Class, Reason})).

-ifdef(namespaced_queues).
-type sc_queue() :: queue:queue().
-else.
-type sc_queue() :: queue().
-endif.


-endif.

