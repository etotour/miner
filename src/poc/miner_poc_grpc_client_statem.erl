-module(miner_poc_grpc_client_statem).
-behavior(gen_statem).

%%-dialyzer({nowarn_function, process_unary_response/1}).
%%-dialyzer({nowarn_function, handle_info/2}).
%%-dialyzer({nowarn_function, build_config_req/1}).


-include("src/grpc/autogen/client/gateway_miner_client_pb.hrl").
-include_lib("public_key/include/public_key.hrl").
-include_lib("helium_proto/include/blockchain_txn_vars_v1_pb.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/0,
    connection/0,
    check_target/6,
    send_report/3,
    region_params/0,
    update_config/1
]).

%% ------------------------------------------------------------------
%% gen_statem Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    callback_mode/0,
    terminate/2
]).

%% ------------------------------------------------------------------
%% record defs and macros
%% ------------------------------------------------------------------
-record(data, {
    self_pub_key_bin,
    self_sig_fun,
    connection,
    connection_pid,
    conn_monitor_ref,
    stream_poc_pid,
    stream_poc_monitor_ref,
    stream_config_update_pid,
    stream_config_update_monitor_ref,
    val_p2p_addr,
    val_public_ip,
    val_grpc_port
}).

%% these are config vars the miner is interested in, if they change we
%% will want to get their latest values
-define(CONFIG_VARS, ["poc_version", "data_aggregation_version"]).

%% delay between validator reconnects attempts
-define(VALIDATOR_RECONNECT_DELAY, 5000).
%% delay between stream reconnects attempts
-define(STREAM_RECONNECT_DELAY, 5000).

-type data() :: #data{}.

%% ------------------------------------------------------------------
%% gen_statem callbacks Exports
%% ------------------------------------------------------------------
-export([
    setup/3,
    connected/3
]).

%% ------------------------------------------------------------------
%% API Definitions
%% ------------------------------------------------------------------
-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_statem:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec connection() -> {ok, grpc_client_custom:connection()}.
connection() ->
    gen_statem:call(?MODULE, connection, infinity).

-spec region_params() -> {error, any()} | {error, any(), map()} | {ok, #gateway_poc_region_params_resp_v1_pb{}, map()}.
region_params() ->
    gen_statem:call(?MODULE, region_params, 15000).

-spec check_target(string(), libp2p_crypto:pubkey_bin(), binary(), binary(), non_neg_integer(), libp2p_crypto:signature()) -> {error, any()} | {error, any(), map()} | {ok, any(), map()}.
check_target(ChallengerURI, ChallengerPubKeyBin, OnionKeyHash, BlockHash, NotificationHeight, ChallengerSig) ->
    gen_statem:call(?MODULE, {check_target, ChallengerURI, ChallengerPubKeyBin, OnionKeyHash, BlockHash, NotificationHeight, ChallengerSig}, 15000).

-spec send_report(witness | receipt, any(), binary()) -> ok.
send_report(ReportType, Report, OnionKeyHash)->
    gen_statem:cast(?MODULE, {send_report, ReportType, Report, OnionKeyHash}).

-spec update_config([string()]) -> ok.
update_config(UpdatedKeys)->
    gen_statem:cast(?MODULE, {update_config, UpdatedKeys}).

%% ------------------------------------------------------------------
%% gen_statem Definitions
%% ------------------------------------------------------------------
init(_Args) ->
    lager:info("starting ~p", [?MODULE]),
    SelfPubKeyBin = blockchain_swarm:pubkey_bin(),
    {ok, _, SigFun, _} = blockchain_swarm:keys(),
    {ok, setup, #data{self_pub_key_bin = SelfPubKeyBin, self_sig_fun = SigFun}}.

callback_mode() -> [state_functions,state_enter].

terminate(_Reason, Data) ->
    ok = disconnect(Data),
    ok.

%% ------------------------------------------------------------------
%% gen_statem callbacks
%% ------------------------------------------------------------------
setup(enter, _OldState, Data)->
    %% each time we enter connecting_validator state we assume we are initiating a new
    %% connection to a durable validators
    %% thus ensure all streams are disconnected
    ok = disconnect(Data),
    erlang:send_after(?VALIDATOR_RECONNECT_DELAY, self(), find_validator),
    {keep_state,
        Data#data{val_public_ip = undefined, val_grpc_port = undefined, val_p2p_addr = undefined}};
setup(info, find_validator, Data) ->
    %% ask a random seed validator for the address of a 'proper' validator
    %% we will then use this as our default durable validator
    case find_validator() of
        {error, _Reason} ->
            {repeat_state, Data};
        {ok, ValIP, ValPort, ValP2P} ->
            {keep_state,
                Data#data{val_public_ip = ValIP, val_grpc_port = ValPort, val_p2p_addr = ValP2P},
                [{next_event, info, connect_validator}]}
    end;
setup(info, connect_validator, #data{val_public_ip = ValIP, val_grpc_port = ValGRPCPort, val_p2p_addr = ValP2P} = Data) ->
    %% connect to our durable validator
    case connect_validator(ValP2P, ValIP, ValGRPCPort) of
        {ok, Connection} ->
            #{http_connection := ConnectionPid} = Connection,
            M = erlang:monitor(process, ConnectionPid),
            {keep_state,
                Data#data{connection = Connection, connection_pid = ConnectionPid, conn_monitor_ref = M},
                [{next_event, info, fetch_config}]};
        {error, _} ->
            {repeat_state, Data}
    end;
setup(info, fetch_config, #data{val_public_ip = ValIP, val_grpc_port = ValGRPCPort} = Data) ->
    %% get necessary config data from our durable validator
    case fetch_config(?CONFIG_VARS, ValIP, ValGRPCPort) of
        ok ->
            {keep_state, Data, [{next_event, info, connect_poc_stream}]};
        {error, _} ->
            {repeat_state, Data}
    end;
setup(info, connect_poc_stream, #data{connection = Connection, self_pub_key_bin = SelfPubKeyBin, self_sig_fun = SelfSigFun} = Data) ->
    %% connect any required streams
    %% we are interested in two streams, poc events and config change events
    case connect_stream_poc(Connection, SelfPubKeyBin, SelfSigFun) of
        {ok, StreamPid} ->
            M = erlang:monitor(process, StreamPid),
            {keep_state,
                Data#data{stream_poc_monitor_ref = M, stream_poc_pid = StreamPid},
                [{next_event, info, connect_config_stream}]};
        {error, _} ->
            {repeat_state, Data}
    end;
setup(info, connect_config_stream, #data{connection = Connection} = Data) ->
    %% connect any required streams
    %% we are interested in two streams, poc events and config change events
    case connect_stream_config_update(Connection) of
        {ok, StreamPid} ->
            M = erlang:monitor(process, StreamPid),
            {next_state, connected,
                Data#data{stream_config_update_monitor_ref = M, stream_config_update_pid = StreamPid}};
        {error, _} ->
            {repeat_state, Data}
    end;
setup(info, {'DOWN', _Ref, process, _, _Reason} = Event, Data) ->
    %% handle down msgs, such as from our streams or validator connection
    handle_down_event(setup, Event, Data);
setup({call, From}, _Msg, Data) ->
    %% return an error for any call msgs whilst in setup state
    {keep_state, Data, [{reply, From, {error, grpc_client_not_ready}}]};
setup(_EventType, _Msg, Data) ->
    %% ignore ev things else whist in setup state
    lager:info("unhandled event whilst in ~p state: Type: ~p, Msg: ~p", [setup, _EventType, _Msg]),
    {keep_state, Data}.

connected(enter, _OldState, Data)->
    {keep_state, Data};
connected(cast, {send_report, ReportType, Report, OnionKeyHash}, #data{connection = Connection, self_sig_fun = SelfSigFun} = Data) ->
    lager:info("send_report ~p with onionkeyhash ~p: ~p", [ReportType, OnionKeyHash, Report]),
    ok = send_report(ReportType, Report, OnionKeyHash, SelfSigFun, Connection),
    {keep_state, Data};
connected(cast, {update_config, Keys}, #data{val_public_ip = ValIP, val_grpc_port = ValPort} = Data) ->
    lager:info("update_config for keys ~p", [Keys]),
    _ = fetch_config(Keys, ValIP, ValPort),
    {keep_state, Data};
connected({call, From}, connection, #data{connection = Connection} = Data) ->
    {keep_state, Data, [{reply, From, {ok, Connection}}]};
connected({call, From}, region_params, #data{self_pub_key_bin = SelfPubKeyBin, self_sig_fun = SelfSigFun, connection = Connection} = Data) ->
    Req = build_region_params_req(SelfPubKeyBin, SelfSigFun),
    Resp = send_grpc_unary_req(Connection, Req, 'region_params'),
    {keep_state, Data, [{reply, From, Resp}]};
connected({call, From}, {check_target, ChallengerURI, ChallengerPubKeyBin, OnionKeyHash, BlockHash, NotificationHeight, ChallengerSig}, #data{self_pub_key_bin = SelfPubKeyBin, self_sig_fun = SelfSigFun} = Data) ->
    %% split the URI into its IP and port parts
    #{host := IP, port := Port, scheme := _Scheme} = uri_string:parse(ChallengerURI),
    TargetIP = maybe_override_ip(IP),
    %% build the request
    Req = build_check_target_req(ChallengerPubKeyBin, OnionKeyHash,
        BlockHash, NotificationHeight, ChallengerSig, SelfPubKeyBin, SelfSigFun),
    Resp = send_grpc_unary_req(TargetIP, Port, Req, 'check_challenge_target'),
    {keep_state, Data, [{reply, From, Resp}]};
connected(_EventType, _Msg, Data)->
    lager:info("unhandled event whilst in ~p state: Type: ~p, Msg: ~p", [connected, _EventType, _Msg]),
    {keep_state, Data}.

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------
-spec disconnect(data())-> ok.
disconnect(_Data = #data{connection = undefined}) ->
    ok;
disconnect(_Data = #data{connection = Connection}) ->
    catch _ = grpc_client_custom:stop_connection(Connection),
    ok.

-spec find_validator() -> {error, any()} | {ok, string(), pos_integer(), string()}.
find_validator()->
    case application:get_env(miner, seed_validators) of
        {ok, SeedValidators} ->
            {_SeedP2PAddr, SeedValIP, SeedValGRPCPort} = lists:nth(rand:uniform(length(SeedValidators)), SeedValidators),
            Req = build_validators_req(1),
            case send_grpc_unary_req(SeedValIP, SeedValGRPCPort, Req, 'validators') of
                {ok, #gateway_validators_resp_v1_pb{result = []}, _ReqDetails} ->
                    %% no routes, retry in a bit
                    lager:warning("failed to find any validator routing from seed validator ~p", [SeedValIP]),
                    {error, no_validators};
                {ok, #gateway_validators_resp_v1_pb{result = Routing}, _ReqDetails} ->
                    %% resp will contain the payload 'gateway_validators_resp_v1_pb'
                    [#routing_address_pb{pub_key = DurableValPubKeyBin, uri = DurableValURI}] = Routing,
                    DurableValP2PAddr = libp2p_crypto:pubkey_bin_to_p2p(DurableValPubKeyBin),
                    #{host := DurableValIP, port := DurableValGRPCPort} = uri_string:parse(DurableValURI),
                    {ok, DurableValIP, DurableValGRPCPort, DurableValP2PAddr};
                {error, Reason} = _Error ->
                    lager:warning("request to validator failed: ~p", [_Error]),
                    {error, Reason}
            end;
        _ ->
            lager:warning("failed to find seed validators", []),
            {error, find_validator_request_failed}
    end.

-spec connect_validator(string(), string(), pos_integer()) -> {error, any()} | {ok, grpc_client_custom:connection()}.
connect_validator(ValAddr, ValIP, ValPort) ->
    try
        lager:info("connecting to validator, p2paddr: ~p, ip: ~p, port: ~p", [ValAddr, ValIP, ValPort]),
        case miner_poc_grpc_client_handler:connect(ValAddr, maybe_override_ip(ValIP), ValPort) of
            {error, _} = Error ->
                Error;
            {ok, Connection} = Res->
                lager:info("successfully connected to validator via connection ~p", [Connection]),
                Res
        end
    catch _Class:_Error:_Stack ->
        lager:info("failed to connect to validator, will try again in a bit. Reason: ~p, Details: ~p, Stack: ~p", [_Class, _Error, _Stack]),
        {error, connect_validator_failed}
    end.

-spec connect_stream_poc(grpc_client_custom:connection(), libp2p_crypto:pubkey_bin(), function()) -> {error, any()} | {ok, pid()}.
connect_stream_poc(Connection, SelfPubKeyBin, SelfSigFun) ->
    lager:info("establishing POC stream on connection ~p", [Connection]),
    case miner_poc_grpc_client_handler:poc_stream(Connection, SelfPubKeyBin, SelfSigFun) of
        {error, _Reason} = Error->
            Error;
        {ok, Stream} = Res->
            lager:info("successfully connected poc stream ~p on connection ~p", [Stream, Connection]),
            Res
    end.

-spec connect_stream_config_update(grpc_client_custom:connection()) -> {error, any()} | {ok, pid()}.
connect_stream_config_update(Connection) ->
    lager:info("establishing config_update stream on connection ~p", [Connection]),
    case miner_poc_grpc_client_handler:config_update_stream(Connection) of
        {error, _Reason} = Error->
            Error;
        {ok, Stream} = Res->
            lager:info("successfully connected config update stream ~p on connection ~p", [Stream, Connection]),
            Res
    end.

-spec send_report(witness | receipt, any(), binary(), function(), grpc_client_custom:connection()) -> ok.
send_report(receipt = ReportType, Report, OnionKeyHash, SigFun, Connection) ->
    EncodedReceipt = gateway_miner_client_pb:encode_msg(Report, blockchain_poc_receipt_v1_pb),
    SignedReceipt = Report#blockchain_poc_receipt_v1_pb{signature = SigFun(EncodedReceipt)},
    Req = #gateway_poc_report_req_v1_pb{onion_key_hash = OnionKeyHash,  msg = {ReportType, SignedReceipt}},
    %%TODO: add a retry mechanism ??
    _ = send_grpc_unary_req(Connection, Req, 'send_report'),
    ok;
send_report(witness = ReportType, Report, OnionKeyHash, SigFun, Connection) ->
    EncodedWitness = gateway_miner_client_pb:encode_msg(Report, blockchain_poc_witness_v1_pb),
    SignedWitness = Report#blockchain_poc_witness_v1_pb{signature = SigFun(EncodedWitness)},
    Req = #gateway_poc_report_req_v1_pb{onion_key_hash = OnionKeyHash,  msg = {ReportType, SignedWitness}},
    _ = send_grpc_unary_req(Connection, Req, 'send_report'),
    ok.

-spec fetch_config([string()], string(), pos_integer()) -> {error, any()} | ok.
fetch_config(UpdatedKeys, ValIP, ValGRPCPort) ->
    %% filter out keys we are not interested in
    %% and then ask our validator for current values
    %% for remaining keys
    FilteredKeys = lists:filter(fun(K)-> lists:member(K, ?CONFIG_VARS) end, UpdatedKeys),
    case FilteredKeys of
        [] -> ok;
        _ ->
            %% retrieve some config from the returned validator
            Req2 = build_config_req(FilteredKeys),
            case send_grpc_unary_req(ValIP, ValGRPCPort, Req2, 'config') of
                {ok, #gateway_config_resp_v1_pb{result = Vars}, _Req2Details} ->
                    [
                        begin
                            {Name, Value} = blockchain_txn_vars_v1:from_var(Var),
                            application:set_env(miner, list_to_atom(Name), Value)
                        end || #blockchain_var_v1_pb{} = Var <- Vars],
                    ok;
                {error, Reason, _Details} ->
                    {error, Reason};
                {error, Reason} ->
                    {error, Reason}
            end
    end.

-spec send_grpc_unary_req(grpc_client_custom:connection(), any(), atom())-> {error, any(), map()} | {error, any()} | {ok, any(), map()} | {ok, map()}.
send_grpc_unary_req(undefined, _Req, _RPC) ->
    {error, no_grpc_connection};
send_grpc_unary_req(Connection, Req, RPC) ->
    try
        lager:info("send unary request: ~p", [Req]),
        Res = grpc_client_custom:unary(
            Connection,
            Req,
            'helium.gateway',
            RPC,
            gateway_miner_client_pb,
            [{callback_mod, miner_poc_grpc_client_handler}]
        ),
        lager:info("send unary result: ~p", [Res]),
        process_unary_response(Res)
    catch
        _Class:_Error:_Stack  ->
            lager:info("send unary failed: ~p, ~p, ~p", [_Class, _Error, _Stack]),
            {error, req_failed}
    end.

-spec send_grpc_unary_req(string(), non_neg_integer(), any(), atom()) -> {error, any(), map()} | {error, any()} | {ok, any(), map()} | {ok, map()}.
send_grpc_unary_req(PeerIP, GRPCPort, Req, RPC)->
    try
        lager:info("Send unary request via new connection to ip ~p: ~p", [PeerIP, Req]),
        {ok, Connection} = grpc_client_custom:connect(tcp, maybe_override_ip(PeerIP), GRPCPort),

        Res = grpc_client_custom:unary(
            Connection,
            Req,
            'helium.gateway',
            RPC,
            gateway_miner_client_pb,
            [{callback_mod, miner_poc_grpc_client_handler}]
        ),
        lager:info("New Connection, send unary result: ~p", [Res]),
            %% we dont need the connection to hang around, so close it out
        catch _ = grpc_client_custom:stop_connection(Connection),
        process_unary_response(Res)
    catch
        _Class:_Error:_Stack  ->
            lager:info("send unary failed: ~p, ~p, ~p", [_Class, _Error, _Stack]),
            {error, req_failed}
    end.

-spec build_check_target_req(libp2p_crypto:pubkey_bin(), binary(), binary(), non_neg_integer(), binary(), libp2p_crypto:pubkey_bin(), function()) -> #gateway_poc_check_challenge_target_req_v1_pb{}.
build_check_target_req(ChallengerPubKeyBin, OnionKeyHash, BlockHash, ChallengeHeight, ChallengerSig, SelfPubKeyBin, SelfSigFun) ->
    Req = #gateway_poc_check_challenge_target_req_v1_pb{
        address = SelfPubKeyBin,
        challenger = ChallengerPubKeyBin,
        block_hash = BlockHash,
        onion_key_hash = OnionKeyHash,
        height = ChallengeHeight,
        notifier = ChallengerPubKeyBin,
        notifier_sig = ChallengerSig,
        challengee_sig = <<>>
    },
    ReqEncoded = gateway_miner_client_pb:encode_msg(Req, gateway_poc_check_challenge_target_req_v1_pb),
    Req#gateway_poc_check_challenge_target_req_v1_pb{challengee_sig = SelfSigFun(ReqEncoded)}.

-spec build_region_params_req(libp2p_crypto:pubkey_bin(), function()) -> #gateway_poc_region_params_req_v1_pb{}.
build_region_params_req(Address, SigFun) ->
    Req = #gateway_poc_region_params_req_v1_pb{
        address = Address
    },
    ReqEncoded = gateway_miner_client_pb:encode_msg(Req, gateway_poc_region_params_req_v1_pb),
    Req#gateway_poc_region_params_req_v1_pb{signature = SigFun(ReqEncoded)}.

-spec build_validators_req(Quantity:: pos_integer()) -> #gateway_validators_req_v1_pb{}.
build_validators_req(Quantity) ->
    #gateway_validators_req_v1_pb{
        quantity = Quantity
    }.

-spec build_config_req([string()]) -> #gateway_config_req_v1_pb{}.
build_config_req(Keys) ->
    #gateway_config_req_v1_pb{ keys = Keys}.

%% TODO: return a better and consistent response
%%-spec process_unary_response(grpc_client_custom:unary_response()) -> {error, any(), map()} | {error, any()} | {ok, any(), map()} | {ok, map()}.
process_unary_response({ok, #{http_status := 200, result := #gateway_resp_v1_pb{msg = {success_resp, _Payload}, height = Height, signature = Sig}}}) ->
    {ok, #{height => Height, signature => Sig}};
process_unary_response({ok, #{http_status := 200, result := #gateway_resp_v1_pb{msg = {error_resp, Details}, height = Height, signature = Sig}}}) ->
    #gateway_error_resp_pb{error = ErrorReason} = Details,
    {error, ErrorReason, #{height => Height, signature => Sig}};
process_unary_response({ok, #{http_status := 200, result := #gateway_resp_v1_pb{msg = {_RespType, Payload}, height = Height, signature = Sig}}}) ->
    {ok, Payload, #{height => Height, signature => Sig}};
process_unary_response({error, ClientError = #{error_type := 'client'}}) ->
    lager:warning("grpc error response ~p", [ClientError]),
    {error, grpc_client_error};
process_unary_response({error, ClientError = #{error_type := 'grpc', http_status := 200, status_message := ErrorMsg}}) ->
    lager:warning("grpc error response ~p", [ClientError]),
    {error, ErrorMsg};
process_unary_response(_Response) ->
    lager:warning("unhandled grpc response ~p", [_Response]),
    {error, unexpected_response}.

handle_down_event(_CurState, {'DOWN', Ref, process, _, Reason}, Data = #data{conn_monitor_ref = Ref, connection = Connection}) ->
    lager:warning("GRPC connection to validator is down, reconnecting.  Reason: ~p", [Reason]),
    _ = grpc_client_custom:stop_connection(Connection),
    %% if the connection goes down, enter setup state to reconnect
    {next_state, setup, Data};
handle_down_event(_CurState, {'DOWN', Ref, process, _, Reason} = Event, Data = #data{stream_poc_monitor_ref = Ref,
                                                                             connection = Connection,
                                                                             self_pub_key_bin = SelfPubKeyBin,
                                                                             self_sig_fun = SelfSigFun}) ->
    %% the poc stream is meant to be long lived, we always want it up as long as we have a grpc connection
    %% so if it goes down start it back up again
    lager:warning("poc stream to validator is down, reconnecting.  Reason: ~p", [Reason]),
    case connect_stream_poc(Connection, SelfPubKeyBin, SelfSigFun) of
        {ok, StreamPid} ->
            M = erlang:monitor(process, StreamPid),
            {keep_state, Data#data{stream_poc_monitor_ref = M, stream_poc_pid = StreamPid}};
        {error, _} ->
            %% if stream reconnnect fails, replay the orig down msg to trigger another attempt
            %% NOTE: not using transition actions below as want a delay before the msgs get processed again
            erlang:send_after(?STREAM_RECONNECT_DELAY, self(), Event),
            {keep_state, Data}
    end;
handle_down_event(_CurState, {'DOWN', Ref, process, _, Reason} = Event, Data = #data{stream_config_update_monitor_ref = Ref,
                                                                             connection = Connection}) ->
    %% the config_update stream is meant to be long lived, we always want it up as long as we have a grpc connection
    %% so if it goes down start it back up again
    lager:warning("config_update stream to validator is down, reconnecting.  Reason: ~p", [Reason]),
    case connect_stream_config_update(Connection) of
        {ok, StreamPid} ->
            M = erlang:monitor(process, StreamPid),
            {keep_state, Data#data{stream_config_update_monitor_ref = M, stream_config_update_pid = StreamPid}};
        {error, _} ->
            %% if stream reconnnect fails, replay the orig down msg to trigger another attempt
            %% NOTE: not using transition actions below as want a delay before the msgs get processed again
            erlang:send_after(?STREAM_RECONNECT_DELAY, self(), Event),
            {keep_state, Data}
    end.

-ifdef(TEST).
maybe_override_ip(_IP)->
    "127.0.0.1".
-else.
maybe_override_ip(IP)->
    IP.
-endif.

