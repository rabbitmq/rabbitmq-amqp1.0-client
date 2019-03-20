%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License at
%% https://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%% License for the specific language governing rights and limitations
%% under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2017 Pivotal Software, Inc.  All rights reserved.
%%

-module(amqp10_client_connection).

-behaviour(gen_fsm).

-include("amqp10_client.hrl").
-include_lib("amqp10_common/include/amqp10_framing.hrl").

-ifdef(nowarn_deprecated_gen_fsm).
-compile({nowarn_deprecated_function,
          [{gen_fsm, reply, 2},
           {gen_fsm, send_all_state_event, 2},
           {gen_fsm, send_event, 2},
           {gen_fsm, start_link, 3},
           {gen_fsm, sync_send_all_state_event, 2}]}).
-endif.

%% Public API.
-export([open/1,
         close/2]).

%% Private API.
-export([start_link/2,
         socket_ready/2,
         protocol_header_received/5,
         begin_session/1,
         heartbeat/1]).

%% gen_fsm callbacks.
-export([init/1,
         handle_event/3,
         handle_sync_event/4,
         handle_info/3,
         terminate/3,
         code_change/4]).

%% gen_fsm state callbacks.
-export([expecting_socket/2,
         sasl_hdr_sent/2,
         sasl_hdr_rcvds/2,
         sasl_init_sent/2,
         hdr_sent/2,
         open_sent/2,
         opened/2,
         close_sent/2]).

-type amqp10_socket() :: {tcp, gen_tcp:socket()} | {ssl, ssl:socket()}.

-type milliseconds() :: non_neg_integer().

-type connection_config() ::
    #{container_id => binary(), % AMQP container id
      hostname => binary(), % the dns name of the target host
      address => inet:socket_address() | inet:hostname(),
      port => inet:port_number(),
      tls_opts => {secure_port, [ssl:ssl_option()]},
      notify => pid(), % the pid to send connection events to
      max_frame_size => non_neg_integer(), % TODO: constrain to large than 512
      outgoing_max_frame_size => non_neg_integer() | undefined,
      idle_time_out => milliseconds(),
      % set to a negative value to allow a sender to "overshoot" the flow
      % control by this margin
      transfer_limit_margin => 0 | neg_integer(),
      sasl => none | anon | {plain, User :: binary(), Pwd :: binary()}
  }.

-record(state,
        {next_channel = 1 :: pos_integer(),
         connection_sup :: pid(),
         reader_m_ref :: reference() | undefined,
         sessions_sup :: pid() | undefined,
         pending_session_reqs = [] :: [term()],
         reader :: pid() | undefined,
         socket :: amqp10_socket() | undefined,
         idle_time_out :: non_neg_integer() | undefined,
         heartbeat_timer :: timer:tref() | undefined,
         config :: connection_config()
        }).

-export_type([connection_config/0,
              amqp10_socket/0]).

-define(DEFAULT_TIMEOUT, 5000).

%% -------------------------------------------------------------------
%% Public API.
%% -------------------------------------------------------------------

-spec open(connection_config()) -> supervisor:startchild_ret().
open(Config) ->
    %% Start the supervision tree dedicated to that connection. It
    %% starts at least a connection process (the PID we want to return)
    %% and a reader process (responsible for opening and reading the
    %% socket).
    case supervisor:start_child(amqp10_client_sup, [Config]) of
        {ok, ConnSup} ->
            %% We query the PIDs of the connection and reader processes. The
            %% reader process needs to know the connection PID to send it the
            %% socket.
            Children = supervisor:which_children(ConnSup),
            {_, Reader, _, _} = lists:keyfind(reader, 1, Children),
            {_, Connection, _, _} = lists:keyfind(connection, 1, Children),
            {_, SessionsSup, _, _} = lists:keyfind(sessions, 1, Children),
            set_other_procs(Connection, #{sessions_sup => SessionsSup,
                                          reader => Reader}),
            {ok, Connection};
        Error ->
            Error
    end.

-spec close(pid(), {amqp10_client_types:amqp_error()
                   | amqp10_client_types:connection_error(), binary()} | none) -> ok.
close(Pid, Reason) ->
    gen_fsm:send_event(Pid, {close, Reason}).

%% -------------------------------------------------------------------
%% Private API.
%% -------------------------------------------------------------------

start_link(Sup, Config) ->
    gen_fsm:start_link(?MODULE, [Sup, Config], []).

set_other_procs(Pid, OtherProcs) ->
    gen_fsm:send_all_state_event(Pid, {set_other_procs, OtherProcs}).

-spec socket_ready(pid(), amqp10_socket()) -> ok.
socket_ready(Pid, Socket) ->
    gen_fsm:send_event(Pid, {socket_ready, Socket}).

-spec protocol_header_received(pid(), 0 | 3, non_neg_integer(),
                               non_neg_integer(), non_neg_integer()) -> ok.
protocol_header_received(Pid, Protocol, Maj, Min, Rev) ->
    gen_fsm:send_event(Pid, {protocol_header_received, Protocol, Maj, Min, Rev}).

-spec begin_session(pid()) -> supervisor:startchild_ret().
begin_session(Pid) ->
    gen_fsm:sync_send_all_state_event(Pid, begin_session).

heartbeat(Pid) ->
    gen_fsm:send_event(Pid, heartbeat).

%% -------------------------------------------------------------------
%% gen_fsm callbacks.
%% -------------------------------------------------------------------

init([Sup, Config0]) ->
    process_flag(trap_exit, true),
    Config = maps:merge(config_defaults(), Config0),
    {ok, expecting_socket, #state{connection_sup = Sup,
                                  config = Config}}.

expecting_socket({socket_ready, Socket}, State = #state{config = Cfg}) ->
    State1 = State#state{socket = Socket},
    case Cfg of
        #{sasl := none} ->
            ok = socket_send(Socket, ?AMQP_PROTOCOL_HEADER),
            {next_state, hdr_sent, State1};
        _ ->
            ok = socket_send(Socket, ?SASL_PROTOCOL_HEADER),
            {next_state, sasl_hdr_sent, State1}
    end.

sasl_hdr_sent({protocol_header_received, 3, 1, 0, 0}, State) ->
    {next_state, sasl_hdr_rcvds, State}.

sasl_hdr_rcvds(#'v1_0.sasl_mechanisms'{
                  sasl_server_mechanisms = {array, symbol, Mechs}},
               State = #state{config = #{sasl := Sasl}}) ->
    SaslBin = {symbol, sasl_to_bin(Sasl)},
    case lists:any(fun(S) when S =:= SaslBin -> true;
                      (_) -> false
                   end, Mechs) of
        true ->
            ok = send_sasl_init(State, Sasl),
            {next_state, sasl_init_sent, State};
        false ->
            {stop, {sasl_not_supported, Sasl}, State}
    end.

sasl_init_sent(#'v1_0.sasl_outcome'{code = {ubyte, 0}},
               #state{socket = Socket} = State) ->
    ok = socket_send(Socket, ?AMQP_PROTOCOL_HEADER),
    {next_state, hdr_sent, State};
sasl_init_sent(#'v1_0.sasl_outcome'{code = {ubyte, 1}},
               #state{} = State) ->
    {stop, sasl_auth_failure, State}.

hdr_sent({protocol_header_received, 0, 1, 0, 0}, State) ->
    case send_open(State) of
        ok    -> {next_state, open_sent, State};
        Error -> {stop, Error, State}
    end;
hdr_sent({protocol_header_received, Protocol, Maj, Min,
                                Rev}, State) ->
    error_logger:warning_msg("Unsupported protocol version: ~b ~b.~b.~b~n",
                             [Protocol, Maj, Min, Rev]),
    {stop, normal, State}.

open_sent(#'v1_0.open'{max_frame_size = MFSz, idle_time_out = Timeout},
          #state{pending_session_reqs = PendingSessionReqs,
                 config = Config} = State0) ->
    State = case Timeout of
                undefined -> State0;
                {uint, T} when T > 0 ->
                    {ok, Tmr} = start_heartbeat_timer(T div 2),
                    State0#state{idle_time_out = T div 2,
                                 heartbeat_timer = Tmr};
                _ -> State0
            end,
    State1 = State#state{config =
                         Config#{outgoing_max_frame_size => unpack(MFSz)}},
    State2 = lists:foldr(
               fun(From, S0) ->
                       {Ret, S2} = handle_begin_session(From, S0),
                       _ = gen_fsm:reply(From, Ret),
                       S2
               end, State1, PendingSessionReqs),
    ok = notify_opened(Config),
    {next_state, opened, State2}.

opened(heartbeat, State = #state{idle_time_out = T}) ->
    ok = send_heartbeat(State),
    {ok, Tmr} = start_heartbeat_timer(T),
    {next_state, opened, State#state{heartbeat_timer = Tmr}};
opened({close, Reason}, State = #state{config = Config}) ->
    %% We send the first close frame and wait for the reply.
    %% TODO: stop all sessions writing
    %% We could still accept incoming frames (See: 2.4.6)
    ok = notify_closed(Config, Reason),
    case send_close(State, Reason) of
        ok              -> {next_state, close_sent, State};
        {error, closed} -> {stop, normal, State};
        Error           -> {stop, Error, State}
    end;
opened(#'v1_0.close'{error = Error}, State = #state{config = Config}) ->
    %% We receive the first close frame, reply and terminate.
    ok = notify_closed(Config, translate_err(Error)),
    _ = send_close(State, none),
    {stop, normal, State};
opened(Frame, State) ->
    error_logger:warning_msg("Unexpected connection frame ~p when in state ~p ~n",
                             [Frame, State]),
    {next_state, opened, State}.

close_sent(#'v1_0.close'{}, State) ->
    % TODO: we should probably set up a timer before this to ensure
    % we close down event if no reply is received

    error_logger:info_msg("Conn close_sent Close received ~n", []),
    {stop, normal, State}.

handle_event({set_other_procs, OtherProcs}, StateName, State) ->
    #{sessions_sup := SessionsSup,
      reader := Reader} = OtherProcs,
    ReaderMRef = monitor(process, Reader),
    amqp10_client_frame_reader:set_connection(Reader, self()),
    State1 = State#state{sessions_sup = SessionsSup,
                         reader_m_ref = ReaderMRef,
                         reader = Reader},
    {next_state, StateName, State1};
handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event(begin_session, From, opened, State) ->
    {Ret, State1} = handle_begin_session(From, State),
    {reply, Ret, opened, State1};
handle_sync_event(begin_session, From, StateName,
                  #state{pending_session_reqs = PendingSessionReqs} = State)
  when StateName =/= close_sent ->
    %% The caller already asked for a new session but the connection
    %% isn't fully opened. Let's queue this request until the connection
    %% is ready.
    State1 = State#state{pending_session_reqs = [From | PendingSessionReqs]},
    {next_state, StateName, State1};
handle_sync_event(begin_session, _From, StateName, State) ->
    {reply, {error, connection_closed}, StateName, State};
handle_sync_event(_Event, _From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.

handle_info({'DOWN', MRef, _, _, Info}, StateName, State = #state{reader_m_ref = MRef,
                                                                  config = Config})
  when StateName =/= close_sent ->
    % reader has gone down and we are not already shutting down
    ok = notify_closed(Config, shutdown),
    error_logger:info_msg("Conn received DOWN from Reader ~p ~p~n", [Info, StateName]),
    {stop, normal, State};
handle_info(Info, StateName, State) ->
    error_logger:info_msg("Conn handle_info ~p ~p~n", [Info, StateName]),
    {next_state, StateName, State}.

terminate(Reason, _StateName, #state{connection_sup = Sup,
                                     config = Config}) ->
    error_logger:warning_msg("terminating connection with '~p'~n", [Reason]),
    ok = notify_closed(Config, Reason),
    case Reason of
        normal -> sys:terminate(Sup, normal);
        _      -> ok
    end,
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%% -------------------------------------------------------------------
%% Internal functions.
%% -------------------------------------------------------------------

handle_begin_session({FromPid, _Ref},
                     #state{sessions_sup = Sup, reader = Reader,
                            next_channel = Channel,
                            config = Config} = State) ->
    Ret = supervisor:start_child(Sup, [FromPid, Channel, Reader, Config]),
    State1 = case Ret of
                 {ok, _} -> State#state{next_channel = Channel + 1};
                 _       -> State
             end,
    {Ret, State1}.

send_open(#state{socket = Socket, config = Config}) ->
    {ok, Product} = application:get_key(description),
    {ok, Version} = application:get_key(vsn),
    Platform = "Erlang/OTP " ++ erlang:system_info(otp_release),
    Props = {map, [{{symbol, <<"product">>},
                    {utf8, list_to_binary(Product)}},
                   {{symbol, <<"version">>},
                    {utf8, list_to_binary(Version)}},
                   {{symbol, <<"platform">>},
                    {utf8, list_to_binary(Platform)}}
                  ]},
    ContainerId = maps:get(container_id, Config, generate_container_id()),
    IdleTimeOut = maps:get(idle_time_out, Config, 0),
    Open0 = #'v1_0.open'{container_id = {utf8, ContainerId},
                         channel_max = {ushort, 100},
                         idle_time_out = {uint, IdleTimeOut},
                         properties = Props},
    Open1 = case Config of
               #{max_frame_size := MFSz} ->
                   Open0#'v1_0.open'{max_frame_size = {uint, MFSz}};
               _ -> Open0
           end,
    Open = case Config of
               #{hostname := Hostname} ->
                   Open1#'v1_0.open'{hostname = {utf8, Hostname}};
               _ -> Open1
           end,
    Encoded = amqp10_framing:encode_bin(Open),
    Frame = amqp10_binary_generator:build_frame(0, Encoded),
    ?DBG("CONN <- ~p~n", [Open]),
    socket_send(Socket, Frame).


send_close(#state{socket = Socket}, _Reason) ->
    Close = #'v1_0.close'{},
    Encoded = amqp10_framing:encode_bin(Close),
    Frame = amqp10_binary_generator:build_frame(0, Encoded),
    ?DBG("CONN <- ~p~n", [Close]),
    Ret = socket_send(Socket, Frame),
    case Ret of
        ok -> _ =
              socket_shutdown(Socket, write),
              ok;
        _  -> ok
    end,
    Ret.

send_sasl_init(State, anon) ->
    Frame = #'v1_0.sasl_init'{mechanism = {symbol, <<"ANONYMOUS">>}},
    send(Frame, 1, State);
send_sasl_init(State, {plain, User, Pass}) ->
    Response = <<0:8, User/binary, 0:8, Pass/binary>>,
    Frame = #'v1_0.sasl_init'{mechanism = {symbol, <<"PLAIN">>},
                              initial_response = {binary, Response}},
    send(Frame, 1, State).

send(Record, FrameType, #state{socket = Socket}) ->
    Encoded = amqp10_framing:encode_bin(Record),
    Frame = amqp10_binary_generator:build_frame(0, FrameType, Encoded),
    ?DBG("CONN <- ~p~n", [Record]),
    socket_send(Socket, Frame).

send_heartbeat(#state{socket = Socket}) ->
    Frame = amqp10_binary_generator:build_heartbeat_frame(),
    socket_send(Socket, Frame).

socket_send({tcp, Socket}, Data) ->
    gen_tcp:send(Socket, Data);
socket_send({ssl, Socket}, Data) ->
    ssl:send(Socket, Data).

socket_shutdown({tcp, Socket}, Data) ->
    gen_tcp:shutdown(Socket, Data);
socket_shutdown({ssl, Socket}, Data) ->
    ssl:shutdown(Socket, Data).

notify_opened(#{notify := Pid}) ->
    Pid ! amqp10_event(opened),
    ok.

notify_closed(#{notify := Pid}, Reason) ->
    Pid ! amqp10_event({closed, Reason}),
    ok.

start_heartbeat_timer(Timeout) ->
    timer:apply_after(Timeout, ?MODULE, heartbeat, [self()]).

unpack(V) -> amqp10_client_types:unpack(V).

-spec generate_container_id() -> binary().
generate_container_id() ->
    Pre = list_to_binary(atom_to_list(node())),
    Id = bin_to_hex(crypto:strong_rand_bytes(8)),
    <<Pre/binary, <<"_">>/binary, Id/binary>>.

bin_to_hex(Bin) ->
    <<<<if N >= 10 -> N -10 + $a;
           true  -> N + $0 end>>
      || <<N:4>> <= Bin>>.

translate_err(undefined) ->
    none;
translate_err(#'v1_0.error'{condition = Cond, description = Desc}) ->
    Err =
        case Cond of
            ?V_1_0_AMQP_ERROR_INTERNAL_ERROR -> internal_error;
            ?V_1_0_AMQP_ERROR_NOT_FOUND -> not_found;
            ?V_1_0_AMQP_ERROR_UNAUTHORIZED_ACCESS -> unauthorized_access;
            ?V_1_0_AMQP_ERROR_DECODE_ERROR -> decode_error;
            ?V_1_0_AMQP_ERROR_RESOURCE_LIMIT_EXCEEDED -> resource_limit_exceeded;
            ?V_1_0_AMQP_ERROR_NOT_ALLOWED -> not_allowed;
            ?V_1_0_AMQP_ERROR_INVALID_FIELD -> invalid_field;
            ?V_1_0_AMQP_ERROR_NOT_IMPLEMENTED -> not_implemented;
            ?V_1_0_AMQP_ERROR_RESOURCE_LOCKED -> resource_locked;
            ?V_1_0_AMQP_ERROR_PRECONDITION_FAILED -> precondition_failed;
            ?V_1_0_AMQP_ERROR_RESOURCE_DELETED -> resource_deleted;
            ?V_1_0_AMQP_ERROR_ILLEGAL_STATE -> illegal_state;
            ?V_1_0_AMQP_ERROR_FRAME_SIZE_TOO_SMALL -> frame_size_too_small;
            ?V_1_0_CONNECTION_ERROR_CONNECTION_FORCED -> forced;
            ?V_1_0_CONNECTION_ERROR_FRAMING_ERROR -> framing_error;
            ?V_1_0_CONNECTION_ERROR_REDIRECT -> redirect;
            _ -> Cond
        end,
    {Err, unpack(Desc)}.

amqp10_event(Evt) ->
    {amqp10_event, {connection, self(), Evt}}.

sasl_to_bin({plain, _, _}) -> <<"PLAIN">>;
sasl_to_bin(anon) -> <<"ANONYMOUS">>.

config_defaults() ->
    #{sasl => none,
      transfer_limit_margin => 0,
      max_frame_size => ?MAX_MAX_FRAME_SIZE}.
