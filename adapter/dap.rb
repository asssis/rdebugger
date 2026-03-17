#!/usr/bin/env ruby # usa o interpretador ruby
# frozen_string_literal: true # congela literais de string

require 'json' # encode/decode JSON
require 'set' # coleção Set
require 'fileutils' # helpers de filesystem

$stdout.sync = true # faz flush imediato no stdout
$stderr.sync = true # faz flush imediato no stderr

log_io = nil # handle do arquivo de log
begin # início da configuração do log
  log_path = ENV['DAP_LOG_PATH'] || File.join(Dir.pwd, '.ruby-dap-logs', 'dap_io.log') # resolve caminho do log
  FileUtils.mkdir_p(File.dirname(log_path)) # garante diretório do log
  log_io = File.open(log_path, 'a') # abre arquivo em append
  log_io.sync = true # flush imediato no arquivo
rescue => e # captura erros de log
  $stderr.puts("DAP LOG ERROR #{e.class}: #{e.message}") # reporta falha de log
end # fim da configuração do log

dap_state = { initialized: false } # estado do DAP (usando hash para ser modificável)

# Versão básica de log_line (será atualizada depois)
log_line = lambda do |line| # helper para logar linha
  timestamp = Time.now.strftime('%Y-%m-%d %H:%M:%S.%3N') # timestamp com milissegundos
  formatted_line = "[#{timestamp}] #{line}" # linha formatada com timestamp
  $stderr.puts(formatted_line) # escreve no console debug
  log_io&.puts(formatted_line) # escreve no arquivo se existir
end # fim do helper de log

seq = 1 # contador de sequência de mensagens
buffer = +'' # buffer de entrada do stream

state = { # estado do debugger
  program_path: nil, # caminho do programa atual
  main_program_path: nil, # caminho do arquivo principal
  current_source_path: nil, # arquivo atual em execução
  sources: {}, # conteúdo por arquivo fonte
  lines: [], # linhas do programa
  current_line: 1, # linha atual
  execution_phase: :runtime, # fase atual (:plan, :runtime)
  execution_plan_lines: [], # cronograma de mapeamento (classes -> métodos)
  execution_plan_index: -1, # índice atual dentro do cronograma
  first_runtime_line: 1, # primeira linha executável no top-level
  class_map: [], # mapa estrutural de classes
  method_map: [], # mapa estrutural de métodos
  method_definitions: {}, # mapeia nome do método para linha do def
  method_ranges: {}, # mapeia método para faixa {def_line, body_start, end_line}
  methods_by_name: Hash.new { |h, k| h[k] = [] }, # índice de métodos por nome
  methods_by_owner: {}, # índice de métodos por "Classe#metodo"
  for_loops_by_start: {}, # mapa de loops "for" por linha inicial
  for_loops_by_end: {}, # mapa de loops "for" por linha final
  active_for_loops: [], # loops "for" ativos em execução
  each_loops_by_start: {}, # mapa de loops "each" por linha inicial
  each_loops_by_end: {}, # mapa de loops "each" por linha final
  active_each_loops: [], # loops "each" ativos em execução
  while_loops_by_start: {}, # mapa de loops "while" por linha inicial
  while_loops_by_end: {}, # mapa de loops "while" por linha final
  active_while_loops: [], # loops "while" ativos em execução
  line_in_method_body: Set.new, # linhas que pertencem ao corpo de métodos
  line_in_class_body: Set.new, # linhas que pertencem ao corpo de classes
  non_exec_top_level_lines: Set.new, # linhas que não devem executar no top-level (ex: def dentro de class)
  call_stack: [], # pilha simples de retorno para stepIn/stepOut
  top_locals: {}, # variáveis simples do contexto top-level
  objects: {}, # objetos simulados por id
  next_object_id: 1, # sequencial para ids de objetos simulados
  object_var_ref_base: 1000, # faixa de variablesReference para objetos
  breakpoints: Hash.new { |h, k| h[k] = Set.new }, # breakpoints por arquivo
  stop_on_entry: true, # parar ao iniciar
  terminated: false # flag de término
} # fim do estado

next_seq = lambda do # gerador de sequência
  current = seq # captura seq atual
  seq += 1 # incrementa seq
  current # retorna seq capturada
end # fim do gerador

send_msg = lambda do |msg| # envia uma mensagem DAP
  json = JSON.generate(msg) # encode em JSON
  header = "Content-Length: #{json.bytesize}\r\n\r\n" # header DAP
  # skip_output_event=true evita recursão infinita (log_line -> send_event -> send_msg -> log_line)
  log_line.call("DAP SAÍDA: #{json}", true) # log apenas do JSON de saída
  $stdout.write(header) # escreve header no stdout
  $stdout.write(json) # escreve body no stdout
end # fim do envio de mensagem

send_response = lambda do |request, body = {}, success = true, message = nil| # envia response
  response = { # monta objeto de response
    type: 'response', # tipo response
    seq: next_seq.call, # sequência do response
    request_seq: request['seq'], # sequência do request
    success: success, # flag de sucesso
    command: request['command'], # comando original
    body: body # corpo do response
  } # fim do response
  response['message'] = message if !success && message # mensagem de erro opcional
  send_msg.call(response) # envia response
end # fim do response

send_event = lambda do |event, body = {}| # envia event
  send_msg.call({ # monta objeto de event
    type: 'event', # tipo event
    seq: next_seq.call, # sequência do event
    event: event, # nome do event
    body: body # corpo do event
  }) # envia event
end # fim do event

# Atualiza log_line para incluir output event no Debug Console
# Usa flag para evitar recursão infinita (não envia output event quando está logando uma mensagem DAP)
log_line = lambda do |line, skip_output_event = false| # helper para logar linha
  timestamp = Time.now.strftime('%Y-%m-%d %H:%M:%S.%3N') # timestamp com milissegundos
  formatted_line = "[#{timestamp}] #{line}" # linha formatada com timestamp
  $stderr.puts(formatted_line) # escreve no console debug
  log_io&.puts(formatted_line) # escreve no arquivo se existir
  
  # Envia para Debug Console do VS Code via Output Event
  # skip_output_event evita recursão quando log_line é chamado de dentro de send_msg
  if !skip_output_event && dap_state[:initialized] # só envia se DAP foi inicializado e não está em recursão
    begin # tenta enviar output event
      send_event.call('output', { # evento de output
        category: 'stdout', # categoria stdout
        output: formatted_line + "\n" # mensagem formatada
      }) # fim do output event
    rescue => e # captura erros
      # Ignora erros ao enviar output (pode falhar se DAP não estiver pronto)
    end # fim do rescue
  end # fim do if
end # fim do helper de log

send_stopped = lambda do |reason| # envia stopped
  send_event.call('stopped', { # payload do stopped
    reason: reason, # motivo da parada
    threadId: 1, # id da thread única
    allThreadsStopped: true # todas threads paradas
  }) # fim do payload
end # fim do stopped

send_terminated = lambda do # envia terminated
  return if state[:terminated] # evita duplicar

  state[:terminated] = true # marca como terminado
  send_event.call('terminated', {}) # emite terminated
end # fim do terminated

load_program = lambda do |program_path| # carrega o programa
  content = File.read(program_path) # lê arquivo
  lines = content.split(/\r?\n/) # separa em linhas
  lines = [''] if lines.empty? # garante pelo menos uma linha
  state[:main_program_path] = program_path
  state[:current_source_path] = program_path
  state[:sources] = { program_path => lines }
  state[:lines] = lines # guarda linhas
  state[:current_line] = 1 # valor temporário (ajustado abaixo)
  state[:execution_phase] = :runtime # valor padrão
  state[:execution_plan_lines] = [] # limpa cronograma
  state[:execution_plan_index] = -1 # reseta índice do cronograma
  state[:first_runtime_line] = 1 # valor padrão
  state[:class_map] = [] # limpa mapa de classes
  state[:method_map] = [] # limpa mapa de métodos
  state[:call_stack] = [] # limpa pilha de chamadas
  state[:top_locals] = {} # limpa variáveis top-level
  state[:objects] = {} # limpa objetos simulados
  state[:next_object_id] = 1 # reseta ids de objeto
  state[:method_definitions] = {} # limpa índice de métodos
  state[:method_ranges] = {} # limpa faixas de métodos
  state[:methods_by_name] = Hash.new { |h, k| h[k] = [] } # limpa índice por nome
  state[:methods_by_owner] = {} # limpa índice por owner
  state[:for_loops_by_start] = {} # limpa mapa de for por início
  state[:for_loops_by_end] = {} # limpa mapa de for por fim
  state[:active_for_loops] = [] # limpa loops ativos
  state[:each_loops_by_start] = {} # limpa mapa de each por início
  state[:each_loops_by_end] = {} # limpa mapa de each por fim
  state[:active_each_loops] = [] # limpa loops each ativos
  state[:while_loops_by_start] = {} # limpa mapa de while por início
  state[:while_loops_by_end] = {} # limpa mapa de while por fim
  state[:active_while_loops] = [] # limpa loops while ativos
  state[:line_in_method_body] = Set.new # limpa marcação de linhas de método
  state[:line_in_class_body] = Set.new # limpa marcação de linhas de classe
  state[:non_exec_top_level_lines] = Set.new # limpa linhas não executáveis no top-level

  loop_key = lambda { |src, line| "#{src}|#{line}" } # chave única para mapas de loop
  block_stack = [] # pilha simples para parear def/end
  lines.each_with_index do |raw_line, idx| # indexa defs para stepIn
    line_no = idx + 1 # linha 1-based
    stripped = raw_line.sub(/#.*$/, '').strip # remove comentário de fim de linha

    if (match = /^def\s+([a-zA-Z_]\w*[!?=]?)(?:\(([^)]*)\))?/.match(stripped)) # início de método
      owner_class = block_stack.reverse.find { |item| item[:type] == 'class' }&.dig(:name) # classe dona do método
      params = match[2].to_s.split(',').map { |p| p.strip }.reject(&:empty?).map { |p| p.split('=').first.to_s.strip } # parâmetros simples (remove defaults)
      block_stack << { type: 'def', name: match[1], line: line_no, owner_class: owner_class, params: params } # empilha def
      state[:non_exec_top_level_lines].add(line_no) if owner_class # top-level não deve parar em def de classe
      next
    end

    if (match = /^class\s+([A-Z]\w*(?:::[A-Z]\w*)*)/.match(stripped)) # início de classe
      block_stack << { type: 'class', name: match[1], line: line_no } # empilha classe nomeada
      state[:non_exec_top_level_lines].add(line_no) # class não é executável no runtime
      next
    end

    if (for_match = /^for\s+([a-z_]\w*)\s+in\s+(.+)$/.match(stripped)) # início de loop for
      block_stack << { type: 'for', line: line_no, var_name: for_match[1], iterable_expr: for_match[2].strip } # empilha for
      next
    end

    if (each_match = /^(.+)\.each\s+do\s+\|([a-z_]\w*)\|$/.match(stripped)) # início de each
      block_stack << { type: 'each', line: line_no, iterable_expr: each_match[1].strip, var_name: each_match[2] } # empilha each
      next
    end

    if (while_match = /^while\s+(.+)$/.match(stripped)) # início de while
      block_stack << { type: 'while', line: line_no, condition_expr: while_match[1].strip } # empilha while
      next
    end

    if /^(module|if|unless|case|begin|until)\b/.match?(stripped) # outros blocos
      block_stack << { type: 'block', line: line_no } # empilha bloco genérico
      next
    end

    next unless stripped == 'end' # só trata fechamento explícito com "end"

    opener = block_stack.pop # desempilha último bloco
    next unless opener

    if opener[:type] == 'def' # fechamento de método
      method_name = opener[:name] # nome do método
      def_line = opener[:line] # linha do def
      owner_class = opener[:owner_class] # classe dona do método (nil para top-level)
      params = opener[:params] || [] # parâmetros do método
      body_start = def_line + 1 # início do corpo
      end_line = line_no # linha do end

      state[:method_definitions][method_name] = def_line unless state[:method_definitions].key?(method_name)
      method_info = { # metadados do método
        name: method_name,
        owner_class: owner_class,
        scope: owner_class || 'top-level',
        params: params,
        source_path: program_path,
        def_line: def_line,
        body_start: body_start,
        end_line: end_line
      }
      state[:method_ranges][method_name] = method_info # mantém compatibilidade com índice antigo
      state[:methods_by_name][method_name] << method_info # índice por nome
      state[:methods_by_owner]["#{owner_class}##{method_name}"] = method_info if owner_class # índice por classe
      state[:method_map] << method_info # adiciona no mapa estrutural de métodos

      (body_start..end_line).each { |l| state[:line_in_method_body].add(l) } # marca corpo do método
      next
    end

    if opener[:type] == 'class' # fechamento de classe
      class_info = { # metadados da classe
        name: opener[:name],
        line_start: opener[:line],
        line_end: line_no,
        scope: 'top-level'
      }
      state[:class_map] << class_info # adiciona no mapa estrutural de classes
      ((opener[:line] + 1)..line_no).each { |l| state[:line_in_class_body].add(l) } # marca corpo da classe
      next
    end

    if opener[:type] == 'for' # fechamento de loop for
      loop_info = {
        start_line: opener[:line],
        body_start: opener[:line] + 1,
        end_line: line_no,
        source_path: program_path,
        var_name: opener[:var_name],
        iterable_expr: opener[:iterable_expr]
      }
      state[:for_loops_by_start][loop_key.call(program_path, loop_info[:start_line])] = loop_info
      state[:for_loops_by_end][loop_key.call(program_path, loop_info[:end_line])] = loop_info
      next
    end

    if opener[:type] == 'each' # fechamento de loop each
      loop_info = {
        start_line: opener[:line],
        body_start: opener[:line] + 1,
        end_line: line_no,
        source_path: program_path,
        var_name: opener[:var_name],
        iterable_expr: opener[:iterable_expr]
      }
      state[:each_loops_by_start][loop_key.call(program_path, loop_info[:start_line])] = loop_info
      state[:each_loops_by_end][loop_key.call(program_path, loop_info[:end_line])] = loop_info
      next
    end

    if opener[:type] == 'while' # fechamento de loop while
      loop_info = {
        start_line: opener[:line],
        body_start: opener[:line] + 1,
        end_line: line_no,
        source_path: program_path,
        condition_expr: opener[:condition_expr]
      }
      state[:while_loops_by_start][loop_key.call(program_path, loop_info[:start_line])] = loop_info
      state[:while_loops_by_end][loop_key.call(program_path, loop_info[:end_line])] = loop_info
    end
  end

  # Mapeia classes/métodos de arquivos requeridos via require_relative
  discover_required_sources = lambda do |entry_path|
    visited = Set.new([entry_path])
    queue = [entry_path]
    discovered = []

    until queue.empty?
      current_path = queue.shift
      current_lines = state[:sources][current_path] || []
      current_dir = File.dirname(current_path)

      current_lines.each do |raw_line|
        stripped = raw_line.sub(/#.*$/, '').strip
        next unless (match = /^require_relative\s+["'](.+)["']$/.match(stripped))

        rel = match[1]
        rel = "#{rel}.rb" unless rel.end_with?('.rb')
        req_path = File.expand_path(rel, current_dir)
        next unless File.file?(req_path)
        next if visited.include?(req_path)

        req_content = File.read(req_path)
        req_lines = req_content.split(/\r?\n/)
        req_lines = [''] if req_lines.empty?
        state[:sources][req_path] = req_lines
        visited.add(req_path)
        queue << req_path
        discovered << req_path
      end
    end

    discovered
  end

  parse_method_map_for_source = lambda do |source_path|
    src_lines = state[:sources][source_path] || []
    block_stack = []

    src_lines.each_with_index do |raw_line, idx|
      line_no = idx + 1
      stripped = raw_line.sub(/#.*$/, '').strip

      if (match = /^def\s+([a-zA-Z_]\w*[!?=]?)(?:\(([^)]*)\))?/.match(stripped))
        owner_class = block_stack.reverse.find { |item| item[:type] == 'class' }&.dig(:name)
        params = match[2].to_s.split(',').map { |p| p.strip }.reject(&:empty?).map { |p| p.split('=').first.to_s.strip }
        block_stack << { type: 'def', name: match[1], line: line_no, owner_class: owner_class, params: params }
        next
      end

      if (match = /^class\s+([A-Z]\w*(?:::[A-Z]\w*)*)/.match(stripped))
        block_stack << { type: 'class', name: match[1], line: line_no }
        next
      end

      if (for_match = /^for\s+([a-z_]\w*)\s+in\s+(.+)$/.match(stripped))
        block_stack << { type: 'for', line: line_no, var_name: for_match[1], iterable_expr: for_match[2].strip }
        next
      end

      if (each_match = /^(.+)\.each\s+do\s+\|([a-z_]\w*)\|$/.match(stripped))
        block_stack << { type: 'each', line: line_no, iterable_expr: each_match[1].strip, var_name: each_match[2] }
        next
      end

      if (while_match = /^while\s+(.+)$/.match(stripped))
        block_stack << { type: 'while', line: line_no, condition_expr: while_match[1].strip }
        next
      end

      if /^(module|if|unless|case|begin|until)\b/.match?(stripped)
        block_stack << { type: 'block', line: line_no }
        next
      end

      next unless stripped == 'end'
      opener = block_stack.pop
      next unless opener

      if opener[:type] == 'def'
        method_name = opener[:name]
        owner_class = opener[:owner_class]
        def_line = opener[:line]
        end_line = line_no
        body_start = def_line + 1
        params = opener[:params] || []

        method_info = {
          name: method_name,
          owner_class: owner_class,
          scope: owner_class || 'top-level',
          params: params,
          source_path: source_path,
          def_line: def_line,
          body_start: body_start,
          end_line: end_line
        }

        state[:methods_by_name][method_name] << method_info
        state[:methods_by_owner]["#{owner_class}##{method_name}"] = method_info if owner_class
        state[:method_map] << method_info
      elsif opener[:type] == 'class'
        class_info = {
          name: opener[:name],
          line_start: opener[:line],
          line_end: line_no,
          scope: 'top-level',
          source_path: source_path
        }
        state[:class_map] << class_info
      elsif opener[:type] == 'for'
        loop_info = {
          start_line: opener[:line],
          body_start: opener[:line] + 1,
          end_line: line_no,
          source_path: source_path,
          var_name: opener[:var_name],
          iterable_expr: opener[:iterable_expr]
        }
        state[:for_loops_by_start][loop_key.call(source_path, loop_info[:start_line])] = loop_info
        state[:for_loops_by_end][loop_key.call(source_path, loop_info[:end_line])] = loop_info
      elsif opener[:type] == 'each'
        loop_info = {
          start_line: opener[:line],
          body_start: opener[:line] + 1,
          end_line: line_no,
          source_path: source_path,
          var_name: opener[:var_name],
          iterable_expr: opener[:iterable_expr]
        }
        state[:each_loops_by_start][loop_key.call(source_path, loop_info[:start_line])] = loop_info
        state[:each_loops_by_end][loop_key.call(source_path, loop_info[:end_line])] = loop_info
      elsif opener[:type] == 'while'
        loop_info = {
          start_line: opener[:line],
          body_start: opener[:line] + 1,
          end_line: line_no,
          source_path: source_path,
          condition_expr: opener[:condition_expr]
        }
        state[:while_loops_by_start][loop_key.call(source_path, loop_info[:start_line])] = loop_info
        state[:while_loops_by_end][loop_key.call(source_path, loop_info[:end_line])] = loop_info
      end
    end
  end

  discover_required_sources.call(program_path).each do |required_path|
    parse_method_map_for_source.call(required_path)
  end

  # Runtime inicia na primeira chamada de método ou Classe.new no top-level
  first_runtime = nil
  simulated_top_locals = {}
  line_no = 1
  while line_no <= state[:lines].length
    raw_text = state[:lines][line_no - 1] || ''
    text = raw_text.sub(/#.*$/, '').strip
    top_level_line = !state[:line_in_method_body].include?(line_no) &&
      !state[:line_in_class_body].include?(line_no) &&
      !state[:non_exec_top_level_lines].include?(line_no)

    if top_level_line && !text.empty? && !text.start_with?('class ') && !text.start_with?('def ') && text != 'end'
      has_call = false

      if (ctor = /([A-Z]\w*(?:::[A-Z]\w*)*)\.new\s*(?:\(|$)/.match(text))
        # Instanciação é chamada de método mesmo sem initialize mapeado
        has_call = true
      elsif (recv_any = /([a-z_]\w*)\.([a-zA-Z_]\w*[!?=]?)/.match(text))
        # Chamada com receiver também conta como "método" para início
        has_call = true
      elsif !text.match?(/^[a-z_]\w*\s*=/) &&
          (plain = /^([a-zA-Z_]\w*[!?=]?)(?=\s|\(|$)/.match(text))
        # Chamada sem receiver (ex: puts "Hello"), ignorando palavras-chave
        ruby_keywords = %w[class module def end if elsif else unless while until for case when do begin rescue ensure return]
        has_call = !ruby_keywords.include?(plain[1])
      end

      first_runtime = line_no if has_call && first_runtime.nil?

      if (assign = /^([a-z_]\w*)\s*=\s*([A-Z]\w*(?:::[A-Z]\w*)*)\.new\b/.match(text))
        simulated_top_locals[assign[1]] = assign[2]
      end
    end

    line_no += 1
  end

  # Fallback quando não houver chamada de método clara
  if first_runtime.nil?
    first_runtime = 1
    while first_runtime <= state[:lines].length
      text = (state[:lines][first_runtime - 1] || '').strip
      top_level_line = !state[:line_in_method_body].include?(first_runtime) &&
        !state[:line_in_class_body].include?(first_runtime) &&
        !state[:non_exec_top_level_lines].include?(first_runtime)
      executable = top_level_line &&
        !text.empty? &&
        !text.start_with?('#') &&
        !text.start_with?('class ') &&
        !text.start_with?('def ') &&
        text != 'end'
      break if executable
      first_runtime += 1
    end
  end

  state[:execution_phase] = :runtime
  state[:execution_plan_lines] = []
  state[:execution_plan_index] = -1
  state[:first_runtime_line] = [first_runtime, state[:lines].length].min
  state[:current_line] = state[:first_runtime_line]
end # fim do load_program

emit_debug_mapping = lambda do # emite mapeamento estrutural ao iniciar sessão
  classes = state[:class_map] || []
  methods = state[:method_map] || []
  for_loops = state[:for_loops_by_start]&.values || []
  each_loops = state[:each_loops_by_start]&.values || []
  while_loops = state[:while_loops_by_start]&.values || []

  log_line.call("DEBUG MAP START file=#{state[:program_path]}")
  log_line.call("DEBUG MAP SUMMARY classes=#{classes.length} methods=#{methods.length} for=#{for_loops.length} each=#{each_loops.length} while=#{while_loops.length}")

  classes.each do |klass|
    log_line.call("DEBUG MAP CLASS #{klass[:name]} L#{klass[:line_start]}-L#{klass[:line_end]}")
  end

  methods.each do |method_info|
    owner = method_info[:owner_class] || 'top-level'
    source_name = method_info[:source_path] ? File.basename(method_info[:source_path]) : 'program.rb'
    log_line.call("DEBUG MAP METHOD #{owner}##{method_info[:name]} #{source_name}:L#{method_info[:def_line]}-L#{method_info[:end_line]}")
  end

  for_loops.each do |loop_info|
    log_line.call("DEBUG MAP FOR L#{loop_info[:start_line]}-L#{loop_info[:end_line]} var=#{loop_info[:var_name]} in=#{loop_info[:iterable_expr]}")
  end
  each_loops.each do |loop_info|
    log_line.call("DEBUG MAP EACH L#{loop_info[:start_line]}-L#{loop_info[:end_line]} var=#{loop_info[:var_name]} in=#{loop_info[:iterable_expr]}")
  end
  while_loops.each do |loop_info|
    log_line.call("DEBUG MAP WHILE L#{loop_info[:start_line]}-L#{loop_info[:end_line]} cond=#{loop_info[:condition_expr]}")
  end

  log_line.call("DEBUG MAP END")
end # fim do emit_debug_mapping

breakpoints_for_source = lambda do |source_path| # resolve breakpoints por caminho com normalização
  path_candidates = [source_path].compact
  path_candidates << source_path.to_s.tr('\\', '/') if source_path

  if source_path && source_path.to_s.start_with?('//wsl.localhost/Ubuntu-24.04/')
    path_candidates << source_path.to_s.sub('//wsl.localhost/Ubuntu-24.04', '')
  end

  bp = nil
  path_candidates.each do |candidate|
    next if candidate.nil? || candidate.empty?
    if state[:breakpoints].key?(candidate)
      bp = state[:breakpoints][candidate]
      break
    end
  end

  if bp.nil?
    normalized_candidates = path_candidates.map { |p| p.to_s.tr('\\', '/') }.uniq
    match_key = state[:breakpoints].keys.find do |key|
      normalized_candidates.include?(key.to_s.tr('\\', '/'))
    end
    bp = state[:breakpoints][match_key] if match_key
  end

  bp ? bp.to_a.sort : [] # retorna lista ordenada
end # fim do breakpoints_for_source

breakpoints_for_program = lambda do # obtém breakpoints do programa
  source_path = state[:current_source_path] || state[:program_path]
  breakpoints_for_source.call(source_path)
end # fim do breakpoints

method_has_breakpoint = lambda do |method_info| # verifica se há breakpoint dentro do método
  return false unless method_info

  source_path = method_info[:source_path] || state[:program_path]
  bp_set = Set.new(breakpoints_for_source.call(source_path))
  bp_set.any? do |line|
    line.is_a?(Integer) && line >= method_info[:def_line] && line <= method_info[:end_line]
  end
end # fim do method_has_breakpoint

line_has_breakpoint = lambda do |line_no| # verifica breakpoint na linha atual
  source_path = state[:current_source_path] || state[:program_path]
  bp_set = Set.new(breakpoints_for_source.call(source_path))
  bp_set.include?(line_no)
end # fim do line_has_breakpoint

find_next_breakpoint = lambda do |start_line| # acha próximo breakpoint
  breakpoints_for_program.call.each do |line| # percorre breakpoints
    return line if line >= start_line # primeiro no/apos start
  end # fim do loop
  nil # nenhum encontrado
end # fim do find_next_breakpoint

# Forward declaration para evitar NameError por ordem de definição
advance_execution = nil

continue_execution = lambda do |include_current| # continua execução
  return if state[:program_path].nil? || state[:terminated] # guarda estado inválido

  if include_current && line_has_breakpoint.call(state[:current_line]) # respeita breakpoint na linha atual
    send_stopped.call('breakpoint')
    return
  end

  # Executa direto em runtime (mapeamento já foi feito no carregamento)
  while true
    moved = advance_execution.call(true)
    break unless moved

    if line_has_breakpoint.call(state[:current_line]) # para no primeiro breakpoint alcançado
      send_stopped.call('breakpoint')
      return
    end
  end
end # fim do continue

step_one = lambda do # step de uma linha
  return if state[:program_path].nil? || state[:terminated] # guarda estado inválido

  # Implementado abaixo via advance_execution (step over realista)
end # fim do step (placeholder)

extract_called_method = lambda do |line_text| # extrai método chamado da linha atual
  text = line_text.to_s.strip # normaliza
  return nil if text.empty? || text.start_with?('#') # ignora vazio/comentário

  # Caso mais simples: chamada "foo" ou "foo(...)"
  if (m = /^([a-zA-Z_]\w*[!?=]?)\s*(?:\(|$)/.match(text))
    return m[1]
  end

  # Chamada com receiver: obj.foo(...) -> tenta último método da cadeia
  chain = text.scan(/\.([a-zA-Z_]\w*[!?=]?)\s*(?=\(|$)/).flatten
  chain.last
end # fim do extract_called_method

current_locals = lambda do # devolve variáveis do frame atual ou do top-level
  frame = state[:call_stack].last
  frame ? frame[:locals] : state[:top_locals]
end # fim do current_locals

current_self_object_id = lambda do # objeto "self" do frame atual
  frame = state[:call_stack].last
  frame ? frame[:self_object_id] : nil
end # fim do current_self_object_id

object_ref = lambda do |object_id| # referência leve de objeto simulado
  { type: 'object_ref', id: object_id }
end # fim do object_ref

is_object_ref = lambda do |value| # verifica referência de objeto
  value.is_a?(Hash) && value[:type] == 'object_ref' && value[:id].is_a?(Integer)
end # fim do is_object_ref

format_value = lambda do |value| # formata valores para painel de variáveis
  if is_object_ref.call(value)
    obj = state[:objects][value[:id]]
    class_name = obj ? obj[:class_name] : 'Object'
    return "#<#{class_name}:#{value[:id]}>"
  end

  return value.inspect if value.is_a?(String)
  return value.to_s if value.is_a?(Numeric)
  return value.inspect if value == true || value == false
  return 'nil' if value.nil?

  value.to_s
end # fim do format_value

lookup_local = lambda do |locals, key| # lookup tolerante string/symbol
  return nil unless locals
  return locals[key] if locals.key?(key)
  sym = key.to_sym
  return locals[sym] if locals.key?(sym)
  nil
end # fim do lookup_local

resolve_object_member_value = lambda do |base_value, member_name| # resolve obj.member sem executar método inteiro
  return nil unless is_object_ref.call(base_value)

  obj = state[:objects][base_value[:id]]
  return nil unless obj

  ivar_key = "@#{member_name}"
  return obj[:ivars][ivar_key] if obj[:ivars].key?(ivar_key) # attr_accessor / ivar getter

  # fallback: método simples que retorna uma ivar na primeira linha útil (ex: def result; @base; end)
  class_name = obj[:class_name]
  method_info = state[:methods_by_owner]["#{class_name}##{member_name}"]
  return nil unless method_info

  source_lines = state[:sources][method_info[:source_path]] || []
  body_start = method_info[:body_start]
  body_end = [method_info[:end_line] - 1, source_lines.length].min
  first_expr = nil
  line_no = body_start
  while line_no <= body_end
    raw = source_lines[line_no - 1].to_s
    text = raw.sub(/#.*$/, '').strip
    if !text.empty? && text != 'end'
      first_expr = text
      break
    end
    line_no += 1
  end
  return nil unless first_expr

  if (m = /^@([a-z_]\w*)$/.match(first_expr))
    return obj[:ivars]["@#{m[1]}"]
  end

  nil
end # fim do resolve_object_member_value

object_variables_reference = lambda do |object_id| # transforma id em variablesReference estável
  state[:object_var_ref_base] + object_id
end # fim do object_variables_reference

object_id_from_reference = lambda do |variables_reference| # resolve id do objeto a partir do ref
  object_id = variables_reference.to_i - state[:object_var_ref_base]
  return nil if object_id <= 0

  state[:objects].key?(object_id) ? object_id : nil
end # fim do object_id_from_reference

resolve_variable_value = lambda do |token, locals, self_obj_id| # resolve token simples para valor
  key = token.to_s.strip
  return nil if key.empty?
  return key[1..-2] if key.start_with?('"') && key.end_with?('"')
  return key.to_i if /\A-?\d+\z/.match?(key)

  if (member_match = /^([a-z_]\w*)\.([a-zA-Z_]\w*[!?=]?)$/.match(key)) # obj.metodo
    base_name = member_match[1]
    member_name = member_match[2]
    base_value = lookup_local.call(locals, base_name)

    if member_name == 'length' && base_value.respond_to?(:length)
      return base_value.length
    end

    value = resolve_object_member_value.call(base_value, member_name)
    return value unless value.nil?
  end

  if (len_match = /^([a-z_]\w*)\.length$/.match(key)) # suporte a length em arrays/strings
    base = lookup_local.call(locals, len_match[1])
    return base.length if base.respond_to?(:length)
  end

  if (idx_match = /^([a-z_]\w*)\[(.+)\]$/.match(key)) # suporte a indexação simples: arr[i]
    base = lookup_local.call(locals, idx_match[1])
    idx = evaluate_expression.call(idx_match[2], locals, self_obj_id) rescue nil
    return base[idx] if base.respond_to?(:[]) && idx.is_a?(Integer)
  end

  if key.start_with?('@') # ivar
    obj = self_obj_id ? state[:objects][self_obj_id] : nil
    return obj ? obj[:ivars][key] : nil
  end

  lookup_local.call(locals, key)
end # fim do resolve_variable_value

evaluate_expression = lambda do |expression, locals, self_obj_id| # avaliador simples para atribuições
  expr = expression.to_s.strip
  return nil if expr.empty?
  return expr[1..-2] if expr.start_with?('"') && expr.end_with?('"')
  return expr.to_i if /\A-?\d+\z/.match?(expr)
  return true if expr == 'true'
  return false if expr == 'false'

  if (array_match = /\A\[(.*)\]\z/.match(expr)) # array literal simples: [a, 1, "x"]
    body = array_match[1].to_s.strip
    return [] if body.empty?
    parts = []
    current = +''
    bracket_depth = 0
    paren_depth = 0
    in_string = false
    quote_char = nil

    body.each_char do |ch|
      if in_string
        current << ch
        if ch == quote_char
          in_string = false
          quote_char = nil
        end
        next
      end

      if ch == '"' || ch == "'"
        in_string = true
        quote_char = ch
        current << ch
        next
      end

      bracket_depth += 1 if ch == '['
      bracket_depth -= 1 if ch == ']'
      paren_depth += 1 if ch == '('
      paren_depth -= 1 if ch == ')'

      if ch == ',' && bracket_depth.zero? && paren_depth.zero?
        parts << current.strip
        current = +''
      else
        current << ch
      end
    end
    parts << current.strip unless current.strip.empty?

    return parts.map { |part| evaluate_expression.call(part, locals, self_obj_id) }
  end

  if (cmp = /\A(.+)\s*(<=|>=|<|>|==|!=)\s*(.+)\z/.match(expr)) # comparações simples
    left = evaluate_expression.call(cmp[1], locals, self_obj_id)
    right = evaluate_expression.call(cmp[3], locals, self_obj_id)
    return left == right if cmp[2] == '=='
    return left != right if cmp[2] == '!='
    return left < right if cmp[2] == '<' && left && right
    return left > right if cmp[2] == '>' && left && right
    return left <= right if cmp[2] == '<=' && left && right
    return left >= right if cmp[2] == '>=' && left && right
  end

  if (m = /\A(.+)\s*([\+\-\*\/])\s*(.+)\z/.match(expr)) # operação binária simples
    left = resolve_variable_value.call(m[1], locals, self_obj_id)
    right = resolve_variable_value.call(m[3], locals, self_obj_id)
    return left + right if m[2] == '+' && left.is_a?(Numeric) && right.is_a?(Numeric)
    return left - right if m[2] == '-' && left.is_a?(Numeric) && right.is_a?(Numeric)
    return left * right if m[2] == '*' && left.is_a?(Numeric) && right.is_a?(Numeric)
    return nil if m[2] == '/' && left.is_a?(Numeric) && right.is_a?(Numeric) && right.zero?
    return left / right if m[2] == '/' && left.is_a?(Numeric) && right.is_a?(Numeric)
  end

  resolve_variable_value.call(expr, locals, self_obj_id)
end # fim do evaluate_expression

split_arguments = lambda do |args_text| # separa argumentos respeitando [] () e strings
  text = args_text.to_s.strip
  return [] if text.empty?

  args = []
  current = +''
  bracket_depth = 0
  paren_depth = 0
  in_string = false
  quote_char = nil

  text.each_char do |ch|
    if in_string
      current << ch
      if ch == quote_char
        in_string = false
        quote_char = nil
      end
      next
    end

    if ch == '"' || ch == "'"
      in_string = true
      quote_char = ch
      current << ch
      next
    end

    bracket_depth += 1 if ch == '['
    bracket_depth -= 1 if ch == ']'
    paren_depth += 1 if ch == '('
    paren_depth -= 1 if ch == ')'

    if ch == ',' && bracket_depth.zero? && paren_depth.zero?
      args << current.strip
      current = +''
    else
      current << ch
    end
  end

  args << current.strip unless current.strip.empty?
  args
end # fim do split_arguments

parse_arguments = lambda do |args_text, locals, self_obj_id| # parse de argumentos "(a, b, [1,2])"
  split_arguments.call(args_text).map { |raw| evaluate_expression.call(raw, locals, self_obj_id) }
end # fim do parse_arguments

apply_line_effects = lambda do |line_text| # efeitos simples de execução para auxiliar resolução de calls
  text = line_text.to_s.sub(/#.*$/, '').strip
  return if text.empty?

  locals = current_locals.call
  self_obj_id = current_self_object_id.call

  if (compound_local = /^([a-z_]\w*)\s*([\+\-\*\/])=\s*(.+)$/.match(text)) # x += 1
    var_name = compound_local[1]
    op = compound_local[2]
    rhs = evaluate_expression.call(compound_local[3], locals, self_obj_id)
    current = locals[var_name]
    locals[var_name] =
      if op == '+' && current.is_a?(Numeric) && rhs.is_a?(Numeric) then current + rhs
      elsif op == '-' && current.is_a?(Numeric) && rhs.is_a?(Numeric) then current - rhs
      elsif op == '*' && current.is_a?(Numeric) && rhs.is_a?(Numeric) then current * rhs
      elsif op == '/' && current.is_a?(Numeric) && rhs.is_a?(Numeric) && rhs != 0 then current / rhs
      else current
      end
    return
  end

  if (compound_ivar = /^@([a-z_]\w*)\s*([\+\-\*\/])=\s*(.+)$/.match(text)) # @base += value
    obj = self_obj_id ? state[:objects][self_obj_id] : nil
    return unless obj

    key = "@#{compound_ivar[1]}"
    op = compound_ivar[2]
    rhs = evaluate_expression.call(compound_ivar[3], locals, self_obj_id)
    current = obj[:ivars][key]
    obj[:ivars][key] =
      if op == '+' && current.is_a?(Numeric) && rhs.is_a?(Numeric) then current + rhs
      elsif op == '-' && current.is_a?(Numeric) && rhs.is_a?(Numeric) then current - rhs
      elsif op == '*' && current.is_a?(Numeric) && rhs.is_a?(Numeric) then current * rhs
      elsif op == '/' && current.is_a?(Numeric) && rhs.is_a?(Numeric) && rhs != 0 then current / rhs
      else current
      end
    log_line.call("EXECUTE LINHA: #{text}")
    return
  end

  if (append_ivar = /^@([a-z_]\w*)\s*<<\s*(.+)$/.match(text)) # @history << @base
    obj = self_obj_id ? state[:objects][self_obj_id] : nil
    return unless obj

    key = "@#{append_ivar[1]}"
    value = evaluate_expression.call(append_ivar[2], locals, self_obj_id)
    current = obj[:ivars][key]
    current = [] if current.nil?
    current = [current] unless current.is_a?(Array)
    current << value
    obj[:ivars][key] = current
    log_line.call("EXECUTE LINHA: #{text}")
    return
  end

  if (assign_ivar = /^@([a-z_]\w*)\s*=\s*(.+)$/.match(text)) # @base = base
    obj = self_obj_id ? state[:objects][self_obj_id] : nil
    return unless obj

    key = "@#{assign_ivar[1]}"
    value = evaluate_expression.call(assign_ivar[2], locals, self_obj_id)
    obj[:ivars][key] = value
    log_line.call("EXECUTE LINHA: #{text}")
    return
  end

  if (append_local = /^([a-z_]\w*)\s*<<\s*(.+)$/.match(text)) # arr << item
    var_name = append_local[1]
    value = evaluate_expression.call(append_local[2], locals, self_obj_id)
    current = locals[var_name]
    current = [] if current.nil?
    current = [current] unless current.is_a?(Array)
    current << value
    locals[var_name] = current
    return
  end

  if (assign_local = /^([a-z_]\w*)\s*=\s*(.+)$/.match(text)) # x = expr
    locals[assign_local[1]] = evaluate_expression.call(assign_local[2], locals, self_obj_id)
    return
  end

  # Leitura de ivar em expressão sem atribuição (ex: @base) não muda estado
end # fim do apply_line_effects

resolve_call_target = lambda do |line_text| # resolve alvo de call para stepIn/continue
  text = line_text.to_s.sub(/#.*$/, '').strip
  return nil if text.empty?

  locals = current_locals.call

  # Construtor: Classe.new(...) entra em Classe#initialize
  if (ctor = /([A-Z]\w*(?:::[A-Z]\w*)*)\.new\s*(?:\(|$)/.match(text))
    owner = ctor[1]
    initialize_target = state[:methods_by_owner]["#{owner}#initialize"]
    return initialize_target if initialize_target
  end

  # Prioriza chamadas com receiver em qualquer ponto da expressão (ex: puts obj.teste)
  if (recv_any = /([a-z_]\w*)\.([a-zA-Z_]\w*[!?=]?)/.match(text))
    var_name = recv_any[1]
    method_name = recv_any[2]
    owner_value = locals[var_name]
    owner = if is_object_ref.call(owner_value)
      state[:objects].dig(owner_value[:id], :class_name)
    else
      owner_value
    end
    return state[:methods_by_owner]["#{owner}##{method_name}"] if owner
    list = state[:methods_by_name][method_name]
    return list.first if list && !list.empty?
  end

  # Encadeado com construtor: Classe.new.metodo(...)
  if (chain = /([A-Z]\w*(?:::[A-Z]\w*)*)\.new\.([a-zA-Z_]\w*[!?=]?)\s*(?:\(|$)/.match(text))
    owner = chain[1]
    method_name = chain[2]
    target = state[:methods_by_owner]["#{owner}##{method_name}"]
    return target if target
  end

  # Chamada com receiver variável: obj.metodo(...)
  if (recv = /^([a-z_]\w*)\.([a-zA-Z_]\w*[!?=]?)\s*(?:\(|$)/.match(text))
    var_name = recv[1]
    method_name = recv[2]
    owner_value = locals[var_name]
    owner = if is_object_ref.call(owner_value)
      state[:objects].dig(owner_value[:id], :class_name)
    else
      owner_value
    end
    return state[:methods_by_owner]["#{owner}##{method_name}"] if owner
    list = state[:methods_by_name][method_name]
    return list.first if list && !list.empty?
  end

  # Chamada sem receiver: metodo(...)
  unless text.match?(/^[a-z_]\w*\s*=/) # evita tratar lado esquerdo de assignment como chamada
    if (plain = /^([a-zA-Z_]\w*[!?=]?)\s*(?:\(|$)/.match(text))
      list = state[:methods_by_name][plain[1]]
      return list.find { |m| m[:owner_class].nil? } || (list && list.first)
    end
  end

  nil
end # fim do resolve_call_target

line_executable = lambda do |line_no, allow_method_body| # valida se linha é executável no contexto
  source_path = state[:current_source_path] || state[:program_path]
  source_lines = state[:sources][source_path] || state[:lines]
  return false if line_no < 1 || line_no > source_lines.length

  text = (source_lines[line_no - 1] || '').strip
  return false if text.empty? || text.start_with?('#') # ignora vazio/comentário
  return false if text.start_with?('class ') || text.start_with?('def ') # class/def não executam no runtime
  return false if text == 'end' # ignora fechamento puro
  if !allow_method_body &&
      source_path == state[:main_program_path] &&
      (state[:line_in_method_body].include?(line_no) ||
      state[:line_in_class_body].include?(line_no) ||
      state[:non_exec_top_level_lines].include?(line_no))
    return false # top-level não executa corpo de método/classe nem linhas estruturais
  end

  true
end # fim do line_executable

next_executable_line = lambda do |start_line, allow_method_body, max_line = nil| # busca próxima linha executável
  source_path = state[:current_source_path] || state[:program_path]
  source_lines = state[:sources][source_path] || state[:lines]
  upper = max_line || source_lines.length
  line_no = start_line
  while line_no <= upper
    return line_no if line_executable.call(line_no, allow_method_body)
    line_no += 1
  end
  nil
end # fim do next_executable_line

active_for_loop_for_line = lambda do |line_no, call_depth, source_path| # encontra loop for ativo no contexto atual
  state[:active_for_loops].reverse.find do |loop|
    loop[:call_depth] == call_depth &&
      loop[:source_path] == source_path &&
      line_no >= loop[:body_start] &&
      line_no <= (loop[:end_line] - 1)
  end
end # fim do active_for_loop_for_line

active_for_loop_end_for_line = lambda do |line_no, call_depth, source_path| # encontra loop for ativo na linha end
  state[:active_for_loops].reverse.find do |loop|
    loop[:call_depth] == call_depth &&
      loop[:source_path] == source_path &&
      line_no == loop[:end_line]
  end
end # fim do active_for_loop_end_for_line

active_loop_for_line = lambda do |line_no, call_depth, source_path| # loop ativo (for/each/while) na linha de corpo
  loops = state[:active_for_loops] + state[:active_each_loops] + state[:active_while_loops]
  matches = loops.select do |loop|
    loop[:call_depth] == call_depth &&
      loop[:source_path] == source_path &&
      line_no >= loop[:body_start] &&
      line_no <= (loop[:end_line] - 1)
  end
  if matches.empty? # fallback quando source_path diverge
    matches = loops.select do |loop|
      loop[:call_depth] == call_depth &&
        line_no >= loop[:body_start] &&
        line_no <= (loop[:end_line] - 1)
    end
  end
  matches.max_by { |loop| loop[:start_line] }
end # fim do active_loop_for_line

active_loop_end_for_line = lambda do |line_no, call_depth, source_path| # loop ativo (for/each/while) na linha end
  loops = state[:active_for_loops] + state[:active_each_loops] + state[:active_while_loops]
  matches = loops.select do |loop|
    loop[:call_depth] == call_depth &&
      loop[:source_path] == source_path &&
      line_no == loop[:end_line]
  end
  if matches.empty? # fallback quando source_path diverge
    matches = loops.select do |loop|
      loop[:call_depth] == call_depth &&
        line_no == loop[:end_line]
    end
  end
  matches.max_by { |loop| loop[:start_line] }
end # fim do active_loop_end_for_line

advance_execution = lambda do |enter_calls| # avança execução respeitando contexto (top-level/método)
  return false if state[:program_path].nil? || state[:terminated]

  current = state[:current_line]
  frame = state[:call_stack].last # frame atual do método (se houver)
  allow_method_body = !frame.nil?
  current_depth = state[:call_stack].length
  current_locals_map = current_locals.call
  current_self_id = current_self_object_id.call
  current_source = state[:current_source_path] || state[:program_path]

  # Se já está no "end" do método, o próximo passo é retornar ao caller
  if frame && current == frame[:end_line]
    finished = state[:call_stack].pop
    depth = state[:call_stack].length
    state[:active_for_loops].reject! { |loop| loop[:call_depth] > depth } # limpa loops do frame encerrado
    state[:active_each_loops].reject! { |loop| loop[:call_depth] > depth } # limpa loops each do frame encerrado
    state[:active_while_loops].reject! { |loop| loop[:call_depth] > depth } # limpa loops while do frame encerrado
    if finished[:return_line]
      state[:current_source_path] = finished[:return_source_path] || state[:main_program_path]
      state[:current_line] = finished[:return_line]
      return true
    end

    # Sem return_line explícita: volta para o fim do frame chamador
    caller_frame = state[:call_stack].last
    if caller_frame
      state[:current_source_path] = caller_frame[:source_path] || caller_frame[:return_source_path] || state[:main_program_path]
      state[:current_line] = caller_frame[:return_line] || caller_frame[:end_line]
      return true
    end

    send_terminated.call
    return false
  end

  # Ao parar no end de loop, decide próxima iteração/saída
  if (loop_end_frame = active_loop_end_for_line.call(current, current_depth, current_source))
    log_line.call("LOOP END HIT kind=#{loop_end_frame[:kind]} L#{loop_end_frame[:end_line]} idx=#{loop_end_frame[:index].inspect} source=#{current_source}")
    if %w[for each].include?(loop_end_frame[:kind])
      if loop_end_frame[:index] + 1 < loop_end_frame[:values].length
        loop_end_frame[:index] += 1
        current_locals_map[loop_end_frame[:var_name]] = loop_end_frame[:values][loop_end_frame[:index]]
        log_line.call("LOOP NEXT ITER kind=#{loop_end_frame[:kind]} idx=#{loop_end_frame[:index]} value=#{current_locals_map[loop_end_frame[:var_name]].inspect}")
        restart_line = next_executable_line.call(loop_end_frame[:body_start], allow_method_body, loop_end_frame[:end_line] - 1)
        if restart_line
          state[:current_line] = restart_line
          return true
        end
      end
    elsif loop_end_frame[:kind] == 'while'
      condition = evaluate_expression.call(loop_end_frame[:condition_expr], current_locals_map, current_self_id)
      if condition
        restart_line = next_executable_line.call(loop_end_frame[:body_start], allow_method_body, loop_end_frame[:end_line] - 1)
        if restart_line
          state[:current_line] = restart_line
          return true
        end
      end
    end

    state[:active_for_loops].delete(loop_end_frame)
    state[:active_each_loops].delete(loop_end_frame)
    state[:active_while_loops].delete(loop_end_frame)
    after_loop = next_executable_line.call(loop_end_frame[:end_line] + 1, allow_method_body, frame ? frame[:end_line] - 1 : nil)
    if after_loop
      state[:current_line] = after_loop
      return true
    end
  end

  # stepIn/continue: se linha atual chama método conhecido, entra no corpo
  current_lines = state[:sources][state[:current_source_path]] || state[:lines]
  line_text = current_lines[current - 1] || ''

  # Suporte a loop for: entra no corpo e itera até o fim
  if (loop_info = state[:for_loops_by_start]["#{current_source}|#{current}"])
    iterable_value = evaluate_expression.call(loop_info[:iterable_expr], current_locals_map, current_self_id)
    values = if iterable_value.nil?
      []
    elsif iterable_value.is_a?(Array)
      iterable_value
    elsif iterable_value.respond_to?(:to_a)
      iterable_value.to_a
    else
      [iterable_value]
    end

    if values.empty? # loop vazio: pula para a linha após o end
      next_after_loop = next_executable_line.call(loop_info[:end_line] + 1, allow_method_body, frame ? frame[:end_line] - 1 : nil)
      if next_after_loop
        state[:current_line] = next_after_loop
        return true
      end
      state[:current_line] = frame[:end_line] if frame
      send_terminated.call unless frame
      return !frame.nil?
    end

    loop_frame = {
      kind: 'for',
      start_line: loop_info[:start_line],
      body_start: loop_info[:body_start],
      end_line: loop_info[:end_line],
      source_path: current_source,
      var_name: loop_info[:var_name],
      values: values,
      index: 0,
      call_depth: current_depth
    }
    log_line.call("LOOP FOR START L#{loop_frame[:start_line]} values=#{loop_frame[:values].inspect}")
    state[:active_for_loops] << loop_frame
    current_locals_map[loop_frame[:var_name]] = loop_frame[:values][0]

    first_body_line = next_executable_line.call(loop_frame[:body_start], allow_method_body, loop_frame[:end_line] - 1)
    if first_body_line
      state[:current_line] = first_body_line
      return true
    end

    # Corpo vazio: encerra loop imediatamente
    state[:active_for_loops].delete(loop_frame)
    next_after_loop = next_executable_line.call(loop_frame[:end_line] + 1, allow_method_body, frame ? frame[:end_line] - 1 : nil)
    if next_after_loop
      state[:current_line] = next_after_loop
      return true
    end
    state[:current_line] = frame[:end_line] if frame
    send_terminated.call unless frame
    return !frame.nil?
  end

  # Suporte a loop each: entra no corpo e itera até o fim
  if (loop_info = state[:each_loops_by_start]["#{current_source}|#{current}"])
    iterable_value = evaluate_expression.call(loop_info[:iterable_expr], current_locals_map, current_self_id)
    values = if iterable_value.nil?
      []
    elsif iterable_value.is_a?(Array)
      iterable_value
    elsif iterable_value.respond_to?(:to_a)
      iterable_value.to_a
    else
      [iterable_value]
    end

    if values.empty?
      next_after_loop = next_executable_line.call(loop_info[:end_line] + 1, allow_method_body, frame ? frame[:end_line] - 1 : nil)
      if next_after_loop
        state[:current_line] = next_after_loop
        return true
      end
      state[:current_line] = frame[:end_line] if frame
      send_terminated.call unless frame
      return !frame.nil?
    end

    loop_frame = {
      kind: 'each',
      start_line: loop_info[:start_line],
      body_start: loop_info[:body_start],
      end_line: loop_info[:end_line],
      source_path: current_source,
      var_name: loop_info[:var_name],
      values: values,
      index: 0,
      call_depth: current_depth
    }
    log_line.call("LOOP EACH START L#{loop_frame[:start_line]} values=#{loop_frame[:values].inspect}")
    state[:active_each_loops] << loop_frame
    current_locals_map[loop_frame[:var_name]] = loop_frame[:values][0]

    first_body_line = next_executable_line.call(loop_frame[:body_start], allow_method_body, loop_frame[:end_line] - 1)
    if first_body_line
      state[:current_line] = first_body_line
      return true
    end

    state[:active_each_loops].delete(loop_frame)
    next_after_loop = next_executable_line.call(loop_frame[:end_line] + 1, allow_method_body, frame ? frame[:end_line] - 1 : nil)
    if next_after_loop
      state[:current_line] = next_after_loop
      return true
    end
    state[:current_line] = frame[:end_line] if frame
    send_terminated.call unless frame
    return !frame.nil?
  end

  # Suporte a loop while: avalia condição para entrar/sair
  if (loop_info = state[:while_loops_by_start]["#{current_source}|#{current}"])
    condition = evaluate_expression.call(loop_info[:condition_expr], current_locals_map, current_self_id)
    log_line.call("LOOP WHILE CHECK L#{loop_info[:start_line]} condition=#{condition.inspect}")
    unless condition
      next_after_loop = next_executable_line.call(loop_info[:end_line] + 1, allow_method_body, frame ? frame[:end_line] - 1 : nil)
      if next_after_loop
        state[:current_line] = next_after_loop
        return true
      end
      state[:current_line] = frame[:end_line] if frame
      send_terminated.call unless frame
      return !frame.nil?
    end

    loop_frame = state[:active_while_loops].find do |loop|
      loop[:call_depth] == current_depth &&
        loop[:start_line] == loop_info[:start_line] &&
        loop[:source_path] == current_source
    end
    unless loop_frame
      loop_frame = {
        kind: 'while',
        start_line: loop_info[:start_line],
        body_start: loop_info[:body_start],
        end_line: loop_info[:end_line],
        source_path: current_source,
        condition_expr: loop_info[:condition_expr],
        call_depth: current_depth
      }
      state[:active_while_loops] << loop_frame
    end

    first_body_line = next_executable_line.call(loop_frame[:body_start], allow_method_body, loop_frame[:end_line] - 1)
    if first_body_line
      state[:current_line] = first_body_line
      return true
    end

    state[:active_while_loops].delete(loop_frame)
    next_after_loop = next_executable_line.call(loop_frame[:end_line] + 1, allow_method_body, frame ? frame[:end_line] - 1 : nil)
    if next_after_loop
      state[:current_line] = next_after_loop
      return true
    end
    state[:current_line] = frame[:end_line] if frame
    send_terminated.call unless frame
    return !frame.nil?
  end

  called_range = resolve_call_target.call(line_text)
  should_enter_called_method = called_range && (enter_calls || method_has_breakpoint.call(called_range))

  if should_enter_called_method
    caller_locals = current_locals.call # locals de quem fez a chamada
    caller_self_object_id = current_self_object_id.call
    call_self_object_id = nil # self do método chamado
    arg_values = [] # argumentos avaliados
    call_text = line_text.to_s.sub(/#.*$/, '').strip # normaliza chamada (remove indent/comentário)

    if (ctor_match = /^(?:([a-z_]\w*)\s*=\s*)?([A-Z]\w*(?:::[A-Z]\w*)*)\.new\s*(?:\((.*)\))?/.match(call_text))
      assign_var = ctor_match[1]
      class_name = ctor_match[2]
      args_text = ctor_match[3]

      object_id = state[:next_object_id]
      state[:next_object_id] += 1
      state[:objects][object_id] = { class_name: class_name, ivars: {} }
      caller_locals[assign_var] = object_ref.call(object_id) if assign_var

      call_self_object_id = object_id
      arg_values = parse_arguments.call(args_text, caller_locals, caller_self_object_id)
    elsif (recv_match = /([a-z_]\w*)\.([a-zA-Z_]\w*[!?=]?)\s*(?:\((.*)\))?/.match(call_text))
      receiver_value = caller_locals[recv_match[1]]
      call_self_object_id = receiver_value[:id] if is_object_ref.call(receiver_value)
      arg_values = parse_arguments.call(recv_match[3], caller_locals, caller_self_object_id)
    elsif (plain_match = /^([a-zA-Z_]\w*[!?=]?)\s*(?:\((.*)\))?/.match(call_text))
      call_self_object_id = caller_self_object_id
      arg_values = parse_arguments.call(plain_match[2], caller_locals, caller_self_object_id)
    end

    frame_locals = {}
    (called_range[:params] || []).each_with_index do |param_name, idx|
      frame_locals[param_name] = arg_values[idx]
    end

    # Chamada dentro de loop deve retornar ao end do loop (não pular para depois dele)
    loop_context = active_loop_for_line.call(current, current_depth, current_source)
    max_return_line = frame ? frame[:end_line] : nil
    if loop_context
      loop_body_end = loop_context[:end_line] - 1
      max_return_line = [max_return_line, loop_body_end].compact.min
    end

    return_line = next_executable_line.call(current + 1, allow_method_body, max_return_line)
    return_line = loop_context[:end_line] if return_line.nil? && loop_context
    state[:call_stack] << {
      method_name: called_range[:name],
      class_name: called_range[:owner_class],
      end_line: called_range[:end_line],
      return_line: return_line,
      locals: frame_locals,
      self_object_id: call_self_object_id,
      source_path: called_range[:source_path] || state[:program_path],
      return_source_path: state[:current_source_path]
    }

    state[:current_source_path] = called_range[:source_path] || state[:program_path]

    body_end = called_range[:end_line] - 1 # ignora linha do "end"
    first_body_line = next_executable_line.call(called_range[:body_start], true, body_end)
    if first_body_line
      state[:current_line] = first_body_line
      return true
    end

    # Método vazio: retorna imediatamente para caller
    finished = state[:call_stack].pop
    if finished[:return_line]
      state[:current_source_path] = finished[:return_source_path] || state[:main_program_path]
      state[:current_line] = finished[:return_line]
      return true
    end

    # Sem linha de retorno: posiciona no end do chamador
    caller_frame = state[:call_stack].last
    if caller_frame
      state[:current_source_path] = caller_frame[:source_path] || state[:main_program_path]
      state[:current_line] = caller_frame[:end_line]
      return true
    end

    send_terminated.call
    return false
  end

  # A linha atual foi executada sem entrar em nova chamada
  apply_line_effects.call(line_text)

  # Avanço normal (step over) dentro do frame atual
  max_line = frame ? frame[:end_line] - 1 : nil
  loop_frame = active_loop_for_line.call(current, current_depth, current_source)
  max_line = [max_line, loop_frame[:end_line] - 1].compact.min if loop_frame
  candidate = next_executable_line.call(current + 1, allow_method_body, max_line)
  if candidate
    state[:current_line] = candidate
    return true
  end

  # Fim da iteração de loop: para no end antes de iterar/sair
  if loop_frame
    state[:current_line] = loop_frame[:end_line]
    return true
  end

  # Sem próxima linha executável no frame: para no "end" antes de retornar
  if frame
    state[:current_line] = frame[:end_line]
    return true
  end

  send_terminated.call
  false
end # fim do advance_execution

step_one = lambda do # step over de uma linha executável
  return if state[:program_path].nil? || state[:terminated]

  # Semântica de Step Over:
  # - executa chamadas da linha atual por baixo dos panos
  # - para em breakpoint interno, se existir
  # - sem breakpoint, para na próxima linha do mesmo frame
  current = state[:current_line]
  frame = state[:call_stack].last
  allow_method_body = !frame.nil?
  current_lines = state[:sources][state[:current_source_path]] || state[:lines]
  line_text = current_lines[current - 1] || ''
  called_range = resolve_call_target.call(line_text)

  if called_range
    target_depth = state[:call_stack].length
    current_source = state[:current_source_path] || state[:program_path]
    loop_context = active_loop_for_line.call(current, target_depth, current_source)
    max_target_line = frame ? frame[:end_line] : nil
    if loop_context
      loop_body_end = loop_context[:end_line] - 1
      max_target_line = [max_target_line, loop_body_end].compact.min
    end
    target_line = next_executable_line.call(current + 1, allow_method_body, max_target_line)

    moved = advance_execution.call(true)
    while moved && !state[:terminated]
      if line_has_breakpoint.call(state[:current_line])
        send_stopped.call('breakpoint')
        return
      end

      reached_target = state[:call_stack].length == target_depth && (!target_line.nil? && state[:current_line] == target_line)
      returned_to_same_frame = target_line.nil? && state[:call_stack].length == target_depth
      returned_to_caller = target_line.nil? && state[:call_stack].length < target_depth
      if reached_target
        send_stopped.call('step')
        return
      end
      if returned_to_same_frame
        send_stopped.call('step')
        return
      end
      if returned_to_caller
        send_stopped.call('step')
        return
      end

      moved = advance_execution.call(true)
    end

    return
  end

  moved = advance_execution.call(false)

  if moved
    reason = line_has_breakpoint.call(state[:current_line]) ? 'breakpoint' : 'step'
    send_stopped.call(reason)
  end
end # fim do step_one

step_in_execution = lambda do # stepIn com tentativa de entrar em método
  return if state[:program_path].nil? || state[:terminated] # guarda estado inválido

  moved = advance_execution.call(true)

  if moved
    reason = line_has_breakpoint.call(state[:current_line]) ? 'breakpoint' : 'step'
    send_stopped.call(reason)
  end
end # fim do step_in_execution

handle_request = lambda do |request| # trata request DAP
  case request['command'] # dispatch por comando
  when 'initialize' # initialize
    dap_state[:initialized] = true # marca DAP como inicializado
    send_response.call(request, { # capabilities
      supportsConfigurationDoneRequest: true, # suporta configurationDone
      supportsTerminateRequest: true, # suporta terminate
      supportsSetVariable: false, # não suporta setVariable
      supportsStepBack: false, # não suporta stepBack
      supportsDataBreakpoints: false, # não suporta data breakpoints
      supportsEvaluateForHovers: false # não suporta hover
    }) # envia capabilities
    send_event.call('initialized') # emite initialized
  when 'launch' # launch
    program = request.dig('arguments', 'program') # pega caminho do programa
    unless program # se faltou
      send_response.call(request, {}, false, 'Missing "program" path') # erro
      next # pula
    end # fim do unless

    state[:program_path] = program # grava caminho
    state[:stop_on_entry] = request.dig('arguments', 'stopOnEntry') != false # define stop_on_entry
    state[:terminated] = false # reseta terminated

    begin # tenta carregar
      load_program.call(program) # carrega o programa
    rescue => e # se falhar
      send_response.call(request, {}, false, "Cannot read program: #{e.message}") # erro
      next # pula
    end # fim do rescue

    send_response.call(request, {}) # responde launch
  when 'setBreakpoints' # setBreakpoints
    source = request.dig('arguments', 'source') || {} # pega source
    path_key = source['path'] || state[:program_path] # resolve path
    requested = request.dig('arguments', 'breakpoints') || [] # breakpoints pedidos
    source_lines = state[:sources][path_key] || state[:lines]

    verified = [] # lista verificada
    bp_set = Set.new # set de breakpoints válidos

    requested.each do |bp| # percorre pedidos
      line = bp['line'] # linha do breakpoint
      ok = line.is_a?(Integer) && line >= 1 && line <= source_lines.length # valida linha
      bp_set.add(line) if ok # adiciona se ok
      verified << { verified: ok, line: line } # adiciona retorno
    end # fim do loop

    state[:breakpoints][path_key] = bp_set if path_key # salva breakpoints
    send_response.call(request, { breakpoints: verified }) # responde
  when 'setExceptionBreakpoints' # setExceptionBreakpoints
    send_response.call(request, {}) # responde vazio
  when 'configurationDone' # configurationDone
    send_response.call(request, {}) # responde
    emit_debug_mapping.call # sempre mapeia primeiro ao iniciar o debug
    # Comportamento estilo Rails: só para quando atingir breakpoint.
    # Sem breakpoint, executa do início ao fim e termina.
    continue_execution.call(true)
  when 'threads' # threads
    send_response.call(request, { threads: [{ id: 1, name: 'thread-1' }] }) # thread única
  when 'stackTrace' # stackTrace
    source_path = state[:current_source_path] || state[:program_path] || '' # caminho do source
    frame = state[:call_stack].last # frame atual
    frame_name = if frame # nome do frame ativo
      frame[:class_name] ? "#{frame[:class_name]}##{frame[:method_name]}" : frame[:method_name]
    else
      'main'
    end
    send_response.call(request, { # responde stack
      stackFrames: [ # frames
        { # frame único
          id: 1, # id do frame
          name: frame_name, # nome do frame
          line: state[:current_line], # linha atual
          column: 1, # coluna
          source: { # info do source
            name: source_path.empty? ? 'program' : File.basename(source_path), # nome do source
            path: source_path # caminho do source
          } # fim do source
        } # fim do frame
      ], # fim dos frames
      totalFrames: 1 # total
    }) # responde stack
  when 'scopes' # scopes
    send_response.call(request, { # responde scopes
      scopes: [ # lista
        { name: 'Locals', variablesReference: 1, expensive: false }, # locals frame atual
        { name: 'Globals', variablesReference: 2, expensive: false } # variáveis do top-level
      ] # fim da lista
    }) # responde scopes
  when 'variables' # variables
    variables_ref = request.dig('arguments', 'variablesReference').to_i
    if variables_ref == 1 # locals
      current_lines = state[:sources][state[:current_source_path]] || state[:lines]
      line_text = current_lines[state[:current_line] - 1] || '' # texto da linha atual
      frame = state[:call_stack].last
      locals = current_locals.call
      vars = [
        { name: 'line', value: state[:current_line].to_s, variablesReference: 0 },
        { name: 'text', value: line_text.inspect, variablesReference: 0 }
      ]

      locals.keys.map(&:to_s).uniq.sort.each do |name|
        value = locals[name]
        value = locals[name.to_sym] if value.nil? && locals.respond_to?(:key?) && locals.key?(name.to_sym)
        child_ref = is_object_ref.call(value) ? object_variables_reference.call(value[:id]) : 0
        vars << { name: name, value: format_value.call(value), variablesReference: child_ref }
      end

      if frame && frame[:self_object_id]
        obj = state[:objects][frame[:self_object_id]]
        if obj
          vars << {
            name: 'self',
            value: "#<#{obj[:class_name]}:#{frame[:self_object_id]}>",
            variablesReference: object_variables_reference.call(frame[:self_object_id])
          }
          obj[:ivars].keys.sort.each do |ivar|
            vars << { name: ivar, value: format_value.call(obj[:ivars][ivar]), variablesReference: 0 }
          end
        end
      end

      send_response.call(request, { # responde variables
        variables: vars # lista completa de variáveis mapeadas
      }) # responde
    elsif variables_ref == 2 # globals/top-level
      vars = []
      state[:top_locals].keys.map(&:to_s).uniq.sort.each do |name|
        value = state[:top_locals][name]
        value = state[:top_locals][name.to_sym] if value.nil? && state[:top_locals].respond_to?(:key?) && state[:top_locals].key?(name.to_sym)
        child_ref = is_object_ref.call(value) ? object_variables_reference.call(value[:id]) : 0
        vars << { name: name, value: format_value.call(value), variablesReference: child_ref }
      end
      send_response.call(request, { variables: vars })
    elsif (object_id = object_id_from_reference.call(variables_ref)) # expansão de objeto
      obj = state[:objects][object_id]
      vars = []
      if obj
        vars << { name: '__class__', value: obj[:class_name], variablesReference: 0 }
        obj[:ivars].keys.sort.each do |ivar|
          ivar_value = obj[:ivars][ivar]
          child_ref = is_object_ref.call(ivar_value) ? object_variables_reference.call(ivar_value[:id]) : 0
          vars << { name: ivar, value: format_value.call(ivar_value), variablesReference: child_ref }
        end
      end
      send_response.call(request, { variables: vars })
    else # outro reference
      send_response.call(request, { variables: [] }) # responde vazio
    end # fim do if
  when 'continue' # continue
    send_response.call(request, { allThreadsContinued: true }) # responde
    continue_execution.call(false) # continua
  when 'next' # step over
    send_response.call(request, {}) # responde
    step_one.call # step
  when 'stepIn' # step into
    send_response.call(request, {}) # responde
    step_in_execution.call # tenta entrar no método chamado
  when 'stepOut' # stepOut
    send_response.call(request, {}) # responde
    finished = state[:call_stack].pop # tenta retorno para caller
    if finished && finished[:return_line]
      state[:current_source_path] = finished[:return_source_path] || state[:main_program_path]
      state[:current_line] = finished[:return_line] # volta para linha após a chamada
      send_stopped.call('step') # mantém sessão ativa
    elsif state[:call_stack].last # sem return_line: cai no end do chamador
      caller_frame = state[:call_stack].last
      state[:current_source_path] = caller_frame[:source_path] || state[:main_program_path]
      state[:current_line] = caller_frame[:end_line]
      send_stopped.call('step')
    else
      state[:current_line] = state[:lines].length # fallback sem stack
      send_terminated.call # termina
    end
  when 'pause' # pause
    send_response.call(request, {}) # responde
    send_stopped.call('pause') # emite stopped
  when 'terminate', 'disconnect' # terminate/disconnect
    send_response.call(request, {}) # responde
    send_terminated.call # termina
  else # comando desconhecido
    send_response.call(request, {}) # resposta default
  end # fim do case
end # fim do handle_request

handle_message = lambda do |msg| # trata mensagem
  return unless msg['type'] == 'request' # ignora não-request

  begin
    handle_request.call(msg) # delega request
  rescue => e
    log_line.call("ERRO AO PROCESSAR REQUEST #{msg['command']}: #{e.class} - #{e.message}")
    send_response.call(msg, {}, false, "#{e.class}: #{e.message}") if msg['seq'] && msg['command']
  end
end # fim do handle_message

parse_buffer = lambda do # faz parse do buffer
  loop do # continua enquanto houver mensagem completa
    header_end = buffer.index("\r\n\r\n") # acha fim do header
    break unless header_end # sai se não há header completo

    header = buffer.byteslice(0, header_end) # extrai header
    match = /Content-Length:\s*(\d+)/i.match(header) # pega content-length
    unless match # se não achou length
      buffer = buffer.byteslice(header_end + 4, buffer.bytesize - header_end - 4) || '' # descarta header
      next # continua
    end # fim do unless

    length = match[1].to_i # tamanho do body
    total = header_end + 4 + length # tamanho total
    break if buffer.bytesize < total # espera mensagem completa

    body = buffer.byteslice(header_end + 4, length) # extrai body
    buffer = buffer.byteslice(total, buffer.bytesize - total) || '' # remove do buffer

    begin # tenta parsear
      msg = JSON.parse(body) # parse JSON
      log_line.call("DAP ENTRADA: #{JSON.generate(msg)}") # log apenas do JSON de entrada
      handle_message.call(msg) # trata mensagem
    rescue JSON::ParserError => e # erro de parse
      log_line.call("ERRO AO PARSEAR JSON: #{e.message}") # log do erro
    end # fim do begin/rescue
  end # fim do loop
end # fim do parse_buffer

begin # início do loop principal
  while (chunk = $stdin.readpartial(8192)) # lê do stdin
    buffer << chunk # adiciona ao buffer
    parse_buffer.call # parseia mensagens
  end # fim do while
rescue EOFError # EOF
  # Exit cleanly
end # fim do loop principal
