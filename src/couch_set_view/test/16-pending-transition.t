#!/usr/bin/env escript
%% -*- Mode: Erlang; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil -*- */
%%! -smp enable

% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-include("../../couchdb/couch_db.hrl").
-include_lib("couch_set_view/include/couch_set_view.hrl").

-define(MAX_WAIT_TIME, 600 * 1000).

test_set_name() -> <<"couch_test_set_pending_transition">>.
num_set_partitions() -> 64.
ddoc_id() -> <<"_design/test">>.
num_docs() -> 20288.  % keep it a multiple of num_set_partitions()

admin_user_ctx() ->
    {user_ctx, #user_ctx{roles = [<<"_admin">>]}}.


main(_) ->
    test_util:init_code_path(),

    etap:plan(73),
    case (catch test()) of
        ok ->
            etap:end_tests();
        Other ->
            etap:diag(io_lib:format("Test died abnormally: ~p", [Other])),
            etap:bail(Other)
    end,
    ok.


test() ->
    couch_set_view_test_util:start_server(test_set_name()),

    create_set(),
    ValueGenFun1 = fun(I) -> I end,
    update_documents(0, num_docs(), ValueGenFun1),

    GroupPid = couch_set_view:get_group_pid(
        mapreduce_view, test_set_name(), ddoc_id(), prod),
    ok = gen_server:call(GroupPid, {set_auto_cleanup, false}, infinity),

    % build index
    _ = get_group_snapshot(),

    verify_btrees_1(ValueGenFun1),

    etap:diag("Marking all odd partitions for cleanup"),
    ok = couch_set_view:set_partition_states(
        mapreduce_view, test_set_name(), ddoc_id(), [], [],
        lists:seq(1, num_set_partitions() - 1, 2)),

    verify_btrees_2(ValueGenFun1),

    etap:diag("Marking partition 1 as active and all even partitions, "
              "except partition 0, for cleanup"),
    ok = couch_set_view:set_partition_states(
        mapreduce_view, test_set_name(), ddoc_id(),
        [1], [], lists:seq(2, num_set_partitions() - 1, 2)),

    verify_btrees_3(ValueGenFun1),

    test_unindexable_partitions(),

    test_pending_transition_changes(),

    lists:foreach(fun(PartId) ->
        etap:diag("Deleting partition " ++ integer_to_list(PartId) ++
            ", currently marked for cleanup in the pending transition"),
        ok = couch_set_view_test_util:delete_set_db(test_set_name(), PartId)
    end, lists:seq(2, num_set_partitions() - 1, 2)),
    ok = timer:sleep(5000),
    etap:is(is_process_alive(GroupPid), true, "Group process didn't die"),

    % Recreate database 1, populate new contents, verify that neither old
    % contents nor new contents are in the index after a stale=false request.
    etap:diag("Recreating partition 1 database, currenly marked as active in the"
              " pending transition - shouldn't cause the group process to die"),
    ok = couch_set_view:set_partition_states(
           mapreduce_view, test_set_name(), ddoc_id(), [], [], [1]),
    recreate_db(1, 9000009),
    ok = timer:sleep(6000),
    etap:is(is_process_alive(GroupPid), true, "Group process didn't die"),

    {ok, Db0} = open_db(0),
    Doc = couch_doc:from_json_obj({[
        {<<"meta">>, {[{<<"id">>, doc_id(9000010)}]}},
        {<<"json">>, {[
            {<<"value">>, 9000010}
        ]}}
    ]}),
    ok = couch_db:update_doc(Db0, Doc, []),
    ok = couch_db:close(Db0),

    % update index - updater will trigger a cleanup and apply the pending transition
    _ = get_group_snapshot(),

    verify_btrees_4(ValueGenFun1),
    compact_view_group(),
    verify_btrees_4(ValueGenFun1),

    test_monitor_pending_partition(),

    couch_set_view_test_util:delete_set_dbs(test_set_name(), num_set_partitions() - 1),
    couch_set_view_test_util:stop_server(),
    ok.


recreate_db(PartId, Value) ->
    DbName = iolist_to_binary([test_set_name(), $/, integer_to_list(PartId)]),
    ok = couch_server:delete(DbName, [admin_user_ctx()]),
    ok = timer:sleep(300),
    {ok, Db} = couch_db:create(DbName, [admin_user_ctx()]),
    Doc = couch_doc:from_json_obj({[
        {<<"meta">>, {[{<<"id">>, doc_id(Value)}]}},
        {<<"json">>, {[
            {<<"value">>, Value}
        ]}}
    ]}),
    ok = couch_db:update_doc(Db, Doc, []),
    ok = couch_db:close(Db).


open_db(PartId) ->
    DbName = iolist_to_binary([test_set_name(), $/, integer_to_list(PartId)]),
    {ok, _} = couch_db:open_int(DbName, []).


create_set() ->
    couch_set_view_test_util:delete_set_dbs(test_set_name(), num_set_partitions()),
    couch_set_view_test_util:create_set_dbs(test_set_name(), num_set_partitions()),
    couch_set_view:cleanup_index_files(mapreduce_view, test_set_name()),
    etap:diag("Creating the set databases (# of partitions: " ++
        integer_to_list(num_set_partitions()) ++ ")"),
    DDoc = {[
        {<<"meta">>, {[{<<"id">>, ddoc_id()}]}},
        {<<"json">>, {[
        {<<"language">>, <<"javascript">>},
        {<<"views">>, {[
            {<<"view_1">>, {[
                {<<"map">>, <<"function(doc, meta) { emit(meta.id, doc.value); }">>},
                {<<"reduce">>, <<"_count">>}
            ]}}
        ]}}
        ]}}
    ]},
    ok = couch_set_view_test_util:update_ddoc(test_set_name(), DDoc),
    etap:diag("Configuring set view with partitions [0 .. 63] as active"),
    Params = #set_view_params{
        max_partitions = num_set_partitions(),
        active_partitions = lists:seq(0, 63),
        passive_partitions = [],
        use_replica_index = false
    },
    ok = couch_set_view:define_group(
        mapreduce_view, test_set_name(), ddoc_id(), Params).


update_documents(StartId, NumDocs, ValueGenFun) ->
    etap:diag("About to update " ++ integer_to_list(NumDocs) ++ " documents"),
    Dbs = dict:from_list(lists:map(
        fun(I) ->
            {ok, Db} = couch_set_view_test_util:open_set_db(test_set_name(), I),
            {I, Db}
        end,
        lists:seq(0, num_set_partitions() - 1))),
    Docs = lists:foldl(
        fun(I, Acc) ->
            Doc = couch_doc:from_json_obj({[
                {<<"meta">>, {[{<<"id">>, doc_id(I)}]}},
                {<<"json">>, {[
                    {<<"value">>, ValueGenFun(I)}
                ]}}
            ]}),
            DocList = case orddict:find(I rem num_set_partitions(), Acc) of
            {ok, L} ->
                L;
            error ->
                []
            end,
            orddict:store(I rem num_set_partitions(), [Doc | DocList], Acc)
        end,
        orddict:new(), lists:seq(StartId, StartId + NumDocs - 1)),
    [] = orddict:fold(
        fun(I, DocList, Acc) ->
            Db = dict:fetch(I, Dbs),
            ok = couch_db:update_docs(Db, DocList, [sort_docs]),
            Acc
        end,
        [], Docs),
    etap:diag("Updated " ++ integer_to_list(NumDocs) ++ " documents"),
    ok = lists:foreach(fun({_, Db}) -> ok = couch_db:close(Db) end, dict:to_list(Dbs)).


doc_id(I) ->
    iolist_to_binary(io_lib:format("doc_~8..0b", [I])).


verify_btrees_1(ValueGenFun) ->
    Group = get_group_snapshot(),
    etap:diag("Verifying btrees"),
    #set_view_group{
        id_btree = IdBtree,
        views = [View1],
        index_header = #set_view_index_header{
            pending_transition = PendingTrans,
            seqs = HeaderUpdateSeqs,
            abitmask = Abitmask,
            pbitmask = Pbitmask,
            cbitmask = Cbitmask
        }
    } = Group,
    #set_view{
        indexer = #mapreduce_view{
            btree = View1Btree
        }
    } = View1,
    ActiveParts = lists:seq(0, num_set_partitions() - 1),
    ExpectedBitmask = couch_set_view_util:build_bitmask(ActiveParts),
    ExpectedABitmask = couch_set_view_util:build_bitmask(ActiveParts),
    DbSeqs = couch_set_view_test_util:get_db_seqs(
        test_set_name(), lists:seq(0, num_set_partitions() - 1)),
    ExpectedKVCount = num_docs(),
    ExpectedBtreeViewReduction = num_docs(),

    etap:is(
        couch_set_view_test_util:full_reduce_id_btree(Group, IdBtree),
        {ok, {ExpectedKVCount, ExpectedBitmask}},
        "Id Btree has the right reduce value"),
    etap:is(
        couch_set_view_test_util:full_reduce_view_btree(Group, View1Btree),
        {ok, {ExpectedKVCount, [ExpectedBtreeViewReduction], ExpectedBitmask}},
        "View1 Btree has the right reduce value"),

    etap:is(HeaderUpdateSeqs, DbSeqs, "Header has right update seqs list"),
    etap:is(Abitmask, ExpectedABitmask, "Header has right active bitmask"),
    etap:is(Pbitmask, 0, "Header has right passive bitmask"),
    etap:is(Cbitmask, 0, "Header has right cleanup bitmask"),
    etap:is(PendingTrans, nil, "Header has nil pending transition"),

    etap:diag("Verifying the Id Btree"),
    MaxPerPart = num_docs() div num_set_partitions(),
    {ok, _, {_, _, _, IdBtreeFoldResult}} = couch_set_view_test_util:fold_id_btree(
        Group,
        IdBtree,
        fun(Kv, _, {P0, I0, C0, It}) ->
            case C0 >= MaxPerPart of
            true ->
                P = P0 + 1,
                I = P,
                C = 1;
            false ->
                P = P0,
                I = I0,
                C = C0 + 1
            end,
            true = (P < num_set_partitions()),
            DocId = doc_id(I),
            Value = [{View1#set_view.id_num, DocId}],
            ExpectedKv = {<<P:16, DocId/binary>>, {P, Value}},
            case ExpectedKv =:= Kv of
            true ->
                ok;
            false ->
                etap:bail("Id Btree has an unexpected KV at iteration " ++ integer_to_list(It))
            end,
            {ok, {P, I + num_set_partitions(), C, It + 1}}
        end,
        {0, 0, 0, 0}, []),
    etap:is(IdBtreeFoldResult, ExpectedKVCount,
        "Id Btree has " ++ integer_to_list(ExpectedKVCount) ++ " entries"),

    etap:diag("Verifying the View1 Btree"),
    {ok, _, View1BtreeFoldResult} = couch_set_view_test_util:fold_view_btree(
        Group,
        View1Btree,
        fun(Kv, _, I) ->
            PartId = I rem num_set_partitions(),
            DocId = doc_id(I),
            ExpectedKv = {{DocId, DocId}, {PartId, ValueGenFun(I)}},
            case ExpectedKv =:= Kv of
            true ->
                ok;
            false ->
                etap:bail("View1 Btree has an unexpected KV at iteration " ++ integer_to_list(I))
            end,
            {ok, I + 1}
        end,
        0, []),
    etap:is(View1BtreeFoldResult, ExpectedKVCount,
        "View1 Btree has " ++ integer_to_list(ExpectedKVCount) ++ " entries"),
    ok.


verify_btrees_2(ValueGenFun) ->
    Group = get_group_snapshot(),
    etap:diag("Verifying btrees"),
    #set_view_group{
        id_btree = IdBtree,
        views = [View1],
        index_header = #set_view_index_header{
            pending_transition = PendingTrans,
            seqs = HeaderUpdateSeqs,
            abitmask = Abitmask,
            pbitmask = Pbitmask,
            cbitmask = Cbitmask
        }
    } = Group,
    #set_view{
        indexer = #mapreduce_view{
            btree = View1Btree
        }
    } = View1,
    ActiveParts = lists:seq(0, num_set_partitions() - 1, 2),
    CleanupParts = lists:seq(1, num_set_partitions() - 1, 2),
    ExpectedBitmask = couch_set_view_util:build_bitmask(lists:seq(0, num_set_partitions() - 1)),
    ExpectedABitmask = couch_set_view_util:build_bitmask(ActiveParts),
    ExpectedCBitmask = couch_set_view_util:build_bitmask(CleanupParts),
    ExpectedDbSeqs = couch_set_view_test_util:get_db_seqs(test_set_name(), ActiveParts),
    ExpectedKVCount = num_docs(),
    ExpectedBtreeViewReduction = num_docs(),

    etap:is(
        couch_set_view_test_util:full_reduce_id_btree(Group, IdBtree),
        {ok, {ExpectedKVCount, ExpectedBitmask}},
        "Id Btree has the right reduce value"),
    etap:is(
        couch_set_view_test_util:full_reduce_view_btree(Group, View1Btree),
        {ok, {ExpectedKVCount, [ExpectedBtreeViewReduction], ExpectedBitmask}},
        "View1 Btree has the right reduce value"),

    etap:is(HeaderUpdateSeqs, ExpectedDbSeqs, "Header has right update seqs list"),
    etap:is(Abitmask, ExpectedABitmask, "Header has right active bitmask"),
    etap:is(Pbitmask, 0, "Header has right passive bitmask"),
    etap:is(Cbitmask, ExpectedCBitmask, "Header has right cleanup bitmask"),
    etap:is(PendingTrans, nil, "Header has nil pending transition"),

    etap:diag("Verifying the Id Btree"),
    MaxPerPart = num_docs() div num_set_partitions(),
    {ok, _, {_, _, _, IdBtreeFoldResult}} = couch_set_view_test_util:fold_id_btree(
        Group,
        IdBtree,
        fun(Kv, _, {P0, I0, C0, It}) ->
            case C0 >= MaxPerPart of
            true ->
                P = P0 + 1,
                I = P,
                C = 1;
            false ->
                P = P0,
                I = I0,
                C = C0 + 1
            end,
            true = (P < num_set_partitions()),
            DocId = doc_id(I),
            Value = [{View1#set_view.id_num, DocId}],
            ExpectedKv = {<<P:16, DocId/binary>>, {P, Value}},
            case ExpectedKv =:= Kv of
            true ->
                ok;
            false ->
                etap:bail("Id Btree has an unexpected KV at iteration " ++ integer_to_list(It))
            end,
            {ok, {P, I + num_set_partitions(), C, It + 1}}
        end,
        {0, 0, 0, 0}, []),
    etap:is(IdBtreeFoldResult, ExpectedKVCount,
        "Id Btree has " ++ integer_to_list(ExpectedKVCount) ++ " entries"),

    etap:diag("Verifying the View1 Btree"),
    {ok, _, View1BtreeFoldResult} = couch_set_view_test_util:fold_view_btree(
        Group,
        View1Btree,
        fun(Kv, _, I) ->
            PartId = I rem num_set_partitions(),
            DocId = doc_id(I),
            ExpectedKv = {{DocId, DocId}, {PartId, ValueGenFun(I)}},
            case ExpectedKv =:= Kv of
            true ->
                ok;
            false ->
                etap:bail("View1 Btree has an unexpected KV at iteration " ++ integer_to_list(I))
            end,
            {ok, I + 1}
        end,
        0, []),
    etap:is(View1BtreeFoldResult, ExpectedKVCount,
        "View1 Btree has " ++ integer_to_list(ExpectedKVCount) ++ " entries"),
    ok.


verify_btrees_3(ValueGenFun) ->
    Group = get_group_snapshot(),
    etap:diag("Verifying btrees"),
    #set_view_group{
        id_btree = IdBtree,
        views = [View1],
        index_header = #set_view_index_header{
            pending_transition = PendingTrans,
            seqs = HeaderUpdateSeqs,
            abitmask = Abitmask,
            pbitmask = Pbitmask,
            cbitmask = Cbitmask
        }
    } = Group,
    #set_view{
        indexer = #mapreduce_view{
            btree = View1Btree
        }
    } = View1,
    ActiveParts = [0],
    CleanupParts = lists:seq(1, num_set_partitions() - 1),
    ExpectedBitmask = couch_set_view_util:build_bitmask(lists:seq(0, num_set_partitions() - 1)),
    ExpectedABitmask = couch_set_view_util:build_bitmask(ActiveParts),
    ExpectedCBitmask = couch_set_view_util:build_bitmask(CleanupParts),
    ExpectedDbSeqs = couch_set_view_test_util:get_db_seqs(test_set_name(), ActiveParts),
    ExpectedKVCount = num_docs(),
    ExpectedBtreeViewReduction = num_docs(),
    ExpectedPendingTrans = #set_view_transition{
        active = [1],
        passive = [],
        unindexable = []
    },

    etap:is(
        couch_set_view_test_util:full_reduce_id_btree(Group, IdBtree),
        {ok, {ExpectedKVCount, ExpectedBitmask}},
        "Id Btree has the right reduce value"),
    etap:is(
        couch_set_view_test_util:full_reduce_view_btree(Group, View1Btree),
        {ok, {ExpectedKVCount, [ExpectedBtreeViewReduction], ExpectedBitmask}},
        "View1 Btree has the right reduce value"),

    etap:is(HeaderUpdateSeqs, ExpectedDbSeqs, "Header has right update seqs list"),
    etap:is(Abitmask, ExpectedABitmask, "Header has right active bitmask"),
    etap:is(Pbitmask, 0, "Header has right passive bitmask"),
    etap:is(Cbitmask, ExpectedCBitmask, "Header has right cleanup bitmask"),
    etap:is(PendingTrans, ExpectedPendingTrans, "Header has expected pending transition"),

    etap:diag("Verifying the Id Btree"),
    MaxPerPart = num_docs() div num_set_partitions(),
    {ok, _, {_, _, _, IdBtreeFoldResult}} = couch_set_view_test_util:fold_id_btree(
        Group,
        IdBtree,
        fun(Kv, _, {P0, I0, C0, It}) ->
            case C0 >= MaxPerPart of
            true ->
                P = P0 + 1,
                I = P,
                C = 1;
            false ->
                P = P0,
                I = I0,
                C = C0 + 1
            end,
            true = (P < num_set_partitions()),
            DocId = doc_id(I),
            Value = [{View1#set_view.id_num, DocId}],
            ExpectedKv = {<<P:16, DocId/binary>>, {P, Value}},
            case ExpectedKv =:= Kv of
            true ->
                ok;
            false ->
                etap:bail("Id Btree has an unexpected KV at iteration " ++ integer_to_list(It))
            end,
            {ok, {P, I + num_set_partitions(), C, It + 1}}
        end,
        {0, 0, 0, 0}, []),
    etap:is(IdBtreeFoldResult, ExpectedKVCount,
        "Id Btree has " ++ integer_to_list(ExpectedKVCount) ++ " entries"),

    etap:diag("Verifying the View1 Btree"),
    {ok, _, View1BtreeFoldResult} = couch_set_view_test_util:fold_view_btree(
        Group,
        View1Btree,
        fun(Kv, _, I) ->
            PartId = I rem num_set_partitions(),
            DocId = doc_id(I),
            ExpectedKv = {{DocId, DocId}, {PartId, ValueGenFun(I)}},
            case ExpectedKv =:= Kv of
            true ->
                ok;
            false ->
                etap:bail("View1 Btree has an unexpected KV at iteration " ++ integer_to_list(I))
            end,
            {ok, I + 1}
        end,
        0, []),
    etap:is(View1BtreeFoldResult, ExpectedKVCount,
        "View1 Btree has " ++ integer_to_list(ExpectedKVCount) ++ " entries"),
    ok.


verify_btrees_4(ValueGenFun) ->
    Group = get_group_snapshot(),
    etap:diag("Verifying btrees"),
    #set_view_group{
        id_btree = IdBtree,
        views = [View1],
        index_header = #set_view_index_header{
            pending_transition = PendingTrans,
            seqs = HeaderUpdateSeqs,
            abitmask = Abitmask,
            pbitmask = Pbitmask,
            cbitmask = Cbitmask
        }
    } = Group,
    #set_view{
        indexer = #mapreduce_view{
            btree = View1Btree
        }
    } = View1,
    ActiveParts = [0],
    ExpectedBitmask = couch_set_view_util:build_bitmask(ActiveParts),
    ExpectedABitmask = couch_set_view_util:build_bitmask(ActiveParts),
    ExpectedDbSeqs = couch_set_view_test_util:get_db_seqs(test_set_name(), ActiveParts),
    ExpectedKVCount = (num_docs() div num_set_partitions()) + 1,
    ExpectedBtreeViewReduction = (num_docs() div num_set_partitions()) + 1,

    etap:is(
        couch_set_view_test_util:full_reduce_id_btree(Group, IdBtree),
        {ok, {ExpectedKVCount, ExpectedBitmask}},
        "Id Btree has the right reduce value"),
    etap:is(
        couch_set_view_test_util:full_reduce_view_btree(Group, View1Btree),
        {ok, {ExpectedKVCount, [ExpectedBtreeViewReduction], ExpectedBitmask}},
        "View1 Btree has the right reduce value"),

    etap:is(HeaderUpdateSeqs, ExpectedDbSeqs, "Header has right update seqs list"),
    etap:is(Abitmask, ExpectedABitmask, "Header has right active bitmask"),
    etap:is(Pbitmask, 0, "Header has right passive bitmask"),
    etap:is(Cbitmask, 0, "Header has right cleanup bitmask"),
    etap:is(PendingTrans, nil, "Header has nil pending transition"),

    etap:diag("Verifying the Id Btree"),
    {ok, _, {_, IdBtreeFoldResult}} = couch_set_view_test_util:fold_id_btree(
        Group,
        IdBtree,
        fun(Kv, _, {I, Count}) ->
            PartId = 0,
            case Count == (ExpectedKVCount - 1) of
            true ->
                DocId = doc_id(9000010);
            false ->
                DocId = doc_id(I)
            end,
            Value = [{View1#set_view.id_num, DocId}],
            ExpectedKv = {<<PartId:16, DocId/binary>>, {PartId, Value}},
            case ExpectedKv =:= Kv of
            true ->
                ok;
            false ->
                etap:bail("Id Btree has an unexpected KV at iteration " ++ integer_to_list(Count))
            end,
            {ok, {I + 64, Count + 1}}
        end,
        {0, 0}, []),
    etap:is(IdBtreeFoldResult, ExpectedKVCount,
        "Id Btree has " ++ integer_to_list(ExpectedKVCount) ++ " entries"),

    etap:diag("Verifying the View1 Btree"),
    {ok, _, {_, View1BtreeFoldResult}} = couch_set_view_test_util:fold_view_btree(
        Group,
        View1Btree,
        fun(Kv, _, {I, Count}) ->
            case Count == (ExpectedKVCount - 1) of
            true ->
                DocId = doc_id(9000010),
                PartId = 0,
                Value = 9000010;
            false ->
                DocId = doc_id(I),
                PartId = I rem num_set_partitions(),
                Value = ValueGenFun(I)
            end,
            ExpectedKv = {{DocId, DocId}, {PartId, Value}},
            case ExpectedKv =:= Kv of
            true ->
                ok;
            false ->
                etap:bail("View1 Btree has an unexpected KV at iteration " ++ integer_to_list(Count))
            end,
            {ok, {I + 64, Count + 1}}
        end,
        {0, 0}, []),
    etap:is(View1BtreeFoldResult, ExpectedKVCount,
        "View1 Btree has " ++ integer_to_list(ExpectedKVCount) ++ " entries"),
    ok.


get_group_snapshot() ->
    get_group_snapshot(false).

get_group_snapshot(Staleness) ->
    GroupPid = couch_set_view:get_group_pid(
        mapreduce_view, test_set_name(), ddoc_id(), prod),
    {ok, Group, 0} = gen_server:call(
        GroupPid, #set_view_group_req{stale = Staleness, debug = true}, infinity),
    Group.


compact_view_group() ->
    {ok, CompactPid} = couch_set_view_compactor:start_compact(
        mapreduce_view, test_set_name(), ddoc_id(), main),
    Ref = erlang:monitor(process, CompactPid),
    etap:diag("Waiting for main view group compaction to finish"),
    receive
    {'DOWN', Ref, process, CompactPid, normal} ->
        ok;
    {'DOWN', Ref, process, CompactPid, noproc} ->
        ok;
    {'DOWN', Ref, process, CompactPid, Reason} ->
        etap:bail("Failure compacting main view group: " ++ couch_util:to_list(Reason))
    after ?MAX_WAIT_TIME ->
        etap:bail("Timeout waiting for main view group compaction to finish")
    end.


test_unindexable_partitions() ->
    % Verify that partitions in the pending transition can be marked
    % as unindexable and indexable back again.
    Group0 = get_group_snapshot(ok),
    PrevPendingTrans = ?set_pending_transition(Group0),

    NewActivePending = lists:seq(1, num_set_partitions() div 2, 2),
    NewPassivePending = lists:seq(num_set_partitions() div 2, num_set_partitions() - 1, 2),
    ok = couch_set_view:set_partition_states(
        mapreduce_view, test_set_name(), ddoc_id(), NewActivePending,
        NewPassivePending, []),

    PendingActiveUnindexable = lists:sublist(NewActivePending, length(NewActivePending) div 2),
    PendingPassiveUnindexable = lists:sublist(NewPassivePending, length(NewPassivePending) div 2),
    Unindexable = ordsets:union(PendingActiveUnindexable, PendingPassiveUnindexable),
    ok = couch_set_view:mark_partitions_unindexable(
        mapreduce_view, test_set_name(), ddoc_id(), Unindexable),

    etap:diag("Marking unindexable partitions to the state they're already in, is a no-op"),
    ok = couch_set_view:set_partition_states(
        mapreduce_view, test_set_name(), ddoc_id(),
        PendingActiveUnindexable, PendingPassiveUnindexable, []),

    Group1 = get_group_snapshot(ok),
    PendingTrans = ?set_pending_transition(Group1),
    etap:is(?pending_transition_unindexable(PendingTrans),
            Unindexable,
            "Right set of unindexable partitions in pending transition"),
    etap:is(?pending_transition_active(PendingTrans),
            NewActivePending,
            "Right set of active partitions in pending transition"),
    etap:is(?pending_transition_passive(PendingTrans),
            NewPassivePending,
            "Right set of passive partitions in pending transition"),
    etap:is(?set_unindexable_seqs(Group1),
            [],
            "Right set of unindexable partitions"),

    ok = couch_set_view:mark_partitions_indexable(
        mapreduce_view, test_set_name(), ddoc_id(), Unindexable),

    Group2 = get_group_snapshot(ok),
    PendingTrans2 = ?set_pending_transition(Group2),
    etap:is(?pending_transition_unindexable(PendingTrans2),
            [],
            "Empty set of unindexable partitions in pending transition"),
    etap:is(?pending_transition_active(PendingTrans2),
            NewActivePending,
            "Right set of active partitions in pending transition"),
    etap:is(?pending_transition_passive(PendingTrans2),
            NewPassivePending,
            "Right set of passive partitions in pending transition"),
    etap:is(?set_unindexable_seqs(Group2),
            [],
            "Right set of unindexable partitions"),

    % Restore to previous state
    PrevActivePending = ?pending_transition_active(PrevPendingTrans),
    PrevPassivePending = ?pending_transition_passive(PrevPendingTrans),
    ok = couch_set_view:set_partition_states(
        mapreduce_view, test_set_name(), ddoc_id(), [], [],
        ordsets:union(NewActivePending, NewPassivePending)),
    ok = couch_set_view:set_partition_states(
        mapreduce_view, test_set_name(), ddoc_id(), PrevActivePending,
        PrevPassivePending, []).


test_monitor_pending_partition() ->
    % Mark partition 0 for cleanup, recreate it (1 doc), add it to pending transition,
    % ask to monitor partition 0, perform cleanup/update and check an update message
    % is received after.
    etap:diag("Marking partition 0 for cleanup"),
    ok = couch_set_view:set_partition_states(
        mapreduce_view, test_set_name(), ddoc_id(), [], [], [0]),

    Group0 = get_group_snapshot(ok),
    etap:is(?set_seqs(Group0), [], "Empty list of seqs in group snapshot"),
    etap:is(?set_cbitmask(Group0), 1, "Partition 0 in cleanup bitmask"),

    etap:diag("Recreating partition 0 database"),
    recreate_db(0, 9000011),

    etap:diag("Marking partition 0 as active while it's still in cleanup"),
    ok = couch_set_view:set_partition_states(
        mapreduce_view, test_set_name(), ddoc_id(), [0], [], []),

    Group1 = get_group_snapshot(ok),
    PendingTrans1 = ?set_pending_transition(Group1),
    etap:is(?set_cbitmask(Group1), 1, "Partition 0 in cleanup bitmask"),
    etap:is(?pending_transition_active(PendingTrans1), [0],
            "Partition 0 in pending transition"),

    Parent = self(),
    {ListenerPid, ListenerRef} = spawn_monitor(fun() ->
        etap:diag("Asking view group to monitor partition 0 (in pending transition)"),
        Ref1 = couch_set_view:monitor_partition_update(
            mapreduce_view, test_set_name(), ddoc_id(), 0),
        Parent ! {self(), ok},
        receive
        {Ref1, Reason} ->
            exit(Reason)
        end
    end),

    receive
    {ListenerPid, ok} ->
        etap:diag("Received ack from listener child");
    {'DOWN', ListenerRef, _, _, Reason} ->
        etap:bail("Child terminated with reason: " ++ couch_util:to_list(Reason))
    after 10000 ->
        etap:bail("Timeout waiting for child listener ack")
    end,

    % Perform cleanup + apply pending transition + update + notify listener
    GroupPid = couch_set_view:get_group_pid(
        mapreduce_view, test_set_name(), ddoc_id(), prod),
    {ok, CleanerPid} = gen_server:call(GroupPid, start_cleaner, infinity),
    CleanerRef = erlang:monitor(process, CleanerPid),
    receive
    {'DOWN', CleanerRef, _, _, _} ->
        ok
    after 60000 ->
        etap:bail("Timeout waiting for cleaner to finish")
    end,

    Group2 = get_group_snapshot(false),
    #set_view_group{
        id_btree = IdBtree,
        views = [#set_view{indexer = #mapreduce_view{btree = View1Btree}}]
    } = Group2,

    etap:is(?set_cbitmask(Group2), 0, "Cleanup bitmask is 0"),
    etap:is(?set_abitmask(Group2), 1, "Active bitmask is 1"),
    etap:is(?set_pending_transition(Group2), nil, "Pending transition is nil"),

    receive
    {'DOWN', ListenerRef, _, _, updated} ->
        etap:diag("Child got notified partition was updated in index");
    {'DOWN', ListenerRef, _, _, Reason2} ->
        etap:bail("Child terminated with reason: " ++ couch_util:to_list(Reason2))
    after 30000 ->
        etap:bail("Child didn't terminate after pending transition was applied")
    end,

    etap:diag("Verifying the Id Btree"),
    {ok, _, IdBtreeFoldResult} = couch_set_view_test_util:fold_id_btree(
        Group2,
        IdBtree,
        fun(Kv, _, Acc) -> {ok, [Kv | Acc]} end,
        [], []),
    etap:is(IdBtreeFoldResult, [{<<0:16, (doc_id(9000011))/binary>>, {0, [{0, doc_id(9000011)}]}}],
            "Id Btree has 1 entry"),

    etap:diag("Verifying the View1 Btree"),
    {ok, _, View1BtreeFoldResult} = couch_set_view_test_util:fold_view_btree(
        Group2,
        View1Btree,
        fun(Kv, _, Acc) -> {ok, [Kv | Acc]} end,
        [], []),
    etap:is(View1BtreeFoldResult, [{{doc_id(9000011), doc_id(9000011)}, {0, 9000011}}],
            "View1 Btree has 1 entry"),
    ok.


test_pending_transition_changes() ->
    Group0 = get_group_snapshot(ok),
    PendingTrans0 = ?set_pending_transition(Group0),
    etap:is(?pending_transition_active(PendingTrans0), [1],
            "Partition 1 in pending transition active set"),
    etap:is(?pending_transition_passive(PendingTrans0), [],
            "Empty pending transition passive set"),
    etap:is(?pending_transition_unindexable(PendingTrans0), [],
            "Empty pending transition unindexable set"),

    ok = couch_set_view:set_partition_states(
        mapreduce_view, test_set_name(), ddoc_id(), [], [1], []),

    Group1 = get_group_snapshot(ok),
    PendingTrans1 = ?set_pending_transition(Group1),
    etap:is(?pending_transition_active(PendingTrans1), [],
            "Empty pending transition active set"),
    etap:is(?pending_transition_passive(PendingTrans1), [1],
            "Partition 1 in pending transition passive set"),
    etap:is(?pending_transition_unindexable(PendingTrans1), [],
            "Empty pending transition unindexable set"),

    ok = couch_set_view:set_partition_states(
        mapreduce_view, test_set_name(), ddoc_id(), [1], [], []),

    Group2 = get_group_snapshot(ok),
    PendingTrans2 = ?set_pending_transition(Group2),
    etap:is(?pending_transition_active(PendingTrans2), [1],
            "Partition 1 in pending transition active set"),
    etap:is(?pending_transition_passive(PendingTrans2), [],
            "Empty pending transition passive set"),
    etap:is(?pending_transition_unindexable(PendingTrans2), [],
            "Empty pending transition unindexable set"),
    ok.
