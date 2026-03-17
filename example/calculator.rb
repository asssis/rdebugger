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
