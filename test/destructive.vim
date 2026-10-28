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

function! s:submit(sql) abort
  call win_gotoid(bufwinid(s:source))
  silent %delete _
  call setline(1, a:sql)
  return pgquery#execute(1, 1, len(a:sql))
endfunction

function! s:wait() abort
  let start = reltime()
  while bufname('%') !=# '[pgquery local]' && reltimefloat(reltime(start)) < 3
    sleep 10m
  endwhile
  call assert_equal('[pgquery local]', bufname('%'))
endfunction

function! s:run(sql) abort
  call assert_equal(1, s:submit(a:sql))
  call s:wait()
  call assert_equal(a:sql, getline(1, len(a:sql)))
  call win_gotoid(bufwinid(s:source))
endfunction

function! s:cancel(sql) abort
  let before = filereadable($PGQUERY_TEST_LOG) ? readfile($PGQUERY_TEST_LOG) : []
  " In silent Ex mode confirm() returns its default: Cancel.
  call assert_equal(0, s:submit(a:sql), string(a:sql))
  sleep 50m
  call assert_equal(before,
        \ filereadable($PGQUERY_TEST_LOG) ? readfile($PGQUERY_TEST_LOG) : [])
  call assert_equal(s:source, bufnr('%'))
endfunction

try
  execute 'file ' . fnameescape(s:directory . '/queries.sql')
  let s:source = bufnr('%')
  call pgquery#new('local', 'postgresql://localhost/local')
  call s:cancel(['delete from users;'])
  call s:cancel(['TrUnCaTe TABLE users;'])
  call s:cancel(['select 1;', 'DELETE FROM users WHERE id = 1;'])
  call s:cancel(['WITH gone AS (DELETE FROM users RETURNING *) SELECT * FROM gone;'])
  call s:cancel(['BEGIN;', 'DELETE FROM users;'])
  call s:cancel(['BEGIN;', 'TRUNCATE users;', 'COMMIT;'])

  call s:run(['-- DELETE FROM users;', '/* outer /* TRUNCATE */ DELETE */',
        \ "select 'DELETE', 'it''s TRUNCATE', \"DELETE\", $tag$TRUNCATE$tag$, $$DELETE$$;",
        \ 'select delete_count, truncate_log, x$DELETE, DELETE$tag$;',
        \ "select 'multiline", 'DELETE TRUNCATE', "';"])
  call s:run(["select E'escaped \\' DELETE TRUNCATE';"])

  " Only the selected range or cursor block is inspected.
  call setline(1, ['DELETE FROM users;', '', 'SELECT 1;'])
  call cursor(3, 1)
  call assert_equal(1, pgquery#execute())
  call s:wait()
  call win_gotoid(bufwinid(s:source))
  call assert_equal(1, pgquery#execute(1, 3, 3))
  call s:wait()
  call win_gotoid(bufwinid(s:source))

  let g:pgquery_confirm_destructive = 0
  call s:run(['DELETE FROM users;'])
  call s:run(['TRUNCATE users;'])
  unlet g:pgquery_confirm_destructive

  call s:run(['BEGIN;'])
  call s:run(['DELETE FROM users;', 'TRUNCATE users;'])
  call s:cancel(['COMMIT;', 'DELETE FROM users;'])
  call s:cancel(['ROLLBACK;', 'TRUNCATE users;'])
  call assert_equal(' [DB: local; TX]', pgquery#statusline())

  " Another buffer using the same connection has no live transaction.
  belowright new
  let s:other = bufnr('%')
  let b:pgquery_connection = 'local'
  call setline(1, 'DELETE FROM users;')
  call assert_equal(0, pgquery#execute())
  execute 'bwipeout! ' . s:other
  call win_gotoid(bufwinid(s:source))
  call s:run(['DELETE FROM users;', 'ROLLBACK;'])
  call s:cancel(['TRUNCATE users;'])
  call s:run(['BEGIN;'])
  call assert_equal(1, s:submit(['DIE']))
  call s:wait()
  call win_gotoid(bufwinid(s:source))
  call assert_equal(' [DB: local]', pgquery#statusline())
  call s:cancel(['DELETE FROM users;'])
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
