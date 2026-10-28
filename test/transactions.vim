set nomore hidden
let s:root = fnamemodify(expand('<sfile>'), ':p:h:h')
let s:directory = tempname()
let s:old_path = $PATH
call mkdir(s:directory . '/bin', 'p')
let g:pgquery_store_path = s:directory . '/store.json'
let $PGQUERY_TEST_LOG = s:directory . '/log'
call writefile(readfile(s:root . '/test/fake_psql.py'), s:directory . '/bin/psql')
call setfperm(s:directory . '/bin/psql', 'rwx------')
let $PATH = s:directory . '/bin:' . $PATH
execute 'set rtp^=' . fnameescape(s:root)
runtime plugin/pgquery.vim

function! s:source() abort
  call win_gotoid(bufwinid(s:source))
endfunction

function! s:submit(sql) abort
  call s:source()
  silent %delete _
  call setline(1, a:sql)
  return pgquery#execute(1, 1, len(a:sql))
endfunction

function! s:wait(name) abort
  let start = reltime()
  while bufname('%') !=# '[pgquery ' . a:name . ']' && reltimefloat(reltime(start)) < 3
    sleep 10m
  endwhile
  call assert_equal('[pgquery ' . a:name . ']', bufname('%'))
  let s:result = bufnr('%')
endfunction

function! s:run(sql, tx) abort
  call assert_equal(1, s:submit(a:sql))
  call s:wait('local')
  call assert_equal(a:sql, getline(1, len(a:sql)))
  call assert_notmatch('__pgquery_', join(getline(1, '$'), "\n"))
  call s:source()
  call assert_equal(' [DB: local' . (a:tx ? '; TX' : '') . ']', pgquery#statusline())
endfunction

function! s:records() abort
  return map(readfile($PGQUERY_TEST_LOG), 'json_decode(v:val)')
endfunction

try
  execute 'file ' . fnameescape(s:directory . '/one.sql')
  let s:source = bufnr('%')
  call assert_equal(1, pgquery#new('other', 'postgresql://localhost/other'))
  call assert_equal(1, pgquery#new('local', 'postgresql://localhost/local'))
  call assert_equal(1, s:submit(['  bEgIn;  ', 'SLOW']))
  call assert_equal(' [DB: local; TX]', pgquery#statusline())
  call assert_equal(0, pgquery#execute(1, 1, 1))
  call s:wait('local')
  call s:source()
  let s:stored = readfile(g:pgquery_store_path)
  call assert_equal(0, pgquery#new('blocked', 'postgresql://localhost/blocked'))
  call assert_equal(0, pgquery#edit('local', 'renamed', 'postgresql://localhost/changed'))
  call assert_equal(0, pgquery#delete('local'))
  call pgquery#connect()
  call popup_close(popup_list()[0], 2)
  call assert_equal('local', b:pgquery_connection)
  call assert_equal(s:stored, readfile(g:pgquery_store_path))
  call s:run(['select 1;'], 1)
  call assert_equal(['select 1;'], getbufline(s:result, 1, '$'))
  call assert_equal(1, len(filter(s:records(), 'has_key(v:val, "args")')))

  " Comments (including nesting), dollar strings, escaped/doubled quotes.
  call s:run(['/* outer', '/* nested */', 'COMMIT;', '*/', '-- ROLLBACK;',
        \ "select 'text", 'ROLLBACK;', "it''s quoted';", 'select $tag$',
        \ 'COMMIT;', '$tag$;', 'select "identifier', 'ROLLBACK;', '";'], 1)
  call s:run(["select E'escaped \\'", 'COMMIT;', "still quoted';"], 1)
  call s:run(['select ERROR;'], 1)
  call assert_equal('ERROR: simulated SQL failure', getbufline(s:result, 1, '$')[-1])

  " A second buffer has an independent process while the first transaction lives.
  call assert_equal(1, s:submit(['SLOW']))
  belowright new
  execute 'file ' . fnameescape(s:directory . '/two.sql')
  let s:second = bufnr('%')
  call pgquery#connect()
  call popup_close(popup_list()[0], 2)
  call setline(1, 'BEGIN;')
  call assert_equal(1, pgquery#execute())
  call s:wait('other')
  sleep 400m
  call s:source()
  call assert_equal(' [DB: local; TX]', pgquery#statusline())
  call assert_equal(2, len(filter(s:records(), 'has_key(v:val, "args")')))
  call s:run(['rOlLbAcK;', 'select 2;'], 0)
  call s:run(['BEGIN;', 'ROLLBACK;', "select '", 'BEGIN;', "';"], 0)
  call s:run(['BEGIN;', 'COMMIT;', 'BEGIN;'], 1)
  call s:run(['COMMIT;', 'BEGIN;', 'ROLLBACK;', 'select 3;'], 0)
  call s:run(['BEGIN;', 'ROLLBACK;'], 0)
  call s:run(['BEGIN;'], 1)

  " Returning to a hidden transaction preserves it; deleting it discards it.
  call win_gotoid(bufwinid(s:second))
  call assert_equal(' [DB: other; TX]', pgquery#statusline())
  execute 'bdelete! ' . s:second
  call s:source()
  call assert_equal(1, pgquery#edit('other', 'postgresql://localhost/edited'))
  call assert_equal(1, s:submit(['DIE']))
  sleep 150m
  call assert_match('terminated unexpectedly', execute('messages'))
  call s:source()
  call assert_equal(' [DB: local]', pgquery#statusline())
  call s:run(['BEGIN;'], 1)
  call assert_equal(1, s:submit(['SLOW']))
  " Ensure the fake has received this file before deleting the buffer.
  sleep 50m
  execute 'bwipeout! ' . s:source
  sleep 100m
  " VimLeavePre must also clean a busy job and its pending file.
  let s:child = s:directory . '/exit.vim'
  call writefile([
        \ 'set nomore',
        \ 'set rtp^=' . fnameescape(s:root),
        \ 'let g:pgquery_store_path = ' . string(g:pgquery_store_path),
        \ 'runtime plugin/pgquery.vim',
        \ 'call pgquery#new("exit", "postgresql://localhost/exit")',
        \ 'call setline(1, ["BEGIN;", "SLOW"])',
        \ 'call pgquery#execute(1, 1, 2)',
        \ 'sleep 100m',
        \ 'quitall!'], s:child)
  call system('vim -Nu NONE -n -es -S ' . shellescape(s:child))
  call assert_equal(0, v:shell_error)
  sleep 100m
  for s:record in s:records()
    if has_key(s:record, 'file')
      call assert_equal('0o600', s:record.mode)
      call assert_false(filereadable(s:record.file), s:record.file . ' leaked')
    else
      call system('kill -0 ' . s:record.pid . ' 2>/dev/null')
      call assert_notequal(0, v:shell_error, 'transaction process leaked')
      call assert_true(index(s:record.args, '-X') >= 0)
      call assert_true(index(s:record.args, 'ON_ERROR_STOP=off') >= 0)
      call assert_true(index(s:record.args, 'ON_ERROR_ROLLBACK=off') >= 0)
      call assert_true(index(s:record.args, 'pager=off') >= 0)
    endif
  endfor
finally
  call pgquery#cleanup()
  let $PATH = s:old_path
  call delete(s:directory, 'rf')
endtry
if !empty(v:errors)
  for s:error in v:errors
    echomsg s:error
  endfor
  cquit
endif
quitall!
