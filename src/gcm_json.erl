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
%%% This module handles JSON conversion for Google Cloud Messaging (GCM).
%%% @end
%%%-------------------------------------------------------------------
-module(gcm_json).
-export([make_notification/1]).

-record(key_t, {key, key_bin, type_fun}).

-export_type([
        recipient_id/0,
        registration_ids/0,
        collapse_key/0,
        priority/0,
        content_available/0,
        delay_while_idle/0,
        time_to_live/0,
        restricted_package_name/0,
        dry_run/0,
        data/0,
        notification/0,
        json_term/0
    ]).

-type recipient_id()            :: binary().
-type registration_ids()        :: [binary()].
-type collapse_key()            :: binary().
-type priority()                :: binary().
-type content_available()       :: boolean().
-type delay_while_idle()        :: boolean().
-type time_to_live()            :: integer().
-type restricted_package_name() :: binary().
-type dry_run()                 :: boolean().
-type data()                    :: [{binary(), any()}].

-type gcm_opt() :: recipient_id() |
                   registration_ids() |
                   collapse_key() |
                   priority() |
                   content_available() |
                   delay_while_idle() |
                   time_to_live() |
                   restricted_package_name() |
                   dry_run() |
                   data().

-type notification() :: [{atom(), gcm_opt()}].

-type json_term() :: [{binary() | atom(), json_term()}] | [{}]
    | [json_term()] | []
    | true | false | null
    | integer() | float()
    | binary() | atom()
    | calendar:datetime().

-type m_optional(T) :: 'None' | {'Some', T}.

%%--------------------------------------------------------------------
%% @doc Create a notification consisting of a JSON binary suitable for
%% transmitting to the Google Cloud Messaging Service.
%%
%% To understand the various properties below, please see
%% <a href="http://developer.android.com/guide/google/gcm/index.html">
%% GCM Architectural Overview</a>.
%% The description given is basically to show how to format the
%% properties in Erlang.
%%
%% == Notification Properties ==
%%
%% <dl>
%%   <dt>`id::binary()'</dt>
%%      <dd>
%%      Recipient ID (binary string). <strong>Required</strong> unless
%%      `registration_ids' is provided.  This corresponds to the GCM `to'
%%      parameter, which is one of a registration token, notification key, or
%%      topic.  </dd>
%%   <dt>`registration_ids::[binary()]'</dt>
%%      <dd>List of binary strings. Each binary is a registration id
%%      for an Android device+application. <strong>Required</strong> unless
%%      `id' is provided.
%%      </dd>
%%   <dt>`data::[{binary(), any()}]'</dt>
%%      <dd><strong>Required</strong>.<br/>
%%          Message payload data, which must be an
%%          object (Erlang proplist) as described in the table below.
%%
%%      <table class="with-borders">
%%        <tr>
%%          <th><strong>json</strong></th><th><strong>erlang</strong></th>
%%        </tr>
%%        <tr>
%%          <td> <code>number</code> </td>
%%          <td> <code>integer()</code> and <code>float()</code></td>
%%        </tr>
%%        <tr>
%%          <td> <code>string</code> </td>
%%          <td> <code>binary()</code> </td>
%%        </tr>
%%        <tr>
%%          <td> <code>true</code>, <code>false</code> and <code>null</code></td>
%%          <td> <code>true</code>, <code>false</code> and <code>null</code></td>
%%        </tr>
%%        <tr>
%%          <td> <code>array</code> </td>
%%          <td> <code>[]</code> and <code>[JSON]</code></td>
%%        </tr>
%%        <tr>
%%          <td> <code>object</code> </td>
%%          <td> <code>[{}]</code> and <code>[{binary() OR atom(), JSON}]</code></td>
%%        </tr>
%%      </table>
%%      </dd>
%%   <dt>`gcm::list()'</dt>
%%   <dd>An optional list of GCM-specific properties</dd>
%%   <dl>
%%       <dt>`collapse_key::binary()'</dt>
%%          <dd>Binary string. Optional.</dd>
%%       <dt>`priority::binary()'</dt>
%%          <dd>Binary string. Optional. Either `<<"normal">>' (default) or
%%          `<<"high">>'.</dd>
%%       <dt>`content_available::boolean()'</dt>
%%          <dd>Binary string. Optional.</dd>
%%       <dt>`delay_while_idle::boolean()'</dt>
%%          <dd>See GCM reference. Optional.</dd>
%%       <dt>`time_to_live::integer()'</dt>
%%          <dd>Optional.</dd>
%%       <dt>`restricted_package_name::binary()'</dt>
%%          <dd>Binary string - overrides default on server. Optional.</dd>
%%       <dt>`dry_run::boolean()'</dt>
%%          <dd>Optional (defaults to false)</dd>
%%  </dl>
%% </dl>
%% == Examples of Notification proplist ==
%%
%% === Simplest possible single registration id notification ===
%%
%% ```
%% Notification = [
%%     {'id', <<"registration-id">>},
%%     {'data', [{msg, <<"Would you like to play a game?">>}]}
%% ].
%% '''
%%
%% === Simplest possible multiple registration id notification ===
%% ```
%% Notification = [
%%     {'registration_ids', [<<"registration-id-1">>, <<"registration-id-2">>]},
%%     {'data', [{msg, <<"Would you like to play a game?">>}]}
%% ].
%% '''
%% @end
%%--------------------------------------------------------------------
-spec make_notification(notification()) -> binary().
make_notification(Notification) ->
    ReqProps = get_req_props(Notification),
    OptProps = type_check_opt_props(get_opt_props(Notification),
                                    optional_keys()),
    jsx:encode(ReqProps ++ OptProps).

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------
-spec get_req_props(notification()) -> json_term().
get_req_props(Notification) ->
    case get_id_or_to_prop(Notification) of
        undefined ->
            [{<<"registration_ids">>, get_valid_reg_ids(Notification)}];
        RegId ->
            [{<<"to">>, valid_reg_id(RegId)}]
    end ++ [{<<"data">>, required(data, Notification)}].

%%--------------------------------------------------------------------
get_id_or_to_prop(Notification) ->
    case {value(id, Notification), value(to, Notification)} of
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
-spec get_opt_props(notification()) -> json_term().
get_opt_props(Notification) ->
    case value(gcm, Notification) of
        undefined ->
            [];
        L when is_list(L) ->
            L
    end.

%%--------------------------------------------------------------------
-spec get_valid_reg_ids(notification()) -> json_term().
get_valid_reg_ids(Notification) ->
    case [valid_reg_id(RegId) ||
          RegId <- required(registration_ids, Notification)] of
        [] ->
            throw({validation_failed, {registration_ids, list_empty}});
        L when length(L) > 1000 ->
            throw(too_many_reg_ids);
        L ->
            L
    end.

%%--------------------------------------------------------------------
-compile({inline, [{valid_reg_id, 1}]}).
-spec valid_reg_id(RegId :: binary()) -> binary().
valid_reg_id(RegId) ->
    type_check(fun is_binary/1, RegId).

%%--------------------------------------------------------------------
required(K, PL) ->
    case value(K, PL) of
        V when V =:= undefined orelse V =:= <<>> ->
            throw({missing_required_key_or_value, K});
        V ->
            V
    end.

%%--------------------------------------------------------------------
-spec optional(V) -> Result when
      V :: any(), Result :: m_optional(V).
optional(V) when V =:= undefined orelse V =:= <<>> ->
    'None';
optional(V) ->
    {'Some', V}.

%%--------------------------------------------------------------------
-compile({inline, [{value, 2}]}).
value(Key, PL) ->
    proplists:get_value(Key, PL).

%%--------------------------------------------------------------------
%% "Monadic" type check, T =:= {'Some', X} | T =:= 'None'
%% Type checks X, returns X if type ok, 'None' if T =:= 'None'
-type type_pred() :: fun((X :: any()) -> boolean()).
-spec m_type_check(Pred, Optional) -> Result when
      Pred :: type_pred(), Optional :: m_optional(Val),
      Val :: any(), Result :: 'None' | Val.
m_type_check(TypePred, T) when is_function(TypePred, 1) ->
    case T of
        'None' ->
            T;
        {'Some', X} ->
            type_check(TypePred, X)
    end.

%%--------------------------------------------------------------------
-spec type_check(TypePred, T) -> T when
      TypePred :: fun((X :: any()) -> boolean()), T :: any().
type_check(TypePred, T) when is_function(TypePred, 1) ->
    case TypePred(T) of
        true ->
            T;
        false ->
            throw(type_check_failed)
    end.

%%--------------------------------------------------------------------
-spec optional_keys() -> [#key_t{}].

optional_keys() ->
    [
        #key_t{key = priority,
               key_bin = <<"priority">>,
               type_fun = fun erlang:is_binary/1},
        #key_t{key = content_available,
               key_bin = <<"content_available">>,
               type_fun = fun erlang:is_boolean/1},
        #key_t{key = collapse_key,
               key_bin = <<"collapse_key">>,
               type_fun = fun erlang:is_binary/1},
        #key_t{key = delay_while_idle,
               key_bin = <<"delay_while_idle">>,
               type_fun = fun erlang:is_boolean/1},
        #key_t{key = time_to_live,
               key_bin = <<"time_to_live">>,
               type_fun = fun erlang:is_integer/1},
        #key_t{key = restricted_package_name,
               key_bin = <<"restricted_package_name">>,
               type_fun = fun erlang:is_binary/1},
        #key_t{key = dry_run,
               key_bin = <<"dry_run">>,
               type_fun = fun erlang:is_boolean/1}
    ].

%%
%%--------------------------------------------------------------------
-spec type_check_opt_props(PL::list(), KeyRecs::list(#key_t{}))
      -> [{Key::binary(), Val::any()}].
type_check_opt_props(PL, [#key_t{}|_] = KeyRecs) ->
    [{KeyBin, Val} || #key_t{key_bin=KeyBin} = R <- KeyRecs,
                      (Val = do_type_check(R, PL)) /= 'None'].

%%--------------------------------------------------------------------
-spec do_type_check(KeyRec, PL) -> Result when
      KeyRec :: #key_t{}, PL :: proplist:proplists(),
      Val :: any(), Result :: 'None' | Val.
do_type_check(#key_t{key=K, type_fun=F}, PL) ->
    V = value(K, PL),
    try
        m_type_check(F, optional(V))
    catch
        throw:type_check_failed ->
            {name, FName} = erlang:fun_info(F, name),
            throw({type_check_failed, {pred, FName, 'key', K, 'val', V}})
    end.

%% vim: ts=4 sts=4 sw=4 et tw=80
