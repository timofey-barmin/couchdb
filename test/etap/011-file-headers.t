#!/usr/bin/env escript
%% -*- erlang -*-
%%! -pa ./src/couchdb -sasl errlog_type error -noshell -smp enable

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

filename() -> test_util:build_file("test/etap/temp.011").
sizeblock() -> 4096. % Need to keep this in sync with couch_file.erl

main(_) ->
    test_util:init_code_path(),
    rand:seed(exrop, {erlang:phash2([node()]),
                      erlang:monotonic_time(),
                      erlang:unique_integer()}),

    etap:plan(34),
    case (catch test()) of
        ok ->
            etap:end_tests();
        Other ->
            etap:diag(io_lib:format("Test died abnormally: ~p", [Other])),
            etap:bail()
    end,
    ok.

test() ->
    couch_file_write_guard:sup_start_link(),
    test_couchdb(),
    test_find_header(),
    ok.

test_couchdb() ->
    {ok, Fd} = couch_file:open(filename(), [create,overwrite]),

    etap:is({ok, 0}, couch_file:bytes(Fd),
        "File should be initialized to contain zero bytes."),

    etap:is({ok, 0}, couch_file:write_header(Fd, {<<"some_data">>, 32}),
        "Writing a header succeeds."),
    ok = couch_file:flush(Fd),
    {ok, Size1} = couch_file:bytes(Fd),
    etap:is_greater(Size1, 0,
        "Writing a header allocates space in the file."),

    etap:is({ok, {<<"some_data">>, 32}, 0}, couch_file:read_header(Fd),
        "Reading the header returns what we wrote."),

    etap:is({ok, 4096}, couch_file:write_header(Fd, [foo, <<"more">>]),
        "Writing a second header succeeds."),

    {ok, Size2} = couch_file:bytes(Fd),
    etap:is_greater(Size2, Size1,
        "Writing a second header allocates more space."),

    ok = couch_file:flush(Fd),
    etap:is({ok, [foo, <<"more">>], 4096}, couch_file:read_header(Fd),
        "Reading the second header does not return the first header."),

    % Delete the second header.
    ok = couch_file:truncate(Fd, Size1),

    etap:is({ok, {<<"some_data">>, 32}, 0}, couch_file:read_header(Fd),
        "Reading the header after a truncation returns a previous header."),

    couch_file:write_header(Fd, [foo, <<"more">>]),
    etap:is({ok, Size2}, couch_file:bytes(Fd),
        "Rewriting the same second header returns the same second size."),

    couch_file:write_header(Fd, erlang:make_tuple(5000, <<"CouchDB">>)),
    ok = couch_file:flush(Fd),
    etap:is(
        couch_file:read_header(Fd),
        {ok, erlang:make_tuple(5000, <<"CouchDB">>), 8192},
        "Headers larger than the block size can be saved (COUCHDB-1319)"
    ),

    ok = couch_file:close(Fd),

    % Now for the fun stuff. Try corrupting the second header and see
    % if we recover properly.

    % Destroy the 0x1 byte that marks a header
    check_header_recovery(fun(CouchFd, RawFd, Expect, HeaderPos) ->
        ok = couch_file:flush(CouchFd),
        etap:isnt(Expect, couch_file:read_header(CouchFd),
            "Should return a different header before corruption."),
        file:pwrite(RawFd, HeaderPos, <<0>>),
        etap:is(Expect, couch_file:read_header(CouchFd),
            "Corrupting the byte marker should read the previous header.")
    end),

    % Corrupt the size.
    check_header_recovery(fun(CouchFd, RawFd, Expect, HeaderPos) ->
        ok = couch_file:flush(CouchFd),
        etap:isnt(Expect, couch_file:read_header(CouchFd),
            "Should return a different header before corruption."),
        % +1 for 0x1 byte marker
        file:pwrite(RawFd, HeaderPos+1, <<10/integer>>),
        etap:is(Expect, couch_file:read_header(CouchFd),
            "Corrupting the size should read the previous header.")
    end),

    % Corrupt the MD5 signature
    check_header_recovery(fun(CouchFd, RawFd, Expect, HeaderPos) ->
        ok = couch_file:flush(CouchFd),
        etap:isnt(Expect, couch_file:read_header(CouchFd),
            "Should return a different header before corruption."),
        % +5 = +1 for 0x1 byte and +4 for term size.
        file:pwrite(RawFd, HeaderPos+5, <<"F01034F88D320B22">>),
        etap:is(Expect, couch_file:read_header(CouchFd),
            "Corrupting the MD5 signature should read the previous header.")
    end),

    % Corrupt the data
    check_header_recovery(fun(CouchFd, RawFd, Expect, HeaderPos) ->
        ok = couch_file:flush(CouchFd),
        etap:isnt(Expect, couch_file:read_header(CouchFd),
            "Should return a different header before corruption."),
        % +21 = +1 for 0x1 byte, +4 for term size and +16 for MD5 sig
        file:pwrite(RawFd, HeaderPos+21, <<"some data goes here!">>),
        etap:is(Expect, couch_file:read_header(CouchFd),
            "Corrupting the header data should read the previous header.")
    end).

test_find_header() ->
    {ok, Fd} = couch_file:open(filename(), [create, overwrite]),

    etap:is({ok, 0}, couch_file:bytes(Fd),
        "File should be initialized to contain zero bytes."),
    etap:is({ok, 0}, couch_file:write_header(Fd, {<<"some_data">>, 32}),
        "Writing a header succeeds."),
    ok = couch_file:flush(Fd),

    etap:is(couch_file:find_header_bin(Fd, 0),
        {ok, term_to_binary({<<"some_data">>, 32}), 0},
        "Found header at the beginning of the file."),

    etap:is(couch_file:find_header_bin(Fd, eof),
        {ok, term_to_binary({<<"some_data">>, 32}), 0},
        "Found header at the beginning of the file when searching from "
        "the end of the file."),

    etap:is({ok, 4096}, couch_file:write_header(Fd, [foo, <<"more">>]),
        "Writing a second header succeeds."),
    ok = couch_file:flush(Fd),

    etap:is(couch_file:find_header_bin(Fd, 0),
        {ok, term_to_binary({<<"some_data">>, 32}), 0},
        "Finding header at the beginning of the file still works."),

    etap:is(couch_file:find_header_bin(Fd, 4096),
        {ok, term_to_binary([foo, <<"more">>]), 4096},
        "Finding second header by supplying its exact position works."),

    etap:is(couch_file:find_header_bin(Fd, eof),
        {ok, term_to_binary([foo, <<"more">>]), 4096},
        "Finding second header by searching from the end of the file works."),

    etap:is(couch_file:find_header_bin(Fd, 4095),
        {ok, term_to_binary({<<"some_data">>, 32}), 0},
        "Finding first header by supplying a position just one byte before "
        "the second header."),

    etap:is(couch_file:find_header_bin(Fd, 3000),
        {ok, term_to_binary({<<"some_data">>, 32}), 0},
        "Finding first header by supplying a position between the first and "
        "the first and the second header."),

    etap:is(couch_file:find_header_bin(Fd, 5000),
        {ok, term_to_binary([foo, <<"more">>]), 4096},
        "Finding second header by supplying a position that is within the "
        "second header."),

    {ok, Size1} = couch_file:bytes(Fd),
    etap:is(couch_file:find_header_bin(Fd, Size1 + 1000),
        {ok, term_to_binary([foo, <<"more">>]), 4096},
        "Finding second header by supplying a position that is bigger than "
        "the file size."),

    etap:is({ok, 8192},
        couch_file:write_header(Fd, erlang:make_tuple(5000, <<"Data">>)),
        "Writing a third header that is > 4KB succeeds."),
    ok = couch_file:flush(Fd),
    {ok, Header1, 8192} = couch_file:find_header_bin(Fd, 8192),
    etap:ok(byte_size(Header1) > 4096, "Header is really > 4KB."),

    etap:is(couch_file:find_header_bin(Fd, 8000),
        {ok, term_to_binary([foo, <<"more">>]), 4096},
        "Finding second header by supplying a position that is between the "
        "second and the third header."),

    etap:is(couch_file:find_header_bin(Fd, eof),
        {ok, term_to_binary(erlang:make_tuple(5000, <<"Data">>)), 8192},
        "Finding third header by searching from the end of the file works.").


check_header_recovery(CheckFun) ->
    {ok, Fd} = couch_file:open(filename(), [create,overwrite]),
    {ok, RawFd} = file:open(filename(), [read, write, raw, binary]),

    {ok, _} = write_random_data(Fd),
    ExpectHeader = {some_atom, <<"a binary">>, 756},
    {ok, ValidHeaderPos} = couch_file:write_header(Fd, ExpectHeader),

    {ok, HeaderPos} = write_random_data(Fd),
    {ok, _} = couch_file:write_header(Fd, {2342, <<"corruption! greed!">>}),

    CheckFun(Fd, RawFd, {ok, ExpectHeader, ValidHeaderPos}, HeaderPos),

    ok = file:close(RawFd),
    ok = couch_file:close(Fd),
    ok.

write_random_data(Fd) ->
    write_random_data(Fd, 100 + rand:uniform(1000)).

write_random_data(Fd, 0) ->
    {ok, Bytes} = couch_file:bytes(Fd),
    {ok, (1 + Bytes div sizeblock()) * sizeblock()};
write_random_data(Fd, N) ->
    Choices = [foo, bar, <<"bizzingle">>, "bank", ["rough", stuff]],
    Term = lists:nth(rand:uniform(4) + 1, Choices),
    {ok, _, _} = couch_file:append_term(Fd, Term),
    write_random_data(Fd, N-1).

