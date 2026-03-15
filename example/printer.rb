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
