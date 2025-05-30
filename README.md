Double-entry ledger Rails engine.

## Description

A ledger is the source of truth for all entries in accounting books, this can include
cash in/out, payments, fees, settlements, credits, and a myriad of other operations
performed in a given account.

This ledger provides double-entry transactions under an operations layer.

Queries are available to power a variety of routine outputs like outstanding balances,
reports, consistency checks, and so on.

## License
You need written authorization from the author for any type of usage.

# Usage
Plug into your existing app and attach it to (preferably brand new) database.

To mount this engine, add the gem

```ruby
# Gemfile
gem 'stern', path: 'engines/stern'
```

and mount the route

```ruby
# config/routes.rb
mount Stern::Engine, at: '/stern'
```

Before using it you have to configure

1. Local time zone
2. Chart of accounts
3. Define operations

For further examples, you may find
[this guide](https://dev.to/szaszolak/extracting-rails-engine-by-example-vikings-social-media-4014)
useful.

### Timezone
The ledger uses the versatile `DateTime` to handle events.
Make sure it is configured in your application

```ruby
# config/application.rb
config.time_zone = 'America/Sao_Paulo'
```

### Chart of accounts
Defined at

```
config/chart_of_accounts.yml
```

and has two structures

1. List of books, each mapping an unique id.
2. List of double-entry transactions, each mapping
an unique code and a pair of additive-subtractive books.

### Migrations

Stern uses Postgres as its database and as a result functions and indexes
will not be embed in `db/schema.rb`.
To circumvent this limitation, you may have to migrate separately to add these required functions with

```sh
bin/rails "db:migrate:functions[development]"
```

## Operations

Ledger defines entries, entry pairs, and operations.

Entries are single records to accounting books; because Stern is a double-entry
guaranteeing consistency in such a way inputs match outputs, each entry requires a
counterpair entry, this pair is called an entry pair. Technically entry pairs are
atomic, consistent, isolated, and durable.

Operations are an abstraction atop entry pairs and technically group sequences of
entry pairs defined programmatically. Users should never input entry pairs directly
nor entries, instead should define operations and use operations as an exposed API.

**Example**. `PayCreditCard` involves multiple steps of entry pairs:
- `add_credit_card_captured`: cash in
- `add_credit_card_fee`: transaction fee
- `add_credit_card_internal_fee`: payment institution + interbank fee
- `add_merchant_balance_withholding`: move money from captured silo to merchant
withholding balance
- `add_merchant_balance`: scheduled operation to move money from withholding balance
to merchant's free balance.

Operations are defined in `app/operations`.
Following name conventions, always start with a verb.

## Testing

Use RSpec to run specs.

```sh
RAILS_ENV=test bundle exec rails app:db:drop app:db:setup_env
```

then run RSpec as usual

```sh
rspec
```

## Standalone setup

```sh
RAILS_ENV=development bundle exec rails app:db:drop app:db:setup_env
```

Then drop to console to use the ledger standalone.

_Tip: You may benefit from `include Stern` so you do not need to prefix commands with
`Stern::` for every call._

## Technical notes

This engine was created with

```
rails plugin new stern \
  --mountable \
  --database postgresql \
  --skip-action-mailer \
  --skip-action-mailbox \
  --skip-action-text \
  --skip-action-storage \
  --skip-action-cable \
  --skip-hotwire --skip-sprockets --skip-javascript --skip-turbolinks \
  --skip-test --skip-system-test \
  --skip-gemfile-entry \
  --css=tailwind \
  --dummy_path=spec/dummy
```
