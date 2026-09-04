if exists('g:loaded_pgquery')
  finish
endif
let g:loaded_pgquery = 1

if !exists('g:pgquery_store_path')
  let g:pgquery_store_path = '~/.vim/pgquery.json'
endif

command! -nargs=0 DBNew call pgquery#new_prompt()
command! -nargs=0 DBConnect call pgquery#connect()
command! -nargs=? -complete=dir DBSetProject call pgquery#set_project(<q-args>)
command! -nargs=0 DBExecute call pgquery#execute()
command! -nargs=0 DBTerminal call pgquery#terminal()

augroup pgquery
  autocmd!
  autocmd BufReadPost,BufNewFile,BufEnter *.sql call pgquery#select_for_buffer()
  autocmd VimLeavePre * call pgquery#cleanup()
augroup END
