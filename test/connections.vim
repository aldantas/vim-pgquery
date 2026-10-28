set nomore
set hidden

let s:original_directory = getcwd()
let s:plugin_directory = fnamemodify(expand('<sfile>'), ':p:h:h')
let s:test_directory = tempname()
let s:project = s:test_directory . '/project'
call mkdir(s:project, 'p')

try
  let g:pgquery_store_path = s:test_directory . '/pgquery.json'
  execute 'set runtimepath^=' . fnameescape(s:plugin_directory)
  runtime plugin/pgquery.vim
  call assert_equal(2, exists(':DBShowURL'))
  call assert_equal(2, exists(':DBEdit'))
  call assert_equal(2, exists(':DBDelete'))
  call assert_equal(0, exists(':DBSetProject'))
  execute 'cd ' . fnameescape(s:project)

  execute 'edit ' . fnameescape(s:project . '/first.sql')
  let s:first_buffer = bufnr('%')
  call assert_equal('', pgquery#statusline())
  call assert_equal(1, pgquery#new('local', 'postgresql://user@localhost/one'))
  call assert_equal(' [DB: local]', pgquery#statusline())
  call assert_equal('postgresql://user@localhost/one',
        \ trim(execute('DBShowURL')))
  if exists('*eval_statusline')
    set statusline=%f%{pgquery#statusline()}
    call assert_match(' \[DB: local\]',
          \ eval_statusline(&statusline, {'winid': win_getid()}))
  endif
  call assert_equal(['local'], pgquery#complete_connections('', '', 0))
  silent DBEdit missing
  silent DBDelete missing
  let s:store_before_invalid_edit = readfile(g:pgquery_store_path)
  call assert_equal(0, pgquery#edit('local', 'not-a-postgresql-url'))
  call assert_equal(s:store_before_invalid_edit, readfile(g:pgquery_store_path))

  execute 'edit ' . fnameescape(s:project . '/mapped.sql')
  let s:mapped_buffer = bufnr('%')
  call assert_equal('', pgquery#statusline())
  call pgquery#connect()
  call popup_close(popup_list()[0], 1)
  call assert_equal('local', b:pgquery_connection)
  call assert_equal(' [DB: local]', pgquery#statusline())

  execute 'split ' . fnameescape(s:project . '/overridden.sql')
  let s:overridden_buffer = bufnr('%')
  call pgquery#connect()
  call popup_close(popup_list()[0], 1)
  let b:db = 'postgresql://other-plugin@localhost/override'
  call assert_equal('postgresql://user@localhost/one',
        \ trim(execute('DBShowURL')))

  call assert_equal(1,
        \ pgquery#edit('local', 'postgresql://user@localhost/middle'))
  call assert_equal('postgresql://user@localhost/middle',
        \ getbufvar(s:mapped_buffer, 'db'))
  call assert_equal('postgresql://other-plugin@localhost/override', b:db)
  call assert_equal(' [DB: local]', pgquery#statusline())

  call assert_equal(1, pgquery#edit(
        \ 'local', 'renamed', 'postgresql://user@localhost/two'))
  let s:store = json_decode(join(readfile(g:pgquery_store_path), "\n"))
  call assert_false(has_key(s:store.connections, 'local'))
  call assert_equal('postgresql://user@localhost/two',
        \ s:store.connections.renamed)
  call assert_equal('renamed', s:store.files[s:project . '/mapped.sql'])
  call assert_equal('renamed',
        \ getbufvar(s:first_buffer, 'pgquery_connection'))
  call assert_equal('renamed',
        \ getbufvar(s:mapped_buffer, 'pgquery_connection'))
  call assert_equal('postgresql://user@localhost/two',
        \ getbufvar(s:mapped_buffer, 'db'))
  call assert_equal('renamed',
        \ getbufvar(s:overridden_buffer, 'pgquery_connection'))
  call assert_equal('postgresql://other-plugin@localhost/override', b:db)
  call assert_equal(' [DB: renamed]', pgquery#statusline())

  call assert_equal(1, pgquery#delete('renamed'))
  let s:store = json_decode(join(readfile(g:pgquery_store_path), "\n"))
  call assert_equal({}, s:store.connections)
  call assert_equal({}, s:store.files)
  call assert_equal(v:null,
        \ getbufvar(s:first_buffer, 'pgquery_connection', v:null))
  call assert_equal(v:null,
        \ getbufvar(s:mapped_buffer, 'pgquery_connection', v:null))
  call assert_equal(v:null,
        \ getbufvar(s:overridden_buffer, 'pgquery_connection', v:null))
  call assert_equal('postgresql://other-plugin@localhost/override', b:db)
  call assert_equal('', pgquery#statusline())

  call assert_equal(1, pgquery#new('pathless', 'postgresql://user@localhost'))
  call assert_equal(' [DB: pathless]', pgquery#statusline())
  call assert_equal(1, pgquery#edit('pathless',
        \ 'postgresql://user:secret@localhost/private?sslmode=require'))
  call assert_equal(' [DB: pathless]', pgquery#statusline())
  call assert_equal('postgresql://user:secret@localhost/private?sslmode=require',
        \ trim(execute('DBShowURL')))
  call assert_equal(1, pgquery#delete('pathless'))
  call assert_match('this buffer is disconnected', execute('DBShowURL'))
finally
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
