module Stern
  class Operation < ApplicationRecord
    enum :direction, { do: 1, undo: -1 }

    validates_format_of :name, with: /\A[A-Z][a-zA-Z0-9]*\z/, blank: false
    validates_presence_of :direction
    validates :params, presence: true, allow_blank: true

    has_many :txs, class_name: 'Stern::Tx'
  end
end
