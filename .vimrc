set scrolloff=6
set number
set relativenumber
set tabstop=4
set shiftwidth=4
set softtabstop=4
set expandtab
" set smartindent

set hidden

set encoding=utf-8

set nobackup
set nowritebackup

set updatetime=200

set signcolumn=yes

set clipboard=unnamed

set termguicolors

let g:netrw_browse_split = 2

" Install vim-plug if not found
if empty(glob('~/.vim/autoload/plug.vim'))
  silent !curl -fLo ~/.vim/autoload/plug.vim --create-dirs
    \ https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
  autocmd VimEnter * PlugInstall --sync | source $MYVIMRC
endif

call plug#begin()

" List your plugins here
" Plug 'tpope/vim-sensible'
Plug 'morhetz/gruvbox'
Plug 'christoomey/vim-tmux-navigator'
Plug 'hashivim/vim-terraform'
Plug 'dense-analysis/ale'
Plug 'tpope/vim-fugitive'

call plug#end()

" These two options set automatically by vim-plug after plug#end() :
" syntax on
" filetype plugin indent on

let g:gruvbox_contrast_light = 'soft'
silent! colorscheme gruvbox

" Tmux/Vim pane navigation
nnoremap <silent> <C-h> :TmuxNavigateLeft<cr>
nnoremap <silent> <C-j> :TmuxNavigateDown<cr>
nnoremap <silent> <C-k> :TmuxNavigateUp<cr>
nnoremap <silent> <C-l> :TmuxNavigateRight<cr>

" Optional fallback if plugin is not loaded
nnoremap <silent> <C-\> <C-w>w

" Enable ALE
let g:ale_enabled = 1
let g:ale_completion_enabled = 1 

" Use ALE for omni-completion
set omnifunc=ale#completion#OmniFunc

" Ale linters config
let g:ale_linters = {
\ 'terraform': ['tflint', 'terraform_ls'],
\ 'tf': ['tflint', 'terraform_ls'],
\}
  " This could be above:
  " 'sh': ['bash-language-server', 'shellcheck'],

" Add custom LSP command for ALE
let g:ale_custom_lsp = {
\ 'terraform-ls': {
\ 'command': 'terraform-ls serve',
\ 'filetypes': ['terraform', 'tf'],
\},
\}

  " This could be in above:
  "  'bash-language-server': {
  "  'command': 'bash-language-server start',
  "  'filetypes': ['sh'],
  "  },
