# vim-pgquery

`vim-pgquery` runs the SQL block under your cursor—or an explicitly selected
line range—through PostgreSQL's `psql` client. It remembers named database URLs
and project directories while keeping the selected connection buffer-local, so
an unrelated SQL buffer does not inherit another project's database.

The plugin targets Vim 8 and Vim 9. `psql` must be available in `PATH`.
`:DBExecute` requires Vim's `+job` feature, and `:DBTerminal` requires
`+terminal`; connection management still works without those features. Vim
must also provide JSON encoding/decoding (standard in supported Vim 8/9
builds).

## Installation

Install the repository with your plugin manager, or as a native Vim package:

```sh
git clone https://github.com/your-user/vim-pgquery.git \
  ~/.vim/pack/plugins/start/vim-pgquery
vim -u NONE -c 'helptags ~/.vim/pack/plugins/start/vim-pgquery/doc' -c quit
```

## Commands

- `:DBNew` prompts for a unique friendly name and then, with hidden input, a
  `postgres://` or `postgresql://` URL. It saves and selects the connection for
  the current buffer, and maps Vim's current working directory to it.
- `:DBConnect` selects a saved connection for the current buffer. Vim builds
  with popups use `popup_menu()`; other builds use a numbered prompt. The list
  shows `name — user@host:port/database`, never the password or URL parameters.
- `:DBEdit [name]` changes a connection's name and URL. When no name is given,
  it presents the saved-connection picker; leave the URL prompt blank to keep
  the existing URL. Renames update project mappings, and all loaded buffers
  using the connection are refreshed.
- `:DBDelete [name]` deletes a connection after confirmation. When no name is
  given, it presents the saved-connection picker. Project mappings that use the
  connection are removed and loaded buffers using it are disconnected.
- `:DBSetProject [directory]` maps the selected connection to a directory. It
  uses `getcwd()` when the argument is omitted.
- `:DBExecute` asynchronously runs the nonblank block containing the cursor.
  Give it a range (including by running it from Visual mode) to execute every
  selected line instead. Blank lines delimit cursor blocks. Standard output
  and standard error appear in a read-only scratch split; a failing `psql`
  status is shown there and reported.
- `:DBTerminal` opens a Vim terminal running `psql` with the selected
  connection.

The plugin deliberately installs no mappings. Optional examples:

```vim
nnoremap <silent> <leader>dq :DBExecute<CR>
xnoremap <silent> <leader>dq :DBExecute<CR>
nnoremap <silent> <leader>dt :DBTerminal<CR>
```

## Projects and buffer isolation

When a `*.sql` buffer is entered, the plugin resolves symlinks and searches
from the file's directory toward the filesystem root. The nearest mapped
ancestor wins. Matching uses complete path components, so `/work/app` does not
match `/work/application`.

The selection lives in `b:pgquery_connection`. An unmapped buffer starts
disconnected, while a connection explicitly chosen with `:DBConnect` remains
selected for that buffer. Missing connections and stale project mappings fail
closed rather than falling back to another database.

For interoperability with `vim-dadbod` and `vim-dadbod-completion`, the
selected URL is also exposed as buffer-local `b:db`. This makes an SQL
`omnifunc` such as `vim_dadbod_completion#omni` use the same connection without
creating a global database setting. If `vim-dadbod-completion` is loaded,
pgquery connects and starts warming its completion cache as soon as a mapped
SQL buffer is opened, so the first completion does not have to initialize it.

```vim
autocmd FileType sql setlocal omnifunc=vim_dadbod_completion#omni
```

To retain vim-dadbod-completion's lazy connection behavior, set this before
plugins are loaded:

```vim
let g:pgquery_eager_dadbod_completion = 0
```

## Storage and credentials

State is stored as versioned JSON at `~/.vim/pgquery.json`. Set a different
location before the plugin loads if desired:

```vim
let g:pgquery_store_path = expand('~/.config/vim/pgquery.json')
```

Writes use a same-directory temporary file and atomic rename, and set the file
mode to `0600`. Malformed JSON or an invalid schema is never overwritten; Vim
reports the path so you can fix or move it. `:DBEdit` and `:DBDelete` preserve
that behavior when changing the store.

Database URLs are plaintext despite the file permissions. Prefer URLs without
passwords together with `.pgpass` or another PostgreSQL credential mechanism
when stronger protection is needed. URLs are passed as individual process
arguments and are not interpolated into a shell command.

See `:help pgquery` for the complete reference.
