set nomore
set hidden

let s:original_directory = getcwd()
let s:original_path = $PATH
let s:plugin_directory = fnamemodify(expand('<sfile>'), ':p:h:h')
let s:test_directory = tempname()
let s:project = s:test_directory . '/project'
let s:bin_directory = s:test_directory . '/bin'
call mkdir(s:project, 'p')
call mkdir(s:bin_directory, 'p')

function! s:wait_for_result() abort
  let deadline = reltime()
  while bufname('%') !=# '[pgquery local]' && reltimefloat(reltime(deadline)) < 2
    sleep 10m
  endwhile
  return bufname('%') ==# '[pgquery local]'
endfunction

function! s:source(lines, line_number) abort
  call win_gotoid(bufwinid(s:source_buffer))
  silent %delete _
  call setline(1, a:lines)
  call cursor(a:line_number, 1)
endfunction

function! s:assert_block(lines, line_number, expected) abort
  call s:source(a:lines, a:line_number)
  call assert_equal(1, pgquery#execute())
  call assert_true(s:wait_for_result(), 'cursor-block query did not finish')
  call assert_equal(a:expected, readfile($PGQUERY_TEST_SQL))
  call assert_equal(a:lines, getbufline(s:source_buffer, 1, '$'))
endfunction

function! s:assert_no_block(lines, line_number) abort
  call s:source(a:lines, a:line_number)
  let before = readfile($PGQUERY_TEST_URLS)
  call assert_equal(0, pgquery#execute())
  call assert_equal(s:source_buffer, bufnr('%'))
  call assert_equal(before, readfile($PGQUERY_TEST_URLS))
endfunction

try
  let g:pgquery_store_path = s:test_directory . '/pgquery.json'
  call writefile([
        \ '#!/bin/sh',
        \ 'printf "%s\n" "$1" >> "$PGQUERY_TEST_URLS"',
        \ 'while [ "$#" -gt 0 ]; do',
        \ '  if [ "$1" = "-f" ]; then',
        \ '    shift',
        \ '    cp "$1" "$PGQUERY_TEST_SQL"',
        \ '    cat "$1"',
        \ '    exit',
        \ '  fi',
        \ '  shift',
        \ 'done',
        \ 'exit 2'], s:bin_directory . '/psql')
  call setfperm(s:bin_directory . '/psql', 'rwx------')
  let $PATH = s:bin_directory . ':' . $PATH
  let $PGQUERY_TEST_URLS = s:test_directory . '/urls'
  let $PGQUERY_TEST_SQL = s:test_directory . '/executed.sql'

  execute 'set runtimepath^=' . fnameescape(s:plugin_directory)
  runtime plugin/pgquery.vim
  execute 'cd ' . fnameescape(s:project)
  silent execute 'file ' . fnameescape(s:project . '/queries.sql')
  call assert_equal(1,
        \ pgquery#new('local', 'postgresql://user@localhost/database'))

  silent execute 'file ' . fnameescape(s:project . '/queries.sql')
  call assert_equal(1, pgquery#new('other', 'postgresql://user@localhost/other'))
  call pgquery#connect()
  call popup_close(popup_list()[0], 1)
  let s:source_buffer = bufnr('%')
  let s:initial_window_count = winnr('$')
  call setline(1, [
        \ "select 'outside';",
        \ '',
        \ "select 'selected one';",
        \ '',
        \ "select 'selected two';",
        \ "select 'selected three';",
        \ '',
        \ "select 'outside too';"])

  3,6DBExecute
  call assert_notmatch('pgquery: started query', execute('messages'))
  call assert_true(s:wait_for_result(), 'range query did not finish')
  call assert_equal('[pgquery local]', bufname('%'))
  call assert_false(exists('b:pgquery_job_id'))
  call assert_notmatch('\[pgquery local\]', execute('messages'))
  call assert_equal(s:initial_window_count + 1, winnr('$'))
  call assert_true(bufwinid(s:source_buffer) > 0)
  call assert_equal([
        \ "select 'outside';",
        \ '',
        \ "select 'selected one';",
        \ '',
        \ "select 'selected two';",
        \ "select 'selected three';",
        \ '',
        \ "select 'outside too';"], getbufline(s:source_buffer, 1, '$'))
  call assert_equal([
        \ "select 'selected one';",
        \ "select 'selected two';",
        \ "select 'selected three';"], getline(1, '$'))

  let s:result_buffer = bufnr('%')
  let s:window_count = winnr('$')
  wincmd p
  call assert_equal(s:source_buffer, bufnr('%'))
  call assert_equal('local', b:pgquery_connection)
  call cursor(5, 1)
  DBExecute
  call assert_true(s:wait_for_result(), 'cursor-block query did not finish')
  call assert_equal('[pgquery local]', bufname('%'))
  call assert_equal(s:result_buffer, bufnr('%'))
  call assert_equal(s:window_count, winnr('$'))
  call assert_equal(1, len(win_findbuf(s:result_buffer)))
  call assert_true(bufwinid(s:source_buffer) > 0)
  call assert_equal([
        \ "select 'selected two';",
        \ "select 'selected three';"], getline(1, '$'))
  call assert_equal(repeat(['postgresql://user@localhost/database'], 2),
        \ readfile($PGQUERY_TEST_URLS))

  " Blank lines remain the default; standalone comments are part of the SQL.
  let s:blank_sql = ['SELECT 1;', '-- comment', 'SELECT 2;', " \t", 'SELECT 3;']
  call s:assert_block(s:blank_sql, 2, s:blank_sql[0:2])
  call s:assert_no_block(s:blank_sql, 4)

  let g:pgquery_comment_as_block_delimiter = 1
  let s:comment_sql = ['SELECT 0;', '-- first block', 'SELECT 1;', '',
        \ 'SELECT 2; -- inline comment', " \t-- next block", 'SELECT 3;', '']
  " A blank cursor line belongs to the surrounding comment-delimited block.
  call s:assert_block(s:comment_sql, 4, s:comment_sql[2:4])
  call s:assert_block(s:comment_sql, 1, ['SELECT 0;'])
  call s:assert_block(s:comment_sql, 7, ['SELECT 3;', ''])
  call s:assert_no_block(s:comment_sql, 2)
  call s:assert_no_block(s:comment_sql, 6)
  " Any comment text works, including without a space after --.
  call s:assert_block(['SELECT 1;', '--breakpoint', 'SELECT 2;'], 1, ['SELECT 1;'])
  call s:assert_block(['SELECT 1;', '--breakpoint', 'SELECT 2;'], 3, ['SELECT 2;'])
  call s:assert_no_block(['--', '-- consecutive breakpoints'], 2)
  call s:assert_no_block(['-- first', '', " \t", '-- next'], 2)
  call s:assert_no_block(['', " \t"], 1)
  call s:assert_block(['', 'SELECT 1;', '', 'SELECT 2;', ''], 3,
        \ ['', 'SELECT 1;', '', 'SELECT 2;', ''])

  " Explicit ranges include both comments and blank lines in either mode.
  call s:source(s:comment_sql, 4)
  2,7DBExecute
  call assert_true(s:wait_for_result(), 'comment-mode range query did not finish')
  call assert_equal(s:comment_sql[1:6], readfile($PGQUERY_TEST_SQL))

  " Changing the setting takes effect on the next execution.
  let g:pgquery_comment_as_block_delimiter = 0
  call s:assert_block(s:blank_sql, 2, s:blank_sql[0:2])
  unlet g:pgquery_comment_as_block_delimiter
finally
  let $PATH = s:original_path
  execute 'cd ' . fnameescape(s:original_directory)
  call delete(s:test_directory, 'rf')
endtry

if !empty(v:errors)
  for s:error in v:errors
    echomsg s:error
  endfor
  cquit
endif
quitall!
