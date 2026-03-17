
require_relative "enumerable_examples"

class Calculator
  attr_accessor :base, :history

  def initialize(base)
    @base = base
    @history = []
  end

  def add(value)
    @base += value
    @history << @base
  end

  def add_many(values)
    for value in values
      add(value)
    end
  end

  def result
    @base
  end
end

class Printer
  attr_accessor :prefix

  def initialize(prefix = "Valor")
    @prefix = prefix
  end

  def print_value(value)
    puts "#{@prefix}: #{value}"
  end

  def print_history(history)
    for item in history
      puts "Historico -> #{item}"
    end
  end
end

def test_debugger
  calc = Calculator.new(10)
  printer = Printer.new("Resultado")

  values = [5, 2, 3]
  for value in values
    calc.add(value)
  end

  calc.add_many([1, 4])

  numbers = [1, 2, 3, 4, 5]
  filtered = numbers.select { |n| n > 2 } # esse filtro trouxe nil, ele deveria trazer 3,4,5

  mutable_numbers = [1, 2, 3, 4, 5]
  mutable_numbers.select! do |n| # não fez o loop
    n > 2
  end

  mapped = mutable_numbers.map do |n|
    n * 10
  end

  i = 0
  while i < mapped.length
    calc.add(mapped[i] / 10)
    i += 1
  end

  printer.print_value(calc.result)
  printer.print_history(calc.history)
  puts "Filtered: #{filtered.inspect}"
  puts "Select! mutable: #{mutable_numbers.inspect}"
  puts "Mapped: #{mapped.inspect}"
end

puts "Hello DAP"
x = 1
numbers = [1, 2, 3]
for n in numbers
  x = x + n
  puts "x parcial: #{x}"
end

numbers.each do |item|
  x = x + item
  puts "x each: #{x}"
end

i = 0
while i < numbers.length
  x = x + numbers[i]
  puts "x while: #{x}"
  i = i + 1
end

calc = Calculator.new(10)

puts x
test_debugger
run_enumerable_examples
puts "done"
