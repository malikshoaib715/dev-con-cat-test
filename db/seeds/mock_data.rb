module Seeds
  # Thin reader over the assignment's fixture files. The `_comment` / `_note`
  # annotations are documentation for humans, not data, so they never reach the
  # database.
  module MockData
    ROOT = Rails.root.join("mock-data")
    ANNOTATION_KEYS = %w[_comment _note].freeze

    def self.read(*path)
      strip_annotations(JSON.parse(ROOT.join(*path).read))
    end

    def self.strip_annotations(value)
      case value
      when Hash  then value.except(*ANNOTATION_KEYS).transform_values { |nested| strip_annotations(nested) }
      when Array then value.map { |nested| strip_annotations(nested) }
      else value
      end
    end
  end
end
