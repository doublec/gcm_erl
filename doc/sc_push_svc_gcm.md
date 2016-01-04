

# Module sc_push_svc_gcm #
* [Description](#description)
* [Function Index](#index)
* [Function Details](#functions)

Google Cloud Messaging Push Notification Service (gcm) API.

Copyright (c) 2015 Silent Circle

__Behaviours:__ [`supervisor`](supervisor.md).

__Authors:__ Edwin Fine ([`efine@silentcircle.com`](mailto:efine@silentcircle.com)).

<a name="description"></a>

## Description ##

This is the API to the Google Cloud Messaging Service Provider. It
runs as a supervisor, so should be started either from an application
module or a supervisor.


### <a name="Synopsis">Synopsis</a> ###


#### <a name="Configuration">Configuration</a> ####

Start the API by calling start_link/1 and providing a list of
sessions to start. Each session is a proplist as shown below:

```
   [
       {name, 'gcm-com.example.Example'},
       {config, [
               {api_key, <<"AIzaffffffffffffffffffffffffffffffff73w">>},
               {ssl_opts, [{verify, verify_none}]},
               {uri, "https://gcm-http.googleapis.com/gcm/send"},
               {max_attempts, 5},
               {retry_interval, 1},
               {max_req_ttl, 600}
           ]}
   ]
```

Note that the session _must_ be named `gcm-AppId`,
where `AppId` is the Android App ID, such as
`com.example.Example`.


#### <a name="Sending_an_alert_via_the_API">Sending an alert via the API</a> ####

Alerts should usually be sent via the API, `gcm_erl`.

```
   Alert = <<"Hello, Android!">>,
   Notification = [{alert, Alert}],
   {ok, SeqNo} = gcm_erl:send(my_push_tester, Notification).
```


#### <a name="Sending_an_alert_via_a_session_(for_testing_only)">Sending an alert via a session (for testing only)</a> ####

```
   Notification = [
       {id, sc_util:to_bin(RegId)}, % Required key
       {data, [{alert, sc_util:to_bin(Msg)}]}
   ],
   {ok, SeqNo} = gcm_erl_session:send(my_push_tester, Notification).
```

For multiple registration ids:

```
   Notification = [
       {registration_ids, [sc_util:to_bin(RegId) || RegId <- RegIds]}, % Required key
       {data, [{alert, sc_util:to_bin(Msg)}]}
   ],
   {ok, SeqNo} = gcm_erl_session:send(my_push_tester, Notification).
```

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#async_send-2">async_send/2</a></td><td>Asynchronously sends a notification specified by proplist
<code>Notification</code>; Same as <a href="#send-2"><code>send/2</code></a> beside returning only 'ok' on success.</td></tr><tr><td valign="top"><a href="#async_send-3">async_send/3</a></td><td>Asynchronously sends a notification specified by proplist
<code>Notification</code>; Same as <a href="#send-3"><code>send/3</code></a> beside returning only 'ok' on success.</td></tr><tr><td valign="top"><a href="#init-1">init/1</a></td><td></td></tr><tr><td valign="top"><a href="#send-2">send/2</a></td><td>Send a notification specified by proplist <code>Notification</code></td></tr><tr><td valign="top"><a href="#send-3">send/3</a></td><td>Send a notification specified by proplist <code>Notification</code> and
with options <code>Opts</code>.</td></tr><tr><td valign="top"><a href="#start_link-1">start_link/1</a></td><td><code>Opts</code> is a list of proplists.</td></tr><tr><td valign="top"><a href="#start_session-2">start_session/2</a></td><td>Start named session for specific host and certificate as
described in the options proplist <code>Opts</code>.</td></tr><tr><td valign="top"><a href="#stop_session-1">stop_session/1</a></td><td>Stop named session.</td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="async_send-2"></a>

### async_send/2 ###

<pre><code>
async_send(Name::term(), Notification::<a href="gcm_json.md#type-notification">gcm_json:notification()</a>) -&gt; ok | {error, Reason::term()}
</code></pre>
<br />

Asynchronously sends a notification specified by proplist
`Notification`; Same as [`send/2`](#send-2) beside returning only 'ok' on success.

<a name="async_send-3"></a>

### async_send/3 ###

<pre><code>
async_send(Name::term(), Notification::<a href="gcm_json.md#type-notification">gcm_json:notification()</a>, Opts::[{atom(), term()}]) -&gt; ok | {error, Reason::term()}
</code></pre>
<br />

Asynchronously sends a notification specified by proplist
`Notification`; Same as [`send/3`](#send-3) beside returning only 'ok' on success.

<a name="init-1"></a>

### init/1 ###

`init(Opts) -> any()`

<a name="send-2"></a>

### send/2 ###

<pre><code>
send(Name::term(), Notification::<a href="gcm_json.md#type-notification">gcm_json:notification()</a>) -&gt; {ok, Ref::term()} | {error, Reason::term()}
</code></pre>
<br />

Send a notification specified by proplist `Notification`

<a name="send-3"></a>

### send/3 ###

<pre><code>
send(Name::term(), Notification::<a href="gcm_json.md#type-notification">gcm_json:notification()</a>, Opts::[{atom(), term()}]) -&gt; {ok, Ref::term()} | {error, Reason::term()}
</code></pre>
<br />

Send a notification specified by proplist `Notification` and
with options `Opts`.

__See also:__ [gcm_erl_session:send/3](gcm_erl_session.md#send-3).

<a name="start_link-1"></a>

### start_link/1 ###

<pre><code>
start_link(Opts::list()) -&gt; {ok, pid()} | {error, term()}
</code></pre>
<br />

`Opts` is a list of proplists.
Each proplist is a session definition containing
`name` and `config` keys.

<a name="start_session-2"></a>

### start_session/2 ###

<pre><code>
start_session(Name::atom(), Opts::list()) -&gt; {ok, pid()} | {error, already_started} | {error, Reason::term()}
</code></pre>
<br />

Start named session for specific host and certificate as
described in the options proplist `Opts`.

__See also:__ [__Options__ in `gcm_erl_session`](gcm_erl_session.md#start_session-2).

<a name="stop_session-1"></a>

### stop_session/1 ###

<pre><code>
stop_session(Name::atom()) -&gt; ok | {error, Reason::term()}
</code></pre>
<br />

Stop named session.

