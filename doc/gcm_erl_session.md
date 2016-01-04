

# Module gcm_erl_session #
* [Description](#description)
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

GCM server session.

Copyright (c) 2015 Silent Circle

__Behaviours:__ [`gen_server`](gen_server.md).

__Authors:__ Edwin Fine ([`efine@silentcircle.com`](mailto:efine@silentcircle.com)).

<a name="description"></a>

## Description ##

There must be one session per API key and
Sessions must have unique (i.e. they are registered) names
within the node.

Reference:

[](http://developer.android.com/guide/google/gcm/gcm.md#server)
<a name="types"></a>

## Data Types ##




### <a name="type-notification">notification()</a> ###


<pre><code>
notification() = <a href="gcm_json.md#type-notification">gcm_json:notification()</a>
</code></pre>




### <a name="type-opt">opt()</a> ###


<pre><code>
opt() = {uri, string()} | {api_key, binary()} | {restricted_package_name, binary()} | {max_req_ttl, non_neg_integer()} | {max_backoff_secs, non_neg_integer()} | {max_attempts, non_neg_integer()} | {retry_interval, non_neg_integer()} | {ssl_opts, [<a href="ssl.md#type-ssloption">ssl:ssloption()</a>]} | {httpc_opts, list()}
</code></pre>




### <a name="type-start_opts">start_opts()</a> ###


<pre><code>
start_opts() = [<a href="gcm_erl_session.md#type-opt">gcm_erl_session:opt()</a>]
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#async_send-2">async_send/2</a></td><td>Asynchronously sends a notification specified by
<code>Notification</code> via <code>SvrRef</code>; same as <a href="#send-2"><code>send/2</code></a> otherwise.</td></tr><tr><td valign="top"><a href="#async_send-3">async_send/3</a></td><td>Asynchronously sends a notification specified by
<code>Notification</code> via <code>SvrRef</code> with options; same as <a href="#send-3"><code>send/3</code></a>
otherwise.</td></tr><tr><td valign="top"><a href="#send-2">send/2</a></td><td>Send a notification specified by <code>Notification</code> via
<code>SvrRef</code>.</td></tr><tr><td valign="top"><a href="#send-3">send/3</a></td><td>Send a notification specified by <code>Notification</code> via
<code>SvrRef</code>, with options <code>Opts</code>.</td></tr><tr><td valign="top"><a href="#start-2">start/2</a></td><td>Start a named session as described by the <code>StartOpts</code>.</td></tr><tr><td valign="top"><a href="#start_link-2">start_link/2</a></td><td>Start a named session as described by the options <code>Opts</code>.</td></tr><tr><td valign="top"><a href="#stop-1">stop/1</a></td><td>Stop session.</td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="async_send-2"></a>

### async_send/2 ###

<pre><code>
async_send(SvrRef::term(), Notification::<a href="#type-notification">notification()</a>) -&gt; ok
</code></pre>
<br />

Asynchronously sends a notification specified by
`Notification` via `SvrRef`; same as [`send/2`](#send-2) otherwise.

<a name="async_send-3"></a>

### async_send/3 ###

<pre><code>
async_send(SvrRef::term(), Notification::<a href="#type-notification">notification()</a>, Opts::list()) -&gt; ok
</code></pre>
<br />

Asynchronously sends a notification specified by
`Notification` via `SvrRef` with options; same as [`send/3`](#send-3)
otherwise.

<a name="send-2"></a>

### send/2 ###

<pre><code>
send(SvrRef::term(), Notification::<a href="#type-notification">notification()</a>) -&gt; {ok, Ref::term()} | {error, Reason::term()}
</code></pre>
<br />

Send a notification specified by `Notification` via
`SvrRef`.  For JSON format, see
[
GCM Architectural Overview](http://developer.android.com/guide/google/gcm/gcm.md#server).

__See also:__ [gcm_json:make_notification/1](gcm_json.md#make_notification-1), [gcm_json:notification/0](gcm_json.md#notification-0).

<a name="send-3"></a>

### send/3 ###

<pre><code>
send(SvrRef::term(), Notification::<a href="#type-notification">notification()</a>, Opts::list()) -&gt; {ok, Ref::term()} | {error, Reason::term()}
</code></pre>
<br />

Send a notification specified by `Notification` via
`SvrRef`, with options `Opts`.

For JSON format, see
[
GCM Architectural Overview](http://developer.android.com/guide/google/gcm/gcm.md#server).


### <a name="Options">Options</a> ###




<dt><code>{callback, {pid(), [progress|completion]}}</code></dt>




<dd><p>Optional internal parameters. This is never sent to GCM.</p><p></p><p><code>{callback, {pid(), [...]}}</code> requests that one or more
status messages be sent to <code>pid()</code>. Status messages consist
of <code>progress</code> and <code>completion</code> messages. Each message is in
the format <code>{gcm_erl, StatusType, Ref, Status}</code>.
<code>StatusType</code> is either <code>progress</code> or <code>completion</code>. No
further messages will be sent for that reference once a
<code>completion</code> status is sent. <code>Ref</code> is the reference that
<code>send/3</code> returns on success (i.e. in <code>{ok, Ref}</code>). <code>Status</code>
is a <code>term()</code> that depends on the <code>StatusType</code> and state of
the request. For <code>progress</code> messages, <code>Status</code> is a binary
string, e.g. <code><<"accepted">></code>. For <code>completion</code>, <code>Status</code> is
either <code>ok</code> or <code>{error, term()}</code>.</p><p></p><p>The default is to deliver no status messages.</p><p></p><h4><a name="Example">Example</a></h4>
<pre>       Opts = [{callback, {self(), [completion]}}],</pre>
</dd>



__See also:__ [gcm_json:make_notification/1](gcm_json.md#make_notification-1), [gcm_json:notification/0](gcm_json.md#notification-0).

<a name="start-2"></a>

### start/2 ###

<pre><code>
start(Name::atom(), StartOpts::<a href="#type-start_opts">start_opts()</a>) -&gt; term()
</code></pre>
<br />

Start a named session as described by the `StartOpts`.
`Name` is registered so that the session can be referenced using
the name to call functions like [`send/2`](#send-2).  Note that this
function is only used for testing.

* For `ssl_opts` see ssl:ssloptions/0 in ssl:connect/2.

* For `httpc_opts`, see httpc:set_options/1.


__See also:__ [start_link/2](#start_link-2).

<a name="start_link-2"></a>

### start_link/2 ###

<pre><code>
start_link(Name::atom(), Opts::<a href="#type-start_opts">start_opts()</a>) -&gt; term()
</code></pre>
<br />

Start a named session as described by the options `Opts`.  The name
`Name` is registered so that the session can be referenced using
the name to call functions like [`send/2`](#send-2).


### <a name="Parameters">Parameters</a> ###


* `Name` - Session name (atom)

* `Opts` - Options



<dt><code>{api_key, binary()}</code></dt>




<dd>Google API Key, e.g.
<code><<"AIzafffffffffffffffffffffffffffffffffaA">></code></dd>




<dt><code>{max_attempts, pos_integer()|infinity}</code></dt>




<dd>The maximum number of times to attempt to send the
message when receiving a 5xx error.</dd>




<dt><code>{retry_interval, pos_integer()}</code></dt>




<dd>The initial number of seconds to wait before reattempting to
send the message.</dd>




<dt><code>{max_req_ttl, pos_integer()}</code></dt>




<dd>The maximum time in seconds for which this request
will live before being considered undeliverable and
stopping with an error.</dd>




<dt><code>{max_backoff_secs, pos_integer()}</code></dt>




<dd>The maximum backoff time in seconds for this request.
This limits the exponential backoff to a maximum
value.</dd>




<dt><code>{restricted_package_name, binary()}</code></dt>




<dd>A string containing the package name of your
application. When set, messages will only be sent to
registration IDs that match the package name.
Optional.</dd>




<dt><code>{uri, string()}</code></dt>




<dd>GCM URI, defaults to
<code>https://gcm-http.googleapis.com/gcm/send</code>. Optional.</dd>




<dt><code>{collapse_key, string()}</code></dt>




<dd>Arbitrary string use to collapse a group of like
messages into a single message when the device is offline.
Optional.</dd>






<a name="stop-1"></a>

### stop/1 ###

<pre><code>
stop(SvrRef::term()) -&gt; term()
</code></pre>
<br />

Stop session.

