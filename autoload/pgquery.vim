let s:store_version = 1
let s:jobs = []

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

function! s:warm_dadbod_completion(buffer, url) abort
  if !get(g:, 'pgquery_eager_dadbod_completion', 1)
        \ || !exists('g:vim_dadbod_completion_loaded')
        \ || a:buffer != bufnr('%')
        \ || getbufvar(a:buffer, '&filetype') !=# 'sql'
    return 0
  endif
  if getbufvar(a:buffer, 'pgquery_dadbod_completion_url', '') ==# a:url
    return 1
  endif

  " The completion plugin's FileType hook can run before pgquery's
  " BufReadPost hook sets b:db. Prime its cache now that the URL is known.
  call setbufvar(a:buffer, 'pgquery_dadbod_completion_url', a:url)
  try
    call vim_dadbod_completion#fetch(a:buffer)
  catch
    let message = substitute(v:exception, '^Vim\%((\a\+)\)\=:', '', '')
    return s:error('could not initialize vim-dadbod-completion: ' . message)
  endtry
  return 1
endfunction

function! s:activate_buffer(buffer, name, url, explicit) abort
  call setbufvar(a:buffer, 'pgquery_connection', a:name)
  call setbufvar(a:buffer, 'pgquery_connection_explicit', a:explicit)
  " vim-dadbod and vim-dadbod-completion discover buffer connections here.
  call setbufvar(a:buffer, 'db', a:url)
  call setbufvar(a:buffer, 'pgquery_dadbod_url', a:url)
  call s:warm_dadbod_completion(a:buffer, a:url)
  redrawstatus!
endfunction

function! s:disconnect_buffer(buffer) abort
  let managed_url = getbufvar(a:buffer, 'pgquery_dadbod_url', v:null)
  let current_url = getbufvar(a:buffer, 'db', v:null)

  if a:buffer == bufnr('%')
    if type(managed_url) == v:t_string
          \ && type(current_url) == v:t_string
          \ && current_url ==# managed_url
      unlet! b:db
    endif
    unlet! b:pgquery_connection
    unlet! b:pgquery_connection_explicit
    unlet! b:pgquery_dadbod_url
    unlet! b:pgquery_dadbod_completion_url
  else
    if type(managed_url) == v:t_string
          \ && type(current_url) == v:t_string
          \ && current_url ==# managed_url
      " Vim has no deletebufvar(); leave a neutral value until next entry.
      call setbufvar(a:buffer, 'db', '')
    endif
    call setbufvar(a:buffer, 'pgquery_connection', v:null)
    call setbufvar(a:buffer, 'pgquery_connection_explicit', 0)
    call setbufvar(a:buffer, 'pgquery_dadbod_url', v:null)
    call setbufvar(a:buffer, 'pgquery_dadbod_completion_url', v:null)
  endif
  redrawstatus!
endfunction

function! s:database_from_url(url) abort
  let rest = substitute(a:url, '^postgres\%(ql\)\?://', '', '')
  let rest = split(rest, '[?#]', 1)[0]
  let slash = stridx(rest, '/')
  return slash < 0 ? '' : matchstr(strpart(rest, slash + 1), '^[^/]*')
endfunction

" Use this in 'statusline' to show the selected connection name.
function! pgquery#statusline() abort
  let name = get(b:, 'pgquery_connection', '')
  if type(name) != v:t_string || empty(name)
    return ''
  endif
  return ' [DB: ' . name . ']'
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
    return s:error('connection "' . name . '" already exists; use :DBEdit to change it')
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
  call s:activate_buffer(bufnr('%'), name, a:url, 1)
  echomsg 'pgquery: saved "' . name . '" and mapped ' . root
  return 1
endfunction

function! s:update_connected_buffers(old_name, new_name, new_url) abort
  for buffer in range(1, bufnr('$'))
    if !bufexists(buffer)
          \ || getbufvar(buffer, 'pgquery_connection', v:null) !=# a:old_name
      continue
    endif

    let managed_url = getbufvar(buffer, 'pgquery_dadbod_url', v:null)
    let current_url = getbufvar(buffer, 'db', v:null)
    call setbufvar(buffer, 'pgquery_connection', a:new_name)
    call setbufvar(buffer, 'pgquery_dadbod_url', a:new_url)
    call setbufvar(buffer, 'pgquery_dadbod_completion_url', v:null)

    " Do not overwrite b:db when another plugin changed it after pgquery did.
    if type(managed_url) == v:t_string
          \ && type(current_url) == v:t_string
          \ && current_url ==# managed_url
      call setbufvar(buffer, 'db', a:new_url)
      call s:warm_dadbod_completion(buffer, a:new_url)
    endif
  endfor
  redrawstatus!
endfunction

" With two arguments, change only the URL. A third argument also renames it.
function! pgquery#edit(name, ...) abort
  if a:0 == 1
    let new_name = trim(a:name)
    let url = a:1
  elseif a:0 == 2
    let new_name = trim(a:1)
    let url = a:2
  else
    return s:error('edit expects an existing name, optional new name, and URL')
  endif
  if empty(new_name)
    return s:error('connection name must not be empty')
  endif
  if !s:valid_url(url)
    return s:error('URL must be a nonempty postgres:// or postgresql:// URL without whitespace')
  endif

  let store = s:read_store(0)
  if store is v:null
    return 0
  endif
  if !has_key(store.connections, a:name)
    return s:error('connection "' . a:name . '" does not exist')
  endif
  if new_name !=# a:name && has_key(store.connections, new_name)
    return s:error('connection "' . new_name . '" already exists')
  endif

  if new_name !=# a:name
    call remove(store.connections, a:name)
    for root in keys(store.projects)
      if store.projects[root] ==# a:name
        let store.projects[root] = new_name
      endif
    endfor
  endif
  let store.connections[new_name] = url
  if !s:write_store(store)
    return 0
  endif

  call s:update_connected_buffers(a:name, new_name, url)
  echomsg 'pgquery: updated connection "' . a:name . '"'
        \ . (new_name ==# a:name ? '' : ' as "' . new_name . '"')
  return 1
endfunction

function! s:edit_named_prompt(name) abort
  let store = s:read_store(0)
  if store is v:null
    return 0
  endif
  if !has_key(store.connections, a:name)
    return s:error('connection "' . a:name . '" does not exist')
  endif

  " Keep keys typed after a popup selection available to these prompts.
  let new_name = input('Connection name: ', a:name)
  if empty(new_name)
    return 0
  endif
  let url = inputsecret('New PostgreSQL URL (leave blank to keep current): ')
  if empty(url)
    let url = store.connections[a:name]
  endif
  return pgquery#edit(a:name, new_name, url)
endfunction

function! s:edit_callback(names, popup, result) abort
  if a:result <= 0 || a:result > len(a:names)
    return 0
  endif
  return s:edit_named_prompt(a:names[a:result - 1])
endfunction

function! pgquery#edit_prompt(...) abort
  if a:0 > 0 && !empty(a:1)
    return s:edit_named_prompt(a:1)
  endif
  let store = s:read_store(0)
  if store is v:null
    return 0
  endif
  let names = sort(keys(store.connections))
  if empty(names)
    return s:error('no saved connections; use :DBNew first')
  endif
  let labels = map(copy(names), 's:url_label(v:val, store.connections[v:val])')
  if exists('*popup_menu')
    call popup_menu(labels, {
          \ 'title': ' Edit PostgreSQL connection ',
          \ 'callback': function('s:edit_callback', [names])})
    return 1
  endif
  let choices = map(copy(labels), '(v:key + 1) . ". " . v:val')
  let choice = inputlist(['Edit PostgreSQL connection:'] + choices)
  if choice <= 0 || choice > len(names)
    return 0
  endif
  return s:edit_named_prompt(names[choice - 1])
endfunction

function! pgquery#delete(name) abort
  let store = s:read_store(0)
  if store is v:null
    return 0
  endif
  if !has_key(store.connections, a:name)
    return s:error('connection "' . a:name . '" does not exist')
  endif

  call remove(store.connections, a:name)
  let removed_mappings = 0
  for root in keys(store.projects)
    if store.projects[root] ==# a:name
      call remove(store.projects, root)
      let removed_mappings += 1
    endif
  endfor
  if !s:write_store(store)
    return 0
  endif

  for buffer in range(1, bufnr('$'))
    if bufexists(buffer)
          \ && getbufvar(buffer, 'pgquery_connection', v:null) ==# a:name
      call s:disconnect_buffer(buffer)
    endif
  endfor
  echomsg 'pgquery: deleted connection "' . a:name . '" and removed '
        \ . removed_mappings . ' project mapping' . (removed_mappings == 1 ? '' : 's')
  return 1
endfunction

function! s:delete_named_prompt(name) abort
  let store = s:read_store(0)
  if store is v:null
    return 0
  endif
  if !has_key(store.connections, a:name)
    return s:error('connection "' . a:name . '" does not exist')
  endif
  let mappings = count(values(store.projects), a:name)
  let message = 'Delete connection "' . a:name . '"? This also removes '
        \ . mappings . ' project mapping' . (mappings == 1 ? '' : 's') . '.'
  if confirm(message, "&Delete\n&Cancel", 2) != 1
    return 0
  endif
  return pgquery#delete(a:name)
endfunction

function! s:delete_callback(names, popup, result) abort
  if a:result <= 0 || a:result > len(a:names)
    return 0
  endif
  return s:delete_named_prompt(a:names[a:result - 1])
endfunction

function! pgquery#delete_prompt(...) abort
  if a:0 > 0 && !empty(a:1)
    return s:delete_named_prompt(a:1)
  endif
  let store = s:read_store(0)
  if store is v:null
    return 0
  endif
  let names = sort(keys(store.connections))
  if empty(names)
    return s:error('no saved connections; use :DBNew first')
  endif
  let labels = map(copy(names), 's:url_label(v:val, store.connections[v:val])')
  if exists('*popup_menu')
    call popup_menu(labels, {
          \ 'title': ' Delete PostgreSQL connection ',
          \ 'callback': function('s:delete_callback', [names])})
    return 1
  endif
  let choices = map(copy(labels), '(v:key + 1) . ". " . v:val')
  let choice = inputlist(['Delete PostgreSQL connection:'] + choices)
  if choice <= 0 || choice > len(names)
    return 0
  endif
  return s:delete_named_prompt(names[choice - 1])
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
  let database = s:database_from_url(a:url)
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

function! pgquery#complete_connections(lead, command_line, cursor_position) abort
  let store = s:read_store(0)
  if store is v:null
    return []
  endif
  return filter(sort(keys(store.connections)), 'stridx(v:val, a:lead) == 0')
endfunction

function! s:select_connection(buffer, name) abort
  let store = s:read_store(0)
  if store is v:null
    return 0
  endif
  if !has_key(store.connections, a:name)
    call s:disconnect_buffer(a:buffer)
    return s:error('connection "' . a:name . '" no longer exists')
  endif
  call s:activate_buffer(a:buffer, a:name, store.connections[a:name], 1)
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
    call s:disconnect_buffer(bufnr('%'))
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
    call s:disconnect_buffer(bufnr('%'))
    return 0
  endif
  try
    let directory = s:canonical_file_directory(bufnr('%'))
  catch
    call s:disconnect_buffer(bufnr('%'))
    return s:error(v:exception)
  endtry
  let mapping = s:mapping_for_directory(store.projects, directory)
  if empty(mapping)
    " Only an explicit buffer-local selection remains valid when unmapped.
    if !get(b:, 'pgquery_connection_explicit', 0)
      call s:disconnect_buffer(bufnr('%'))
    endif
    return 0
  endif
  let name = mapping[1]
  if !has_key(store.connections, name)
    call s:disconnect_buffer(bufnr('%'))
    return s:error('project ' . mapping[0] . ' refers to missing connection "' . name . '"; fix the protected store')
  endif
  call s:activate_buffer(bufnr('%'), name, store.connections[name], 0)
  return 1
endfunction

function! s:active_connection() abort
  if !exists('b:pgquery_connection') || type(b:pgquery_connection) != v:t_string || empty(b:pgquery_connection)
    call s:error('this buffer is disconnected; use :DBConnect or :DBNew')
    return v:null
  endif
  let store = s:read_store(0)
  if store is v:null
    call s:disconnect_buffer(bufnr('%'))
    return v:null
  endif
  if !has_key(store.connections, b:pgquery_connection)
    let missing = b:pgquery_connection
    call s:disconnect_buffer(bufnr('%'))
    call s:error('connection "' . missing . '" is missing from storage; the buffer was disconnected')
    return v:null
  endif
  return {'name': b:pgquery_connection, 'url': store.connections[b:pgquery_connection]}
endfunction

function! pgquery#show_url() abort
  let connection = s:active_connection()
  if connection is v:null
    return 0
  endif
  echo connection.url
  return 1
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

function! s:on_job_output(state, channel, message) abort
  if index(s:jobs, a:state) >= 0 && !empty(a:message)
    call add(a:state.output, a:message)
  endif
endfunction

function! s:buffer_named(name) abort
  for buffer in getbufinfo()
    if bufname(buffer.bufnr) ==# a:name
      return buffer.bufnr
    endif
  endfor
  return -1
endfunction

function! s:show_job_result(state, status) abort
  let result_name = '[pgquery ' . a:state.name . ']'
  let result_buffer = s:buffer_named(result_name)
  if result_buffer > 0
    let result_window = bufwinid(result_buffer)
    if result_window > 0
      call win_gotoid(result_window)
    else
      silent execute 'belowright sbuffer ' . result_buffer
    endif
    setlocal modifiable noreadonly
    silent %delete _
  else
    silent execute 'belowright new'
    setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted
    silent execute 'file ' . fnameescape(result_name)
  endif
  let b:pgquery_exit_status = a:status
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

function! s:on_job_exit(state, job, status) abort
  let job_index = index(s:jobs, a:state)
  if job_index < 0
    return
  endif
  call remove(s:jobs, job_index)
  if !empty(a:state.temporary)
    call delete(a:state.temporary)
  endif
  call s:show_job_result(a:state, a:status)
  if a:status != 0
    call s:error('psql exited with status ' . a:status)
  endif
endfunction

function! pgquery#execute(...) abort
  if !has('job') || !exists('*job_start')
    return s:error(':DBExecute requires Vim compiled with +job')
  endif
  let connection = s:active_connection()
  if connection is v:null
    return 0
  endif
  if a:0 >= 3 && a:1 > 0
    let sql = getline(a:2, a:3)
    if join(sql, "\n") !~# '\S'
      return s:error('no SQL in the selected range')
    endif
  else
    let sql = s:sql_block(line('.'))
    if empty(sql)
      return s:error('no nonblank SQL block under the cursor')
    endif
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
  let state = {'name': connection.name, 'temporary': temporary, 'output': []}
  call add(s:jobs, state)
  let command = ['psql', connection.url, '-f', temporary]
  try
    let job = job_start(command, {
          \ 'out_mode': 'nl', 'err_mode': 'nl',
          \ 'out_cb': function('s:on_job_output', [state]),
          \ 'err_cb': function('s:on_job_output', [state]),
          \ 'exit_cb': function('s:on_job_exit', [state])})
  catch
    call delete(temporary)
    call remove(s:jobs, index(s:jobs, state))
    return s:error('could not start psql: ' . v:exception)
  endtry
  if job_status(job) ==# 'fail'
    call delete(temporary)
    call remove(s:jobs, index(s:jobs, state))
    return s:error('could not start psql; make sure it is installed and in PATH')
  endif
  return 1
endfunction

function! pgquery#cleanup() abort
  for state in s:jobs
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
