let s:store_version = 1
let s:jobs = {}
let s:next_job_id = 1

function! s:error(message) abort
  echohl ErrorMsg
  echomsg 'pgquery: ' . a:message
  echohl None
  return 0
endfunction

function! s:empty_store() abort
  return {'version': s:store_version, 'connections': {}, 'projects': {}}
endfunction

function! s:store_path() abort
  let path = expand(get(g:, 'pgquery_store_path', '~/.vim/pgquery.json'))
  return fnamemodify(path, ':p')
endfunction

function! s:valid_url(url) abort
  return type(a:url) == v:t_string
        \ && a:url =~# '^postgres\%(ql\)\?://\S\+$'
endfunction

function! s:validate_store(store) abort
  if type(a:store) != v:t_dict
    throw 'the top-level value is not an object'
  endif
  if type(get(a:store, 'version', 0)) != v:t_number
        \ || a:store.version != s:store_version
    throw 'unsupported or missing version'
  endif
  if type(get(a:store, 'connections', 0)) != v:t_dict
    throw '"connections" must be an object'
  endif
  if type(get(a:store, 'projects', 0)) != v:t_dict
    throw '"projects" must be an object'
  endif
  for [name, url] in items(a:store.connections)
    if empty(trim(name)) || !s:valid_url(url)
      throw 'connection "' . name . '" is invalid'
    endif
  endfor
  for [root, name] in items(a:store.projects)
    if empty(root) || type(name) != v:t_string || empty(name)
      throw 'project mapping "' . root . '" is invalid'
    endif
    let normalized = fnamemodify(root, ':p')
    let normalized = normalized ==# '/' ? '/' : substitute(normalized, '/\+$', '', '')
    if normalized !=# root
      throw 'project root "' . root . '" must be a normalized absolute path'
    endif
  endfor
  return a:store
endfunction

function! s:read_store(allow_missing) abort
  let path = s:store_path()
  if !filereadable(path)
    if !empty(getftype(path))
      call s:error('cannot read existing store ' . path . '; check its type and permissions. It was not changed')
      return v:null
    endif
    if a:allow_missing
      return s:empty_store()
    endif
    call s:error('no connection store exists; use :DBNew first')
    return v:null
  endif
  try
    let contents = join(readfile(path, 'b'), "\n")
    if empty(contents)
      throw 'the file is empty'
    endif
    return s:validate_store(json_decode(contents))
  catch
    call s:error('cannot read ' . path . ': ' . substitute(v:exception, '^Vim\%((\a\+)\)\=:', '', '') . '. Fix or move the file; it was not changed')
    return v:null
  endtry
endfunction

function! s:write_store(store) abort
  try
    call s:validate_store(a:store)
  catch
    return s:error('refusing to write invalid storage: ' . v:exception)
  endtry

  let path = s:store_path()
  let directory = fnamemodify(path, ':h')
  if !isdirectory(directory)
    try
      call mkdir(directory, 'p', 0700)
    catch
      return s:error('cannot create storage directory ' . directory . ': ' . v:exception)
    endtry
  endif

  " Put the temporary file beside the destination so rename() is atomic.
  let temporary = directory . '/.' . fnamemodify(path, ':t') . '.tmp.' . getpid() . '.' . reltimefloat(reltime())
  try
    call writefile([json_encode(a:store)], temporary, 'b')
    if setfperm(temporary, 'rw-------') == 0
      throw 'could not set mode 0600 on the temporary file'
    endif
    if rename(temporary, path) != 0
      throw 'atomic rename failed'
    endif
    " Defend against unusual rename implementations retaining target metadata.
    if setfperm(path, 'rw-------') == 0
      throw 'could not set mode 0600 on the store'
    endif
  catch
    if filereadable(temporary)
      call delete(temporary)
    endif
    return s:error('cannot save ' . path . ': ' . v:exception)
  endtry
  return 1
endfunction

function! s:canonical_directory(path) abort
  let path = empty(a:path) ? getcwd() : a:path
  let absolute = fnamemodify(path, ':p')
  if !isdirectory(absolute)
    throw 'not a directory: ' . a:path
  endif
  let canonical = resolve(absolute)
  return canonical ==# '/' ? '/' : substitute(canonical, '/\+$', '', '')
endfunction

function! s:canonical_file_directory(buffer) abort
  let name = bufname(a:buffer)
  if empty(name)
    return s:canonical_directory(getcwd())
  endif
  let absolute = fnamemodify(name, ':p')
  if !empty(getftype(absolute))
    return s:canonical_directory(fnamemodify(resolve(absolute), ':h'))
  endif
  " Resolving the parent also handles a new file below a symlinked directory.
  return s:canonical_directory(fnamemodify(absolute, ':h'))
endfunction

function! s:mapping_for_directory(projects, directory) abort
  let current = a:directory
  while 1
    if has_key(a:projects, current)
      return [current, a:projects[current]]
    endif
    let parent = fnamemodify(current, ':h')
    if parent ==# current
      break
    endif
    let current = parent
  endwhile
  return []
endfunction

function! pgquery#new(name, url) abort
  let name = trim(a:name)
  if empty(name)
    return s:error('connection name must not be empty')
  endif
  if !s:valid_url(a:url)
    return s:error('URL must be a nonempty postgres:// or postgresql:// URL without whitespace')
  endif

  let store = s:read_store(1)
  if store is v:null
    return 0
  endif
  if has_key(store.connections, name)
    return s:error('connection "' . name . '" already exists; edit or remove the protected store deliberately to replace it')
  endif
  try
    let root = s:canonical_directory(getcwd())
  catch
    return s:error(v:exception)
  endtry
  let store.connections[name] = a:url
  let store.projects[root] = name
  if !s:write_store(store)
    return 0
  endif
  let b:pgquery_connection = name
  let b:pgquery_connection_explicit = 1
  echomsg 'pgquery: saved "' . name . '" and mapped ' . root
  return 1
endfunction

function! pgquery#new_prompt() abort
  call inputsave()
  try
    let name = input('Connection name: ')
    if empty(name)
      return 0
    endif
    let url = inputsecret('PostgreSQL URL: ')
  finally
    call inputrestore()
  endtry
  return pgquery#new(name, url)
endfunction

function! s:url_label(name, url) abort
  let rest = substitute(a:url, '^postgres\%(ql\)\?://', '', '')
  let rest = split(rest, '[?#]', 1)[0]
  let slash = stridx(rest, '/')
  let authority = slash < 0 ? rest : strpart(rest, 0, slash)
  let database = slash < 0 ? '?' : split(strpart(rest, slash + 1), '/', 1)[0]
  let at = strridx(authority, '@')
  let userinfo = at < 0 ? '' : strpart(authority, 0, at)
  let hostport = at < 0 ? authority : strpart(authority, at + 1)
  let user = empty(userinfo) ? '?' : split(userinfo, ':', 1)[0]
  if empty(hostport)
    let hostport = '?'
  endif
  if hostport !~# ':\d\+$' && hostport !~# '^\[.*\]:\d\+$'
    let hostport .= ':5432'
  endif
  return a:name . ' — ' . user . '@' . hostport . '/' . (empty(database) ? '?' : database)
endfunction

function! s:select_connection(buffer, name) abort
  let store = s:read_store(0)
  if store is v:null
    return 0
  endif
  if !has_key(store.connections, a:name)
    call setbufvar(a:buffer, 'pgquery_connection', v:null)
    call setbufvar(a:buffer, 'pgquery_connection_explicit', 0)
    return s:error('connection "' . a:name . '" no longer exists')
  endif
  call setbufvar(a:buffer, 'pgquery_connection', a:name)
  call setbufvar(a:buffer, 'pgquery_connection_explicit', 1)
  echomsg 'pgquery: buffer connected to "' . a:name . '"'
  return 1
endfunction

function! s:connect_callback(buffer, names, popup, result) abort
  if a:result <= 0 || a:result > len(a:names) || !bufexists(a:buffer)
    return 0
  endif
  return s:select_connection(a:buffer, a:names[a:result - 1])
endfunction

function! pgquery#connect() abort
  let store = s:read_store(0)
  if store is v:null
    return 0
  endif
  let names = sort(keys(store.connections))
  if empty(names)
    return s:error('no saved connections; use :DBNew first')
  endif
  let labels = map(copy(names), 's:url_label(v:val, store.connections[v:val])')
  let target = bufnr('%')
  if exists('*popup_menu')
    call popup_menu(labels, {
          \ 'title': ' PostgreSQL connection ',
          \ 'callback': function('s:connect_callback', [target, names])})
    return 1
  endif
  let choice = inputlist(['Select PostgreSQL connection:'] + map(copy(labels), '(v:key + 1) . ". " . v:val'))
  if choice <= 0 || choice > len(names)
    return 0
  endif
  return s:select_connection(target, names[choice - 1])
endfunction

function! pgquery#set_project(path) abort
  if !exists('b:pgquery_connection') || type(b:pgquery_connection) != v:t_string || empty(b:pgquery_connection)
    return s:error('this buffer has no selected connection; use :DBConnect or :DBNew first')
  endif
  let store = s:read_store(0)
  if store is v:null
    return 0
  endif
  if !has_key(store.connections, b:pgquery_connection)
    unlet b:pgquery_connection
    unlet! b:pgquery_connection_explicit
    return s:error('the selected connection is missing from storage; select another with :DBConnect')
  endif
  try
    let root = s:canonical_directory(a:path)
  catch
    return s:error(v:exception)
  endtry
  let store.projects[root] = b:pgquery_connection
  if !s:write_store(store)
    return 0
  endif
  echomsg 'pgquery: mapped ' . root . ' to "' . b:pgquery_connection . '"'
  return 1
endfunction

function! pgquery#select_for_buffer() abort
  if expand('%:e') !=# 'sql'
    return 0
  endif
  let path = s:store_path()
  if !filereadable(path)
    if empty(getftype(path))
      return 0
    endif
  endif
  let store = s:read_store(0)
  if store is v:null
    unlet! b:pgquery_connection
    unlet! b:pgquery_connection_explicit
    return 0
  endif
  try
    let directory = s:canonical_file_directory(bufnr('%'))
  catch
    unlet! b:pgquery_connection
    unlet! b:pgquery_connection_explicit
    return s:error(v:exception)
  endtry
  let mapping = s:mapping_for_directory(store.projects, directory)
  if empty(mapping)
    " Only an explicit buffer-local selection remains valid when unmapped.
    if !get(b:, 'pgquery_connection_explicit', 0)
      unlet! b:pgquery_connection
      unlet! b:pgquery_connection_explicit
    endif
    return 0
  endif
  let name = mapping[1]
  if !has_key(store.connections, name)
    unlet! b:pgquery_connection
    unlet! b:pgquery_connection_explicit
    return s:error('project ' . mapping[0] . ' refers to missing connection "' . name . '"; fix the protected store')
  endif
  let b:pgquery_connection = name
  let b:pgquery_connection_explicit = 0
  return 1
endfunction

function! s:active_connection() abort
  if !exists('b:pgquery_connection') || type(b:pgquery_connection) != v:t_string || empty(b:pgquery_connection)
    call s:error('this buffer is disconnected; use :DBConnect or :DBNew')
    return v:null
  endif
  let store = s:read_store(0)
  if store is v:null
    return v:null
  endif
  if !has_key(store.connections, b:pgquery_connection)
    let missing = b:pgquery_connection
    unlet b:pgquery_connection
    unlet! b:pgquery_connection_explicit
    call s:error('connection "' . missing . '" is missing from storage; the buffer was disconnected')
    return v:null
  endif
  return {'name': b:pgquery_connection, 'url': store.connections[b:pgquery_connection]}
endfunction

function! s:sql_block(line_number) abort
  if a:line_number < 1 || a:line_number > line('$') || getline(a:line_number) =~# '^\s*$'
    return []
  endif
  let first = a:line_number
  while first > 1 && getline(first - 1) !~# '^\s*$'
    let first -= 1
  endwhile
  let last = a:line_number
  while last < line('$') && getline(last + 1) !~# '^\s*$'
    let last += 1
  endwhile
  return getline(first, last)
endfunction

function! s:on_job_output(identifier, channel, message) abort
  let key = string(a:identifier)
  if has_key(s:jobs, key) && !empty(a:message)
    call add(s:jobs[key].output, a:message)
  endif
endfunction

function! s:show_job_result(state, status) abort
  execute 'belowright new'
  setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted
  let b:pgquery_exit_status = a:status
  let b:pgquery_job_id = a:state.id
  execute 'file ' . fnameescape('[pgquery ' . a:state.name . ' #' . a:state.id . ']')
  let lines = copy(a:state.output)
  if empty(lines)
    let lines = ['(no output)']
  endif
  if a:status != 0
    call add(lines, '')
    call add(lines, 'psql exited with status ' . a:status)
  endif
  call setline(1, lines)
  normal! gg
  setlocal nomodified readonly nomodifiable
endfunction

function! s:on_job_exit(identifier, job, status) abort
  let key = string(a:identifier)
  if !has_key(s:jobs, key)
    return
  endif
  let state = remove(s:jobs, key)
  if !empty(state.temporary)
    call delete(state.temporary)
  endif
  call s:show_job_result(state, a:status)
  if a:status != 0
    call s:error('psql exited with status ' . a:status)
  endif
endfunction

function! pgquery#execute() abort
  if !has('job') || !exists('*job_start')
    return s:error(':DBExecute requires Vim compiled with +job')
  endif
  let connection = s:active_connection()
  if connection is v:null
    return 0
  endif
  let sql = s:sql_block(line('.'))
  if empty(sql)
    return s:error('no nonblank SQL block under the cursor')
  endif
  let temporary = tempname() . '.sql'
  try
    call writefile(sql, temporary)
    if setfperm(temporary, 'rw-------') == 0
      throw 'could not set mode 0600'
    endif
  catch
    call delete(temporary)
    return s:error('cannot create temporary SQL file: ' . v:exception)
  endtry
  let identifier = s:next_job_id
  let s:next_job_id += 1
  let key = string(identifier)
  let s:jobs[key] = {'id': identifier, 'name': connection.name, 'temporary': temporary, 'output': []}
  let command = ['psql', connection.url, '-f', temporary]
  try
    let job = job_start(command, {
          \ 'out_mode': 'nl', 'err_mode': 'nl',
          \ 'out_cb': function('s:on_job_output', [identifier]),
          \ 'err_cb': function('s:on_job_output', [identifier]),
          \ 'exit_cb': function('s:on_job_exit', [identifier])})
  catch
    call delete(temporary)
    call remove(s:jobs, key)
    return s:error('could not start psql: ' . v:exception)
  endtry
  if job_status(job) ==# 'fail'
    call delete(temporary)
    call remove(s:jobs, key)
    return s:error('could not start psql; make sure it is installed and in PATH')
  endif
  echomsg 'pgquery: started query #' . identifier . ' using "' . connection.name . '"'
  return identifier
endfunction

function! pgquery#cleanup() abort
  for state in values(s:jobs)
    if !empty(state.temporary)
      call delete(state.temporary)
    endif
  endfor
endfunction

function! pgquery#terminal() abort
  if !has('terminal') || !exists('*term_start')
    return s:error(':DBTerminal requires Vim compiled with +terminal')
  endif
  let connection = s:active_connection()
  if connection is v:null
    return 0
  endif
  belowright new
  try
    let terminal_buffer = term_start(['psql', connection.url], {
          \ 'curwin': 1, 'term_name': 'pgquery: ' . connection.name})
  catch
    bwipeout!
    return s:error('could not start psql: ' . v:exception)
  endtry
  if terminal_buffer == 0 || job_status(term_getjob(terminal_buffer)) ==# 'fail'
    bwipeout!
    return s:error('could not start psql; make sure it is installed and in PATH')
  endif
  return 1
endfunction
