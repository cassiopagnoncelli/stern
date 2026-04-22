# frozen_string_literal: true

# Adds `each_update!` / `each_update` to the including model's relations only.
# Unlike a global `ActiveRecord::Relation.include`, this leaves the host app's own
# relations untouched.
#
# Usage:
#
#   class Foo < ApplicationRecord
#     include Stern::EachUpdate
#   end
#
#   Foo.where(...).each_update!(status: :picked)
module Stern
  module EachUpdate
    extend ActiveSupport::Concern

    module RelationMethods
      def each_update!(attributes)
        each { |record| record.update!(attributes) }
      end

      def each_update(attributes)
        each { |record| record.update(attributes) }
      end
    end

    included do
      relation_delegate_class(ActiveRecord::Relation).include(RelationMethods)
    end
  end
end
