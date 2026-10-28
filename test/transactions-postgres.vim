" Run against an empty disposable database via PGQUERY_TEST_DATABASE.
set nomore hidden
let s:root = fnamemodify(expand('<sfile>'), ':p:h:h')
let s:directory = tempname()
call mkdir(s:directory, 'p')
let g:pgquery_store_path = s:directory . '/store.json'
execute 'set rtp^=' . fnameescape(s:root)
runtime plugin/pgquery.vim

function! s:query(sql, tx) abort
  call win_gotoid(bufwinid(s:source))
  silent %delete _
  call setline(1, a:sql)
  call assert_equal(1, pgquery#execute(1, 1, len(a:sql)))
  let start = reltime()
  while bufname('%') !=# '[pgquery integration]' && reltimefloat(reltime(start)) < 5
    sleep 10m
  endwhile
  call assert_equal('[pgquery integration]', bufname('%'))
  let output = join(getline(1, '$'), "\n")
  call win_gotoid(bufwinid(s:source))
  call assert_equal(' [DB: integration' . (a:tx ? '; TX' : '') . ']', pgquery#statusline())
  return output
endfunction

function! s:external(sql) abort
  let result = system('psql -X -w -At ' . shellescape($PGQUERY_TEST_DATABASE) . ' -c ' . shellescape(a:sql))
  call assert_equal(0, v:shell_error, result)
  return trim(result)
endfunction

try
  call assert_false(empty($PGQUERY_TEST_DATABASE), 'PGQUERY_TEST_DATABASE must name a disposable database')
  execute 'file ' . fnameescape(s:directory . '/integration.sql')
  let s:source = bufnr('%')
  call pgquery#new('integration', $PGQUERY_TEST_DATABASE)
  call s:external('CREATE TABLE pgquery_tx_test (id integer)')
  call s:query(['BEGIN;'], 1)
  call s:query(['INSERT INTO pgquery_tx_test VALUES (1);'], 1)
  call s:query(['/*', 'COMMIT;', '*/', 'SELECT $tag$', 'ROLLBACK;', '$tag$;'], 1)
  call s:query(["SELECT E'escaped \\'", 'COMMIT;', "still quoted';"], 1)
  call assert_equal('0', s:external('SELECT count(*) FROM pgquery_tx_test'))
  call s:query(['COMMIT;', 'INSERT INTO pgquery_tx_test VALUES (2);'], 0)
  call assert_equal('2', s:external('SELECT count(*) FROM pgquery_tx_test'))
  call s:query(['BEGIN;', 'INSERT INTO pgquery_tx_test VALUES (3);'], 1)
  call s:query(['ROLLBACK;'], 0)
  call assert_equal('2', s:external('SELECT count(*) FROM pgquery_tx_test'))
  call s:query(['BEGIN;'], 1)
  call assert_match('division by zero', s:query(['SELECT 1/0;'], 1))
  call assert_match('current transaction is aborted', s:query(['INSERT INTO pgquery_tx_test VALUES (4);'], 1))
  call s:query(['ROLLBACK;'], 0)
  call assert_equal('2', s:external('SELECT count(*) FROM pgquery_tx_test'))
  call s:query(['BEGIN;', 'COMMIT;', 'BEGIN;'], 1)
  call s:query(['INSERT INTO pgquery_tx_test VALUES (5);'], 1)
  call pgquery#cleanup()
  call assert_equal(' [DB: integration]', pgquery#statusline())
  call assert_equal('2', s:external('SELECT count(*) FROM pgquery_tx_test'))
finally
  call pgquery#cleanup()
  call delete(s:directory, 'rf')
endtry
if !empty(v:errors)
  for s:error in v:errors
    echomsg s:error
  endfor
  cquit
endif
quitall!
