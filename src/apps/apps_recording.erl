%%%---------------------------------------------------------------------------------------
%%% @author     Max Lapshin <max@maxidoors.ru> [http://erlyvideo.org]
%%% @copyright  2009 Max Lapshin
%%% @doc        RTMP functions, that support recording
%%% @reference  See <a href="http://erlyvideo.org/" target="_top">http://erlyvideo.org</a> for more information
%%% @end
%%%
%%% This file is part of erlyvideo.
%%% 
%%% erlyvideo is free software: you can redistribute it and/or modify
%%% it under the terms of the GNU General Public License as published by
%%% the Free Software Foundation, either version 3 of the License, or
%%% (at your option) any later version.
%%%
%%% erlyvideo is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%%% GNU General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with erlyvideo.  If not, see <http://www.gnu.org/licenses/>.
%%%
%%%---------------------------------------------------------------------------------------
-module(apps_recording).
-author('Max Lapshin <max@maxidoors.ru>').
-include("../../include/ems.hrl").
-include("../../include/rtmp_session.hrl").
-include_lib("erlmedia/include/video_frame.hrl").

-export([publish/2]).
-export(['FCPublish'/2, 'FCUnpublish'/2]).


%%-------------------------------------------------------------------------
%% @private
%%-------------------------------------------------------------------------

'FCPublish'(State, #rtmp_funcall{args = [null, Name]} = _AMF) -> 
  ?D({"FCpublish", Name}),
  State.

'FCUnpublish'(State, #rtmp_funcall{args = [null, FullName]} = _AMF) ->
  {RawName, _Args1} = http_uri2:parse_path_query(FullName),
  Name = string:join( [Part || Part <- ems:str_split(RawName, "/"), Part =/= ".."], "/"),
  ?D({"FCunpublish", Name}),
  % apps_streaming:stop(State, AMF).
  % rtmp_session:reply(State,AMF#rtmp_funcall{args = [null, undefined]}),
  State.


real_publish(#rtmp_session{host = Host, streams = Streams, socket = Socket} = State, FullName, Type, StreamId) ->

  {RawName, Args1} = http_uri2:parse_path_query(FullName),
  Name = string:join( [Part || Part <- ems:str_split(RawName, "/"), Part =/= ".."], "/"),
  Options1 = extract_publish_args(Args1),
  Options = lists:ukeymerge(1, Options1, [{type,Type}]),
  
  ems_log:access(Host, "PUBLISH ~p ~s ~p ~s", [Type, State#rtmp_session.addr, State#rtmp_session.user_id, Name]),
  ?D(Options),
  {ok, Recorder} = media_provider:create(Host, Name, Options),
  rtmp_socket:send(Socket, #rtmp_message{type = stream_begin, stream_id = StreamId}),
  rtmp_socket:status(Socket, StreamId, ?NS_PUBLISH_START),
  State#rtmp_session{streams = ems:setelement(StreamId, Streams, Recorder)}.
  
extract_publish_args([]) -> [];
extract_publish_args({"source_timeout", "infinity"}) -> {source_timeout, infinity};
extract_publish_args({"source_timeout", "shutdown"}) -> {source_timeout, shutdown};
extract_publish_args({"source_timeout", Timeout}) -> {source_timeout, list_to_integer(Timeout)};
extract_publish_args({Key, Value}) -> {Key, Value};
extract_publish_args(List) -> [extract_publish_args(Arg) || Arg <- List].

publish(State, #rtmp_funcall{args = [null,Name, <<"record">>], stream_id = StreamId} = _AMF) -> 
  real_publish(State, Name, record, StreamId);

publish(State, #rtmp_funcall{args = [null,Name,<<"append">>], stream_id = StreamId} = _AMF) -> 
  real_publish(State, Name, append, StreamId);

publish(State, #rtmp_funcall{args = [null,Name,<<"LIVE">>], stream_id = StreamId} = _AMF) ->
  real_publish(State, Name, live, StreamId);

publish(State, #rtmp_funcall{args = [null,Name,<<"live">>], stream_id = StreamId} = _AMF) -> 
  real_publish(State, Name, live, StreamId);

publish(State, #rtmp_funcall{args = [null, false]} = AMF) ->
  apps_streaming:stop(State, AMF);

publish(State, #rtmp_funcall{args = [null, null]} = AMF) ->
  apps_streaming:stop(State, AMF);

publish(State, #rtmp_funcall{args = [null, <<"null">>]} = AMF) ->
  apps_streaming:stop(State, AMF);
  
publish(State, #rtmp_funcall{args = [null,Name], stream_id = StreamId} = _AMF) -> 
  real_publish(State, Name, live, StreamId).

