# frozen_string_literal: true

# Here for one reason: the README's "Transactions" example creates an Account
# and a Person that belongs to it, and `includes(:account)` is the eager-load
# in the "Graph associations" acceptance line. It has no graph mapping.
class Account < ApplicationRecord
  has_many :people, dependent: :nullify
end
