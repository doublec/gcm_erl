%%% ==========================================================================
%%% Copyright 2015 Silent Circle
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%% ==========================================================================

%%%-------------------------------------------------------------------
%%% @author Edwin Fine <efine@silentcircle.com>
%%% @copyright 2015 Silent Circle
%%% @doc
%%% GCM server session. There must be one session per API key and
%%% Sessions must have unique (i.e. they are registered) names
%%% within the node.
%%%
%%% Reference:
%%%
%%% <a href="http://developer.android.com/guide/google/gcm/gcm.html#server"/>
%%% @end
%%%-------------------------------------------------------------------
-module(gcm_erl_session).

-behaviour(gen_server).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

%%--------------------------------------------------------------------
-define(SERVER, ?MODULE).

-define(SECONDS, 1).
-define(MINUTES, (60 * ?SECONDS)).
-define(HOURS, (60 * ?MINUTES)).
-define(DAYS, (24 * ?HOURS)).
-define(WEEKS, (7 * ?DAYS)).

-define(DEFAULT_GCM_URI, "https://gcm-http.googleapis.com/gcm/send").
-define(DEFAULT_MAX_ATTEMPTS, 1000).
-define(DEFAULT_RETRY_INTERVAL, 1).
-define(DEFAULT_MAX_REQ_TTL, 3600).
-define(DEFAULT_MAX_BACKOFF_SECS, 64).
-define(DEFAULT_EXPIRY_TIME, (4 * ?WEEKS)).

-define(nyi, throw(not_yet_implemented)).

-define(assert(Cond),
    case (Cond) of
        true ->
            true;
        false ->
            throw({assertion_failed, ??Cond})
    end).

-define(assertList(Term), begin ?assert(is_list(Term)), Term end).
-define(assertInt(Term), begin ?assert(is_integer(Term)), Term end).
-define(assertPosInt(Term), begin ?assert(is_integer(Term) andalso Term > 0), Term end).
-define(assertBinary(Term), begin ?assert(is_binary(Term)), Term end).

%%--------------------------------------------------------------------
-type field() :: string().
-type value() :: string().
-type header() :: {field(), value()}.
-type url() :: string().
-type headers() :: [header()].
-type content_type() :: string().
-type body() :: string() | binary(). %% We won't be using the fun or chunkify parts

%% We are using POSTs only, so need the content_type() and body().
-type httpc_request() :: {url(), headers(), content_type(), body()}.
-type notification() :: gcm_json:notification().
-type subscription() :: 'progress' | 'completion'.
-type terminate_reason() :: normal |
                            shutdown |
                            {shutdown, term()} |
                            term().

%%--------------------------------------------------------------------
-include_lib("lager/include/lager.hrl").

%%--------------------------------------------------------------------
-record(gcm_req, {
        req_id                                 :: undefined | reference(),
        cb_pid                                 :: undefined | pid(),
        subscriptions = []                     :: [subscription()],
        req_data    = []                       :: notification(),
        http_req                               :: httpc_request(),
        headers     = [],
        http_opts   = [],
        httpc_opts  = [],
        req_opts    = [],
        num_attempts = 0                       :: non_neg_integer(),
        created_at  = 0                        :: integer(),
        backoff_secs = ?DEFAULT_RETRY_INTERVAL :: non_neg_integer()
    }).

-type gcm_req() :: #gcm_req{}.

-record(state, {
        id_seq_no               = 0                           :: integer(),
        name                    = undefined                   :: atom(),
        uri                     = ?DEFAULT_GCM_URI            :: string(),
        api_key                 = <<>>                        :: binary(),
        auth_value              = "key="                      :: string(),
        restricted_package_name = <<>>                        :: binary(),
        max_attempts            = ?DEFAULT_MAX_ATTEMPTS       :: non_neg_integer(),
        retry_interval          = ?DEFAULT_RETRY_INTERVAL     :: non_neg_integer(),
        max_req_ttl             = ?DEFAULT_MAX_REQ_TTL        :: non_neg_integer(),
        max_backoff_secs        = ?DEFAULT_MAX_BACKOFF_SECS   :: non_neg_integer(),
        ssl_opts                = []                          :: list(),
        httpc_opts              = []                          :: list()
    }).

-type state() :: #state{}.

%%%===================================================================
%%% API
%%%===================================================================
-export([start/2,
         start_link/2,
         stop/1,
         send/2,
         send/3,
         async_send/2,
         async_send/3,
         get_state/1]).

-export_type([opt/0,
              start_opts/0]).

-type opt() :: {uri, string()}
             | {api_key, binary()}
             | {restricted_package_name, binary()}
             | {max_req_ttl, non_neg_integer()}
             | {max_backoff_secs, non_neg_integer()}
             | {max_attempts, non_neg_integer()}
             | {retry_interval, non_neg_integer()}
             | {ssl_opts, list(ssl:ssloption())}
             | {httpc_opts, list()}
             .

-type start_opts() :: list(gcm_erl_session:opt()).

%%--------------------------------------------------------------------
%% @doc Start a named session as described by the `StartOpts'.
%% `Name' is registered so that the session can be referenced using
%% the name to call functions like {@link send/2}.  Note that this
%% function is only used for testing.
%% <ul>
%% <li>For `ssl_opts' see ssl:ssloptions/0 in ssl:connect/2.</li>
%% <li>For `httpc_opts', see httpc:set_options/1.</li>
%% </ul>
%% @see start_link/2.
%% @end
%%--------------------------------------------------------------------
-spec start(atom(), start_opts()) -> term().
start(Name, StartOpts) when is_atom(Name), is_list(StartOpts) ->
    gen_server:start({local, Name}, ?MODULE, [Name, StartOpts], []).

%%--------------------------------------------------------------------
%% @doc Start a named session as described by the options `Opts'.  The name
%% `Name' is registered so that the session can be referenced using
%% the name to call functions like {@link send/2}.
%%
%% == Parameters ==
%% <ul>
%%  <li>`Name' - Session name (atom)</li>
%%  <li>`Opts' - Options
%%   <dl>
%%     <dt>`{api_key, binary()}'</dt>
%%        <dd>Google API Key, e.g.
%%        `<<"AIzafffffffffffffffffffffffffffffffffaA">>'</dd>
%%     <dt>`{max_attempts, pos_integer()|infinity}'</dt>
%%        <dd>The maximum number of times to attempt to send the
%%            message when receiving a 5xx error.</dd>
%%     <dt>`{retry_interval, pos_integer()}'</dt>
%%        <dd>The initial number of seconds to wait before reattempting to
%%        send the message.</dd>
%%     <dt>`{max_req_ttl, pos_integer()}'</dt>
%%        <dd>The maximum time in seconds for which this request
%%        will live before being considered undeliverable and
%%        stopping with an error.</dd>
%%     <dt>`{max_backoff_secs, pos_integer()}'</dt>
%%        <dd>The maximum backoff time in seconds for this request.
%%        This limits the exponential backoff to a maximum
%%        value.</dd>
%%     <dt>`{restricted_package_name, binary()}'</dt>
%%        <dd>A string containing the package name of your
%%        application. When set, messages will only be sent to
%%        registration IDs that match the package name.
%%        Optional.</dd>
%%     <dt>`{uri, string()}'</dt>
%%        <dd>GCM URI, defaults to
%%        `https://gcm-http.googleapis.com/gcm/send'. Optional.</dd>
%%     <dt>`{collapse_key, string()}'</dt>
%%        <dd>Arbitrary string use to collapse a group of like
%%        messages into a single message when the device is offline.
%%        Optional.</dd>
%%   </dl>
%%  </li>
%% </ul>
%%
%% @end
%%--------------------------------------------------------------------
-spec start_link(atom(), start_opts()) -> term().
start_link(Name, Opts) when is_atom(Name), is_list(Opts) ->
    gen_server:start_link({local, Name}, ?MODULE, [Name, Opts], []).

%%--------------------------------------------------------------------
%% @doc Stop session.
%% @end
%%--------------------------------------------------------------------
-spec stop(SvrRef::term()) -> term().
stop(SvrRef) ->
    gen_server:cast(SvrRef, stop).

%%--------------------------------------------------------------------
%% @doc Send a notification specified by `Notification' via
%% `SvrRef'.  For JSON format, see
%% <a href="http://developer.android.com/guide/google/gcm/gcm.html#server">
%% GCM Architectural Overview</a>.
%%
%% @see gcm_json:make_notification/1.
%% @see gcm_json:notification/0.
%% @end
%%--------------------------------------------------------------------
-spec send(SvrRef::term(), Notification::notification()) ->
       {ok, Ref::term()} | {error, Reason::term()}.
send(SvrRef, Notification) when is_list(Notification) ->
    send(SvrRef, Notification, []).

%%--------------------------------------------------------------------
%% @doc Send a notification specified by `Notification' via
%% `SvrRef', with options `Opts'.
%%
%% For JSON format, see
%% <a href="http://developer.android.com/guide/google/gcm/gcm.html#server">
%% GCM Architectural Overview</a>.
%%
%% == Options ==
%% <dl>
%%   <dt>`{callback, {pid(), [progress|completion]}}'</dt>
%%      <dd>Optional internal parameters. This is never sent to GCM.
%%
%%      `{callback, {pid(), [...]}}' requests that one or more
%%      status messages be sent to `pid()'. Status messages consist
%%      of `progress' and `completion' messages. Each message is in
%%      the format `{gcm_erl, StatusType, Ref, Status}'.
%%      `StatusType' is either `progress' or `completion'. No
%%      further messages will be sent for that reference once a
%%      `completion' status is sent. `Ref' is the reference that
%%      `send/3' returns on success (i.e. in `{ok, Ref}'). `Status'
%%      is a `term()' that depends on the `StatusType' and state of
%%      the request. For `progress' messages, `Status' is a binary
%%      string, e.g. `<<"accepted">>'. For `completion', `Status' is
%%      either `ok' or `{error, term()}'.
%%
%%      The default is to deliver no status messages.
%%
%%      === Example ===
%%      ```
%%      Opts = [{callback, {self(), [completion]}}],
%%      '''
%%      </dd>
%% </dl>
%% @see gcm_json:make_notification/1.
%% @see gcm_json:notification/0.
%% @end
%%--------------------------------------------------------------------
-spec send(SvrRef::term(), Notification::notification(), Opts::list()) ->
       {ok, Ref::term()} | {error, Reason::term()}.
send(SvrRef, Notification, Opts) when is_list(Notification), is_list(Opts) ->
    gen_server:call(SvrRef, {send, Notification, Opts}).

%%--------------------------------------------------------------------
%% @doc Asynchronously sends a notification specified by
%% `Notification' via `SvrRef'; same as {@link send/2} otherwise.
%% @end
%%--------------------------------------------------------------------
-spec async_send(SvrRef::term(), Notification::notification()) -> ok.
async_send(SvrRef, Notification) when is_list(Notification) ->
    async_send(SvrRef, Notification, []).

%%--------------------------------------------------------------------
%% @doc Asynchronously sends a notification specified by
%% `Notification' via `SvrRef' with options; same as {@link send/3}
%% otherwise.
%% @end
%%--------------------------------------------------------------------
-spec async_send(SvrRef::term(), Notification::notification(), Opts::list()) -> ok.
async_send(SvrRef, Notification, Opts) when is_list(Notification), is_list(Opts) ->
    gen_server:cast(SvrRef, {send, Notification, Opts}).

%%--------------------------------------------------------------------
%% @private
%%--------------------------------------------------------------------
get_state(SvrRef) ->
    gen_server:call(SvrRef, get_state).

async_resched(ServerRef, #gcm_req{} = Req, Headers) when is_list(Headers) ->
    gen_server:cast(ServerRef, {reschedule, Req, Headers}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @end
%%--------------------------------------------------------------------
-spec init(term()) -> {ok, State::term()} |
                      {ok, State::term(), Timeout::timeout()} |
                      {ok, State::term(), 'hibernate'} |
                      {stop, Reason::term()} |
                      'ignore'
                      .

init([Name, Opts]) ->
    try
        {ok, validate_args(Name, Opts)}
    catch
        _What:_Why ->
            {stop, {invalid_opts, Opts}}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages.
%% <dl>
%%   <dt>`{send, Notification, Opts}'</dt>
%%      <dd>`Notification' is as required in gcm_json:make_notification/1.
%%      `Opts' is described in {@link send/3}.
%%      </dd>
%% </dl>
%% @end
%%--------------------------------------------------------------------
-type call_req_type() :: {send, notification(), list()}
                       | get_state
                       | term().

-spec handle_call(Request::call_req_type(),
                  From::{pid(), Tag::term()},
                  State::term()) ->
    {reply, Reply::term(), NewState::term()} |
    {reply, Reply::term(), NewState::term(), Timeout::timeout()} |
    {reply, Reply::term(), NewState::term(), 'hibernate'} |
    {noreply, NewState::term()} |
    {noreply, NewState::term(), 'hibernate'} |
    {noreply, NewState::term(), Timeout::timeout()} |
    {stop, Reason::term(), Reply::term(), NewState::term()} |
    {stop, Reason::term(), NewState::term()}
    .

handle_call({send, Notification, Opts}, _From, #state{uri = URI} = State) ->
    _ = lager:info("send to ~s", [URI]),
    Reply = case try_make_gcm_req(self(), Notification, Opts, State, 1) of
                {ok, GCMReq} ->
                    dispatch_req(GCMReq, State#state.httpc_opts, URI);
                {error, Reason} = Error ->
                    _ = lager:error("Bad GCM notification: ~p, error: ~p",
                                    [Notification, Reason]),
                    Error
            end,
    {reply, Reply, State};

handle_call(get_state, _From, State) ->
    Reply = State,
    {reply, Reply, State};

handle_call(_Request, _From, State) ->
    Reply = {error, invalid_call},
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%% @end
%%--------------------------------------------------------------------
-spec handle_cast(Request::call_req_type(),
                  State::term()) ->
    {noreply, NewState::term()} |
    {noreply, NewState::term(), 'hibernate'} |
    {noreply, NewState::term(), Timeout::timeout()} |
    {stop, Reason::term(), NewState::term()}
    .

handle_cast({send, Notification, Opts}, #state{uri = URI} = State) ->
    _ = lager:info("send to ~s", [URI]),
    Result = case try_make_gcm_req(self(), Notification, Opts, State, 1) of
                 {ok, GCMReq} ->
                     dispatch_req(GCMReq, State#state.httpc_opts, URI);
                 {error, Reason} = Error ->
                     _ = lager:error("Bad GCM notification: ~p, error: ~p",
                                     [Notification, Reason]),
                     Error
             end,
    _ = lager:debug("Result of sending ~p: ~p", [Notification, Result]),
    {noreply, State};
handle_cast({reschedule, #gcm_req{} = Req, Hdrs}, State) when is_list(Hdrs) ->
    reschedule_req(self(), State, Req, Hdrs),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%% @end
%%--------------------------------------------------------------------
-spec handle_info(Request::term(),
                  State::term()) ->
    {noreply, NewState::term()} |
    {noreply, NewState::term(), 'hibernate'} |
    {noreply, NewState::term(), Timeout::timeout()} |
    {stop, Reason::term(), NewState::term()}
    .

handle_info({resched_failed_reg_ids, FailedRegIds, Req, Headers}, State) ->
    NewReq = replace_regids(Req, FailedRegIds),
    reschedule_req(self(), State, NewReq, Headers),
    {noreply, State};
handle_info({http, {RequestId, {error, Reason}}}, State) ->
    Req = retrieve_req(RequestId),
    do_cb({error, Reason}, Req),
    _ = lager:warning("HTTP error; rescheduling request~n"
                      "Reason: ~p~nRequest ID: ~p~nRequest:~p",
                      [Reason, RequestId, Req]),
    reschedule_req(self(), State, Req),
    {noreply, State};
handle_info({http, {ReqId, Result}}, State) ->
    _ = case retrieve_req(ReqId) of
            Req = #gcm_req{} ->
                Self = self(),
                case process_gcm_result(Req, Result) of
                    ok ->
                        do_cb(ok, Req);
                    {ok, _Headers} ->
                        do_cb(ok, Req);
                    {{ok, ErrorList}, Headers} ->
                        ErrorResults = process_errors(Req, ErrorList),
                        process_error_results(Self, Req, Headers,
                                              ErrorResults);
                    {reschedule, Headers} ->
                        reschedule_req(Self, State, Req, Headers);
                    {{error, Reason}, _Headers} ->
                        do_cb({error, Reason}, Req),
                        _ = lager:error("Bad GCM Result, reason: ~p; "
                                        "req = ~p, result = ~p",
                                        [Reason, Req, Result])
                end;
            undefined ->
                _ = lager:error("Req ID not found: ~p", [ReqId])
        end,
    {noreply, State};
%% Trigger notification received from request scheduler.
handle_info({triggered, {_ReqId, GCMReq}}, #state{uri = URI} = State) ->
    dispatch_req(GCMReq, State#state.httpc_opts, URI),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @end
%%--------------------------------------------------------------------
-spec terminate(Reason::terminate_reason(),
                State::term()) -> no_return().
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @end
%%--------------------------------------------------------------------
-spec code_change(OldVsn::term() | {down, term()},
                  State::term(),
                  Extra::term()) ->
    {ok, NewState::term()} |
    {error, Reason::term()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

validate_args(Name, Opts) ->
    SslOpts = pv_req(ssl_opts, Opts),
    HttpcOpts = ?assertList(pv(httpc_opts, Opts, [])),
    ApiKey = ?assertBinary(pv_req(api_key, Opts)),

    #state{
        name = Name, % Name must be Service ++ "_" ++ AppId
        uri = pv(uri, Opts, ?DEFAULT_GCM_URI),
        api_key = ApiKey,
        auth_value = "key=" ++ binary_to_list(ApiKey),
        restricted_package_name = ?assertBinary(pv(restricted_package_name,
                                                Opts,
                                                <<>>)),
        max_attempts = ?assertPosInt(pv(max_attempts,
                                        Opts,
                                        ?DEFAULT_MAX_ATTEMPTS)),
        retry_interval = ?assertPosInt(pv(retry_interval,
                                          Opts,
                                          ?DEFAULT_RETRY_INTERVAL)),
        max_req_ttl = ?assertPosInt(pv(max_req_ttl,
                                       Opts,
                                       ?DEFAULT_MAX_REQ_TTL)),
        max_backoff_secs = ?assertPosInt(pv(max_backoff_secs,
                                         Opts,
                                         ?DEFAULT_MAX_BACKOFF_SECS)),
        ssl_opts = SslOpts,
        httpc_opts = HttpcOpts
    }.

%%--------------------------------------------------------------------
%% The HTTP request is sent asynchronously, and the request ID is added
%% to the push request manager for tracking.
%% The response is dealt with in handle_info({http, _}, State).
dispatch_req(GCMReq, HTTPCOpts, URI) ->
    Request = GCMReq#gcm_req.http_req,
    HTTPOpts = GCMReq#gcm_req.http_opts,
    ReqOpts = GCMReq#gcm_req.req_opts,

    ok = httpc:set_options(HTTPCOpts),
    try httpc:request(post, Request, HTTPOpts, ReqOpts) of
        {ok, RequestId} when is_reference(RequestId) ->
            sc_push_req_mgr:add(RequestId, GCMReq#gcm_req{req_id = RequestId}),
            do_cb(<<"queued">>, GCMReq),
            _ = lager:info("Queued POST (req ID: ~p) to ~s",
                           [RequestId, URI]),
            {ok, RequestId};
        Error ->
            _ = lager:error("POST error to ~s:~n~p", [URI, Error]),
            do_cb({error, Error}, GCMReq),
            Error
    catch
        _Class:Reason ->
            _ = lager:error("POST failed to ~s, reason:~n~p", [URI, Reason]),
            do_cb({error, Reason}, GCMReq),
            {error, Reason}
    end.

%%--------------------------------------------------------------------
retrieve_req(RequestId) ->
    case sc_push_req_mgr:remove(RequestId) of
        [{_,_}|_] = PL ->
            proplists:get_value(req, PL);
        undefined ->
            undefined
    end.

%%--------------------------------------------------------------------
-compile({inline, [{pv, 2}]}).
pv(Key, PL) ->
    proplists:get_value(Key, PL).

-compile({inline, [{pv, 3}]}).
pv(Key, PL, Default) ->
    proplists:get_value(Key, PL, Default).

%%--------------------------------------------------------------------
pv_req(Key, PL) ->
    case pv(Key, PL) of
        undefined ->
            throw({key_not_found, Key});
        Val ->
            Val
    end.

%%--------------------------------------------------------------------
process_gcm_result(#gcm_req{} = Req, {StatusLine, Headers, Resp}) ->
    {_HTTPVersion, StatusCode, ReasonPhrase} = StatusLine,
    case StatusCode of
        200 ->
            {check_json_resp(Req, Resp), Headers};
        400 ->
            _ = lager:error("Bad GCM request, reason: ~s~nReq: ~p",
                            [ReasonPhrase, Req]),
            ok; % Nothing we can do
        401 ->
            _ = lager:error("GCM Req auth failed, reason: ~s~n~p",
                            [ReasonPhrase, Req]),
            ok; % Someone must fix the auth
        Code when Code >= 500 -> % Retry needed
            {reschedule, Headers}
    end.

%%--------------------------------------------------------------------
process_errors(#gcm_req{} = Req, ErrorList) ->
    [process_error(Req, Error) || Error <- ErrorList].

%%--------------------------------------------------------------------
%% Some of the errors require a reschedule of only those registration IDs that
%% failed temporarily, e.g. "Unavailable" error.
process_error_results(Pid, Req, Headers, ErrorResults) ->
    case get_failed_regids(ErrorResults) of
        [] ->
            do_cb(ok, Req),
            ok;
        FailedRegIds ->
            NewReq = replace_regids(Req, FailedRegIds),
            async_resched(Pid, NewReq, Headers)
    end.

%%--------------------------------------------------------------------
get_failed_regids(ErrorResults) ->
    [BRegId || {failed_reg_id, BRegId} <- ErrorResults].

%%--------------------------------------------------------------------
%% @doc Replace the registration IDs in the existing
%% request with the failed ones, so that it retries only those.
replace_regids(Req, FailedRegIds) ->
    ReqData = replace_prop(registration_ids,
                           Req#gcm_req.req_data,
                           FailedRegIds),
    Body = notification_to_json(ReqData),
    HttpReq = setelement(4, Req#gcm_req.http_req, Body),
    Req#gcm_req{req_data = ReqData,
                http_req = HttpReq}.

%%--------------------------------------------------------------------
replace_prop(Key, Props, NewVal) ->
    lists:keyreplace(Key, 1, Props, {Key, NewVal}).

%%--------------------------------------------------------------------
%% process_error/2
%%--------------------------------------------------------------------
process_error(Req, {gcm_missing_reg, _BRegId}) ->
    lager:error("Req missing registration ID: ~p", [Req]);

process_error(_Req, {gcm_invalid_reg, BRegId}) ->
    SvcTok = sc_push_reg_api:make_svc_tok(gcm, BRegId),
    ok = sc_push_reg_api:deregister_svc_tok(SvcTok),
    lager:info("Deregistered invalid registration ID ~p", [BRegId]);

process_error(_Req, {gcm_mismatched_sender, BRegId}) ->
    lager:error("Mismatched Sender for registration ID ~p", [BRegId]);

process_error(Req, {gcm_not_registered, BRegId}) ->
    _ = lager:error("Unregistered registration ID ~p in req ~p",
                    [BRegId, Req]),
    SvcTok = sc_push_reg_api:make_svc_tok(gcm, BRegId),
    ok = sc_push_reg_api:deregister_svc_tok(SvcTok);

process_error(Req, {gcm_message_too_big, _BRegId}) ->
    lager:error("Message too big, req ~p", [Req]);

process_error(Req, {gcm_invalid_data_key, _BRegId}) ->
    lager:error("Invalid data key in req: ~p", [Req]);

process_error(Req, {gcm_invalid_ttl, _BRegId}) ->
    lager:error("Invalid TTL in req: ~p", [Req]);

process_error(_Req, {gcm_unavailable, BRegId}) ->
    {failed_reg_id, BRegId};

process_error(_Req, {gcm_internal_server_error, BRegId}) ->
    {failed_reg_id, BRegId};

process_error(Req, {gcm_invalid_package_name, _BRegId}) ->
    lager:error("Invalid package name in req ~p", [Req]);

%% TODO: Figure out how to compensate for this
process_error(Req, {gcm_device_message_rate_exceeded, _BRegId}) ->
    lager:error("Device message rate exceeded in req ~p", [Req]);

%% TODO: If we add support for topics, fix this.
process_error(Req, {gcm_topics_message_rate_exceeded, _BRegId}) ->
    lager:error("Topics message rate exceeded in req ~p", [Req]);

process_error(Req, {unknown_error_for_reg_id, {BRegId, GCMError}}) ->
    lager:error("Unknown GCM Error ~p sending to registration ID ~p, req: ~p",
                [GCMError, BRegId, Req]);

process_error(_Req, {canonical_id, {old, BRegId}, {new, CanonicalId}}) ->
    _ = lager:info("Changing old GCM reg id ~p to new ~p",
                   [BRegId, CanonicalId]),
    OldSvcTok = sc_push_reg_api:make_svc_tok(gcm, BRegId),
    ok = sc_push_reg_api:reregister_svc_tok(OldSvcTok, CanonicalId).

%% @doc
%% See <a href="http://developer.android.com/google/gcm/gcm.html#response">
%% GCM Architectural Reference</a> for more details.
%%
%% JSON response can contain the following:
%%
%% <dl>
%%     <dt>`multicast_id'</dt>
%%       <dd>Unique ID (number) identifying the multicast
%%       message.</dd>
%%     <dt>`success'</dt>
%%       <dd>Number of messages that were processed without an
%%       error.</dd>
%%     <dt>`failure'</dt>
%%       <dd>Number of messages that could not be processed.</dd>
%%     <dt>`canonical_ids'</dt>
%%       <dd>
%%       Number of results that contain a canonical registration ID.
%%       See Advanced Topics for more discussion of this topic.
%%       </dd>
%%     <dt>`results'</dt>
%%       <dd>
%%       Array of objects representing the status of the messages
%%       processed. The objects are listed in the same order as the
%%       request (i.e., for each registration ID in the request, its
%%       result is listed in the same index in the response) and
%%       they can have these fields:
%%         <dl>
%%            <dt>`message_id'</dt>
%%              <dd>
%%              String representing the message when it was
%%              successfully processed.
%%              </dd>
%%            <dt>`registration_id'</dt>
%%              <dd>
%%              If set, means that GCM processed the message but it
%%              has another canonical registration ID for that
%%              device, so sender should replace the IDs on future
%%              requests (otherwise they might be rejected). This
%%              field is never set if there is an error in the
%%              request.
%%              </dd>
%%            <dt>`error'</dt>
%%              <dd>
%%              String describing an error that occurred while
%%              processing the message for that recipient. The
%%              possible values are the same as documented in the
%%              above table, plus "Unavailable" (meaning GCM servers
%%              were busy and could not process the message for that
%%              particular recipient, so it could be retried).
%%              </dd>
%%         </dl>
%%     </dd>
%% </dl>

%%--------------------------------------------------------------------
check_json_resp(Req, Resp) ->
    try
        EJSON = jsx:decode(Resp),
        check_ejson_resp(Req, EJSON)
    catch
        Class:Reason ->
            CR = {Class, Reason},
            _ = lager:error("JSON error ~p parsing GCM resp, req: ~p, resp ~p",
                            [CR, Req, Resp]),
            {error, Reason}
    end.

%%--------------------------------------------------------------------
-spec check_ejson_resp(#gcm_req{}, list())
      -> ok | {ok, list()} | {error, term()}.
check_ejson_resp(Req, EJSON) ->
    case {pv(<<"failure">>, EJSON, 0), pv(<<"canonical_ids">>, EJSON, 0)} of
        {0, 0} -> % All successful!
            do_cb(ok, Req),
            ok;
        {_, _} ->
            Results = pv(<<"results">>, EJSON, []),
            check_results(Req, Results)
    end.

%%--------------------------------------------------------------------
-spec check_results(#gcm_req{}, list()) -> ok | {ok, list()} | {error, term()}.
check_results(Req, []) -> % No results, nothing to do
    _ = lager:warning("Expected GCM results, none found for req ~p", [Req]),
    do_cb({error, no_results_received}, Req),
    ok;
check_results(#gcm_req{req_data = Props}, Results) ->
    RegistrationIds = case pv(registration_ids, Props, []) of
        [] -> % Generate correct number of empty RegId binaries
            lists:duplicate(length(Results), <<>>);
        L when is_list(L) ->
            L
    end,
    check_results(RegistrationIds, Results, []).

%%--------------------------------------------------------------------
-spec check_results(list(binary()), list(), list())
      ->  {ok, list()} |
          {error, {reg_ids_out_of_sync, {list(), list(), list()}}}.
check_results([<<RegId/binary>>|RegIds], [Result|Results], Acc) ->
    NewAcc = [check_result(RegId, Result) | Acc],
    check_results(RegIds, Results, NewAcc);
check_results([], [], Acc) ->
    {ok, lists:reverse(Acc)};
check_results(RegIds, Results, Acc) ->
    RAcc = lists:reverse(Acc),
    _ = lager:error("No of reg IDs in req do not match resp~n"
                    "RegIds: ~p~nResults:~pAcc:~p", [RegIds, Results, RAcc]),
    {error, {reg_ids_out_of_sync, {RegIds, Results, RAcc}}}.

%%--------------------------------------------------------------------
%% JsonProps may contain <<"message_id">>, <<"registration_id">>, and
%% <<"error">>
check_result(BRegId, JsonProps) ->
    case {pv(<<"message_id">>, JsonProps), pv(<<"registration_id">>, JsonProps)} of
        {<<_MsgId/binary>>, <<CanonicalId/binary>>} ->
            {canonical_id, {old, BRegId}, {new, CanonicalId}};
        _ ->
            GCMError = pv(<<"error">>, JsonProps, <<>>),
            case gcm_error_to_atom(GCMError) of
                gcm_unknown_error ->
                    {unknown_error_for_reg_id, {BRegId, GCMError}};
                KnownError when is_atom(KnownError) ->
                    {KnownError, BRegId}
            end
    end.

%%--------------------------------------------------------------------
gcm_error_to_atom(<<"MissingRegistration">>)       -> gcm_missing_reg;
gcm_error_to_atom(<<"InvalidRegistration">>)       -> gcm_invalid_reg;
gcm_error_to_atom(<<"MismatchSenderId">>)          -> gcm_mismatched_sender;
gcm_error_to_atom(<<"NotRegistered">>)             -> gcm_not_registered;
gcm_error_to_atom(<<"MessageTooBig">>)             -> gcm_message_too_big;
gcm_error_to_atom(<<"InvalidDataKey">>)            -> gcm_invalid_data_key;
gcm_error_to_atom(<<"InvalidTtl">>)                -> gcm_invalid_ttl;
gcm_error_to_atom(<<"Unavailable">>)               -> gcm_unavailable;
gcm_error_to_atom(<<"InternalServerError">>)       -> gcm_internal_server_error;
gcm_error_to_atom(<<"InvalidPackageName">>)        -> gcm_invalid_package_name;
gcm_error_to_atom(<<"DeviceMessageRateExceeded">>) -> gcm_device_message_rate_exceeded;
gcm_error_to_atom(<<"TopicsMessageRateExceeded">>) -> gcm_topics_message_rate_exceeded;
gcm_error_to_atom(<<_/binary>>)                    -> gcm_unknown_error.

%%--------------------------------------------------------------------
%% @doc Implement exponential backoff algorithm when headers are
%% absent.
reschedule_req(Pid, State, #gcm_req{} = Request) ->
    reschedule_req(Pid, State, Request, []).

%%--------------------------------------------------------------------
%% @doc Implement exponential backoff algorithm, honoring any
%% Retry-After header.
reschedule_req(Pid, State, #gcm_req{} = Request, Headers) ->
    case calc_delay(State, Request, Headers) of
        {ok, WaitSecs} ->
            ReqId = Request#gcm_req.req_id,
            TriggerTime = sc_util:posix_time() + WaitSecs,
            NewReq = backoff_gcm_req(Request, WaitSecs),
            ok = gcm_req_sched:add(ReqId, TriggerTime, NewReq, Pid),
            do_cb(<<"rescheduled">>, Request),
            ok;
        Status ->
            _ = lager:error("Dropped notification because ~p:~n~p",
                            [Status, Request]),
            do_cb({error, Status}, Request),
            ok
    end.

%%--------------------------------------------------------------------
%% @doc Calculate exponential backoff
calc_delay(State, Request, Headers) ->
    RequestAge = request_age(Request),
    if
        RequestAge >= State#state.max_req_ttl ->
            max_age_exceeded;
        Request#gcm_req.num_attempts >= State#state.max_attempts ->
            max_attempts_exceeded;
        true ->
            {ok, calc_backoff_secs(State, Request, Headers)}
    end.

%%--------------------------------------------------------------------
calc_backoff_secs(State, Request, Headers) ->
    Secs = case retry_after_val(Headers) of
        Delay when Delay > 0 ->
            Delay;
        _ ->
            Request#gcm_req.backoff_secs * 2
    end,
    min(Secs, State#state.max_backoff_secs).

%%--------------------------------------------------------------------
retry_after_val(Headers) -> % headers come back in lowercase
    list_to_integer(pv("retry-after", Headers, "0")).

%%--------------------------------------------------------------------
request_age(#gcm_req{created_at = CreatedAt}) ->
    sc_util:posix_time() - CreatedAt.

%%--------------------------------------------------------------------
-spec try_make_gcm_req(NotifyPid, Notification, Opts, State,
                       NumAttempts) -> Result when
      NotifyPid :: pid(), Notification :: notification(),
      Opts :: list(), State :: state(), NumAttempts :: non_neg_integer(),
      Result :: {ok, gcm_req()} | {error, any()}.

try_make_gcm_req(NotifyPid, Notification, Opts, State, NumAttempts) ->
    try
        Req = make_gcm_req(NotifyPid, Notification, Opts, State, NumAttempts),
        {ok, Req}
    catch
        _:Error ->
            {error, Error}
    end.

%%--------------------------------------------------------------------
-spec make_gcm_req(NotifyPid, Notification, Opts, State,
                   NumAttempts) -> Result when
      NotifyPid :: pid(), Notification :: notification(),
      Opts :: list(), State :: state(), NumAttempts :: non_neg_integer(),
      Result :: gcm_req().

make_gcm_req(NotifyPid, Notification, Opts, State, NumAttempts) ->
    {HTTPOptions, ReqOptions} = make_req_options(NotifyPid,
                                                 State#state.ssl_opts),
    Headers = [
        {"Authorization", State#state.auth_value}
    ],
    Request = make_json_req(State#state.uri, Headers, Notification),
    {CbPid, Subscriptions} = make_notify_options(Opts),

    #gcm_req{
        req_id = undefined,
        cb_pid = CbPid,
        subscriptions = Subscriptions,
        req_data = Notification,
        http_req = Request,
        http_opts = HTTPOptions,
        httpc_opts = State#state.httpc_opts,
        req_opts = ReqOptions,
        created_at = sc_util:posix_time(),
        num_attempts = NumAttempts,
        backoff_secs = State#state.retry_interval
    }.

%%--------------------------------------------------------------------
-compile({inline, [{make_json_req, 3}]}).
-spec make_json_req(Url, Headers, Notification) -> Result when
      Url :: url(), Headers :: headers(),
      Notification :: notification(), Result :: httpc_request().

make_json_req(Url, Headers, Notification) ->
    ContentType = "application/json",
    Body = notification_to_json(Notification),
    {Url, Headers, ContentType, Body}.

%%--------------------------------------------------------------------
backoff_gcm_req(#gcm_req{num_attempts = Attempt} = R, NewBackoff) ->
    R#gcm_req{
        num_attempts = Attempt + 1,
        backoff_secs = NewBackoff
    }.

%%--------------------------------------------------------------------
-spec make_req_options(Pid, SSLOptions) -> Result when
      Pid :: pid(), SSLOptions :: list(), Result :: {HttpOptions, Options},
      HttpOptions :: list(), Options :: list().

make_req_options(Pid, []) ->
    SSLOptions = [
        {verify, verify_none}, % TODO: Figure out why {verify, verify_peer} fails to connect to GCM.
        {reuse_sessions, true}
    ],
    make_req_options(Pid, SSLOptions);

%%--------------------------------------------------------------------
make_req_options(Pid, SSLOptions) ->
    HTTPOptions = [
        {timeout, 10000},
        {connect_timeout, 5000},
        {ssl, SSLOptions}
    ],
    Options = [
        {sync, false}, % async requests
        {receiver, Pid} % result calls handle_info({http, ReplyInfo}, ...)
    ],
    {HTTPOptions, Options}.

%%--------------------------------------------------------------------
-spec make_notify_options(Opts) -> Result when
      Opts :: [proplists:property()],
      Result :: {NotifyPid, NotifyTypes},
      NotifyPid :: undefined | pid(),
      NotifyTypes :: undefined | [subscription()].
make_notify_options(Opts) ->
    case proplists:get_value(callback, Opts) of
        {Pid, Types} when is_pid(Pid), is_list(Types) ->
            ?assert(lists:all(fun(T) -> T =:= progress orelse T =:= completion
                              end, Types)),
            {Pid, Types};
        undefined ->
            {undefined, undefined}
    end.

%%--------------------------------------------------------------------
-spec notification_to_json(Notification) -> Result when
      Notification :: notification(), Result :: binary().
notification_to_json(Notification) ->
    gcm_json:make_notification(Notification).

%%--------------------------------------------------------------------
do_cb(_Msg, #gcm_req{cb_pid = undefined}) ->
    ok;
do_cb(_Msg, #gcm_req{cb_pid = Pid, subscriptions = []}) when is_pid(Pid) ->
    ok;
do_cb(Msg, #gcm_req{cb_pid = Pid,
                    subscriptions = Ts} = R) when is_pid(Pid), is_list(Ts) ->
    StatusType = stype(Msg),

    case lists:member(StatusType, Ts) of
        true ->
            Pid ! {gcm_erl, StatusType, R#gcm_req.req_id, Msg},
            ok;
        false ->
            ok
    end.


%%--------------------------------------------------------------------
-spec stype('ok' | {'error', any()} | binary()) -> subscription().

stype(ok)                -> completion;
stype({error, _})        -> completion;
stype(<<_/binary>>)      -> progress.

%% vim: ts=4 sts=4 sw=4 et tw=68

