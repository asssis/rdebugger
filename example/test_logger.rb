require 'fileutils'

class TestLogger
  def initialize(file_path)
    @file_path = file_path
    FileUtils.mkdir_p(File.dirname(@file_path))
  end

  def write(message)
    timestamp = Time.now.strftime('%Y-%m-%d %H:%M:%S.%L')
    File.open(@file_path, 'a') do |f|
      f.puts("[#{timestamp}] #{message}")
    end
  end
end
