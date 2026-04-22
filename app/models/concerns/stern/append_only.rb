# frozen_string_literal: true

# Forbids any kind of update on the including model: instance-level `update` / `update!`,
# class-level `update_all`, and `save` on a persisted record with changes (via `before_update`).
# Creates and destroys are not restricted here — models that need a stricter contract (e.g.
# blocking bare `create` / `destroy` in favor of bang-only access) add their own overrides.
module Stern
  module AppendOnly
    extend ActiveSupport::Concern

    included do
      before_update { raise NotImplementedError, ::Stern::AppendOnly.update_message(self.class) }
    end

    class_methods do
      def update_all(*_args)
        raise NotImplementedError, ::Stern::AppendOnly.update_message(self)
      end
    end

    def update(*_args)
      raise NotImplementedError, ::Stern::AppendOnly.update_message(self.class)
    end

    def update!(*_args)
      raise NotImplementedError, ::Stern::AppendOnly.update_message(self.class)
    end

    def self.update_message(klass)
      "#{klass.name.demodulize} records cannot be updated by design"
    end
  end
end
