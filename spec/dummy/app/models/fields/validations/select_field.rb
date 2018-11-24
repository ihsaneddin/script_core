# frozen_string_literal: true

module Fields::Validations
  class SelectField < FieldOptions
    prepend Concerns::Fields::Validations::Presence
  end
end
