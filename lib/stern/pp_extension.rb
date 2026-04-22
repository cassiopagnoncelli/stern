# frozen_string_literal: true

# Console-only helper: extends Array / ActiveRecord::Relation with `.pp` so the user can
# pretty-print every element via `Entry.all.pp`. Installed in `Engine.console` only —
# never loaded in web / test / production request paths to avoid polluting host apps.
module Stern
  module PpExtension
    def pp
      each(&:pp)
      self
    end
  end
end
