%%%-------------------------------------------------------------------
%% @Dec
%% == miner hbbft_handler ==
%% @end
%%%-------------------------------------------------------------------
-module(miner_hbbft_handler).

-behavior(relcast).

-export([
         init/1,
         handle_message/3, handle_command/2, callback_message/3,
         serialize/1, deserialize/1, restore/2,
         metadata/3
        ]).

-include_lib("blockchain/include/blockchain_vars.hrl").
-include("miner_util.hrl").

-record(state,
        {
         n :: non_neg_integer(),
         f :: non_neg_integer(),
         id :: non_neg_integer(),
         hbbft :: hbbft:hbbft_data(),
         sk :: tc_key_share:tc_key_share() | tpke_privkey:privkey() | binary(),
         sigs_valid     = [] :: addr_sigs(),
         sigs_unchecked = [] :: addr_sigs(),
         signatures_required = 0,
         sig_phase = unsent :: unsent | sig | gossip | done,
         artifact :: undefined | binary(),
         members :: [libp2p_crypto:pubkey_bin()],
         chain :: blockchain:blockchain(),
         last_round_signed = 0 :: non_neg_integer(),
         seen = #{} :: #{non_neg_integer() => boolean()},
         bba = <<>> :: binary()
        }).

-type addr() ::
    libp2p_crypto:pubkey_bin().

-type addr_sig() ::
    {addr(), Sig :: binary()}.

-type addr_sigs() ::
    [addr_sig()].

-type hbbft_msg() ::
      hbbft_msg_signature()
    | hbbft_msg_signatures()
    | hbbft:acs_msg()
    | hbbft:dec_msg()
    | hbbft:sign_msg().

-type hbbft_msg_signature() ::
    {signature, Round :: pos_integer(), addr(), Sig :: binary()}.

-type hbbft_msg_signatures() ::
    {signatures, Round :: pos_integer(), addr_sigs()}.

-spec metadata(V, M, C) -> binary()
    when V :: tuple | map,
         M :: #{} | #{seen => binary(), bba_completion => binary()},
         C :: blockchain:blockchain().
%% TODO No need to pass Meta when tuple. Use sum type: {map, Meta} | tuple
metadata(Version, Meta, Chain) ->
    {ok, HeadHash} = blockchain:head_hash(Chain),
    %% construct a 2-tuple of the system time and the current head block hash as our stamp data
    case Version of
        tuple ->
            term_to_binary({erlang:system_time(seconds), HeadHash});
        map ->
            ChainMeta0 = #{timestamp => erlang:system_time(seconds), head_hash => HeadHash},
            {ok, Height} = blockchain:height(Chain),
            Ledger = blockchain:ledger(Chain),
            ChainMeta = case blockchain:config(?snapshot_interval, Ledger) of
                            {ok, Interval} ->
                                lager:debug("snapshot interval is ~p h ~p rem ~p",
                                            [Interval, Height, Height rem Interval]),
                                case Height rem Interval == 0 of
                                    true ->
                                        Blocks = blockchain_ledger_snapshot_v1:get_blocks(Chain),
                                        case blockchain_ledger_snapshot_v1:snapshot(Ledger, Blocks) of
                                            {ok, Snapshot} ->
                                                ok = blockchain:add_snapshot(Snapshot, Chain),
                                                SHA = blockchain_ledger_snapshot_v1:hash(Snapshot),
                                                lager:info("snapshot hash is ~p", [SHA]),
                                                maps:put(snapshot_hash, SHA, ChainMeta0);
                                            _Err ->
                                                lager:warning("error constructing snapshot ~p", [_Err]),
                                                ChainMeta0
                                        end;
                                    false ->
                                        ChainMeta0
                                end;
                            _ ->
                                lager:info("no snapshot interval configured"),
                                ChainMeta0
                        end,
            t2b(maps:merge(Meta, ChainMeta))
    end.

init([Members, Id, N, F, BatchSize, SK, Chain]) ->
    init([Members, Id, N, F, BatchSize, SK, Chain, 0, []]);
init([Members, Id, N, F, BatchSize, SK, Chain, Round, Buf]) ->
    %% if we're first starting up, we don't know anything about the
    %% metadata.
    ?mark(init),
    Ledger0 = blockchain:ledger(Chain),
    Version = md_version(Ledger0),
    HBBFT = hbbft:init(SK, N, F, Id-1, BatchSize, 1500,
                       {?MODULE, metadata, [Version, #{}, Chain]}, Round, Buf),
    Ledger = blockchain_ledger_v1:new_context(Ledger0),
    Chain1 = blockchain:ledger(Ledger, Chain),

    lager:info("HBBFT~p started~n", [Id]),
    {ok, #state{n = N,
                id = Id - 1,
                sk = SK,
                f = F,
                members = Members,
                signatures_required = N - F,
                hbbft = HBBFT,
                chain = Chain1}}.

handle_command(start_acs, State) ->
    case hbbft:start_on_demand(State#state.hbbft) of
        {_HBBFT, already_started} ->
            ?mark(start_acs_already),
            {reply, ok, ignore};
        {NewHBBFT, {send, Msgs}} ->
            ?mark(start_acs_new),
            lager:notice("Started HBBFT round because of a block timeout"),
            {reply, ok, fixup_msgs(Msgs), State#state{hbbft=NewHBBFT}}
    end;
handle_command(have_key, State) ->
    {reply, hbbft:have_key(State#state.hbbft), [], State};
handle_command(get_buf, State) ->
    {reply, {ok, hbbft:buf(State#state.hbbft)}, ignore};
handle_command({set_buf, Buf}, State) ->
    {reply, ok, [], State#state{hbbft = hbbft:buf(Buf, State#state.hbbft)}};
handle_command(stop, State) ->
    %% TODO add ignore support for this four tuple to use ignore
    lager:info("stop called without timeout"),
    {reply, ok, [{stop, 0}], State};
handle_command({stop, Timeout}, State) ->
    %% TODO add ignore support for this four tuple to use ignore
    lager:info("stop called with timeout: ~p", [Timeout]),
    {reply, ok, [{stop, Timeout}], State};
handle_command({status, Ref, Worker}, State) ->
    Map = hbbft:status(State#state.hbbft),
    ArtifactHash = case State#state.artifact of
                       undefined -> undefined;
                       A -> blockchain_utils:bin_to_hex(crypto:hash(sha256, A))
                   end,
    SigMemIds = addr_sigs_to_mem_pos(State#state.sigs_valid, State),
    PubKeyHash = case tc_key_share:is_key_share(State#state.sk) of
                     true ->
                         crypto:hash(sha256, term_to_binary(tc_pubkey:serialize(tc_key_share:public_key(State#state.sk))));
                     false ->
                         crypto:hash(sha256, term_to_binary(tpke_pubkey:serialize(tpke_privkey:public_key(State#state.sk))))
                 end,
    Worker ! {Ref, maps:merge(#{signatures_required =>
                                    max(State#state.signatures_required - length(SigMemIds), 0),
                                signatures => SigMemIds,
                                sig_phase => State#state.sig_phase,
                                artifact_hash => ArtifactHash,
                                public_key_hash => blockchain_utils:bin_to_hex(PubKeyHash)
                               }, maps:remove(sig_sent, Map))},
    {reply, ok, ignore};
handle_command({skip, Ref, Worker}, #state{chain=Chain}=S) ->
    Version = md_version(blockchain:ledger(Chain)),
    HBBFT0 = hbbft:set_stamp_fun(?MODULE, metadata, [Version, #{}, Chain], S#state.hbbft),
    ?mark(skip),
    case hbbft:next_round(HBBFT0) of
        {HBBFT1, ok} ->
            Worker ! {Ref, ok},
            {reply, ok, [new_epoch], state_reset(HBBFT1, S)};
        {HBBFT1, {send, NextMsgs}} ->
            {reply, ok, [new_epoch | fixup_msgs(NextMsgs)], state_reset(HBBFT1, S)}
    end;
handle_command(mark_done, _State) ->
    {reply, ok, ignore};
%% XXX this is a hack because we don't yet have a way to message this process other ways
handle_command(
    {next_round, NextRound, TxnsToRemove, _Sync},
    #state{chain=Chain, hbbft=HBBFT}=S
) ->
    PrevRound = hbbft:round(HBBFT),
    case NextRound - PrevRound of
        N when N > 0 ->
            %% we've advanced to a new round, we need to destroy the old ledger context
            %% (with the old speculatively absorbed changes that may now be invalid/stale)
            %% and create a new one, and then use that new context to filter the pending
            %% transactions to remove any that have become invalid
            lager:info("Advancing from PreviousRound: ~p to NextRound ~p and emptying hbbft buffer",
                       [PrevRound, NextRound]),
            ?mark(next_round),
            HBBFT1 =
                case get(filtered) of
                    Done when Done == NextRound ->
                        HBBFT;
                    _ ->
                        Buf = hbbft:buf(HBBFT),
                        BinTxnsToRemove = [blockchain_txn:serialize(T) || T <- TxnsToRemove],
                        Buf1 = miner_hbbft_sidecar:new_round(Buf, BinTxnsToRemove),
                        hbbft:buf(Buf1, HBBFT)
                end,
            Ledger = blockchain:ledger(Chain),
            Version = md_version(Ledger),
            Seen = blockchain_utils:map_to_bitvector(S#state.seen),
            HBBFT2 = hbbft:set_stamp_fun(?MODULE, metadata, [Version,
                                                             #{seen => Seen,
                                                               bba_completion => S#state.bba},
                                                             Chain], HBBFT1),
            case hbbft:next_round(HBBFT2, NextRound, []) of
                {HBBFT3, ok} ->
                    {reply, ok, [new_epoch], state_reset(HBBFT3, S)};
                {HBBFT3, {send, Msgs}} ->
                    {reply, ok, [new_epoch] ++ fixup_msgs(Msgs), state_reset(HBBFT3, S)}
            end;
        0 ->
            lager:warning("Already at the current Round: ~p", [NextRound]),
            {reply, ok, ignore};
        _ ->
            lager:warning("Cannot advance to NextRound: ~p from PrevRound: ~p", [NextRound, PrevRound]),
            {reply, error, ignore}
    end;
%% these are coming back from the sidecar, they don't need to be
%% validated further.
handle_command({txn, Txn}, State=#state{hbbft=HBBFT}) ->
    Buf = hbbft:buf(HBBFT),
    case lists:member(blockchain_txn:serialize(Txn), Buf) of
        true ->
            {reply, ok, ignore};
        false ->
            case hbbft:input(State#state.hbbft, blockchain_txn:serialize(Txn)) of
                {NewHBBFT, ok} ->
                    {reply, ok, [], State#state{hbbft=NewHBBFT}};
                {_HBBFT, full} ->
                    {reply, {error, full}, ignore};
                {NewHBBFT, {send, Msgs}} ->
                    {reply, ok, fixup_msgs(Msgs), State#state{hbbft=NewHBBFT}}
            end
    end;
handle_command(_, _State) ->
    {reply, ignored, ignore}.

-spec handle_message(binary(), pos_integer(), #state{}) ->
    defer | ignore | {#state{}, [RelcastMsg]} when
    RelcastMsg ::
          {multicast, binary()}
        | {unicast, pos_integer(), binary()}.
handle_message(<<BinMsgIn/binary>>, Index, #state{hbbft=HBBFT}=S0) ->
    CurRound = hbbft:round(HBBFT),
    case bin_to_msg(BinMsgIn) of
        %% Multiple sigs
        {ok, {signatures, SigRound, _   }} when SigRound > CurRound ->
            defer;
        {ok, {signatures, SigRound, _   }} when SigRound < CurRound ->
            ignore;
        {ok, {signatures, _, SigsIn}} ->
            handle_sigs({received, SigsIn}, S0);

        %% Single sig
        {ok, {signature, SigRound, _, _}} when SigRound > CurRound ->
            defer;
        {ok, {signature, SigRound, _, _}} when SigRound < CurRound ->
            ignore;
        {ok, {signature, _, Addr, Sig}} ->
            handle_sigs({received, [{Addr, Sig}]}, S0);

        %% Other
        {ok, MsgIn} ->
            handle_msg_hbbft(MsgIn, Index, S0);
        {error, truncated} ->
            lager:warning("got truncated message: ~p:", [BinMsgIn]),
            ignore
    end.

callback_message(_, _, _) -> none.

-spec handle_msg_hbbft(MsgHBBFT, pos_integer(), #state{}) ->
    defer | ignore | {#state{}, [MsgRelcast]} when
    MsgHBBFT :: hbbft:acs_msg() | hbbft:dec_msg() | hbbft:sign_msg(),
    MsgRelcast ::
          {multicast, binary()}
        | {unicast, pos_integer(), binary()}.
handle_msg_hbbft(Msg, Index, #state{hbbft=HBBFT0}=S0) ->
    S1 = S0#state{seen = (S0#state.seen)#{Index => true}},
    case hbbft:handle_msg(HBBFT0, Index - 1, Msg) of
        ignore ->
            ignore;
        {HBBFT1, ok} ->
            {S1#state{hbbft=HBBFT1}, []};
        {_, defer} ->
            defer;
        {HBBFT1, {send, MsgsOut}} ->
            {S1#state{hbbft=HBBFT1}, fixup_msgs(MsgsOut)};
        {HBBFT1, {result, {transactions, Metadata0, BinTxns}}} ->
            Metadata = lists:map(fun({Id, BMap}) -> {Id, binary_to_term(BMap)} end, Metadata0),
            Txns = [blockchain_txn:deserialize(B) || B <- BinTxns],
            CurRound = hbbft:round(HBBFT0),
            lager:info("Reached consensus ~p ~p", [Index, CurRound]),
            ?mark(done_protocol),
            %% send agreed upon Txns to the parent blockchain worker
            %% the worker sends back its address, signature and txnstoremove which contains all or a subset of
            %% transactions depending on its buffer
            NewRound = hbbft:round(HBBFT1),
            Before = erlang:monotonic_time(millisecond),
            case miner:create_block(Metadata, Txns, NewRound) of
                {ok,
                    #{
                        address               := Address,
                        unsigned_binary_block := Artifact,
                        signature             := Signature,
                        pending_txns          := PendingTxns,
                        invalid_txns          := InvalidTxns
                     }
                } ->
                    lager:info("self-made artifact: ~p ",
                        [[
                            {addr, b58(Address)},
                            {sig, b58(Signature)},
                            {art, b58(Artifact)}
                        ]]),
                    ?mark(block_success),
                    %% call hbbft finalize round
                    Duration = erlang:monotonic_time(millisecond) - Before,
                    lager:info("block creation for round ~p took: ~p ms", [NewRound, Duration]),
                    %% remove any pending txns or invalid txns from the buffer
                    BinTxnsToRemove = [blockchain_txn:serialize(T) || T <- PendingTxns ++ InvalidTxns],
                    HBBFT2 = hbbft:finalize_round(HBBFT1, BinTxnsToRemove),
                    Buf = hbbft:buf(HBBFT2),
                    %% do an async filter of the remaining txn buffer while we finish off the block
                    Buf1 = miner_hbbft_sidecar:prefilter_round(Buf, PendingTxns),
                    put(filtered, NewRound),
                    S2 = S1#state{
                        hbbft     = hbbft:buf(Buf1, HBBFT2),
                        sig_phase = sig,
                        bba       = make_bba(S1#state.n, Metadata),
                        artifact  = Artifact
                    },
                    ?mark(finalize_round),
                    handle_sigs({produced, {Address, Signature}, NewRound}, S2);
                {error, Reason} ->
                    ?mark(block_failure),
                    %% this is almost certainly because we got the new block gossipped before we completed consensus locally
                    %% which is harmless
                    lager:warning("failed to create new block ~p", [Reason]),
                    {S1#state{hbbft=HBBFT1}, []}
            end
    end.

-spec make_bba(non_neg_integer(), [{non_neg_integer(), _}]) -> binary().
make_bba(Sz, Metadata) ->
    %% note that BBA indices are 0 indexed, but bitvectors are 1 indexed
    %% so we correct that here
    M = maps:from_list([{Id + 1, true} || {Id, _} <- Metadata]),
    M1 = lists:foldl(fun(Id, Acc) ->
                             case Acc of
                                 #{Id := _} ->
                                     Acc;
                                 _ ->
                                     Acc#{Id => false}
                             end
                     end, M, lists:seq(1, Sz)),
    blockchain_utils:map_to_bitvector(M1).

-spec serialize(#state{}) -> #{atom() => binary()}.
serialize(State) ->
    {SerializedHBBFT, SerializedSK} = hbbft:serialize(State#state.hbbft, true),
    Fields = record_info(fields, state),
    StateList0 = tuple_to_list(State),
    StateList = tl(StateList0),
    lists:foldl(fun({K = hbbft, _}, M) ->
                        M#{K => SerializedHBBFT};
                   ({K = sk, _}, M) ->
                        M#{K => term_to_binary(SerializedSK,  [compressed])};
                   ({chain, _}, M) ->
                        M;
                   ({K, V}, M)->
                        VB = term_to_binary(V, [compressed]),
                        M#{K => VB}
                end,
                #{},
                lists:zip(Fields, StateList)).

-spec deserialize(binary() | #{atom() => binary()}) -> #state{}.
deserialize(BinState) when is_binary(BinState) ->
    State = binary_to_term(BinState),
    SK = try tc_key_share:deserialize(State#state.sk) of
             Res -> Res
         catch _:_ ->
                   tpke_privkey:deserialize(State#state.sk)
         end,
    HBBFT = hbbft:deserialize(State#state.hbbft, SK),
    State#state{hbbft=HBBFT, sk=SK};
deserialize(#{sk := SKSer,
              hbbft := HBBFTSer} = StateMap) ->
    SK = try tc_key_share:deserialize(binary_to_term(SKSer)) of
             Res -> Res
         catch _:_ ->
                   tpke_privkey:deserialize(binary_to_term(SKSer))
         end,
    HBBFT = hbbft:deserialize(HBBFTSer, SK),
    Fields = record_info(fields, state),
    Bundef = term_to_binary(undefined, [compressed]),
    DeserList =
        lists:map(
          fun(hbbft) ->
                  HBBFT;
             (sk) ->
                  SK;
             (chain) ->
                  undefined;
             (K)->
                  case StateMap of
                      #{K := V} when V /= undefined andalso
                                     V /= Bundef ->
                          binary_to_term(V);
                      _ when K == sig_phase ->
                          sig;
                      _ when K == seen ->
                          #{};
                      _ when K == bba ->
                          <<>>;
                      _ ->
                          undefined
                  end
          end,
          Fields),
    list_to_tuple([state | DeserList]).

-spec restore(#state{}, #state{}) -> {ok, #state{}}.
restore(OldState, NewState) ->
    %% replace the stamp fun from the old state with the new one
    %% because we have non-serializable data in it (rocksdb refs)
    HBBFT = OldState#state.hbbft,
    {M, F, A} = hbbft:get_stamp_fun(NewState#state.hbbft),
    Buf = hbbft:buf(HBBFT),
    Buf1 = miner_hbbft_sidecar:new_round(Buf, []),
    HBBFT1 = hbbft:buf(Buf1, HBBFT),
    {ok, OldState#state{hbbft = hbbft:set_stamp_fun(M, F, A, HBBFT1)}}.

%% helper functions
-spec fixup_msgs([MsgIn]) -> [MsgOut] when
    MsgIn  :: {unicast, non_neg_integer(), term()}   | {multicast, term()},
    MsgOut :: {unicast, non_neg_integer(), binary()} | {multicast, binary()}.
fixup_msgs(Msgs) ->
    lists:map(fun({unicast, J, NextMsg}) ->
                      {unicast, J+1, msg_to_bin(NextMsg)};
                 ({multicast, NextMsg}) ->
                      {multicast, msg_to_bin(NextMsg)}
              end, Msgs).

%% @doc Finds unique member positions (if any) of addresses in the given
%% `{Address, Signature}' tuples.
%% @end
-spec addr_sigs_to_mem_pos(addr_sigs(), #state{}) -> [pos_integer()].
addr_sigs_to_mem_pos(AddrSigs, #state{members=MemberAddresses}) ->
    lists:usort(positions([Addr || {Addr, _} <- AddrSigs], MemberAddresses)).

-spec positions([A], [A]) -> [pos_integer()].
positions(Unordered, Ordered) ->
    Positions = lists:zip(Ordered, lists:seq(1, length(Ordered))),
    FindPosition = fun (X) -> {_, I} = lists:keyfind(X, 1, Positions), I end,
    lists:map(FindPosition, Unordered).

-spec md_version(blockchain_ledger_v1:ledger()) -> map | tuple.
md_version(Ledger) ->
    case blockchain:config(?election_version, Ledger) of
        {ok, N} when N >= 3 ->
            map;
        _ ->
            tuple
    end.

-spec state_reset(hbbft:hbbft_data(), #state{}) -> #state{}.
state_reset(HBBFT, #state{}=S) ->
    S#state{
        hbbft          = HBBFT,
        sigs_valid     = [],
        sigs_unchecked = [],
        artifact       = undefined,
        sig_phase      = unsent,
        bba            = <<>>,
        seen           = #{}
    }.

-spec handle_sigs(
    {received, addr_sigs()} | {produced, addr_sig(), non_neg_integer()},
    #state{}
) ->
    {#state{}, [{multicast, binary()}]}.
handle_sigs(Given, #state{hbbft=HBBFT}=S0) ->
    SigsIn =
        case Given of
            {received, Sigs} -> Sigs;
            {produced, Sig, _} -> [Sig]
        end,
    CurRound = hbbft:round(HBBFT),
    case state_sigs_input(SigsIn, S0) of
        {{done, SigsOut}, S1} ->
            ?mark(done_sigs),
            MsgOut = msg_to_bin({signatures, CurRound, SigsOut}),
            {S1, [{multicast, MsgOut}]};
        {{gossip, SigsOut}, S1} ->
            ?mark(gossip_sigs),
            MsgOut = msg_to_bin({signatures, CurRound, SigsOut}),
            {S1, [{multicast, MsgOut}]};
        {pending, S1} ->
            MsgsOut =
                case Given of
                    {received, _} ->
                        [];
                    {produced, {SelfAddr, SelfSig}, NewRound} ->
                        [{multicast, {signature, NewRound, SelfAddr, SelfSig}}]
                end,
            {S1, fixup_msgs(MsgsOut)}
    end.

-spec state_sigs_input(addr_sigs(), #state{}) ->
    {
        {done, addr_sigs()} | {gossip, addr_sigs()} | pending,
        #state{}
    }.
state_sigs_input(SigsIn, #state{hbbft=HBBFT}=S0) ->
    CurRound = hbbft:round(HBBFT),
    S1 = state_sigs_add(SigsIn, S0),
    S2 = state_sigs_retry_unchecked(S1),
    case state_sigs_check_if_enough(S2) of
        {{enough_for, {gossip, _}=Gossip}, S3} ->
            {Gossip, S3#state{sig_phase = gossip}};
        {
            {enough_for, {done, Sigs}=Done},
            #state{artifact = <<Art/binary>>, last_round_signed=LastRoundSigned}=S3
        } when CurRound > LastRoundSigned ->
            ok = miner:signed_block(Sigs, Art),
            S4 =
                S3#state{
                    last_round_signed = CurRound,
                    sig_phase = done
                },
            {Done, S4};
        {{enough_for, {done, _}}, S3} ->
            {pending, S3};
        {not_enough, S3} ->
            {pending, S3}
    end.

-spec state_sigs_add(addr_sigs(), #state{}) -> #state{}.
state_sigs_add(Sigs, #state{}=S) ->
    lists:foldl(fun state_sigs_add_one/2, S, Sigs).

-spec state_sigs_add_one(addr_sig(), #state{}) -> #state{}.
state_sigs_add_one({Addr, Sig}, #state{artifact = undefined, sigs_unchecked=Unchecked}=S) ->
    %% Provisionally accept signatures if we don't have the means to
    %% verify them yet. We'll retry verifying them later.
    S#state{sigs_unchecked = kvl_set(Addr, Sig, Unchecked)};
state_sigs_add_one({Addr, Sig}, #state{}=S) ->
    case sig_is_valid({Addr, Sig}, S) of
        true  -> S#state{sigs_valid = kvl_set(Addr, Sig, S#state.sigs_valid)};
        false -> S
    end.

-spec state_sigs_retry_unchecked(#state{}) -> #state{}.
state_sigs_retry_unchecked(#state{artifact=undefined}=S0) ->
    S0;
state_sigs_retry_unchecked(#state{artifact = <<_/binary>>, sigs_unchecked = Unchecked}=S) ->
    state_sigs_add(Unchecked, S).

-spec state_sigs_check_if_enough(#state{}) ->
    {not_enough | {enough_for, Next}, #state{}} when
    Next :: {gossip, addr_sigs()} | {done, addr_sigs()}.
state_sigs_check_if_enough(#state{artifact=undefined}=S) ->
    {not_enough, S};
state_sigs_check_if_enough(#state{sig_phase = sig, sigs_valid = Sigs, f = F}=S) when length(Sigs) < F + 1 ->
    {not_enough, S};
state_sigs_check_if_enough(#state{sig_phase = done, sigs_valid = SigsValid}=S) ->
    {{enough_for, {done, SigsValid}}, S};
state_sigs_check_if_enough(
    #state{
        sig_phase = Phase,
        artifact = <<_/binary>>,
        f = F,
        sigs_valid = SigsValidAll,
        signatures_required = Threshold0
    }=S0
) ->
    Threshold1 =
        case Phase of
            sig -> F + 1;
            gossip -> Threshold0
        end,
    SigsValidRand =
        lists:sublist(blockchain_utils:shuffle(SigsValidAll), Threshold1),
    case
        length(SigsValidAll) =< (3*F)+1 andalso
        length(SigsValidRand) >= Threshold1
    of
        true ->
            %% So, this is a little dicey, if we don't need all N signatures,
            %% we might have competing subsets depending on message order.
            %% Given that the underlying artifact they're signing is the same
            %% though, it should be ok as long as we disregard the signatures
            %% for testing equality but check them for validity
            SigsValidRandSubset =
                lists:sublist(lists:sort(SigsValidRand), Threshold0),
            case Phase of
                gossip ->
                    {{enough_for, {done, SigsValidRandSubset}}, S0};
                sig ->
                    case length(SigsValidRand) >= Threshold0 of
                        true ->
                            {{enough_for, {done, SigsValidRandSubset}}, S0};
                        false ->
                            {{enough_for, {gossip, lists:sort(SigsValidRand)}}, S0}
                    end
            end;
        false ->
            {not_enough, S0}
    end.

-spec sig_is_valid(addr_sig(), #state{}) -> boolean().
sig_is_valid(
    {<<Addr/binary>>, <<Sig/binary>>}=AddrSig,
    #state{artifact=Art, members=MemberAddresses, hbbft=HBBFT}=S
) ->
    IsMember = lists:member(Addr, MemberAddresses),
    IsValid =
        IsMember
        andalso
        libp2p_crypto:verify(Art, Sig, libp2p_crypto:bin_to_pubkey(Addr)),
    case IsValid of
        true ->
            ok;
        false ->
            CurRound = hbbft:round(HBBFT),
            case IsMember of
                true ->
                    [MemId] = addr_sigs_to_mem_pos([AddrSig], S),
                    lager:warning("Invalid signature from member ~b in our round ~p", [MemId, CurRound]);
                false ->
                    lager:warning("Invalid signature from non-member ~s in our round ~p", [b58(Addr), CurRound])
            end
    end,
    IsValid.

-spec kvl_set(K, V, KVL) -> KVL when KVL :: [{K, V}].
kvl_set(K, V, KVL) ->
    lists:keystore(K, 1, KVL, {K, V}).

-spec b58(binary()) -> string().
b58(<<Bin/binary>>) ->
    libp2p_crypto:bin_to_b58(Bin).

-spec t2b(term()) -> binary().
t2b(Term) ->
    term_to_binary(Term, [{compressed, 1}]).

-spec msg_to_bin(hbbft_msg()) -> binary().
msg_to_bin(Msg) ->
    t2b(Msg).

-spec bin_to_msg(binary()) -> {ok, hbbft_msg()} | {error, truncated}.
bin_to_msg(<<Bin/binary>>) ->
    try
        {ok, binary_to_term(Bin)}
    catch _:_ ->
        {error, truncated}
    end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

positions_test() ->
    ?assertMatch([1], positions([a], [a]), "Position 1 of 1"),
    ?assertMatch([1], positions([a], [a, b]), "Position 1 of 2"),
    ?assertMatch([2], positions([b], [a, b, c]), "Position 2 of 3"),
    ?assertMatch([2, 2], positions([b, b], [a, b, c]), "Position 2,2 of 3").

-endif.
