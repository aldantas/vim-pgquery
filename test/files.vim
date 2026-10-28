set nomore
set hidden

let s:plugin_directory = fnamemodify(expand('<sfile>'), ':p:h:h')
let s:test_directory = tempname()
call mkdir(s:test_directory, 'p')

function! s:choose(index) abort
  call pgquery#connect()
  call popup_close(popup_list()[0], a:index)
endfunction

try
  let g:pgquery_store_path = s:test_directory . '/pgquery.json'
  execute 'set runtimepath^=' . fnameescape(s:plugin_directory)
  runtime plugin/pgquery.vim

  " Old project defaults must never override a file's explicit choice.
  let s:legacy = {'version': 1,
        \ 'connections': {'alpha': 'postgresql://localhost/alpha',
        \                 'beta': 'postgresql://localhost/beta'},
        \ 'projects': {s:test_directory: 'alpha'}}
  call writefile([json_encode(s:legacy)], g:pgquery_store_path)
  execute 'edit ' . fnameescape(s:test_directory . '/one.sql')
  call assert_equal('', pgquery#statusline())
  call assert_equal(s:legacy, json_decode(join(readfile(g:pgquery_store_path))))
  call s:choose(2)
  call assert_equal('beta', b:pgquery_connection)
  let s:store = json_decode(join(readfile(g:pgquery_store_path)))
  call assert_equal(2, s:store.version)
  call assert_equal(s:legacy.connections, s:store.connections)
  call assert_false(has_key(s:store, 'projects'))
  call assert_equal({s:test_directory . '/one.sql': 'beta'}, s:store.files)
  call assert_equal('rw-------', getfperm(g:pgquery_store_path))

  " A neighboring file does not inherit the first file's selection.
  execute 'edit ' . fnameescape(s:test_directory . '/two.sql')
  call assert_equal('', pgquery#statusline())
  call s:choose(1)
  call assert_equal('alpha', b:pgquery_connection)
  execute 'buffer ' . bufnr(s:test_directory . '/one.sql')
  call assert_equal('beta', b:pgquery_connection)
  call assert_equal('postgresql://localhost/beta', b:db)

  " Discard all buffer state and restore solely from the persisted file path.
  bwipeout!
  execute 'edit ' . fnameescape(s:test_directory . '/one.sql')
  call assert_equal('beta', b:pgquery_connection)
  call s:choose(1)
  bwipeout!
  execute 'edit ' . fnameescape(s:test_directory . '/one.sql')
  call assert_equal('alpha', b:pgquery_connection)
  call s:choose(0)
  call assert_equal('alpha', b:pgquery_connection)

  " New files reached through a symlink use the same canonical path.
  call system('ln -s ' . shellescape(s:test_directory)
        \ . ' ' . shellescape(s:test_directory . '/alias'))
  call assert_equal(0, v:shell_error)
  execute 'edit ' . fnameescape(s:test_directory . '/alias/one.sql')
  call assert_equal('alpha', b:pgquery_connection)

  " File associations also work when the filename has a different extension.
  execute 'edit ' . fnameescape(s:test_directory . '/query.pgsql')
  call assert_equal('', pgquery#statusline())
  call s:choose(2)
  bwipeout!
  execute 'edit ' . fnameescape(s:test_directory . '/query.pgsql')
  call assert_equal('beta', b:pgquery_connection)
  execute 'edit ' . fnameescape(s:test_directory . '/one.sql')

  " Stale mappings and malformed stores fail closed without being overwritten.
  let s:store = json_decode(join(readfile(g:pgquery_store_path)))
  let s:store.files[s:test_directory . '/one.sql'] = 'missing'
  call writefile([json_encode(s:store)], g:pgquery_store_path)
  call assert_equal(0, pgquery#select_for_buffer())
  call assert_equal('', pgquery#statusline())
  call assert_match('missing connection', execute('messages'))
  call writefile(['{"version":2,"connections":{},"files":[]}'], g:pgquery_store_path)
  let s:invalid = readfile(g:pgquery_store_path)
  call assert_equal(0, pgquery#new('new', 'postgresql://localhost/new'))
  call assert_equal(s:invalid, readfile(g:pgquery_store_path))

  " An unnamed buffer has no persistent file mapping.
  call delete(g:pgquery_store_path)
  enew
  call assert_equal(1, pgquery#new('scratch', 'postgresql://localhost/scratch'))
  call assert_equal({}, json_decode(join(readfile(g:pgquery_store_path))).files)
  call assert_equal('scratch', b:pgquery_connection)
finally
  call delete(s:test_directory, 'rf')
endtry

if !empty(v:errors)
  for s:error in v:errors
    echomsg s:error
  endfor
  cquit
endif
quitall!
