" Utilities {{{

function! flog#instance() abort
  let l:instance = g:flog_instance_counter
  let g:flog_instance_counter += 1
  return l:instance
endfunction

function! flog#get_all_window_ids() abort
  let l:tabs = gettabinfo()
  let l:windows = []
  for l:tab in l:tabs
    let l:windows += l:tab.windows
  endfor
  return l:windows
endfunction

function! flog#exclude(list, filters) abort
  return filter(a:list, 'index(a:filters, v:val) < 0')
endfunction

function! flog#ellipsize(string, ...) abort
  let l:max_len = a:0 >= 1 ? min(a:1, 4) : 15
  let l:dir = a:0 >= 2 ? a:2 : 0

  if len(a:string) > l:max_len
    if l:dir == 0
      return a:string[: l:max_len - 4] . '...'
    else
      return '...' . a:string[l:max_len - 3 :]
    endif
  else
    return a:string
  endif
endfunction

function! flog#unescape_arg(arg) abort
  " remove trailing backslashes to prevent evaluation errors
  let l:arg = substitute(a:arg, '\\*$', '', '')
  try
    " unescape spaces to deal with argument interpolation
    let l:arg = substitute(l:arg, '\\ ', ' ', '')
  catch /E114:/
    " invalid trailing escape sequence
    return []
  endtry
  return l:arg
endfunction

function! flog#resolve_path(path, relative_dir) abort
  let l:full_path = fnamemodify(a:path, ':p')
  if stridx(l:full_path, a:relative_dir) == 0
    return l:full_path[len(a:relative_dir) + 1:]
  endif
  return a:path
endfunction

function! flog#split_limit(limit) abort
  let [l:match, l:start, l:end] = matchstrpos(a:limit, '^.\{1}:\zs')
  if l:start < 0
    return [a:limit, '']
  endif
  return [a:limit[: l:start - 1], a:limit[l:start :]]
endfunction

" }}}

" Shell interface {{{

function! flog#systemlist(command) abort
  let l:output = systemlist(a:command)
  if v:shell_error
    echoerr join(l:output, "\n")
    throw g:flog_shell_error
  endif
  return l:output
endfunction

" }}}

" Fugitive interface {{{

function! flog#is_fugitive_buffer() abort
  try
    call fugitive#repo()
  catch /not a Git repository/
    return v:false
  endtry
  return v:true
endfunction

function! flog#resolve_fugitive_path_arg(path) abort
  return flog#resolve_path(a:path, fugitive#repo().tree())
endfunction

function! flog#get_initial_fugitive_repo() abort
  return fugitive#repo()
endfunction

function! flog#get_fugitive_workdir() abort
  let l:tree = flog#get_state().fugitive_repo.tree()
  return l:tree
endfunction

function! flog#get_fugitive_git_command() abort
  let l:git_command = flog#get_state().fugitive_repo.git_command()
  return l:git_command
endfunction

function! flog#trigger_fugitive_git_detection() abort
  let b:git_dir = flog#get_state().fugitive_repo.dir()
  let l:workdir = flog#get_fugitive_workdir()
  call FugitiveDetect(l:workdir)
endfunction

" }}}

" Argument handling {{{

" Argument parsing {{{

function! flog#get_internal_default_args() abort
  let l:defaults = {
        \ 'raw_args': v:null,
        \ 'format': '%Cblue%ad%Creset %C(yellow)[%h]%Creset %Cgreen{%an}%Creset%Cred%d%Creset %s',
        \ 'date': 'iso8601',
        \ 'all': v:false,
        \ 'bisect': v:false,
        \ 'no_merges': v:false,
        \ 'reflog': v:false,
        \ 'skip': v:null,
        \ 'max_count': v:null,
        \ 'open_cmd': 'tabedit',
        \ 'search': v:null,
        \ 'patch_search': v:null,
        \ 'limit': v:null,
        \ 'rev': [],
        \ 'path': []
        \ }

  " read the user immutable defaults
  if exists('g:flog_permanent_default_arguments')
    for [l:key, l:value] in items(g:flog_permanent_default_arguments)
      if has_key(l:defaults, l:key)
        let l:defaults[l:key] = l:value
      else
        echoerr 'Warning: unrecognized immutable argument ' . l:key
      endif
    endfor
  endif

  return l:defaults
endfunction

function! flog#get_default_args() abort
  if !g:flog_has_shown_deprecated_default_argument_vars_warning
        \ && (exists('g:flog_default_format') || exists('g:flog_default_date_format'))
    echoerr 'Warning: the options g:flog_default_format and g:flog_default_date_format are deprecated'
    echoerr 'Please use g:flog_default_arguments or g:flog_permanent_default_arguments to set any defaults'
  endif

  let l:defaults = flog#get_internal_default_args()

  " read the user argument defaults
  if exists('g:flog_default_arguments')
    for [l:key, l:value] in items(g:flog_default_arguments)
      if has_key(l:defaults, l:key)
        let l:defaults[l:key] = l:value
      else
        echoerr 'Warning: unrecognized default argument ' . l:key
      endif
    endfor
  endif

  return l:defaults
endfunction

function! flog#parse_arg_opt(arg) abort
  let l:opt = matchstr(a:arg, '=\zs.*')
  return l:opt
endfunction

function! flog#parse_limit_opt(arg) abort
  let l:arg = flog#parse_arg_opt(a:arg)
  let [l:limit, l:path] = flog#split_limit(l:arg)
  if l:path ==# ''
    return l:arg
  endif
  return l:limit . fnameescape(flog#resolve_fugitive_path_arg(l:path))
endfunction

function! flog#parse_path_opt(arg) abort
  return [fnameescape(flog#resolve_fugitive_path_arg(expand(flog#parse_arg_opt(a:arg))))]
endfunction

function! flog#parse_set_args(args, current_args, defaults) abort
  let l:has_set_path = v:false

  let l:has_set_rev = v:false

  let l:has_set_raw_args = v:false
  let l:got_raw_args_token = v:false
  let l:raw_args = []

  for l:arg in a:args
    if l:got_raw_args_token
      let l:has_set_raw_args = v:true
      let l:raw_args += [l:arg]
    elseif l:arg ==# '--'
      let l:got_raw_args_token = v:true
    elseif l:arg =~# '^-format=.\+'
      let a:current_args.format = flog#parse_arg_opt(l:arg)
    elseif l:arg ==# '-format='
      let a:current_args.format = a:defaults.format
    elseif l:arg =~# '^-date=.\+'
      let a:current_args.date = flog#parse_arg_opt(l:arg)
    elseif l:arg ==# '-date='
      let a:current_args.date = a:defaults.date
    elseif l:arg =~# '^-raw-args=.\+'
      let l:has_set_raw_args = v:true
      let l:raw_args += [flog#parse_arg_opt(l:arg)]
    elseif l:arg ==# '-raw-args='
      let l:has_set_raw_args = v:false
      let a:current_args.raw_args = a:defaults.raw_args
    elseif l:arg ==# '-all'
      let a:current_args.all = v:true
    elseif l:arg ==# '-bisect'
      let a:current_args.bisect = v:true
    elseif l:arg ==# '-no-merges'
      let a:current_args.no_merges = v:true
    elseif l:arg ==# '-reflog'
      let a:current_args.reflog = v:true
    elseif l:arg ==# '-reflog'
      let a:current_args.reflog = v:true
    elseif l:arg =~# '^-skip=\d\+'
      let a:current_args.skip = flog#parse_arg_opt(l:arg)
    elseif l:arg ==# '-skip='
      let a:current_args.skip = a:defaults.skip
    elseif l:arg =~# '^-max-count=\d\+'
      let a:current_args.max_count = flog#parse_arg_opt(l:arg)
    elseif l:arg ==# '-max-count='
      let a:current_args.max_count = a:defaults.max_count
    elseif l:arg =~# '^-open-cmd=.\+'
      let a:current_args.open_cmd = flog#parse_arg_opt(l:arg)
    elseif l:arg ==# '-open-cmd='
      let a:current_args.open_cmd = a:defaults.open_cmd
    elseif l:arg =~# '^-search=.\+'
      let a:current_args.search = flog#parse_arg_opt(l:arg)
    elseif l:arg ==# '-search='
      let a:current_args.search = a:defaults.search
    elseif l:arg =~# '^-patch-search=.\+'
      let a:current_args.patch_search = flog#parse_arg_opt(l:arg)
    elseif l:arg ==# '-patch-search='
      let a:current_args.patch_search = a:defaults.patch_search
    elseif l:arg =~# '^-limit=.\+'
      let a:current_args.limit = flog#parse_limit_opt(l:arg)
    elseif l:arg ==# '-limit='
      let a:current_args.limit = a:defaults.limit
    elseif l:arg =~# '^-rev=.\+'
      if !l:has_set_rev
        let a:current_args.rev = []
        let l:has_set_rev = v:true
      endif
      let a:current_args.rev += [flog#parse_arg_opt(l:arg)]
    elseif l:arg ==# '-rev='
      let l:has_set_rev = v:false
      let a:current_args.rev = a:defaults.rev
    elseif l:arg =~# '^-path=.\+'
      if !l:has_set_path
        let a:current_args.path = []
        let l:has_set_path = v:true
      endif
      let a:current_args.path += flog#parse_path_opt(l:arg)
    elseif l:arg ==# '-path='
      let a:current_args.path = a:defaults.path
      let l:has_set_path = v:false
    else
      echoerr 'error parsing argument ' . l:arg
      throw g:flog_unsupported_argument
    endif
  endfor

  if l:has_set_raw_args
    let a:current_args.raw_args = join(l:raw_args, ' ')
  endif

  return a:current_args
endfunction

function! flog#parse_args(args) abort
  return flog#parse_set_args(a:args, flog#get_default_args(), flog#get_internal_default_args())
endfunction

" }}}

" Argument completion {{{

function! flog#filter_completions(arg_lead, completions) abort
  let l:lead = escape(a:arg_lead, '\\')
  return filter(a:completions, 'v:val =~# "^" . l:lead')
endfunction

function! flog#escape_completions(lead, completions) abort
  return map(a:completions, "a:lead . substitute(v:val, ' ', '\\\\ ', '')")
endfunction

function! flog#split_single_completable_arg(arg) abort
  let l:start_pattern = '^\([^=]*=\)\?'
  let l:start = matchstr(a:arg, l:start_pattern)
  let l:rest = matchstr(a:arg, l:start_pattern . '\zs.*')

  return [l:start, l:rest]
endfunction

function! flog#split_completable_arg(arg) abort
  let [l:start, l:rest ] = flog#split_single_completable_arg(a:arg)

  let l:split = split(l:rest, '\\ ', v:true)

  let l:trimmed = l:split[:-2]

  if l:split != []
    let l:last = l:split[-1]
  else
    let l:last = ''
  endif

  let l:lead = l:start . join(l:trimmed, '\ ')
  if len(l:trimmed) > 0
    let l:lead .= '\ '
  endif

  return [l:lead, l:last]
endfunction

function! flog#complete_line(arg_lead, cmd_line, cursor_pos) abort
  let l:line = line('.')
  let l:firstline = line("'<")
  let l:lastline = line("'>")

  if (l:line != l:firstline && l:line != l:lastline) || l:firstline == l:lastline
    " complete for only the current line
    let l:commit = flog#get_commit_at_current_line()
    if type(l:commit) != v:t_dict
      return []
    endif
    let l:completions = [l:commit.short_commit_hash] + l:commit.ref_name_list
  else
    " complete for a range
    let l:commit = flog#get_commit_at_line(l:firstline, l:lastline)
    if type(l:commit) != v:t_list
      return []
    endif
    let l:first_commit = l:commit[0]
    let l:last_commit = l:commit[1]
    let l:first_hash = l:first_commit.short_commit_hash
    let l:last_hash = l:last_commit.short_commit_hash
    let l:completions = [l:first_hash, l:last_hash]
          \ + l:first_commit.ref_name_list + l:last_commit.ref_name_list
          \ + [
            \ l:last_hash . '..' . l:first_hash,
            \ l:last_hash . '^..' . l:first_hash
          \ ]
  endif

  return flog#filter_completions(a:arg_lead, l:completions)
endfunction

function! flog#complete_git(arg_lead, cmd_line, cursor_pos) abort
  let l:state = flog#get_state()

  let l:split_args = split(a:cmd_line, '\s', v:true)
  let l:current_arg_num = len(l:split_args)
  if l:current_arg_num <= 2
    return flog#filter_completions(a:arg_lead, copy(g:flog_git_commands))
  endif
  let l:command = l:split_args[1]

  let l:completions = flog#complete_line(a:arg_lead, a:cmd_line, a:cursor_pos)
  if l:state.limit
    let [l:limit, l:limit_path] = flog#split_limit(l:state.limit)
    let l:completions += [l:limit_path]
  endif
  let l:completions += flog#exclude(l:state.path, l:completions)
  let l:completions += flog#exclude(getcompletion(a:arg_lead, 'file'), l:completions)
  if l:current_arg_num == 3 && has_key(g:flog_git_subcommands, l:command)
    let l:completions += flog#filter_completions(a:arg_lead, copy(g:flog_git_subcommands[l:command]))
  endif

  return l:completions
endfunction

function! flog#complete_refs(arg_lead, cmd_line, cursor_pos) abort
  let l:state = flog#get_state()
  return flog#filter_completions(a:arg_lead, copy(l:state.all_refs))
endfunction

function! flog#complete_format(arg_lead) abort
  " build patterns
  let l:completable_pattern = g:flog_eat_specifier_pattern
        \ . '\zs%' . g:flog_completable_specifier_pattern . '\?$'
  let l:noncompletable_pattern = g:flog_eat_specifier_pattern
        \ . '\zs%' . g:flog_noncompletable_specifier_pattern . '$'

  " test the arg lead
  if a:arg_lead =~# l:noncompletable_pattern
    " format ends with an incompletable pattern
    return []
  elseif a:arg_lead =~# l:completable_pattern
    " format ends with a completable pattern
    let l:lead = substitute(a:arg_lead, l:completable_pattern, '', '')
    let l:completions = map(copy(g:flog_completion_specifiers), 'l:lead . v:val')
    return flog#filter_completions(a:arg_lead, copy(l:completions))
  else
    " format does not end with any special atom
    return [a:arg_lead . '%']
  endif
endfunction

function! flog#complete_date(arg_lead) abort
  let [l:lead, l:path] = flog#split_single_completable_arg(a:arg_lead)
  let l:completions = map(copy(g:flog_date_formats), 'l:lead . v:val')
  return flog#filter_completions(a:arg_lead, l:completions)
endfunction

function! flog#complete_open_cmd(arg_lead) abort
  " get the lead without the last command
  let [l:lead, l:last] = flog#split_completable_arg(a:arg_lead)

  " build the list of possible completions
  let l:completions = []
  let l:completions += map(copy(g:flog_open_cmd_modifiers), 'l:lead . v:val')
  let l:completions += map(copy(g:flog_open_cmds), 'l:lead . v:val')

  return flog#filter_completions(a:arg_lead, l:completions)
endfunction

function! flog#complete_limit(arg_lead) abort
  let [l:lead, l:last] = flog#split_completable_arg(a:arg_lead)

  let [l:limit, l:path] = flog#split_limit(l:last)
  if l:limit !~# '^.\{1}:$'
    return []
  endif

  let l:files = getcompletion(flog#unescape_arg(l:path), 'file')
  let l:completions = flog#escape_completions(l:lead . l:limit, l:files)

  return flog#filter_completions(a:arg_lead, l:completions)
endfunction

function! flog#complete_rev(arg_lead) abort
  if !flog#is_fugitive_buffer()
    return []
  endif
  let [l:lead, l:last] = flog#split_single_completable_arg(a:arg_lead)
  let l:cmd = fugitive#repo().git_command()
        \ . ' rev-parse --symbolic --branches --tags --remotes'
  let l:revs = flog#systemlist(l:cmd) +  ['HEAD', 'FETCH_HEAD', 'MERGE_HEAD', 'ORIG_HEAD']
  return flog#filter_completions(a:arg_lead, map(l:revs, 'l:lead . v:val'))
endfunction

function! flog#complete_path(arg_lead) abort
  let [l:lead, l:path] = flog#split_single_completable_arg(a:arg_lead)

  let l:files = getcompletion(flog#unescape_arg(l:path), 'file')
  let l:completions = flog#escape_completions(l:lead, l:files)

  return flog#filter_completions(a:arg_lead, l:completions)
endfunction

function! flog#complete(arg_lead, cmd_line, cursor_pos) abort
  if a:cmd_line[:a:cursor_pos] =~# ' -- '
    return []
  endif

  if a:arg_lead ==# ''
    return flog#filter_completions(a:arg_lead, copy(g:flog_default_completion))
  elseif a:arg_lead =~# '^-format='
    return flog#complete_format(a:arg_lead)
  elseif a:arg_lead =~# '^-date='
    return flog#complete_date(a:arg_lead)
  elseif a:arg_lead =~# '^-open-cmd='
    return flog#complete_open_cmd(a:arg_lead)
  elseif a:arg_lead =~# '^-\(patch-\)\?search='
    return []
  elseif a:arg_lead =~# '^-limit='
    return flog#complete_limit(a:arg_lead)
  elseif a:arg_lead =~# '^-rev='
    return flog#complete_rev(a:arg_lead)
  elseif a:arg_lead =~# '^-path='
    return flog#complete_path(a:arg_lead)
  endif
  return flog#filter_completions(a:arg_lead, copy(g:flog_default_completion))
endfunction

" }}}

" }}}

" State management {{{

function! flog#get_initial_state(parsed_args, original_file) abort
  return extend(copy(a:parsed_args), {
        \ 'instance': flog#instance(),
        \ 'fugitive_repo': flog#get_initial_fugitive_repo(),
        \ 'original_file': a:original_file,
        \ 'graph_window_id': v:null,
        \ 'preview_window_ids': [],
        \ 'previous_log_command': v:null,
        \ 'line_commits': [],
        \ 'all_refs': [],
        \ 'commit_refs': [],
        \ 'line_commit_refs': [],
        \ 'ref_line_lookup': {},
        \ 'ansi_esc_called': v:false,
        \ })
endfunction

function! flog#set_buffer_state(state) abort
  let b:flog_state = a:state
endfunction

function! flog#get_state() abort
  if !exists('b:flog_state')
    throw g:flog_missing_state
  endif
  return b:flog_state
endfunction

" }}}

" Log command management {{{

function! flog#create_log_format() abort
  let l:state = flog#get_state()

  " start format
  let l:format = 'format:'
  let l:format .= g:flog_format_start

  " add data specifiers
  let l:tokens = []
  for l:specifier in g:flog_log_data_format_specifiers
    let l:tokens += [g:flog_format_specifiers[l:specifier]]
  endfor
  let l:format .= join(l:tokens, g:flog_format_separator)

  " add display specifiers
  let l:format .= g:flog_format_separator . g:flog_display_commit_start
  let l:format .= l:state.format
  let l:format .= g:flog_display_commit_end

  " end format
  let l:format .= g:flog_format_end
  " perform string formatting to avoid shell interpolation
  return shellescape(l:format)
endfunction

function! flog#parse_log_commit(c) abort
  let l:i = stridx(a:c, g:flog_format_start)
  if l:i < 0
    return {}
  endif
  let l:j = stridx(a:c, g:flog_display_commit_start)
  let l:k = stridx(a:c, g:flog_display_commit_end)
  let l:l = stridx(a:c, g:flog_format_end)

  let l:dat = split(a:c[l:i + len(g:flog_format_start) : l:j - 1], g:flog_format_separator, v:true)

  let l:c = {}

  let l:c.short_commit_hash = l:dat[g:flog_log_data_hash_index]
  let l:c.ref_names_unwrapped = l:dat[g:flog_log_data_ref_index]
  let l:c.internal_data = l:dat

  let l:c.ref_name_list = split(l:c.ref_names_unwrapped, ' -> \|, \|tag: ')

  let l:end = a:c[l:l  + len(g:flog_format_end):]
  if l:end !=# '' && l:end[0] !=# "\n"
    let l:end = "\n" . l:end
  endif
  let l:c.display = split(
        \ a:c[0 : l:i - 1]
        \ . a:c[l:j + len(g:flog_display_commit_start) : l:k - 1]
        \ . l:end,
        \ "\n")

  return l:c
endfunction

function! flog#parse_log_output(output) abort
  let l:output_len = len(a:output)
  if l:output_len == 0
    return []
  endif

  let l:o = []
  let l:raw = []
  let l:i = 0

  " Group non-commit lines at the start of output with the first commit
  " See https://github.com/rbong/vim-flog/pull/14
  while l:i < l:output_len && a:output[l:i] !~# g:flog_format_start
    let l:raw += [a:output[l:i]]
    let l:i += 1
  endwhile
  if l:raw != []
    let l:raw += [a:output[l:i]]
    let l:i += 1
  endif

  while l:i < l:output_len
    let l:line = a:output[l:i]
    if l:line =~# g:flog_format_start && l:raw != []
      let l:o += [flog#parse_log_commit(join(l:raw, "\n"))]
      let l:raw = []
    endif
    let l:raw += [l:line]
    let l:i += 1
  endwhile

  if l:raw != []
      let l:o += [flog#parse_log_commit(join(l:raw, "\n"))]
  endif

  return l:o
endfunction

function! flog#build_log_paths() abort
  let l:state = flog#get_state()
  if len(l:state.path) == 0
    return ''
  endif
  let l:paths = map(l:state.path, 'fnamemodify(v:val, ":.")')
  return ' -- ' . join(l:paths, ' ')
endfunction

function! flog#build_log_command() abort
  let l:state = flog#get_state()

  let l:command = flog#get_fugitive_git_command()
  let l:command .= ' log --graph --no-color'
  let l:command .= ' --pretty=' . flog#create_log_format()
  let l:command .= ' --date=' . shellescape(l:state.date)
  if l:state.all && !l:state.limit
    let l:command .= ' --all'
  endif
  if l:state.bisect && !l:state.limit
    let l:command .= ' --bisect'
  endif
  if l:state.no_merges
    let l:command .= ' --no-merges'
  endif
  if l:state.reflog && !l:state.limit
    let l:command .= ' --reflog'
  endif
  if l:state.skip != v:null
    let l:command .= ' --skip=' . shellescape(l:state.skip)
  endif
  if l:state.max_count != v:null
    let l:command .= ' --max-count=' . shellescape(l:state.max_count)
  endif
  if l:state.search != v:null
    let l:search = shellescape(l:state.search)
    let l:command .= ' --grep=' . l:search
  endif
  if l:state.patch_search != v:null
    let l:patch_search = shellescape(l:state.patch_search)
    let l:command .= ' -G' . l:patch_search
  endif
  if l:state.limit != v:null
    let l:limit = shellescape(l:state.limit)
    let l:command .= ' -L' . l:limit
  endif
  if l:state.raw_args != v:null
    let l:command .= ' ' . l:state.raw_args
  endif
  if len(l:state.rev) >= 1
    if l:state.limit
      let l:rev = l:state.rev[0]
    else
      let l:rev = join(l:state.rev, ' ')
    endif
    let l:command .= ' ' . l:rev . ' --'
  endif
  if get(g:, 'flog_use_ansi_esc')
    let l:command .= ' --color'
  endif
  let l:command .= flog#build_log_paths()

  return l:command
endfunction

function! flog#get_log_display(commits) abort
  let l:o = []
  for l:c in a:commits
    let l:o += l:c.display
  endfor
  return l:o
endfunction

" }}}

" Commit operations {{{

function! flog#get_commit_at_line(...) abort
  let l:firstline = exists('a:1') ? a:1 : -1
  let l:lastline = exists('a:2') ? a:2 : -1
  let l:should_swap = exists('a:3') ? a:3 : v:false

  if l:firstline < 0
    let l:firstline = line('.')
  endif

  if l:lastline < 0
    let l:lastline = line('.')
  endif

  if l:should_swap
    let l:tmp = l:lastline
    let l:lastline = l:firstline
    let l:firstline = l:tmp
  endif

  let l:state = flog#get_state()

  let l:first_commit = get(l:state.line_commits, l:firstline - 1, v:null)

  if type(l:first_commit) != v:t_dict
    return v:null
  endif

  " not a range, return only first commit
  if l:firstline == l:lastline
    return l:first_commit
  endif

  let l:last_commit = get(l:state.line_commits, l:lastline - 1, v:null)

  if type(l:last_commit) != v:t_dict
    return v:null
  endif

  return [l:first_commit, l:last_commit]
endfunction

function! flog#get_commit_at_current_line() abort
  return flog#get_commit_at_line(line('.'), line('.'))
endfunction

function! flog#get_commit_at_selection(...) abort
  let l:should_swap = exists('a:1') ? a:1 : v:false
  return flog#get_commit_at_line(line("'<"), line("'>"), l:should_swap)
endfunction

function! flog#format_commit(commit, ...) abort
  let l:format = exists('a:1') ? a:1 : ''
  let l:dual_format = exists('a:2') ? a:2 : ''
  let l:default_first = exists('a:3') ? a:3 : ''

  if empty(l:format)
    let l:format = '%s'
  endif

  if empty(l:dual_format)
    let l:dual_format = printf(l:format, '%s %s')
  endif

  if type(a:commit) == v:t_dict
    " single commit
    if !empty(l:default_first)
      return printf(l:dual_format, l:default_first, a:commit.short_commit_hash)
    endif
    return printf(l:format, a:commit.short_commit_hash)
  elseif type(a:commit) == v:t_list
    " two commits
    return printf(l:dual_format, a:commit[0].short_commit_hash, a:commit[1].short_commit_hash)
  endif
  " presumably no commit
  return v:null
endfunction

function! flog#jump_commits(commits) abort
  let l:state = flog#get_state()

  let l:current_commit = flog#get_commit_at_current_line()
  if type(l:current_commit) != v:t_dict
    return
  endif

  let l:index = index(l:state.commits, l:current_commit) + a:commits
  let l:index = min([max([l:index, 0]), len(l:state.commits) - 1])

  let l:line = index(l:state.line_commits, l:state.commits[l:index]) + 1

  if l:line >= 0
    exec l:line
  endif
endfunction

function! flog#next_commit() abort
  call flog#jump_commits(v:count1)
endfunction

function! flog#previous_commit() abort
  call flog#jump_commits(-v:count1)
endfunction

function! flog#copy_commits(...) range abort
  let l:by_line = exists('a:1') ? a:1 : v:false
  let l:state = flog#get_state()

  let l:commits = flog#get_commit_at_line(a:firstline, a:lastline)

  if type(l:commits) == v:t_dict
    let l:first_commit = l:commits
    let l:last_commit = l:commits
  elseif type(l:commits) == v:t_list
    let l:first_commit = l:commits[0]
    let l:last_commit = l:commits[1]
  else
    return 0
  endif

  let l:first_index = index(l:state.commits, l:first_commit)

  if l:by_line
    let l:last_index = index(l:state.commits, l:last_commit)
  else
    let l:last_index = l:first_index + a:lastline - a:firstline
  endif

  let l:commits = l:state.commits[l:first_index : l:last_index]
  let l:commits = map(l:commits, 'v:val.short_commit_hash')

  return setreg(v:register, join(l:commits, ' '))
endfunction

" }}}

" Ref operations {{{

function! flog#get_ref_at_line(...) abort
  let l:line = exists('a:1') ? a:1 : line('.')
  let l:state = flog#get_state()
  return get(l:state.line_commit_refs, l:line - 1, v:null)
endfunction

function! flog#jump_refs(refs) abort
  let l:state = flog#get_state()

  if l:state.commit_refs == []
    return
  endif

  let l:current_ref = flog#get_ref_at_line()
  let l:current_commit = flog#get_commit_at_current_line()
  if type(l:current_commit) != v:t_dict
    return
  endif

  let l:refs = a:refs
  if l:refs < 0 && l:current_commit.ref_names_unwrapped ==# ''
    let l:refs += 1
  endif

  if type(l:current_ref) != v:t_list
    let l:index = -1
  else
    let l:index = index(l:state.commit_refs, l:current_ref)
  endif
  let l:index = max([0, l:index + l:refs])
  if l:index >= len(l:state.commit_refs)
    return
  endif

  let l:line = index(l:state.line_commit_refs, l:state.commit_refs[l:index]) + 1

  if l:line >= 0
    exec l:line
  endif
endfunction

function! flog#jump_to_ref(ref) abort
  let l:state = flog#get_state()
  if !has_key(l:state.ref_line_lookup, a:ref)
    return
  endif
  exec l:state.ref_line_lookup[a:ref] + 1
endfunction

function! flog#next_ref() abort
  call flog#jump_refs(v:count1)
endfunction

function! flog#previous_ref() abort
  call flog#jump_refs(-v:count1)
endfunction

" }}}

" Buffer management {{{

" Graph buffer {{{

function! flog#modify_graph_buffer_contents(content) abort
  let l:state = flog#get_state()

  let l:cursor_pos = line('.')

  silent setlocal modifiable
  silent setlocal noreadonly
  1,$ d
  call append(0, a:content)
  $,$ d
  call flog#graph_buffer_settings()

  exec l:cursor_pos
  let l:state.line_commits = []
endfunction

function! flog#set_graph_buffer_commits(commits) abort
  let l:state = flog#get_state()

  call flog#modify_graph_buffer_contents(flog#get_log_display(a:commits))

  let l:state.line_commits = []

  let l:state.all_refs = []
  let l:state.commit_refs = []
  let l:state.line_commit_refs = []
  let l:state.ref_line_lookup = {}

  let l:cr = v:null

  let l:scr = l:state.commit_refs
  let l:sr = l:state.all_refs
  let l:srl = l:state.ref_line_lookup
  let l:slc = l:state.line_commits
  let l:slr = l:state.line_commit_refs

  for l:c in a:commits
    if l:c.ref_name_list !=# []
      let l:cr = l:c.ref_name_list
      let l:scr += [l:cr]
      let l:sr += l:cr
      for l:r in l:cr
        let l:srl[l:r] = len(l:slc)
      endfor
    endif

    let l:slc += repeat([l:c], len(l:c.display))
    let l:slr += repeat([l:cr], len(l:c.display))
  endfor
endfunction

function! flog#set_graph_buffer_title() abort
  let l:state = flog#get_state()

  let l:title = 'flog-' . l:state.instance
  if l:state.all && !l:state.limit
    let l:title .= ' [all]'
  endif
  if l:state.bisect && !l:state.limit
    let l:title .= ' [bisect]'
  endif
  if l:state.no_merges
    let l:title .= ' [no_merges]'
  endif
  if l:state.reflog && !l:state.limit
    let l:title .= ' [reflog]'
  endif
  if l:state.skip != v:null
    let l:title .= ' [skip=' . l:state.skip . ']'
  endif
  if l:state.max_count != v:null
    let l:title .= ' [max_count=' . l:state.max_count . ']'
  endif
  if l:state.search != v:null
    let l:title .= ' [search=' . flog#ellipsize(l:state.search) . ']'
  endif
  if l:state.patch_search != v:null
    let l:title .= ' [patch_search=' . flog#ellipsize(l:state.patch_search) . ']'
  endif
  if l:state.limit != v:null
    let l:title .= ' [limit=' . flog#ellipsize(l:state.limit) . ']'
  endif
  if len(l:state.rev) == 1
    let l:title .= ' [rev=' . flog#ellipsize(l:state.rev[0]) . ']'
  endif
  if len(l:state.rev) > 1
    let l:title .= ' [rev=...]'
  endif
  if len(l:state.path) == 1
    let l:title .= ' [path=' . flog#ellipsize(fnamemodify(l:state.path[0], ':t')) . ']'
  elseif len(l:state.path) > 1
    let l:title .= ' [path=...]'
  endif

  exec 'silent file '. l:title

  return l:title
endfunction

function! flog#set_graph_buffer_color() abort
  if get(g:, 'flog_use_ansi_esc')
    let l:state = flog#get_state()
    if !l:state.ansi_esc_called
      AnsiEsc
      let l:state.ansi_esc_called = 1
    else
      AnsiEsc!
    endif
  endif
endfunction

function! flog#get_graph_cursor() abort
  let l:state = flog#get_state()
  if l:state.line_commits != []
    return flog#get_commit_at_current_line()
  endif
  return v:null
endfunction

function! flog#restore_graph_cursor(cursor) abort
  if type(a:cursor) != v:t_dict
    return
  endif

  let l:state = flog#get_state()

  if len(l:state.commits) == 0
    return
  endif

  let l:short_commit_hash = a:cursor.short_commit_hash

  let l:commit = flog#get_commit_at_current_line()
  if type(l:commit) != v:t_dict
    return
  endif
  if l:short_commit_hash ==# l:commit.short_commit_hash
    return
  endif

  let l:line = v:null
  for l:commit in l:state.commits
    if l:commit.short_commit_hash == l:short_commit_hash
      call cursor(index(l:state.line_commits, l:commit) + 1, 1)
      return
    endif
  endfor
endfunction

function! flog#populate_graph_buffer() abort
  let l:state = flog#get_state()

  let l:cursor = flog#get_graph_cursor()

  let l:command = flog#build_log_command()
  let l:state.previous_log_command = l:command

  let l:output = flog#systemlist(l:command)
  let l:commits = flog#parse_log_output(l:output)

  call flog#set_graph_buffer_commits(l:commits)
  call flog#set_graph_buffer_title()
  call flog#set_graph_buffer_color()

  let l:state.commits = l:commits

  call flog#restore_graph_cursor(l:cursor)
endfunction

function! flog#clear_graph_update_queue() abort
  augroup FlogGraphUpdate
    autocmd! * <buffer>
  augroup END
endfunction

function! flog#do_queued_graph_update() abort
  call flog#clear_graph_update_queue()
  call flog#populate_graph_buffer()
endfunction

function! flog#queue_graph_update(buff) abort
  augroup FlogGraphUpdate
    exec 'autocmd! * <buffer=' . a:buff . '>'
    exec 'autocmd WinEnter <buffer=' . a:buff . '> call flog#do_queued_graph_update()'
  augroup END
endfunction

function! flog#graph_buffer_settings() abort
  exec 'lcd ' . flog#get_fugitive_workdir()
  set filetype=floggraph
endfunction

function! flog#initialize_graph_buffer(state) abort
  call flog#set_buffer_state(a:state)
  call flog#trigger_fugitive_git_detection()
  call flog#graph_buffer_settings()
  call flog#populate_graph_buffer()
endfunction

function! flog#update_options(args, force) abort
  let l:state = flog#get_state()
  let l:defaults = flog#get_internal_default_args()

  if a:force
    call extend(l:state, l:defaults)
  endif

  call flog#parse_set_args(a:args, l:state, l:defaults)

  call flog#populate_graph_buffer()
endfunction

function! flog#toggle_all_refs_option() abort
  let l:state = flog#get_state()
  let l:state.all = l:state.all ? v:false : v:true
  call flog#populate_graph_buffer()
endfunction

function! flog#toggle_bisect_option() abort
  let l:state = flog#get_state()
  let l:state.bisect = l:state.bisect ? v:false : v:true
  call flog#populate_graph_buffer()
endfunction

function! flog#toggle_no_merges_option() abort
  let l:state = flog#get_state()
  let l:state.no_merges = l:state.no_merges ? v:false : v:true
  call flog#populate_graph_buffer()
endfunction

function! flog#toggle_reflog_option() abort
  let l:state = flog#get_state()
  let l:state.reflog = l:state.reflog ? v:false : v:true
  call flog#populate_graph_buffer()
endfunction

function! flog#set_skip_option(skip) abort
  let l:state = flog#get_state()
  let l:state.skip = a:skip
  call flog#populate_graph_buffer()
endfunction

function! flog#change_skip_by_max_count(multiplier) abort
  let l:state = flog#get_state()
  if a:multiplier == 0 || l:state.max_count == v:null
    return
  endif
  if l:state.skip == v:null
    let l:state.skip = 0
  endif
  let l:state.skip = max([0, l:state.skip + l:state.max_count * a:multiplier])
  call flog#populate_graph_buffer()
endfunction

" }}}

" Preview buffer {{{

function! flog#preview_buffer_settings() abort
  silent doautocmd User FlogPreviewSetup
endfunction

function! flog#commit_preview_buffer_settings() abort
  silent doautocmd User FlogCommitPreviewSetup
endfunction

function! flog#initialize_preview_buffer(state) abort
  let a:state.preview_window_ids += [win_getid()]
  call flog#set_buffer_state(a:state)
  call flog#preview_buffer_settings()
endfunction

" }}}

" }}}

" Layout management {{{

" Preview layout management {{{

function! flog#close_preview() abort
  let l:state = flog#get_state()
  let l:previous_window_id = win_getid()

  for l:preview_window_id in l:state.preview_window_ids
    " preview buffer is not open
    if win_id2tabwin(l:preview_window_id) == [0, 0]
      continue
    endif

    " get the previous buffer to switch back to it after closing
    call win_gotoid(l:preview_window_id)
    close
  endfor

  let l:state.preview_window_ids = []

  " go back to the previous window
  call win_gotoid(l:previous_window_id)

  return
endfunction

function! flog#preview(command, ...) abort
  let l:keep_focus = exists('a:1') ? a:1 : v:false
  let l:should_update = exists('a:2') ? a:2 : v:false

  let l:previous_window_id = win_getid()
  let l:previous_buffer_number = bufnr()

  let l:state = flog#get_state()

  let l:saved_window_ids = flog#get_all_window_ids()
  exec a:command
  let l:preview_window_ids = flog#exclude(flog#get_all_window_ids(), l:saved_window_ids)
  if l:preview_window_ids != []
    call win_gotoid(l:previous_window_id)
    call flog#close_preview()
    for l:preview_window_id in l:preview_window_ids
      call win_gotoid(l:preview_window_id)
      call flog#initialize_preview_buffer(l:state)
    endfor
  endif

  call flog#handle_command_cleanup(
        \ l:keep_focus, l:should_update, l:previous_window_id, l:previous_buffer_number)
endfunction

" }}}

" Graph layout management {{{

function! flog#handle_command_window_cleanup(keep_focus, previous_window_id) abort
  if !a:keep_focus
    call win_gotoid(a:previous_window_id)
    if has('nvim')
      redraw!
    endif
  endif
endfunction

function! flog#handle_command_update_cleanup(should_update, previous_window_id, previous_buffer_number) abort
  if a:should_update
    if win_getid() != a:previous_window_id
      call flog#queue_graph_update(a:previous_buffer_number)
    else
      call flog#populate_graph_buffer()
    endif
  endif
endfunction

function! flog#handle_command_cleanup(keep_focus, should_update, previous_window_id, previous_buffer_number) abort
  call flog#handle_command_window_cleanup(a:keep_focus, a:previous_window_id)
  call flog#handle_command_update_cleanup(a:should_update, a:previous_window_id, a:previous_buffer_number)
endfunction

function! flog#open_graph(state) abort
  let l:window_name = 'flog-' . a:state.instance . ' [uninitialized]'
  silent exec a:state.open_cmd . ' ' . l:window_name

  let a:state.graph_window_id = win_getid()

  call flog#initialize_graph_buffer(a:state)
endfunction

function! flog#open(args) abort
  if !flog#is_fugitive_buffer()
    throw g:flog_not_a_fugitive_buffer
  endif

  let l:original_file = expand('%:p')

  let l:parsed_args = flog#parse_args(a:args)
  let l:initial_state = flog#get_initial_state(l:parsed_args, l:original_file)

  call flog#open_graph(l:initial_state)
endfunction

function! flog#quit() abort
  let l:flog_tab = tabpagenr()
  let l:tabs = tabpagenr('$')
  call flog#close_preview()
  quit!
  if l:tabs > tabpagenr('$') && l:flog_tab == tabpagenr()
    tabprev
  endif
endfunction

" }}}

" }}}

" Command helpers {{{

function! flog#run_command(cmd, ...) abort
  let l:keep_focus = exists('a:1') ? a:1 : v:false
  let l:should_update = exists('a:2') ? a:2 : v:false
  let l:should_preview = exists('a:3') ? a:3 : v:false

  let l:previous_window_id = win_getid()
  let l:previous_buffer_number = bufnr()

  let g:debug = a:cmd

  if type(a:cmd) != v:t_string
    return
  endif

  if l:should_preview
    call flog#preview(a:cmd, v:true)
    call flog#commit_preview_buffer_settings()
    call flog#handle_command_window_cleanup(l:keep_focus, l:previous_window_id)
  else
    exec a:cmd
    call flog#handle_command_cleanup(
          \ l:keep_focus, l:should_update, l:previous_window_id, l:previous_buffer_number)
  endif
endfunction

function! flog#preview_command(cmd, ...) abort
  let l:keep_focus = exists('a:1') ? a:1 : v:false
  let l:should_update = exists('a:2') ? a:2 : v:false

  call flog#run_command(a:cmd, l:keep_focus, l:should_update, v:true)
endfunction

" }}}

" vim: set et sw=2 ts=2 fdm=marker:
