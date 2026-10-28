# vim-pgquery

`vim-pgquery` runs the SQL block under your cursor—or an explicitly selected
line range—through PostgreSQL's `psql` client. It remembers named database URLs
and the last selected connection for each file path, so each SQL file keeps
its own database across buffer switches and Vim sessions.

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
  the current buffer, and remembers it for the file path.
- `:DBConnect` selects and remembers a saved connection for the current file.
  Vim builds with popups use `popup_menu()`; other builds use a numbered prompt. The list
  shows `name — user@host:port/database`, never the password or URL parameters.
- `:DBCurrent` displays the current buffer's full saved connection URL. This
  includes credentials and URL parameters when present.
- `:DBEdit [name]` changes a connection's name and URL. When no name is given,
  it presents the saved-connection picker; leave the URL prompt blank to keep
  the existing URL. Renames update file mappings, and all loaded buffers
  using the connection are refreshed.
- `:DBDelete [name]` deletes a connection after confirmation. When no name is
  given, it presents the saved-connection picker. File mappings that use the
  connection are removed and loaded buffers using it are disconnected.
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

## File connections and buffer isolation

When a file buffer is entered, the plugin restores the last connection
selected for that exact file path. Paths are absolute and symlinks are
resolved, including for new files. `:DBNew` and `:DBConnect` remember the
selection immediately; returning from query results keeps that selection.

The selection lives in `b:pgquery_connection`. A file with no saved connection
stays disconnected until you use `:DBConnect` or `:DBNew`. Other files in the
same directory have independent selections. Unnamed buffers keep their
selection only in memory until they are named and a connection is used.
Missing saved connections fail closed rather than selecting another database.

To show the selected connection name in an existing Vim statusline, add this
to your vimrc:

```vim
set laststatus=2
set statusline+=%{pgquery#statusline()}
```

`pgquery#statusline()` displays `[DB: name]` for the current buffer and nothing
when it is disconnected. It uses the saved connection name, even when that
differs from the database in the URL. It updates when you switch buffers,
rename a connection, or delete one. If you use Vim's default statusline, set
a full format first, for example:

```vim
set statusline=%f%m%r%=%{pgquery#statusline()}\ %l:%c
```

For interoperability with `vim-dadbod` and `vim-dadbod-completion`, the
selected URL is also exposed as buffer-local `b:db`. This makes an SQL
`omnifunc` such as `vim_dadbod_completion#omni` use the same connection without
creating a global database setting. If `vim-dadbod-completion` is loaded,
pgquery connects and starts warming its completion cache as soon as an SQL
buffer with a remembered connection is opened, so the first completion does
not have to initialize it.

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

Version 2 stores named connections and a `files` map from absolute file paths
to connection names. Version 1 stores remain readable: saved connections are
preserved, and obsolete project defaults are ignored. The next change writes
the version 2 format. `:DBSetProject` has been removed; select a connection for
each file with `:DBConnect`.

Database URLs, including any embedded passwords, are stored as plaintext.
Mode `0600` restricts access to your Unix user, but processes running as you,
root, and copies in backups can still expose those credentials. The temporary
store file is written before its permissions are restricted, leaving a brief
exposure window if the directory is accessible and your umask permits reads.

Full URLs are also passed to `psql` as individual process arguments, which may
be visible through process inspection depending on operating-system access
restrictions. They are not interpolated into a shell command. `:DBCurrent`
displays the full URL, including passwords, so take care during screen sharing.

Prefer password-free URLs such as `postgresql://user@host/database` and put
passwords in PostgreSQL's [`~/.pgpass` file](https://www.postgresql.org/docs/current/libpq-pgpass.html)
with permissions set using `chmod 0600 ~/.pgpass`. This keeps passwords out of
the plugin store and process arguments. `.pgpass` itself stores plaintext
passwords, so protect it and its backups as well.

See `:help pgquery` for the complete reference.
