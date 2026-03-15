
# Classe 1
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

# Classe 2
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

puts x
test_debugger
puts "done"
