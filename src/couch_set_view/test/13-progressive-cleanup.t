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

-define(MAX_WAIT_TIME, 900 * 1000).

test_set_name() -> <<"couch_test_set_index_cleanups">>.
num_set_partitions() -> 64.
ddoc_id() -> <<"_design/test">>.
num_docs() -> 21312.  % keep it a multiple of num_set_partitions()


main(_) ->
    test_util:init_code_path(),

    etap:plan(770),
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
    add_documents(0, num_docs()),
    GroupPid = couch_set_view:get_group_pid(
        mapreduce_view, test_set_name(), ddoc_id(), prod),
    erlang:put(group_pid, GroupPid),

    % build index
    _ = get_group_snapshot(),

    ActivePartitions1 = lists:seq(0, 63),
    ExpectedReduceValue1 = 3 * lists:sum(lists:seq(0, num_docs() - 1)),
    FoldFun = fun(PartId, {ActivePartsAcc, RedValueAcc}) ->
        ActivePartsAcc2 = ordsets:del_element(PartId, ActivePartsAcc),
        RedValueAcc2 = RedValueAcc - (3 * lists:sum(
            lists:seq(PartId, num_docs() - 1, num_set_partitions())
        )),
        ok = couch_set_view:set_partition_states(
            mapreduce_view, test_set_name(), ddoc_id(), [], [], [PartId]),
        wait_for_cleanup(),
        verify_btrees(ActivePartsAcc2, RedValueAcc2),
        {ActivePartsAcc2, RedValueAcc2}
    end,

    etap:diag("Starting phase 1 cleanup"),

    {ActivePartitions2, ExpectedReduceValue2} = lists:foldl(
        FoldFun,
        {ActivePartitions1, ExpectedReduceValue1},
        lists:seq(1, 63, 2)),

    etap:diag("Phase 1 cleanup finished"),

    etap:is(
        ActivePartitions2,
        lists:seq(0, 63, 2),
        "Right list of active partitions after first cleanup phase"),

    etap:diag("Starting phase 2 cleanup"),

    {ActivePartitions3, _} = lists:foldl(
        FoldFun,
        {ActivePartitions2, ExpectedReduceValue2},
        lists:reverse(lists:seq(0, 63, 2))),

    etap:diag("Phase 2 cleanup finished"),

    etap:is(
        ActivePartitions3,
        [],
        "Right list of active partitions after second cleanup phase"),

    couch_set_view_test_util:delete_set_dbs(test_set_name(), num_set_partitions()),
    couch_set_view_test_util:stop_server(),
    ok.


get_group_snapshot() ->
    GroupPid = couch_set_view:get_group_pid(
        mapreduce_view, test_set_name(), ddoc_id(), prod),
    {ok, Group, 0} = gen_server:call(
        GroupPid, #set_view_group_req{stale = false, debug = true}, infinity),
    Group.


wait_for_cleanup() ->
    {ok, Pid} = gen_server:call(erlang:get(group_pid), cleaner_pid, infinity),
    CheckCleanupList = case Pid of
    nil ->
        true;
    _ ->
        Ref = erlang:monitor(process, Pid),
        receive
        {'DOWN', Ref, process, Pid, noproc} ->
            true;
        {'DOWN', Ref, process, Pid, {clean_group, _, _, _}} ->
            false
        after ?MAX_WAIT_TIME ->
            etap:bail("Timeout waiting for index cleanup")
        end
    end,
    case CheckCleanupList of
    true ->
        GroupInfo = get_group_info(),
        case couch_util:get_value(cleanup_partitions, GroupInfo) of
        [] ->
            ok;
        _ ->
            etap:bail("Cleanup was not triggered")
        end;
    false ->
        ok
    end.


get_group_info() ->
    {ok, Info} = couch_set_view:get_group_info(
        mapreduce_view, test_set_name(), ddoc_id(), prod),
    Info.


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
            ]}},
            {<<"view_2">>, {[
                {<<"map">>, <<"function(doc, meta) { emit(meta.id, doc.value * 3); }">>},
                {<<"reduce">>, <<"_sum">>}
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


add_documents(StartId, Count) ->
    etap:diag("Adding " ++ integer_to_list(Count) ++ " new documents"),
    DocList0 = lists:map(
        fun(I) ->
            {I rem num_set_partitions(), {[
            {<<"meta">>, {[{<<"id">>, doc_id(I)}]}},
            {<<"json">>, {[
                {<<"value">>, I}
            ]}}
            ]}}
        end,
        lists:seq(StartId, StartId + Count - 1)),
    DocList = [Doc || {_, Doc} <- lists:keysort(1, DocList0)],
    ok = couch_set_view_test_util:populate_set_sequentially(
        test_set_name(),
        lists:seq(0, num_set_partitions() - 1),
        DocList).


doc_id(I) ->
    iolist_to_binary(io_lib:format("doc_~8..0b", [I])).


get_view(_ViewName, []) ->
    undefined;
get_view(ViewName, [SetView | Rest]) ->
    RedFuns = (SetView#set_view.indexer)#mapreduce_view.reduce_funs,
    case couch_util:get_value(ViewName, RedFuns) of
    undefined ->
        get_view(ViewName, Rest);
    _ ->
        SetView
    end.


verify_btrees([], _ExpectedView2Reduction) ->
    Group = get_group_snapshot(),
    #set_view_group{
        id_btree = IdBtree,
        views = Views,
        index_header = #set_view_index_header{
            seqs = HeaderUpdateSeqs,
            abitmask = Abitmask,
            pbitmask = Pbitmask,
            cbitmask = Cbitmask
        }
    } = Group,
    etap:is(2, length(Views), "2 view btrees in the group"),
    View1 = get_view(<<"view_1">>, Views),
    View2 = get_view(<<"view_2">>, Views),
    etap:isnt(View1, View2, "Views 1 and 2 have different btrees"),
    #set_view{
        indexer = #mapreduce_view{
            btree = View1Btree
        }
    } = View1,
    #set_view{
        indexer = #mapreduce_view{
            btree = View2Btree
        }
    } = View2,

    etap:is(
        couch_set_view_test_util:full_reduce_id_btree(Group, IdBtree),
        {ok, {0, 0}},
        "Id Btree has the right reduce value"),
    etap:is(
        couch_set_view_test_util:full_reduce_view_btree(Group, View1Btree),
        {ok, {0, [0], 0}},
        "View1 Btree has the right reduce value"),
    etap:is(
        couch_set_view_test_util:full_reduce_view_btree(Group, View2Btree),
        {ok, {0, [0], 0}},
        "View2 Btree has the right reduce value"),

    etap:is(HeaderUpdateSeqs, [], "Header has right update seqs list"),
    etap:is(Abitmask, 0, "Header has right active bitmask"),
    etap:is(Pbitmask, 0, "Header has right passive bitmask"),
    etap:is(Cbitmask, 0, "Header has right cleanup bitmask"),

    etap:diag("Verifying the Id Btree"),
    {ok, _, IdBtreeFoldResult} = couch_set_view_test_util:fold_id_btree(
        Group,
        IdBtree,
        fun(_Kv, _, I) ->
            {ok, I + 1}
        end,
        0, []),
    etap:is(IdBtreeFoldResult, 0, "Id Btree is empty"),

    etap:diag("Verifying the View1 Btree"),
    {ok, _, View1BtreeFoldResult} = couch_set_view_test_util:fold_view_btree(
        Group,
        View1Btree,
        fun(_Kv, _, I) ->
            {ok, I + 1}
        end,
        0, []),
    etap:is(View1BtreeFoldResult, 0, "View1 Btree is empty"),

    etap:diag("Verifying the View2 Btree"),
    {ok, _, View2BtreeFoldResult} = couch_set_view_test_util:fold_view_btree(
        Group,
        View2Btree,
        fun(_Kv, _, I) ->
            {ok, I + 1}
        end,
        0, []),
    etap:is(View2BtreeFoldResult, 0, "View2 Btree is empty");

verify_btrees(ActiveParts, ExpectedView2Reduction) ->
    Group = get_group_snapshot(),
    #set_view_group{
        id_btree = IdBtree,
        views = Views,
        index_header = #set_view_index_header{
            seqs = HeaderUpdateSeqs,
            abitmask = Abitmask,
            pbitmask = Pbitmask,
            cbitmask = Cbitmask
        }
    } = Group,
    etap:is(2, length(Views), "2 view btrees in the group"),
    View1 = get_view(<<"view_1">>, Views),
    View2 = get_view(<<"view_2">>, Views),
    etap:isnt(View1, View2, "Views 1 and 2 have different btrees"),
    #set_view{
        indexer = #mapreduce_view{
            btree = View1Btree
        }
    } = View1,
    #set_view{
        indexer = #mapreduce_view{
            btree = View2Btree
        }
    } = View2,
    ExpectedBitmask = couch_set_view_util:build_bitmask(ActiveParts),
    DbSeqs = couch_set_view_test_util:get_db_seqs(test_set_name(), ActiveParts),
    ExpectedKVCount = (num_docs() div num_set_partitions()) * length(ActiveParts),

    etap:is(
        couch_set_view_test_util:full_reduce_id_btree(Group, IdBtree),
        {ok, {ExpectedKVCount, ExpectedBitmask}},
        "Id Btree has the right reduce value"),
    etap:is(
        couch_set_view_test_util:full_reduce_view_btree(Group, View1Btree),
        {ok, {ExpectedKVCount, [ExpectedKVCount], ExpectedBitmask}},
        "View1 Btree has the right reduce value"),
    etap:is(
        couch_set_view_test_util:full_reduce_view_btree(Group, View2Btree),
        {ok, {ExpectedKVCount, [ExpectedView2Reduction], ExpectedBitmask}},
        "View2 Btree has the right reduce value"),

    etap:is(HeaderUpdateSeqs, DbSeqs, "Header has right update seqs list"),
    etap:is(Abitmask, ExpectedBitmask, "Header has right active bitmask"),
    etap:is(Pbitmask, 0, "Header has right passive bitmask"),
    etap:is(Cbitmask, 0, "Header has right cleanup bitmask"),

    etap:diag("Verifying the Id Btree"),
    MaxPerPart = num_docs() div num_set_partitions(),
    {ok, _, {_, _, _, IdBtreeFoldResult}} = couch_set_view_test_util:fold_id_btree(
        Group,
        IdBtree,
        fun(Kv, _, {Parts, I0, C0, It}) ->
            case C0 >= MaxPerPart of
            true ->
                [_ | RestParts] = Parts,
                [P | _] = RestParts,
                I = P,
                C = 1;
            false ->
                RestParts = Parts,
                [P | _] = RestParts,
                I = I0,
                C = C0 + 1
            end,
            true = (P < num_set_partitions()),
            DocId = doc_id(I),
            Value = [
                {View2#set_view.id_num, doc_id(I)},
                {View1#set_view.id_num, doc_id(I)}
            ],
            ExpectedKv = {<<P:16, DocId/binary>>, {P, Value}},
            case ExpectedKv =:= Kv of
            true ->
                ok;
            false ->
                etap:bail("Id Btree has an unexpected KV at iteration " ++ integer_to_list(It))
            end,
            {ok, {RestParts, I + num_set_partitions(), C, It + 1}}
        end,
        {ActiveParts, hd(ActiveParts), 0, 0}, []),
    etap:is(IdBtreeFoldResult, ExpectedKVCount,
        "Id Btree has " ++ integer_to_list(ExpectedKVCount) ++ " entries"),

    etap:diag("Verifying the View1 Btree"),
    {ok, _, {_, View1BtreeFoldResult}} = couch_set_view_test_util:fold_view_btree(
        Group,
        View1Btree,
        fun(Kv, _, {NextVal, I}) ->
            PartId = NextVal rem num_set_partitions(),
            DocId = doc_id(NextVal),
            ExpectedKv = {{DocId, DocId}, {PartId, NextVal}},
            case ExpectedKv =:= Kv of
            true ->
                ok;
            false ->
                etap:bail("View1 Btree has an unexpected KV at iteration " ++ integer_to_list(I))
            end,
            {ok, {next_val(NextVal, ActiveParts), I + 1}}
        end,
        {hd(ActiveParts), 0}, []),
    etap:is(View1BtreeFoldResult, ExpectedKVCount,
        "View1 Btree has " ++ integer_to_list(ExpectedKVCount) ++ " entries"),

    etap:diag("Verifying the View2 Btree"),
    {ok, _, {_, View2BtreeFoldResult}} = couch_set_view_test_util:fold_view_btree(
        Group,
        View2Btree,
        fun(Kv, _, {NextVal, I}) ->
            PartId = NextVal rem num_set_partitions(),
            DocId = doc_id(NextVal),
            ExpectedKv = {{DocId, DocId}, {PartId, NextVal * 3}},
            case ExpectedKv =:= Kv of
            true ->
                ok;
            false ->
                etap:bail("View2 Btree has an unexpected KV at iteration " ++ integer_to_list(I))
            end,
            {ok, {next_val(NextVal, ActiveParts), I + 1}}
        end,
        {hd(ActiveParts), 0}, []),
    etap:is(View2BtreeFoldResult, ExpectedKVCount,
        "View2 Btree has " ++ integer_to_list(ExpectedKVCount) ++ " entries"),
    ok.


next_val(I, ActiveParts) ->
    case ordsets:is_element((I + 1) rem num_set_partitions(), ActiveParts) of
    true ->
        I + 1;
    false ->
        next_val(I + 1, ActiveParts)
    end.

