%%%---------------------------------------------------------------------------------------
%%% @author     Max Lapshin <max@maxidoors.ru> [http://erlyvideo.org]
%%% @copyright  2010 Max Lapshin
%%% @doc        main erlyvideo module
%%% @reference  See <a href="http://erlyvideo.org" target="_top">http://erlyvideo.org</a> for more information
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
-module(erlyvideo).
-author('Max Lapshin <max@maxidoors.ru>').
-include("log.hrl").


-export([start/2, stop/1]).
-export([start/0,stop/0,restart/0,rebuild/0,reload/0,reload/1,upgrade/0]).
-export([load_config/0, reconfigure/0]).
-export([start_modules/0, stop_modules/0]).
-export([call_modules/2]).
-export([stats/1]).
-export([vhosts/0]).
-export([main/1, test/0]).


main([]) ->
  ok = start(),
  Ref = erlang:monitor(process, whereis(ems_sup)),
  {ok, EscriptFiles} = ems_file:load_escript_files(),
  application:set_env(erlyvideo, escript_files, EscriptFiles),
  receive
    {'DOWN', Ref, process, _Client, _Reason} -> ok
  end.


test() ->
  % ems_network_lag_monitor,
  % ems_media,
  % ems_media_clients,
  
  eunit:test([
    ems,
    amf0_tests,
    amf3_tests,
    aac,
    h264,
    mp4,
    mp4_writer,
    flv_video_frame,
    sdp,
    rtp_decoder,
    http_uri2,
    packet_codec,
    srt_parser,
    mpeg2_crc32,
    mpegts_reader,
    rtmp,
    rtmp_handshake,
    rtsp,
    mpegts_reader,
    mpegts_psi,
    ems_media_clients,
    ems_media_timeout_tests,
    ems_media_flow_tests,
    ems_test_file_reading,
    mpegts_encode_tests,
    rtmp_publish_tests,
    % ems_license_client,
    rtmp_read_tests,
    rtmp_cookie
  ]).


upgrade() ->
  Paths = filelib:wildcard("/opt/erlyvideo/lib/*/ebin"),
  OldPaths = code:get_path(),
  NewPaths = lists:filter(fun(Path) ->
    not lists:member(Path, OldPaths)
  end, Paths),
  [code:add_patha(Path) || Path <- NewPaths],
  ems:reload(amf),
  ems:reload(erlmedia),
  ems:reload(erlyvideo),
  ems:reload(ibrowse),
  ems:reload(log4erl),
  ems:reload(misultin),
  ems:reload(mpegts),
  ems:reload(rtmp),
  ems:reload(rtp),
  ems:reload(rtsp).


start(normal, []) ->
	error_logger:info_report("Starting Erlyvideo ..."),
  LicenseReply = ems_license_client:load(),
  ems_log:start(),
  set_logging_function(erlmedia),
  set_logging_function(mpegts),
  set_logging_function(rtmp),
  set_logging_function(rtsp),
  set_logging_function(rtp),
	load_config(),
  load_script_paths(),
	lists:foreach(fun(PluginPath) ->
  	[code:add_pathz(Path) || Path <- filelib:wildcard(PluginPath++"/*/ebin")]
	end, ems:get_var(paths, [])),
	[code:add_pathz(Path) || Path <- ems:get_var(paths, [])],
  [code:add_pathz(Path) || Path <- filelib:wildcard("plugins/*/ebin")],
  ems_vhosts:start(),
  {ok, Supervisor} = ems_sup:start_link(),
  start_http(),
  start_rtmp(),
	start_modules(),
	load_plugin_files(),
	ems_rtsp:start(),
  media_provider:start_static_streams(),
	error_logger:info_report("Started Erlyvideo"),
	case LicenseReply of
	  {ok, LicenseClient} -> ems_license_client:afterload(LicenseClient);
	  _ -> ok
	end,
  error_logger:delete_report_handler(sasl_report_tty_h),
  error_logger:delete_report_handler(sasl_report_file_h),
	{ok, Supervisor}.

stop(_) ->
  %stop().
  ok.


vhosts() ->
  [Host || {Host, _} <- ems:get_var(vhosts, [])].

%%--------------------------------------------------------------------
%% @spec () -> any()
%% @doc Starts Erlyvideo
%% @end
%%--------------------------------------------------------------------

start() ->
  application:load(erlyvideo),
  {ok, Apps} = application:get_key(erlyvideo, applications),
  [application:start(App) || App <- Apps],
	application:start(erlyvideo).

start_http() ->
  case ems:get_var(http_port, 8082) of
    undefined ->
      ok;
    HTTP ->
      ems_sup:start_http_server(HTTP)
  end.


set_logging_function(Application) ->
  application:set_env(Application, logging_function, fun(M, L, X) ->
    ems_log:debug(3, Application, "~p:~p ~240p",[M, L, X])
  end).
  

start_rtmp() ->
  case ems:get_var(rtmp_port, 1935) of
    undefined ->
      ok;
    RTMP ->
      rtmp_socket:start_server(RTMP, rtmp_listener1, ems_rtmp)
  end.


load_plugin_files() ->
  PluginPath = "plugins",
  [begin
    Plugin = filename:basename(Path,".beam"),
    error_logger:info_msg("Load plugin ~s", [Plugin]),
    code:load_abs(PluginPath ++ "/"++ Plugin)
  end || Path <- filelib:wildcard(PluginPath++"/*.beam")].

stats(Host) ->
  Entries = lists:sort(fun({Name1, _, _}, {Name2, _, _}) -> Name1 < Name2 end, media_provider:entries(Host)),
  Streams = [{object, [{name,Name}, {count, proplists:get_value(client_count, Options)}]} || {Name, _Pid, Options} <- Entries],
  CPULoad = {object, [{avg1, cpu_sup:avg1() / 256}, {avg5, cpu_sup:avg5() / 256}, {avg15, cpu_sup:avg15() / 256}]},
  % RTMPTraf = [{object, Info} || Info <- rtmp_stat_collector:stats()],
  RTMPTraf = [{object, []}],
  FixStats = fun(List) ->
    [begin
      {Key, if
        Value == undefined -> null;
        is_atom(Value) -> atom_to_binary(Value, utf8);
        is_list(Value) -> list_to_binary(Value);
        true -> Value
      end}
    end || {Key,Value} <- List]
  end,
  Users = [{object, FixStats(Stat)} || {_Pid, Stat} <- rtmp_session:collect_stats(Host)],
  Stats = [{streams,Streams},{cpu,CPULoad},{rtmp,RTMPTraf},{users,Users}],
  {object, Stats}.
  


%%--------------------------------------------------------------------
%% @spec () -> any()
%% @doc Stops Erlyvideo
%% @end
%%--------------------------------------------------------------------
stop() ->
	io:format("Stopping Erlyvideo ...~n"),
  ems_vhosts:stop(),
	stop_modules(),
	application:stop(erlyvideo),
	application:stop(rtmp),
  ems_log:stop(),
	ok.

%%--------------------------------------------------------------------
%% @spec () -> any()
%% @doc Stops, Compiles , Reloads and starts Erlyvideo
%% @end
%%--------------------------------------------------------------------
restart() ->
	stop(),
	rebuild(),
	reload(),
	start().


reconfigure() ->
  RTMP = ems:get_var(rtmp_port, undefined),
  HTTP = ems:get_var(http_port, undefined),
  % ems_vhosts:stop(),
  ems_event:stop_handlers(),
  ems_log:stop(),
  ems_log:start(),
  load_config(),
  ems_vhosts:start(),
  ems_event:start_handlers(),
  % ems_http:stop(),
  case {RTMP, ems:get_var(rtmp_port, undefined)} of
    {undefined, undefined} -> ok;
    {RTMP, RTMP} -> ok;
    {undefined, _} ->
      {ok, _} = start_rtmp();
    _ ->
      supervisor:terminate_child(rtmp_sup, rtmp_listener1),
      supervisor:delete_child(rtmp_sup, rtmp_listener1),
      {ok, _} = start_rtmp()
  end,
  case {HTTP, ems:get_var(http_port, undefined)} of
    {undefined, _} -> ok;
    {HTTP, HTTP} -> ok;
    _ ->
      ems_http:stop()
  end,
  ok.

load_config() ->

  File = load_file_config(),
  % Dets = load_persistent_config(),
  % Env = deep_merge(File, Dets),
  Env = File,
  [application:set_env(erlyvideo, Key, Value) || {Key, Value} <- Env],
  ok.

load_script_paths() ->
  application:load(elixir),
  Paths = ems:get_var(script_paths, ["scripts", "/opt/erlyvideo/scripts", "/etc/erlyvideo/scripts"]),
  Paths1 = [{filename:absname(Path), Path} || Path <- Paths],
  Paths2 = [Path || {_FullPath, Path} <- lists:ukeysort(1, Paths1)],
  application:set_env(elixir, paths, Paths2).

load_file_config() ->
  case file:path_consult(["priv", "etc", "/etc/erlyvideo"], "erlyvideo.conf") of
    {ok, Env, Path} ->
      error_logger:info_report("Erlyvideo is loading config from file ~s~n", [Path]),
      Env;
    {error, enoent} ->
      case file:path_consult(["priv", "etc"], "erlyvideo.conf.sample") of
        {ok, Env, Path} ->
          error_logger:info_report("No erlyvideo.conf found, starting with sample: ~s~n", [Path]),
          Env;
        {error, _} ->
          error_logger:error_msg("No erlyvideo.conf found"),
          []
      end;
    {error, Reason} ->
      error_logger:error_msg("Couldn't load erlyvideo.conf: ~p~n", [Reason]),
      []
  end.


% load_persistent_config() ->
%   load_persistent_config(["priv", "/var/lib/erlyvideo"]).
%
% load_persistent_config([]) ->
%   [];
%
% load_persistent_config([Path|Paths]) ->
%   case file:read_file_info(Path) of
%     {ok, _FileInfo} ->
%       case dets:is_dets_file(Path) of
%         true ->
%           {ok, Config} = dets:open_file("erlyvideo_config", [{file, Path}]),
%           [Entry || [Entry] <- dets:match(Config, '$1')];
%         false ->
%           []
%       end;
%     {error, _} ->
%       load_persistent_config(Paths)
%   end.
%
% deep_merge(List1, List2) ->
%   deep_merge(lists:ukeysort(1, List1), lists:ukeysort(1, List2), []).
%
% % TODO: implement real deep merge for erlyvideo
% deep_merge(List1, _, _) ->
%   List1.

%%--------------------------------------------------------------------
%% @spec () -> any()
%% @doc Compiles Erlyvideo
%% @end
%%--------------------------------------------------------------------
rebuild() ->
	io:format("Recompiling EMS Modules ...~n"),
	make:all([load]).


%%--------------------------------------------------------------------
%% @spec () -> any()
%% @doc Compiles and reloads Erlyvideo modules
%% @end
%%--------------------------------------------------------------------
reload() ->
  reload(erlyvideo).

reload(App) ->
	application:load(App),
	case application:get_key(App,modules) of
		undefined ->
			ok;
		{ok,Modules} ->
			io:format("Reloading ~p Modules: ~p~n", [App, Modules]),
			reload_mods(lists:usort(Modules))
	end.

reload_mod(Module) when is_atom(Module) ->
	code:soft_purge(Module),
	code:purge(Module),
	code:load_file(Module),
	true.

reload_mods([]) -> ok;
reload_mods([?MODULE | T]) -> reload(T);
reload_mods([H|T]) ->
	reload_mod(H),
	reload_mods(T).


%%--------------------------------------------------------------------
%% @spec () -> ok | {error, Reason}
%% @doc Initializes all modules
%% @end
%%--------------------------------------------------------------------
start_modules() -> call_modules(start, []).

call_modules(Function, Args) -> call_modules(Function, Args, ems:get_var(modules, [])).

call_modules(_, _, []) ->
  ok;
call_modules(Function, Args, [Module|Modules]) ->
  case ems:respond_to(Module, Function, length(Args)) of
    true ->
      ok = erlang:apply(Module, Function, Args);
    _ ->
      ok
  end,
  call_modules(Function, Args, Modules).


%%--------------------------------------------------------------------
%% @spec () -> ok | {error, Reason}
%% @doc Shutdown all modules
%% @end
%%--------------------------------------------------------------------
stop_modules() -> io:format("Stopping modules: ~p~n", [ems:get_var(modules, [])]), call_modules(stop, []).




