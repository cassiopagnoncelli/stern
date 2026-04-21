# frozen_string_literal: true

# Installs the append-only ledger contract on a record:
#
#   - `create!` is the only way in (bare `create` raises).
#   - Updates are never allowed (instance, class, or via save of a persisted record).
#   - `destroy!` is the only way out (bare `destroy` raises, and `destroy_all` is blocked).
module Stern
  module AppendOnly
    extend ActiveSupport::Concern

    included do
      before_update { raise NotImplementedError, ::Stern::AppendOnly.update_message(self.class) }
    end

    class_methods do
      def create(**_attrs)
        raise NotImplementedError, "Use create! instead"
      end

      def update_all(*_args)
        raise NotImplementedError, ::Stern::AppendOnly.update_message(self)
      end

      def destroy_all
        raise NotImplementedError, "Ledger is append-only; use delete_all if you really mean it"
      end
    end

    def update(*_args)
      raise NotImplementedError, ::Stern::AppendOnly.update_message(self.class)
    end

    def update!(*_args)
      raise NotImplementedError, ::Stern::AppendOnly.update_message(self.class)
    end

    def destroy
      raise NotImplementedError, "Use destroy! instead"
    end

    def self.update_message(klass)
      "#{klass.name.demodulize} records cannot be updated by design"
    end
  end
end
