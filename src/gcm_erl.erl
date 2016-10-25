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
%%% @doc Google Cloud Messaging (GCM) API.
%%%
%%% This is the API to the GCM Service Provider.
%%%
%%% == Synopsis ==
%%% In the example below, all optional values are shown with their
%%% defaults if omitted.
%%% === Starting a session ===
%%% ```
%%% Opts = [
%%%             %% Required GCM API key
%%%             {api_key, <<"ahsgdfjkjkjfdk">>},
%%%             %% Required, even if empty list. Defaults shown.
%%%             {ssl_opts, [
%%%                 {verify, verify_peer},
%%%                 {reuse_sessions, true}
%%%             ]},
%%%             %% Optional, defaults as shown.
%%%             {uri, "https://gcm-http.googleapis.com/gcm/send"},
%%%             %% Optional, omitted if missing.
%%%             {restricted_package_name, <<"my-android-pkg">>},
%%%             %% Maximum times to try to send and then give up.
%%%             {max_attempts, 10},
%%%             %% Starting point in seconds for exponential backoff.
%%%             %% Optional.
%%%             {retry_interval, 1},
%%%             %% Maximum seconds for a request to live in a retrying state.
%%%             {max_req_ttl, 3600},
%%%             %% Reserved for future use
%%%             {failure_action, fun(_)}
%%%         ],
%%%
%%% {ok, Pid} = gcm_erl:start_session(my_push_tester, Opts).
%%% '''
%%%
%%% === Sending an alert via the API ===
%%% ```
%%% RegId = <<"e7b300...a67b">>, % From earlier Android registration
%%% SimpleOpts = [
%%%     {id, RegId},
%%%     {collapse_key, <<"New Mail">>},
%%%     {data, [{msg, <<"You have new mail">>}]}
%%% ],
%%% {ok, Ref} = gcm_erl:send(my_push_tester, SimpleOpts).
%%% '''
%%%
%%% === Sending an alert via a session (for testing only) ===
%%% ```
%%% {ok, Ref} = gcm_erl_session:send(my_push_tester, SimpleOpts).
%%% '''
%%%
%%% === Stopping a session ===
%%% ```
%%% ok = gcm_erl:stop_session(my_push_tester).
%%% '''
%%%
%%% == References ==
%%% <dl>
%%%   <dt>[REF]</dt><dd>Description</dd>
%%% </dl>
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(gcm_erl).

%%--------------------------------------------------------------------
%% Includes
%%--------------------------------------------------------------------
-include_lib("lager/include/lager.hrl").

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------
-export([
        start_session/2,
        stop_session/1,
        send/2,
        async_send/2
    ]).

%%--------------------------------------------------------------------
%% @doc
%% Start a named session.
%% @see gcm_erl_session:start_link/2.
%% @end
%%--------------------------------------------------------------------
-spec start_session(atom(), gcm_erl_session:start_opts()) ->
    {ok, pid()} | {error, already_started} | {error, Reason::term()}.
start_session(Name, Opts) when is_atom(Name), is_list(Opts) ->
    gcm_erl_session_sup:start_child(Name, Opts).

%%--------------------------------------------------------------------
%% @doc Stop named session.
%% @end
%%--------------------------------------------------------------------
-spec stop_session(Name::atom()) -> ok | {error, Reason::term()}.
stop_session(Name) when is_atom(Name) ->
    gcm_erl_session_sup:stop_child(Name).

%%--------------------------------------------------------------------
%% @doc Send a notification specified by proplist `Notification'
%% `SvrRef'.
%% Note that `SvrRef' may be the registered name or `{Name, Node}',
%% where `Node' is an Erlang node on which the registered process
%% called `Name' is running.
%%
%% === Example ===
%%
%% ```
%% Name = 'my_android_app1', % Note: atom() !
%% Notification = [
%%    %% Required, all others optional
%%    {id, <<"abc">>},
%%    {collapse_key, <<"Something">>},
%%    {priority, <<"high">>},
%%    {content_available, true},
%%    {data, []},
%%    {delay_while_idle, false},
%%    {time_to_live, 3600},
%%    {restricted_package_name, <<"foo_pkg>>},
%%    {dry_run, false}
%% ],
%% gcm_erl:send(Name, Notification),
%% gcm_erl:send({Name, node()}, Notification).
%% '''
%% @see gcm_erl_session:send/2.
%% @end
%%--------------------------------------------------------------------
-spec send(SvrRef, Notification) -> Result when
      SvrRef :: term(), Notification :: gcm_json:notification(),
      Result :: {ok, Reply} | {error, Reason}, Reply :: term(),
      Reason :: term().
send(SvrRef, Notification) when is_list(Notification) ->
    gcm_erl_session:send(SvrRef, Notification).

-spec async_send(SvrRef, Notification) -> Result when
      SvrRef :: term(), Notification :: gcm_json:notification(),
      Result :: {ok, Reply} | {error, Reason}, Reply :: term(),
      Reason :: term().
async_send(SvrRef, Notification) when is_list(Notification) ->
    gcm_erl_session:async_send(SvrRef, Notification).


%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------
