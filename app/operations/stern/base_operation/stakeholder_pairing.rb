module Stern
  class BaseOperation
    # Polymorphism helpers for ops parameterized over `merchant`/`customer`/
    # `partner` (or the `merchant`/`partner` funder subset), plus the
    # `performs_stakeholder_pair` DSL that the dominant single-pair ops use to
    # generate their `target_tuples`/`perform`/`runtime_check` triple.
    #
    # Contract:
    #   * `stakeholder_for(prefix)` / `funder_for(prefix)` scan declared
    #     inputs in a fixed type order and return `[id, type]` for the first
    #     present `<prefix><type>_id`, or `[nil, nil]` if none is set. The
    #     order is load-bearing (Charge*Fee ops rely on `merchant` being
    #     scanned before `customer`).
    #   * `gid_for_slot(:resolved, rid)` returns `rid`; any other Symbol is
    #     dispatched as an input read.
    #   * `pair_template_for(template, type)` interpolates `%{type}` and any
    #     declared input — extra keys ignored, missing keys raise.
    #   * `apply_available_credit` is a no-op for non-positive amounts so fee
    #     reversals leave standing credit alone.
    #   * `performs_stakeholder_pair(...)` defines `target_tuples`, `perform`,
    #     and (when `requires_balance:` is set) `runtime_check` on the
    #     including class. Subclasses may override any generated method.
    module StakeholderPairing
      extend ActiveSupport::Concern

      STAKEHOLDER_TYPES = %i[merchant customer partner].freeze
      FUNDER_TYPES = %i[merchant partner].freeze

      class_methods do
        # Generates `target_tuples`, `perform`, and (optionally) `runtime_check`
        # for the dominant single-pair shape: an op picks a stakeholder/funder via
        # `stakeholder_for` / `funder_for`, formats one entry-pair name from the
        # type, locks the pair's two `(book, gid, currency)` tuples, then writes
        # `EntryPair.add_<pair>(uid, gid, amount, currency, operation_id:)`.
        #
        # `pair_template` is a printf-style string with `%{type}` interpolated
        # from the helper's returned type symbol, e.g. `"unlock_%{type}_balance"`,
        # `"%{type}_credit"`, `"reverse_withdrawal_%{type}"`.
        #
        # `using:` picks the polymorphism helper. `:stakeholder_for` (default)
        # scans `merchant`/`customer`/`partner`; `:funder_for` scans
        # `merchant`/`partner` only — for ops where `customer_id` is a recipient,
        # not a stakeholder candidate (see `ReverseRefund`).
        #
        # `sub_gid:` / `add_gid:` choose the gid passed to `tuples_for_pair` for
        # each side, and (by default) the matching arg to `EntryPair.add_<pair>`.
        # Pass `:resolved` (default) for the id returned by the configured
        # helper, or any input symbol (e.g. `:payment_id`, `:refund_id`).
        #
        # `entry_uid:` / `entry_gid:` override the args to `EntryPair.add_<pair>`
        # (entry uid / cause-of-entry, and the gid both legs land at) for the
        # rare cases where the lock-side gids and the entry-side gids diverge —
        # `ReverseRefund` writes the entry at `(uid: refund_id, gid: funder_id)`
        # while locking on `customer_id`/`funder_id`; `CancelRefund` writes at
        # `(uid: stakeholder_id, gid: refund_id)` while locking on
        # `refund_id`/`stakeholder_id`. Default to `sub_gid` / `add_gid`.
        #
        # `requires_balance:` declares a friendly pre-check via
        # `require_sufficient_balance!`. Keys:
        #   * `book:`        — Symbol (literal book) or String (interpolated with `%{type}`)
        #   * `label:`       — `balance_label:` for the error message
        #   * `gid:`         — slot for the balance read; defaults to `sub_gid`
        #   * `bypass_when:` — method/attr that, when truthy, skips the check
        #
        # `op_label` for the error message is always
        # `name.demodulize.underscore`. Subclasses may override any generated
        # method to extend the behavior.
        #
        # `requires_credit_application:` (default false) extends the macro to the
        # ChargeFee shape: locks an additional `apply_<type>_credit` pair on the
        # stakeholder, and prepends a call to `apply_available_credit` inside the
        # generated `perform` so any standing credit drains into `*_available`
        # before the fee is debited. Used by the four `Charge*Fee` ops.
        #
        # `pair_template` may also reference any input attribute via `%{name}`
        # (e.g. `"charge_%{payment_method}_fee_%{type}"`); all declared inputs
        # are interpolated at call time alongside the resolved `:type`.
        def performs_stakeholder_pair(pair_template,
                                      using: :stakeholder_for,
                                      sub_gid: :resolved,
                                      add_gid: :resolved,
                                      entry_uid: nil,
                                      entry_gid: nil,
                                      requires_balance: nil,
                                      requires_credit_application: false)
          helper       = using
          uid_slot     = entry_uid || sub_gid
          gid_slot     = entry_gid || add_gid
          balance_cfg  = requires_balance
          needs_credit = requires_credit_application

          define_method(:target_tuples) do
            rid, type = public_send(helper)
            pair = pair_template_for(pair_template, type).to_sym
            tuples = tuples_for_pair(pair,
              gid_for_slot(sub_gid, rid),
              gid_for_slot(add_gid, rid),
              currency)
            if needs_credit
              tuples += tuples_for_pair("apply_#{type}_credit".to_sym, rid, rid, currency)
            end
            tuples
          end

          define_method(:perform) do |operation_id|
            rid, type = public_send(helper)
            apply_available_credit(rid, type, operation_id) if needs_credit
            pair = "add_#{pair_template_for(pair_template, type)}".to_sym
            EntryPair.public_send(pair,
              gid_for_slot(uid_slot, rid),
              gid_for_slot(gid_slot, rid),
              amount, currency, operation_id:)
          end

          return unless balance_cfg

          bal_book    = balance_cfg.fetch(:book)
          bal_label   = balance_cfg.fetch(:label)
          bal_gid     = balance_cfg.fetch(:gid, sub_gid)
          bypass_when = balance_cfg[:bypass_when]

          define_method(:runtime_check) do
            next if bypass_when && public_send(bypass_when)

            rid, type = public_send(helper)
            book = bal_book.is_a?(Symbol) ? bal_book : (bal_book % { type: type }).to_sym
            require_sufficient_balance!(
              book_id:       book,
              gid:           gid_for_slot(bal_gid, rid),
              currency:,
              amount:,
              op_label:      self.class.name.demodulize.underscore,
              balance_label: bal_label,
            )
          end
        end
      end

      # Returns `[id, type]` for the first present `<prefix><type>_id` input,
      # scanning `:merchant`, `:customer`, `:partner` in that order. Returns
      # `[nil, nil]` when none is set.
      #
      # `prefix` lets ops with multiple stakeholder slots (e.g. `TransferBalance`'s
      # `from_*` / `to_*`) reuse the same scan:
      #
      #   stakeholder_for           # → [merchant_id, :merchant] etc.
      #   stakeholder_for("from_")  # → [from_merchant_id, :merchant] etc.
      #
      # Subclasses pair this with `validates_exactly_one_of` on the same fields
      # so exactly one branch is reachable after validation.
      def stakeholder_for(prefix = "")
        STAKEHOLDER_TYPES.each do |type|
          attr = :"#{prefix}#{type}_id"
          next unless self.class.inputs.include?(attr)

          id = public_send(attr)
          return [ id, type ] if id.present?
        end

        [ nil, nil ]
      end

      # Returns `[id, type]` for the first present `<prefix><type>_id` input
      # restricted to funder roles (`:merchant`, `:partner`) — distinct from
      # `stakeholder_for`, which would return `customer_id` first when an op
      # carries it as a recipient rather than as a stakeholder candidate
      # (e.g. `ReverseRefund`).
      def funder_for(prefix = "")
        FUNDER_TYPES.each do |type|
          attr = :"#{prefix}#{type}_id"
          next unless self.class.inputs.include?(attr)

          id = public_send(attr)
          return [ id, type ] if id.present?
        end

        [ nil, nil ]
      end

      # Resolves a gid slot used by `performs_stakeholder_pair`. The sentinel
      # `:resolved` returns the id from the configured polymorphism helper
      # (`stakeholder_for` / `funder_for`); any other Symbol is treated as an
      # input name and read via `public_send`.
      def gid_for_slot(slot, resolved_id)
        slot == :resolved ? resolved_id : public_send(slot)
      end

      # Interpolates `pair_template` with the resolved stakeholder `type` plus
      # every declared input attribute, so templates may reference inputs
      # directly (e.g. `"charge_%{payment_method}_fee_%{type}"`). Extra keys are
      # ignored by Ruby's `%` operator; missing keys raise KeyError.
      def pair_template_for(pair_template, type)
        args = { type: type }
        self.class.inputs.each { |inp| args[inp] = public_send(inp) }
        pair_template % args
      end

      # Drains standing `<type>_credit` into `<type>_available` up to `amount`
      # before a fee is debited. Used by ops declared with
      # `performs_stakeholder_pair ..., requires_credit_application: true`.
      # No-op for non-positive amounts (fee reversals leave the credit alone).
      def apply_available_credit(stakeholder_id, stakeholder_type, operation_id)
        return unless amount.positive?

        credit_balance = ::Stern.balance(stakeholder_id, "#{stakeholder_type}_credit".to_sym, currency)
        credit_to_apply = [ credit_balance, amount ].min
        return unless credit_to_apply.positive?

        EntryPair.public_send(
          "add_apply_#{stakeholder_type}_credit".to_sym,
          stakeholder_id, stakeholder_id, credit_to_apply, currency, operation_id:,
        )
      end

      private

      # Friendly pre-check for ops that move funds out of a `(book, gid, currency)`
      # slice: reads the per-gid balance under the operation's advisory lock and
      # raises `Stern::InsufficientFunds` when `amount` would overdraw it. The
      # DB-level `non_negative` constraint on guarded books would translate the
      # same condition into `BalanceNonNegativeViolation`; we raise the parent
      # `InsufficientFunds` here so callers can rescue both layers uniformly.
      #
      # `op_label` and `balance_label` shape the message as
      # `"#{op_label} amount #{amount} exceeds #{balance_label} #{current}"`,
      # so existing callers (and their specs) can keep the exact phrasing they
      # had before extraction.
      def require_sufficient_balance!(book_id:, gid:, currency:, amount:, op_label:, balance_label:)
        current = BalanceQuery.new(gid:, book_id:, currency:, timestamp: Time.current).call
        return if amount <= current

        raise ::Stern::InsufficientFunds,
          "#{op_label} amount #{amount} exceeds #{balance_label} #{current}"
      end
    end
  end
end
