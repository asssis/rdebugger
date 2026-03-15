
require_relative "calculator"
require_relative "printer"

# Método de teste
def test_debugger
	calc = Calculator.new(10)
	values = [5, 2, 3]
	for value in values
		calc.add(value)
	end

	calc.add_many([1, 4])

	printer = Printer.new("Resultado")
	printer.print_value(calc.result)
	printer.print_history(calc.history)
end

# Execução principal
puts "Hello DAP"
x = 1
numbers = [1, 2, 3]
for n in numbers
	x = x + n
	puts "x parcial: #{x}"
end

# Loop com each
numbers.each do |item|
	x = x + item
	puts "x each: #{x}"
end

# Loop com while
i = 0
while i < numbers.length
	x = x + numbers[i]
	puts "x while: #{x}"
	i = i + 1
end

calc = Calculator.new(10)

puts x
test_debugger
puts "done"
