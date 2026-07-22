module OutputCapture
  # The seed loaders report progress on stdout; specs that drive them keep the
  # RSpec output readable.
  def without_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = original
  end
end

RSpec.configure do |config|
  config.include OutputCapture
end
