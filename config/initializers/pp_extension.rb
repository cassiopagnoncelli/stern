# frozen_string_literal: true

# Extend Array with pp method that calls pp on each element
module PpExtension
  def pp
    each(&:pp)
    self
  end
end

# Apply the extension to Array
Array.include PpExtension

# Apply the extension to ActiveRecord::Relation if ActiveRecord is defined
if defined?(ActiveRecord::Relation)
  ActiveRecord::Relation.include PpExtension
end
