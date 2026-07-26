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

  # The same capture, kept — for specs that assert on what an operator would read.
  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end
end

RSpec.configure do |config|
  config.include OutputCapture
end
