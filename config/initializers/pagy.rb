# frozen_string_literal: true

require "pagy/extras/overflow"

# Asking for page 900 of a 3-page list is a bad request, not a 500.
Pagy::DEFAULT[:overflow] = :empty_page
Pagy::DEFAULT[:limit] = 25
Pagy::DEFAULT.freeze
