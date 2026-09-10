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
  while bufname('%') !~# '^\[pgquery ' && reltimefloat(reltime(deadline)) < 2
    sleep 10m
  endwhile
  return bufname('%') =~# '^\[pgquery '
endfunction

try
  let g:pgquery_store_path = s:test_directory . '/pgquery.json'
  call writefile([
        \ '#!/bin/sh',
        \ 'while [ "$#" -gt 0 ]; do',
        \ '  if [ "$1" = "-f" ]; then',
        \ '    shift',
        \ '    cat "$1"',
        \ '    exit',
        \ '  fi',
        \ '  shift',
        \ 'done',
        \ 'exit 2'], s:bin_directory . '/psql')
  call setfperm(s:bin_directory . '/psql', 'rwx------')
  let $PATH = s:bin_directory . ':' . $PATH

  execute 'set runtimepath^=' . fnameescape(s:plugin_directory)
  runtime plugin/pgquery.vim
  execute 'cd ' . fnameescape(s:project)
  call assert_equal(1,
        \ pgquery#new('local', 'postgresql://user@localhost/database'))

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
  call assert_true(s:wait_for_result(), 'range query did not finish')
  call assert_equal([
        \ "select 'selected one';",
        \ "select 'selected two';",
        \ "select 'selected three';"], getline(1, '$'))

  bwipeout!
  call cursor(5, 1)
  DBExecute
  call assert_true(s:wait_for_result(), 'cursor-block query did not finish')
  call assert_equal([
        \ "select 'selected two';",
        \ "select 'selected three';"], getline(1, '$'))
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
