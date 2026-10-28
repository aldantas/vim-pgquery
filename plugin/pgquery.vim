if exists('g:loaded_pgquery')
  finish
endif
let g:loaded_pgquery = 1

if !exists('g:pgquery_store_path')
  let g:pgquery_store_path = '~/.vim/pgquery.json'
endif

command! -nargs=0 DBNew call pgquery#new_prompt()
command! -nargs=0 DBConnect call pgquery#connect()
command! -nargs=0 DBShowURL call pgquery#show_url()
command! -nargs=? -complete=customlist,pgquery#complete_connections DBEdit
      \ call pgquery#edit_prompt(<q-args>)
command! -nargs=? -complete=customlist,pgquery#complete_connections DBDelete
      \ call pgquery#delete_prompt(<q-args>)
command! -nargs=0 -range DBExecute
      \ call pgquery#execute(<range>, <line1>, <line2>)
command! -nargs=0 DBTerminal call pgquery#terminal()

augroup pgquery
  autocmd!
  autocmd BufReadPost,BufNewFile,BufEnter * call pgquery#select_for_buffer()
  autocmd VimLeavePre * call pgquery#cleanup()
augroup END
