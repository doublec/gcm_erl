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
%%% @copyright 2015, 2016 Silent Circle
%%% @doc GCM server session.
%%%
%%% There must be one session per API key and sessions must have unique (i.e.
%%% they are registered) names within the node.
%%%
%%% == Request ==
%%%
%%% ```
%%% Nf = [{id, sc_util:to_bin(RegId)},
%%%       {data, [{alert, sc_util:to_bin(Msg)}]}],
%%% {ok, Res} = gcm_erl_session:send('gcm-com.example.MyApp', Nf).
%%% '''
%%%
%%% Note that the above notification is semantically identical to
%%%
%%% ```
%%% Nf = [{registration_ids, [sc_util:to_bin(RegId)]},
%%%       {data, [{alert, sc_util:to_bin(Msg)]}].
%%% '''
%%%
%%% === DEPRECATED until future enhancement ===
%%%
%%% It follows that you should be able to send to multiple registration ids,
%%% as shown below, but this functionality is not working correctly yet.
%%% The notification will be sent, but the session will crash (deliberately)
%%% with an internal error.
%%%
%%% Consider this future functionality until it is fixed and this notice is
%%% removed.
%%%
%%% ```
%%% BRegIds = [sc_util:to_bin(RegId) || RegId <- RegIds],
%%% Nf = [{registration_ids, BRegIds},
%%%       {data, [{alert, sc_util:to_bin(Msg)}]}
%%% ],
%%% Rsps = gcm_erl_session:send('gcm-com.example.MyApp', Nf).
%%% '''
%%%
%%% === JSON ===
%%%
%%% This is an example of the JSON sent to GCM:
%%%
%%% ```
%%% {
%%%   "to": "dQMPBffffff:APA91bbeeff...8yC19k7ULYDa9X",
%%%   "priority": "high",
%%%   "collapse_key": "true",
%%%   "data": {"alert": "Some text"}
%%% }
%%% '''
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(gcm_erl_session).

-behaviour(gen_server).

-export([start/2,
         start_link/2,
         stop/1,
         send/2,
         send/3,
         async_send/2,
         async_send/3,
         async_send_cb/5,
         sync_send_callback/3,
         async_send_callback/3,
         get_state/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

%% internal
-export([sync_reply/3,
         async_reply/3]).

-export_type([opt/0,
              start_opts/0]).

-include_lib("lager/include/lager.hrl").
-include("gcm_erl_internal.hrl").

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

%%--------------------------------------------------------------------
-type field() :: string().
-type value() :: string().
-type header() :: {field(), value()}.
-type url() :: string().
-type headers() :: [header()].
-type http_version() :: string().
-type http_status_code() :: pos_integer().
-type http_reason_phrase() :: string().
-type content_type() :: string().
-type body() :: string() | binary(). % We won't be using the fun or chunkify
                                     % parts

%% We are using POSTs only, so need the content_type() and body().
-type httpc_request() :: {url(), headers(), content_type(), body()}.
-type httpc_status_line() :: {http_version(), http_status_code(),
                              http_reason_phrase()}.
-type notification() :: gcm_json:notification().
-type terminate_reason() :: normal |
                            shutdown |
                            {shutdown, term()} |
                            term().
-type ssloptions() :: [ssl:ssloption()].
-type proplist() :: proplists:proplist().
-type http_opts() :: proplist().  % httpc:set_options/1.
-type httpc_opts() :: proplist(). % httpc:request/5 http_options().
-type req_opts() :: proplist(). % httpc:request/5 options().
-type req_mode() :: sync | async.

-type callback() :: fun((NfPL   :: proplist(),
                         Req    :: proplist(),
                         Result :: proplist()) -> any()).
-type bstring() :: binary().
-type uuid() :: uuid:uuid().
-type uuid_str() :: bstring().
-type json() :: bstring().
-type ejson() :: gcm_json:json_term().
-type gcm_error() :: gcm_missing_reg
                   | gcm_invalid_reg
                   | gcm_mismatched_sender
                   | gcm_not_registered
                   | gcm_message_too_big
                   | gcm_invalid_data_key
                   | gcm_invalid_ttl
                   | gcm_unavailable
                   | gcm_internal_server_error
                   | gcm_invalid_package_name
                   | gcm_device_msg_rate_exceeded
                   | gcm_topics_msg_rate_exceeded
                   | gcm_unknown_error.

-type gcm_error_string() :: bstring().

-type reg_id() :: bstring().
-type reg_ids() :: [reg_id()].
-type gcm_msg_id() :: bstring().
-type canonical_id() :: reg_id().
-type canonical_id_change() :: {canonical_id,
                                {old, reg_id(), new, reg_id()}}.
-type gcm_success_result() :: {success, reg_id()}.
-type gcm_error_result() :: {gcm_error(), reg_id()}
                          | {unknown_error_for_reg_id, {reg_id(),
                                                        gcm_error_string()}}.
-type checked_result() :: canonical_id_change()
                        | gcm_success_result()
                        | gcm_error_result().

-type checked_results() :: [checked_result()].

-type ejson_dict(T) :: [T].

-type message_id_key() :: bstring().
-type error_key() :: bstring().
-type success_key() :: bstring().
-type failure_key() :: bstring().
-type canonical_ids_key() :: bstring().
-type results_key() :: bstring().
-type multicast_id_key() :: bstring().
-type registration_id_key() :: bstring().

-type gcm_result() :: {message_id_key(), gcm_msg_id()} |
                      {registration_id_key(), canonical_id()} |
                      {error_key(), gcm_error_string()}.

-type gcm_results() :: ejson_dict(gcm_result()).

-type gcm_ejson_prop() :: {multicast_id_key(), integer()}
                        | {success_key(), non_neg_integer()}
                        | {failure_key(), non_neg_integer()}
                        | {canonical_ids_key(), non_neg_integer()}
                        | {results_key(), gcm_results()}.

-type gcm_ejson_response() :: ejson_dict(gcm_ejson_prop()).

%%--------------------------------------------------------------------
-record(gcm_req, {
          req_id       = undefined               :: undefined | reference(),
          uuid         = <<>>                    :: uuid(),
          mode         = async                   :: req_mode(),
          from         = undefined               :: {pid(), term()},
          cb_pid       = undefined               :: undefined | pid(),
          callback     = undefined               :: undefined | callback(),
          req_data     = []                      :: notification(),
          http_req     = []                      :: httpc_request(),
          headers      = []                      :: headers(),
          http_opts    = []                      :: http_opts(),
          httpc_opts   = []                      :: httpc_opts(),
          req_opts     = []                      :: req_opts(),
          num_attempts = 0                       :: non_neg_integer(),
          created_at   = 0                       :: pos_integer(),
          backoff_secs = ?DEFAULT_RETRY_INTERVAL :: non_neg_integer()
         }).

-type gcm_req() :: #gcm_req{}.

-define(S, ?MODULE).

-record(?S, {
          name                    = undefined                 :: atom(),
          uri                     = ?DEFAULT_GCM_URI          :: string(),
          api_key                 = <<>>                      :: binary(),
          auth_value              = "key="                    :: string(),
          restricted_package_name = <<>>                      :: binary(),
          max_attempts            = ?DEFAULT_MAX_ATTEMPTS     :: pos_integer(),
          retry_interval          = ?DEFAULT_RETRY_INTERVAL   :: pos_integer(),
          max_req_ttl             = ?DEFAULT_MAX_REQ_TTL      :: pos_integer(),
          max_backoff_secs        = ?DEFAULT_MAX_BACKOFF_SECS :: pos_integer(),
          ssl_opts                = []                        :: list(),
          httpc_opts              = []                        :: list()
         }).

-type state() :: #?S{}.

%%--------------------------------------------------------------------
%% <dl>
%%   <dt>`mode'</dt>
%%      <dd>`sync' or `async'.</dd>
%%   <dt>`nf'</dt>
%%     <dd>A notification as per gcm_json:make_notification/1.</dd>
%%   <dt>`opts'</dt>
%%     <dd>Options as described in {@link send/3}.</dd>
%%   <dt>`from'</dt>
%%     <dd>The internal `pid' to which to send the raw HTTP reply.</dd>
%%   <dt>`cb_pid'</dt>
%%     <dd>The `pid' to which the callback function sends data.</dd>
%%   <dt>`callback'</dt>
%%     <dd>A callback function that is invoked when the notification
%%     processing completes.</dd>
%% </dl>
%%--------------------------------------------------------------------
-record(send_req, {
          mode      = async,
          nf        = [],
          opts      = [],
          cb_pid    = undefined,
          callback  = undefined}).

-type send_req() :: #send_req{}.

%%%===================================================================
%%% API
%%%===================================================================
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
%% @equiv send(SvrRef, Nf, [])
%% @end
%%--------------------------------------------------------------------
-spec send(SvrRef, Nf) -> Result when
      SvrRef :: term(), Nf :: notification(),
      Result :: {ok, {UUID, Response}} | {error, Reason},
      UUID :: uuid(), Response :: term(), Reason :: term().
send(SvrRef, Nf) when is_list(Nf) ->
    send(SvrRef, Nf, []).

%%--------------------------------------------------------------------
%% @doc Synchronously send a notification specified by `Nf' via `SvrRef', with
%% options `Opts'. `SvrRef' can be the session name atom, a pid, or any other
%% valid `gen_server' destination.
%%
%% == Opts ==
%%
%% <dl>
%%  <dt>`http_headers :: [{string(), string()}]'</dt>
%%  <dd>Extra HTTP headers to include with a request. These will be merged
%%  with any internally-generated headers, and will override internally
%%  generated headers, so caution is advised. Avoiding the `Authorization'
%%  header is recommended. Currently only used for testing with the GCM
%%  simulator.</dd>
%% </dl>
%%
%% == Caveats ==
%%
%% Note that sending a notification synchronously is not recommended, because
%% the duration of the call is unpredictable. The call may time out, leaving the
%% status of the notification in doubt. Timeouts can occur for a number of
%% reasons, such as the need for this session to retry sending the notification
%% to GCM.
%%
%% It is better to use the asynchronous interface and handle the responses
%% sent to the mailbox of the calling process, or provide a user-defined
%% callback function. The callback function is spawned into its own process.
%%
%% == More information ==
%%
%% For JSON format and other information, see <a
%% href="https://developers.google.com/cloud-messaging/http-server-ref"> GCM
%% Connection Server Reference</a>.
%%
%% @see async_send/3.
%% @see gcm_json:make_notification/1.
%% @see gcm_json:notification/0.
%% @end
%%--------------------------------------------------------------------
-spec send(SvrRef, Nf, Opts) -> Result when
      SvrRef :: term(), Nf :: notification(), Opts :: list(),
      Result :: {ok, {UUID, Response}} | {error, Reason},
      UUID :: uuid(), Response :: term(), Reason :: term().
send(SvrRef, Nf, Opts) when is_list(Nf), is_list(Opts) ->
    Req = #send_req{mode      = sync,
                    nf        = Nf,
                    opts      = Opts,
                    cb_pid    = self(),
                    callback  = fun sync_send_callback/3},
    gen_server:call(SvrRef, Req).

%%--------------------------------------------------------------------
%% @equiv async_send(SvrRef, Nf, [])
%% @end
%%--------------------------------------------------------------------
-spec async_send(SvrRef, Nf) -> Result when
      SvrRef :: term(), Nf :: notification(),
      Result :: {ok, {submitted, UUID}} | {error, Reason},
      UUID :: uuid(), Reason :: term().
async_send(SvrRef, Nf) when is_list(Nf) ->
    async_send(SvrRef, Nf, []).

%%--------------------------------------------------------------------
%% @doc Asynchronously send a notification specified by
%% `Nf' via `SvrRef', with options `Opts'.
%%
%% The immediate response will be either `{ok, {submitted, UUID}}', or
%% `{error, term()}'. `UUID' is either generated for the caller, or is the
%% value of the property `{uuid, UUID}' if present in the notification
%% property list.
%%
%% Note that the UUID must be a binary in standard UUID string format, e.g.
%% `d611dcf3-bd70-453d-9fdd-94bc66cea7f7'. It is converted internally to
%% a 128-bit binary on both storage and lookup, so it is case-insensitive.
%%
%% @equiv async_send_cb(SvrRef, Nf, Opts, self(), fun async_send_callback/3)
%% @end
%%--------------------------------------------------------------------
-spec async_send(SvrRef, Nf, Opts) -> Result when
      SvrRef :: term(), Nf :: notification(), Opts :: list(),
      Result :: {ok, {submitted, UUID}} | {error, Reason},
      UUID :: uuid(), Reason :: term().
async_send(SvrRef, Nf, Opts) when is_list(Nf), is_list(Opts) ->
    async_send_cb(SvrRef, Nf, Opts, self(), fun async_send_callback/3).

%%--------------------------------------------------------------------
%% @doc Asynchronously send a notification specified by
%% `Nf' via `SvrRef' with options `Opts'. Respond immediately with the status of
%% the call, and when the call completes asynchronously, run the callback
%% function `Cb' and send the response `Resp' to `ReplyPid'.
%%
%% == Parameters ==
%%
%% <dl>
%%  <dt>`Nf'</dt>
%%   <dd>The notification proplist.</dd>
%%  <dt>`ReplyPid'</dt>
%%   <dd>A `pid' to which asynchronous responses are to be sent.</dd>
%%  <dt>`Cb'</dt>
%%   <dd>A function to be called when the asynchronous operation is complete.
%%   Its function spec is
%%
%%   ```
%%   -spec callback(NfPL, Req, Resp) -> any() when
%%         NfPL :: proplists:proplist(), % Nf proplist
%%         Req  :: proplists:proplist(), % Request data
%%         Resp :: {ok, ParsedResp} | {error, term()},
%%         ParsedResp :: proplists:proplist().
%%   '''
%%  </dd>
%% </dl>
%% @end
%%--------------------------------------------------------------------
async_send_cb(SvrRef, Nf, Opts, ReplyPid, Cb) when is_list(Nf),
                                                   is_list(Opts),
                                                   is_pid(ReplyPid),
                                                   is_function(Cb, 3) ->
    Req = #send_req{mode      = async,
                    nf        = Nf,
                    opts      = Opts,
                    cb_pid    = ReplyPid,
                    callback  = Cb},
    gen_server:call(SvrRef, Req).

%%--------------------------------------------------------------------
%% @doc Callback function to simulate a synchronous send. This is the
%% callback function used by send/3.
%% @end
%%--------------------------------------------------------------------
sync_send_callback(NfPL, Req, Resp) ->
    gen_send_callback(fun sync_reply/3, NfPL, Req, Resp).

%%--------------------------------------------------------------------
%% @doc Standard callback function for an asynchronous send. This is
%% the callback function used by async_send/3.
%% @end
%%--------------------------------------------------------------------
async_send_callback(NfPL, Req, Resp) ->
    gen_send_callback(fun async_reply/3, NfPL, Req, Resp).

%%--------------------------------------------------------------------
%% @private
get_state(SvrRef) ->
    gen_server:call(SvrRef, get_state).

%%--------------------------------------------------------------------
%% @private
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
%% @doc Handle call messages.
%%
%% @end
%%--------------------------------------------------------------------
-type call_req_type() :: {send, notification(), list(), pid(), function()}
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

handle_call(#send_req{mode=Mode, nf=Nf, callback=Callback}=SR, From,
            #?S{uri=URI}=St) when is_function(Callback, 3) andalso
                                  (Mode == sync orelse Mode == async) ->
    _ = ?LOG_DEBUG("~p send to ~s: ~p", [Mode, URI, Nf]),
    case {Mode, do_send(SR, From, St)} of
        {sync, {ok, {submitted, _UUID}}} ->
            {noreply, St};
        {async, {ok, {submitted, _UUID}}=Reply} ->
            {reply, Reply, St};
        {_, {error, _Reason}=Error} ->
            {reply, Error, St}
    end;
handle_call(get_state, _From, St) ->
    Reply = St,
    {reply, Reply, St};
handle_call(_Msg, _From, St) ->
    _ = ?LOG_NOTICE("Got unexpected handle_call msg ~p", [_Msg]),
    Reply = {error, invalid_call},
    {reply, Reply, St}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%% @end
%%--------------------------------------------------------------------
-spec handle_cast(Request::call_req_type(),
                  St::term()) ->
    {noreply, NewSt::term()} |
    {noreply, NewSt::term(), 'hibernate'} |
    {noreply, NewSt::term(), Timeout::timeout()} |
    {stop, Reason::term(), NewSt::term()}
    .

handle_cast({reschedule, #gcm_req{} = Req, Hdrs}, St) when is_list(Hdrs) ->
    reschedule_req(self(), backoff_params(St), Req, Hdrs),
    {noreply, St};
handle_cast(stop, St) ->
    {stop, stopped_by_api, St};
handle_cast(_Msg, St) ->
    _ = ?LOG_NOTICE("Got unexpected handle_cast msg ~p", [_Msg]),
    {noreply, St}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%% @end
%%--------------------------------------------------------------------
-spec handle_info(Request::term(),
                  St::term()) ->
    {noreply, NewSt::term()} |
    {noreply, NewSt::term(), 'hibernate'} |
    {noreply, NewSt::term(), Timeout::timeout()} |
    {stop, Reason::term(), NewSt::term()}
    .

handle_info({http, {RequestId, {error, Reason}=Err}}, St) ->
    Req = retrieve_req(RequestId),
    _ = ?LOG_DEBUG("Got http error resp, req: ~p, error: ~p, reqid: ~p",
                   [pp(Req), Err, RequestId]),
    do_cb(Err, Req),
    _ = ?LOG_WARNING("HTTP error; rescheduling request~n"
                     "Reason: ~p~nRequest ID: ~p~nRequest:~p",
                     [Reason, RequestId, pp(sanitize_req(Req))]),
    reschedule_req(self(), backoff_params(St), Req),
    {noreply, St};
handle_info({http, {ReqId, Result}}, St) ->
    _ = case retrieve_req(ReqId) of
            #gcm_req{} = Req ->
                ?LOG_DEBUG("Got http resp for req ~p: ~p", [pp(Req), Result]),
                Msg = handle_gcm_result(self(), Req, Result,
                                        backoff_params(St)),
                do_cb(Msg, Req);
            undefined ->
                _ = ?LOG_ERROR("Req ID ~p not found, http response: ~p",
                               [ReqId, Result])
        end,
    {noreply, St};
%% Handle trigger notification received from request scheduler. This is needed
%% for rescheduled notifications after backing off.  Call is set up by
%% gcm_req_sched:add(ReqId, TriggerTime, NewReq, Pid).
handle_info({triggered, {_ReqId, GCMReq}}, #?S{uri = URI} = St) ->
    _ = ?LOG_DEBUG("Triggered ~s to resend ~p",
                   [uuid_to_str(GCMReq#gcm_req.uuid), pp(GCMReq)]),
    dispatch_req(GCMReq, St#?S.httpc_opts, URI),
    {noreply, St};
handle_info(_Info, St) ->
    _ = ?LOG_NOTICE("Got unexpected handle_info msg ~p", [_Info]),
    {noreply, St}.

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
                St::term()) -> no_return().
terminate(_Reason, _St) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @end
%%--------------------------------------------------------------------
-spec code_change(OldVsn::term() | {down, term()},
                  St::term(),
                  Extra::term()) ->
    {ok, NewSt::term()} |
    {error, Reason::term()}.
code_change(_OldVsn, St, _Extra) ->
    {ok, St}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

validate_args(Name, Opts) ->
    SslOpts = ?assertList(pv_req(ssl_opts, Opts)),
    HttpcOpts = ?assertList(pv(httpc_opts, Opts, [])),
    ApiKey = ?assertBinary(pv_req(api_key, Opts)),

    #?S{
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
%% @private
%% @doc
%%
%% The HTTP request is sent asynchronously, and the request ID is added
%% to the push request manager for tracking.
%% The response is dealt with in handle_info({http, _}, State).
%%
%% An example of a populated gcm_req record follows.
%%
%% == Example gcm_req record ==
%%
%% ```
%% #gcm_req{req_id = SomeRef,
%%          uuid = <<_:128>>,
%%          mode = async,
%%          cb_pid = SomePid,
%%          callback = SomeFun,
%%          req_data = [{token,<<"<redacted>">>},
%%                      {alert,<<"Please register">>},
%%                      {gcm,[{priority,<<"high">>},
%%                            {collapse_key,<<"true">>}]},
%%                      {receivers,[{svc_appid_tok,
%%                                  [{gcm,<<"com.example.MyApp">>,
%%                                   <<"<redacted>">>}]}]},
%%                      {id,<<"<redacted>">>},
%%                      {data,[{<<"alert">>,<<"Please register">>}]}],
%%          http_req = {"https://gcm-http.googleapis.com/gcm/send",
%%                      [{"Authorization", "key=<redacted>"}],
%%                      "application/json",
%%                      <<"{\"to\":\"<redacted>\","
%%                        "\"data\":{\"alert\":\"Please register\"},"
%%                        "\"priority\":\"high\","
%%                        "\"collapse_key\":\"true\"}">>},
%%          headers = [],
%%          http_opts = [{timeout,10000},
%%                       {connect_timeout,5000},
%%                       {ssl,[{verify,verify_none}]}],
%%          httpc_opts = [],
%%          req_opts = [{sync,false},{receiver, SomePid}],
%%          num_attempts = 1,
%%          created_at = 1477078258,
%%          backoff_secs = 1}
%% '''
%% @end
%%--------------------------------------------------------------------
dispatch_req(#gcm_req{uuid      = UUID,
                      http_req  = Request,
                      http_opts = HTTPOpts,
                      req_opts  = ReqOpts
                     }=GCMReq, HTTPCOpts, URI) when is_binary(UUID),
                                                    bit_size(UUID) == 128 ->

    _ = ?LOG_DEBUG("dispatch_req(req: ~p, httpcopts: ~p, uri: ~p)",
                   [pp(GCMReq), HTTPCOpts, URI]),
    ok = httpc:set_options(HTTPCOpts),
    ?LOG_DEBUG("httpc:set_options(~p)", [HTTPCOpts]),
    try httpc:request(post, Request, HTTPOpts, ReqOpts) of
        {ok, RequestId} when is_reference(RequestId) ->
            sc_push_req_mgr:add(RequestId,
                                GCMReq#gcm_req{req_id=RequestId}),
            _ = ?LOG_INFO("Queued POST (uuid: ~p, req id: ~p) to ~s",
                          [uuid_to_str(UUID), RequestId, URI]),
            {ok, {submitted, UUID}};
        Error ->
            _ = ?LOG_ERROR("POST error to ~s:~n~p", [URI, Error]),
            Error
    catch
        Class:Reason ->
            _ = ?LOG_ERROR("POST failed to ~s~nStack trace:~s",
                           [URI, ?STACKTRACE(Class, Reason)]),
            {error, Reason}
    end.

%%--------------------------------------------------------------------
do_send(#send_req{}=Req, From, #?S{}=St) ->
    case try_make_gcm_req(Req, From, 1, St) of
        {ok, GR} ->
            dispatch_req(GR, St#?S.httpc_opts, St#?S.uri);
        {error, Reason} = Error ->
            _ = ?LOG_ERROR("Bad GCM notification: ~p, error: ~p",
                           [Req#send_req.nf, Reason]),
            Error
    end.

%%--------------------------------------------------------------------
retrieve_req(RequestId) ->
    case sc_push_req_mgr:remove(RequestId) of
        [{_,_}|_] = PL -> pv(req, PL);
        undefined      -> undefined
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
handle_gcm_result(SvrRef, Req, Result, BackoffParams) ->
    UUID = Req#gcm_req.uuid,
    case process_gcm_result(Req, Result) of
        {{success, {_UUID, _Props}=Success}, _Hdrs} ->
            {ok, Success};
        {{results, CheckedResults}, Hdrs} ->
            process_checked_results(SvrRef, Req, Hdrs, Result, CheckedResults);
        {reschedule, {Hdrs, _StatusDesc}} ->
            ok = reschedule_req(SvrRef, BackoffParams, Req, Hdrs),
            case get_reg_ids(Req#gcm_req.req_data) of
                [_|_] = RegIds -> % Trying for API consistency here
                    Failed = [{gcm_unavailable, Id} || Id <- RegIds],
                    {error, {UUID, {failed, Failed, rescheduled, RegIds}}};
                {error, Reason} ->
                    {error, {UUID, Reason}}
            end;
        {error, {<<UUID/binary>>, Reason}}=Err ->
            _ = ?LOG_ERROR("Bad HTTP Result, uuid: ~p, reason: ~p, req=~p, "
                           "result=~p",
                           [uuid_to_str(UUID), Reason, Req, Result]),
            Err;
        {error, Reason} ->
            _ = ?LOG_ERROR("Bad HTTP Result, reason: ~p, req=~p, result=~p",
                           [Reason, Req, Result]),
            {error, {UUID, Reason}};
        {{error, Reason}, _Hdrs} ->
            _ = ?LOG_ERROR("Bad GCM Result, reason: ~p; req=~p, result=~p",
                           [Reason, Req, Result]),
            {error, {UUID, Reason}}
    end.

%%--------------------------------------------------------------------
-spec process_gcm_result(Req, {StatusLine, Headers, Resp}) -> Result when
      Req :: gcm_req(), StatusLine :: httpc_status_line(),
      Headers :: headers(), Resp :: binary(),
      Result :: {{success, {UUID, Props}, Headers}}
              | {{results, CheckedResults}, Headers}
              | {reschedule, {Headers, StatusDesc}}
              | {error, ErrorInfo}
              ,
       ErrorInfo :: missing_id_and_registration_ids
                  | no_results_received
                  | {bad_json, Resp, reason, Reason}
                  | {UUID, Props}
                  | {reg_ids_out_of_sync, {RegIds, GCMResults, CheckedResults}}
                  ,
       UUID :: uuid(), RegIds :: reg_ids(), GCMResults :: gcm_results(),
       CheckedResults :: checked_results(), StatusDesc :: bstring(),
       Props :: proplists:proplist(), Reason :: term().

process_gcm_result(#gcm_req{}=Req, {StatusLine, Headers, Resp}) ->
    {HTTPVersion, StatusCode, ReasonPhrase} = StatusLine,
    GCMResult = #{request => Req,
                  http_version => HTTPVersion,
                  status_code => StatusCode,
                  reason_phrase => ReasonPhrase,
                  headers => Headers,
                  response => Resp},
    _ = ?LOG_DEBUG("process_gcm_result(~p)", [GCMResult]),
    process_gcm_result(GCMResult).

%%--------------------------------------------------------------------
-spec process_gcm_result(GcmResult) -> Result when
      GcmResult :: map(), Result :: {{success, {UUID, Props}, Headers}}
                                  | {{results, CheckedResults}, Headers}
                                  | {reschedule, {Headers, StatusDesc}}
                                  | {error, ErrorInfo}
                                  ,
      ErrorInfo :: missing_id_and_registration_ids
                 | no_results_received
                 | {bad_json, Resp, reason, Reason}
                 | {UUID, Props}
                 | {reg_ids_out_of_sync, {RegIds, GCMResults, CheckedResults}}
                 ,
      Resp :: binary(), UUID :: uuid(), RegIds :: reg_ids(),
      GCMResults :: gcm_results(), CheckedResults :: checked_results(),
      StatusDesc :: bstring(), Props :: proplists:proplist(),
      Reason :: term().
process_gcm_result(#{status_code := 200, request := Req, response := Resp,
                     headers := Headers}) ->
    CheckedRes = check_json_resp(Req, Resp),
    Chk = map_checked_res(CheckedRes, 200, Req#gcm_req.uuid, Resp),
    _ = ?LOG_DEBUG("HTTP 200, chk: ~p, req: ~p, resp: ~p",
                   [Chk, Req, Resp]),
    {Chk, Headers};
process_gcm_result(#{status_code := 400, request := Req, response := Resp,
                     reason_phrase := ReasonPhrase}) ->
    UUID = Req#gcm_req.uuid,
    _ = ?LOG_ERROR("Bad GCM request, reason: ~s~nReq: ~p",
                   [ReasonPhrase, Req]),
    Props = parsed_resp(400, <<"BadRequest">>,
                        ReasonPhrase, UUID, Resp),
    {error, {UUID, Props}};
process_gcm_result(#{status_code := 401, request := Req, response := Resp,
                     reason_phrase := ReasonPhrase}) ->
    _ = ?LOG_ERROR("GCM Req auth failed, reason: ~s~n~p",
                   [ReasonPhrase, Req]),
    UUID = Req#gcm_req.uuid,
    Props = parsed_resp(401, <<"AuthenticationFailure">>,
                        ReasonPhrase, UUID, Resp),
    {error, {UUID, Props}};
process_gcm_result(#{status_code := SC, headers := Headers}) when SC >= 500 ->
    StatusDesc = status_desc(SC),
    {reschedule, {Headers, StatusDesc}};
process_gcm_result(#{status_code := SC, request := Req, response := Resp,
                     reason_phrase := ReasonPhrase}) ->
    _ = ?LOG_ERROR("Unhandled status code: ~p, reason: ~s~nreq: ~p",
                   [SC, ReasonPhrase, Req]),
    UUID = Req#gcm_req.uuid,
    Props = parsed_resp(SC, <<"Unknown">>, ReasonPhrase, UUID, Resp),
    {error, {UUID, Props}}.

%%--------------------------------------------------------------------
-spec map_checked_res(CheckedRes, Status, UUID, Resp) -> Result when
      CheckedRes :: ok | term(), Status:: pos_integer(),
      UUID :: uuid(), Resp :: binary(),
      Result :: {success, {UUID, Props}} | term(),
      Props :: proplists:proplist().
map_checked_res(ok, Status, UUID, Resp) ->
    Props = parsed_resp(Status, UUID, Resp),
    {success, {UUID, Props}};
map_checked_res(CheckedRes, _Status, _UUID, _Resp) ->
    CheckedRes.

%%--------------------------------------------------------------------
process_checked_results(_SvrRef, Req, _Hdrs, Result,
                        [{canonical_id, _}=Res]) ->
    {canonical_id, {old, <<BRegId/binary>>,
                    new, <<CanonicalId/binary>>}} = Res,
    _ = ?LOG_INFO("Changing old GCM reg id ~p to new ~p",
                  [BRegId, CanonicalId]),
    OldSvcTok = sc_push_reg_api:make_svc_tok(gcm, BRegId),
    ok = sc_push_reg_api:reregister_svc_tok(OldSvcTok, CanonicalId),
    UUID = Req#gcm_req.uuid,
    {_StatusLine, _Hdrs, Resp} = Result,
    Props = parsed_resp(200, undefined, undefined, UUID, Resp),
    {ok, {UUID, Props}};
process_checked_results(SvrRef, Req, Hdrs, Result, [Res]) ->
    UUID = Req#gcm_req.uuid,
    PErrors = process_errors(Req, [Res]),
    case maybe_reschedule(SvrRef, Req, Hdrs, PErrors) of
        [] -> % No rescheds, all errors
            {_StatusLine, _Hdrs, Resp} = Result,
            {error, {UUID, errors_to_props(PErrors, Resp, UUID)}};
        RegIds ->
            {error, {UUID, {failed, PErrors, rescheduled, RegIds}}}
    end;
process_checked_results(_SvrRef, _Req, _Hdrs, _Result, CheckedResults) ->
    throw({internal_error,
           {cannot_process_multiple_results, CheckedResults}}).

%%--------------------------------------------------------------------
-spec process_errors(Req, ErrorList) -> Result when
      Req :: gcm_req(), ErrorList :: checked_results(),
      Result :: [{gcm_error(), reg_id()}].
process_errors(#gcm_req{} = Req, ErrorList) ->
    SReq = sanitize_req(Req),
    [process_error(SReq, Error) || Error <- ErrorList].

%%--------------------------------------------------------------------
%% Some of the errors require a reschedule of only those registration IDs that
%% failed temporarily, e.g. "Unavailable" error.
%% This returns a list of failed registration ids that will be rescheduled.
-spec maybe_reschedule(Pid, Req, Headers, ErrorResults) -> ReschedIds when
      Pid :: pid(), Req :: gcm_req(), Headers :: headers(),
      ErrorResults :: [{gcm_error(), reg_id()}],
      ReschedIds :: [reg_id()].

maybe_reschedule(Pid, Req, Headers, ErrorResults) ->
    case get_reschedulable_regids(ErrorResults) of
        [] ->
            [];
        FailedRegIds ->
            NewReq = replace_regids(Req, FailedRegIds),
            async_resched(Pid, NewReq, Headers),
            FailedRegIds
    end.

%%--------------------------------------------------------------------
get_reschedulable_regids(ErrorResults) ->
    [BRegId || {_, BRegId}=Err <- ErrorResults,
               is_reschedulable_regid(Err)].

%%--------------------------------------------------------------------
is_reschedulable_regid({gcm_unavailable, _BRegId}) -> true;
is_reschedulable_regid({gcm_internal_server_error, _BRegId}) -> true;
is_reschedulable_regid({gcm_device_msg_rate_exceeded, _BRegId}) -> true;
is_reschedulable_regid({gcm_topics_msg_rate_exceeded, _BRegId}) -> true;
is_reschedulable_regid(_) -> false.

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
-spec process_error(Req, CheckedResult) -> Result when
      Req :: gcm_req(), CheckedResult :: checked_result(),
      Result :: gcm_error() | {gcm_error(), reg_id()}.
process_error(Req, {gcm_missing_reg, _BRegId}) ->
    ?LOG_ERROR("Req missing registration ID: ~p", [pp(Req)]),
    {gcm_missing_reg, <<>>};
process_error(_Req, {gcm_invalid_reg, BRegId}=Err) ->
    SvcTok = sc_push_reg_api:make_svc_tok(gcm, BRegId),
    ok = sc_push_reg_api:deregister_svc_tok(SvcTok),
    ?LOG_INFO("Deregistered invalid registration ID ~p", [BRegId]),
    Err;
process_error(_Req, {gcm_mismatched_sender, BRegId}=Err) ->
    ?LOG_ERROR("Mismatched Sender for registration ID ~p", [BRegId]),
    Err;
process_error(Req, {gcm_not_registered, BRegId}=Err) ->
    _ = ?SENTRY_WARNING("Unregistered registration ID ~s", [BRegId]),
    _ = ?LOG_ERROR("Unregistered registration ID ~s in req ~p",
                   [BRegId, pp(Req)]),
    SvcTok = sc_push_reg_api:make_svc_tok(gcm, BRegId),
    ok = sc_push_reg_api:deregister_svc_tok(SvcTok),
    Err;
process_error(Req, {gcm_message_too_big, _BRegId}=Err) ->
    ?LOG_ERROR("Message too big, req ~p", [pp(Req)]),
    Err;
process_error(Req, {gcm_invalid_data_key, _BRegId}=Err) ->
    ?LOG_ERROR("Invalid data key in req: ~p", [pp(Req)]),
    Err;
process_error(Req, {gcm_invalid_ttl, _BRegId}=Err) ->
    ?LOG_ERROR("Invalid TTL in req: ~p", [pp(Req)]),
    Err;
process_error(Req, {gcm_unavailable, BRegId}=Err) ->
    ?LOG_WARNING("GCM timeout error for reg id ~p in req ~p", [BRegId, Req]),
    Err;
process_error(Req, {gcm_internal_server_error, BRegId}=Err) ->
    ?LOG_WARNING("GCM internal server error for reg id ~p in req ~p",
                 [BRegId, Req]),
    Err;
process_error(Req, {gcm_invalid_package_name, _BRegId}=Err) ->
    ?LOG_ERROR("Invalid package name in req ~p", [pp(Req)]),
    Err;
%% TODO: Figure out how to compensate for this
process_error(Req, {gcm_device_msg_rate_exceeded, _BRegId}=Err) ->
    ?LOG_ERROR("Device message rate exceeded in req ~p", [pp(Req)]),
    Err;
%% TODO: If we add support for topics, fix this.
process_error(Req, {gcm_topics_msg_rate_exceeded, _BRegId}=Err) ->
    ?LOG_WARNING("Topics message rate exceeded in req ~p", [pp(Req)]),
    Err;
process_error(Req, {unknown_error_for_reg_id, {BRegId, GCMError}}=Err) ->
    ?LOG_ERROR("Unknown GCM Error ~p sending to registration ID ~p, req: ~p",
               [GCMError, BRegId, Req]),
    Err.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% See
%% <a href="https://developers.google.com/cloud-messaging/http-server-ref">
%% HTTP Connection Server Reference</a> for more details.
%%
%% The JSON response can contain the following:
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
%% @end
%%--------------------------------------------------------------------
-spec check_json_resp(Req, Resp) -> Result when
      Req :: gcm_req(), Resp :: json(),
      Result :: ok
              | {results, CheckedResults}
              | {error, missing_id_and_registration_ids}
              | {error, no_results_received}
              | {error, {bad_json, Resp, reason, Reason}}
              | {error, {reg_ids_out_of_sync,
                         {reg_ids(), gcm_results(), CheckedResults}}}
              ,
      CheckedResults :: checked_results(), Reason :: term().
check_json_resp(Req, Resp) ->
    case decode_json(Resp) of
        {ok, EJSON} ->
            check_ejson_resp(Req, EJSON);
        {error, _}=Err ->
            Err
    end.

%%--------------------------------------------------------------------
decode_json(JSON) ->
    try
        {ok, jsx:decode(JSON)}
    catch
        Class:Reason ->
            CR = {Class, Reason},
            _ = ?LOG_ERROR("JSON error ~p parsing GCM resp: ~p", [CR, JSON]),
            {error, {bad_json, JSON, reason, Reason}}
    end.

%%--------------------------------------------------------------------
-spec check_ejson_resp(Req, Resp) -> Result when
      Req :: gcm_req(), Resp :: gcm_ejson_response(),
      Result :: ok
              | {results, CheckedResults}
              | {error, Reason},
      CheckedResults :: checked_results(), Reason :: term().
check_ejson_resp(Req, EJSON) ->
    case {pv(<<"failure">>, EJSON, 0), pv(<<"canonical_ids">>, EJSON, 0)} of
        {0, 0} -> % Nothing failed or needs further attention
            ok;
        {_, _} ->
            Results = pv(<<"results">>, EJSON, []),
            check_results(Req, Results)
    end.

%%--------------------------------------------------------------------
-spec check_results(Req, Results) -> Retval when
      Req :: gcm_req(), Results :: gcm_results(),
      Retval :: {results, CheckedResults} | {error, Reason},
      CheckedResults :: checked_results(), Reason :: term().
check_results(Req, []) -> % No results, nothing to do
    _ = lager:warning("Expected GCM results, none found for req ~p", [Req]),
    {error, no_results_received};
check_results(#gcm_req{req_data = Props}, Results) ->
    case get_reg_ids(Props) of
        [_|_] = RIds ->
            check_results(RIds, Results, []);
        {error, _} = Error ->
            Error
    end.

%%--------------------------------------------------------------------
-spec check_results(RegIds, Results, Acc) -> Result when
      RegIds :: reg_ids(), Results :: gcm_results(), Acc :: checked_results(),
      Result :: {results, RAcc} | {error, {reg_ids_out_of_sync, {RegIds,
                                                                 Results,
                                                                 RAcc}}},
      RAcc :: checked_results().
check_results([<<RegId/binary>>|RegIds], [Result|Results], Acc) ->
    NewAcc = [check_result(RegId, Result) | Acc],
    check_results(RegIds, Results, NewAcc);
check_results([], [], Acc) ->
    {results, lists:reverse(Acc)};
check_results(RegIds, Results, Acc) ->
    RAcc = lists:reverse(Acc),
    _ = ?LOG_ERROR("No of reg IDs in req do not match resp~n"
                   "RegIds: ~p~nResults:~pAcc:~p", [RegIds, Results, RAcc]),
    {error, {reg_ids_out_of_sync, {RegIds, Results, RAcc}}}.

%%--------------------------------------------------------------------
%% JsonProps may contain <<"message_id">>, <<"registration_id">>, and
%% <<"error">>
%% @private
-spec check_result(BRegId, JsonProps) -> Result when
      BRegId :: reg_id(), JsonProps :: ejson(),
      Result :: checked_result().
check_result(BRegId, JsonProps) ->
    case {pv(<<"message_id">>, JsonProps),
          pv(<<"registration_id">>, JsonProps)} of
        {<<_MsgId/binary>>, <<CanonicalId/binary>>} ->
            {canonical_id, {old, BRegId, new, CanonicalId}};
        _ ->
            GCMError = pv(<<"error">>, JsonProps, <<>>),
            case to_gcm_error(GCMError) of
                gcm_unknown_error ->
                    {unknown_error_for_reg_id, {BRegId, GCMError}};
                KnownError when is_atom(KnownError) ->
                    {KnownError, BRegId}
            end
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc Implement exponential backoff algorithm when headers are
%% absent.
reschedule_req(Pid, BackoffParams, #gcm_req{} = Request) ->
    reschedule_req(Pid, BackoffParams, Request, []).

%%--------------------------------------------------------------------
%% @private
%% @doc Implement exponential backoff algorithm, honoring any
%% Retry-After header.
reschedule_req(Pid, BackoffParams, #gcm_req{} = Request, Headers) ->
    Res = calc_delay(BackoffParams, Request, Headers),
    case Res of
        {ok, WaitSecs} ->
            ReqId = Request#gcm_req.req_id,
            Now = erlang:monotonic_time(milli_seconds),
            TriggerTime = {Now + WaitSecs * 1000, milli_seconds},
            NewReq = backoff_gcm_req(Request, WaitSecs),
            ok = gcm_req_sched:add(ReqId, TriggerTime, NewReq, Pid),
            _ = ?LOG_DEBUG("Rescheduled ~p for ~B secs from now",
                           [uuid_to_str(Request#gcm_req.uuid), WaitSecs]),
            ok;
        Status ->
            _ = ?LOG_ERROR("Dropped notification because ~p:~n~p",
                           [Status, Request]),
            do_cb({error, Status}, Request),
            ok
    end.

%%--------------------------------------------------------------------
backoff_params(#?S{max_attempts=MaxAttempts,
                   max_req_ttl=MaxTtl,
                   max_backoff_secs=MaxBackoff}) ->
    {MaxTtl, MaxAttempts, MaxBackoff}.

%%--------------------------------------------------------------------
%% @private
%% @doc Calculate exponential backoff
calc_delay({MaxTtl, MaxAttempts, MaxBackoff}, Request, Headers) ->
    RequestAge = request_age(Request),
    if
        RequestAge >= MaxTtl ->
            max_age_exceeded;
        Request#gcm_req.num_attempts >= MaxAttempts ->
            max_attempts_exceeded;
        true ->
            {ok, calc_backoff_secs(MaxBackoff, Request, Headers)}
    end.

%%--------------------------------------------------------------------
%% @private
calc_backoff_secs(MaxBackoff, Request, Headers) ->
    Secs = case retry_after_val(Headers) of
        Delay when Delay > 0 ->
            Delay;
        _ ->
            Request#gcm_req.backoff_secs * 2
    end,
    min(Secs, MaxBackoff).

%%--------------------------------------------------------------------
%% @private
retry_after_val(Headers) ->
    case retry_after_hdr(Headers) of
        undefined ->
            0;
        Str ->
            list_to_integer(Str)
    end.

%%--------------------------------------------------------------------
%% @private
retry_after_hdr(Headers) -> % headers come back in lowercase
    pv("retry-after", Headers).

%%--------------------------------------------------------------------
%% @private
request_age(#gcm_req{created_at = CreatedAt}) ->
    sc_util:posix_time() - CreatedAt.

%%--------------------------------------------------------------------
%% @private
try_make_gcm_req(#send_req{}=SR, From, NumAttempts, #?S{}=St) ->
    try
        {ok, make_gcm_req(SR, From, NumAttempts, St)}
    catch
        throw:Error ->
            {error, Error}
    end.

%%--------------------------------------------------------------------
%% @private
-spec make_gcm_req(SR, From, NumAttempts, St) -> Result when
      SR :: send_req(), From :: {pid(), any()},
      NumAttempts :: non_neg_integer(),
      St :: state(), Result :: gcm_req().
make_gcm_req(#send_req{nf=Nf, opts=SendOpts}=SR, From, NumAttempts,
             #?S{ssl_opts=SslOpts,
                 auth_value=AuthValue,
                 uri=URI,
                 httpc_opts=HTTPCOpts,
                 retry_interval=RetrySecs}) ->
    {HTTPOpts, ReqOpts} = make_req_options(self(), SslOpts),
    SendHeaders = get_send_headers(SendOpts),
    Headers = merge_headers(SendHeaders, [{"Authorization", AuthValue}]),
    Req = make_json_req(URI, Headers, Nf),
    make_gcm_req(SR, From, Req, HTTPOpts, HTTPCOpts,
                 ReqOpts, NumAttempts, RetrySecs).

%%--------------------------------------------------------------------
merge_headers(Headers1, Headers2) ->
    lists:keymerge(1, lists:usort(normalize_headers(Headers1)),
                   lists:usort(normalize_headers(Headers2))).

%%--------------------------------------------------------------------
get_send_headers(Opts) ->
    case pv(http_headers, Opts, []) of
        [_|_] = L ->
            true = lists:all(fun({K, V}) -> is_list(K) andalso is_list(V);
                                (X) -> throw({invalid_header_value, X})
                             end, L),
            L;
        [] ->
            []
    end.

%%--------------------------------------------------------------------
normalize_headers(Headers) ->
    lists:map(fun({K, V}) -> {string:to_lower(K), V} end, Headers).

%%--------------------------------------------------------------------
%% @private
-spec make_gcm_req(SR, From, HR, HTTPOpts, HTTPCOpts, ReqOpts, NumAttempts,
                   BackoffSecs) -> Result when
      SR :: send_req(), From :: {pid(), any()}, HR :: httpc_request(),
      HTTPOpts :: http_opts(), HTTPCOpts :: httpc_opts(),
      ReqOpts :: req_opts(), NumAttempts :: pos_integer(),
      BackoffSecs :: pos_integer(), Result :: gcm_req().
make_gcm_req(#send_req{mode=Mode,
                       cb_pid=CbPid,
                       callback=Callback,
                       nf=Nf},
             From, HR, HTTPOpts, HTTPCOpts, ReqOpts, NumAttempts,
             BackoffSecs) ->
    UUID = case pv(uuid, Nf) of
               undefined -> make_uuid();
               UUIDVal   -> str_to_uuid(UUIDVal)
           end,

    #gcm_req{
        req_id = undefined,
        uuid = UUID,
        mode = Mode,
        from = From,
        cb_pid = CbPid,
        callback = Callback,
        req_data = lists:keydelete(uuid, 1, Nf),
        http_req = HR,
        http_opts = HTTPOpts,
        httpc_opts = HTTPCOpts,
        req_opts = ReqOpts,
        created_at = sc_util:posix_time(),
        num_attempts = NumAttempts,
        backoff_secs = BackoffSecs
    }.

%%--------------------------------------------------------------------
-compile({inline, [{make_json_req, 3}]}).
%% @private
-spec make_json_req(Url, Headers, Nf) -> Result when
      Url :: url(), Headers :: headers(),
      Nf :: notification(), Result :: httpc_request().

make_json_req(Url, Headers, Nf) ->
    ContentType = "application/json",
    Body = notification_to_json(Nf),
    {Url, Headers, ContentType, Body}.

%%--------------------------------------------------------------------
%% @private
backoff_gcm_req(#gcm_req{num_attempts = Attempt} = R, NewBackoff) ->
    R#gcm_req{
        num_attempts = Attempt + 1,
        backoff_secs = NewBackoff
    }.

%%--------------------------------------------------------------------
%% @private
-spec make_req_options(Pid, SSLOptions) -> Result when
      Pid :: pid(), SSLOptions :: ssloptions(),
      Result :: {HttpOptions, Options},
      HttpOptions :: http_opts(), Options :: req_opts().

make_req_options(Pid, []) ->
    SSLOptions = [
        {verify, verify_none}, % TODO: Figure out why {verify, verify_peer} fails to connect to GCM.
        {reuse_sessions, true}
    ],
    make_req_options(Pid, SSLOptions);
make_req_options(Pid, SSLOptions) ->
    HTTPOptions = [
        {timeout, 10000},
        {connect_timeout, 5000},
        {ssl, SSLOptions}
    ],
    Options = [
        {sync, false}, % async requests
        {receiver, Pid} % Sent to handle_info({http, ReplyInfo}, ...)
    ],
    {HTTPOptions, Options}.

%%--------------------------------------------------------------------
%% @private
-spec notification_to_json(Nf) -> Result when
      Nf :: notification(), Result :: binary().
notification_to_json(Nf) ->
    gcm_json:make_notification(Nf).

%%--------------------------------------------------------------------
%% @private
do_cb(Msg, #gcm_req{callback=Callback}=R) when is_function(Callback, 3) ->
    spawn(fun() ->
                  ReqPL = gcm_req_to_list(R),
                  try
                      ok = Callback(R#gcm_req.req_data, ReqPL, Msg)
                  catch
                      _:Error ->
                          ?LOG_WARNING("Callback failed: ~p", [Error])
                  end
          end).

%%--------------------------------------------------------------------
%% @private
-compile({inline, [{make_uuid, 0}]}).
-spec make_uuid() -> uuid().
make_uuid() ->
    uuid:get_v4().

%%--------------------------------------------------------------------
%% @private
-compile({inline, [{is_uuid, 1}]}).
-spec is_uuid(uuid()) -> boolean().
is_uuid(UUID) ->
    uuid:is_uuid(UUID).

%%--------------------------------------------------------------------
%% @private
-compile({inline, [{make_uuid_str, 0}]}).
-spec make_uuid_str() -> uuid_str().
make_uuid_str() ->
    uuid_to_str(make_uuid()).

%%--------------------------------------------------------------------
%% @private
-compile({inline, [{uuid_to_str, 1}]}).
-spec uuid_to_str(uuid()) -> uuid_str().
uuid_to_str(UUID) ->
    uuid:uuid_to_string(UUID, binary_standard).

%%--------------------------------------------------------------------
%% @private
-compile({inline, [{str_to_uuid, 1}]}).
-spec str_to_uuid(string() | binary()) -> uuid().
str_to_uuid(UUIDStr) ->
    uuid:string_to_uuid(UUIDStr).

%%--------------------------------------------------------------------
%% @private
-spec gen_send_callback(ReplyFun, NfPL, Req, Resp) -> Result when
      ReplyFun :: function(), NfPL :: [{atom(), term()}], Req :: proplist(),
      Resp :: term(), Result :: any().
gen_send_callback(ReplyFun, _NfPL, Req, Resp) when is_function(ReplyFun, 3) ->
    case pv(from, Req) of
        undefined ->
            ?LOG_ERROR("Cannot send result, no caller info: ~p", [Req]),
            {error, no_caller_info};
        Caller ->
            UUID = pv_req(uuid, Req),
            true = is_uuid(UUID),
            ?LOG_DEBUG("Invoke callback(caller=~p, uuid=~s, resp=~p",
                       [Caller, uuid_to_str(UUID), Resp]),
            ReplyFun(Caller, UUID, Resp),
            ok
    end.

%%--------------------------------------------------------------------
%% @private
sync_reply(Caller, _UUID, Resp) ->
    ?LOG_DEBUG("sync_reply to caller ~p, uuid=~p, resp=~p",
               [Caller, catch uuid_to_str(_UUID), Resp]),
    gen_server:reply(Caller, Resp).

%%--------------------------------------------------------------------
%% @private
async_reply({Pid, _Tag} = Caller, UUID, Resp) ->
    ?LOG_DEBUG("async_reply to caller ~p, uuid=~p, resp=~p",
               [Caller, catch uuid_to_str(UUID), Resp]),
    Pid ! gcm_response(UUID, Resp);
async_reply(Pid, UUID, Resp) when is_pid(Pid) ->
    ?LOG_DEBUG("async_reply to pid ~p, uuid=~p, resp=~p",
               [Pid, catch uuid_to_str(UUID), Resp]),
    Pid ! gcm_response(UUID, Resp).

%%--------------------------------------------------------------------
-compile({inline, [{gcm_response, 2}]}).
gcm_response(UUID, Resp) ->
    true = is_uuid(UUID),
    {gcm_response, v1, {UUID, Resp}}.

%%--------------------------------------------------------------------
%% @private
-spec gcm_req_to_list(GCMReq) -> Result when
      GCMReq :: gcm_req(), Result :: proplists:proplist().
gcm_req_to_list(#gcm_req{}=R) ->
    [{req_id,        R#gcm_req.req_id},
     {uuid,          R#gcm_req.uuid},
     {mode,          R#gcm_req.mode},
     {from,          R#gcm_req.from},
     {cb_pid,        R#gcm_req.cb_pid},
     {callback,      R#gcm_req.callback},
     {req_data,      R#gcm_req.req_data},
     {http_req,      R#gcm_req.http_req},
     {headers,       R#gcm_req.headers},
     {http_opts,     R#gcm_req.http_opts},
     {httpc_opts,    R#gcm_req.httpc_opts},
     {req_opts,      R#gcm_req.req_opts},
     {num_attempts,  R#gcm_req.num_attempts},
     {created_at,    R#gcm_req.created_at},
     {backoff_secs,  R#gcm_req.backoff_secs}].

%%--------------------------------------------------------------------
%% @private
-spec to_gcm_error(GCMErrorString) -> Result when
      GCMErrorString :: bstring(), Result :: gcm_error().
to_gcm_error(<<"MissingRegistration">>)       -> gcm_missing_reg;
to_gcm_error(<<"InvalidRegistration">>)       -> gcm_invalid_reg;
to_gcm_error(<<"MismatchSenderId">>)          -> gcm_mismatched_sender;
to_gcm_error(<<"NotRegistered">>)             -> gcm_not_registered;
to_gcm_error(<<"MessageTooBig">>)             -> gcm_message_too_big;
to_gcm_error(<<"InvalidDataKey">>)            -> gcm_invalid_data_key;
to_gcm_error(<<"InvalidTtl">>)                -> gcm_invalid_ttl;
to_gcm_error(<<"Unavailable">>)               -> gcm_unavailable;
to_gcm_error(<<"InternalServerError">>)       -> gcm_internal_server_error;
to_gcm_error(<<"InvalidPackageName">>)        -> gcm_invalid_package_name;
to_gcm_error(<<"DeviceMessageRateExceeded">>) -> gcm_device_msg_rate_exceeded;
to_gcm_error(<<"TopicsMessageRateExceeded">>) -> gcm_topics_msg_rate_exceeded;
to_gcm_error(<<_/binary>>)                    -> gcm_unknown_error.

%%--------------------------------------------------------------------
%% @private
-spec from_gcm_error(GCMError) -> Result when
      GCMError :: gcm_error(), Result :: bstring().

from_gcm_error(gcm_missing_reg)              -> <<"MissingRegistration">>;
from_gcm_error(gcm_invalid_reg)              -> <<"InvalidRegistration">>;
from_gcm_error(gcm_mismatched_sender)        -> <<"MismatchSenderId">>;
from_gcm_error(gcm_not_registered)           -> <<"NotRegistered">>;
from_gcm_error(gcm_message_too_big)          -> <<"MessageTooBig">>;
from_gcm_error(gcm_invalid_data_key)         -> <<"InvalidDataKey">>;
from_gcm_error(gcm_invalid_ttl)              -> <<"InvalidTtl">>;
from_gcm_error(gcm_unavailable)              -> <<"Unavailable">>;
from_gcm_error(gcm_internal_server_error)    -> <<"InternalServerError">>;
from_gcm_error(gcm_invalid_package_name)     -> <<"InvalidPackageName">>;
from_gcm_error(gcm_device_msg_rate_exceeded) -> <<"DeviceMessageRateExceeded">>;
from_gcm_error(gcm_topics_msg_rate_exceeded) -> <<"TopicsMessageRateExceeded">>;
from_gcm_error(Err) when is_atom(Err)        -> sc_util:to_bin(Err).

%%--------------------------------------------------------------------
%% @doc Map HTTP status code to textual description.
%% @end
%%--------------------------------------------------------------------
-spec status_desc(Status) -> Desc
    when Status :: pos_integer(), Desc :: bstring().
status_desc(200) -> <<"Success">>;
status_desc(400) -> <<"Invalid JSON">>;
status_desc(401) -> <<"Authentication error">>;
status_desc(404) -> <<"The path was bad">>;
status_desc(Status) when is_integer(Status), Status >= 500 ->
    <<"Unavailable">>;
status_desc(Status) when is_integer(Status) ->
    list_to_binary([<<"Unknown status code ">>, integer_to_list(Status)]).

%%--------------------------------------------------------------------
%% @doc Map GCM JSON error string to text description.
%% @end
%%--------------------------------------------------------------------
-spec reason_desc(Reason) -> Desc
    when Reason :: gcm_error_string(), Desc :: bstring().
reason_desc(<<"MissingRegistration">>) ->
    <<"Check that the request contains a registration token in the 'to' "
      "or 'registration_ids' field">>;
reason_desc(<<"InvalidRegistration">>) ->
    <<"Make sure the registration token matches the one the client app "
      "receives from registering with GCM">>;
reason_desc(<<"NotRegistered">>) ->
    <<"Unregistered device.">>;
reason_desc(<<"InvalidPackageName">>) ->
    <<"Make sure the message was addressed to a registration token whose "
      "package name matches the value passed in the request.">>;
reason_desc(<<"MismatchSenderId">>) ->
    <<"Make sure the sender ID matches one registered by the client app">>;
reason_desc(<<"MessageTooBig">>) ->
    <<"Check that the total size of the payload data does not exceed"
      "GCM limits.">>;
reason_desc(<<"InvalidDataKey">>) ->
    <<"Check that the payload data does not contain a key (such as 'from',"
      " or 'gcm', or any value prefixed by 'google') that is used "
      "internally by GCM">>;
reason_desc(<<"InvalidTtl">>) ->
    <<"Check that the value used in 'time_to_live' is an integer "
      "representing a duration in seconds between 0 and 2,419,200">>;
reason_desc(<<"Unavailable">>) ->
    <<"The server couldn't process the request in time.">>;
reason_desc(<<"DeviceMessageRateExceeded">>) ->
    <<"The rate of messages to a particular device is too high.">>;
reason_desc(<<"TopicsMessageRateExceeded">>) ->
    <<"The rate of messages to subscribers to a particular topic "
      "is too high.">>;
reason_desc(<<"InternalServerError">>) ->
    <<"The server encountered an error while trying to process "
      "the request.">>;
reason_desc(<<Other/bytes>>) ->
    Other.

%%--------------------------------------------------------------------
parsed_resp(Status, UUID, Resp) ->
    parsed_resp(Status, undefined, UUID, Resp).

parsed_resp(Status, Reason, UUID, Resp) ->
    RD = case Reason == undefined of
             true  -> undefined;
             false -> reason_desc(Reason)
         end,
    parsed_resp(Status, Reason, RD, UUID, Resp).

%%--------------------------------------------------------------------
parsed_resp(Status, Reason, ReasonDesc, UUID, Resp) ->
    S = sc_util:to_bin(Status),
    SD = status_desc(Status),
    BResp = sc_util:to_bin(Resp),
    EJSON = try jsx:decode(BResp) catch _:_ -> BResp end,

    [{uuid, uuid_to_str(UUID)},
     {status, S},
     {status_desc, SD}] ++
    case Reason of
        undefined -> [];
        _         -> R = sc_util:to_bin(Reason),
                     RD = sc_util:to_bin(ReasonDesc),
                     [{reason, R},
                      {reason_desc, RD}]
    end ++
     [{body, EJSON}].

%%--------------------------------------------------------------------
get_id_or_to_prop(Props) ->
    case {pv(id, Props), pv(to, Props)} of
        {undefined, undefined} ->
            undefined;
        {Id, undefined} ->
            Id;
        {undefined, Id} ->
            Id;
        {_, _} = Ids ->
            throw({ambiguous_ids, Ids})
    end.

%%--------------------------------------------------------------------
get_reg_ids(Props) ->
    case {pv(registration_ids, Props, []), get_id_or_to_prop(Props)} of
        {[], <<Id/binary>>} when Id /= <<>> -> % A single reg id
            [Id];
        {[_|_]=L, _} -> % A list of reg ids
            L;
        _ ->
            {error, missing_id_and_registration_ids}
    end.

%%--------------------------------------------------------------------
errors_to_props([{_,_}=Error], Resp, UUID) ->
    error_to_props(Error, Resp, UUID);
errors_to_props(Errors, Resp, UUID) ->
    {errors, [error_to_props(Error, Resp, UUID) || Error <- Errors]}.

%%--------------------------------------------------------------------
error_to_props({GcmError, <<_RegId/binary>>},
               Resp, UUID) when is_atom(GcmError) ->
    Reason = from_gcm_error(GcmError),
    ReasonDesc = reason_desc(Reason),
    parsed_resp(200, Reason, ReasonDesc, UUID, Resp);
error_to_props({GcmError, {<<_RegId/binary>>, <<Reason/binary>>}},
               Resp, UUID) when is_atom(GcmError) ->
    ReasonDesc = reason_desc(Reason),
    parsed_resp(200, Reason, ReasonDesc, UUID, Resp).

%%--------------------------------------------------------------------
%% Remove sensitive and otherwise uninteresting request data for
%% logging purposes.
%%--------------------------------------------------------------------
sanitize_req(#gcm_req{http_req=HttpReq}=R) ->
    R#gcm_req{
          http_req = sanitize_http_req(HttpReq)
         }.

%%--------------------------------------------------------------------
sanitize_http_req({Uri, Headers0, CType, Body}) ->
    Headers = lists:map(fun({K, _}=KV) ->
                                case string:to_lower(K) of
                                    "authorization" -> {K, "<redacted>"};
                                    _ -> KV
                                end
                           end, Headers0),
    {Uri, Headers, CType, Body}.

%%--------------------------------------------------------------------
-compile({inline, [{pp, 1}]}).
pp(Rec) ->
    lager:pr(Rec, ?MODULE).

%% vim: ts=4 sts=4 sw=4 et tw=80

