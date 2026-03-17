require_relative "test_logger"

def run_enumerable_examples
  puts "\n=== Enumerable examples ==="
  logger = TestLogger.new(File.join(__dir__, "..", ".ruby-dap-logs", "enumerable_tests.log"))
  logger.write("==== start run_enumerable_examples ====")
  log = lambda do |message|
    line = "[ENUM LOG] #{message}"
    puts line
    logger.write(line)
  end
  assert_total = 0
  assert_failed = 0
  assert_equal = lambda do |name, actual, expected|
    assert_total += 1
    if actual == expected
      ok_line = "[OK] #{name}"
      puts ok_line
      logger.write(ok_line)
    else
      assert_failed += 1
      err_line = "[ERRO] #{name} esperado=#{expected.inspect} obtido=#{actual.inspect}"
      puts err_line
      logger.write(err_line)
    end
  end

  numbers = [1, 2, 3, 4, 5]
  pairs = [[:a, 1], [:b, 2], [:c, 3]]
  words = %w[ana bob carol davi]
  nested = [1, [2, [3]], 4]
  with_nil = [1, nil, 2, nil, 3]
  log.call("base numbers=#{numbers.inspect} words=#{words.inspect}")

  results = {}

  # each family
  log.call("starting each family")
  each_direct = []
  numbers.each do |n|
    doubled = n * 2
    log.call("each {} n=#{n} doubled=#{doubled}")
    each_direct << doubled
  end

  each_do = []
  numbers.each do |n|
    plus_ten = n + 10
    log.call("each do n=#{n} plus_ten=#{plus_ten}")
    each_do << plus_ten
  end

  results[:each_with_index] = []
  numbers.each_with_index do |n, idx|
    results[:each_with_index] << "#{idx}:#{n}"
  end
  results[:each_entry] = numbers.each_entry.to_a
  results[:each_slice] = numbers.each_slice(2).to_a
  results[:each_cons] = numbers.each_cons(3).to_a
  results[:each_with_object] = numbers.each_with_object({}) { |n, h| h[n] = n * n }
  results[:each_direct] = each_direct
  results[:each_do] = each_do

  # map family
  log.call("starting map family")
  results[:map] = numbers.map { |n| n * 10 }
  mutable_map = numbers.dup
  mutable_map.map! do |n|
    mapped = n * 3
    log.call("map! n=#{n} mapped=#{mapped}")
    mapped
  end
  results[:map_bang] = mutable_map

  mutable_collect = numbers.dup
  results[:collect] = numbers.collect { |n| n + 1 }
  mutable_collect.collect! do |n|
    mapped = n + 2
    log.call("collect! n=#{n} mapped=#{mapped}")
    mapped
  end
  results[:collect_bang] = mutable_collect
  results[:flat_map] = [[1, 2], [3], [4, 5]].flat_map { |arr| arr }
  results[:filter_map] = numbers.filter_map { |n| n * 100 if n.odd? }

  # select/filter family
  log.call("starting select/filter family")
  results[:select] = numbers.select { |n| n > 2 }
  results[:filter] = numbers.filter { |n| n.even? }
  results[:reject] = numbers.reject { |n| n < 3 }
  results[:grep] = words.grep(/a/)
  results[:grep_v] = words.grep_v(/a/)

  # find family
  log.call("starting find family")
  results[:find] = numbers.find { |n| n > 3 }
  results[:detect] = numbers.detect { |n| n > 3 }
  results[:find_all] = numbers.find_all { |n| n.odd? }
  results[:find_index] = numbers.find_index { |n| n == 4 }

  # predicate family
  log.call("starting predicate family")
  results[:any] = numbers.any? { |n| n > 4 }
  results[:all] = numbers.all? { |n| n.positive? }
  results[:none] = numbers.none? { |n| n < 0 }
  results[:one] = numbers.one? { |n| n == 3 }
  results[:include] = numbers.include?(3)
  results[:member] = numbers.member?(3)

  # size/count family
  log.call("starting size/count family")
  results[:count] = numbers.count(&:odd?)
  results[:size] = numbers.size
  results[:length] = numbers.length
  results[:tally] = [1, 1, 2, 2, 2, 3].tally

  # reduce/inject
  log.call("starting reduce/inject family")
  results[:reduce] = numbers.reduce(0) { |acc, n| acc + n }
  results[:inject] = numbers.inject(1) { |acc, n| acc * n }

  # grouping/splitting
  log.call("starting grouping/splitting family")
  results[:group_by] = words.group_by(&:length)
  results[:partition] = numbers.partition(&:even?)
  results[:chunk] = [1, 1, 2, 2, 3, 1].chunk { |n| n }.to_a
  results[:chunk_while] = [1, 2, 3, 7, 8, 20].chunk_while { |a, b| b == a + 1 }.to_a
  results[:slice_when] = [1, 2, 4, 5, 9].slice_when { |a, b| (b - a) > 1 }.to_a

  # sorting/reverse
  log.call("starting sorting/reverse family")
  sortable = [3, 1, 5, 2, 4]
  results[:sort] = sortable.sort
  sortable_bang = sortable.dup
  sortable_bang.sort!
  results[:sort_bang] = sortable_bang
  results[:sort_by] = words.sort_by(&:length)
  results[:reverse] = numbers.reverse
  results[:reverse_each] = numbers.reverse_each.to_a

  # min/max family
  log.call("starting min/max family")
  results[:min] = numbers.min
  results[:max] = numbers.max
  results[:minmax] = numbers.minmax
  results[:min_by] = words.min_by(&:length)
  results[:max_by] = words.max_by(&:length)
  results[:minmax_by] = words.minmax_by(&:length)

  # take/drop family
  log.call("starting take/drop family")
  results[:take] = numbers.take(3)
  results[:take_while] = numbers.take_while { |n| n < 4 }
  results[:drop] = numbers.drop(2)
  results[:drop_while] = numbers.drop_while { |n| n < 3 }

  # first/last
  log.call("starting first/last family")
  results[:first] = numbers.first
  results[:last] = numbers.last

  # cycle
  log.call("starting cycle family")
  cycle_values = []
  [1, 2].cycle(2) do |n|
    log.call("cycle yielded=#{n}")
    cycle_values << n
  end
  results[:cycle] = cycle_values

  # zip
  log.call("starting zip family")
  results[:zip] = [1, 2, 3].zip(%i[a b c], %w[x y z])

  # conversions
  log.call("starting conversions family")
  results[:to_a] = (1..3).to_a
  results[:to_h] = pairs.to_h
  results[:entries] = numbers.entries

  # misc
  log.call("starting misc family")
  results[:sum] = numbers.sum
  results[:uniq] = [1, 1, 2, 2, 3].uniq
  uniq_bang = [1, 1, 2, 2, 3]
  uniq_bang.uniq!
  results[:uniq_bang] = uniq_bang
  results[:compact] = with_nil.compact
  compact_bang = with_nil.dup
  compact_bang.compact!
  results[:compact_bang] = compact_bang
  results[:flatten] = nested.flatten
  flatten_bang = nested.dup
  flatten_bang.flatten!
  results[:flatten_bang] = flatten_bang

  log.call("finished all calculations, running assertions")
  assert_equal.call("each_with_index", results[:each_with_index], ["0:1", "1:2", "2:3", "3:4", "4:5"])
  assert_equal.call("each_entry", results[:each_entry], [1, 2, 3, 4, 5])
  assert_equal.call("each_slice", results[:each_slice], [[1, 2], [3, 4], [5]])
  assert_equal.call("each_cons", results[:each_cons], [[1, 2, 3], [2, 3, 4], [3, 4, 5]])
  assert_equal.call("each_with_object", results[:each_with_object], { 1 => 1, 2 => 4, 3 => 9, 4 => 16, 5 => 25 })
  assert_equal.call("each_direct", results[:each_direct], [2, 4, 6, 8, 10])
  assert_equal.call("each_do", results[:each_do], [11, 12, 13, 14, 15])

  assert_equal.call("map", results[:map], [10, 20, 30, 40, 50])
  assert_equal.call("map_bang", results[:map_bang], [3, 6, 9, 12, 15])
  assert_equal.call("collect", results[:collect], [2, 3, 4, 5, 6])
  assert_equal.call("collect_bang", results[:collect_bang], [3, 4, 5, 6, 7])
  assert_equal.call("flat_map", results[:flat_map], [1, 2, 3, 4, 5])
  assert_equal.call("filter_map", results[:filter_map], [100, 300, 500])

  assert_equal.call("select", results[:select], [3, 4, 5])
  assert_equal.call("filter", results[:filter], [2, 4])
  assert_equal.call("reject", results[:reject], [3, 4, 5])
  assert_equal.call("grep", results[:grep], ["ana", "carol", "davi"])
  assert_equal.call("grep_v", results[:grep_v], ["bob"])

  assert_equal.call("find", results[:find], 4)
  assert_equal.call("detect", results[:detect], 4)
  assert_equal.call("find_all", results[:find_all], [1, 3, 5])
  assert_equal.call("find_index", results[:find_index], 3)

  assert_equal.call("any", results[:any], true)
  assert_equal.call("all", results[:all], true)
  assert_equal.call("none", results[:none], true)
  assert_equal.call("one", results[:one], true)
  assert_equal.call("include", results[:include], true)
  assert_equal.call("member", results[:member], true)

  assert_equal.call("count", results[:count], 3)
  assert_equal.call("size", results[:size], 5)
  assert_equal.call("length", results[:length], 5)
  assert_equal.call("tally", results[:tally], { 1 => 2, 2 => 3, 3 => 1 })

  assert_equal.call("reduce", results[:reduce], 15)
  assert_equal.call("inject", results[:inject], 120)

  assert_equal.call("group_by", results[:group_by], { 3 => ["ana", "bob"], 5 => ["carol"], 4 => ["davi"] })
  assert_equal.call("partition", results[:partition], [[2, 4], [1, 3, 5]])
  assert_equal.call("chunk", results[:chunk], [[1, [1, 1]], [2, [2, 2]], [3, [3]], [1, [1]]])
  assert_equal.call("chunk_while", results[:chunk_while], [[1, 2, 3], [7, 8], [20]])
  assert_equal.call("slice_when", results[:slice_when], [[1, 2], [4, 5], [9]])

  assert_equal.call("sort", results[:sort], [1, 2, 3, 4, 5])
  assert_equal.call("sort_bang", results[:sort_bang], [1, 2, 3, 4, 5])
  assert_equal.call("sort_by", results[:sort_by], ["ana", "bob", "davi", "carol"])
  assert_equal.call("reverse", results[:reverse], [5, 4, 3, 2, 1])
  assert_equal.call("reverse_each", results[:reverse_each], [5, 4, 3, 2, 1])

  assert_equal.call("min", results[:min], 1)
  assert_equal.call("max", results[:max], 5)
  assert_equal.call("minmax", results[:minmax], [1, 5])
  assert_equal.call("min_by", results[:min_by], "ana")
  assert_equal.call("max_by", results[:max_by], "carol")
  assert_equal.call("minmax_by", results[:minmax_by], ["ana", "carol"])

  assert_equal.call("take", results[:take], [1, 2, 3])
  assert_equal.call("take_while", results[:take_while], [1, 2, 3])
  assert_equal.call("drop", results[:drop], [3, 4, 5])
  assert_equal.call("drop_while", results[:drop_while], [3, 4, 5])

  assert_equal.call("first", results[:first], 1)
  assert_equal.call("last", results[:last], 5)
  assert_equal.call("cycle", results[:cycle], [1, 2, 1, 2])
  assert_equal.call("zip", results[:zip], [[1, :a, "x"], [2, :b, "y"], [3, :c, "z"]])
  assert_equal.call("to_a", results[:to_a], [1, 2, 3])
  assert_equal.call("to_h", results[:to_h], { a: 1, b: 2, c: 3 })
  assert_equal.call("entries", results[:entries], [1, 2, 3, 4, 5])

  assert_equal.call("sum", results[:sum], 15)
  assert_equal.call("uniq", results[:uniq], [1, 2, 3])
  assert_equal.call("uniq_bang", results[:uniq_bang], [1, 2, 3])
  assert_equal.call("compact", results[:compact], [1, 2, 3])
  assert_equal.call("compact_bang", results[:compact_bang], [1, 2, 3])
  assert_equal.call("flatten", results[:flatten], [1, 2, 3, 4])
  assert_equal.call("flatten_bang", results[:flatten_bang], [1, 2, 3, 4])

  summary = "[TEST SUMMARY] total=#{assert_total} ok=#{assert_total - assert_failed} erro=#{assert_failed}"
  puts summary
  logger.write(summary)
  logger.write("==== end run_enumerable_examples ====")
end
