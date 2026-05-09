module Stern
  class Operation < ApplicationRecord
    # Name of the partial unique index on `stern_operations.idem_key`. Kept in
    # lockstep with the `add_index` in db/migrate/20260427000000_init_stern_schema.rb;
    # used by `idem_key_collision?` to distinguish RecordNotUnique caused by an
    # idem_key replay from any other unique-violation surfaced via this table.
    IDEM_KEY_INDEX = "index_stern_operations_on_idem_key".freeze

    has_many :entry_pairs, class_name: "Stern::EntryPair", dependent: :restrict_with_exception

    validates :name, presence: true, allow_blank: false, allow_nil: false
    validates :params, presence: true, allow_blank: true
    validates :idem_key,
      presence: true,
      allow_blank: true,
      uniqueness: true,
      length: { minimum: 8, maximum: 24, allow_nil: true, allow_blank: false }

    # True iff `err` is a unique-violation specifically against the idem_key
    # index. Inspects PG's CONSTRAINT_NAME diagnostic field (the same approach
    # `Entry.non_negative_violation?` uses for CHECK violations) so the caller
    # can swallow benign idem_key replay races without masking unrelated
    # uniqueness failures from `perform`.
    def self.idem_key_collision?(err)
      cause = err.cause
      return false unless defined?(PG::UniqueViolation) && cause.is_a?(PG::UniqueViolation)

      cause.result&.error_field(PG::Result::PG_DIAG_CONSTRAINT_NAME) == IDEM_KEY_INDEX
    end

    # Returns the CamelCase names of every operation class exposed by the active chart's
    # operations module (e.g. ["ChargePayment"] when the chart declares `operations: general`).
    # Returns strings, not classes, to avoid depending on Zeitwerk having already loaded them.
    def self.list
      dir = Engine.root.join("app", "operations", "stern", ::Stern.chart.operations_module)
      Dir[dir.join("*.rb")].map { |file| File.basename(file, ".rb").camelize }.sort
    end

    def pp
      params_flat = flatten_params(params).map { |k, v| "#{k}:#{v}" }.join(" ") if params
      params_flat ||= "N/A"

      AnsiPrint.puts_colorized([
        [ "Operation", :white ],
        [ "#{format("%5s", id)}", :white, :bold ],
        [ "|", :white ],
        [ updated_at, :purple, :bold ],
        [ "|", :white ],
        [ "Name:", :white ],
        [ format("%-15s", name || "N/A"), :white, :bold ],
        [ "|", :white ],
        [ "Idemp:", :white ],
        [ format("%-20s", idem_key || "N/A"), :orange, :bold ],
        [ "|", :white ],
        [ "Params:", :white ],
        [ params_flat, :yellow, :bold ]
      ])
    end

    private

    def flatten_params(hash, parent_key = "", separator = ".")
      hash.each_with_object({}) do |(k, v), h|
        new_key = parent_key.empty? ? k : "#{parent_key}#{separator}#{k}"
        if v.is_a?(Hash)
          h.merge!(flatten_params(v, new_key, separator))
        else
          h[new_key] = v
        end
      end
    end
  end
end
