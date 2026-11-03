# vim-pgquery
Write and run PostgreSQL queries directly in plain Vim.

Save named database connections, remember the selected connection for each file, and keep transactions open across query executions. Integrates with [vim-dadbod](https://github.com/tpope/vim-dadbod) and [vim-dadbod-completion](https://github.com/kristijanhusak/vim-dadbod-completion) for smart SQL completion suggestions.

See `:help pgquery` for the complete reference.

## Installation

Install the repository with your plugin manager, or as a native Vim package:

```sh
git clone https://github.com/your-user/vim-pgquery.git \
  ~/.vim/pack/plugins/start/vim-pgquery
vim -u NONE -c 'helptags ~/.vim/pack/plugins/start/vim-pgquery/doc' -c quit
```

### Requirements

- Vim 8 or Vim 9 with JSON support and `+job` for `:DBExecute`.
- Vim's `+terminal` feature for `:DBTerminal`.
- PostgreSQL's `psql` client installed and available in `PATH`.
- Optional: `vim-dadbod` and `vim-dadbod-completion` for SQL completion.

## Commands

| Command | Description |
| --- | --- |
| `:DBNew` | Save and select a new named connection. |
| `:DBConnect` | Select a saved connection for the current file. |
| `:DBCurrent` | Show the current connection URL |
| `:DBEdit [name]` | Edit a saved connection's name and URL. |
| `:DBDelete [name]` | Delete a saved connection after confirmation. |
| `:[range]DBExecute` | Run the current SQL block or selected lines asynchronously. |
| `:DBTerminal` | Open `psql` with the current connection in a terminal. |

The plugin deliberately installs no mappings. Optional examples:

```vim
nnoremap <silent> <leader>e :DBExecute<CR>
xnoremap <silent> <leader>e :DBExecute<CR>
```

## Transactions across executions

Run `BEGIN;` with `:DBExecute` to start a live transaction. Subsequent queries executed in the same buffer run within that transaction. Run `COMMIT;` the same way to save the changes, or `ROLLBACK;` to discard them.

## Status line

```vim
set statusline+=%{pgquery#statusline()}
```

`pgquery#statusline()` displays `[DB: name]` for the current buffer and nothing when it is disconnected; an open transaction adds a `TX` flag to it. It uses the saved connection name, and updates when you switch buffers, rename a connection, or delete one.

## Dadbod integration

For interoperability with `vim-dadbod` and `vim-dadbod-completion`, the selected URL is also exposed as buffer-local `b:db`. This makes an SQL `omnifunc` such as `vim_dadbod_completion#omni` use the same connection without creating a global database setting. If `vim-dadbod-completion` is loaded, pgquery connects and starts warming its completion cache as soon as an SQL buffer with a remembered connection is opened.

```vim
autocmd FileType sql setlocal omnifunc=vim_dadbod_completion#omni
```

## Credentials and security

Database URLs, including any embedded passwords, are stored as plaintext.  Mode `0600` restricts access to your Unix user, but processes running as you, root, and copies in backups can still expose those credentials.

Full URLs are also passed to `psql` as individual process arguments, which may be visible through process inspection depending on operating-system access restrictions. They are not interpolated into a shell command. `:DBCurrent` also displays the full URL, including passwords.

Prefer password-free URLs such as `postgresql://user@host/database` and put passwords in PostgreSQL's [`~/.pgpass` file](https://www.postgresql.org/docs/current/libpq-pgpass.html) with permissions set using `chmod 0600 ~/.pgpass`. This keeps passwords out of the plugin store and process arguments. `.pgpass` itself stores plaintext passwords, so protect it and its backups as well.

## Scope and alternatives
The goal of this plugin is to fulfill my personal needs: use plain Vim to maintain SQL queries and execute them. If you would rather have a full-fledged SQL client in Vim, consider using [vim-dadbod-ui](https://github.com/kristijanhusak/vim-dadbod-ui). Another good alternative is a TUI such as [lazysql](https://github.com/jorgerojas26/lazysql).

## License

Copyright (c) 2026 Augusto.

Licensed under the [GNU General Public License v3.0](LICENSE) (`GPL-3.0-only`).
