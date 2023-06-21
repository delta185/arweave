%%% @doc The 2.6 mining server.
-module(ar_mining_server).
% TODO fix arg order in remote's
% TODO Seed, NextSeed, StartIntervalNumber, StepNumber, NonceLimiterOutput -> #vdf

-behaviour(gen_server).

-export([start_link/0, pause/0, start_mining/1, set_difficulty/1, pause_performance_reports/1,
		set_merkle_rebase_threshold/1, remote_compute_h2/2, cm_exit_prepare_solution/1,
		get_recall_bytes/4]).

-export([init/1, handle_cast/2, handle_call/3, handle_info/2, terminate/2]).

-include_lib("arweave/include/ar.hrl").
-include_lib("arweave/include/ar_config.hrl").
-include_lib("arweave/include/ar_consensus.hrl").
-include_lib("arweave/include/ar_mining.hrl").
-include_lib("eunit/include/eunit.hrl").

-record(mining_session, {
	ref,
	paused = true,
	seed,
	next_seed,
	start_interval_number,
	partition_upper_bound,
	step_number_by_output = #{},
	chunk_cache = #{},
	chunk_cache_size_limit = infinity
}).

-record(state, {
	hashing_threads				= queue:new(),
	hashing_thread_monitor_refs = #{},
	session						= #mining_session{},
	diff						= infinity,
	merkle_rebase_threshold		= infinity,
	partitions					= sets:new(),
	task_queue					= gb_sets:new(),
	pause_performance_reports	= false,
	pause_performance_reports_timeout
}).

-define(TASK_CHECK_FREQUENCY_MS, 200).

%%%===================================================================
%%% Public interface.
%%%===================================================================

%% @doc Start the gen_server.
start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Start mining.
start_mining(Args) ->
	gen_server:cast(?MODULE, {start_mining, Args}).

%% @doc Callback from ar_mining_io when a chunk is read
recall_chunk(chunk1, Chunk, Nonce, Candidate) ->
	ar_mining_stats:increment_partition_stats(Candidate#mining_candidate.partition_number),
	add_task(chunk1, Candidate#mining_candidate{ chunk1 = Chunk, nonce = Nonce });
recall_chunk(chunk2, Chunk, Nonce, Candidate) ->
	ar_mining_stats:increment_partition_stats(Candidate#mining_candidate.partition_number),
	add_task(chunk2, Candidate#mining_candidate{ chunk2 = Chunk, nonce = Nonce });
recall_chunk(skipped, undefined, Nonce, Candidate) ->
	update_chunk_cache_size(-1),
	signal_cache_cleanup(Nonce, Candidate).

%% @doc Callback from the hashing threads when a hash is computed
computed_hash(computed_h0, H0, undefined, Candidate) ->
	add_task(computed_h0, Candidate#mining_candidate{ h0 = H0 });
computed_hash(computed_h1, H1, Preimage, Candidate) ->
	add_task(computed_h1, Candidate#mining_candidate{ h1 = H1, preimage = Preimage });
computed_hash(computed_h2, H2, Preimage, Candidate) ->
	add_task(computed_h2, Candidate#mining_candidate{ h2 = H2, preimage = Preimage }).

%% @doc Compute H2 for a remote peer (used in coordinated mining).
compute_h2_for_peer(Candidate, H1List) ->
	gen_server:cast(?MODULE, {compute_h2_for_peer, generate_cache_ref(Candidate), H1List}).

%% @doc Set the new mining difficulty. We do not recalculate it inside the mining
%% server because we want to completely detach the mining server from the block
%% ordering. The previous block is chosen only after the mining solution is found (if
%% we choose it in advance we may miss a better option arriving in the process).
%% Also, a mining session may (in practice, almost always will) span several blocks.
set_difficulty(Diff) ->
	gen_server:cast(?MODULE, {set_difficulty, Diff}).

set_merkle_rebase_threshold(Threshold) ->
	gen_server:cast(?MODULE, {set_merkle_rebase_threshold, Threshold}).

%% @doc Stop logging performance reports for the given number of milliseconds.
pause_performance_reports(Time) ->
	gen_server:cast(?MODULE, {pause_performance_reports, Time}).

%% @doc Compute h2 from a remote request.
remote_compute_h2(Peer, H2Materials) ->
	gen_server:cast(?MODULE, {remote_compute_h2, Peer, H2Materials}).
remote_io_thread_recall_range2_chunk(Args) ->
	{H0, PartitionNumber, Nonce, _Seed, _NextSeed, _StartIntervalNumber, _StepNumber,
		NonceLimiterOutput, ReplicaID, Chunk, CorrelationRef, Session} = Args,
	gen_server:cast(?MODULE, {remote_io_thread_recall_range2_chunk, H0, PartitionNumber, Nonce, NonceLimiterOutput, ReplicaID, Chunk, CorrelationRef, Session}).

%% @doc Process the solution found by the coordinated mining peer.
cm_exit_prepare_solution({PartitionNumber, Nonce, H0, Seed, NextSeed, StartIntervalNumber,
		StepNumber, NonceLimiterOutput, ReplicaID, PoA1, PoA2, H2, Preimage,
		PartitionUpperBound, SuppliedCheckpoints}) ->
	gen_server:cast(?MODULE, {cm_exit_prepare_solution, PartitionNumber, Nonce, H0, Seed,
			NextSeed, StartIntervalNumber, StepNumber, NonceLimiterOutput, ReplicaID, PoA1,
			PoA2, H2, Preimage, PartitionUpperBound, SuppliedCheckpoints, 50});

cm_exit_prepare_solution({PartitionNumber, Nonce, H0, Seed, NextSeed, StartIntervalNumber,
		StepNumber, NonceLimiterOutput, ReplicaID, PoA1, PoA2, H2, Preimage,
		PartitionUpperBound, SuppliedCheckpoints, RetryConterLeft}) ->
	gen_server:cast(?MODULE, {cm_exit_prepare_solution, PartitionNumber, Nonce, H0, Seed,
			NextSeed, StartIntervalNumber, StepNumber, NonceLimiterOutput, ReplicaID, PoA1,
			PoA2, H2, Preimage, PartitionUpperBound, SuppliedCheckpoints, RetryConterLeft}).

%%%===================================================================
%%% Generic server callbacks.
%%%===================================================================

init([]) ->
	process_flag(trap_exit, true),
	ok = ar_events:subscribe(nonce_limiter),
	{ok, Config} = application:get_env(arweave, config),
	ar_chunk_storage:open_files("default"),
	gen_server:cast(?MODULE, handle_task),
	reset_chunk_cache_size(),
	State = lists:foldl(
		fun(_, Acc) -> start_hashing_thread(Acc) end,
		#state{},
		lists:seq(1, Config#config.hashing_threads)
	),
	{ok, State}.

handle_call(get_task_queue_len, _From, State) ->
	%% Used in tests.
	#state{ task_queue = Q } = State,
	Length = length(gb_sets:to_list(Q)),
	{reply, Length, State};

handle_call(Request, _From, State) ->
	?LOG_WARNING("event: unhandled_call, request: ~p", [Request]),
	{reply, ok, State}.

handle_cast(pause, State) ->
	#state{ session = Session } = State,
	prometheus_gauge:set(mining_rate, 0),
	%% Setting paused to true allows all pending tasks to complete, but prevents new output to be 
	%% distributed. Setting diff to infnity ensures that no solutions are found.
	{noreply, State#state{ diff = infinity, session = Session#mining_session{ paused = true } }};

handle_cast({start_mining, Args}, State) ->
	{Diff, RebaseThreshold} = Args,
	ar:console("Starting mining.~n"),
	#state{ io_threads = IOThreads } = State,
	Session = reset_mining_session(State),
	[Thread ! reset_performance_counters || Thread <- maps:values(IOThreads)],
	CacheSizeLimit = get_chunk_cache_size_limit(State),
	log_chunk_cache_size_limit(CacheSizeLimit),
	ets:insert(?MODULE, {chunk_cache_size, 0}),
	prometheus_gauge:set(mining_server_chunk_cache_size, 0),
	Session = #mining_session{ ref = Ref, chunk_cache_size_limit = CacheSizeLimit },
	{noreply, State#state{ diff = Diff, merkle_rebase_threshold = RebaseThreshold,
			session = Session }};

handle_cast({set_difficulty, _Diff},
		#state{ session = #mining_session{ ref = undefined } } = State) ->
	{noreply, State};
handle_cast({set_difficulty, Diff}, State) ->
	{noreply, State#state{ diff = Diff }};

handle_cast({set_merkle_rebase_threshold, Threshold}, State) ->
	{noreply, State#state{ merkle_rebase_threshold = Threshold }};

handle_cast(handle_task, #state{ task_queue = Q } = State) ->
	case gb_sets:is_empty(Q) of
		true ->
			ar_util:cast_after(?TASK_CHECK_FREQUENCY_MS, ?MODULE, handle_task),
			{noreply, State};
		_ ->
			{{_Priority, _ID, Task}, Q2} = gb_sets:take_smallest(Q),
			prometheus_gauge:dec(mining_server_task_queue_len),
			may_be_warn_about_lag(Task, Q2),
			gen_server:cast(?MODULE, handle_task),
			handle_task(Task, State#state{ task_queue = Q2 })
	end;

handle_cast({compute_h2_for_peer, Candidate, H1List}, State) ->
	#state{ session = Session } = State,
	#mining_session{ chunk_cache = Map } = Session,
	#mining_candidate{
		h0 = H0,
		partition_number = PartitionNumber,
		partition_upper_bound = PartitionUpperBound
	} = Candidate,
	
	{_RecallRange1Start, RecallRange2Start} = ar_block:get_recall_range(H0,
			PartitionNumber, PartitionUpperBound),
	Range2Exists = ar_mining_io:read_recall_range(chunk2, Candidate, RecallRange2Start),
	case Range2Exists of
		true ->
			%% Only reserve enough space to process the H1 list provided. If this is less
			%% than the full recall range, some of the chunk2s will be read, cached, and ignored
			%% (since we don't have the H1 needed to compute the H2).
			%%
			%% This may cause some temporary memory bloat - but it will be cleaned up with the
			%% next mining session (e.g. when the next block is applied).
			%%
			%% If however we reserve cache space for these "orphan" chunk2s the cache space they
			%% consume will prevent usable chunks from being read and negatively impact the mining
			%% rate.
			reserve_cache_space(length(H1List)),
			Map2 = cache_h1_list(Candidate, H1List, Map),
			Session2 = Session#mining_session{ chunk_cache = Map2 },
			{noreply, State#state{ session = Session2 }};
		false ->
			%% This can happen if the remote peer has an outdated partition table
			{noreply, State}
	end;
handle_cast(report_performance, #state{ io_threads = IOThreads, session = Session } = State) ->
	#mining_session{ partition_upper_bound = PartitionUpperBound } = Session,
	Max = max(0, PartitionUpperBound div ?PARTITION_SIZE - 1),
	Partitions =
		lists:sort(sets:to_list(
			maps:fold(
				fun({Partition, _, StoreID}, _, Acc) ->
					case Partition > Max of
						true ->
							Acc;
						_ ->
							sets:add_element({Partition, StoreID}, Acc)
					end
				end,
				sets:new(), % A storage module may be smaller than a partition.
				IOThreads
			))),
	Now = erlang:monotonic_time(millisecond),
	VdfSpeed = vdf_speed(Now),
	{IOList, MaxPartitionTime, PartitionsSum, MaxCurrentTime, CurrentsSum} =
		lists:foldr(
			fun({Partition, StoreID}, {Acc1, Acc2, Acc3, Acc4, Acc5} = Acc) ->
				case ets:lookup(?MODULE, {performance, Partition}) of
					[] ->
						Acc;
					[{_, PartitionStart, _, CurrentStart, _}]
							when Now - PartitionStart =:= 0
								orelse Now - CurrentStart =:= 0 ->
						Acc;
					[{_, PartitionStart, PartitionTotal, CurrentStart, CurrentTotal}] ->
						ets:update_counter(?MODULE,
										{performance, Partition},
										[{4, -1, Now, Now}, {5, 0, -1, 0}]),
						PartitionTimeLapse = (Now - PartitionStart) / 1000,
						PartitionAvg = PartitionTotal / PartitionTimeLapse / 4,
						CurrentTimeLapse = (Now - CurrentStart) / 1000,
						CurrentAvg = CurrentTotal / CurrentTimeLapse / 4,
						Optimal = optimal_performance(StoreID, VdfSpeed),
						?LOG_INFO([{event, mining_partition_performance_report},
								{partition, Partition}, {avg, PartitionAvg},
								{current, CurrentAvg}]),
						case Optimal of
							undefined ->
								{[io_lib:format("Partition ~B avg: ~.2f MiB/s, "
										"current: ~.2f MiB/s.~n",
									[Partition, PartitionAvg, CurrentAvg]) | Acc1],
									max(Acc2, PartitionTimeLapse), Acc3 + PartitionTotal,
									max(Acc4, CurrentTimeLapse), Acc5 + CurrentTotal};
							_ ->
								{[io_lib:format("Partition ~B avg: ~.2f MiB/s, "
										"current: ~.2f MiB/s, "
										"optimum: ~.2f MiB/s, ~.2f MiB/s (full weave).~n",
									[Partition, PartitionAvg, CurrentAvg, Optimal / 2,
											Optimal]) | Acc1],
									max(Acc2, PartitionTimeLapse), Acc3 + PartitionTotal,
									max(Acc4, CurrentTimeLapse), Acc5 + CurrentTotal}
						end
				end
			end,
			{[], 0, 0, 0, 0},
			Partitions
		),
	case MaxPartitionTime > 0 of
		true ->
			TotalAvg = PartitionsSum / MaxPartitionTime / 4,
			TotalCurrent = CurrentsSum / MaxCurrentTime / 4,
			?LOG_INFO([{event, mining_performance_report}, {total_avg_mibps, TotalAvg},
					{total_avg_hps, TotalAvg * 4}, {total_current_mibps, TotalCurrent},
					{total_current_hps, TotalCurrent * 4}]),
			Str =
				case VdfSpeed of
					undefined ->
						io_lib:format("~nMining performance report:~nTotal avg: ~.2f MiB/s, "
								" ~.2f h/s; current: ~.2f MiB/s, ~.2f h/s.~n",
						[TotalAvg, TotalAvg * 4, TotalCurrent, TotalCurrent * 4]);
					_ ->
						io_lib:format("~nMining performance report:~nTotal avg: ~.2f MiB/s, "
								" ~.2f h/s; current: ~.2f MiB/s, ~.2f h/s; VDF: ~.2f s.~n",
						[TotalAvg, TotalAvg * 4, TotalCurrent, TotalCurrent * 4, VdfSpeed])
				end,
			prometheus_gauge:set(mining_rate, TotalCurrent),
			IOList2 = [Str | [IOList | ["~n"]]],
			ar:console(iolist_to_binary(IOList2));
		false ->
			ok
	end,
	ar_util:cast_after(?PERFORMANCE_REPORT_FREQUENCY_MS, ?MODULE, report_performance),
	{noreply, State};

handle_cast({post_solution, Solution}, State) ->
	post_solution(Solution, State),
	{noreply, State};

handle_cast({may_be_remove_chunk_from_cache, _Args},
		#state{ session = #mining_session{ ref = undefined } } = State) ->
	{noreply, State};
handle_cast({may_be_remove_chunk_from_cache, _Args} = Task,
		#state{ task_queue = Q } = State) ->
	Q2 = gb_sets:insert({priority(may_be_remove_chunk_from_cache), make_ref(), Task}, Q),
	prometheus_gauge:inc(mining_server_task_queue_len),
	{noreply, State#state{ task_queue = Q2 }};

handle_cast({remote_compute_h2, Peer, H2Materials}, State) ->
	{Diff, Addr, H0, PartitionNumber, PartitionNumber2, PartitionUpperBound, Seed, NextSeed, StartIntervalNumber, StepNumber, NonceLimiterOutput, SuppliedCheckpoints,
			ReqList} = H2Materials,
	{_RecallRange1Start, RecallRange2Start} = ar_block:get_recall_range(H0,
			PartitionNumber, PartitionUpperBound),
	Range2End = RecallRange2Start + ?RECALL_RANGE_SIZE,
	case find_thread(PartitionNumber2, Addr, Range2End, RecallRange2Start,
			State#state.io_threads) of
		not_found ->
			%% This can be if calling peer has outdated partition table
			ok;
		Thread ->
			reserve_cache_space(),
			CorrelationRef = {PartitionNumber, PartitionNumber2, PartitionUpperBound, make_ref()},
			Session = {remote, Diff, Addr, H0, PartitionNumber, PartitionNumber2, PartitionUpperBound,
					RecallRange2Start, Seed, NextSeed, StartIntervalNumber, StepNumber, NonceLimiterOutput, SuppliedCheckpoints, ReqList, Peer},
			Thread ! {remote_read_recall_range2, Thread, Session, CorrelationRef}
	end,
	{noreply, State};

handle_cast({cm_exit_prepare_solution, PartitionNumber, Nonce, H0, Seed, NextSeed,
		StartIntervalNumber, StepNumber, NonceLimiterOutput, ReplicaID,
		PoA1, PoA2, H2, Preimage, PartitionUpperBound, SuppliedCheckpoints, _RetryConterLeft},
		#state{ diff = Diff, session = #mining_session{ ref = Ref } } = State) ->
	{RecallByte1, RecallByte2} = get_recall_bytes(H0, PartitionNumber, Nonce,
			PartitionUpperBound),
	case binary:decode_unsigned(H2, big) > Diff of
		true ->
			?LOG_INFO([{event, found_solution_send_to_cm_exit_peer},
					{partition, PartitionNumber},
					{seed, ar_util:encode(Seed)},
					{next_seed, ar_util:encode(NextSeed)},
					{start_interval_number, StartIntervalNumber},
					{step_number, StepNumber},
					{mining_address, ar_util:encode(ReplicaID)},
					{recall_byte1, RecallByte1},
					{recall_byte2, RecallByte2},
					{solution_h, ar_util:encode(H2)},
					{nonce_limiter_output, ar_util:encode(NonceLimiterOutput)}]),
			Args = {PartitionNumber, Nonce, H0, Seed, NextSeed, StartIntervalNumber,
					StepNumber, NonceLimiterOutput, ReplicaID,
					PoA1, PoA2, H2, Preimage, PartitionUpperBound, Ref},
			NewState = case ar_wallet:load_key(ReplicaID) of
				not_found ->
					?LOG_WARNING([{event, found_solution_send_to_cm_exit_peer_but_no_key},
							{solution_h, ar_util:encode(H2)},
							{mining_address, ar_util:encode(ReplicaID)}]),
					ar:console("WARNING. Can't find key ~w~n", [ar_util:encode(ReplicaID)]),
					State;
				Key ->
					FixPoA2 = case PoA2 of
						not_set ->
							#poa{};
						_ ->
							PoA2
					end,
					RecallByte22 = case PoA2 of not_set -> undefined; _ -> RecallByte2 end,
					prepare_solution(Args, State, Key, RecallByte1, RecallByte22, PoA1, FixPoA2, SuppliedCheckpoints)
			end,
			{noreply, NewState};
		false ->
			?LOG_INFO([{event, found_solution_send_to_cm_exit_peer_low_diff},
					{partition, PartitionNumber},
					{seed, ar_util:encode(Seed)},
					{next_seed, ar_util:encode(NextSeed)},
					{start_interval_number, StartIntervalNumber},
					{step_number, StepNumber},
					{mining_address, ar_util:encode(ReplicaID)},
					{recall_byte1, RecallByte1},
					{recall_byte2, RecallByte2},
					{solution_h, ar_util:encode(H2)},
					{nonce_limiter_output, ar_util:encode(NonceLimiterOutput)}]),
			{noreply, State}
	end;

%% TODO: This should probably go inside the task_queue, but we don't have a StepNumber so
%% FIXME. Now we have StepNumber
%% we can't assing a priority to it
handle_cast({remote_io_thread_recall_range2_chunk,
		_H0, _PartitionNumber, Nonce, _NonceLimiterOutput, _ReplicaID, Chunk, CorrelationRef,
		Session}, State) ->
	%% Prevent an accidental pattern match of _H0, _PartitionNumber.
	{remote, _Diff, _Addr, _H0_, _PartitionNumber_, _PartitionNumber2, _PartitionUpperBound, _RecallByte2Start,
			_Seed, _NextSeed, _StartIntervalNumber, _StepNumber, _NonceLimiterOutput2, _SuppliedCheckpoints,
			ReqList, _Peer } = Session,
	#state{ hashing_threads = Threads } = State,
	%% The accumulator is in fact the un-accumulator here.
	NewThreads = lists:foldl(
		fun (Value, AccThreads) ->
			case Value of
				{H1, Nonce} ->
					{Thread, Threads2} = pick_hashing_thread(AccThreads),
					Thread ! {remote_compute_h2, {self(), H1, Nonce, Chunk, Session,
							CorrelationRef}},
					Threads2;
				_ ->
					AccThreads
			end
		end,
		Threads,
		ReqList
	),
	{noreply, State#state{ hashing_threads = NewThreads }};

handle_cast(Cast, State) ->
	?LOG_WARNING("event: unhandled_cast, cast: ~p", [Cast]),
	{noreply, State}.

handle_info({'DOWN', Ref, process, _, Reason},
		#state{ io_thread_monitor_refs = IOThreadRefs,
				hashing_thread_monitor_refs = HashingThreadRefs } = State) ->
	case {maps:is_key(Ref, IOThreadRefs), maps:is_key(Ref, HashingThreadRefs)} of
		{true, _} ->
			{noreply, handle_io_thread_down(Ref, Reason, State)};
		{_, true} ->
			{noreply, handle_hashing_thread_down(Ref, Reason, State)};
		_ ->
			{noreply, State}
	end;

handle_info({event, nonce_limiter, {computed_output, _}},
		#state{ session = #mining_session{ ref = undefined } } = State) ->
	?LOG_DEBUG([{event, mining_debug_nonce_limiter_computed_output_session_undefined}]),
	{noreply, State};
handle_info({event, nonce_limiter, {computed_output, _}},
		#state{ session = #mining_session{ paused = true } } = State) ->
	{noreply, State};
handle_info({event, nonce_limiter, {computed_output, Args}},
		#state{ task_queue = Q } = State) ->
	{SessionKey, Session, _PrevSessionKey, _PrevSession, Output, PartitionUpperBound} = Args,
	StepNumber = Session#vdf_session.step_number,
	true = is_integer(StepNumber),
	ets:update_counter(?MODULE,
			{performance, nonce_limiter},
			[{3, 1}],
			{{performance, nonce_limiter}, erlang:monotonic_time(millisecond), 0}),
	#vdf_session{ seed = Seed, step_number = StepNumber } = Session,
	Task = {computed_output, {SessionKey, Seed, StepNumber, Output, PartitionUpperBound}},
	Q2 = gb_sets:insert({priority(nonce_limiter_computed_output, StepNumber), make_ref(),
			Task}, Q),
	prometheus_gauge:inc(mining_server_task_queue_len),
	{noreply, State#state{ task_queue = Q2 }};
handle_info({event, nonce_limiter, _}, State) ->
	{noreply, State};

handle_info({io_thread_recall_range_chunk, _Args},
		#state{ session = #mining_session{ ref = undefined } } = State) ->
	{noreply, State};
handle_info({io_thread_recall_range_chunk, Args} = Task,
		#state{ task_queue = Q } = State) ->
	StepNumber = element(7, Args),
	Q2 = gb_sets:insert({priority(io_thread_recall_range_chunk, StepNumber),
			make_ref(), Task}, Q),
	prometheus_gauge:inc(mining_server_task_queue_len),
	{noreply, State#state{ task_queue = Q2 }};

handle_info({io_thread_recall_range2_chunk, _Args},
		#state{ session = #mining_session{ ref = undefined } } = State) ->
	{noreply, State};
handle_info({io_thread_recall_range2_chunk, Args} = Task,
		#state{ task_queue = Q } = State) ->
	StepNumber = element(7, Args),
	Q2 = gb_sets:insert({priority(io_thread_recall_range2_chunk, StepNumber),
			make_ref(), Task}, Q),
	prometheus_gauge:inc(mining_server_task_queue_len),
	{noreply, State#state{ task_queue = Q2 }};

handle_info({mining_thread_computed_h0, _Args},
		#state{ session = #mining_session{ ref = undefined } } = State) ->
	{noreply, State};
handle_info({mining_thread_computed_h0, Args} = Task,
		#state{ task_queue = Q } = State) ->
	StepNumber = element(7, Args),
	Q2 = gb_sets:insert({priority(mining_thread_computed_h0, StepNumber), make_ref(),
			Task}, Q),
	prometheus_gauge:inc(mining_server_task_queue_len),
	{noreply, State#state{ task_queue = Q2 }};

handle_info({mining_thread_computed_h1, _Args},
		#state{ session = #mining_session{ ref = undefined } } = State) ->
	{noreply, State};
handle_info({mining_thread_computed_h1, Args} = Task,
		#state{ task_queue = Q } = State) ->
	StepNumber = element(7, Args),
	Q2 = gb_sets:insert({priority(mining_thread_computed_h1, StepNumber), make_ref(),
			Task}, Q),
	prometheus_gauge:inc(mining_server_task_queue_len),
	{noreply, State#state{ task_queue = Q2 }};

handle_info({may_be_remove_chunk_from_cache, _Args},
		#state{ session = #mining_session{ ref = undefined } } = State) ->
	{noreply, State};
handle_info({may_be_remove_chunk_from_cache, _Args} = Task,
		#state{ task_queue = Q } = State) ->
	Q2 = gb_sets:insert({priority(may_be_remove_chunk_from_cache), make_ref(), Task}, Q),
	prometheus_gauge:inc(mining_server_task_queue_len),
	{noreply, State#state{ task_queue = Q2 }};

handle_info({mining_thread_computed_h2, _Args},
		#state{ session = #mining_session{ ref = undefined } } = State) ->
	{noreply, State};
handle_info({mining_thread_computed_h2, Args} = Task,
		#state{ task_queue = Q } = State) ->
	StepNumber = element(7, Args),
	Q2 = gb_sets:insert({priority(mining_thread_computed_h2, StepNumber),
			make_ref(), Task}, Q),
	prometheus_gauge:inc(mining_server_task_queue_len),
	{noreply, State#state{ task_queue = Q2 }};

handle_info(Message, State) ->
	?LOG_WARNING("event: unhandled_info, message: ~p", [Message]),
	{noreply, State}.

terminate(_Reason, #state{ hashing_threads = HashingThreads }) ->
	[Thread ! stop || Thread <- queue:to_list(HashingThreads)],
	ok.

%%%===================================================================
%%% Private functions.
%%%===================================================================

start_hashing_thread(State) ->
	#state{ hashing_threads = Threads, hashing_thread_monitor_refs = Refs,
			session = #mining_session{ ref = SessionRef } } = State,
	Thread = spawn(fun hashing_thread/0),
	Ref = monitor(process, Thread),
	Threads2 = queue:in(Thread, Threads),
	Refs2 = maps:put(Ref, Thread, Refs),
	case SessionRef of
		undefined ->
			ok;
		_ ->
			Thread ! {new_mining_session, SessionRef}
	end,
	State#state{ hashing_threads = Threads2, hashing_thread_monitor_refs = Refs2 }.

handle_hashing_thread_down(Ref, Reason,
		#state{ hashing_threads = Threads, hashing_thread_monitor_refs = Refs } = State) ->
	?LOG_WARNING([{event, mining_hashing_thread_down},
			{reason, io_lib:format("~p", [Reason])}]),
	Thread = maps:get(Ref, Refs),
	Refs2 = maps:remove(Ref, Refs),
	Threads2 = queue:delete(Thread, Threads),
	start_hashing_thread(State#state{ hashing_threads = Threads2,
			hashing_thread_monitor_refs = Refs2 }).

get_chunk_cache_size_limit() ->
	ThreadCount = ar_mining_io:get_thread_count(),
	% Two ranges per output.
	OptimalLimit = ar_util:ceil_int(
		(?RECALL_RANGE_SIZE * 2 * ThreadCount) div ?DATA_CHUNK_SIZE,
		100),

io_thread(PartitionNumber, ReplicaID, StoreID, SessionRef) ->
	receive
		%% Prioritize stop and new_mining_session message before any read_recall_range messages,
		%% this ensures we don't continue to process previously queued read_recall_range messages
		%% after a mining session change
		stop ->
			io_thread(PartitionNumber, ReplicaID, StoreID);
		reset_performance_counters ->
			ets:insert(?MODULE, [{{performance, PartitionNumber},
					erlang:monotonic_time(millisecond), 0,
					erlang:monotonic_time(millisecond), 0}]),
			io_thread(PartitionNumber, ReplicaID, StoreID, SessionRef);
		{read_recall_range, {SessionRef, From, PartitionNumber2, RecallRangeStart, H0,
				Seed, NextSeed, StartIntervalNumber, StepNumber, NonceLimiterOutput,
				CorrelationRef}} ->
			read_recall_range(io_thread_recall_range_chunk, H0, PartitionNumber2,
					RecallRangeStart, Seed, NextSeed, StartIntervalNumber, StepNumber,
					NonceLimiterOutput, ReplicaID, StoreID, From, SessionRef, CorrelationRef),
			io_thread(PartitionNumber, ReplicaID, StoreID, SessionRef);
		{read_recall_range, _} ->
			%% Clear the message queue from the requests from the outdated mining session.
			io_thread(PartitionNumber, ReplicaID, StoreID, SessionRef);
		{remote_read_recall_range2, From, Session, CorrelationRef} ->
			{remote, _Diff, Addr, H0, _PartitionNumber, PartitionNumber2, _PartitionUpperBound, RecallRangeStart,
					_Seed, _NextSeed, _StartIntervalNumber, _StepNumber, _NonceLimiterOutput, _SuppliedCheckpoints,
					_ReqList, _Peer} = Session,
			case ReplicaID of
				Addr ->
					read_recall_range(remote_io_thread_recall_range2_chunk, H0,
							PartitionNumber2, RecallRangeStart, not_provided, not_provided,
							not_provided, not_provided, not_provided, ReplicaID, StoreID, From,
							Session, CorrelationRef);
					_ ->
						ar:console("WARNING recv Addr ~s but ReplicaID ~s ~n",
								[ar_util:encode(Addr), ar_util:encode(ReplicaID)])
			end,
			io_thread(PartitionNumber, ReplicaID, StoreID, SessionRef);
		{remote_io_thread_recall_range2_chunk, Args} ->
			remote_io_thread_recall_range2_chunk(Args),
			io_thread(PartitionNumber, ReplicaID, StoreID, SessionRef);
		{read_recall_range2, {SessionRef, From, PartitionNumber2, RecallRangeStart, H0,
				Seed, NextSeed, StartIntervalNumber, StepNumber, NonceLimiterOutput,
				CorrelationRef}} ->
			read_recall_range(io_thread_recall_range2_chunk, H0, PartitionNumber2,
					RecallRangeStart, Seed, NextSeed, StartIntervalNumber, StepNumber,
					NonceLimiterOutput, ReplicaID, StoreID, From, SessionRef, CorrelationRef),
			io_thread(PartitionNumber, ReplicaID, StoreID, SessionRef);
		{read_recall_range2, _} ->
			%% Clear the message queue from the requests from the outdated mining session.
			io_thread(PartitionNumber, ReplicaID, StoreID, SessionRef);
		{new_mining_session, Ref} ->
			io_thread(PartitionNumber, ReplicaID, StoreID, Ref)
	after 0 ->
		receive
			stop ->
				io_thread(PartitionNumber, ReplicaID, StoreID);
			{new_mining_session, Ref} ->
				io_thread(PartitionNumber, ReplicaID, StoreID, Ref);
			reset_performance_counters ->
				ets:insert(?MODULE, [{{performance, PartitionNumber},
						erlang:monotonic_time(millisecond), 0,
						erlang:monotonic_time(millisecond), 0}]),
				io_thread(PartitionNumber, ReplicaID, StoreID, SessionRef);
			{read_recall_range, {SessionRef, From, PartitionNumber2, RecallRangeStart, H0,
					NonceLimiterOutput, CorrelationRef}} ->
				read_recall_range(io_thread_recall_range_chunk, H0, PartitionNumber2,
						RecallRangeStart, NonceLimiterOutput, ReplicaID, StoreID, From,
						SessionRef, CorrelationRef),
				io_thread(PartitionNumber, ReplicaID, StoreID, SessionRef);
			{read_recall_range, _} ->
				%% Clear the message queue from the requests from the outdated mining session.
				io_thread(PartitionNumber, ReplicaID, StoreID, SessionRef);
			{read_recall_range2, {SessionRef, From, PartitionNumber2, RecallRangeStart, H0,
					NonceLimiterOutput, CorrelationRef}} ->
				read_recall_range(io_thread_recall_range2_chunk, H0, PartitionNumber2,
						RecallRangeStart, NonceLimiterOutput, ReplicaID, StoreID, From,
						SessionRef, CorrelationRef),
				io_thread(PartitionNumber, ReplicaID, StoreID, SessionRef);
			{read_recall_range2, _} ->
				%% Clear the message queue from the requests from the outdated mining session.
				io_thread(PartitionNumber, ReplicaID, StoreID, SessionRef)
		end
	end.

get_chunk_cache_size_limit(State) ->
	{ok, Config} = application:get_env(arweave, config),
	Limit = case Config#config.mining_server_chunk_cache_size_limit of
		undefined ->
			#state{ io_threads = IOThreads } = State,
			ThreadCount = map_size(IOThreads),
			Free = proplists:get_value(total_memory,
					memsup:get_system_memory_data(), 2000000000),
			Bytes = Total * 0.7 / 3,
			CalculatedLimit = erlang:ceil(Bytes / ?DATA_CHUNK_SIZE),
			min(ar_util:ceil_int(CalculatedLimit, 100), OptimalLimit);
		N ->
			N
	end,

	ar:console("~nSetting the chunk cache size limit to ~B chunks.~n", [Limit]),
	?LOG_INFO([{event, setting_chunk_cache_size_limit}, {limit, Limit}]),
	case Limit < OptimalLimit of
		true ->
			ar:console("~nChunk cache size limit is below optimal limit of ~p. "
				"Mining performance may be impacted.~n"
				"Consider adding more RAM or changing the "
				"'mining_server_chunk_cache_size_limit' option.", [OptimalLimit]);
		false -> ok
	end,
	Limit.

may_be_warn_about_lag({computed_output, _Args}, Q) ->
	case gb_sets:is_empty(Q) of
		true ->
			ok;
		false ->
			case gb_sets:take_smallest(Q) of
				{{_Priority, _ID, {computed_output, _}}, Q3} ->
					N = count_nonce_limiter_tasks(Q3) + 1,
					?LOG_WARNING([{event, mining_server_lags_behind_the_nonce_limiter},
						{step_count, N}]);
				_ ->
					ok
			end
	end;
may_be_warn_about_lag(_Task, _Q) ->
	ok.

count_nonce_limiter_tasks(Q) ->
	case gb_sets:is_empty(Q) of
		true ->
			0;
		false ->
			case gb_sets:take_smallest(Q) of
				{{_Priority, _ID, {computed_output, _Args}}, Q2} ->
					1 + count_nonce_limiter_tasks(Q2);
				_ ->
					0
			end
	end.

read_recall_range(Type, H0, PartitionNumber, RecallRangeStart, Seed, NextSeed,
		StartIntervalNumber, StepNumber, NonceLimiterOutput, ReplicaID, StoreID, From,
		SessionRef, CorrelationRef) ->
	Size = ?RECALL_RANGE_SIZE,
	Intervals = get_packed_intervals(RecallRangeStart, RecallRangeStart + Size,
			ReplicaID, StoreID, ar_intervals:new()),
	ChunkOffsets = ar_chunk_storage:get_range(RecallRangeStart, Size, StoreID),
	ChunkOffsets2 = filter_by_packing(ChunkOffsets, Intervals, StoreID),
	?LOG_DEBUG([{event, mining_debug_read_recall_range},
			{found_chunks, length(ChunkOffsets)},
			{found_chunks_with_required_packing, length(ChunkOffsets2)}]),
	NonceMax = max(0, (Size div ?DATA_CHUNK_SIZE - 1)),
	read_recall_range(Type, H0, PartitionNumber, RecallRangeStart, Seed, NextSeed,
			StartIntervalNumber, StepNumber, NonceLimiterOutput,
			ReplicaID, From, 0, NonceMax, ChunkOffsets2, SessionRef, CorrelationRef).

get_packed_intervals(Start, End, ReplicaID, "default" = StoreID, Intervals) ->
	Packing = {spora_2_6, ReplicaID},
	case ar_sync_record:get_next_synced_interval(Start, End, Packing, ar_data_sync, StoreID) of
		not_found ->
			Intervals;
		{Right, Left} ->
			get_packed_intervals(Right, End, ReplicaID, StoreID,
					ar_intervals:add(Intervals, Right, Left))
	end;
get_packed_intervals(_Start, _End, _ReplicaID, _StoreID, _Intervals) ->
	no_interval_check_implemented_for_non_default_store.

filter_by_packing([], _Intervals, _StoreID) ->
	[];
filter_by_packing([{EndOffset, Chunk} | ChunkOffsets], Intervals, "default" = StoreID) ->
	case ar_intervals:is_inside(Intervals, EndOffset) of
		false ->
			filter_by_packing(ChunkOffsets, Intervals, StoreID);
		true ->
			[{EndOffset, Chunk} | filter_by_packing(ChunkOffsets, Intervals, StoreID)]
	end;
filter_by_packing(ChunkOffsets, _Intervals, _StoreID) ->
	ChunkOffsets.

read_recall_range(_Type, _H0, _PartitionNumber, _RecallRangeStart, _Seed, _NextSeed,
		_StartIntervalNumber, _StepNumber, _NonceLimiterOutput,
		_ReplicaID, _From, Nonce, NonceMax, _ChunkOffsets, _Ref, _CorrelationRef)
			when Nonce > NonceMax ->
	ok;
read_recall_range(Type, H0, PartitionNumber, RecallRangeStart, Seed, NextSeed,
		StartIntervalNumber, StepNumber, NonceLimiterOutput,
		ReplicaID, From, Nonce, NonceMax, [], Ref, CorrelationRef) ->
	%% Two recall ranges are processed asynchronously so we need to make sure chunks
	%% do not remain in the chunk cache.
	ets:update_counter(?MODULE, chunk_cache_size, {2, -1}),
	prometheus_gauge:dec(mining_server_chunk_cache_size),
	signal_cache_cleanup(Nonce, CorrelationRef, Ref, From),
	read_recall_range(Type, H0, PartitionNumber, RecallRangeStart, Seed, NextSeed,
			StartIntervalNumber, StepNumber, NonceLimiterOutput,
			ReplicaID, From, Nonce + 1, NonceMax, [], Ref, CorrelationRef);
read_recall_range(Type, H0, PartitionNumber, RecallRangeStart, Seed, NextSeed,
		StartIntervalNumber, StepNumber, NonceLimiterOutput,
		ReplicaID, From, Nonce, NonceMax, [{EndOffset, Chunk} | ChunkOffsets], Ref,
		CorrelationRef)
		%% Only 256 KiB chunks are supported at this point.
		when RecallRangeStart + Nonce * ?DATA_CHUNK_SIZE < EndOffset - ?DATA_CHUNK_SIZE ->
	ets:update_counter(?MODULE, chunk_cache_size, {2, -1}),
	prometheus_gauge:dec(mining_server_chunk_cache_size),
	signal_cache_cleanup(Nonce, CorrelationRef, Ref, From),
	read_recall_range(Type, H0, PartitionNumber, RecallRangeStart, Seed, NextSeed,
			StartIntervalNumber, StepNumber, NonceLimiterOutput,
			ReplicaID, From, Nonce + 1, NonceMax, [{EndOffset, Chunk} | ChunkOffsets], Ref,
			CorrelationRef);
read_recall_range(Type, H0, PartitionNumber, RecallRangeStart, Seed, NextSeed,
		StartIntervalNumber, StepNumber, NonceLimiterOutput,
		ReplicaID, From, Nonce, NonceMax, [{EndOffset, _Chunk} | ChunkOffsets], Ref,
		CorrelationRef)
		when RecallRangeStart + Nonce * ?DATA_CHUNK_SIZE >= EndOffset ->
	read_recall_range(Type, H0, PartitionNumber, RecallRangeStart, Seed, NextSeed,
			StartIntervalNumber, StepNumber, NonceLimiterOutput,
			ReplicaID, From, Nonce, NonceMax, ChunkOffsets, Ref, CorrelationRef);
read_recall_range(Type, H0, PartitionNumber, RecallRangeStart, Seed, NextSeed,
		StartIntervalNumber, StepNumber, NonceLimiterOutput,
		ReplicaID, From, Nonce, NonceMax, [{_EndOffset, Chunk} | ChunkOffsets], Ref,
		CorrelationRef) ->
	ets:update_counter(?MODULE, {performance, PartitionNumber}, [{3, 1}, {5, 1}],
			{{performance, PartitionNumber},
			 erlang:monotonic_time(millisecond), 1,
			 erlang:monotonic_time(millisecond), 1}),
	From ! {Type, {H0, PartitionNumber, Nonce, Seed, NextSeed, StartIntervalNumber, StepNumber,
			NonceLimiterOutput, ReplicaID, Chunk, CorrelationRef, Ref}},
	read_recall_range(Type, H0, PartitionNumber, RecallRangeStart, Seed, NextSeed,
			StartIntervalNumber, StepNumber, NonceLimiterOutput, ReplicaID, From, Nonce + 1,
			NonceMax, ChunkOffsets, Ref, CorrelationRef).

hashing_thread() ->
	hashing_thread(not_set).

hashing_thread(SessionRef) ->
	receive
		stop ->
			hashing_thread();
		{compute_h0, {SessionRef, From, Seed, NextSeed, StartIntervalNumber, StepNumber,
				Output, PartitionNumber, Seed, PartitionUpperBound, ReplicaID}} ->
			H0 = ar_block:compute_h0(Output, PartitionNumber, Seed, ReplicaID),
			From ! {mining_thread_computed_h0, {H0, PartitionNumber, PartitionUpperBound,
				Seed, NextSeed, StartIntervalNumber, StepNumber, Output, ReplicaID, SessionRef}},
			hashing_thread(SessionRef);
		{compute_h1, {SessionRef, From, H0, PartitionNumber, Nonce, Seed, NextSeed,
				StartIntervalNumber, StepNumber, NonceLimiterOutput, ReplicaID, Chunk,
				CorrelationRef}} ->
			{H1, Preimage} = ar_block:compute_h1(H0, Nonce, Chunk),
			From ! {mining_thread_computed_h1, {H0, PartitionNumber, Nonce, Seed, NextSeed,
					StartIntervalNumber, StepNumber, NonceLimiterOutput, ReplicaID, Chunk, H1,
					Preimage, CorrelationRef, SessionRef}},
			hashing_thread(SessionRef);
		{compute_h1, _} ->
			 %% Clear the message queue from the requests from the outdated mining session.
			 hashing_thread(SessionRef);
		{compute_h2, {SessionRef, From, H0, PartitionNumber, Nonce, Seed, NextSeed,
				StartIntervalNumber, StepNumber, NonceLimiterOutput, ReplicaID, Chunk1,
				Chunk2, H1}} ->
			{H2, Preimage} = ar_block:compute_h2(H1, Chunk2, H0),
			From ! {mining_thread_computed_h2, {H0, PartitionNumber, Nonce, Seed, NextSeed,
					StartIntervalNumber, StepNumber, NonceLimiterOutput, ReplicaID, Chunk1,
					Chunk2, H2, Preimage, SessionRef}},
			hashing_thread(SessionRef);
		{compute_h2, _} ->
			 %% Clear the message queue from the requests from the outdated mining session.
			 hashing_thread(SessionRef);
		{remote_compute_h2, {_From, H1, Nonce, Chunk2, Session, _CorrelationRef}} ->
			%% Important: here we make http requests inside the hashing thread
			%% to reduce the latency.
			{remote, Diff, ReplicaID, H0, PartitionNumber, _PartitionNumber2, PartitionUpperBound,
					_RecallByte2Start, Seed, NextSeed, StartIntervalNumber, StepNumber, NonceLimiterOutput, SuppliedCheckpoints,
					_ReqList, Peer } = Session,
			{H2, Preimage2} = ar_block:compute_h2(H1, Chunk2, H0),
			case binary:decode_unsigned(H2, big) > Diff of
				true ->
					Options = #{ pack => true, packing => {spora_2_6, ReplicaID} },
					{_RecallByte1, RecallByte2} = get_recall_bytes(H0, PartitionNumber, Nonce,
							PartitionUpperBound),
					% TODO FIXME how can be Chunk2 not_set?
					PoA2 =
						case Chunk2 of
							not_set ->
								#poa{};
							_ ->
								case ar_data_sync:get_chunk(RecallByte2 + 1, Options) of
									{ok, #{ chunk := Chunk2, tx_path := TXPath2,
											data_path := DataPath2 }} ->
										#poa{ option = 1, chunk = Chunk2, tx_path = TXPath2,
											data_path = DataPath2 };
									_ ->
										error
								end
						end,
					case PoA2 of
						error ->
							?LOG_WARNING([{event,
									mined_block_but_failed_to_read_chunk_proofs_cm},
									{recall_byte2, RecallByte2},
									{mining_address, ar_util:encode(ReplicaID)}]),
							ar:console("WARNING. mined_block_but_failed_to_read_chunk_proofs_cm. Check logs for details~n"),
							ok;
						_ ->
							ar_coordination:computed_h2({Diff, ReplicaID, H0, H1, Nonce,
									PartitionNumber, PartitionUpperBound, PoA2, H2, Preimage2,
									Seed, NextSeed, StartIntervalNumber, StepNumber, NonceLimiterOutput, SuppliedCheckpoints, Peer})
					end;
				false ->
					ok
			end,
			hashing_thread(SessionRef);
		{new_mining_session, Ref} ->
			hashing_thread(Ref)
	end.

distribute_output(Seed, PartitionUpperBound, Seed, NextSeed, StartIntervalNumber, StepNumber,
		Output, Iterator, Distributed, Ref, State) ->
	distribute_output(Seed, PartitionUpperBound, Seed, NextSeed, StartIntervalNumber,
			StepNumber, Output, Iterator, Distributed, Ref, State, 0).

distribute_output(Seed, PartitionUpperBound, Seed, NextSeed, StartIntervalNumber, StepNumber,
		Output, Iterator, Distributed, Ref, State, N) ->
	MaxPartitionNumber = max(0, PartitionUpperBound div ?PARTITION_SIZE - 1),
	case maps:next(Iterator) of
		none ->
			{N, State};
		{{PartitionNumber, ReplicaID, _StoreID}, _Thread, Iterator2}
				when PartitionNumber =< MaxPartitionNumber,
					not is_map_key({PartitionNumber, ReplicaID}, Distributed) ->
			#state{ hashing_threads = Threads } = State,
			{Thread, Threads2} = pick_hashing_thread(Threads),
			Thread ! {compute_h0, {Ref, self(), Seed, NextSeed, StartIntervalNumber,
					StepNumber, Output, PartitionNumber, Seed, PartitionUpperBound,
					ReplicaID}},
			State2 = State#state{ hashing_threads = Threads2 },
			Distributed2 = maps:put({PartitionNumber, ReplicaID}, sent, Distributed),
			distribute_output(Seed, PartitionUpperBound, Seed, NextSeed, StartIntervalNumber,
					StepNumber, Output, Iterator2, Distributed2, Ref, State2, N + 1);
		{_Key, _Thread, Iterator2} ->
			distribute_output(Seed, PartitionUpperBound, Seed, NextSeed, StartIntervalNumber,
					StepNumber, Output, Iterator2, Distributed, Ref, State, N)
	end.

%% @doc Before loading a recall range we reserve enough cache space for the whole range. This
%% helps make sure we don't exceed the cache limit (too much) when there are many parallel
%% reads. 
%%
%% As we compute hashes we'll decrement the chunk_cache_size to indicate available cache space.
reserve_cache_space() ->
	reserve_cache_space(nonce_max() + 1).

reserve_cache_space(NumChunks) ->
	update_chunk_cache_size(NumChunks).

priority(may_be_remove_chunk_from_cache) ->
	0.

priority(computed_h2, StepNumber) ->
	{1, -StepNumber};
priority(computed_h1, StepNumber) ->
	{2, -StepNumber};
priority(chunk2, StepNumber) ->
	{3, -StepNumber};
priority(chunk1, StepNumber) ->
	{4, -StepNumber};
priority(computed_h0, StepNumber) ->
	{5, -StepNumber};
priority(nonce_limiter_computed_output, StepNumber) ->
	{6, -StepNumber}.

handle_task({computed_output, _},
		#state{ session = #mining_session{ ref = undefined } } = State) ->
	?LOG_DEBUG([{event, mining_debug_handle_task_computed_output_session_undefined}]),
	{noreply, State};
handle_task({computed_output, Args}, State) ->
	#state{ session = Session, io_threads = IOThreads } = State,
	{ 
		{NextSeed, StartIntervalNumber},
		#vdf_session{ seed = Seed, step_number = StepNumber } = VDFSession,
		Output, PartitionUpperBound
	} = Args,
	#mining_session{ next_seed = CurrentNextSeed,
			start_interval_number = CurrentStartIntervalNumber,
			partition_upper_bound = CurrentPartitionUpperBound } = Session,
	Session2 =
		case {CurrentStartIntervalNumber, CurrentNextSeed, CurrentPartitionUpperBound}
				== {StartIntervalNumber, NextSeed, PartitionUpperBound} of
			true ->
				Session;
			false ->
				ar:console("Starting new mining session. Upper bound: ~B, entropy nonce: ~s, "
						"next entropy nonce: ~s, interval number: ~B.~n",
						[PartitionUpperBound, ar_util:encode(Seed), ar_util:encode(NextSeed),
						StartIntervalNumber]),
				?LOG_INFO("Starting new mining session. Upper bound: ~B, entropy nonce: ~s, "
						"next entropy nonce: ~s, interval number: ~B.~n",
						[PartitionUpperBound, ar_util:encode(Seed), ar_util:encode(NextSeed),
						StartIntervalNumber]),
				NewSession = reset_mining_session(State),
				NewSession#mining_session{ seed = Seed, next_seed = NextSeed,
						start_interval_number = StartIntervalNumber,
						partition_upper_bound = PartitionUpperBound }
		end,
	#mining_session{ step_number_by_output = Map } = Session2,
	Map2 = maps:put(Output, StepNumber, Map),
	Session3 = Session2#mining_session{ step_number_by_output = Map2 },
	Ref = Session3#mining_session.ref,
	Iterator = maps:iterator(IOThreads),
	{N, State2} = distribute_output(Seed, PartitionUpperBound, Seed, NextSeed,
			StartIntervalNumber, StepNumber, Output, Iterator, #{}, Ref, State),
	?LOG_DEBUG([{event, mining_debug_processing_vdf_output}, {found_io_threads, N},
		{step_number, StepNumber}, {output, ar_util:encode(Output)},
		{start_interval_number, StartIntervalNumber},
		{vdf_difficulty, VDFSession#vdf_session.vdf_difficulty},
		{next_vdf_difficulty, VDFSession#vdf_session.next_vdf_difficulty}]),
	{noreply, State2#state{ session = Session3 }};

handle_task({io_thread_recall_range_chunk, {H0, PartitionNumber, Nonce, Seed, NextSeed,
		StartIntervalNumber, StepNumber, NonceLimiterOutput, ReplicaID, Chunk, CorrelationRef,
		Ref}}, #state{ session = #mining_session{ ref = Ref } } = State) ->
	#state{ hashing_threads = Threads } = State,
	{Thread, Threads2} = pick_hashing_thread(Threads),
	Thread ! {compute_h1, {Ref, self(), H0, PartitionNumber, Nonce, Seed, NextSeed,
			StartIntervalNumber, StepNumber, NonceLimiterOutput, ReplicaID, Chunk,
			CorrelationRef}},
	{noreply, State#state{ hashing_threads = Threads2 }};
handle_task({io_thread_recall_range_chunk, _Args}, State) ->
	{noreply, State};

handle_task({io_thread_recall_range2_chunk, {H0, PartitionNumber, Nonce,
		Seed, NextSeed, StartIntervalNumber, StepNumber, NonceLimiterOutput, ReplicaID,
		Chunk, CorrelationRef, Ref}},
		#state{ session = #mining_session{ ref = Ref } } = State) ->
	#state{ session = Session, hashing_threads = Threads } = State,
	#mining_session{ chunk_cache = Map } = Session,
	case maps:take({CorrelationRef, Nonce}, Map) of
		{do_not_cache, Map2} ->
			Session2 = Session#mining_session{ chunk_cache = Map2 },
			ets:update_counter(?MODULE, chunk_cache_size, {2, -1}),
			prometheus_gauge:dec(mining_server_chunk_cache_size),
			{noreply, State#state{ session = Session2 }};
		error ->
			Map2 = maps:put({CorrelationRef, Nonce}, Chunk, Map),
			Session2 = Session#mining_session{ chunk_cache = Map2 },
			{noreply, State#state{ session = Session2 }};
		{{Chunk1, H1}, Map2} ->
			Session2 = Session#mining_session{ chunk_cache = Map2 },
			ets:update_counter(?MODULE, chunk_cache_size, {2, -2}),
			prometheus_gauge:dec(mining_server_chunk_cache_size, 2),
			{Thread, Threads2} = pick_hashing_thread(Threads),
			Thread ! {compute_h2, {Ref, self(), H0, PartitionNumber, Nonce,
					Seed, NextSeed, StartIntervalNumber, StepNumber, NonceLimiterOutput,
					ReplicaID, Chunk1, Chunk, H1}},
			{noreply, State#state{ hashing_threads = Threads2, session = Session2 }}
	end;
handle_task({io_thread_recall_range2_chunk, _Args}, State) ->
	{noreply, State};

handle_task({mining_thread_computed_h0, {H0, PartitionNumber, PartitionUpperBound,
		Seed, NextSeed, StartIntervalNumber, StepNumber, Output, ReplicaID, Ref}} = Task,
		#state{ task_queue = Q,
		session = #mining_session{ ref = Ref, chunk_cache_size_limit = Limit } } = State) ->
	[{_, Size}] = ets:lookup(?MODULE, chunk_cache_size),
	case Size > Limit of
		true ->
			Q2 = gb_sets:insert({priority(mining_thread_computed_h0, StepNumber),
					make_ref(), Task}, Q),
			prometheus_gauge:inc(mining_server_task_queue_len),
			{noreply, State#state{ task_queue = Q2 }};
		false ->
			#state{ io_threads = Threads } = State,
			{RecallRange1Start, RecallRange2Start} = ar_block:get_recall_range(H0,
					PartitionNumber, PartitionUpperBound),
			PartitionNumber2 = get_partition_number_by_offset(RecallRange2Start),
			CorrelationRef = {PartitionNumber, PartitionNumber2, PartitionUpperBound, make_ref()},
			Range1End = RecallRange1Start + ?RECALL_RANGE_SIZE,
			case find_thread(PartitionNumber, ReplicaID, Range1End, RecallRange1Start,
					Threads) of
				not_found ->
					?LOG_DEBUG([{event, mining_debug_no_io_thread_found_for_range},
							{range_start, RecallRange1Start},
							{range_end, Range1End}]),
					%% We have a storage module smaller than the partition size which
					%% partially covers this partition but does not include this range.
					ok;
				Thread1 ->
					reserve_cache_space(),
					Thread1 ! {read_recall_range, {Ref, self(), PartitionNumber,
							RecallRange1Start, H0, Seed, NextSeed, StartIntervalNumber,
							StepNumber, Output, CorrelationRef}},
					PartitionNumber2 = get_partition_number_by_offset(RecallRange2Start),
					Range2End = RecallRange2Start + ?RECALL_RANGE_SIZE,
					case find_thread(PartitionNumber2, ReplicaID, Range2End, RecallRange2Start,
							Threads) of
						not_found ->
							signal_cache_cleanup(CorrelationRef, Ref, self());
						Thread2 ->
							reserve_cache_space(),
							Thread2 ! {read_recall_range2, {Ref, self(), PartitionNumber,
									RecallRange2Start, H0, Seed, NextSeed, StartIntervalNumber,
									StepNumber, Output, CorrelationRef}}
					end
			end;
		false ->
			ok
	end,
	{noreply, State};

handle_task({mining_thread_computed_h1, {H0, PartitionNumber, Nonce, Seed, NextSeed,
		StartIntervalNumber, StepNumber, NonceLimiterOutput, ReplicaID, Chunk, H1, Preimage,
		CorrelationRef, Ref}},
		#state{ session = #mining_session{ ref = Ref } } = State) ->
	#state{ session = Session, diff = Diff, hashing_threads = Threads } = State,
	#mining_session{ chunk_cache = Map } = Session,
	case binary:decode_unsigned(H1, big) > Diff of
		true ->
			#state{ session = Session } = State,
			#mining_session{ partition_upper_bound = PartitionUpperBound } = Session,
			Args = {PartitionNumber, Nonce, H0, Seed, NextSeed, StartIntervalNumber,
					StepNumber, NonceLimiterOutput, ReplicaID, Chunk, not_set, H1, Preimage,
					PartitionUpperBound, Ref},
			Map3 =
				case maps:take({CorrelationRef, Nonce}, Map) of
					{do_not_cache, Map2} ->
						ets:update_counter(?MODULE, chunk_cache_size, {2, -1}),
						prometheus_gauge:dec(mining_server_chunk_cache_size),
						Map2;
					{_, Map2} ->
						ets:update_counter(?MODULE, chunk_cache_size, {2, -2}),
						prometheus_gauge:dec(mining_server_chunk_cache_size, 2),
						Map2;
					error ->
						ets:update_counter(?MODULE, chunk_cache_size, {2, -1}),
						prometheus_gauge:dec(mining_server_chunk_cache_size),
						maps:put({CorrelationRef, Nonce}, do_not_cache, Map)
				end,
			Session2 = Session#mining_session{ chunk_cache = Map3 },
			State2 = State#state{ session = Session2 },
			{noreply, prepare_solution(Args, State2)};
		false ->
			{ok, Config} = application:get_env(arweave, config),
			case maps:take({CorrelationRef, Nonce}, Map) of
				{do_not_cache, Map2} ->
					ets:update_counter(?MODULE, chunk_cache_size, {2, -1}),
					prometheus_gauge:dec(mining_server_chunk_cache_size),
					Session2 = Session#mining_session{ chunk_cache = Map2 },
					case Config#config.coordinated_mining of
						false ->
							ok;
						true ->
							{_PartitionNumber, PartitionNumber2, PartitionUpperBound, _ref} = CorrelationRef,
							[{_, TipNonceLimiterInfo}] = ets:lookup(node_state, nonce_limiter_info),
							#nonce_limiter_info{ next_seed = PrevNextSeed,
								global_step_number = PrevStepNumber } = TipNonceLimiterInfo,
							case StepNumber > PrevStepNumber of
								true ->
									SuppliedCheckpoints = ar_nonce_limiter:get_steps(PrevStepNumber, StepNumber, PrevNextSeed),
									ar_coordination:computed_h1({CorrelationRef, Diff, ReplicaID, H0,
											H1, Nonce, PartitionNumber, PartitionNumber2, PartitionUpperBound, Seed,
											NextSeed, StartIntervalNumber, StepNumber,
											NonceLimiterOutput, SuppliedCheckpoints, Ref});
								false ->
									ok
							end
					end,
					{noreply, State#state{ session = Session2 }};
				error ->
					case Config#config.coordinated_mining of
						false ->
							ok;
						true ->
							{_PartitionNumber, PartitionNumber2, PartitionUpperBound, _ref} = CorrelationRef,
							[{_, TipNonceLimiterInfo}] = ets:lookup(node_state, nonce_limiter_info),
							#nonce_limiter_info{ next_seed = PrevNextSeed,
								global_step_number = PrevStepNumber } = TipNonceLimiterInfo,
							case StepNumber > PrevStepNumber of
								true ->
									SuppliedCheckpoints = ar_nonce_limiter:get_steps(PrevStepNumber, StepNumber, PrevNextSeed),
									ar_coordination:computed_h1({CorrelationRef, Diff, ReplicaID, H0,
											H1, Nonce, PartitionNumber, PartitionNumber2, PartitionUpperBound, Seed,
											NextSeed, StartIntervalNumber, StepNumber,
											NonceLimiterOutput, SuppliedCheckpoints, Ref});
								false ->
									ok
							end
					end,
					{noreply, State};
				{Chunk2, Map2} ->
					{Thread, Threads2} = pick_hashing_thread(Threads),
					Thread ! {compute_h2, {Ref, self(), H0, PartitionNumber, Nonce,
							NonceLimiterOutput, ReplicaID, Chunk, Chunk2, H1}},
					Session2 = Session#mining_session{ chunk_cache = Map2 },
					ets:update_counter(?MODULE, chunk_cache_size, {2, -2}),
					prometheus_gauge:dec(mining_server_chunk_cache_size, 2),
					{noreply, State#state{ session = Session2, hashing_threads = Threads2 }}
			end
	end;
handle_task({mining_thread_computed_h1, _Args}, State) ->
	{noreply, State};

handle_task({may_be_remove_chunk_from_cache, {Nonce, CorrelationRef, Ref}},
			#state{ session = #mining_session{ ref = Ref } = Session } = State) ->
	#mining_session{ chunk_cache = Map } = Session,
	case maps:take({CorrelationRef, Nonce}, Map) of
		error ->
			Map2 = maps:put({CorrelationRef, Nonce}, do_not_cache, Map),
			Session2 = Session#mining_session{ chunk_cache = Map2 },
			{noreply, State#state{ session = Session2 }};
		{do_not_cache, Map2} ->
			Session2 = Session#mining_session{ chunk_cache = Map2 },
			{noreply, State#state{ session = Session2 }};
		{_, Map2} ->
			Session2 = Session#mining_session{ chunk_cache = Map2 },
			ets:update_counter(?MODULE, chunk_cache_size, {2, -1}),
			prometheus_gauge:dec(mining_server_chunk_cache_size),
			{noreply, State#state{ session = Session2 }}
	end;
handle_task({may_be_remove_chunk_from_cache, _Args}, State) ->
	{noreply, State};

handle_task({mining_thread_computed_h2, {H0, PartitionNumber, Nonce, Seed, NextSeed,
		StartIntervalNumber, StepNumber, NonceLimiterOutput, ReplicaID, Chunk1, Chunk2, H2,
		Preimage, Ref}},
		#state{ diff = Diff, session = #mining_session{ ref = Ref } } = State) ->
	case binary:decode_unsigned(H2, big) > Diff of
		true ->
			Args = {PartitionNumber, Nonce, H0, Seed, NextSeed, StartIntervalNumber,
					StepNumber, NonceLimiterOutput, ReplicaID, Chunk1, Chunk2, H2, Preimage,
					Ref},
			{noreply, prepare_solution(Args, State)};
		false ->
			{noreply, State}
	end;

prepare_solution(Args, #state{ session = #mining_session{ ref = Ref } } = State)
		when element(15, Args) /= Ref ->
	State;
prepare_solution(Args, State) ->
	{PartitionNumber, Nonce, H0, Seed, NextSeed, StartIntervalNumber, StepNumber,
			NonceLimiterOutput, ReplicaID, Chunk1, Chunk2, H2, Preimage, PartitionUpperBound,
			_Ref} = Args,
	{ok, Config} = application:get_env(arweave, config),
	case Config#config.cm_exit_peer of
		not_set ->
			case ar_wallet:load_key(ReplicaID) of
				not_found ->
					?LOG_WARNING([{event, mined_block_but_no_mining_key_found},
							{mining_address, ar_util:encode(ReplicaID)}]),
					ar:console("WARNING. Can't find key ~w~n", [ar_util:encode(ReplicaID)]),
					State;
				Key ->
					prepare_solution(Args, State, Key)
			end;
		_ ->
			{RecallByte1, RecallByte2} = get_recall_bytes(H0, PartitionNumber, Nonce,
					PartitionUpperBound),
			?LOG_INFO([{event, found_solution_send_to_cm_exit_peer},
					{partition, PartitionNumber},
					{step_number, StepNumber},
					{mining_address, ar_util:encode(ReplicaID)},
					{recall_byte1, RecallByte1},
					{recall_byte2, RecallByte2},
					{solution_h, ar_util:encode(H2)},
					{nonce_limiter_output, ar_util:encode(NonceLimiterOutput)}]),
			Options = #{ pack => true, packing => {spora_2_6, ReplicaID} },
			case ar_data_sync:get_chunk(RecallByte1 + 1, Options) of
				{ok, #{ chunk := Chunk1, tx_path := TXPath1, data_path := DataPath1 }} ->
					PoA1 = #poa{ option = 1, chunk = Chunk1, tx_path = TXPath1,
							data_path = DataPath1 },
					PoA2 =
						case Chunk2 of
							not_set ->
								not_set;
							_ ->
								case ar_data_sync:get_chunk(RecallByte2 + 1, Options) of
									{ok, #{ chunk := Chunk2, tx_path := TXPath2,
											data_path := DataPath2 }} ->
										#poa{ option = 1, chunk = Chunk2, tx_path = TXPath2,
											data_path = DataPath2 };
									_ ->
										error
								end
						end,
					case PoA2 of
						error ->
							?LOG_WARNING([{event,
									mined_block_but_failed_to_read_chunk_proofs_cm},
									{recall_byte2, RecallByte2},
									{mining_address, ar_util:encode(ReplicaID)}]),
							ar:console("WARNING. mined_block_but_failed_to_read_chunk_proofs_cm. Check logs for details~n");
						_ ->
							% TODO error handling
							[{_, TipNonceLimiterInfo}] = ets:lookup(node_state, nonce_limiter_info),
							#nonce_limiter_info{ next_seed = PrevNextSeed,
								global_step_number = PrevStepNumber } = TipNonceLimiterInfo,
							SuppliedCheckpoints = ar_nonce_limiter:get_steps(PrevStepNumber, StepNumber, PrevNextSeed),
							ar_http_iface_client:cm_publish_send(Config#config.cm_exit_peer,
									{PartitionNumber, Nonce, H0, Seed, NextSeed,
									StartIntervalNumber, StepNumber, NonceLimiterOutput,
									ReplicaID, PoA1, PoA2, H2, Preimage, PartitionUpperBound, SuppliedCheckpoints})
					end;
				_ ->
					{RecallRange1Start, _RecallRange2Start} = ar_block:get_recall_range(H0,
							PartitionNumber, PartitionUpperBound),
					?LOG_WARNING([{event, mined_block_but_failed_to_read_chunk_proofs_cm},
							{recall_byte, RecallByte1},
							{recall_range_start, RecallRange1Start},
							{nonce, Nonce},
							{partition, PartitionNumber},
							{mining_address, ar_util:encode(ReplicaID)}]),
					ar:console("WARNING. mined_block_but_failed_to_read_chunk_proofs_cm. Check logs for details~n")
			end,
			State
	end.

prepare_solution(Args, State, Key) ->
	{PartitionNumber, Nonce, H0, _Seed, _NextSeed, _StartIntervalNumber, _StepNumber,
			_NonceLimiterOutput, ReplicaID, Chunk1, Chunk2, _H, _Preimage,
			PartitionUpperBound, _Ref} = Args,
	{RecallByte1, RecallByte2} = get_recall_bytes(H0, PartitionNumber, Nonce,
			PartitionUpperBound),
	Options = #{ pack => true, packing => {spora_2_6, ReplicaID} },
	case ar_data_sync:get_chunk(RecallByte1 + 1, Options) of
		{ok, #{ chunk := Chunk1, tx_path := TXPath1, data_path := DataPath1 }} ->
			PoA1 = #poa{ option = 1, chunk = Chunk1, tx_path = TXPath1,
					data_path = DataPath1 },
			PoA2 =
				case Chunk2 of
					not_set ->
						#poa{};
					_ ->
						case ar_data_sync:get_chunk(RecallByte2 + 1, Options) of
							{ok, #{ chunk := Chunk2, tx_path := TXPath2,
									data_path := DataPath2 }} ->
								#poa{ option = 1, chunk = Chunk2, tx_path = TXPath2,
									data_path = DataPath2 };
							_ ->
								error
						end
				end,
			case PoA2 of
				error ->
					?LOG_WARNING([{event, mined_block_but_failed_to_read_chunk_proofs},
							{recall_byte2, RecallByte2},
							{mining_address, ar_util:encode(ReplicaID)}]),
					ar:console("WARNING. mined_block_but_failed_to_read_chunk_proofs. Check logs for details~n"),
					State;
				_ ->
					RecallByte22 = case Chunk2 of not_set -> undefined; _ -> RecallByte2 end,
					prepare_solution(Args, State, Key, RecallByte1, RecallByte22, PoA1, PoA2, not_found)
			end;
		_ ->
			{RecallRange1Start, _RecallRange2Start} = ar_block:get_recall_range(H0,
					PartitionNumber, PartitionUpperBound),
			?LOG_WARNING([{event, mined_block_but_failed_to_read_chunk_proofs},
					{recall_byte1, RecallByte1},
					{recall_range_start1, RecallRange1Start},
					{nonce, Nonce},
					{partition, PartitionNumber},
					{mining_address, ar_util:encode(ReplicaID)}]),
			ar:console("WARNING. mined_block_but_failed_to_read_chunk_proofs. Check logs for details~n"),
			State
	end.

prepare_solution(Args, State, Key, RecallByte1, RecallByte2, PoA1, PoA2, SuppliedCheckpoints) ->
	{PartitionNumber, Nonce, _H0, Seed, NextSeed, StartIntervalNumber, StepNumber,
			NonceLimiterOutput, ReplicaID, _Chunk1, _Chunk2, H, Preimage, PartitionUpperBound,
			_Ref} = Args,
	#state{ diff = Diff, merkle_rebase_threshold = RebaseThreshold } = State,
	LastStepCheckpoints = ar_nonce_limiter:get_step_checkpoints(
			StepNumber, NextSeed, StartIntervalNumber),
	case validate_solution({NonceLimiterOutput, PartitionNumber, Seed, ReplicaID, Nonce,
			PoA1, PoA2, Diff, PartitionUpperBound, RebaseThreshold}) of
		error ->
			?LOG_WARNING([{event, failed_to_validate_solution},
					{partition, PartitionNumber},
					{step_number, StepNumber},
					{mining_address, ar_util:encode(MiningAddress)},
					{recall_byte1, RecallByte1},
					{recall_byte2, RecallByte2},
					{solution_h, ar_util:encode(H)},
					{nonce_limiter_output, ar_util:encode(NonceLimiterOutput)}]),
			ar:console("WARNING. failed_to_validate_solution. Check logs for details~n"),
			State;
		false ->
			?LOG_WARNING([{event, found_invalid_solution}, {partition, PartitionNumber},
					{step_number, StepNumber},
					{mining_address, ar_util:encode(MiningAddress)},
					{recall_byte1, RecallByte1},
					{recall_byte2, RecallByte2},
					{solution_h, ar_util:encode(H)},
					{nonce_limiter_output, ar_util:encode(NonceLimiterOutput)}]),
			ar:console("WARNING. found_invalid_solution. Check logs for details~n"),
			State;
		{true, PoACache, PoA2Cache} ->
			SolutionArgs = {H, Preimage, PartitionNumber, Nonce, StartIntervalNumber,
					NextSeed, NonceLimiterOutput, StepNumber, SuppliedCheckpoints, LastStepCheckpoints,
					RecallByte1, RecallByte2, PoA1, PoA2, PoACache, PoA2Cache, Key,
					RebaseThreshold},
			?LOG_INFO([{event, found_mining_solution},
					{partition, PartitionNumber}, {step_number, StepNumber},
					{mining_address, ar_util:encode(ReplicaID)},
					{recall_byte1, RecallByte1}, {recall_byte2, RecallByte2},
					{solution_h, ar_util:encode(H)},
					{nonce_limiter_output, ar_util:encode(NonceLimiterOutput)}]),
			ar_events:send(miner, {found_solution, SolutionArgs}),
			State
	end.

validate_solution(Args) ->
	{NonceLimiterOutput, PartitionNumber, Seed, RewardAddr, Nonce, PoA1, PoA2, Diff,
			PartitionUpperBound, RebaseThreshold} = Args,
	H0 = ar_block:compute_h0(NonceLimiterOutput, PartitionNumber, Seed, RewardAddr),
	{H1, _Preimage1} = ar_block:compute_h1(H0, Nonce, PoA1#poa.chunk),
	{RecallRange1Start, RecallRange2Start} = ar_block:get_recall_range(H0,
			PartitionNumber, PartitionUpperBound),

	RecallByte1 = RecallRange1Start + Nonce * ?DATA_CHUNK_SIZE,
	{BlockStart1, BlockEnd1, TXRoot1} = ar_block_index:get_block_bounds(RecallByte1),
	BlockSize1 = BlockEnd1 - BlockStart1,
	case ar_poa:validate({BlockStart1, RecallByte1, TXRoot1, BlockSize1, PoA1,
			?STRICT_DATA_SPLIT_THRESHOLD, {spora_2_6, RewardAddr}, RebaseThreshold,
			not_set}) of
		{true, ChunkID} ->
			PoACache = {{BlockStart1, RecallByte1, TXRoot1, BlockSize1,
					?STRICT_DATA_SPLIT_THRESHOLD, {spora_2_6, RewardAddr}, RebaseThreshold},
					ChunkID},
			case binary:decode_unsigned(H1, big) > Diff of
				true ->
					{true, PoACache, undefined};
				false ->
					{H2, _Preimage2} = ar_block:compute_h2(H1, PoA2#poa.chunk, H0),
					case binary:decode_unsigned(H2, big) > Diff of
						false ->
							false;
						true ->
							RecallByte2 = RecallRange2Start + Nonce * ?DATA_CHUNK_SIZE,
							{BlockStart2, BlockEnd2, TXRoot2} =
									ar_block_index:get_block_bounds(RecallByte2),
							BlockSize2 = BlockEnd2 - BlockStart2,
							case ar_poa:validate({BlockStart2, RecallByte2, TXRoot2,
									BlockSize2, PoA2, ?STRICT_DATA_SPLIT_THRESHOLD,
									{spora_2_6, RewardAddr}, RebaseThreshold, not_set}) of
								{true, Chunk2ID} ->
									PoA2Cache = {{BlockStart2, RecallByte2, TXRoot2,
											BlockSize2, ?STRICT_DATA_SPLIT_THRESHOLD,
											{spora_2_6, RewardAddr}, RebaseThreshold},
											Chunk2ID},
									{true, PoACache, PoA2Cache};
								Result2 ->
									Result2
							end
					end
			end;
		Result ->
			Result
	end.

get_difficulty(State, #mining_candidate{ cm_diff = not_set }) ->
	State#state.diff;
get_difficulty(_State, #mining_candidate{ cm_diff = Diff }) ->
	Diff.

get_recall_bytes(H0, PartitionNumber, Nonce, PartitionUpperBound) ->
	{RecallRange1Start, RecallRange2Start} = ar_block:get_recall_range(H0,
			PartitionNumber, PartitionUpperBound),
	RelativeOffset = Nonce * (?DATA_CHUNK_SIZE),
	{RecallRange1Start + RelativeOffset, RecallRange2Start + RelativeOffset}.

pick_hashing_thread(Threads) ->
	{{value, Thread}, Threads2} = queue:out(Threads),
	{Thread, queue:in(Thread, Threads2)}.

optimal_performance(_StoreID, undefined) ->
	undefined;
optimal_performance("default", _VdfSpeed) ->
	undefined;
optimal_performance(StoreID, VdfSpeed) ->
	{PartitionSize, PartitionIndex, _Packing} = ar_storage_module:get_by_id(StoreID),
	case prometheus_gauge:value(v2_index_data_size_by_packing, [StoreID, spora_2_6,
			PartitionSize, PartitionIndex]) of
		undefined -> 0.0;
		StorageSize -> (200 / VdfSpeed) * (StorageSize / PartitionSize)
	end.

vdf_speed(Now) ->
	case ets:lookup(?MODULE, {performance, nonce_limiter}) of
		[] ->
			undefined;
		[{_, Now, _}] ->
			undefined;
		[{_, _Now, 0}] ->
			undefined;
		[{_, VdfStart, VdfCount}] ->
			ets:update_counter(?MODULE,
							{performance, nonce_limiter},
							[{2, -1, Now, Now}, {3, 0, -1, 0}]),
			VdfLapse = (Now - VdfStart) / 1000,
			VdfLapse / VdfCount
	end.

reset_mining_session(State) ->
	#state{ hashing_threads = HashingThreads, io_threads = IOThreads } = State,
	Ref = make_ref(),
	[Thread ! {new_mining_session, Ref} || Thread <- queue:to_list(HashingThreads)],
	[Thread ! {new_mining_session, Ref} || Thread <- maps:values(IOThreads)],
	CacheSizeLimit = get_chunk_cache_size_limit(State),
	log_chunk_cache_size_limit(CacheSizeLimit),
	ets:insert(?MODULE, {chunk_cache_size, 0}),
	prometheus_gauge:set(mining_server_chunk_cache_size, 0),
	ar_coordination:reset_mining_session(),
	#mining_session{ ref = Ref, chunk_cache_size_limit = CacheSizeLimit }.

%%%===================================================================
%%% Tests.
%%%===================================================================

read_recall_range_test() ->
	H0 = crypto:strong_rand_bytes(32),
	Output = crypto:strong_rand_bytes(32),
	Ref = make_ref(),
	ReplicaID = crypto:strong_rand_bytes(32),
	Chunk = crypto:strong_rand_bytes(?DATA_CHUNK_SIZE),
	ChunkOffsets = [{?DATA_CHUNK_SIZE, Chunk}],
	CorrelationRef = {0, 0, 1, make_ref()},
	read_recall_range(type, H0, 0, 0, <<>>, <<>>, 0, 0, Output, ReplicaID, self(), 0, 1,
			ChunkOffsets, Ref, CorrelationRef),
	receive {type, {H0, 0, 0, 0, Output, ReplicaID, Chunk, CorrelationRef, Ref}} ->
		ok
	after 1000 ->
		?assert(false, "Did not receive the expected message.")
	end.
