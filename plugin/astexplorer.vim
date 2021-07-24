command! ASTExplore call s:ASTExplore()
command! ASTViewNode call s:ASTJumpToNode()

highlight AstNode guibg=blue ctermbg=blue

" TODO: move to syntax file
highlight AstNodeType guifg=blue ctermfg=blue
highlight AstNodeDescriptor guifg=green ctermfg=green
highlight AstNodeValue guifg=red ctermfg=red


""" --- Helpers --- {{{
function! s:EchoError(message) abort
  echohl WarningMsg
  echo a:message
  echohl None
endfunction
"""}}}


""" --- AST Manipulation --- {{{
let s:node_identifier = 0

function! s:BuildTree(node, tree, parent_id, descriptor) abort
  if type(a:node) == v:t_dict
    if has_key(a:node, 'type') && type(a:node.type) == v:t_string && has_key(a:node, 'loc')
      let current_node_id = s:node_identifier
      if !has_key(a:tree, a:parent_id)
        let a:tree[a:parent_id] = []
      endif
      let node_info = { 'type': a:node.type, 'loc': a:node.loc, 'id': current_node_id,
            \ 'descriptor': a:descriptor, 'extra': {} }
      let insertion_index = 0
      for sibling in a:tree[a:parent_id]
        if sibling.loc.start.line > node_info.loc.start.line ||
              \ sibling.loc.start.line == node_info.loc.start.line &&
              \ sibling.loc.start.column > node_info.loc.start.column
          break
        endif
        let insertion_index += 1
      endfor
      call insert(a:tree[a:parent_id], node_info, insertion_index)
      if has_key(a:node, 'value') && type(a:node.value) != v:t_dict
        let node_info.value = json_encode(a:node.value)
      elseif has_key(a:node, 'name') && type(a:node.name) == v:t_string
        let node_info.value = a:node.name
      elseif has_key(a:node, 'operator') && type(a:node.operator) == v:t_string
        let node_info.value = a:node.operator
      endif
      for [key, value] in items(a:node)
        if key !=# 'type' && key !=# 'loc' && key !=# 'value' && key !=# 'operator' && key !=# 'name' &&
              \ (type(value) != v:t_dict || !has_key(value, 'loc')) && type(value) != v:t_list
          let node_info.extra[key] = value
        endif
      endfor
      let s:node_identifier += 1
      for [key, node] in items(a:node)
        call s:BuildTree(node, a:tree, current_node_id, key)
      endfor
    endif
  elseif type(a:node) == v:t_list
    for node in a:node
      call s:BuildTree(node, a:tree, a:parent_id, a:descriptor)
    endfor
  endif
endfunction

function! s:BuildOutputList(list, node_id, tree, depth) abort
  if !has_key(a:tree, a:node_id)
    return
  endif
  for node in a:tree[a:node_id]
    let indent = repeat(' ', a:depth)
    call add(a:list, [indent
          \ . (!empty(node.descriptor) ? node.descriptor . ': ' : '')
          \ . node.type
          \ . (has_key(node, 'value') ? ' - ' . node.value : '  ')
          \ , node.loc, json_encode(node.extra)])
    call s:BuildOutputList(a:list, node.id, a:tree, a:depth + 1)
  endfor
endfunction
"""}}}


""" --- Source Window Functions --- {{{
function! s:AddMatch(match) abort
  call add(b:ast_explorer_match_list, matchaddpos('AstNode', [a:match]))
endfunction

function! s:AddMatches(locinfo) abort
  if !exists('b:ast_explorer_match_list')
    let b:ast_explorer_match_list = []
  endif
  let start = a:locinfo.start
  let end = a:locinfo.end
  if start.line == end.line
    call s:AddMatch([start.line, start.column + 1, end.column - start.column])
    return
  endif
  call s:AddMatch([start.line, start.column + 1, len(getline(start.line)) - start.column])
  for line in range(start.line + 1, end.line - 1)
    call s:AddMatch(line)
  endfor
  call s:AddMatch([end.line, 1, end.column])
endfunction

function! s:DeleteMatches() abort
  if !exists('b:ast_explorer_match_list')
    return
  endif
  for match_id in b:ast_explorer_match_list
    try
      call matchdelete(match_id)
    catch /E803/
      " ignore matches that were already cleared
    endtry
  endfor
  let b:ast_explorer_match_list = []
endfunction

function! s:CurrentWindowAstShown() abort
  let ast_explorer_window_id = get(t:, 'ast_explorer_window_id')
  return ast_explorer_window_id &&
        \ getbufvar(winbufnr(ast_explorer_window_id), 'ast_explorer_source_window') == win_getid()
endfunction

function! s:DeleteMatchesIfAstExplorerGone() abort
  if !s:CurrentWindowAstShown()
    call s:DeleteMatches()
    augroup ast_source
      autocmd! * <buffer>
    augroup END
  endif
endfunction

function! s:OpenAstExplorerWindow(ast, source_window_id, available_parsers, current_parser) abort
  execute 'silent keepalt botright 60vsplit ASTExplorer' . tabpagenr()
  let b:ast_explorer_node_list = []
  let b:ast_explorer_source_window = a:source_window_id
  let b:ast_explorer_available_parsers = a:available_parsers
  let b:ast_explorer_current_parser = a:current_parser
  let t:ast_explorer_window_id = win_getid()

  let tree = {}
  call s:BuildTree(a:ast, tree, 'root', '')
  call s:BuildOutputList(b:ast_explorer_node_list, 'root', tree, 0)

  let buffer_line_list = []
  for [buffer_line; _] in b:ast_explorer_node_list
    call add(buffer_line_list, buffer_line)
  endfor
  call s:DrawAst(buffer_line_list)
  unlet! b:ast_explorer_previous_cursor_line
  call s:HighlightNodeForCurrentLine()

  " TODO: move to syntax file
  syntax region AstNodeDescriptor start="^" end=":"me=e-1
  syntax region AstNodeValue start="- "ms=s+1 end="$"
  syntax region AstNodeType start=": "ms=s+2 end=" -\|$"me=e-2

  augroup ast
    autocmd! * <buffer>
    autocmd CursorMoved <buffer> call s:HighlightNodeForCurrentLine()
    autocmd BufEnter <buffer> call s:CloseTabIfOnlyContainsExplorer()
  augroup END
  nnoremap <silent> <buffer> l :echo <SID>GetNodeInfoForCurrentLine()[1]<CR>
  nnoremap <silent> <buffer> i :echo <SID>GetNodeInfoForCurrentLine()[2]<CR>
  nnoremap <silent> <buffer> p :echo b:ast_explorer_available_parsers<CR>
  nnoremap <silent> <buffer> s :call <SID>SwitchParsers()<CR>
endfunction
"""}}}


""" --- AST Explorer Window Functions --- {{{
function! s:HighlightNode(locinfo) abort
  if !exists('b:ast_explorer_previous_cursor_line')
    let b:ast_explorer_previous_cursor_line = 0
  endif
  let current_cursor_line = line('.')
  if current_cursor_line == b:ast_explorer_previous_cursor_line
    return
  endif
  let b:ast_explorer_previous_cursor_line = current_cursor_line
  if !win_gotoid(b:ast_explorer_source_window)
    call s:EchoError('Source window is gone!')
    return
  endif
  call s:DeleteMatches()
  call s:AddMatches(a:locinfo)
  execute printf('normal! %dG%d|', a:locinfo.start.line, a:locinfo.start.column + 1)
  call win_gotoid(t:ast_explorer_window_id)
endfunction

function! s:GetNodeInfoForCurrentLine() abort
  return b:ast_explorer_node_list[line('.') - 1]
endfunction

function! s:HighlightNodeForCurrentLine() abort
  call s:HighlightNode(s:GetNodeInfoForCurrentLine()[1])
endfunction

function! AstExplorerCurrentParserName() abort
  return b:ast_explorer_current_parser
endfunction

function! s:DrawAst(buffer_line_list) abort
  setlocal modifiable
  setlocal noreadonly
  call setline(1, a:buffer_line_list)
  setlocal nomodifiable
  setlocal readonly
  setlocal nobuflisted
  setlocal buftype=nofile
  setlocal noswapfile
  setlocal cursorline
  setlocal foldmethod=indent
  setlocal shiftwidth=1
  setlocal filetype=ast
  setlocal statusline=ASTExplorer\ [%{AstExplorerCurrentParserName()}]
  setlocal nonumber
  if &colorcolumn
    setlocal colorcolumn=
  endif
  setlocal winfixwidth
  setlocal bufhidden=delete
  setlocal nowrap
endfunction

function! s:CloseTabIfOnlyContainsExplorer() abort
  if len(gettabinfo(tabpagenr())[0].windows) == 1
    quit
  endif
endfunction

function! s:SwitchParsers() abort
  let parser_names = keys(b:ast_explorer_available_parsers)
  if len(parser_names) == 1
    echo 'No other parsers available'
    return
  endif
  let prompt = 'Choose new parser: '
  let choice_value = 1
  for parser_name in parser_names
    let prompt = prompt . '(' . choice_value . ') ' . parser_name . '; '
    let choice_value += 1
  endfor
  let choice = input(prompt)
  if choice < 1 || choice > len(parser_names)
    call s:EchoError('Invalid choice "' . choice . '"')
    return
  endif
  let new_parser = get(parser_names, choice - 1)
  let filetype = b:ast_explorer_available_parsers[new_parser].filetype
  " This won't necessarily do the switch if there are parsers loaded for multiple filetypes
  let s:supported_parsers[filetype].default = new_parser
  call s:CloseAstExplorerWindow()
  ASTExplore
  echo 'Now using "' . new_parser . '".'
endfunction
"""}}}


""" --- Functions for any context --- {{{
function! s:GoToAstExplorerWindow() abort
  let ast_explorer_window_id = get(t:, 'ast_explorer_window_id')
  let ast_explorer_window_number = win_id2win(ast_explorer_window_id)
  if ast_explorer_window_number
    call win_gotoid(ast_explorer_window_id)
  endif
  return ast_explorer_window_number
endfunction

function! s:CloseAstExplorerWindow() abort
  if s:GoToAstExplorerWindow()
    let old_source_window_id = win_id2win(b:ast_explorer_source_window)
    quit
    if old_source_window_id
      execute old_source_window_id . 'windo call s:DeleteMatches()'
    endif
  endif
endfunction

function! s:InsideAstExplorerWindow() abort
  return exists('b:ast_explorer_source_window')
endfunction

let s:supported_parsers = {
      \   'javascript': {
      \     'default': '@babel/parser',
      \     'executables': {
      \       '@babel/parser': {
      \         'test': 'node_modules/.bin/parser',
      \         'command': ['node_modules/.bin/parser']
      \       },
      \       'babylon': {
      \         'test': 'node_modules/.bin/babylon',
      \         'command': ['node_modules/.bin/babylon']
      \       },
      \       'esprima': {
      \         'test': 'node_modules/.bin/esparse',
      \         'command': ['node_modules/.bin/esparse', '--loc']
      \       },
      \       'acorn': {
      \         'test': 'acorn',
      \         'command': ['acorn', '--locations', '--ecma2018']
      \       },
      \     }
      \   },
      \   'json': {
      \     'default': 'json-to-ast',
      \     'executables': {
      \       'json-to-ast': {
      \        'test': 'node_modules/json-to-ast',
      \         'command': ['node', '-e', "\"const lines = []; require('readline').createInterface({ input: process.stdin }).on('line', line => { lines.push(line) }).on('close', () => { console.log(JSON.stringify(require('json-to-ast')(lines.join('\\n')))) })\"", '<']
      \       }
      \     }
      \   },
      \ }

function! s:ASTExplore() abort
  if s:InsideAstExplorerWindow()
    call s:CloseAstExplorerWindow()
    return
  endif

  let current_source_window_id = win_getid()

  if s:GoToAstExplorerWindow()
    let old_source_window_id = b:ast_explorer_source_window
    call s:CloseAstExplorerWindow()
    if old_source_window_id == current_source_window_id
      return
    else
      call win_gotoid(current_source_window_id)
    endif
  endif

  let filetypes = split(&filetype, '\.')

  let available_parsers = {}
  let supported_parsers_for_filetypes = []
  let default_parsers_for_filetypes = []
  for filetype in filetypes
    let filetype_parsers = get(s:supported_parsers, filetype, {})
    if empty(filetype_parsers)
      continue
    endif
    call add(default_parsers_for_filetypes, filetype_parsers.default)
    for [parser_name, details] in items(filetype_parsers.executables)
      if empty(findfile(details.test, ';')) &&
            \ empty(finddir(details.test, ';')) &&
            \ !executable(details.test)
        continue
      endif
      let [parser_executable; flags] = details.command
      let executable_file = findfile(parser_executable, ';')
      if empty(executable_file)
        let executable_file = exepath(parser_executable)
      endif
      if executable(executable_file)
        call add(supported_parsers_for_filetypes, parser_name)
        let available_parsers[parser_name] = {
              \ 'command': fnamemodify(executable_file, ':p') . ' ' . join(flags),
              \ 'filetype': filetype,
              \ }
      endif
    endfor
  endfor

  if empty(supported_parsers_for_filetypes)
    call s:EchoError('No supported parsers for filetype "' . &filetype . '".')
    return
  endif

  if empty(available_parsers)
    call s:EchoError('No supported parsers found for filetype "' . &filetype . '". '
          \ . 'Install one of [' . join(supported_parsers_for_filetypes, ', ') . '].')
    return
  endif

  let current_parser = ''
  for default_parser in default_parsers_for_filetypes
    if has_key(available_parsers, default_parser)
      let current_parser = default_parser
    endif
  endfor
  if empty(current_parser)
    let current_parser = keys(available_parsers)[0]
  endif

  augroup ast_source
    autocmd! * <buffer>
    autocmd BufEnter <buffer> call s:DeleteMatchesIfAstExplorerGone()
  augroup END

  if &modified
    if !exists('g:ast_explorer_tempfile_path')
      let g:ast_explorer_tempfile_path = tempname()
    endif
    let filepath = g:ast_explorer_tempfile_path
    execute 'silent keepalt write! ' . filepath
    execute 'bwipeout ' . bufnr('$')
  else
    let filepath = expand('%')
  endif

  let ast_json = system(available_parsers[current_parser].command . ' ' . filepath)
  let ast_dict = json_decode(ast_json)

  call s:OpenAstExplorerWindow(ast_dict, current_source_window_id, available_parsers, current_parser)
endfunction

function! s:ASTJumpToNode() abort
  if s:InsideAstExplorerWindow()
    return
  endif
  let cursor_line = line('.')
  let cursor_column = col('.') - 1
  if !s:CurrentWindowAstShown()
    ASTExplore
  endif
  call s:GoToAstExplorerWindow()
  let buffer_line = 1
  let jump_node_buffer_line = 1
  for [_, locinfo; _] in b:ast_explorer_node_list
    if locinfo.start.line > cursor_line
      break
    endif
    let start = locinfo.start
    let end = locinfo.end
    if start.line == cursor_line && cursor_column >= start.column &&
          \ (cursor_line < end.line || cursor_line == end.line && cursor_column < end.column) ||
          \ start.line < cursor_line && cursor_line < end.line ||
          \ end.line == cursor_line && cursor_column < end.column &&
          \ (cursor_line > start.line || cursor_line == start.line && cursor_column >= start.column)
      let jump_node_buffer_line = buffer_line
    endif
    let buffer_line += 1
  endfor
  execute 'normal! zR' . jump_node_buffer_line . 'Gzz'
endfunction
"""}}}
