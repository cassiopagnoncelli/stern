Double-entry ledger Rails engine.

## To do

1. Scheduled operations

## Description

A ledger is the source of truth for all entries in accounting books, this can include
cash in/out, payments, fees, settlements, credits, and a myriad of other operations
performed in a given account.

This ledger provides double-entry transactions under an operations layer.

Queries are also available to power a variety of routine outputs like outstanding balances,
reports, consistency checks, and so on.

## License
You need written authorization from the author for any type of usage.

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

Before using it you may have to configure

1. Local time zone
2. Chart of accounts
3. Define operations

For further examples, you may find
[this guide](https://dev.to/szaszolak/extracting-rails-engine-by-example-vikings-social-media-4014)
useful.

## Timezone
The ledger uses the versatile `DateTime` to handle events.
Make sure it is configured in your application

```ruby
# config/application.rb
config.time_zone = 'America/Sao_Paulo'
```

## Chart of accounts
Defined at

```
config/chart_of_accounts.yml
```

and has two structures

1. List of books, each mapping an unique id.
2. List of double-entry transactions, each mapping
an unique code and a pair of additive-subtractive books.

## Migrations

Stern uses Postgres as its database and as a result functions and indexes
will not be embed in `db/schema.rb`.
To circumvent this limitation, you have add functions to migrations with

```sh
rails app:db:migrate:functions
```

## Operatons
Operations are an abstraction layer defining how transactions take place.
In fact, TXs should never be used directly; instead, use operations.

> Example. `PayCreditCard` rebates fees from existing credits before registering
> the fee via `add_credit_card_fee` transaction, then registered the captured amount
> via `add_credit_card_capture` transaction.

Refer to `app/operations` to implement operations.
Following name conventions, always start with a verb.

# Testing the app

Use RSpec to run specs.

To do it, have a clean database and prepare it first.

```sh
RAILS_ENV=test rails db:drop
RAILS_ENV=test rails db:create db:schema:load app:db:migrate:functions
```

then run RSpec as usual

```sh
rspec
```
