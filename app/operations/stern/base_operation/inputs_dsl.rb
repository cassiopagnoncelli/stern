module Stern
  class BaseOperation
    # Declared-input handling: the `inputs` macro, kwarg-checked construction,
    # the `normalize_inputs` hook, currency validation/coercion, and the
    # hash/JSON projections that downstream concerns read.
    #
    # Contract: a subclass declares its public surface via `inputs :a, :b`;
    # every kwarg passed to `.new` must be in that list (else `ArgumentError`),
    # and every declared input is exposed as an `attr_accessor`. After kwargs
    # are assigned, `normalize_inputs` runs once. `operation_params` and
    # `json_normalized_params` are both keyed exclusively by the declared
    # input names — stray instance variables never leak into them.
    #
    # Currency: when `:currency` is declared, an unknown value surfaces as a
    # validation error (not a constructor raise). Normalization to the
    # integer code is deferred to `BaseOperation#call` so the validation
    # error path is reachable.
    module InputsDsl
      extend ActiveSupport::Concern

      included do
        validate :currency_must_be_known
      end

      class_methods do
        def inputs(*names)
          @inputs ||= []
          return @inputs if names.empty?

          @inputs.concat(names)
          attr_accessor(*names)
        end

        # Declares that exactly one of the given attributes must be present. Adds an
        # error on `:base` when the count is not 1, so validation messages flow through
        # the standard `errors.full_messages` path instead of bare `ArgumentError`s
        # raised from `perform`.
        def validates_exactly_one_of(*attrs)
          validate do
            present = attrs.count { |a| public_send(a).present? }
            next if present == 1

            errors.add(:base, "exactly one of #{attrs.join(', ')} must be set (got #{present})")
          end
        end
      end

      def initialize(**kwargs)
        extra = kwargs.keys - self.class.inputs
        raise ArgumentError, "unknown inputs for #{self.class.name}: #{extra}" if extra.any?

        self.class.inputs.each { |n| public_send("#{n}=", kwargs[n]) }
        normalize_inputs
      end

      # Hook for subclasses to coerce/transform assigned inputs. Runs at the end
      # of `initialize`, so subclasses don't need to call `super`. Currency
      # normalization is deferred to `call` so unknown currencies surface as
      # validation errors rather than raising from the constructor.
      def normalize_inputs; end

      private

      def operation_params
        self.class.inputs.to_h { |n| [ n.to_s, public_send(n) ] }
      end

      # `operation_params` projected through JSON's type system, so the result has the
      # same shape as `Operation.params` after a round-trip through the `json` column.
      def json_normalized_params
        JSON.parse(operation_params.to_json)
      end

      # Validates that `currency` (when declared as an input) refers to a known
      # currency. Runs through `Stern.cur` and translates `UnknownCurrencyError`
      # into a regular validation error so callers see `errors.full_messages`
      # rather than a raw raise from the constructor. Blank values fall through
      # to the subclass's `presence` validation.
      def currency_must_be_known
        return unless self.class.inputs.include?(:currency)
        return if currency.blank?

        ::Stern.cur(currency, result: :index)
      rescue ::Stern::UnknownCurrencyError
        errors.add(:currency, "is not a recognized currency")
      end

      # Canonicalizes validated inputs (e.g. currency name → integer code). Runs
      # in `call` after `invalid?` passes, so unknown values cannot reach this
      # point. `Stern.cur(_, result: :index)` is idempotent for integer inputs.
      def normalize_validated_inputs
        self.currency = ::Stern.cur(currency, result: :index) if self.class.inputs.include?(:currency) && currency
      end
    end
  end
end
